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
-- A contextual keyword is a token of its base kind with its text (see
-- lexogram.compile): such a token gets the kind of the keyword when it is
-- read, which the decisions have wherever the base kind can come (see
-- lexogram.compile.ll), and a MATCH of the base kind takes it too and
-- writes it with the base kind. Only tokens of a base kind are compared,
-- and only those of the length of a keyword read their text.
--
-- A prefix match (PREFIX) that splits the next token writes the part that
-- it takes and replaces the token in the queue by the token tokenized from
-- the rest. When that token does not end where the split one did, the
-- tokens read after the split one are dropped, and reading goes on from
-- its end. Under a backtrack point, a split keeps what it replaced, so
-- that a rewind puts the queue back as it was.
--
-- A backtrack point (TRY) saves the event count, the queue index of the
-- first raw token not yet written, the call stack depth and the last valid
-- token; rewinding drops the events after it and moves the head of the
-- queue back, so that the tokens read are read again from the queue
-- without tokenizing them again. While a backtrack point is kept the queue
-- is not emptied, so it holds the tokens read since the outermost one. A
-- token whose error stops the analysis is the last one read, and a rewind
-- drops it from the queue, so that it is read again, and its error
-- reported, only where the analysis reaches it again. Each failure is
-- noted before rewinding: a syntax error is reported at the furthest token
-- where a failure happened, in a trial or not, with the kinds expected by
-- all the failures there.
--
-- Error recovery is not implemented yet: the first syntax error, a
-- delimited token that is unterminated or has a nested open forbidden by
-- its nest setting, or a pattern token whose text fails a pattern after
-- the first of the array that defines it, stops the analysis with nil and
-- an error
-- { code, pos, line, column, expected, actual, message } (column in bytes,
-- see lexogram.events).
local type = type
local error = error
local next = next
local ipairs = ipairs
local sort = table.sort
local concat = table.concat
local sub = string.sub
local lower = string.lower
local tokenizer = require('lexogram.tokenizer')
local scanner = tokenizer.scanner
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
local PREFIX = codegen.PREFIX
-- codegen.COMMIT is the only other opcode; it is the last branch of the
-- dispatch below.

-- The key of a second map that takes any token (see codegen); only a
-- possessive repetition has it, since a choice with it is ambiguous.
local ANY = codegen.ANY
-- the number of tokens written from the head of the queue after which an
-- outermost backtrack point moves the tokens read ahead to its start
local COMPACT = 64

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

