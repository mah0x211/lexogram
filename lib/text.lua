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
-- lexogram.text: formatting of strings for messages and paths.
local byte = string.byte
local sub = string.sub
local format = string.format
local concat = table.concat

--- escape returns s with backslash and double quote escaped by a backslash
--- and every byte below 32, byte 127 and every byte 128 or above written
--- as \ddd (three decimal digits).
--- @param s string
--- @return string
local function escape(s)
    local parts = {}
    -- plain bytes are copied in runs; run is the start of the current run
    local run = 1
    for i = 1, #s do
        local b = byte(s, i)
        local esc
        if b == 92 or b == 34 then
            esc = '\\' .. sub(s, i, i)
        elseif b < 32 or b >= 127 then
            esc = format('\\%03d', b)
        end
        if esc then
            parts[#parts + 1] = sub(s, run, i - 1)
            parts[#parts + 1] = esc
            run = i + 1
        end
    end
    parts[#parts + 1] = sub(s, run)
    return concat(parts)
end

--- quote returns s escaped and enclosed in double quotes.
--- @param s string
--- @return string
local function quote(s)
    return '"' .. escape(s) .. '"'
end

return {
    escape = escape,
    quote = quote,
}
