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
-- the definition, nil and the diagnostics (warnings only), or nil, a
-- message and the diagnostics. The function is
-- compiled from the Lua source of the grammar (see lexogram.source): each
-- call runs the table constructors, without walking a table to copy it.
--
-- A grammar may embed built-in mixins (embeds), which it needs extends for.
-- A built-in mixin (mixin = true, see lexogram.extend) is defined the same
-- way: the function checks its metadata and the shape of its difference,
-- and returns a function that returns a new copy of the mixin as written.
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
local check = require('lexogram.check')
local extend = require('lexogram.extend')

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
    elseif rawget(grammar, 'name') ~= name then
        return nil,
               'module lexogram.grammars.' .. name .. ' defines the grammar ' ..
                   tostring(rawget(grammar, 'name'))
    end
    return grammar
end

--- builtin_name returns the name of the built-in grammar or mixin v
--- ("lexogram:<name>"), or nil.
--- @param v any
--- @return string?
local function builtin_name(v)
    return type(v) == 'string' and match(v, '^lexogram:([A-Za-z0-9_-]+)$') or
               nil
end

--- chain_of returns the chain of the built-in mixin def named name: the
--- mixins it extends, from the one that extends no other, and then def,
--- each as { source = "lexogram:<name>", diff = mixin }; or nil and an
--- error message.
--- @param name string
--- @param def table
--- @return table[]? chain
--- @return string? err
local function chain_of(name, def)
    local chain = {}
    local base = rawget(def, 'extends')
    if base ~= nil then
        local base_name = builtin_name(base)
        if not base_name then
            return nil,
                   'extends must name a built-in mixin' ..
                       ' ("lexogram:<name>"), got ' .. tostring(base)
        end
        local base_def, err = builtin(base_name)
        if not base_def then
            return nil, 'cannot extend "' .. base .. '": ' .. err
        elseif rawget(base_def, 'mixin') ~= true then
            return nil, 'cannot extend "' .. base .. '": it is not a mixin'
        end
        chain, err = chain_of(base_name, base_def)
        if not chain then
            return nil, err
        end
    end
    chain[#chain + 1] = {
        source = 'lexogram:' .. name,
        diff = def,
    }
    return chain
end

--- builtin_value returns a new copy of the built-in grammar name and
--- "grammar", the chain of the built-in mixin name (see chain_of) and
--- "mixin", or nil and an error message.
--- @param name string the part after "lexogram:"
--- @return table? value
--- @return string? err
--- @return string? kind "grammar" or "mixin"
local function builtin_value(name)
    local def, err = builtin(name)
    if not def then
        return nil, err
    elseif rawget(def, 'mixin') ~= true then
        return def, nil, 'grammar'
    end
    local chain
    chain, err = chain_of(name, def)
    if not chain then
        return nil, err
    end
    return chain, nil, 'mixin'
end

