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
-- lexogram.compile.utf8range: splits a code point range into sequences of
-- UTF-8 byte ranges, for building byte-level automata from code point
-- classes. It follows the standard algorithm (RE2, Rust's utf8-ranges):
-- the range is split at the encoding-length boundaries and around the
-- surrogates, then until every continuation byte position either spans
-- the full 0x80..0xBF range or has equal leading bytes. The splitting is
-- iterative (explicit stack) and uses arithmetic only (no bitwise
-- operators).
local type = type
local error = error
local byte = string.byte
local format = string.format
local floor = math.floor
local encode = require('lexogram.utf8').encode

-- Largest valid Unicode code point and the surrogate range.
local MAX_CODE_POINT = 0x10FFFF
local SURROGATE_MIN = 0xD800
local SURROGATE_MAX = 0xDFFF
-- Largest code point encoded with 1, 2 and 3 bytes.
local MAX_BY_LENGTH = {
    0x7F,
    0x7FF,
    0xFFFF,
}
-- Number of code points covered by the trailing 1, 2 and 3 continuation
-- bytes: 2^6, 2^12 and 2^18.
local BLOCK_SIZES = {
    0x40,
    0x1000,
    0x40000,
}

--- check_argument raises an error at the level of the caller of split if v
--- is not an integral code point.
--- @param name string
--- @param v any
local function check_argument(name, v)
    if type(v) ~= 'number' then
        error(name .. ' must be integer, got ' .. type(v), 3)
    elseif floor(v) ~= v then
        error(name .. ' must be integer, got ' .. format('%.17g', v), 3)
    elseif v < 0 or v > MAX_CODE_POINT then
        error(name .. ' must be in range 0 to 1114111 (0x10FFFF), got ' ..
                  format('%.17g', v), 3)
    end
end

--- to_sequence returns the byte range sequence of a range lo..hi whose
--- code points have the same encoding length and whose bytes after the
--- first differing one span full continuation ranges.
--- @param lo integer
--- @param hi integer
--- @return table sequence
local function to_sequence(lo, hi)
    local slo, shi = encode(lo), encode(hi)
    local seq = {}
    for i = 1, #slo do
        seq[i] = {
            byte(slo, i),
            byte(shi, i),
        }
    end
    return seq
end

--- split_off returns the end of the first part of lo..hi if the range
--- must be split further, or nil if lo..hi maps to one sequence. The range
--- has a single encoding length and does not contain surrogates.
--- @param lo integer
--- @param hi integer
--- @return integer? mid the last code point of the first part
local function split_off(lo, hi)
    for i = 1, 3 do
        local max = MAX_BY_LENGTH[i]
        if lo <= max and max < hi then
            return max
        end
    end
    if hi <= 0x7F then
        return nil
    end
    for i = 1, 3 do
        local size = BLOCK_SIZES[i]
        local lo_block, hi_block = floor(lo / size), floor(hi / size)
        if lo_block ~= hi_block then
            if lo % size ~= 0 then
                -- the first part ends at the end of lo's block
                return lo_block * size + size - 1
            elseif hi % size ~= size - 1 then
                -- the second part starts at the start of hi's block
                return hi_block * size - 1
            end
        end
    end
    return nil
end

--- split returns the byte range sequences that match exactly the UTF-8
--- encodings of the scalar values in lo..hi (surrogates are skipped),
--- sorted by the smallest code point they encode.
--- @param lo integer
--- @param hi integer
--- @return table[] sequences array of arrays of { blo, bhi }
local function split(lo, hi)
    check_argument('lo', lo)
    check_argument('hi', hi)
    if lo > hi then
        error('lo must not be greater than hi', 2)
    end

    local seqs = {}
    -- pending ranges as pairs of values; the top is processed first, and
    -- the upper part of a split is pushed so that output stays ascending
    local stack = {
        lo,
        hi,
    }
    while #stack > 0 do
        local e = stack[#stack]
        local s = stack[#stack - 1]
        stack[#stack] = nil
        stack[#stack] = nil
        while s <= e do
            if s < SURROGATE_MAX + 1 and e > SURROGATE_MIN - 1 then
                -- remove the surrogates: keep the part below, push above
                stack[#stack + 1] = SURROGATE_MAX + 1
                stack[#stack + 1] = e
                e = SURROGATE_MIN - 1
            else
                local mid = split_off(s, e)
                if not mid then
                    seqs[#seqs + 1] = to_sequence(s, e)
                    break
                end
                stack[#stack + 1] = mid + 1
                stack[#stack + 1] = e
                e = mid
            end
        end
    end
    return seqs
end

return {
    split = split,
}
