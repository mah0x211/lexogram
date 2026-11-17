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
-- lexogram.source: writes a grammar table as Lua source text that returns
-- an equal table (used by lexogram.merge).
--
-- The output is the same for the same table on every runtime: fields of
-- the grammar come in the order of the specification, a delimited token
-- table starts with open, close, prefix, match and nest, and other keys
-- follow the items of the array part in a fixed order. A string is written
-- in single quotes when it needs no escape, otherwise in the long brackets
-- of the lowest level that its content allows, and with escapes when long
-- brackets would change it (a carriage return or another control byte
-- than tab and newline, or a newline at the start).
local type = type
local next = next
local ipairs = ipairs
local rawget = rawget
local tostring = tostring
local concat = table.concat
local sort = table.sort
local rep = string.rep
local find = string.find
local format = string.format
local gsub = string.gsub
local match = string.match
local floor = math.floor
local huge = math.huge
local byte_less = require('lexogram.compat').byte_less

-- Order of the fields of a grammar, and of the keys of a delimited token
-- table.
local ROOT_ORDER = {
    'lexogram',
    'name',
    'version',
    'start',
    'tokens',
    'symbols',
    'keywords',
    'skip',
    'leading',
    'rules',
    'greedy',
    'recover',
}
local DELIMITED_ORDER = {
    'open',
    'close',
    'prefix',
    'match',
    'nest',
}

-- Reserved words of Lua 5.1 to 5.4, which cannot be written as bare keys.
local RESERVED = {}
for word in ('and break do else elseif end false for function goto if in' ..
                ' local nil not or repeat return then true until while'):gmatch(
                '%a+') do
    RESERVED[word] = true
end

