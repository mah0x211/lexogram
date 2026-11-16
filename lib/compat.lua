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
-- lexogram.compat: hides differences between Lua runtimes
-- (Lua 5.1 - 5.5 and LuaJIT 2.1). Every runtime-specific choice is made by
-- feature detection, never by inspecting the version string.
local type = type
local next = next
local rawget = rawget
local byte = string.byte
local sort = table.sort
local setfenv = setfenv
local loadstring = loadstring
local load = load

-- The built-in unpack function: a global in Lua 5.1 and LuaJIT,
-- table.unpack in Lua 5.2 and later.
local unpack = unpack or table.unpack

-- Byte value of ESC, the first byte of every binary (bytecode) chunk.
local ESC = 27

--- validate_load_args raises an error if any argument of load_text has the
--- wrong type.
--- @param src any
--- @param chunkname any
--- @param env any
local function validate_load_args(src, chunkname, env)
    if type(src) ~= 'string' then
        error('src must be string, got ' .. type(src), 3)
    elseif type(chunkname) ~= 'string' then
        error('chunkname must be string, got ' .. type(chunkname), 3)
    elseif type(env) ~= 'table' then
        error('env must be table, got ' .. type(env), 3)
    end
end

--- load_text compiles Lua source text into a function whose global
--- environment is env. Binary chunks are rejected.
--- @param src string
--- @param chunkname string
--- @param env table
--- @return function? fn
--- @return string? err
local load_text
if setfenv then
    -- Lua 5.1 and LuaJIT: loadstring accepts binary chunks, so they are
    -- rejected before loading, and the environment is set with setfenv.
    load_text = function(src, chunkname, env)
        validate_load_args(src, chunkname, env)
        if byte(src, 1) == ESC then
            return nil, chunkname .. ': attempt to load a binary chunk'
        end

        local fn, err = loadstring(src, chunkname)
        if not fn then
            return nil, err
        end
        return setfenv(fn, env)
    end
else
    -- Lua 5.2 and later: load takes a mode and an environment.
    load_text = function(src, chunkname, env)
        validate_load_args(src, chunkname, env)
        if byte(src, 1) == ESC then
            return nil, chunkname .. ': attempt to load a binary chunk'
        end
        return load(src, chunkname, 't', env)
    end
end

--- byte_less returns true if string a sorts before string b in byte order.
--- A string that is a prefix of another sorts first. The < operator is not
--- used on strings because it depends on the locale (strcoll).
--- @param a string
--- @param b string
--- @return boolean
local function byte_less(a, b)
    local alen = #a
    local blen = #b
    local n = alen < blen and alen or blen
    for i = 1, n do
        local ca = byte(a, i)
        local cb = byte(b, i)
        if ca ~= cb then
            return ca < cb
        end
    end
    return alen < blen
end

--- collect_sorted_keys returns a new array of the keys of tbl: number keys
--- in ascending order, followed by string keys in ascending byte order.
--- Keys are enumerated with next (raw access), so a __pairs metamethod is
--- never consulted on any runtime. Errors are raised at the level of the
--- caller of the public function that called this helper.
--- @param tbl table
--- @return any[] keys
local function collect_sorted_keys(tbl)
    if type(tbl) ~= 'table' then
        error('tbl must be table, got ' .. type(tbl), 3)
    end

    local nums = {}
    local strs = {}
    for k in next, tbl do
        local t = type(k)
        if t == 'number' then
            nums[#nums + 1] = k
        elseif t == 'string' then
            strs[#strs + 1] = k
        else
            error('unsupported key type: ' .. t, 3)
        end
    end

    sort(nums)
    sort(strs, byte_less)
    local nnum = #nums
    for i = 1, #strs do
        nums[nnum + i] = strs[i]
    end
    return nums
end

--- sorted_keys returns a new array of the keys of tbl in deterministic order.
--- @param tbl table
--- @return any[] keys
local function sorted_keys(tbl)
    return collect_sorted_keys(tbl)
end

--- sorted_pairs returns an iterator that visits the key/value pairs of tbl in
--- the order of sorted_keys. The key order is fixed at call time; each value
--- is read when its pair is visited.
--- @param tbl table
--- @return function iterator
local function sorted_pairs(tbl)
    local keys = collect_sorted_keys(tbl)
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k ~= nil then
            return k, rawget(tbl, k)
        end
    end
end

return {
    byte_less = byte_less,
    unpack = unpack,
    load_text = load_text,
    sorted_keys = sorted_keys,
    sorted_pairs = sorted_pairs,
}
