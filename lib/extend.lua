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
-- lexogram.extend: applies the difference table of a grammar that extends
-- another one (see lexogram.loader) to a copy of the base grammar.
--
-- A key of the difference table may start with a mark that tells what to
-- do with the value of that name in the base, directly under it:
--
--   +X   append the items of the array value to the array X
--   -X   remove the items of the array value from the array X
--   ++X  add the fields of the table value to the table X
--   --X  remove the fields named by the array value from the table X
--   =X   replace the value of X
--   X    enter the table X, whose value is a table of the same form (the
--        number of fields directly under X does not change)
--
-- The target X must exist in the base; the top-level table fields (tokens,
-- rules, symbols, keywords, skip, leading, greedy and recover) exist as
-- empty tables when the base has none. An item or field to add must not
-- exist, and one to remove or replace must. In each table, removals are
-- applied first, then replacements and entered tables, then additions.
-- At the top level, extends and lexogram are written without a mark.
local type = type
local next = next
local ipairs = ipairs
local rawget = rawget
local tostring = tostring
local sort = table.sort
local match = string.match
local format = string.format
local byte_less = require('lexogram.compat').byte_less

-- Top-level fields that are tables, and those that are not.
local TABLE_FIELDS = {
    tokens = true,
    rules = true,
    symbols = true,
    keywords = true,
    skip = true,
    leading = true,
    greedy = true,
    recover = true,
}
local VALUE_FIELDS = {
    lexogram = true,
    start = true,
}

-- The phase of each mark: removals, then replacements and entered tables,
-- then additions.
local PHASE = {
    ['-'] = 1,
    ['--'] = 1,
    ['='] = 2,
    [''] = 2,
    ['+'] = 3,
    ['++'] = 3,
}

--- copy returns a deep copy of v (shared and cyclic references are kept).
--- @param v any
--- @param seen table
--- @return any
local function copy(v, seen)
    if type(v) ~= 'table' then
        return v
    elseif seen[v] then
        return seen[v]
    end
    local out = {}
    seen[v] = out
    for k, val in next, v do
        out[copy(k, seen)] = copy(val, seen)
    end
    return out
end

--- quote returns v as a quoted string for messages.
--- @param v any
--- @return string
local function quote(v)
    if type(v) == 'string' then
        return format('%q', v)
    end
    return tostring(v)
end

--- child returns the path of name under path.
--- @param path string
--- @param name string
--- @return string
local function child(path, name)
    if path == '' then
        return name
    end
    return path .. '.' .. name
end

--- array_length returns n if the keys of t are exactly 1..n, or nil.
--- @param t table
--- @return integer? n
local function array_length(t)
    local n = 0
    for _ in next, t do
        n = n + 1
    end
    for i = 1, n do
        if rawget(t, i) == nil then
            return nil
        end
    end
    return n
end

--- index_of returns the index of item in the array part 1..#t of t, or nil.
--- @param t table
--- @param item any
--- @return integer?
local function index_of(t, item)
    local i = 1
    local v = rawget(t, i)
    while v ~= nil do
        if v == item then
            return i
        end
        i = i + 1
        v = rawget(t, i)
    end
    return nil
end

--- parse_key splits the key k of a difference table into its mark and its
--- name, or returns nil and an error message.
--- @param k any
--- @return string? mark
--- @return string|nil name or error message
local function parse_key(k)
    if type(k) ~= 'string' then
        return nil, 'key ' .. quote(k) .. ' must be a string'
    end
    local mark, name = match(k, '^([%+%-=]*)(.*)$')
    if not PHASE[mark] or name == '' then
        return nil, 'key ' .. quote(k) .. ' has an invalid mark'
    end
    return mark, name
end

local apply

-- Operations by mark: op(t, name, value, path, root) applies the operation
-- to the table t (the table that holds name) and returns nil, or an error
-- message.

--- target returns the value of name in t, creating an empty table for a
--- top-level table field that the base does not have, or nil and an error
--- message if it does not exist or is not a table.
--- @param t table
--- @param name string
--- @param path string path of name
--- @param root boolean t is the grammar itself
--- @return table? value
--- @return string? err
local function target(t, name, path, root)
    local v = rawget(t, name)
    if v == nil and root and TABLE_FIELDS[name] then
        v = {}
        t[name] = v
    end
    if v == nil then
        return nil, path .. ': does not exist'
    elseif type(v) ~= 'table' then
        return nil, path .. ': is not a table'
    end
    return v
end

