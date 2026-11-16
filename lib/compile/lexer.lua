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
-- checked and compiled with lexogram.compile.delimited. The grammar must
-- have passed the structure, names and
-- patterns passes of lexogram.check without errors; in particular every
-- fragment is a pattern string (the names pass rejects a delimited token
-- table named like a fragment), so every reference can be expanded.
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
    end
    return segs[1] .. '[' .. segs[2] .. ']'
end

--- collect_tokens returns the sorted names of the pattern tokens, the
--- parsed fragments and the sorted names of the delimited token tables.
--- @param tokens table
--- @return string[] names
--- @return table fragments name -> AST
--- @return string[] tables
local function collect_tokens(tokens)
    local names, fragments, tables = {}, {}, {}
    for k, v in next, tokens do
        if type(v) == 'table' then
            tables[#tables + 1] = k
        elseif byte(k, 1) == UNDERSCORE then
            fragments[k] = parse(v, 'tokens')
        else
            names[#names + 1] = k
        end
    end
    sort(names, byte_less)
    sort(tables, byte_less)
    return names, fragments, tables
end

-- Reserved kinds that precede every definition: 1 is a byte that matches
-- no token, 2 is an error span (used by the parser).
local RESERVED = {
    'INVALID',
    'ERROR',
}

--- collect_definitions returns the definitions of the grammar (the
--- reserved kinds INVALID and ERROR as ids 1 and 2, then pattern tokens
--- sorted by name, symbols and keywords in index order, and delimited
--- tokens sorted by name), the nfa definitions of the pattern
--- tokens and literals, the ranks, the fragments and the ids of the
--- delimited tokens by name.
--- @param grammar table
--- @return table[] defs
--- @return table[] nfa_defs
--- @return table rank
--- @return table fragments
--- @return table delimited_ids name -> id
local function collect_definitions(grammar)
    local tokens = rawget(grammar, 'tokens')
    local names, fragments, tables = collect_tokens(tokens)
    local defs, nfa_defs, rank = {}, {}, {}
    for i, name in ipairs(RESERVED) do
        defs[i] = {
            id = i,
            kind = 'reserved',
            name = name,
        }
    end
    for _, name in ipairs(names) do
        local id = #defs + 1
        defs[id] = {
            id = id,
            kind = 'token',
            name = name,
            segments = pair('tokens', name),
        }
        nfa_defs[#nfa_defs + 1] = {
            id = id,
            ast = parse(rawget(tokens, name), 'tokens'),
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
        end
    end
    local delimited_ids = {}
    for _, name in ipairs(tables) do
        local id = #defs + 1
        defs[id] = {
            id = id,
            kind = 'delimited',
            name = name,
            segments = pair('tokens', name),
        }
        delimited_ids[name] = id
    end
    return defs, nfa_defs, rank, fragments, delimited_ids
end

--- check_recursion adds fragment_recursion for each cycle of fragment
--- references and returns true if there is any.
--- @param diagnostics table[]
--- @param fragments table
--- @return boolean
local function check_recursion(diagnostics, fragments)
    local cycles = nfa.find_cycles(fragments)
    for _, cycle in ipairs(cycles) do
        add_error(diagnostics, 'fragment_recursion', pair('tokens', cycle[1]),
                  'fragment ' .. cycle[1] .. ' is recursive: ' ..
                      concat(cycle, ' -> ') .. ' -> ' .. cycle[1])
    end
    return #cycles > 0
end

--- check_conflicts adds empty_match, token_conflict and literal_conflict
--- errors and returns true if there is any.
--- @param diagnostics table[]
--- @param defs table[]
--- @param d table
--- @return boolean
local function check_conflicts(diagnostics, defs, d)
    local before = #diagnostics
    for _, id in ipairs(d.accept_sets[1]) do
        local def = defs[id]
        if def.kind == 'token' then
            add_error(diagnostics, 'empty_match', def.segments,
                      label(def) .. ' matches the empty string')
        end
    end

    local example = delimited.examples(d)
    local seen = {}
    -- state 1 would give an empty example; empty_match covers it
    for s = 2, d.nstates do
        local ids = d.accept_sets[s]
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
    return #diagnostics > before
end

--- check_adoption warns about pattern tokens that win in no state.
--- @param diagnostics table[]
--- @param defs table[]
--- @param d table
local function check_adoption(diagnostics, defs, d)
    local won = {}
    for s = 1, d.nstates do
        won[d.accept[s]] = true
    end
    for _, def in ipairs(defs) do
        if def.kind == 'token' and not won[def.id] then
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

--- build_delimited checks and compiles the delimited token tables. It
--- returns { open, tokens }, or nil and an automaton_too_large error.
--- @param grammar table
--- @param defs table[]
--- @param ids table delimited token name -> id
--- @param fragments table
--- @param diagnostics table[]
--- @param limits table { nfa, dfa }
--- @return table? delimited { open, tokens }
--- @return table? err
local function build_delimited(grammar, defs, ids, fragments, diagnostics,
                               limits)
    local tokens = rawget(grammar, 'tokens')
    local entries, compiled = {}, {}
    for _, def in ipairs(defs) do
        if def.kind == 'delimited' then
            local entry, err = delimited.analyze(def.name,
                                                 rawget(tokens, def.name),
                                                 fragments, diagnostics, limits)
            if err then
                return nil, err
            elseif entry then
                entries[#entries + 1] = entry
                compiled[def.id] = entry.token
            end
        end
    end
    local open, err = delimited.build_open(entries, ids, fragments, diagnostics,
                                           limits)
    if not open then
        return nil, err
    end
    return {
        open = open,
        tokens = compiled,
    }
end

--- build builds the token automaton of grammar.
--- @param grammar table a grammar that passed the earlier checks
--- @param limits table? for tests only: { nfa_states, dfa_states }, the
--- largest number of states of every non-deterministic automaton (passed
--- to nfa.build) and of every deterministic automaton (passed to dfa.build)
--- built for the grammar; each defaults to the builder's MAX_STATES
--- @return table? result { defs, dfa, delimited }, nil when there is an
--- error
--- @return table[] diagnostics { severity, code, segments, pos, message }
local function build(grammar, limits)
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
    local defs, nfa_defs, rank, fragments, ids = collect_definitions(grammar)
    if check_recursion(diagnostics, fragments) then
        return nil, diagnostics
    end

    local machine, err = nfa.build(nfa_defs, fragments, limits.nfa)
    if not machine then
        return too_large(diagnostics, err)
    end
    local d
    d, err = dfa.build(machine, rank, limits.dfa)
    if not d then
        return too_large(diagnostics, err)
    end

    local compiled
    compiled, err = build_delimited(grammar, defs, ids, fragments, diagnostics,
                                    limits)
    if not compiled then
        return too_large(diagnostics, err)
    end

    if check_conflicts(diagnostics, defs, d) or #diagnostics > 0 then
        return nil, diagnostics
    end
    check_adoption(diagnostics, defs, d)
    return {
        defs = defs,
        dfa = d,
        delimited = compiled,
    }, diagnostics
end

return {
    build = build,
}
