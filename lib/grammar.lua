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
-- lexogram.grammar: defines a grammar as a Lua module.
--
-- A built-in grammar (lexogram.grammars.<name>, read as "lexogram:<name>")
-- is a module that returns the result of this function:
--
--   return assert(require('lexogram.grammar')({ ... }))
--
-- The function merges a grammar that extends another one (whose extends
-- must name a built-in grammar, since a module has no directory) and runs
-- every check of lexogram.check. It returns a function that returns a new
-- copy of the checked grammar on each call, so that no caller can change
-- the definition, or nil, a message and the diagnostics. The function is
-- compiled from the Lua source of the grammar (see lexogram.source): each
-- call runs the table constructors, without walking a table to copy it.
local type = type
local ipairs = ipairs
local rawget = rawget
local setmetatable = setmetatable
local pcall = pcall
local tostring = tostring
local require = require
local concat = table.concat
local sub = string.sub
local match = string.match
local load_text = require('lexogram.compat').load_text
local write = require('lexogram.source').write
local check = require('lexogram.check').check
local extend = require('lexogram.extend').extend

--- builtin returns a new copy of the built-in grammar name, or nil and an
--- error message.
--- @param name string the part after "lexogram:"
--- @return table? grammar
--- @return string? err
local function builtin(name)
    local module = 'lexogram.grammars.' .. name
    local ok, fn = pcall(require, module)
    if not ok then
        local msg = tostring(fn)
        -- the rest of the message of require lists the places it looked in,
        -- which differ by environment
        local prefix = "module '" .. module .. "' not found"
        if sub(msg, 1, #prefix) == prefix then
            return nil,
                   'no built-in grammar named "' .. name .. '" (module ' ..
                       module .. ' not found)'
        end
        return nil, msg
    elseif type(fn) ~= 'function' then
        return nil,
               'module lexogram.grammars.' .. name ..
                   ' must return a function, got ' .. type(fn)
    end
    local grammar = fn()
    if type(grammar) ~= 'table' then
        return nil, 'module lexogram.grammars.' .. name ..
                   ' must return a function that returns a table, got ' ..
                   type(grammar)
    end
    return grammar
end

--- new checks the grammar def, merged into the grammar it extends if it
--- has extends, and returns a function that returns a new copy of the
--- result on each call. On an error it returns nil, a message (one line
--- per error, for assert) and, when the check ran, its diagnostics.
--- @param def table
--- @return function? fn
--- @return string? err
--- @return table[]? diagnostics
local function new(def)
    if type(def) ~= 'table' then
        return nil, 'grammar must be a table, got ' .. type(def)
    end
    local grammar = def
    local base = rawget(def, 'extends')
    if base ~= nil then
        local name = type(base) == 'string' and
                         match(base, '^lexogram:([A-Za-z0-9_-]+)$')
        if not name then
            return nil,
                   'extends must name a built-in grammar' ..
                       ' ("lexogram:<name>"), got ' .. tostring(base)
        end
        local err
        grammar, err = builtin(name)
        if not grammar then
            return nil, 'cannot extend "' .. base .. '": ' .. err
        end
        grammar, err = extend(grammar, def)
        if not grammar then
            return nil, err
        end
    end

    local diagnostics = check(grammar)
    local lines = {}
    for _, d in ipairs(diagnostics) do
        if d.severity == 'error' then
            lines[#lines + 1] = d.path .. ': ' .. d.message
        end
    end
    if #lines > 0 then
        return nil, concat(lines, '\n'), diagnostics
    end
    -- a grammar that passed every check holds only strings, booleans and
    -- tables, which all have source text
    local src = assert(write(grammar, {}))
    local chunk = assert(load_text('return function()\n' .. src .. 'end\n',
                                   '=lexogram.grammar', {}))
    return chunk()
end

return setmetatable({
    new = new,
    builtin = builtin,
}, {
    __call = function(_, def)
        return new(def)
    end,
})