local OPERATIONS = {
    ['+'] = function(t, name, value, path, root)
        local n = type(value) == 'table' and array_length(value)
        if not n then
            return '+' .. path .. ': the value must be an array of items'
        end
        local list, err = target(t, name, path, root)
        if not list then
            return err
        end
        for i = 1, n do
            local item = rawget(value, i)
            if index_of(list, item) then
                return path .. ': already has ' .. quote(item)
            end
            list[#list + 1] = copy(item, {})
        end
    end,
    ['-'] = function(t, name, value, path, root)
        local n = type(value) == 'table' and array_length(value)
        if not n then
            return '-' .. path .. ': the value must be an array of items'
        end
        local list, err = target(t, name, path, root)
        if not list then
            return err
        end
        for i = 1, n do
            local item = rawget(value, i)
            local at = index_of(list, item)
            if not at then
                return path .. ': does not have ' .. quote(item)
            end
            -- shift the rest of the array part down
            local j = at
            while rawget(list, j) ~= nil do
                list[j] = rawget(list, j + 1)
                j = j + 1
            end
        end
    end,
    ['++'] = function(t, name, value, path, root)
        if type(value) ~= 'table' then
            return '++' .. path .. ': the value must be a table of fields'
        end
        for k in next, value do
            if type(k) ~= 'string' then
                return '++' .. path .. ': the value must be a table of fields'
            end
        end
        local tbl, err = target(t, name, path, root)
        if not tbl then
            return err
        end
        local keys = {}
        for k in next, value do
            keys[#keys + 1] = k
        end
        sort(keys, byte_less)
        for _, k in ipairs(keys) do
            if rawget(tbl, k) ~= nil then
                return child(path, k) .. ': already exists'
            end
            tbl[k] = copy(rawget(value, k), {})
        end
    end,
    ['--'] = function(t, name, value, path, root)
        local n = type(value) == 'table' and array_length(value)
        if n then
            for i = 1, n do
                if type(rawget(value, i)) ~= 'string' then
                    n = nil
                    break
                end
            end
        end
        if not n then
            return '--' .. path .. ': the value must be an array of names'
        end
        local tbl, err = target(t, name, path, root)
        if not tbl then
            return err
        end
        for i = 1, n do
            local k = rawget(value, i)
            if rawget(tbl, k) == nil then
                return child(path, k) .. ': does not exist'
            end
            tbl[k] = nil
        end
    end,
    ['='] = function(t, name, value, path, root)
        if rawget(t, name) == nil and not (root and TABLE_FIELDS[name]) then
            return path .. ': does not exist'
        end
        t[name] = copy(value, {})
    end,
    [''] = function(t, name, value, path, root)
        if type(value) ~= 'table' then
            return path .. ': a value without a mark must be a table' ..
                       ' (write =' .. name .. ' to replace the value)'
        end
        local tbl, err = target(t, name, path, root)
        if not tbl then
            return err
        end
        return apply(tbl, value, path, false)
    end,
}

--- apply applies the difference table diff to the table t at path and
--- returns nil, or an error message.
--- @param t table
--- @param diff table
--- @param path string
--- @param root boolean t is the grammar itself
--- @return string? err
function apply(t, diff, path, root)
    local ops = {}
    local marks = {}
    for k, v in next, diff do
        local mark, name = parse_key(k)
        if not mark then
            return (path == '' and '' or path .. ': ') .. name
        end
        if root and not (TABLE_FIELDS[name] or VALUE_FIELDS[name]) then
            return k .. ': unknown field'
        end
        local seen = marks[name] or {}
        marks[name] = seen
        seen[mark] = true
        if seen['='] and seen[''] then
            return child(path, name) .. ': =' .. name .. ' and ' .. name ..
                       ' cannot be used together'
        end
        ops[#ops + 1] = {
            phase = PHASE[mark],
            mark = mark,
            name = name,
            value = v,
        }
    end
    -- a fixed order, so that the first error is the same on every runtime
    sort(ops, function(a, b)
        if a.phase ~= b.phase then
            return a.phase < b.phase
        elseif a.name ~= b.name then
            return byte_less(a.name, b.name)
        end
        return byte_less(a.mark, b.mark)
    end)
    for _, op in ipairs(ops) do
        local err = OPERATIONS[op.mark](t, op.name, op.value,
                                        child(path, op.name), root)
        if err then
            return err
        end
    end
    return nil
end

--- extend returns a copy of the grammar base with the difference table diff
--- applied, or nil and an error message. diff.extends is not applied, and
--- diff.lexogram (without a mark) replaces the version of the base.
--- @param base table
--- @param diff table
--- @return table? grammar
--- @return string? err
local function extend(base, diff)
    local grammar = copy(base, {})
    local rest = {}
    for k, v in next, diff do
        if k == 'lexogram' then
            grammar.lexogram = copy(v, {})
        elseif k ~= 'extends' then
            rest[k] = v
        end
    end
    local err = apply(grammar, rest, '', true)
    if err then
        return nil, err
    end
    return grammar
end

return {
    extend = extend,
}
