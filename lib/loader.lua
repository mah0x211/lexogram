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
-- lexogram.loader: loads grammar files. A grammar file is a Lua chunk that
-- returns one table. It runs in an isolated global environment that holds
-- only import, pairs and ipairs; reading any other global or assigning any
-- global is an error. The isolation keeps grammar files declarative; it is
-- not a security sandbox (string methods stay reachable through string
-- values, and loops are not bounded).
--
-- Names of other grammars (the argument of import and the extends field)
-- are resolved the same way: "name" or "dir/name" is the file name.lua
-- below the directory of the file that writes it (each part matches
-- ^[A-Za-z0-9_-]+$, so a name cannot go up, be absolute or hold a drive),
-- and "lexogram:name" is the built-in grammar of the module
-- lexogram.grammars.name, read with require (see lexogram.grammar). A
-- grammar whose table has extends is merged into a copy of that grammar,
-- and of the mixins it embeds (embeds), by lexogram.extend after the file
-- has run. A file whose table has mixin is a mixin: its metadata and the
-- shape of its difference are checked, and the mixin it extends is
-- resolved, but it is not a grammar: it can be embedded only, and neither
-- loaded nor imported nor extended by a grammar.
local type = type
local error = error
local pcall = pcall
local next = next
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable
local open = io.open
local find = string.find
local gsub = string.gsub
local match = string.match
local gmatch = string.gmatch
local byte = string.byte
local rawget = rawget
local concat = table.concat
local getinfo = debug.getinfo
local load_text = require('lexogram.compat').load_text
local extend = require('lexogram.extend')
local grammar_module = require('lexogram.grammar')
local builtin_value = grammar_module.builtin_value
local check_mixin = grammar_module.check_mixin

-- Pattern of a part of a grammar name.
local PART = '[A-Za-z0-9_-]+'

--- deep_copy returns a copy of v. Tables are copied recursively, including
--- table keys; shared and cyclic references are preserved through seen.
--- Metatables are not copied.
--- @param v any
--- @param seen table map from original tables to their copies
--- @return any
local function deep_copy(v, seen)
    if type(v) ~= 'table' then
        return v
    elseif seen[v] then
        return seen[v]
    end

    local copy = {}
    seen[v] = copy
    for k, val in next, v do
        copy[deep_copy(k, seen)] = deep_copy(val, seen)
    end
    return copy
end

--- read_file returns the content of the file at pathname.
--- @param pathname string
--- @return string? src
--- @return string? err
local function read_file(pathname)
    local f, err = open(pathname, 'rb')
    if not f then
        return nil, err
    end

    local src
    src, err = f:read('*a')
    f:close()
    if not src then
        return nil, pathname .. ': ' .. tostring(err)
    end
    return src
end

--- dirname returns the part of pathname up to and including the last "/"
--- or "\", or an empty string if there is none.
--- @param pathname string
--- @return string
local function dirname(pathname)
    return match(pathname, '^(.*[/\\])') or ''
end

--- new_env returns a fresh isolated environment that holds import, pairs
--- and ipairs. Reading another global or assigning any global raises an
--- error at the level of the accessing code.
--- @param import function
--- @return table
local function new_env(import)
    local names = {
        import = import,
        pairs = pairs,
        ipairs = ipairs,
    }
    return setmetatable({}, {
        __index = function(_, name)
            local v = names[name]
            if v == nil then
                error("undefined variable '" .. tostring(name) .. "'", 2)
            end
            return v
        end,
        __newindex = function(_, name)
            error("assignment to global variable '" .. tostring(name) .. "'", 2)
        end,
    })
end

--- raise_import_error raises msg for an import call made by the file at
--- pathname. The line of the call is added when it is known; after a tail
--- call (return import(...)) it is not, so only the pathname is added.
--- @param pathname string the importing file
--- @param msg string
local function raise_import_error(pathname, msg)
    -- level 1 is this function, 2 is import and 3 is the caller of import
    local info = getinfo(3, 'Sl')
    if info and info.source == '@' .. pathname and info.currentline > 0 then
        error(pathname .. ':' .. info.currentline .. ': ' .. msg, 0)
    end
    error(pathname .. ': ' .. msg, 0)
end

--- describe_name returns a printable form of an import name.
--- @param name any
--- @return string
local function describe_name(name)
    if type(name) == 'string' then
        return '"' .. name .. '"'
    end
    return type(name)
end

local load_file

--- resolve returns the pathname of the grammar name written in the file at
--- pathname, or nil if name is not a valid name. A name is "lexogram:" and
--- one part, or parts separated by "/"; a part matches ^[A-Za-z0-9_-]+$,
--- so a name cannot contain "\", ".", whitespace, control characters or a
--- NUL byte, and therefore cannot go up (".."), be absolute, hold a drive
--- or be cut by a C library.
--- @param pathname string
--- @param name any
--- @return string? resolved the pathname, or the name of a built-in
--- grammar ("lexogram:name")
local function resolve(pathname, name)
    if type(name) ~= 'string' then
        return nil
    elseif find(name, '^lexogram:' .. PART .. '$') then
        return name
    elseif find(name, '^' .. PART .. '$') or
        find(name, '^' .. PART .. '/[A-Za-z0-9_/-]*[A-Za-z0-9_-]$') and
        not find(name, '//', 1, true) then
        return dirname(pathname) .. name .. '.lua'
    end
    return nil