--- error_lines returns the errors of diagnostics, one line each, or nil.
--- @param diagnostics table[]
--- @return string?
local function error_lines(diagnostics)
    local lines = {}
    for _, d in ipairs(diagnostics) do
        if d.severity == 'error' then
            lines[#lines + 1] = d.path .. ': ' .. d.message
        end
    end
    if #lines > 0 then
        return concat(lines, '\n')
    end
    return nil
end

--- check_mixin checks the metadata of the mixin def and the shape of its
--- difference, and returns nil, or an error message (one line per error)
--- and, for errors of the metadata, their diagnostics.
--- @param def table
--- @return string? err
--- @return table[]? diagnostics
local function check_mixin(def)
    local diagnostics = check.mixin(def)
    local err = error_lines(diagnostics)
    if err then
        return err, diagnostics
    end
    return extend.validate(def)
end

--- compile_function returns the function that returns a new copy of tbl,
--- compiled from its Lua source, or nil and an error message.
--- @param tbl table
--- @return function? fn
--- @return string? err
local function compile_function(tbl)
    local src, err = write(tbl, {})
    if not src then
        return nil, err
    end
    -- the chunk name tells the grammar and its version in error messages
    -- and tracebacks ("@" is not a character of a name or a version)
    local chunk = assert(load_text('return function()\n' .. src .. 'end\n',
                                   '=lexogram.grammar:' .. tbl.name .. '@' ..
                                       tbl.version, {}))
    return chunk()
end

--- new_mixin checks the mixin def and returns a function that returns a new
--- copy of it on each call, nil and an empty array of diagnostics, or nil,
--- an error message and, for errors of the metadata, their diagnostics.
--- @param def table
--- @return function? fn
--- @return string? err
--- @return table[]? diagnostics
local function new_mixin(def)
    local err, diagnostics = check_mixin(def)
    if err then
        return nil, err, diagnostics
    end
    local base = rawget(def, 'extends')
    if base ~= nil then
        local name = builtin_name(base)
        if not name then
            return nil, 'extends must name a built-in mixin' ..
                       ' ("lexogram:<name>"), got ' .. base
        end
        local _, kind
        _, err, kind = builtin_value(name)
        if err then
            return nil, 'cannot extend "' .. base .. '": ' .. err
        elseif kind ~= 'mixin' then
            return nil, 'cannot extend "' .. base .. '": it is not a mixin'
        end
    end
    local fn
    fn, err = compile_function(def)
    if not fn then
        return nil, err
    end
    return fn, nil, {}
end

--- embedded returns the chains of the built-in mixins that the grammar def
--- embeds (see lexogram.extend), or nil and an error message.
--- @param def table
--- @return table[][]? mixins
--- @return string? err
local function embedded(def)
    local names, err = extend.embeds(def)
    if not names then
        return nil, err
    end
    local mixins = {}
    for i, v in ipairs(names) do
        local name = builtin_name(v)
        if not name then
            return nil,
                   'embeds must name built-in mixins' ..
                       ' ("lexogram:<name>"), got ' .. tostring(v)
        end
        local chain, kind
        chain, err, kind = builtin_value(name)
        if not chain then
            return nil, 'cannot embed "' .. v .. '": ' .. err
        elseif kind ~= 'mixin' then
            return nil, 'cannot embed "' .. v .. '": it is not a mixin'
        end
        mixins[i] = chain
    end
    return mixins
end

--- new checks the grammar def, merged into the grammar it extends and the
--- mixins it embeds if it has extends, and returns a function that returns
--- a new copy of the result on each call, nil and the diagnostics: the
--- warnings of the mixins, in the order they were applied, and then those
--- of the check. On an error it returns nil, a message (one line per
--- error, for assert) and, when the check ran, its diagnostics. A mixin
--- def is checked by new_mixin.
--- @param def table
--- @return function? fn
--- @return string? err
--- @return table[]? diagnostics
local function new(def)
    if type(def) ~= 'table' then
        return nil, 'grammar must be a table, got ' .. type(def)
    elseif rawget(def, 'mixin') ~= nil then
        return new_mixin(def)
    end
    local grammar = def
    local warnings = {}
    local base = rawget(def, 'extends')
    if base ~= nil then
        local name = builtin_name(base)
        if not name then
            return nil,
                   'extends must name a built-in grammar' ..
                       ' ("lexogram:<name>"), got ' .. tostring(base)
        end
        local value, err, kind = builtin_value(name)
        if not value then
            return nil, 'cannot extend "' .. base .. '": ' .. err
        elseif kind ~= 'grammar' then
            return nil, 'cannot extend "' .. base ..
                       '": it is a mixin (embed it with embeds)'
        end
        local mixins
        if rawget(def, 'embeds') ~= nil then
            mixins, err = embedded(def)
            if not mixins then
                return nil, err
            end
        end
        grammar, err, warnings = extend.extend(value, def, mixins)
        if not grammar then
            return nil, err
        end
    elseif rawget(def, 'embeds') ~= nil then
        return nil, 'embeds needs extends'
    end

    local diagnostics = check.check(grammar)
    local err = error_lines(diagnostics)
    if err then
        return nil, err, diagnostics
    end
    for _, d in ipairs(diagnostics) do
        warnings[#warnings + 1] = d
    end
    -- a grammar that passed every check holds only strings, booleans and
    -- tables, which all have source text
    return assert(compile_function(grammar)), nil, warnings
end

return setmetatable({
    new = new,
    builtin = builtin,
    builtin_value = builtin_value,
    check_mixin = check_mixin,
}, {
    __call = function(_, def)
        return new(def)
    end,
})
