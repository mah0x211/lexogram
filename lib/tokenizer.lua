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
-- the tokenizing procedure). It creates no tables and no strings per call:
-- the automata are run over the flat arrays with string.byte, and the close
-- string of a delimited token is matched in place.
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
local type = type
local error = error
local floor = math.floor
local byte = string.byte
local find = string.find

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
--- position after it, or nil at the end of input. A third value
--- 'unterminated' marks a delimited token without close, which runs to the
--- end of input; 'nested', with the position of the nested open as a fourth
--- value, marks a delimited token whose nest is 'error' containing an open
--- of itself (the token still ends at its first close).
--- @param compiled table result of lexogram.compile
--- @param source string
--- @param pos integer 1 <= pos <= #source + 1
--- @param mode string? nil or 'default'
--- @return integer? kind
--- @return integer? stop
--- @return string? problem 'unterminated' or 'nested'
--- @return integer? at position of the nested open
local function tokenize(compiled, source, pos, mode)
    if type(compiled) ~= 'table' then
        error('compiled must be table, got ' .. type(compiled), 2)
    elseif type(source) ~= 'string' then
        error('source must be string, got ' .. type(source), 2)
    elseif type(pos) ~= 'number' or floor(pos) ~= pos then
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
    local index, stop = longest(lexer.open, source, pos, len)
    if index then
        return delimited_token(lexer, index, source, pos, stop, len)
    end
    local kind
    kind, stop = longest(lexer, source, pos, len)
    if kind then
        return kind, stop
    end
    -- kind 1 is INVALID: a byte that starts no token
    return 1, pos + 1
end

return {
    tokenize = tokenize,
}