--- contextual_tables returns, for the contextual keywords of kinds, the
--- keywords of each base kind as an array of { kind, text, ignore_case }
--- (text lowered when ignore_case) and the base kind of each keyword.
--- @param kinds table
--- @return table by_base base kind -> array
--- @return table base_of keyword kind -> base kind
local function contextual_tables(kinds)
    local by_base, base_of = {}, {}
    for k, kind in ipairs(kinds) do
        local base = kind.base
        if base then
            local list = by_base[base] or {}
            list[#list + 1] = {
                k,
                kind.ignore_case and lower(kind.name) or kind.name,
                kind.ignore_case,
            }
            by_base[base] = list
            base_of[k] = base
        end
    end
    return by_base, base_of
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
    local by_base, base_of = contextual_tables(kinds)
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
    -- the queue index of the next valid token once peek has found it, kept
    -- until the head of the queue moves past it (nil: not known)
    local next_i
    -- the token at a position of the source, which keeps the values of its
    -- lookaheads (see lexogram.tokenizer)
    -- and the part of a token that the automaton of a prefix match accepts
    local scan, part = scanner(compiled, new_input(source))
    -- absent when the prefix matches name delimited tokens only
    local prefixes = compiled.lexer.prefixes or {}
    local failure -- error of a delimited token

    -- frames: return address, rule kind, ENTER event number, start, and
    -- the largest stop of the rules that ended inside it
    local fret, fkind, fenter, fstart, fmax = {}, {}, {}, {}, {}
    local depth = 0

    -- backtrack points
    local tevents, tqueue, tdepth, tresume = {}, {}, {}, {}
    local tstop, ttoken = {}, {}
    local tmax = {}
    local ntry = 0
    -- what the splits under backtrack points replaced, and the number of
    -- them at each backtrack point
    local undo, tundo = {}, {}
    local nundo = 0

    -- expected kinds since the last consumed token
    local exp = {}
    local nexp = 0

    -- the furthest failure so far, in a trial or not: the start of its
    -- next token (0 before any), that token's kind and the sources of the
    -- kinds expected there (see note)
    local far_pos, far_actual = 0, nil
    local far_exp, far_nexp = {}, 0

    --- token tokenizes the token at pos and returns its kind and stop: a
    --- token of a base kind with the text of a contextual keyword gets the
    --- kind of the keyword, and an erroneous token sets failure.
    local function token(pos)
        local k, stop, problem, at = scan(pos)
        local keywords = by_base[k]
        if keywords then
            local n = stop - pos
            for _, kw in ipairs(keywords) do
                local text = kw[2]
                if #text == n then
                    local s = sub(source, pos, stop - 1)
                    if (kw[3] and lower(s) or s) == text then
                        k = kw[1]
                        break
                    end
                end
            end
        end
        if problem == 'unterminated' then
            failure = {
                code = 'unterminated_token',
                pos = pos,
                actual = k,
                expected = {},
                message = 'unterminated ' .. kind_label(kinds, k),
            }
        elseif problem == 'invalid' then
            failure = {
                code = 'invalid_token',
                pos = pos,
                actual = k,
                expected = {},
                message = 'invalid ' .. kind_label(kinds, k),
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
        return k, stop
    end

    --- read appends the next raw token to the queue; false at the end of
    --- input or after an erroneous delimited token.
    local function read()
        if raw_pos > len or failure then
            return false
        end
        local k, stop = token(raw_pos)
        qt = qt + 1
        qk[qt], qs[qt], qe[qt] = k, raw_pos, stop
        raw_pos = stop
        return true
    end

    --- split replaces the token at queue index i by the token tokenized
    --- from at, where the part that a prefix match takes ends. When it does
    --- not end where the replaced token did, the tokens after it are
    --- dropped and reading goes on from its end. Under a backtrack point,
    --- what it replaces is kept for a rewind (see restore).
    local function split(i, at)
        if ntry > 0 then
            local tail = {}
            for j = i + 1, qt do
                tail[#tail + 1] = qk[j]
                tail[#tail + 1] = qs[j]
                tail[#tail + 1] = qe[j]
            end
            nundo = nundo + 1
            undo[nundo] = {
                i = i,
                k = qk[i],
                s = qs[i],
                e = qe[i],
                qt = qt,
                raw_pos = raw_pos,
                failure = failure,
                tail = tail,
            }
        end
        local old = qe[i]
        if qt == i then
            -- the error of the replaced token, read last, no longer holds
            failure = nil
        end
        local k, stop = token(at)
        qk[i], qs[i], qe[i] = k, at, stop
        if stop ~= old then
            if qt > i then
                failure = nil
            end
            qt, raw_pos = i, stop
        end
    end

    --- restore undoes the splits made after the backtrack point n.
    local function restore(n)
        while nundo > tundo[n] do
            local u = undo[nundo]
            undo[nundo] = nil
            nundo = nundo - 1
            local i, tail = u.i, u.tail
            qk[i], qs[i], qe[i] = u.k, u.s, u.e
            local at = i
            for j = 1, #tail, 3 do
                at = at + 1
                qk[at], qs[at], qe[at] = tail[j], tail[j + 1], tail[j + 2]
            end
            qt, raw_pos, failure = u.qt, u.raw_pos, u.failure
        end
    end

    --- peek returns the kind and queue index of the n-th valid token
    --- ahead (kind 0 and nil at the end of input).
    local function peek(n)
        local i = qh
        if next_i then
            if n == 1 then
                return qk[next_i], next_i
            end
            i, n = next_i + 1, n - 1
        end
        while true do
            if i > qt and not read() then
                return END, nil
            end
            local k = qk[i]
            if not skipped[k] then
                if not next_i then
                    next_i = i
                end
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
                if i > qh then
                    flush(i)
                end
                start = qs[i]
            elseif qt >= qh then
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

    --- note keeps the failure at the next token if it is the furthest one
    --- so far, or adds what it expected to the furthest one at the same
    --- position.
    local function note()
        local t, i = peek(1)
        local pos = i and qs[i] or len + 1
        if pos > far_pos then
            far_pos, far_actual, far_nexp = pos, t, 0
        elseif pos < far_pos then
            return
        end
        for j = 1, nexp do
            far_nexp = far_nexp + 1
            far_exp[far_nexp] = exp[j]
        end
    end

    --- fail rewinds to the innermost backtrack point and returns its resume
    --- address, or returns nil when there is none. The failure is noted
    --- first, so that the error reported is the furthest one in the input,
    --- of the alternatives tried or of the last one.
    local function fail()
        note()
        if ntry == 0 then
            return nil
        end
        restore(ntry)
        count = tevents[ntry]
        depth = tdepth[ntry]
        fmax[depth] = tmax[ntry]
        last_stop, last_token = tstop[ntry], ttoken[ntry]
        local resume = tresume[ntry]
        qh, next_i = tqueue[ntry], nil
        ntry = ntry - 1
        if failure then
            -- the erroneous token is the last one read: read it again
            raw_pos = qs[qt]
            qt = qt - 1
            failure = nil
        end
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
            if (t == k or base_of[t] == k) and i then
                if i > qh then
                    flush(i)
                end
                emit(TOKEN_EVENT, k, qs[i], qe[i])
                last_stop, last_token = qe[i], count
                qh, next_i = i + 1, nil
                if qh > qt and ntry == 0 then
                    -- reuse the queue arrays from the start, when no
                    -- backtrack point refers to them
                    qh, qt = 1, 0
                end
                nexp = 0
                pc = pc + 2
            else
                expect(k)
                pc = fail()
            end
        elseif op == PREFIX then
            local k = code[pc + 1]
            local t, i = peek(1)
            local stop
            if i then
                if t == k or base_of[t] == k then
                    stop = qe[i]
                elseif prefixes[k] then
                    -- a part shorter than the token
                    stop = part(k, qs[i], qe[i] - 2)
                end
            end
            if stop then
                if i > qh then
                    flush(i)
                end
                emit(TOKEN_EVENT, k, qs[i], stop)
                last_stop, last_token = stop, count
                if stop == qe[i] then
                    qh = i + 1
                else
                    split(i, stop)
                    qh = i
                end
                next_i = nil
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
                take = second[(peek(2))] or second[ANY]
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
                if ntry == 0 and qh > COMPACT then
                    -- the outermost backtrack point: move the tokens not
                    -- yet written to the start of the queue, so that it
                    -- holds the tokens of one trial at a time
                    local n = qt - qh + 1
                    for j = 1, n do
                        local from = qh + j - 1
                        qk[j], qs[j], qe[j] = qk[from], qs[from], qe[from]
                    end
                    qh, qt, next_i = 1, n, nil
                end
                ntry = ntry + 1
                tevents[ntry] = count
                tqueue[ntry] = qh
                tdepth[ntry] = depth
                tresume[ntry] = code[pc + 2]
                tstop[ntry], ttoken[ntry] = last_stop, last_token
                tmax[ntry] = fmax[depth]
                tundo[ntry] = nundo
                pc = pc + 3
            else
                expect(d.first)
                pc = code[pc + 2]
            end
        else -- COMMIT
            ntry = ntry - 1
            if ntry == 0 then
                -- no rewind can reach the splits kept
                for j = nundo, 1, -1 do
                    undo[j] = nil
                end
                nundo = 0
            end
            pc = pc + 1
        end
        -- an erroneous delimited token stops the analysis wherever it was
        -- read
        if failure then
            err = failure
            break
        end
        if not pc then
            -- the furthest failure (fail has noted the last one); a
            -- contextual keyword that is not expected is its base kind
            err = syntax_error(kinds, far_pos,
                               base_of[far_actual] or far_actual,
                               expected_kinds(far_exp, far_nexp))
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
