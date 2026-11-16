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
-- lexogram.utf8: strict UTF-8 encoding and decoding. Only arithmetic and
-- string.byte / string.char are used, so the behavior is identical on every
-- supported runtime (no utf8 library, no bitwise operators).
local type = type
local byte = string.byte
local char = string.char
local floor = math.floor

-- Largest valid Unicode code point.
local MAX_CODE_POINT = 0x10FFFF
-- Surrogate range, which is not encodable in UTF-8.
local SURROGATE_MIN = 0xD800
local SURROGATE_MAX = 0xDFFF
-- Multipliers that shift a value by 6, 12 and 18 bits.
local SHIFT6 = 0x40
local SHIFT12 = 0x1000
local SHIFT18 = 0x40000
-- Smallest code point that each sequence length may encode; a smaller value
-- is an overlong encoding. Indexed by the sequence length.
local MIN_CODE_POINT = {
    0,
    0x80,
    0x800,
    0x10000,
}

--- is_integer returns true if v is a number with an integral value.
--- NaN is rejected because it is not equal to itself.
--- @param v any
--- @return boolean
local function is_integer(v)
    return type(v) == 'number' and floor(v) == v
end

--- encode returns the UTF-8 encoding of the code point cp.
--- It never raises an error.
--- @param cp any
--- @return string? str
--- @return string? err
local function encode(cp)
    if not is_integer(cp) then
        return nil, 'code point must be an integer'
    elseif cp < 0 or cp > MAX_CODE_POINT then
        return nil, 'code point out of range'
    elseif cp >= SURROGATE_MIN and cp <= SURROGATE_MAX then
        return nil, 'surrogate code point'
    elseif cp < 0x80 then
        return char(cp)
    elseif cp < 0x800 then
        return char(0xC0 + floor(cp / SHIFT6), 0x80 + cp % SHIFT6)
    elseif cp < 0x10000 then
        return char(0xE0 + floor(cp / SHIFT12),
                    0x80 + floor(cp / SHIFT6) % SHIFT6, 0x80 + cp % SHIFT6)
    end
    return char(0xF0 + floor(cp / SHIFT18), 0x80 + floor(cp / SHIFT12) % SHIFT6,
                0x80 + floor(cp / SHIFT6) % SHIFT6, 0x80 + cp % SHIFT6)
end

--- decode_lead returns the length of the sequence that starts with the lead
--- byte b and the code point bits carried by that byte. It returns nil if b
--- cannot start a multi-byte sequence (a continuation byte, 0xC0, 0xC1 or
--- 0xF5..0xFF). The caller handles ASCII bytes (0x00..0x7F) before this.
--- @param b integer
--- @return integer? len
--- @return integer? bits
local function decode_lead(b)
    if b < 0xC2 then
        return nil
    elseif b < 0xE0 then
        return 2, b - 0xC0
    elseif b < 0xF0 then
        return 3, b - 0xE0
    elseif b < 0xF5 then
        return 4, b - 0xF0
    end
    return nil
end

--- decode decodes the single UTF-8 sequence that starts at byte pos of s.
--- @param s string
--- @param pos integer? 1-based byte position (default 1)
--- @return integer? cp
--- @return integer|string len_or_err
local function decode(s, pos)
    if type(s) ~= 'string' then
        error('s must be string, got ' .. type(s), 2)
    elseif pos == nil then
        pos = 1
    elseif not is_integer(pos) then
        error('pos must be integer, got ' .. type(pos), 2)
    end

    local slen = #s
    if pos < 1 or pos > slen then
        return nil, 'position out of range'
    end

    local b = byte(s, pos)
    if b < 0x80 then
        return b, 1
    end

    local len, cp = decode_lead(b)
    if not len then
        return nil, 'invalid lead byte'
    elseif pos + len - 1 > slen then
        return nil, 'truncated sequence'
    end

    for i = pos + 1, pos + len - 1 do
        b = byte(s, i)
        if b < 0x80 or b > 0xBF then
            return nil, 'invalid continuation byte'
        end
        cp = cp * SHIFT6 + (b - 0x80)
    end

    if cp < MIN_CODE_POINT[len] then
        return nil, 'overlong encoding'
    elseif cp >= SURROGATE_MIN and cp <= SURROGATE_MAX then
        return nil, 'surrogate code point'
    elseif cp > MAX_CODE_POINT then
        return nil, 'code point out of range'
    end
    return cp, len
end

return {
    encode = encode,
    decode = decode,
}
