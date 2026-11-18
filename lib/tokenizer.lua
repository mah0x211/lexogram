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
-- lexogram.tokenizer: finds the token at a position of a source string with
-- the tables of a compiled grammar (see lexogram.compile for the format and
-- the tokenizing procedure). Without lookaheads it creates no tables and no
-- strings per call: the automata are run over the flat arrays with
-- string.byte, and the close string of a delimited token is matched in
-- place.
--
-- Close search: the close is a sequence of parts (literals and the
-- capture). When the first part is a literal, its next occurrence is found
-- with a plain string.find; at each occurrence the remaining parts are
-- compared byte by byte (the capture against the captured bytes of the
-- source), and the search continues one byte after a mismatching
-- occurrence. When the first part is the capture, every position is tried
-- the same way. In the worst case this takes O(n * m) byte comparisons for
-- a body of n bytes and a close of m bytes.
--
-- With nest set, the body is scanned position by position: the close is
-- tried first, then the open automaton; an open of the inner entry (the
-- delimited token itself, or the table named by a prefixed table) with the
-- same captured bytes either opens a nested level that needs its own close
-- (nest = 'count'), or is reported (nest = 'error': the token still ends
-- at the first close, so tokenizing can go on, and the position of the
-- first such open is returned).
--
-- Lookaheads: an automaton with dispatch states (see lexogram.compile) is
-- run by a separate loop that evaluates the predicates of a dispatch
-- state at its position. A predicate with a distance is evaluated there by
-- its forward automaton, which reads at most that many bytes; a predicate
-- without one is computed for every position of the input once, by its
-- backward automaton run from the end, and kept in the input made by
-- input(source), so that no part of the input is scanned again for each
-- token. Given a plain string, such a predicate is evaluated where it is
-- needed by its forward automaton too, which may read up to the end of the
-- input for that call. An input holds its source, so the values kept in it
-- always belong to the string tokenized (comparing the source of a call
-- with a kept one would read both on Lua 5.5, whose comparison of long
-- strings has no shortcut for the same string).
local type = type
local setmetatable = setmetatable
local getmetatable = getmetatable
local error = error
local floor = math.floor
local byte = string.byte
local find = string.find
local char = string.char
local concat = table.concat
local unpack = table.unpack or unpack

-- Metatable of an input (see input), which marks it.
local INPUT = {}

-- Powers of two for valuations.
local POW = {}
for j = 1, 31 do
    POW[j] = 2 ^ (j - 1)
end

-- Number of positions converted to a string at a time by precompute.
local CHUNK = 1024

local holds

--- valuation returns the valuation of the predicates preds at pos (bit
--- j - 1 set when preds[j] holds).
--- @param predicates table[]
--- @param preds integer[]
--- @param source string
--- @param pos integer
--- @param len integer
--- @param state table
--- @return integer
local function valuation(predicates, preds, source, pos, len, state)
    local v = 0
    for j = 1, #preds do
        if holds(predicates, preds[j], source, pos, len, state) then
            v = v + POW[j]
        end
    end
    return v
end

