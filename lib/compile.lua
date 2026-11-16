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
-- tokenizer (the syntax part is added by a later version). compile(grammar)
-- runs lexogram.check first; with any error it returns nil and the
-- diagnostics, otherwise the compiled object and the diagnostics (only
-- warnings, possibly none). It never raises.
--
-- The compiled object contains only numbers, strings, booleans and tables
-- of them, without metatables, cycles or tables referenced twice, and is
-- the same on every runtime for the same grammar:
--
--   lexogram  the specification revision in effect for the grammar (an
--             entry of the revision history, not the grammar's own string)
--   kinds     array indexed by kind id of { name, category, skip }:
--               1 = { name = 'INVALID', category = 'error' }: a byte that
--                   matches no token
--               2 = { name = 'ERROR', category = 'error' }: an error span
--               then pattern tokens (by name), symbols and keywords (by
--               index) and delimited tokens (by name). category is
--               'token' (also for delimited tokens), 'symbol', 'keyword'
--               or 'error'; skip is true for tokens listed in skip.
--   names     map from token names and the reserved names to kind ids
--   literals  map from literal strings (as declared) to kind ids
--   lexer     the token automaton:
--     nclasses, classes  classes[b + 1] is the class (1..nclasses) of byte b
--     nstates, trans     trans[(s - 1) * nclasses + c] is the state after
--                        state s and a byte of class c; 0 is the dead state
--                        (no transition). The start state is 1.
--     accept             accept[s] is the kind id accepted in state s, or 0
--     open               an automaton of the same shape over the opens of
--                        the delimited tokens; accept holds their kind ids
--     delimited          dense array of { id, prefix, capture, close }
--                        sorted by kind id, one per delimited token:
--                          prefix   fixed byte length before the capture
--                                   (absent without a capture)
--                          capture  automaton of the capture definition
--                                   (same shape, absent without a capture)
--                          close    array of parts { literal = <string> }
--                                   or { capture = true }
--
-- Tokenizing: at a position, if the open automaton accepts a non-empty
-- prefix, the delimited token with the longest open wins. After its open
-- matched at pos, the capture starts at pos + prefix and ends where the
-- capture automaton, run greedily from there, has no transition. The close
-- string is the concatenation of the close parts with the captured bytes
-- substituted, and the body ends at the first occurrence of the close
-- string after the open (without one, the token runs to the end of the
-- input). Otherwise the longest prefix accepted by lexer wins, with the
-- kind accept[s] of its final state; a byte that starts no token is
-- INVALID.
local type = type
local next = next
local rawget = rawget
local ipairs = ipairs
local check = require('lexogram.check').check
local resolve_version = require('lexogram.version').resolve
local build_lexer = require('lexogram.compile.lexer').build

-- Category of each definition kind of lexogram.compile.lexer.
local CATEGORY = {
    reserved = 'error',
    token = 'token',
    delimited = 'token',
    symbol = 'symbol',
    keyword = 'keyword',
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
    return {
        nclasses = d.nclasses,
        classes = copy_array(d.classes),
        nstates = d.nstates,
        trans = copy_array(d.trans),
        accept = copy_array(d.accept),
    }
end

--- delimited_entries returns the compiled delimited tokens sorted by id.
--- @param defs table[]
--- @param tokens table id -> { prefix, capture, close }
--- @return table[]
local function delimited_entries(defs, tokens)
    local out = {}
    for _, def in ipairs(defs) do
        local token = tokens[def.id]
        if token then
            local close = {}
            for i, part in ipairs(token.close) do
                close[i] = {
                    literal = part.literal,
                    capture = part.capture,
                }
            end
            out[#out + 1] = {
                id = def.id,
                prefix = token.prefix,
                capture = token.capture and automaton(token.capture),
                close = close,
            }
        end
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
--- @param result table result of lexogram.compile.lexer.build
--- @return table
local function build_object(grammar, result)
    local skipped = skipped_names(grammar)
    local kinds, names, literals = {}, {}, {}
    for _, def in ipairs(result.defs) do
        local category = CATEGORY[def.kind]
        kinds[def.id] = {
            name = def.name,
            category = category,
            skip = skipped[def.name] == true and category == 'token',
        }
        if category == 'symbol' or category == 'keyword' then
            literals[def.name] = def.id
        else
            names[def.name] = def.id
        end
    end
    local lexer = automaton(result.dfa)
    lexer.open = automaton(result.delimited.open)
    lexer.delimited = delimited_entries(result.defs, result.delimited.tokens)
    return {
        lexogram = resolve_version(rawget(grammar, 'lexogram')),
        kinds = kinds,
        names = names,
        literals = literals,
        lexer = lexer,
    }
end

--- compile compiles grammar. It returns nil and the diagnostics of
--- lexogram.check when there is an error, otherwise the compiled object
--- and the diagnostics (warnings only). It never raises.
--- @param grammar any
--- @return table? compiled
--- @return table[] diagnostics
local function compile(grammar)
    local diagnostics = check(grammar)
    for _, d in ipairs(diagnostics) do
        if d.severity == 'error' then
            return nil, diagnostics
        end
    end
    return build_object(grammar, (build_lexer(grammar))), diagnostics
end

return {
    compile = compile,
}
