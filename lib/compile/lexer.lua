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
-- lexogram.compile.lexer: builds the token automaton of a grammar (pattern
-- tokens and the literals of symbols and keywords) and reports the lexical
-- diagnostics: fragment recursion, automata that are too large, tokens
-- matching the empty string, conflicts between pattern tokens or between
-- literals, and pattern tokens that never win. Delimited token tables are
-- checked and compiled with lexogram.compile.delimited. A pattern token
-- written as an array of patterns (stages) is in the automaton by its first
-- pattern; each later one is an automaton of its own (a check), which the
-- whole text of the token must match. A fragment written as an array
-- matches the strings that all its patterns match: the token automaton
-- reads it by its first pattern, and a token that refers to one has a
-- check of its first pattern, in which the fragment is the intersection of
-- its patterns and the lookaheads match nothing (they were evaluated when
-- the token was chosen). A pattern token that a prefix match of the rules
-- names ("#name") also has an automaton of its own, which finds the part of
-- a longer token that it matches. The grammar must have passed the
-- structure, names and patterns passes of lexogram.check without errors;
-- in particular every fragment is a pattern string (the names pass rejects
-- a table named like a fragment), so every reference can be expanded.
local type = type
local next = next
local rawget = rawget
local ipairs = ipairs
local byte = string.byte
local concat = table.concat
local sort = table.sort
local byte_less = require('lexogram.compat').byte_less
local parse = require('lexogram.pattern').parse
local quote = require('lexogram.text').quote
local nfa = require('lexogram.compile.nfa')
local dfa = require('lexogram.compile.dfa')
local delimited = require('lexogram.compile.delimited')
local lookahead = require('lexogram.compile.lookahead')
local get_limit = require('lexogram.compile.limits').get

-- Byte value of "_", which starts a fragment name.
local UNDERSCORE = 95
-- Ranks for dfa.build: a literal wins over a pattern token on equal length.
local LITERAL_RANK = 1
local TOKEN_RANK = 2

--- pair returns the array { a, b }.
--- @param a any
--- @param b any
--- @return table
local function pair(a, b)
    local t = {}
    t[1], t[2] = a, b
    return t
end

--- add_error appends an error diagnostic.
--- @param diagnostics table[]
--- @param code string
--- @param segments any[]
--- @param message string
local function add_error(diagnostics, code, segments, message)
    diagnostics[#diagnostics + 1] = {
        severity = 'error',
        code = code,
        segments = segments,
        message = message,
    }
end

--- label returns the path string of a definition for messages.
--- @param def table
--- @return string
local function label(def)
    local segs = def.segments
    if segs[1] == 'tokens' then
        return 'tokens.' .. segs[2]
    elseif segs[2] == 'contextual' then
        return 'keywords.contextual[' .. segs[3] .. ']'
    end
    return segs[1] .. '[' .. segs[2] .. ']'
end

-- Keys of a delimited token table (with open and close, or prefixed).
local DELIMITED_KEYS = {
    'open',
    'close',
    'nest',
    'prefix',
    'match',
}

--- is_staged returns true if the value v of a token is an array of
--- patterns (stages): a table with an item and none of the keys of a
--- delimited token table, which is checked as such otherwise.
--- @param v any
--- @return boolean
local function is_staged(v)
    if type(v) ~= 'table' or rawget(v, 1) == nil then
        return false
    end
    for _, key in ipairs(DELIMITED_KEYS) do
        if rawget(v, key) ~= nil then
            return false
        end
    end
    return true
end