end

--- get_value returns a copy of the grammar at resolved and "grammar", or
--- the chain of the mixin at resolved (an array of { source, diff }, see
--- lexogram.extend) and "mixin", loading it once per top-level load; or
--- nil and an error message (circular is the word used in the message
--- about a cycle).
--- @param state table
--- @param resolved string
--- @param circular string
--- @return table? value
--- @return string? err
--- @return string? kind "grammar" or "mixin"
local function get_value(state, resolved, circular)
    local name = match(resolved, '^lexogram:(.*)$')
    if name then
        -- a new copy on each call (a built-in grammar extends no grammar)
        return builtin_value(name)
    elseif state.active[resolved] then
        return nil,
               'circular ' .. circular .. ': ' .. concat(state.stack, ' -> ') ..
                   ' -> ' .. resolved
    end
    local entry = state.cache[resolved]
    if not entry then
        local value, err, kind = load_file(state, resolved)
        if not value then
            return nil, err
        end
        entry = {
            value = value,
            kind = kind,
        }
        state.cache[resolved] = entry
    end
    return deep_copy(entry.value, {}), nil, entry.kind
end

--- new_import returns the import function for the file at pathname.
--- @param state table state of the current top-level load
--- @param pathname string the importing file
--- @return function
local function new_import(state, pathname)
    return function(name)
        local resolved = resolve(pathname, name)
        if not resolved then
            raise_import_error(pathname,
                               'invalid import name: ' .. describe_name(name))
        end
        local tbl, err, kind = get_value(state, resolved, 'import')
        if not tbl then
            if state.active[resolved] then
                raise_import_error(pathname, err)
            end
            raise_import_error(pathname,
                               'cannot import ' .. describe_name(name) .. ': ' ..
                                   err)
        elseif kind ~= 'grammar' then
            raise_import_error(pathname,
                               'cannot import ' .. describe_name(name) ..
                                   ': it is a mixin')
        end
        return tbl
    end
end

--- get_named returns the value and the kind of the grammar or mixin name
--- written in the field field (extends or embeds) of the file at pathname,
--- or nil and an error message that starts with pathname.
--- @param state table
--- @param pathname string
--- @param name any
--- @param field string
--- @return table? value
--- @return string? err
--- @return string? kind
local function get_named(state, pathname, name, field)
    local resolved = resolve(pathname, name)
    if not resolved then
        return nil, pathname .. ': invalid ' .. field .. ' name: ' ..
                   describe_name(name)
    end
    local value, err, kind = get_value(state, resolved, field)
    if not value then
        if state.active[resolved] then
            return nil, pathname .. ': ' .. err
        end
        return nil,
               pathname .. ': cannot ' ..
                   (field == 'extends' and 'extend ' or 'embed ') ..
                   describe_name(name) .. ': ' .. err
    end
    return value, nil, kind
end

