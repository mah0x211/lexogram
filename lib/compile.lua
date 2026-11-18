--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- lexogram.compile: compiles a grammar table into plain data for the
-- tokenizer and the analyzer. compile(grammar) runs lexogram.check first
-- (and reuses the automaton and decisions it built); with any error it returns nil and the
-- diagnostics, otherwise the compiled object and the diagnostics (only
-- warnings, possibly none). It never raises.
--
-- The compiled object contains only numbers, strings, booleans and tables
-- of them, without metatables, cycles or tables referenced twice, and is
-- the same on every runtime for the same grammar:
--
--   lexogram  the specification revision in effect for the grammar (an
--             entry of the revision history, not the grammar's own string)
--   name      the name of the grammar
--   version   the version of the grammar (MAJOR.MINOR.PATCH)
--   kinds     array indexed by kind id of { name, category, skip }:
--               1 = { name = 'INVALID', category = 'error' }: a byte that
--                   matches no token
--               2 = { name = 'ERROR', category = 'error' }: an error span
--               then pattern tokens (by name), symbols and keywords (by
--               index), delimited tokens (by name) and the rules whose
--               names do not start with "_" (by name); the contextual
--               keywords follow the keywords (by index). category is
--               'token' (also for delimited tokens), 'symbol', 'keyword',
--               'rule' or 'error'; skip is true for tokens listed in skip.
--               A contextual keyword (category 'keyword') also has base,
--               the kind id of the pattern token that its text is read as
--               (the parser takes a token of that kind with that text as
--               the keyword where its rules expect the keyword), and
--               ignore_case = true when its text is compared after ASCII
--               folding.
--   names     map from token names, rule names (rules with a kind) and the
--             reserved names to kind ids
--   literals  map from literal strings (as declared) to kind ids
--   lexer     the token automaton:
--     nclasses, classes  classes[b + 1] is the class (1..nclasses) of byte b
--     nstates, trans     trans[(s - 1) * nclasses + c] is the state after
--                        state s and a byte of class c; 0 is the dead state
--                        (no transition). The start state is 1.
--     accept             accept[s] is the kind id accepted in state s, or 0;
--                        -1 marks a dispatch state
--     dispatch           with lookaheads only: dispatch[s] = { preds,
--                        targets } for a dispatch state s, which consumes
--                        nothing: at a position, with v the valuation of
--                        the predicates preds there (bit j - 1 set when
--                        preds[j] holds), the state is targets[v + 1]
--     predicates         with lookaheads only: array by predicate id of
--                        { forward, distance, backward }: forward is an
--                        automaton of the same shape (dead state 0 also
--                        when the predicate can no longer hold): the
--                        predicate holds at a position when it reaches a
--                        state with accept ~= 0 from there (also without
--                        a bound on the bytes it reads); distance is the
--                        largest number of bytes such a run reads, or false
--                        without a bound, in which case backward is an
--                        automaton that, run from the end of the input
--                        toward its start (from state 1, resolving its
--                        dispatch states at each position), accepts at
--                        position i when the predicate holds there
--     leading            an automaton of the same shape over the leading
--                        tokens (listed in leading), which the automaton
--                        above does not have; absent without them
--     open               an automaton of the same shape over the opens of
--                        the delimited tokens; accept holds indexes into
--                        delimited
--     delimited          dense array of { id, prefix, capture, close, nest,
--                        inner } in kind id order: one per delimited token
--                        table with open and close, and one per table named
--                        by the match of a prefixed table (in match order):
--                          id       the kind id of the token
--                          prefix   fixed byte length before the capture
--                                   (absent without a capture)
--                          capture  automaton of the capture definition
--                                   (same shape, absent without a capture)
--                          close    array of parts { literal = <string> }
--                                   or { capture = true }
--                          nest     'count' or 'error' (absent: an open in
--                                   the body is ordinary text)
--                          inner    with nest, the index of the entry whose
--                                   open is a nested open (the entry itself,
--                                   or for a prefixed table the entry of the
--                                   named table)
--
-- Tokenizing: at the start of input, if the leading automaton accepts a
-- non-empty prefix, the longest one is the token. Otherwise, at a
-- position, if the open automaton accepts a non-empty prefix, the entry of
-- delimited with the longest open wins. After its open
-- matched at pos, the capture starts at pos + prefix and ends where the
-- capture automaton, run greedily from there, has no transition. The close
-- string is the concatenation of the close parts with the captured bytes
-- substituted, and the body ends at the first occurrence of the close
-- string after the open (without one, the token runs to the end of the
-- input). Otherwise the longest prefix accepted by lexer wins, with the
-- kind accept[s] of its final state; a byte that starts no token is
-- INVALID. In an automaton with dispatch states, a dispatch state reached
-- at a position (the start state at the start position, or the state after
-- a byte at the position after it) is replaced by its target for the
-- values of its predicates at that position before anything else.
--
--   syntax    the rules as instructions (see lexogram.compile.codegen for
--             the instruction set and the shape of each construct):
--     start      index of the start rule in rules; the input must end after
--                it (the next token is the end of input, kind 0)
--     rules      array, by rule name, of { name, kind, entry }: kind is the
--                kind id emitted by ENTER and EXIT, or 0 for a rule whose
--                name starts with "_" (no events); entry is its address
--     code       flat array of opcodes and operands
--     decisions  array of decision tables used by SWITCH, TEST and TRY;
--                maps keyed by kind ids, 0 being the end of input
local type = type
local next = next
local rawget = rawget
local ipairs = ipairs
local run_check = require('lexogram.check').run
local generate = require('lexogram.compile.codegen').generate
local resolve_version = require('lexogram.version').resolve

-- Category of each definition kind of lexogram.compile.lexer.
local CATEGORY = {
    reserved = 'error',
    token = 'token',
    delimited = 'token',
    symbol = 'symbol',
    keyword = 'keyword',
    contextual = 'keyword',
}

--- copy_array returns a copy of the array t of plain values.
--- @param t table
--- @return table
local function copy_array(t)
    local out = {}
    for i = 1, #t do
        out[i] = t[i]
    end
    return out
end

--- automaton returns the runtime fields of a DFA of lexogram.compile.dfa.
--- @param d table
--- @return table
local function automaton(d)
    local dispatch
    local accept = copy_array(d.accept)
    if d.dispatch then
        dispatch = {}
        for s, entry in next, d.dispatch do
            dispatch[s] = {
                preds = copy_array(entry.preds),
                targets = copy_array(entry.targets),
            }
            -- the runtime looks at accept on every state; a dispatch state
            -- accepts nothing, so the mark costs nothing on other states
            accept[s] = -1
        end
    end
    return {
        nclasses = d.nclasses,
        classes = copy_array(d.classes),
        nstates = d.nstates,
        trans = copy_array(d.trans),
        accept = accept,
        dispatch = dispatch,
    }
end

--- predicate_automata returns the compiled predicates of
--- lexogram.compile.lookahead.build, or nil without lookaheads.
--- @param list table[]?
--- @return table[]?
local function predicate_automata(list)
    if not list then
        return nil
    end
    local out = {}
    for id, entry in ipairs(list) do
        out[id] = {
            forward = automaton(entry.forward),
            distance = entry.distance,
            backward = entry.backward and automaton(entry.backward),
        }
    end
    return out
end

--- delimited_entries returns the compiled delimited tokens in the order
--- of the indexes accepted by the open automaton.
--- @param entries table[] { id, token, inner }
--- @return table[]
local function delimited_entries(entries)
    local out = {}
    for i, entry in ipairs(entries) do
        local token = entry.token
        local close = {}
        for j, part in ipairs(token.close) do
            close[j] = {
                literal = part.literal,
                capture = part.capture,
            }
        end
        out[i] = {
            id = entry.id,
            prefix = token.prefix,
            capture = token.capture and automaton(token.capture),
            close = close,
            nest = token.nest,
            inner = token.nest and entry.inner,
        }
    end
    return out
end

--- skipped_names returns the set of names listed in skip.
--- @param grammar table
--- @return table
local function skipped_names(grammar)
    local set = {}
    local skip = rawget(grammar, 'skip')
    if type(skip) == 'table' then
        for _, name in next, skip do
            set[name] = true
        end
    end
    return set
end

--- build_object returns the compiled object of a grammar without errors.
--- @param grammar table
--- @param lexer table result of lexogram.compile.lexer.build
--- @param syntax table result of lexogram.compile.syntax.analyze
--- @return table
local function build_object(grammar, lexer, syntax)
    local skipped = skipped_names(grammar)
    local kinds, names, literals = {}, {}, {}
    for _, def in ipairs(lexer.defs) do
        local category = CATEGORY[def.kind]
        kinds[def.id] = {
            name = def.name,
            category = category,
            skip = skipped[def.name] == true and category == 'token',
            base = def.base,
            ignore_case = def.base and def.ignore_case or nil,
        }
        if category == 'symbol' or category == 'keyword' then
            literals[def.name] = def.id
        else
            names[def.name] = def.id
        end
    end
    local code, rule_kinds = generate(syntax, rawget(grammar, 'start'),
                                      #kinds + 1)
    for _, kind in ipairs(rule_kinds) do
        kinds[kind.id] = {
            name = kind.name,
            category = 'rule',
            skip = false,
        }
        names[kind.name] = kind.id
    end
    local automata = automaton(lexer.dfa)
    automata.leading = lexer.leading and automaton(lexer.leading)
    automata.open = automaton(lexer.delimited.open)
    automata.delimited = delimited_entries(lexer.delimited.entries)
    automata.predicates = predicate_automata(lexer.predicates)
    return {
        lexogram = resolve_version(rawget(grammar, 'lexogram')),
        name = rawget(grammar, 'name'),
        version = rawget(grammar, 'version'),
        kinds = kinds,
        names = names,
        literals = literals,
        lexer = automata,
        syntax = code,
    }
end

--- compile compiles grammar. It returns nil and the diagnostics of
--- lexogram.check when there is an error, otherwise the compiled object
--- and the diagnostics (warnings only). It reuses the token automaton and
--- the lookahead decisions that the check built. It never raises.
--- @param grammar any
--- @return table? compiled
--- @return table[] diagnostics
local function compile(grammar)
    local diagnostics, lexer, syntax = run_check(grammar)
    for _, d in ipairs(diagnostics) do
        if d.severity == 'error' then
            return nil, diagnostics
        end
    end
    return build_object(grammar, lexer, syntax), diagnostics
end

return {
    compile = compile,
}