-- Escapes of the bytes that are written with a backslash in quotes.
local ESCAPES = {
    ['\\'] = '\\\\',
    ["'"] = "\\'",
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

--- quoted returns s in single quotes with escapes; other control bytes are
--- written as three decimal digits.
--- @param s string
--- @return string
local function quoted(s)
    return "'" .. gsub(s, "[%c\\']", function(c)
        return ESCAPES[c] or format('\\%03d', c:byte())
    end) .. "'"
end

--- long_bracket returns s in the long brackets of the lowest level whose
--- close does not occur in s (nor at its end with the close).
--- @param s string
--- @return string
local function long_bracket(s)
    local level = 0
    while true do
        local eq = rep('=', level)
        local close = ']' .. eq .. ']'
        if find(s .. close, close, 1, true) == #s + 1 then
            return '[' .. eq .. '[' .. s .. close
        end
        level = level + 1
    end
end

--- string_literal returns s as a Lua string literal.
--- @param s string
--- @return string
local function string_literal(s)
    if not find(s, "[%c\\']") then
        return "'" .. s .. "'"
    elseif find(gsub(s, '[\t\n]', ''), '%c') or find(s, '^\n') then
        return quoted(s)
    end
    return long_bracket(s)
end

--- number_literal returns n as a Lua number literal, or nil if it has none.
--- @param n number
--- @return string?
local function number_literal(n)
    if n ~= n or n == huge or n == -huge then
        return nil
    elseif n == floor(n) and n > -2 ^ 53 and n < 2 ^ 53 then
        return format('%d', n)
    end
    return format('%.17g', n)
end

--- key_literal returns the key k as written before "=", or nil if it
--- cannot be written.
--- @param k any
--- @return string?
local function key_literal(k)
    local t = type(k)
    if t == 'string' then
        if match(k, '^[A-Za-z_][A-Za-z0-9_]*$') and not RESERVED[k] then
            return k
        end
        return '[' .. string_literal(k) .. ']'
    elseif t == 'number' then
        local n = number_literal(k)
        return n and '[' .. n .. ']'
    elseif t == 'boolean' then
        return '[' .. tostring(k) .. ']'
    end
    return nil
end

-- Rank of the key types in the order of the keys after the array part.
local TYPE_RANK = {
    number = 1,
    string = 2,
    boolean = 3,
}

--- key_less orders keys: numbers, then strings in byte order, then false
--- and true; other keys come last (they cannot be written).
--- @param a any
--- @param b any
--- @return boolean
local function key_less(a, b)
    local ra, rb = TYPE_RANK[type(a)] or 4, TYPE_RANK[type(b)] or 4
    if ra ~= rb then
        return ra < rb
    elseif ra == 1 then
        return a < b
    elseif ra == 2 then
        return byte_less(a, b)
    elseif ra == 3 then
        return not a and b
    end
    return false
end

--- ordered_keys returns the keys of t other than its array part 1..n, the
--- keys named in first (in that order) before the others.
--- @param t table
--- @param n integer
--- @param first string[]?
--- @return any[]
local function ordered_keys(t, n, first)
    local keys, taken = {}, {}
    for _, k in ipairs(first or {}) do
        if rawget(t, k) ~= nil then
            keys[#keys + 1] = k
            taken[k] = true
        end
    end
    local rest = {}
    for k in next, t do
        local item = type(k) == 'number' and k >= 1 and k <= n and k == floor(k)
        if not item and not taken[k] then
            rest[#rest + 1] = k
        end
    end
    sort(rest, key_less)
    for _, k in ipairs(rest) do
        keys[#keys + 1] = k
    end
    return keys
end

--- describe returns the path of key under path for messages.
--- @param path string
--- @param k any
--- @return string
local function describe(path, k)
    if type(k) == 'string' and match(k, '^[A-Za-z_][A-Za-z0-9_]*$') then
        return path == '' and k or path .. '.' .. k
    end
    return path .. '[' .. tostring(k) .. ']'
end

local write_value

--- write_table appends table t at indent level depth to out.
--- @param out string[]
--- @param t table
--- @param depth integer
--- @param path string
--- @param seen table tables being written
--- @param first string[]? keys of t written first
--- @param child_first string[]? keys written first in the tables in t
--- @return string? err
local function write_table(out, t, depth, path, seen, first, child_first)
    if seen[t] then
        return (path == '' and 'grammar' or path) ..
                   ': a table refers to itself'
    end
    local n = 0
    while rawget(t, n + 1) ~= nil do
        n = n + 1
    end
    local keys = ordered_keys(t, n, first)
    if n == 0 and #keys == 0 then
        out[#out + 1] = '{}'
        return nil
    end
    seen[t] = true
    local pad = rep('    ', depth + 1)
    out[#out + 1] = '{\n'
    for i = 1, n do
        out[#out + 1] = pad
        local err = write_value(out, rawget(t, i), depth + 1, describe(path, i),
                                seen)
        if err then
            return err
        end
        out[#out + 1] = ',\n'
    end
    for _, k in ipairs(keys) do
        local key = key_literal(k)
        if not key then
            return describe(path, k) .. ': a key of type ' .. type(k) ..
                       ' cannot be written'
        end
        out[#out + 1] = pad .. key .. ' = '
        -- the tables in tokens are delimited token tables
        local own, inner = child_first, nil
        if depth == 0 and k == 'tokens' then
            own, inner = nil, DELIMITED_ORDER
        end
        local err = write_value(out, rawget(t, k), depth + 1, describe(path, k),
                                seen, own, inner)
        if err then
            return err
        end
        out[#out + 1] = ',\n'
    end
    out[#out + 1] = rep('    ', depth) .. '}'
    seen[t] = nil
    return nil
end

--- write_value appends value v to out.
--- @param out string[]
--- @param v any
--- @param depth integer
--- @param path string
--- @param seen table
--- @param first string[]? keys written first when v is a table
--- @param child_first string[]? keys written first in the tables in v
--- @return string? err
function write_value(out, v, depth, path, seen, first, child_first)
    local t = type(v)
    if t == 'string' then
        out[#out + 1] = string_literal(v)
    elseif t == 'number' then
        local n = number_literal(v)
        if not n then
            return path .. ': the number ' .. tostring(v) ..
                       ' cannot be written'
        end
        out[#out + 1] = n
    elseif t == 'boolean' then
        out[#out + 1] = tostring(v)
    elseif t == 'table' then
        return write_table(out, v, depth, path, seen, first, child_first)
    else
        return path .. ': a value of type ' .. t .. ' cannot be written'
    end
    return nil
end

--- write returns the Lua source text of a chunk that returns the grammar
--- table grammar, after the comment lines of header (a control byte in a
--- line is written as a backslash and three decimal digits, so that a line
--- never ends the comment), or nil and an error
--- message for a value that cannot be written (a function, a table that
--- refers to itself, a table key, an infinite number or NaN).
--- @param grammar table
--- @param header string[] comment lines without "-- "
--- @return string? source
--- @return string? err
local function write(grammar, header)
    local out = {}
    for _, line in ipairs(header) do
        out[#out + 1] = '-- ' .. gsub(line, '%c', function(c)
            return format('\\%03d', c:byte())
        end) .. '\n'
    end
    out[#out + 1] = 'return '
    local err = write_table(out, grammar, 0, '', {}, ROOT_ORDER)
    if err then
        return nil, err
    end
    out[#out + 1] = '\n'
    return concat(out)
end

return {
    write = write,
}