--- resolve_extends merges the grammar diff of the file at pathname into a
--- copy of the grammar it extends and of the mixins it embeds; the
--- warnings of the mixins are added to state.warnings.
--- @param state table
--- @param pathname string
--- @param diff table
--- @return table? grammar
--- @return string? err
local function resolve_extends(state, pathname, diff)
    local name = rawget(diff, 'extends')
    local base, err, kind = get_named(state, pathname, name, 'extends')
    if not base then
        return nil, err
    elseif kind ~= 'grammar' then
        return nil, pathname .. ': cannot extend ' .. describe_name(name) ..
                   ': it is a mixin (embed it with embeds)'
    end
    local mixins
    if rawget(diff, 'embeds') ~= nil then
        local names
        names, err = extend.embeds(diff)
        if not names then
            return nil, pathname .. ': ' .. err
        end
        mixins = {}
        for i, v in ipairs(names) do
            local chain
            chain, err, kind = get_named(state, pathname, v, 'embeds')
            if not chain then
                return nil, err
            elseif kind ~= 'mixin' then
                return nil, pathname .. ': cannot embed ' .. describe_name(v) ..
                           ': it is not a mixin'
            end
            mixins[i] = chain
        end
    end
    local grammar, warnings
    grammar, err, warnings = extend.extend(base, diff, mixins)
    if not grammar then
        return nil, pathname .. ': ' .. err
    end
    local list = state.warnings
    for _, w in ipairs(warnings) do
        list[#list + 1] = w
    end
    return grammar
end

--- resolve_mixin checks the mixin def of the file at pathname and returns
--- its chain (see get_value), or nil and an error message.
--- @param state table
--- @param pathname string
--- @param def table
--- @return table[]? chain
--- @return string? err
local function resolve_mixin(state, pathname, def)
    local err = check_mixin(def)
    if err then
        return nil, (gsub(err, '[^\n]+', pathname .. ': %0'))
    end
    local chain = {}
    local name = rawget(def, 'extends')
    if name ~= nil then
        local kind
        chain, err, kind = get_named(state, pathname, name, 'extends')
        if not chain then
            return nil, err
        elseif kind ~= 'mixin' then
            return nil, pathname .. ': cannot extend ' .. describe_name(name) ..
                       ': it is not a mixin'
        end
    end
    chain[#chain + 1] = {
        source = pathname,
        diff = def,
    }
    return chain
end

--- run_chunk runs the compiled grammar fn of the file at pathname, and
--- resolves its extends and embeds, while the file is marked as being
--- loaded. It returns the grammar and "grammar", the chain of a mixin and
--- "mixin", or nil and an error message.
--- @param state table
--- @param pathname string
--- @param fn function
--- @return table? value
--- @return string? err
--- @return string? kind
local function run_chunk(state, pathname, fn)
    local stack = state.stack
    state.active[pathname] = true
    stack[#stack + 1] = pathname
    local ok, res = pcall(fn)
    local err
    local kind = 'grammar'
    if not ok then
        res, err = nil, tostring(res)
    elseif type(res) ~= 'table' then
        res, err = nil, pathname .. ': grammar must return a table, got ' ..
                       type(res)
    elseif rawget(res, 'mixin') ~= nil then
        res, err = resolve_mixin(state, pathname, res)
        kind = 'mixin'
    elseif rawget(res, 'extends') ~= nil then
        res, err = resolve_extends(state, pathname, res)
    elseif rawget(res, 'embeds') ~= nil then
        res, err = nil, pathname .. ': embeds needs extends'
    end
    stack[#stack] = nil
    state.active[pathname] = nil
    if not res then
        return nil, err
    end
    return res, nil, kind
end

--- load_file loads the grammar or mixin file at pathname within state (see
--- run_chunk).
--- @param state table
--- @param pathname string
--- @return table? value
--- @return string? err
--- @return string? kind
function load_file(state, pathname)
    local src, err = read_file(pathname)
    if not src then
        return nil, err
    end

    local fn
    fn, err = load_text(src, '@' .. pathname,
                        new_env(new_import(state, pathname)))
    if not fn then
        return nil, err
    end

    return run_chunk(state, pathname, fn)
end

--- normalize returns pathname with empty and "." segments removed: repeated
--- and trailing "/" are collapsed and "./" is dropped. ".." segments are
--- kept unchanged, because removing "dir/.." lexically gives a different
--- file when dir is a symbolic link. Only "/" is treated as a separator. An
--- empty result is "." for a relative pathname and "/" for an absolute one.
--- @param pathname string
--- @return string
local function normalize(pathname)
    local segments = {}
    for segment in gmatch(pathname, '[^/]+') do
        if segment ~= '.' then
            segments[#segments + 1] = segment
        end
    end

    local path = concat(segments, '/')
    if byte(pathname, 1) == 47 then -- "/"
        return '/' .. path
    elseif path == '' then
        return '.'
    end
    return path
end

-- The error of loading a mixin as a grammar.
local NOT_A_GRAMMAR = ': a mixin is not a grammar (embed it with embeds)'

--- load loads the grammar file at pathname and returns the table it
--- returns, merged into the grammar it extends and the mixins it embeds if
--- it has extends, or a new copy of the built-in grammar when pathname is
--- "lexogram:name"; and nil and the warnings of the mixins (see
--- lexogram.extend), which are none for a built-in grammar. Imported and
--- extended files are executed at most once per call. The pathname is
--- normalized first and the normalized form is used everywhere, including
--- in error messages.
--- @param pathname string
--- @return table? grammar
--- @return string? err
--- @return table[]? warnings
local function load(pathname)
    if type(pathname) ~= 'string' then
        error('pathname must be string, got ' .. type(pathname), 2)
    elseif find(pathname, '\0', 1, true) then
        -- the C library would cut the pathname at the NUL byte and open a
        -- different file than the caller validated
        return nil, 'pathname must not contain a NUL byte'
    end

    local name = match(pathname, '^lexogram:(' .. PART .. ')$')
    if name then
        local grammar, err, kind = builtin_value(name)
        if not grammar then
            return nil, pathname .. ': ' .. err
        elseif kind ~= 'grammar' then
            return nil, pathname .. NOT_A_GRAMMAR
        end
        return grammar, nil, {}
    end

    local state = {
        -- resolved pathname -> { value, kind } of the imported, extended or
        -- embedded file
        cache = {},
        -- pathnames of the files being loaded, outermost first
        stack = {},
        -- set of the pathnames in stack
        active = {},
        -- warnings of the mixins, in the order they were applied
        warnings = {},
    }
    pathname = normalize(pathname)
    local grammar, err, kind = load_file(state, pathname)
    if not grammar then
        return nil, err
    elseif kind ~= 'grammar' then
        return nil, pathname .. NOT_A_GRAMMAR
    end
    return grammar, nil, state.warnings
end

return {
    load = load,
}
