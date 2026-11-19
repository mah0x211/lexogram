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
-- rules, symbols, keywords, skip, leading and recover) exist as
-- empty tables when the base has none. An item or field to add must not
-- exist, and one to remove or replace must. In each table, removals are
-- applied first, then replacements and entered tables, then additions.
-- At the top level, extends, embeds, mixin, lexogram, name and version are
-- written without a mark; name and version are not inherited.
--
-- A mixin (mixin = true) is a difference table without a base, which
-- grammars embed (embeds = { names }). The mixins are applied after the
-- base and before the difference of the grammar itself, in the order they
-- are written; a mixin that extends another mixin is applied after it. A
-- grammar without a base is a complete table, which the mixins are applied
-- to in the same order.
-- Since a mixin is written without knowing the base it is embedded in, an
-- item or field that it adds and that already exists is not added, with a
-- warning; a replacement replaces what an earlier mixin wrote (the later
-- one wins). The other marks work as in a difference of extends.
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
    recover = true,
}
local VALUE_FIELDS = {
    lexogram = true,
    name = true,
    version = true,
    start = true,
}

-- Fields that tell about the file itself: written without a mark, and
-- name and version are not inherited. Of these, the grammar takes
-- lexogram, name and version from the difference of the grammar itself
-- (COPIED), and none from a mixin.
local OWN_FIELDS = {
    extends = true,
    embeds = true,
    mixin = true,
    lexogram = true,
    name = true,
    version = true,
}
local COPIED = {
    lexogram = true,
    name = true,
    version = true,
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

-- Shapes by mark: shape(name, value, path) returns nil if value has the
-- shape that the mark takes, or an error message.
local SHAPES = {
    ['+'] = function(_, value, path)
        if not (type(value) == 'table' and array_length(value)) then
            return '+' .. path .. ': the value must be an array of items'
        end
    end,
    ['-'] = function(_, value, path)
        if not (type(value) == 'table' and array_length(value)) then
            return '-' .. path .. ': the value must be an array of items'
        end
    end,
    ['++'] = function(_, value, path)
        if type(value) ~= 'table' then
            return '++' .. path .. ': the value must be a table of fields'
        end
        for k in next, value do
            if type(k) ~= 'string' then
                return '++' .. path .. ': the value must be a table of fields'
            end
        end
    end,
    ['--'] = function(_, value, path)
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
    end,
    ['='] = function()
    end,
    [''] = function(name, value, path)
        if type(value) ~= 'table' then
            return path .. ': a value without a mark must be a table' ..
                       ' (write =' .. name .. ' to replace the value)'
        end
    end,
}

-- Operations by mark: op(t, name, value, path, root, mixin) applies the
-- operation to the table t (the table that holds name), whose value has
-- the shape of the mark, and returns nil, or an error message. mixin is
-- the state of the mixin being applied, or nil for a difference of
-- extends.

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

--- warn adds the warning that the mixin did not add what already exists
--- at path.
--- @param mixin table { source, warnings }
--- @param path string
--- @param message string
local function warn(mixin, path, message)
    local list = mixin.warnings
    list[#list + 1] = {
        severity = 'warning',
        code = 'already_defined',
        path = path,
        message = message,
        source = mixin.source,
    }
end

local OPERATIONS = {
    ['+'] = function(t, name, value, path, root, mixin)
        local list, err = target(t, name, path, root)
        if not list then
            return err
        end
        for i = 1, array_length(value) do
            local item = rawget(value, i)
            if not index_of(list, item) then
                list[#list + 1] = copy(item, {})
            elseif mixin then
                warn(mixin, path, path .. ' already has ' .. quote(item) ..
                         '; it is not added')
            else
                return path .. ': already has ' .. quote(item)
            end
        end
    end,
    ['-'] = function(t, name, value, path, root)
        local list, err = target(t, name, path, root)
        if not list then
            return err
        end
        for i = 1, array_length(value) do
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
    ['++'] = function(t, name, value, path, root, mixin)
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
            local at = child(path, k)
            if rawget(tbl, k) == nil then
                tbl[k] = copy(rawget(value, k), {})
            elseif mixin then
                warn(mixin, at, at .. ' already exists; it is not added')
            else
                return at .. ': already exists'
            end
        end
    end,
    ['--'] = function(t, name, value, path, root)
        local tbl, err = target(t, name, path, root)
        if not tbl then
            return err
        end
        for i = 1, array_length(value) do
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
    [''] = function(t, name, value, path, root, mixin)
        local tbl, err = target(t, name, path, root)
        if not tbl then
            return err
        end
        return apply(tbl, value, path, false, mixin)
    end,
}

--- operations returns the operations of the difference table diff at path
--- in the order they are applied, or nil and an error message. At the top
--- level (root), diff must not hold the fields of OWN_FIELDS.
--- @param diff table
--- @param path string
--- @param root boolean
--- @return table[]? ops { mark, name, value }
--- @return string? err
local function operations(diff, path, root)
    local ops = {}
    local marks = {}
    for k, v in next, diff do
        local mark, name = parse_key(k)
        if not mark then
            return nil, (path == '' and '' or path .. ': ') .. name
        end
        if root and not (TABLE_FIELDS[name] or VALUE_FIELDS[name]) then
            return nil, k .. ': unknown field'
        end
        local seen = marks[name] or {}
        marks[name] = seen
        seen[mark] = true
        if seen['='] and seen[''] then
            return nil, child(path, name) .. ': =' .. name .. ' and ' .. name ..
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
    return ops
end

--- apply applies the difference table diff to the table t at path and
--- returns nil, or an error message.
--- @param t table
--- @param diff table
--- @param path string
--- @param root boolean t is the grammar itself
--- @param mixin table? { source, warnings } of the mixin being applied
--- @return string? err
function apply(t, diff, path, root, mixin)
    local ops, err = operations(diff, path, root)
    if not ops then
        return err
    end
    for _, op in ipairs(ops) do
        local at = child(path, op.name)
        err = SHAPES[op.mark](op.name, op.value, at) or
                  OPERATIONS[op.mark](t, op.name, op.value, at, root, mixin)
        if err then
            return err
        end
    end
    return nil
end

--- validate_table checks the shapes of the difference table diff at path
--- without applying it, and returns nil, or an error message.
--- @param diff table
--- @param path string
--- @param root boolean
--- @return string? err
local function validate_table(diff, path, root)
    local ops, err = operations(diff, path, root)
    if not ops then
        return err
    end
    for _, op in ipairs(ops) do
        local at = child(path, op.name)
        err = SHAPES[op.mark](op.name, op.value, at)
        if not err and op.mark == '' then
            err = validate_table(op.value, at, false)
        end
        if err then
            return err
        end
    end
    return nil
end

--- difference returns the fields of the difference table diff other than
--- those of OWN_FIELDS.
--- @param diff table
--- @return table
local function difference(diff)
    local rest = {}
    for k, v in next, diff do
        if not OWN_FIELDS[k] then
            rest[k] = v
        end
    end
    return rest
end

--- validate checks the shape of the difference table diff of a mixin (the
--- marks of its keys, the top-level field names and the shape of each
--- value) without a base, and returns nil, or an error message. Whether
--- the targets exist is known only when the mixin is embedded.
--- @param diff table
--- @return string? err
local function validate(diff)
    return validate_table(difference(diff), '', true)
end

--- embeds returns the names of the embeds field of the difference table
--- diff, or nil and an error message if it is not a non-empty array.
--- @param diff table
--- @return any[]? names
--- @return string? err
local function embeds(diff)
    local v = rawget(diff, 'embeds')
    local n = type(v) == 'table' and array_length(v)
    if not n or n == 0 then
        return nil, 'embeds must be a non-empty array of names'
    end
    local names = {}
    for i = 1, n do
        names[i] = rawget(v, i)
    end
    return names
end

--- check_duplicates returns an error message if a mixin is in two of the
--- chains of mixins, or nil.
--- @param mixins table[][] chains of { source, diff }
--- @return string? err
local function check_duplicates(mixins)
    -- source of a mixin -> source of the embedded mixin whose chain has it
    local seen = {}
    for _, chain in ipairs(mixins) do
        local entry = chain[#chain].source
        for _, link in ipairs(chain) do
            local source = link.source
            local prev = seen[source]
            if prev == entry then
                return 'cannot embed ' .. quote(entry) .. ' twice'
            elseif prev and source == entry then
                return 'cannot embed ' .. quote(source) ..
                           ': it is already embedded through ' .. quote(prev)
            elseif prev and source == prev then
                return 'cannot embed ' .. quote(source) ..
                           ': it is already embedded through ' .. quote(entry)
            elseif prev then
                return 'cannot embed ' .. quote(source) .. ' twice: through ' ..
                           quote(prev) .. ' and ' .. quote(entry)
            end
        end
        for _, link in ipairs(chain) do
            seen[link.source] = entry
        end
    end
    return nil
end

--- apply_mixins applies the mixins, the chains of the mixins of embeds,
--- to the grammar, adding their warnings to warnings, and returns nil, or
--- an error message that starts with the source of the mixin.
--- @param grammar table
--- @param mixins table[][]
--- @param warnings table[]
--- @return string? err
local function apply_mixins(grammar, mixins, warnings)
    local err = check_duplicates(mixins)
    if err then
        return err
    end
    for _, chain in ipairs(mixins) do
        for _, link in ipairs(chain) do
            err = apply(grammar, difference(link.diff), '', true, {
                source = link.source,
                warnings = warnings,
            })
            if err then
                return link.source .. ': ' .. err
            end
        end
    end
    return nil
end

--- extend returns a copy of the grammar base with the mixins and then the
--- difference table diff applied, the warnings of the mixins, or nil and
--- an error message. Each item of mixins is the chain of a mixin of embeds,
--- an array of { source = name, diff = difference table } from the mixin
--- that extends no other one; the error message of a mixin starts with its
--- source. Of the fields of OWN_FIELDS, only diff.lexogram (which replaces
--- the version of the base), diff.name and diff.version are taken: the
--- result has the name and version of diff only.
--- @param base table
--- @param diff table
--- @param mixins table[][]?
--- @return table? grammar
--- @return string? err
--- @return table[]? warnings { severity, code, path, message, source }
local function extend(base, diff, mixins)
    local grammar = copy(base, {})
    grammar.name, grammar.version = nil, nil
    local warnings = {}
    if mixins then
        local err = apply_mixins(grammar, mixins, warnings)
        if err then
            return nil, err
        end
    end
    for k in next, COPIED do
        local v = rawget(diff, k)
        if v ~= nil then
            grammar[k] = copy(v, {})
        end
    end
    local err = apply(grammar, difference(diff), '', true)
    if err then
        return nil, err
    end
    return grammar, nil, warnings
end

--- embed returns a copy of the grammar def, which extends no other one,
--- with the mixins applied (see extend) and without its embeds field, the
--- warnings of the mixins, or nil and an error message.
--- @param def table
--- @param mixins table[][]
--- @return table? grammar
--- @return string? err
--- @return table[]? warnings { severity, code, path, message, source }
local function embed(def, mixins)
    local grammar = copy(def, {})
    grammar.embeds = nil
    local warnings = {}
    local err = apply_mixins(grammar, mixins, warnings)
    if err then
        return nil, err
    end
    return grammar, nil, warnings
end

return {
    extend = extend,
    embed = embed,
    validate = validate,
    embeds = embeds,
}