--- precompute returns the string whose byte at position i (1 .. len + 1)
--- is 1 when the predicate p holds at i and 0 otherwise, computed by the
--- backward automaton of p in one pass from the end of source, and keeps
--- it in state.
--- @param predicates table[]
--- @param p integer
--- @param source string
--- @param len integer
--- @param state table
--- @return string
local function precompute(predicates, p, source, len, state)
    local d = predicates[p].backward
    local nclasses, classes, trans, accept, dispatch = d.nclasses, d.classes,
                                                       d.trans, d.accept,
                                                       d.dispatch
    -- the pieces hold the positions from the end, each in forward order
    local pieces, buf, n = {}, {}, 0
    local s = 1
    for i = len + 1, 1, -1 do
        if i <= len then
            s = trans[(s - 1) * nclasses + classes[byte(source, i) + 1]]
        end
        local k = accept[s]
        if k < 0 then
            local entry = dispatch[s]
            s = entry.targets[valuation(predicates, entry.preds, source, i, len,
                                        state) + 1]
            k = accept[s]
        end
        n = n + 1
        buf[n] = k ~= 0 and 1 or 0
        if n == CHUNK or i == 1 then
            local forward = {}
            for j = 1, n do
                forward[j] = buf[n - j + 1]
            end
            pieces[#pieces + 1] = char(unpack(forward, 1, n))
            n = 0
        end
    end
    local ordered = {}
    for j = #pieces, 1, -1 do
        ordered[#ordered + 1] = pieces[j]
    end
    local values = concat(ordered)
    state.values[p] = values
    return values
end

--- holds returns whether the predicate p holds at pos of source.
--- @param predicates table[]
--- @param p integer
--- @param source string
--- @param pos integer
--- @param len integer
--- @param state table? input of input(), nil for a plain string
--- @return boolean
function holds(predicates, p, source, pos, len, state)
    local entry = predicates[p]
    if entry.backward and state then
        local values = state.values[p] or
                           precompute(predicates, p, source, len, state)
        return byte(values, pos) == 1
    end
    local d = entry.forward
    local nclasses, classes, trans, accept, dispatch = d.nclasses, d.classes,
                                                       d.trans, d.accept,
                                                       d.dispatch
    local s = 1
    while true do
        local k = accept[s]
        if k < 0 then
            local e = dispatch[s]
            s =
                e.targets[valuation(predicates, e.preds, source, pos, len, state) +
                    1]
            if s == 0 then
                return false
            end
            k = accept[s]
        end
        if k ~= 0 then
            return true
        elseif pos > len then
            return false
        end
        s = trans[(s - 1) * nclasses + classes[byte(source, pos) + 1]]
        if s == 0 then
            return false
        end
        pos = pos + 1
    end
end

--- longest_guarded is longest for an automaton with dispatch states (whose
--- accept is -1), whose predicates are those of lexer.
--- @param a table automaton
--- @param lexer table
--- @param source string
--- @param pos integer
--- @param len integer
--- @param state table?
--- @return integer? kind
--- @return integer? stop
local function longest_guarded(a, lexer, source, pos, len, state)
    local nclasses, classes, trans, accept, dispatch = a.nclasses, a.classes,
                                                       a.trans, a.accept,
                                                       a.dispatch
    local predicates = lexer.predicates
    local s = 1
    if accept[s] < 0 then
        local e = dispatch[s]
        s = e.targets[valuation(predicates, e.preds, source, pos, len, state) +
                1]
    end
    local kind, stop
    for i = pos, len do
        s = trans[(s - 1) * nclasses + classes[byte(source, i) + 1]]
        if s == 0 then
            break
        end
        local k = accept[s]
        if k ~= 0 then
            if k < 0 then
                local e = dispatch[s]
                s = e.targets[valuation(predicates, e.preds, source, i + 1, len,
                                        state) + 1]
                k = accept[s]
            end
            if k ~= 0 then
                kind, stop = k, i + 1
            end
        end
    end
    return kind, stop
end

--- longest returns the kind accepted for the longest non-empty prefix of
--- source from pos in automaton a, and the position after it, or nil.
--- @param a table automaton { nclasses, classes, trans, accept }
--- @param source string
--- @param pos integer
--- @param len integer #source
--- @return integer? kind
--- @return integer? stop
local function longest(a, source, pos, len)
    local nclasses, classes, trans, accept = a.nclasses, a.classes, a.trans,
                                             a.accept
    local s = 1
    local kind, stop
    for i = pos, len do
        s = trans[(s - 1) * nclasses + classes[byte(source, i) + 1]]
        if s == 0 then
            break
        end
        local k = accept[s]
        if k ~= 0 then
            kind, stop = k, i + 1
        end
    end
    return kind, stop
end

--- satisfies returns true if the automaton a of a check matches the whole
--- text of source from first to last. Its predicates see only that text:
--- they are evaluated forward with last as the end of the input.
--- @param a table automaton
--- @param predicates table[]?
--- @param source string
--- @param first integer
--- @param last integer
--- @return boolean
local function satisfies(a, predicates, source, first, last)
    local nclasses, classes, trans, accept, dispatch = a.nclasses, a.classes,
                                                       a.trans, a.accept,
                                                       a.dispatch
    local s = 1
    local i = first
    while true do
        if accept[s] < 0 then
            local e = dispatch[s]
            s = e.targets[valuation(predicates, e.preds, source, i, last) + 1]
            if s == 0 then
                return false
            end
        end
        if i > last then
            return accept[s] ~= 0
        end
        s = trans[(s - 1) * nclasses + classes[byte(source, i) + 1]]
        if s == 0 then
            return false
        end
        i = i + 1
    end
end

--- check returns kind and stop, with 'invalid' and the index of the first
--- check of list that the text from pos to stop - 1 fails when there is
--- one: 1 for the check of the first pattern with the fragments written as
--- arrays (list.first), otherwise the index of its pattern in the array
--- that defines the token.
--- @param list table the checks of kind { first, ... }
--- @param predicates table[]?
--- @param kind integer
--- @param source string
--- @param pos integer
--- @param stop integer
--- @return integer kind
--- @return integer stop
--- @return string? problem 'invalid'
--- @return integer? index
local function check(list, predicates, kind, source, pos, stop)
    local first = list.first
    if first and not satisfies(first, predicates, source, pos, stop - 1) then
        return kind, stop, 'invalid', 1
    end
    for i = 1, #list do
        if not satisfies(list[i], predicates, source, pos, stop - 1) then
            return kind, stop, 'invalid', i + 1
        end
    end
    return kind, stop
end

--- capture_end returns the position after the bytes read greedily from
--- first by the capture automaton a (until it has no transition).
--- @param a table
--- @param source string
--- @param first integer
--- @param len integer
--- @return integer
local function capture_end(a, source, first, len)
    local nclasses, classes, trans = a.nclasses, a.classes, a.trans
    local s = 1
    for i = first, len do
        s = trans[(s - 1) * nclasses + classes[byte(source, i) + 1]]
        if s == 0 then
            return i
        end
    end
    return len + 1
end

--- match_close returns the position after the close parts from index k
--- on, matched at position at of source, or nil if they do not match.
--- @param close table[] close parts
--- @param k integer index of the first part to match
--- @param source string
--- @param at integer
--- @param len integer
--- @param cap_start integer first captured byte
--- @param cap_end integer position after the captured bytes
--- @return integer? stop
local function match_close(close, k, source, at, len, cap_start, cap_end)
    for i = k, #close do
        local lit = close[i].literal
        if lit then
            local n = #lit
            if at + n - 1 > len then
                return nil
            end
            for j = 1, n do
                if byte(source, at + j - 1) ~= byte(lit, j) then
                    return nil
                end
            end
            at = at + n
        else
            local n = cap_end - cap_start
            if at + n - 1 > len then
                return nil
            end
            for j = 0, n - 1 do
                if byte(source, at + j) ~= byte(source, cap_start + j) then
                    return nil
                end
            end
            at = at + n
        end
    end
    return at
end

--- find_close returns the position after the first occurrence of the close
--- string at or after from, or nil.
--- @param close table[]
--- @param source string
--- @param from integer
--- @param len integer
--- @param cap_start integer
--- @param cap_end integer
--- @return integer? stop
local function find_close(close, source, from, len, cap_start, cap_end)
    local first = close[1].literal
    if first then
        local n = #first
        while true do
            local at = find(source, first, from, true)
            if not at then
                return nil
            end
            local stop = match_close(close, 2, source, at + n, len, cap_start,
                                     cap_end)
            if stop then
                return stop
            end
            from = at + 1
        end
    end
    for at = from, len do
        local stop = match_close(close, 1, source, at, len, cap_start, cap_end)
        if stop then
            return stop
        end
    end
    return nil
end

--- same_capture returns true if the capture of an open of entry matched at
--- at holds the same bytes as cap_start..cap_end - 1 (always true for an
--- entry without a capture).
--- @param entry table
--- @param source string
--- @param at integer
--- @param len integer
--- @param cap_start integer
--- @param cap_end integer
--- @return boolean
local function same_capture(entry, source, at, len, cap_start, cap_end)
    if not entry.capture then
        return true
    end
    local first = at + entry.prefix
    local stop = capture_end(entry.capture, source, first, len)
    if stop - first ~= cap_end - cap_start then
        return false
    end
    for j = 0, stop - first - 1 do
        if byte(source, first + j) ~= byte(source, cap_start + j) then
            return false
        end
    end
    return true
end

--- scan_nested scans the body of a delimited token with a nest setting
--- from from and returns the position after its close (nil when there is
--- none) and the position of the first nested open found with nest =
--- 'error'.
--- @param lexer table
--- @param entry table
--- @param source string
--- @param from integer
--- @param len integer
--- @param cap_start integer
--- @param cap_end integer
--- @return integer? stop
--- @return integer? nested
local function scan_nested(lexer, entry, source, from, len, cap_start, cap_end)
    local close, count = entry.close, entry.nest == 'count'
    local depth, nested = 0, nil
    local at = from
    while at <= len do
        local stop = match_close(close, 1, source, at, len, cap_start, cap_end)
        if stop then
            if depth == 0 then
                return stop, nested
            end
            depth = depth - 1
            at = stop
        else
            local index, open_stop = longest(lexer.open, source, at, len)
            if index == entry.inner and
                same_capture(lexer.delimited[index], source, at, len, cap_start,
                             cap_end) then
                if count then
                    depth = depth + 1
                    at = open_stop
                else
                    nested = nested or at
                    at = at + 1
                end
            else
                at = at + 1
            end
        end
    end
    return nil, nested
end

--- delimited_token returns the kind and the stop of the delimited token of
--- the entry index whose open matched source from pos to open_stop; a third
--- value 'unterminated' marks a token without close (it runs to the end of
--- input), and 'nested' with a fourth value marks an open nested at that
--- position in a token whose nest is 'error'.
--- @param lexer table
--- @param index integer
--- @param source string
--- @param pos integer
--- @param open_stop integer
--- @param len integer
--- @return integer kind
--- @return integer stop
--- @return string? problem 'unterminated' or 'nested'
--- @return integer? at position of the nested open
local function delimited_token(lexer, index, source, pos, open_stop, len)
    local entry = lexer.delimited[index]
    local kind = entry.id
    local cap_start, cap_end = pos, pos
    if entry.capture then
        cap_start = pos + entry.prefix
        cap_end = capture_end(entry.capture, source, cap_start, len)
    end
    local stop, nested
    if entry.nest then
        stop, nested = scan_nested(lexer, entry, source, open_stop, len,
                                   cap_start, cap_end)
    else
        stop = find_close(entry.close, source, open_stop, len, cap_start,
                          cap_end)
    end
    if nested then
        return kind, stop or len + 1, 'nested', nested
    elseif not stop then
        return kind, len + 1, 'unterminated'
    end
    return kind, stop
end

--- tokenize returns the kind of the token of source starting at pos and the
--- position after it, or nil at the end of input. At pos 1, a leading token
--- wins over every other token. A third value
--- 'unterminated' marks a delimited token without close, which runs to the
--- end of input; 'nested', with the position of the nested open as a fourth
--- value, marks a delimited token whose nest is 'error' containing an open
--- of itself (the token still ends at its first close); 'invalid', with the
--- index of a pattern as a fourth value, marks a pattern token whose text
--- fails a check (its kind and stop are those of the first pattern): 1 when
--- a fragment written as an array that its first pattern refers to does
--- not match all its patterns, otherwise a pattern after the first of the
--- array that defines the token.
--- source is a string, or an input made by input(source) for repeated
--- calls on the same string, which keeps the values of the lookaheads
--- computed for the whole input; with a string they are computed for the
--- call.
--- @param compiled table result of lexogram.compile
--- @param source string|table string or input
--- @param pos integer 1 <= pos <= #source + 1
--- @param mode string? nil or 'default'
--- @return integer? kind
--- @return integer? stop
--- @return string? problem 'unterminated', 'nested' or 'invalid'
--- @return integer? at position of the nested open, or index of the pattern
local function tokenize(compiled, source, pos, mode)
    if type(compiled) ~= 'table' then
        error('compiled must be table, got ' .. type(compiled), 2)
    end
    -- a string costs one type check per call, as without inputs
    local state
    if type(source) ~= 'string' then
        if getmetatable(source) ~= INPUT then
            error('source must be string or input, got ' .. type(source), 2)
        end
        state, source = source, source.source
    end
    if type(pos) ~= 'number' or floor(pos) ~= pos then
        error('pos must be integer, got ' .. type(pos), 2)
    elseif pos < 1 or pos > #source + 1 then
        error('pos must be in range 1 to ' .. (#source + 1), 2)
    elseif mode ~= nil and mode ~= 'default' then
        error('mode must be nil or "default"', 2)
    end

    local len = #source
    if pos > len then
        return nil
    end
    local lexer = compiled.lexer
    local checks = lexer.checks
    -- leading tokens are tried at the start of input only, before the rest
    local leading = pos == 1 and lexer.leading
    if leading then
        local kind, stop
        if leading.dispatch then
            kind, stop =
                longest_guarded(leading, lexer, source, pos, len, state)
        else
            kind, stop = longest(leading, source, pos, len)
        end
        if kind then
            local list = checks and checks[kind]
            if list then
                return check(list, lexer.predicates, kind, source, pos, stop)
            end
            return kind, stop
        end
    end
    local index, stop = longest(lexer.open, source, pos, len)
    if index then
        return delimited_token(lexer, index, source, pos, stop, len)
    end
    local kind
    if lexer.dispatch then
        kind, stop = longest_guarded(lexer, lexer, source, pos, len, state)
    else
        kind, stop = longest(lexer, source, pos, len)
    end
    if kind then
        local list = checks and checks[kind]
        if list then
            return check(list, lexer.predicates, kind, source, pos, stop)
        end
        return kind, stop
    end
    -- kind 1 is INVALID: a byte that starts no token
    return 1, pos + 1
end

--- input returns an input of source for repeated calls of tokenize on it:
--- it holds source and the values of the lookaheads computed for it.
--- @param source string
--- @return table
local function input(source)
    if type(source) ~= 'string' then
        error('source must be string, got ' .. type(source), 2)
    end
    return setmetatable({
        source = source,
        values = {},
    }, INPUT)
end

return {
    tokenize = tokenize,
    input = input,
}
