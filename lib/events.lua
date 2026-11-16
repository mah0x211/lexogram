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
-- lexogram.events: reading helpers for the result of lexogram.parse, and
-- line and column numbers of byte positions.
--
-- An event i (1-based) occupies events[(i - 1) * 4 + 1 .. (i - 1) * 4 + 4]:
-- op, kind, then for TOKEN its start and stop, for ENTER its start and the
-- number of its EXIT, for EXIT its stop and the number of its ENTER. A stop
-- is the first position after the range, so the text of a range is
-- source:sub(start, stop - 1).
--
-- Lines are separated by LF, CRLF or a lone CR, each counting as one line
-- break. Line and column numbers start at 1; the column counts bytes from
-- the start of the line, or code points with column_codepoints. The table
-- of line starts is built on the first request by one scan of the source
-- and kept (in the result object, or by the caller of line_starts), and
-- positions are then found by binary search.
local type = type
local error = error
local floor = math.floor
local byte = string.byte
local find = string.find
local sub = string.sub

-- Event opcodes.
local TOKEN = 1
local ENTER = 2
local EXIT = 3

-- Byte values of CR and LF.
local CR = 13
local LF = 10

-- lines

--- line_starts returns the sorted start positions of the lines of source.
--- @param source string
--- @return integer[]
local function line_starts(source)
    local starts = {
        1,
    }
    local pos = 1
    while true do
        local at = find(source, '[\r\n]', pos)
        if not at then
            return starts
        end
        if byte(source, at) == CR and byte(source, at + 1) == LF then
            at = at + 1
        end
        pos = at + 1
        starts[#starts + 1] = pos
    end
end

--- locate returns the line number of pos and the start of that line.
--- @param starts integer[] result of line_starts
--- @param pos integer
--- @return integer line
--- @return integer start
local function locate(starts, pos)
    local lo, hi = 1, #starts
    while lo < hi do
        local mid = floor((lo + hi + 1) / 2)
        if starts[mid] <= pos then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo, starts[lo]
end

--- check_result raises an error at the level of the caller of the public
--- function if result is not a parse result.
--- @param result any
local function check_result(result)
    if type(result) ~= 'table' or type(result.source) ~= 'string' or
        type(result.events) ~= 'table' then
        error('result must be a result of lexogram.parse', 3)
    end
end

--- check_pos raises an error at the level of the caller of the public
--- function if pos is not a position of source (1 to #source + 1).
--- @param source string
--- @param pos any
local function check_pos(source, pos)
    if type(pos) ~= 'number' or floor(pos) ~= pos or pos < 1 or pos > #source +
        1 then
        error('pos must be an integer from 1 to ' .. (#source + 1), 3)
    end
end

--- starts_of returns the line starts of a result, building and keeping
--- them on the first call.
--- @param result table
--- @return integer[]
local function starts_of(result)
    local starts = result.lines
    if not starts then
        starts = line_starts(result.source)
        result.lines = starts
    end
    return starts
end

--- position returns the line and the byte column of pos in the source of
--- result.
--- @param result table result of lexogram.parse
--- @param pos integer 1 to #source + 1
--- @return integer line
--- @return integer column
local function position(result, pos)
    check_result(result)
    check_pos(result.source, pos)
    local line, start = locate(starts_of(result), pos)
    return line, pos - start + 1
end

--- column_codepoints returns the line and the column of pos counted in
--- code points (bytes other than UTF-8 continuation bytes 0x80..0xBF).
--- @param result table result of lexogram.parse
--- @param pos integer 1 to #source + 1
--- @return integer line
--- @return integer column
local function column_codepoints(result, pos)
    check_result(result)
    local source = result.source
    check_pos(source, pos)
    local line, start = locate(starts_of(result), pos)
    local column = 1
    for i = start, pos - 1 do
        local b = byte(source, i)
        if b < 0x80 or b > 0xBF then
            column = column + 1
        end
    end
    return line, column
end

-- events

--- check_event raises an error at the level of the caller of the public
--- function if i is not an event number of result.
--- @param result any
--- @param i any
local function check_event(result, i)
    check_result(result)
    if type(i) ~= 'number' or floor(i) ~= i or i < 1 or i > result.count then
        error('i must be an event number from 1 to ' .. result.count, 3)
    end
end

--- op returns the opcode of event i (TOKEN, ENTER or EXIT).
--- @param result table
--- @param i integer
--- @return integer
local function op(result, i)
    check_event(result, i)
    return result.events[(i - 1) * 4 + 1]
end

--- kind returns the kind id of event i.
--- @param result table
--- @param i integer
--- @return integer
local function kind(result, i)
    check_event(result, i)
    return result.events[(i - 1) * 4 + 2]
end

--- name returns the kind name of event i (a token or rule name, a literal,
--- INVALID or ERROR) and its category.
--- @param result table
--- @param i integer
--- @return string name
--- @return string category
local function name(result, i)
    check_event(result, i)
    local k = result.grammar.kinds[result.events[(i - 1) * 4 + 2]]
    return k.name, k.category
end

--- range returns the start and the stop of event i; for ENTER and EXIT it
--- is the range of the rule.
--- @param result table
--- @param i integer
--- @return integer start
--- @return integer stop
local function range(result, i)
    check_event(result, i)
    local events = result.events
    local at = (i - 1) * 4
    local o = events[at + 1]
    if o == TOKEN then
        return events[at + 3], events[at + 4]
    elseif o == ENTER then
        return events[at + 3], events[(events[at + 4] - 1) * 4 + 3]
    end
    return events[(events[at + 4] - 1) * 4 + 3], events[at + 3]
end

--- text returns the source text of the range of event i.
--- @param result table
--- @param i integer
--- @return string
local function text(result, i)
    check_event(result, i)
    local start, stop = range(result, i)
    return sub(result.source, start, stop - 1)
end

--- match returns the number of the EXIT of an ENTER event, or of the ENTER
--- of an EXIT event; nil for a TOKEN.
--- @param result table
--- @param i integer
--- @return integer?
local function match(result, i)
    check_event(result, i)
    local at = (i - 1) * 4
    if result.events[at + 1] == TOKEN then
        return nil
    end
    return result.events[at + 4]
end

--- children returns an iterator over the numbers of the events directly
--- inside the ENTER event i (tokens and the ENTERs of nested rules, whose
--- contents are skipped), in order.
--- @param result table
--- @param i integer an ENTER event
--- @return function
local function children(result, i)
    check_event(result, i)
    local events = result.events
    local at = (i - 1) * 4
    if events[at + 1] ~= ENTER then
        error('event ' .. i .. ' is not an ENTER', 2)
    end
    local stop = events[at + 4]
    local cur = i + 1
    return function()
        if cur >= stop then
            return nil
        end
        local j = cur
        local o = events[(j - 1) * 4 + 1]
        if o == ENTER then
            cur = events[(j - 1) * 4 + 4] + 1
        else
            cur = j + 1
        end
        return j
    end
end

--- tree builds the nested structure of a result from the event array and
--- the kind table alone: an array of the top-level nodes, where a rule is
--- { name = <rule>, children = { ... } } and a token is { name = <kind
--- name>, text = <text> }. It is iterative, so deep nesting is fine.
--- @param result table
--- @return table[]
local function tree(result)
    check_result(result)
    local events, kinds, source = result.events, result.grammar.kinds,
                                  result.source
    local top = {}
    local stack = {
        top,
    }
    for i = 1, result.count do
        local at = (i - 1) * 4
        local o, k = events[at + 1], events[at + 2]
        local list = stack[#stack]
        if o == TOKEN then
            list[#list + 1] = {
                name = kinds[k].name,
                text = sub(source, events[at + 3], events[at + 4] - 1),
            }
        elseif o == ENTER then
            local node = {
                name = kinds[k].name,
                children = {},
            }
            list[#list + 1] = node
            stack[#stack + 1] = node.children
        else
            stack[#stack] = nil
        end
    end
    return top
end

return {
    TOKEN = TOKEN,
    ENTER = ENTER,
    EXIT = EXIT,
    line_starts = line_starts,
    locate = locate,
    position = position,
    column_codepoints = column_codepoints,
    op = op,
    kind = kind,
    name = name,
    range = range,
    text = text,
    match = match,
    children = children,
    tree = tree,
}
