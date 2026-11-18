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
--
-- lexogram.analyzer: runs the instructions of a compiled grammar (see
-- lexogram.compile.codegen) over a source and returns the event array.
-- The machine keeps its own call stack and backtrack stack in integer
-- arrays, so deep nesting in the source does not use the Lua call stack.
--
-- Tokens come from lexogram.tokenizer. Skipped tokens are kept pending and
-- written just before the next TOKEN or ENTER, so they follow the EXITs
-- after the previous valid token and precede the ENTERs before the next
-- one. Lookahead keeps raw tokens (skipped ones included) in a queue and
-- looks at most two valid tokens ahead.
--
-- Events are four integers each (op, kind, third, fourth):
--   TOKEN (1)  kind, start, stop (stop is the first position after it)
--   ENTER (2)  kind, start, number of the matching EXIT event
--   EXIT  (3)  kind, stop, number of the matching ENTER event
-- An empty rule starts and stops at the start of the next valid token, and
-- the EXIT of a rule stops at its last valid token or at the stop of an
-- empty rule inside it, whichever is later, so that ranges always nest.
--
-- A backtrack point (TRY) saves the event count, the start of the first
-- raw token not yet written, the call stack depth and the last valid
-- token; rewinding drops the events after it, empties the lookahead and
-- tokenizes again from the saved position.
--
-- Error recovery is not implemented yet: the first syntax error, or a
-- delimited token that is unterminated or has a nested open forbidden by
-- its nest setting, stops the analysis with nil and an error
-- { code, pos, line, column, expected, actual, message } (column in bytes,
-- see lexogram.events).
local type = type
local error = error
local next = next
local ipairs = ipairs
local sort = table.sort
local concat = table.concat
local tokenizer = require('lexogram.tokenizer')
local tokenize = tokenizer.tokenize
local new_input = tokenizer.input
local quote = require('lexogram.text').quote
local codegen = require('lexogram.compile.codegen')
local events_module = require('lexogram.events')

local MATCH = codegen.MATCH
local CALL = codegen.CALL
local TAILCALL = codegen.TAILCALL
local RET = codegen.RET
local JUMP = codegen.JUMP
local SWITCH = codegen.SWITCH
local TEST = codegen.TEST
local TRY = codegen.TRY
-- codegen.COMMIT is the only other opcode; it is the last branch of the
-- dispatch below.

-- Event opcodes.
local TOKEN_EVENT = events_module.TOKEN
local ENTER_EVENT = events_module.ENTER
local EXIT_EVENT = events_module.EXIT
local line_starts = events_module.line_starts
local locate = events_module.locate

-- Kind of the end of input in lookahead and decision tables.
local END = 0

--- kind_label returns a printable name of a kind for messages.
--- @param kinds table compiled.kinds
--- @param k integer
--- @return string
local function kind_label(kinds, k)
    if k == END then
        return 'end of input'
    end
    local kind = kinds[k]
    if kind.category == 'symbol' or kind.category == 'keyword' then
        return quote(kind.name)
    end
    return kind.name
end