--- collect_tokens returns the sorted names of the pattern tokens, the
--- parsed fragments (by their first pattern), the sorted names of the
--- delimited token tables and the parsed patterns of the fragments written
--- as arrays.
--- @param tokens table
--- @return string[] names
--- @return table fragments name -> AST
--- @return string[] tables
--- @return table staged name -> ASTs
local function collect_tokens(tokens)
    local names, fragments, tables, staged = {}, {}, {}, {}
    for k, v in next, tokens do
        if byte(k, 1) == UNDERSCORE and is_staged(v) then
            local list = {}
            local i = 1
            while rawget(v, i) ~= nil do
                list[i] = parse(rawget(v, i), 'tokens')
                i = i + 1
            end
            fragments[k] = list[1]
            staged[k] = list
        elseif is_staged(v) then
            names[#names + 1] = k
        elseif type(v) == 'table' then
            tables[#tables + 1] = k
        elseif byte(k, 1) == UNDERSCORE then
            fragments[k] = parse(v, 'tokens')
        else
            names[#names + 1] = k
        end
    end
    sort(names, byte_less)
    sort(tables, byte_less)
    return names, fragments, tables, staged
end

-- Reserved kinds that precede every definition: 1 is a byte that matches
-- no token, 2 is an error span (used by the parser).
local RESERVED = {
    'INVALID',
    'ERROR',
}

--- leading_names returns the set of names listed in leading.
--- @param grammar table
--- @return table
local function leading_names(grammar)
    local set = {}
    local list = rawget(grammar, 'leading')
    if list then
        local i = 1
        local v = rawget(list, i)
        while v ~= nil do
            set[v] = true
            i = i + 1
            v = rawget(list, i)
        end
    end
    return set
end

--- collect_definitions returns the definitions of the grammar (the
--- reserved kinds INVALID and ERROR as ids 1 and 2, then pattern tokens
--- sorted by name, symbols and keywords in index order, and delimited
--- tokens sorted by name), the nfa definitions of the pattern tokens and
--- literals, those of the leading tokens (pattern tokens listed in leading,
--- which are tried at the start of input only), the ranks and the
--- fragments. A leading token has leading = true in its definition, and a
--- token written as an array of patterns has checks, the ASTs of its
--- patterns after the first. The last result has the patterns of the
--- fragments written as arrays.
--- @param grammar table
--- @return table[] defs
--- @return table[] nfa_defs
--- @return table[] leading_defs
--- @return table rank
--- @return table fragments
--- @return table staged
local function collect_definitions(grammar)
    local tokens = rawget(grammar, 'tokens')
    local names, fragments, tables, staged = collect_tokens(tokens)
    local leading = leading_names(grammar)
    local defs, nfa_defs, leading_defs, rank = {}, {}, {}, {}
    for i, name in ipairs(RESERVED) do
        defs[i] = {
            id = i,
            kind = 'reserved',
            name = name,
        }
    end
    for _, name in ipairs(names) do
        local id = #defs + 1
        local v = rawget(tokens, name)
        local first, checks = v, nil
        if is_staged(v) then
            first = rawget(v, 1)
            checks = {}
            local i = 2
            while rawget(v, i) ~= nil do
                checks[i - 1] = parse(rawget(v, i), 'tokens')
                i = i + 1
            end
            -- an array of one pattern is that pattern
            if i == 2 then
                checks = nil
            end
        end
        local ast = parse(first, 'tokens')
        defs[id] = {
            id = id,
            kind = 'token',
            name = name,
            segments = pair('tokens', name),
            leading = leading[name] or nil,
            checks = checks,
        }
        local list = leading[name] and leading_defs or nfa_defs
        list[#list + 1] = {
            id = id,
            ast = ast,
        }
        rank[id] = TOKEN_RANK
    end
    for _, field in ipairs({
        'symbols',
        'keywords',
    }) do
        local tbl = rawget(grammar, field)
        if tbl ~= nil then
            local ignore_case = rawget(tbl, 'ignore_case') == true
            local i = 1
            local v = rawget(tbl, i)
            while v ~= nil do
                local id = #defs + 1
                defs[id] = {
                    id = id,
                    kind = field == 'symbols' and 'symbol' or 'keyword',
                    name = v,
                    segments = {
                        field,
                        i,
                    },
                }
                nfa_defs[#nfa_defs + 1] = {
                    id = id,
                    literal = v,
                    ignore_case = ignore_case,
                }
                rank[id] = LITERAL_RANK
                i = i + 1
                v = rawget(tbl, i)
            end
            -- contextual keywords are not in the automaton: a contextual
            -- keyword is read as the pattern token it matches (base)
            local contextual = field == 'keywords' and rawget(tbl, 'contextual')
            if contextual then
                i = 1
                v = rawget(contextual, i)
                while v ~= nil do
                    local id = #defs + 1
                    defs[id] = {
                        id = id,
                        kind = 'contextual',
                        name = v,
                        ignore_case = ignore_case,
                        segments = {
                            'keywords',
                            'contextual',
                            i,
                        },
                    }
                    i = i + 1
                    v = rawget(contextual, i)
                end
            end
        end
    end
    for _, name in ipairs(tables) do
        local id = #defs + 1
        defs[id] = {
            id = id,
            kind = 'delimited',
            name = name,
            segments = pair('tokens', name),
        }
    end
    return defs, nfa_defs, leading_defs, rank, fragments, staged
end

--- check_recursion adds fragment_recursion for each cycle of fragment
--- references and returns true if there is any.
--- @param diagnostics table[]
--- @param fragments table
--- @param staged table
--- @return boolean
local function check_recursion(diagnostics, fragments, staged)
    -- a fragment written as an array refers to the names of all its
    -- patterns
    local all = {}
    for name, ast in next, fragments do
        all[name] = staged[name] and {
            type = 'choice',
            items = staged[name],
        } or ast
    end
    local cycles = nfa.find_cycles(all)
    for _, cycle in ipairs(cycles) do
        add_error(diagnostics, 'fragment_recursion', pair('tokens', cycle[1]),
                  'fragment ' .. cycle[1] .. ' is recursive: ' ..
                      concat(cycle, ' -> ') .. ' -> ' .. cycle[1])
    end
    return #cycles > 0
end

--- check_conflicts adds empty_match, token_conflict and literal_conflict
--- errors. For an automaton with lookaheads (dispatch states), only the
--- states that an input can reach with consistent predicates are checked
--- (see lexogram.compile.lookahead.reachable); it returns an
--- automaton_too_large error when that analysis exceeds its limit.
--- @param diagnostics table[]
--- @param defs table[]
--- @param d table
--- @param predicates table[]? result of lexogram.compile.lookahead.build
--- @param max integer largest number of configurations of the analysis
--- @return table? err
local function check_conflicts(diagnostics, defs, d, predicates, max)
    local example, states
    if d.dispatch then
        local found, err = lookahead.reachable(d, predicates, max)
        if not found then
            return err
        end
        example = function(s)
            return found[s]
        end
        states = {}
        for s in next, found do
            states[#states + 1] = s
        end
        sort(states, function(a, b)
            if #found[a] ~= #found[b] then
                return #found[a] < #found[b]
            end
            return a < b
        end)
    else
        example = delimited.examples(d)
        states = {}
        for s = 1, d.nstates do
            states[s] = s
        end
    end

    local empty = {}
    for _, s in ipairs(states) do
        if example(s) == '' then
            for _, id in ipairs(d.accept_sets[s]) do
                local def = defs[id]
                if def.kind == 'token' and not empty[id] then
                    empty[id] = true
                    add_error(diagnostics, 'empty_match', def.segments,
                              label(def) .. ' matches the empty string')
                end
            end
        end
    end

    local seen = {}
    -- a state reached without input gives an empty example; empty_match
    -- covers it
    for _, s in ipairs(states) do
        local ids = example(s) == '' and {} or d.accept_sets[s]
        for i = 1, #ids do
            local a = defs[ids[i]]
            for j = i + 1, #ids do
                local b = defs[ids[j]]
                local same_kind = (a.kind == 'token') == (b.kind == 'token')
                local key = a.id .. ',' .. b.id
                if same_kind and not seen[key] then
                    seen[key] = true
                    local code = a.kind == 'token' and 'token_conflict' or
                                     'literal_conflict'
                    -- ids are sorted, so b is the later definition
                    add_error(diagnostics, code, b.segments,
                              label(b) .. ' can match the same string as ' ..
                                  label(a) .. ', e.g. ' .. quote(example(s)))
                end
            end
        end
    end
end

--- winners returns the ids that win in the states of d where the whole
--- string text can end, taking every target of a dispatch state (whatever
--- its predicates give); it may thus include ids that no context gives.
--- @param d table
--- @param text string
--- @return table id -> true
local function winners(d, text)
    local nclasses, classes, trans = d.nclasses, d.classes, d.trans
    local dispatch = d.dispatch or {}
    local function expand(list)
        local out, seen = {}, {}
        for _, s in ipairs(list) do
            local entry = dispatch[s]
            for _, t in ipairs(entry and entry.targets or {
                s,
            }) do
                if t ~= 0 and not seen[t] then
                    seen[t] = true
                    out[#out + 1] = t
                end
            end
        end
        return out
    end
    local list = expand({
        1,
    })
    for i = 1, #text do
        local c = classes[byte(text, i) + 1]
        local nxt = {}
        for _, s in ipairs(list) do
            nxt[#nxt + 1] = trans[(s - 1) * nclasses + c]
        end
        list = expand(nxt)
    end
    local ids = {}
    for _, s in ipairs(list) do
        local id = d.accept[s]
        if id > 0 then
            ids[id] = true
        end
    end
    return ids
end

--- resolve_contextual sets the base of each contextual keyword definition:
--- the pattern token that the tokenizer reads its text as (in some context
--- of its lookaheads), which must be exactly one and not be listed in skip
--- (it never reaches the parser); otherwise it adds invalid_contextual.
--- @param diagnostics table[]
--- @param defs table[]
--- @param d table automaton of the pattern tokens and literals
--- @param skip any the skip field of the grammar
local function resolve_contextual(diagnostics, defs, d, skip)
    local skipped
    for _, def in ipairs(defs) do
        if def.kind == 'contextual' then
            if not skipped then
                -- raw reads: the grammar may have metatables
                skipped = {}
                local i = 1
                local name = type(skip) == 'table' and rawget(skip, i)
                while name do
                    skipped[name] = true
                    i = i + 1
                    name = rawget(skip, i)
                end
            end
            local names, base = {}, nil
            for id in next, winners(d, def.name) do
                names[#names + 1] = label(defs[id])
                base = defs[id].kind == 'token' and id or nil
            end
            sort(names, byte_less)
            if base and #names == 1 and skipped[defs[base].name] then
                add_error(diagnostics, 'invalid_contextual', def.segments,
                          label(def) .. ' is read as ' .. names[1] ..
                              ', which is listed in skip and never reaches' ..
                              ' the parser')
            elseif #names == 1 and base then
                def.base = base
            else
                add_error(diagnostics, 'invalid_contextual', def.segments,
                          label(def) .. ' must be read as exactly one' ..
                              ' pattern token, which it stands for; it is' ..
                              ' read as ' ..
                              (#names == 0 and 'none' or concat(names, ' or ')))
            end
        end
    end
end

--- check_adoption warns about pattern tokens that win in no state of d.
--- Leading tokens are not in d; their automaton has no literal, so one that
--- never wins conflicts with another leading token, which is an error.
--- @param diagnostics table[]
--- @param defs table[]
--- @param d table
local function check_adoption(diagnostics, defs, d)
    local won = {}
    for s = 1, d.nstates do
        won[d.accept[s]] = true
    end
    for _, def in ipairs(defs) do
        if def.kind == 'token' and not def.leading and not won[def.id] then
            diagnostics[#diagnostics + 1] = {
                severity = 'warning',
                code = 'never_adopted',
                segments = def.segments,
                message = label(def) .. ' is never adopted: it is always' ..
                    ' shadowed by a literal or a longer match',
            }
        end
    end
end

--- too_large converts an automaton_too_large error into a diagnostic.
--- @param diagnostics table[]
--- @param err table
--- @return nil
local function too_large(diagnostics, err)
    add_error(diagnostics, err.code, {
        'tokens',
    }, err.message)
    return nil, diagnostics
end

--- matches_nonempty returns true if the automaton d accepts in a state
--- reached after at least one byte. The predicates of its dispatch states
--- are not evaluated: every target counts.
--- @param d table
--- @return boolean
local function matches_nonempty(d)
    local nclasses, trans, accept = d.nclasses, d.trans, d.accept
    local dispatch = d.dispatch or {}
    local seen, stack = {}, {}
    local function push(s)
        if s ~= 0 and not seen[s] then
            seen[s] = true
            stack[#stack + 1] = s
        end
    end
    local function targets(s)
        return dispatch[s] and dispatch[s].targets or {}
    end
    -- the states of the start position (through dispatch targets), then
    -- those after one byte
    local starts, queue, found = {}, {}, {}
    queue[1] = 1
    while #queue > 0 do
        local s = queue[#queue]
        queue[#queue] = nil
        if s ~= 0 and not found[s] then
            found[s] = true
            starts[#starts + 1] = s
            for _, t in ipairs(targets(s)) do
                queue[#queue + 1] = t
            end
        end
    end
    for _, s in ipairs(starts) do
        for c = 1, nclasses do
            push(trans[(s - 1) * nclasses + c])
        end
    end
    while #stack > 0 do
        local s = stack[#stack]
        stack[#stack] = nil
        if accept[s] ~= 0 then
            return true
        end
        for _, t in ipairs(targets(s)) do
            push(t)
        end
        for c = 1, nclasses do
            push(trans[(s - 1) * nclasses + c])
        end
    end
    return false
end

--- find_lookahead returns the position of the first lookahead in ast,
--- expanding the fragments it refers to except those written as arrays
--- (staged), and the name of the fragment through which it is reached, or
--- nil.
--- @param ast table
--- @param fragments table
--- @param staged table
--- @return integer? pos
--- @return string? through
local function find_lookahead(ast, fragments, staged)
    -- each item is { node, position of the reference, its name }
    local stack, seen = {}, {}
    stack[1] = {
        ast,
    }
    while #stack > 0 do
        local item = stack[#stack]
        stack[#stack] = nil
        local node = item[1]
        if node.type == 'lookahead' then
            return item[2] or node.pos, item[3]
        elseif not seen[node] then
            seen[node] = true
            local kids = node.items
            if not kids and node.item then
                kids = {
                    node.item,
                }
            elseif not kids and node.type == 'ref' and not staged[node.name] then
                kids = {
                    fragments[node.name],
                }
            end
            for i = #(kids or {}), 1, -1 do
                stack[#stack + 1] = {
                    kids[i],
                    item[2] or (node.type == 'ref' and node.pos) or nil,
                    item[3] or (node.type == 'ref' and node.name) or nil,
                }
            end
        end
    end
    return nil
end

--- check_staged_lookaheads adds lookahead_not_allowed for each pattern of a
--- fragment written as an array that has a lookahead (also through another
--- fragment), and returns true if there is any: the intersection of the
--- patterns would not tell where a lookahead holds.
--- @param diagnostics table[]
--- @param fragments table
--- @param staged table
--- @return boolean
local function check_staged_lookaheads(diagnostics, fragments, staged)
    local found = false
    for name, list in next, staged do
        for i, ast in ipairs(list) do
            local pos, through = find_lookahead(ast, fragments, staged)
            if pos then
                found = true
                diagnostics[#diagnostics + 1] = {
                    severity = 'error',
                    code = 'lookahead_not_allowed',
                    segments = {
                        'tokens',
                        name,
                        i,
                    },
                    pos = pos,
                    message = 'tokens.' .. name .. '[' .. i .. ']: a' ..
                        ' lookahead is not allowed in a fragment written as' ..
                        ' an array of patterns' ..
                        (through and ' (through ' .. through .. ')' or ''),
                }
            end
        end
    end
    return found
end

--- staged_refs returns the set of the fragments written as arrays that ast
--- refers to, directly or through other fragments.
--- @param ast table
--- @param fragments table
--- @param staged table
--- @return table name -> true
local function staged_refs(ast, fragments, staged)
    local found, seen = {}, {}
    local stack = {}
    stack[1] = ast
    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        if node.type == 'ref' then
            local name = node.name
            if staged[name] then
                found[name] = true
            elseif fragments[name] and not seen[name] then
                seen[name] = true
                stack[#stack + 1] = fragments[name]
            end
        elseif node.items then
            for i = #node.items, 1, -1 do
                stack[#stack + 1] = node.items[i]
            end
        elseif node.item then
            stack[#stack + 1] = node.item
        end
    end
    return found
end

--- build_exact returns the fragments with each fragment written as an
--- array replaced by an automaton node of the intersection of its
--- patterns, built in the order of their references (fragments are
--- acyclic). A fragment whose intersection accepts no non-empty string is
--- unmatchable_pattern. It returns nil and an automaton_too_large error
--- when an automaton exceeds its limit.
--- @param fragments table
--- @param staged table
--- @param limits table { nfa, dfa }
--- @param diagnostics table[]
--- @return table? exact name -> AST or automaton node
--- @return table? err
local function build_exact(fragments, staged, limits, diagnostics)
    local exact, pending, deps = {}, {}, {}
    for name, ast in next, fragments do
        exact[name] = ast
    end
    for name, list in next, staged do
        pending[#pending + 1] = name
        local set = {}
        for _, ast in ipairs(list) do
            for ref in next, staged_refs(ast, fragments, staged) do
                set[ref] = true
            end
        end
        deps[name] = set
    end
    sort(pending, byte_less)
    local done = {}
    while #pending > 0 do
        local rest = {}
        for _, name in ipairs(pending) do
            local ready = true
            for ref in next, deps[name] do
                if not done[ref] then
                    ready = false
                end
            end
            if ready then
                local list = {}
                for i, ast in ipairs(staged[name]) do
                    local machine, err = nfa.build({
                        {
                            id = 1,
                            ast = ast,
                        },
                    }, exact, limits.nfa, nil, true)
                    if not machine then
                        return nil, err
                    end
                    list[i], err = dfa.build(machine, {
                        1,
                    }, limits.dfa)
                    if not list[i] then
                        return nil, err
                    end
                end
                local d, err = dfa.intersect(list, limits.dfa)
                if not d then
                    return nil, err
                end
                if not matches_nonempty(d) then
                    add_error(diagnostics, 'unmatchable_pattern',
                              pair('tokens', name),
                              'tokens.' .. name ..
                                  ' matches no non-empty string: no string' ..
                                  ' matches all its patterns')
                end
                exact[name] = {
                    type = 'automaton',
                    automaton = d,
                }
                done[name] = true
            else
                rest[#rest + 1] = name
            end
        end
        pending = rest
    end
    return exact
end

--- marked returns the fragments with each fragment written as an array
--- replaced by a node of type 'staged', which a delimited token table must
--- not refer to (see lexogram.compile.delimited).
--- @param fragments table
--- @param staged table
--- @return table
local function marked(fragments, staged)
    local out = {}
    for name, ast in next, fragments do
        out[name] = staged[name] and {
            type = 'staged',
        } or ast
    end
    return out
end

--- build_checks builds the checks of the pattern tokens and returns them by
--- kind id ({ first = <automaton>?, <automaton>... }), or nil when there is
--- none: first is the check of the first pattern of a token that refers to
--- a fragment written as an array (with the intersections of exact, and
--- without its lookaheads), and the array has the patterns after the first
--- of a token written as an array. A later pattern that accepts no
--- non-empty string is unmatchable_pattern (the check of the first pattern
--- always accepts one: a pattern that matches only the empty string is
--- empty_match, and a fragment that matches none is reported by
--- build_exact). It returns nil and an automaton_too_large error when an
--- automaton exceeds its limit.
--- @param defs table[]
--- @param asts table kind id -> AST of the (first) pattern of each token
--- @param fragments table
--- @param exact table the fragments of build_exact
--- @param staged table
--- @param preds table predicates shared with the token automaton
--- @param limits table { nfa, dfa }
--- @param diagnostics table[]
--- @return table? checks kind id -> automata
--- @return table? err
local function build_checks(defs, asts, fragments, exact, staged, preds, limits,
                            diagnostics)
    local checks
    for _, def in ipairs(defs) do
        local first
        local pattern = def.kind == 'token' and asts[def.id]
        if pattern and next(staged_refs(pattern, fragments, staged)) then
            local machine, err = nfa.build({
                {
                    id = def.id,
                    ast = pattern,
                },
            }, exact, limits.nfa, nil, true)
            if not machine then
                return nil, err
            end
            first, err = dfa.build(machine, {
                [def.id] = TOKEN_RANK,
            }, limits.dfa)
            if not first then
                return nil, err
            end
        end
        if first or def.checks then
            local list = {
                first = first,
            }
            for i, ast in ipairs(def.checks or {}) do
                local machine, err = nfa.build({
                    {
                        id = def.id,
                        ast = ast,
                    },
                }, exact, limits.nfa, preds)
                if not machine then
                    return nil, err
                end
                local d
                d, err = dfa.build(machine, {
                    [def.id] = TOKEN_RANK,
                }, limits.dfa)
                if not d then
                    return nil, err
                end
                if not matches_nonempty(d) then
                    local index = i + 1
                    local segments = {
                        'tokens',
                        def.name,
                        index,
                    }
                    local message = label(def) .. '[' .. index .. ']' ..
                                        ' matches no non-empty string, so' ..
                                        ' every token of ' .. label(def) ..
                                        ' fails it'
                    add_error(diagnostics, 'unmatchable_pattern', segments,
                              message)
                end
                list[i] = d
            end
            checks = checks or {}
            checks[def.id] = list
        end
    end
    return checks
end

--- build_delimited checks and compiles the delimited token tables. It
--- returns { open, tokens, entries }, or nil and an automaton_too_large
--- error. tokens maps the kind id of each table with open and close to its
--- compiled token; entries lists, in the order of the indexes accepted by
--- open, { id, token, inner } for those tables and for each table named by
--- a prefixed table (id is the kind id, inner the index of the entry whose
--- open is a nested open).
--- @param grammar table
--- @param defs table[]
--- @param fragments table
--- @param diagnostics table[]
--- @param limits table { nfa, dfa }
--- @return table? delimited { open, tokens, entries }
--- @return table? err
local function build_delimited(grammar, defs, fragments, diagnostics, limits)
    local tokens = rawget(grammar, 'tokens')
    local by_name, compiled = {}, {}
    for _, def in ipairs(defs) do
        local tbl = def.kind == 'delimited' and rawget(tokens, def.name)
        if tbl and not delimited.is_prefixed(tbl) then
            local entry, err = delimited.analyze(def.name, tbl, fragments,
                                                 diagnostics, limits)
            if err then
                return nil, err
            elseif entry then
                by_name[def.name] = entry
                compiled[def.id] = entry.token
            end
        end
    end

    -- entries in kind id order; the entries of a prefixed table follow the
    -- order of its match
    local entries = {}
    for _, def in ipairs(defs) do
        local tbl = def.kind == 'delimited' and rawget(tokens, def.name)
        local list
        if not tbl then
            list = {}
        elseif delimited.is_prefixed(tbl) then
            list = delimited.analyze_prefixed(def.name, tbl, by_name, fragments,
                                              diagnostics)
        else
            list = {
                by_name[def.name],
            }
        end
        for _, entry in ipairs(list) do
            entry.id = def.id
            entries[#entries + 1] = entry
        end
    end
    local open, err = delimited.build_open(entries, fragments, diagnostics,
                                           limits)
    if not open then
        return nil, err
    end

    local index, out = {}, {}
    for i, entry in ipairs(entries) do
        if entry.field == 'open' then
            index[entry.name] = i
        end
    end
    for i, entry in ipairs(entries) do
        out[i] = {
            id = entry.id,
            token = entry.token,
            inner = index[entry.inner],
        }
    end
    return {
        open = open,
        tokens = compiled,
        entries = out,
    }
end

--- build_prefixes returns the automata of the pattern tokens named in
--- prefixed, by kind id; their lookaheads are registered in preds.
--- @param prefixed table? token name -> true
--- @param defs table[]
--- @param lists table[] the definitions of the automata (nfa_defs and
--- leading_defs)
--- @param rank table
--- @param fragments table
--- @param preds table
--- @param limits table
--- @return table? automata kind id -> automaton (nil without any)
--- @return table? err
local function build_prefixes(prefixed, defs, lists, rank, fragments, preds,
                              limits)
    if not prefixed then
        return nil
    end
    local ids = {}
    for _, def in ipairs(defs) do
        if def.kind == 'token' and prefixed[def.name] then
            ids[def.id] = true
        end
    end
    local out
    for _, list in ipairs(lists) do
        for _, def in ipairs(list) do
            if ids[def.id] then
                local machine, err = nfa.build({
                    def,
                }, fragments, limits.nfa, preds)
                if not machine then
                    return nil, err
                end
                local d
                d, err = dfa.build(machine, rank, limits.dfa)
                if not d then
                    return nil, err
                end
                out = out or {}
                out[def.id] = d
            end
        end
    end
    return out
end

--- build builds the token automaton of grammar.
--- @param grammar table a grammar that passed the earlier checks
--- @param limits table? for tests only: { nfa_states, dfa_states }, the
--- largest number of states of every non-deterministic automaton (passed
--- to nfa.build) and of every deterministic automaton (passed to dfa.build)
--- built for the grammar; each defaults to the builder's MAX_STATES
--- @param prefixed table? the names of the tokens that prefix matches of
--- the rules name ("#name"): name -> true
--- @return table? result { defs, dfa, leading, delimited, predicates,
--- checks, prefixes }, nil when there is an error; leading is the automaton
--- of the leading tokens (nil without them), predicates the automata of the
--- predicates of the lookaheads (see lexogram.compile.lookahead; nil
--- without them), checks the automata of the checks by kind id (nil
--- without them), prefixes the automata of the pattern tokens named in
--- prefixed, by kind id (nil without them)
--- @return table[] diagnostics { severity, code, segments, pos, message }
local function build(grammar, limits, prefixed)
    -- read here, so that an invalid limit raises at the caller of build
    limits = {
        nfa = {
            max_states = get_limit(limits, 'nfa_states', nfa.MAX_STATES),
        },
        dfa = {
            max_states = get_limit(limits, 'dfa_states', dfa.MAX_STATES),
        },
    }
    local diagnostics = {}
    local defs, nfa_defs, leading_defs, rank, fragments, staged =
        collect_definitions(grammar)
    if check_recursion(diagnostics, fragments, staged) or
        check_staged_lookaheads(diagnostics, fragments, staged) then
        return nil, diagnostics
    end

    local preds = nfa.new_predicates()
    local machine, err = nfa.build(nfa_defs, fragments, limits.nfa, preds)
    if not machine then
        return too_large(diagnostics, err)
    end
    local d
    d, err = dfa.build(machine, rank, limits.dfa)
    if not d then
        return too_large(diagnostics, err)
    end

    local leading
    if #leading_defs > 0 then
        machine, err = nfa.build(leading_defs, fragments, limits.nfa, preds)
        if not machine then
            return too_large(diagnostics, err)
        end
        leading, err = dfa.build(machine, rank, limits.dfa)
        if not leading then
            return too_large(diagnostics, err)
        end
    end

    local compiled
    compiled, err = build_delimited(grammar, defs, marked(fragments, staged),
                                    diagnostics, limits)
    if not compiled then
        return too_large(diagnostics, err)
    end

    resolve_contextual(diagnostics, defs, d, rawget(grammar, 'skip'))

    -- the fragments with the intersections of those written as arrays,
    -- which the checks and the lookaheads match exactly
    local exact
    exact, err = build_exact(fragments, staged, limits, diagnostics)
    if not exact then
        return too_large(diagnostics, err)
    end

    -- before the predicates, which the checks may add to
    local asts = {}
    for _, list in ipairs({
        nfa_defs,
        leading_defs,
    }) do
        for _, def in ipairs(list) do
            asts[def.id] = def.ast
        end
    end
    local checks
    checks, err = build_checks(defs, asts, fragments, exact, staged, preds,
                               limits, diagnostics)
    if err then
        return too_large(diagnostics, err)
    end

    -- also before the predicates
    local prefixes
    prefixes, err = build_prefixes(prefixed, defs, {
        nfa_defs,
        leading_defs,
    }, rank, fragments, preds, limits)
    if err then
        return too_large(diagnostics, err)
    end

    local predicates
    if #preds.list > 0 then
        predicates, err = lookahead.build(preds, exact, limits)
        if not predicates then
            return too_large(diagnostics, err)
        end
    end

    local max = limits.dfa.max_states
    err = check_conflicts(diagnostics, defs, d, predicates, max)
    if err then
        return too_large(diagnostics, err)
    end
    -- leading tokens are checked among themselves only: at the start of
    -- input they win over every other token
    if leading then
        err = check_conflicts(diagnostics, defs, leading, predicates, max)
        if err then
            return too_large(diagnostics, err)
        end
    end
    if #diagnostics > 0 then
        return nil, diagnostics
    end
    check_adoption(diagnostics, defs, d)
    return {
        defs = defs,
        dfa = d,
        leading = leading,
        delimited = compiled,
        predicates = predicates,
        checks = checks,
        prefixes = prefixes,
    }, diagnostics
end

return {
    is_staged = is_staged,
    build = build,
}
