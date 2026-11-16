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
-- lexogram.compile.limits: reads the optional state limits that tests pass
-- to the automaton builders (nfa.build, dfa.build, lexer.build) to reach
-- the automaton_too_large paths with small automata.
local type = type
local error = error
local rawget = rawget
local tostring = tostring
local floor = math.floor

--- get returns limits[key] if it is given, otherwise default. It raises at
--- the level of the caller of the builder that called it (level 3) if
--- limits is neither nil nor a table, or if the value is not a positive
--- integer.
--- @param limits any
--- @param key string
--- @param default integer
--- @return integer
local function get(limits, key, default)
    if limits == nil then
        return default
    elseif type(limits) ~= 'table' then
        error('limits must be table, got ' .. type(limits), 3)
    end
    local v = rawget(limits, key)
    if v == nil then
        return default
    elseif type(v) ~= 'number' or v < 1 or floor(v) ~= v then
        error('limits.' .. key .. ' must be a positive integer, got ' ..
                  tostring(v), 3)
    end
    return v
end

return {
    get = get,
}