--- expected_kinds returns the sorted kinds collected as expected: each
--- source is a kind or a decision table whose keys are kinds.
--- @param sources table
--- @param n integer number of sources
--- @return integer[]
local function expected_kinds(sources, n)
    local set = {}
    for i = 1, n do
        local src = sources[i]
        if type(src) == 'table' then
            for k in next, src do
                set[k] = true
            end
        else
            set[src] = true
        end
    end
    local list = {}
    for k in next, set do
        list[#list + 1] = k
    end
    sort(list)
    return list
end

--- syntax_error returns the error of an unexpected token.
--- @param kinds table
--- @param pos integer start of the unexpected token
--- @param actual integer its kind (0 at the end of input)
--- @param expected integer[]
--- @return table
local function syntax_error(kinds, pos, actual, expected)
    local labels = {}
    for i, k in ipairs(expected) do
        labels[i] = kind_label(kinds, k)
    end
    return {
        code = 'syntax_error',
        pos = pos,
        actual = actual,
        expected = expected,
        message = 'unexpected ' .. kind_label(kinds, actual) .. ', expected ' ..
            concat(labels, ', '),
    }
end

--- with_position adds the line and the byte column of err.pos to err.
--- @param err table
--- @param source string
--- @return table err
local function with_position(err, source)
    local line, start = locate(line_starts(source), err.pos)
    err.line, err.column = line, err.pos - start + 1
    return err
end

--- skip_set returns the kinds of the skipped tokens.
--- @param kinds table
--- @return table
local function skip_set(kinds)
    local set = {}
    for k, kind in ipairs(kinds) do
        if kind.skip then
            set[k] = true
        end
    end
    return set
end

--- parse analyzes source with the compiled grammar.
--- @param compiled table result of lexogram.compile
--- @param source string
--- @return table? result { source, events, count, errors, grammar }
--- @return table? err { code, pos, line, column, expected, actual, message }
local function parse(compiled, source)
    if type(compiled) ~= 'table' then
        error('compiled must be table, got ' .. type(compiled), 2)
    elseif type(source) ~= 'string' then
        error('source must be string, got ' .. type(source), 2)
    end

    local kinds = compiled.kinds
    local syntax = compiled.syntax
    local code, decisions, rules = syntax.code, syntax.decisions, syntax.rules
    local skipped = skip_set(kinds)
    local len = #source

    -- events
    local events = {}
    local count = 0
    local last_stop = 1 -- stop of the last valid token written
    local last_token = 0 -- event number of the last valid token written

    -- raw token queue (qh..qt) and the position to tokenize next
    local qk, qs, qe = {}, {}, {}
    local qh, qt = 1, 0
    local raw_pos = 1
    -- the source with the values of its lookaheads (see lexogram.tokenizer)
    local input = new_input(source)
    local failure -- error of a delimited token

    -- frames: return address, rule kind, ENTER event number, start, and
    -- the largest stop of the rules that ended inside it
    local fret, fkind, fenter, fstart, fmax = {}, {}, {}, {}, {}
    local depth = 0

    -- backtrack points
    local tevents, traw, tdepth, tresume, tstop, ttoken = {}, {}, {}, {}, {}, {}
    local tmax = {}
    local ntry = 0

    -- expected kinds since the last consumed token
    local exp = {}
    local nexp = 0

    --- read appends the next raw token to the queue; false at the end of
    --- input or after an erroneous delimited token.
    local function read()
        if raw_pos > len or failure then
            return false
        end
        local k, stop, problem, at = tokenize(compiled, input, raw_pos)
        qt = qt + 1
        qk[qt], qs[qt], qe[qt] = k, raw_pos, stop
        if problem == 'unterminated' then
            failure = {
                code = 'unterminated_token',
                pos = raw_pos,
                actual = k,
                expected = {},
                message = 'unterminated ' .. kind_label(kinds, k),
            }
        elseif problem then
            failure = {
                code = 'nested_delimiter',
                pos = at,
                actual = k,
                expected = {},
                message = 'nested delimiter in ' .. kind_label(kinds, k),
            }
        end
        raw_pos = stop
        return true
    end

    --- peek returns the kind and queue index of the n-th valid token
    --- ahead (kind 0 and nil at the end of input).
    local function peek(n)
        local i = qh
        while true do
            if i > qt and not read() then
                return END, nil
            end
            local k = qk[i]
            if not skipped[k] then
                n = n - 1
                if n == 0 then
                    return k, i
                end
            end
            i = i + 1
        end
    end

    --- emit appends an event and returns its number.
    local function emit(op, kind, third, fourth)
        local at = count * 4
        events[at + 1], events[at + 2], events[at + 3], events[at + 4] = op,
                                                                         kind,
                                                                         third,
                                                                         fourth
        count = count + 1
        return count
    end

    --- flush writes the queued tokens before queue index upto (exclusive),
    --- which are all skipped tokens.
    local function flush(upto)
        for i = qh, upto - 1 do
            emit(TOKEN_EVENT, qk[i], qs[i], qe[i])
        end
        qh = upto
    end

    --- enter sets up the frame at depth for rule r, writing its ENTER.
    local function enter(r)
        local rule = rules[r]
        local kind = rule.kind
        fkind[depth] = kind
        if kind ~= 0 then
            local _, i = peek(1)
            local start = len + 1
            if i then
                flush(i)
                start = qs[i]
            else
                flush(qt + 1)
            end
            fstart[depth] = start
            fenter[depth] = emit(ENTER_EVENT, kind, start, 0)
        end
        return rule.entry
    end

    --- leave writes the EXIT of the frame at depth, if it has a kind, and
    --- passes the stop of what ended inside it on to the caller's frame.
    local function leave()
        local kind = fkind[depth]
        local stop = fmax[depth]
        if kind ~= 0 then
            local entered = fenter[depth]
            local own = fstart[depth]
            if last_token > entered then
                own = last_stop
            end
            if own > stop then
                stop = own
            end
            local exited = emit(EXIT_EVENT, kind, stop, entered)
            events[(entered - 1) * 4 + 4] = exited
        end
        if depth > 1 and stop > fmax[depth - 1] then
            fmax[depth - 1] = stop
        end
    end

    --- expect records a source of expected kinds.
    local function expect(src)
        nexp = nexp + 1
        exp[nexp] = src
    end

    --- fail rewinds to the innermost backtrack point and returns its resume
    --- address, or returns nil when there is none.
    local function fail()
        if ntry == 0 then
            return nil
        end
        count = tevents[ntry]
        raw_pos = traw[ntry]
        depth = tdepth[ntry]
        fmax[depth] = tmax[ntry]
        last_stop, last_token = tstop[ntry], ttoken[ntry]
        local resume = tresume[ntry]
        ntry = ntry - 1
        qh, qt = 1, 0
        failure = nil
        nexp = 0
        return resume
    end

    depth = 1
    fret[1], fmax[1] = 0, 0
    local pc = enter(syntax.start)
    local err
    while true do
        local op = code[pc]
        if op == MATCH then
            local k = code[pc + 1]
            local t, i = peek(1)
            if t == k and i then
                flush(i)
                emit(TOKEN_EVENT, t, qs[i], qe[i])
                last_stop, last_token = qe[i], count
                qh = i + 1
                if qh > qt then
                    -- reuse the queue arrays from the start
                    qh, qt = 1, 0
                end
                nexp = 0
                pc = pc + 2
            else
                expect(k)
                pc = fail()
            end
        elseif op == TEST then
            local d = decisions[code[pc + 1]]
            local t = peek(1)
            local take = d.enter[t]
            local second = d.second[t]
            if take and second then
                take = second[(peek(2))]
            end
            if take then
                pc = pc + 3
            else
                expect(d.enter)
                pc = code[pc + 2]
            end
        elseif op == SWITCH then
            local d = decisions[code[pc + 1]]
            local t = peek(1)
            local second = d.second[t]
            local to
            if second then
                to = second[(peek(2))]
            else
                to = d.first[t]
            end
            if to then
                pc = to
            else
                expect(d.first)
                expect(d.second)
                pc = fail()
            end
        elseif op == CALL then
            depth = depth + 1
            fret[depth], fmax[depth] = pc + 2, 0
            pc = enter(code[pc + 1])
        elseif op == TAILCALL then
            pc = enter(code[pc + 1])
        elseif op == RET then
            leave()
            pc = fret[depth]
            depth = depth - 1
            if pc == 0 then
                -- the start rule returned: the input must end here
                if peek(1) == END then
                    flush(qt + 1)
                    break
                end
                expect(END)
                pc = fail()
            end
        elseif op == JUMP then
            pc = code[pc + 1]
        elseif op == TRY then
            local d = decisions[code[pc + 1]]
            if d.first[(peek(1))] then
                ntry = ntry + 1
                tevents[ntry] = count
                traw[ntry] = qh <= qt and qs[qh] or raw_pos
                tdepth[ntry] = depth
                tresume[ntry] = code[pc + 2]
                tstop[ntry], ttoken[ntry] = last_stop, last_token
                tmax[ntry] = fmax[depth]
                pc = pc + 3
            else
                expect(d.first)
                pc = code[pc + 2]
            end
        else -- COMMIT
            ntry = ntry - 1
            pc = pc + 1
        end
        -- an erroneous delimited token stops the analysis wherever it was
        -- read
        if failure then
            err = failure
            break
        end
        if not pc then
            local t, i = peek(1)
            err = syntax_error(kinds, i and qs[i] or len + 1, t,
                               expected_kinds(exp, nexp))
            break
        end
    end

    if err then
        return nil, with_position(err, source)
    end
    -- drop events left over from rewinds
    for i = #events, count * 4 + 1, -1 do
        events[i] = nil
    end
    return {
        source = source,
        events = events,
        count = count,
        errors = {},
        grammar = compiled,
    }
end

return {
    TOKEN = TOKEN_EVENT,
    ENTER = ENTER_EVENT,
    EXIT = EXIT_EVENT,
    parse = parse,
}
