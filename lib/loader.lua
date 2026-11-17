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
-- and "lexogram:name" is the built-in grammar name.lua installed in the
-- grammars directory next to this module (lexogram/grammars/). A grammar
-- whose table has extends is merged into a copy of that grammar by
-- lexogram.extend after the file has run.
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
local match = string.match
local gmatch = string.gmatch
local byte = string.byte
local sub = string.sub
local rawget = rawget
local concat = table.concat
local getinfo = debug.getinfo
local load_text = require('lexogram.compat').load_text
local extend = require('lexogram.extend').extend

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
--- @param state table
--- @param pathname string
--- @param name any
--- @return string? resolved
--- @return string? err set when name is valid but cannot be resolved
local function resolve(state, pathname, name)
    if type(name) ~= 'string' then
        return nil
    end
    local builtin = match(name, '^lexogram:(' .. PART .. ')$')
    if builtin then
        if not state.builtin then
            return nil, 'built-in grammars are not available: ' ..
                       'lexogram.loader was not loaded from a file'
        end
        return state.builtin .. builtin .. '.lua'
    elseif find(name, '^' .. PART .. '$') or
        find(name, '^' .. PART .. '/[A-Za-z0-9_/-]*[A-Za-z0-9_-]$') and
        not find(name, '//', 1, true) then
        return dirname(pathname) .. name .. '.lua'
    end
    return nil
end

--- get_grammar returns a copy of the grammar at resolved, loading it once
--- per top-level load, or nil and an error message (circular is the word
--- used in the message about a cycle).
--- @param state table
--- @param resolved string
--- @param circular string
--- @return table? grammar
--- @return string? err
local function get_grammar(state, resolved, circular)
    if state.active[resolved] then
        return nil,
               'circular ' .. circular .. ': ' .. concat(state.stack, ' -> ') ..
                   ' -> ' .. resolved
    end
    local tbl = state.cache[resolved]
    if not tbl then
        local err
        tbl, err = load_file(state, resolved)
        if not tbl then
            return nil, err
        end
        state.cache[resolved] = tbl
    end
    return deep_copy(tbl, {})
end

--- new_import returns the import function for the file at pathname.
--- @param state table state of the current top-level load
--- @param pathname string the importing file
--- @return function
local function new_import(state, pathname)
    return function(name)
        local resolved, why = resolve(state, pathname, name)
        if not resolved then
            raise_import_error(pathname, why or 'invalid import name: ' ..
                                   describe_name(name))
        end
        local tbl, err = get_grammar(state, resolved, 'import')
        if not tbl then
            if state.active[resolved] then
                raise_import_error(pathname, err)
            end
            raise_import_error(pathname,
                               'cannot import ' .. describe_name(name) .. ': ' ..
                                   err)
        end
        return tbl
    end
end

--- resolve_extends merges the grammar diff of the file at pathname into a
--- copy of the grammar it extends.
--- @param state table
--- @param pathname string
--- @param diff table
--- @return table? grammar
--- @return string? err
local function resolve_extends(state, pathname, diff)
    local name = rawget(diff, 'extends')
    local resolved, why = resolve(state, pathname, name)
    if not resolved then
        return nil, pathname .. ': ' ..
                   (why or 'invalid extends name: ' .. describe_name(name))
    end
    local base, err = get_grammar(state, resolved, 'extends')
    if not base then
        if state.active[resolved] then
            return nil, pathname .. ': ' .. err
        end
        return nil, pathname .. ': cannot extend ' .. describe_name(name) ..
                   ': ' .. err
    end
    local grammar
    grammar, err = extend(base, diff)
    if not grammar then
        return nil, pathname .. ': ' .. err
    end
    return grammar
end

--- run_chunk runs the compiled grammar fn of the file at pathname, and
--- resolves its extends, while the file is marked as being loaded.
--- @param state table
--- @param pathname string
--- @param fn function
--- @return table? grammar
--- @return string? err
local function run_chunk(state, pathname, fn)
    local stack = state.stack
    state.active[pathname] = true
    stack[#stack + 1] = pathname
    local ok, res = pcall(fn)
    local err
    if not ok then
        res, err = nil, tostring(res)
    elseif type(res) ~= 'table' then
        res, err = nil, pathname .. ': grammar must return a table, got ' ..
                       type(res)
    elseif rawget(res, 'extends') ~= nil then
        res, err = resolve_extends(state, pathname, res)
    end
    stack[#stack] = nil
    state.active[pathname] = nil
    return res, err
end

--- load_file loads the grammar file at pathname within state.
--- @param state table
--- @param pathname string
--- @return table? grammar
--- @return string? err
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

--- builtin_dir returns the directory of the built-in grammars: grammars/
--- next to this module, or nil when the module was not loaded from a file.
--- @return string?
local function builtin_dir()
    local source = getinfo(1, 'S').source
    if byte(source, 1) == 64 then -- "@"
        return dirname(sub(source, 2)) .. 'grammars/'
    end
    return nil
end

local BUILTIN_DIR = builtin_dir()

--- load loads the grammar file at pathname and returns the table it
--- returns, merged into the grammar it extends if it has extends. Imported
--- and extended files are executed at most once per call. The pathname is
--- normalized first and the normalized form is used everywhere, including
--- in error messages.
--- @param pathname string
--- @param builtin string? for tests only: the directory of the built-in
--- grammars (with a trailing "/") instead of the installed one
--- @return table? grammar
--- @return string? err
local function load(pathname, builtin)
    if type(pathname) ~= 'string' then
        error('pathname must be string, got ' .. type(pathname), 2)
    elseif find(pathname, '\0', 1, true) then
        -- the C library would cut the pathname at the NUL byte and open a
        -- different file than the caller validated
        return nil, 'pathname must not contain a NUL byte'
    end

    return load_file({
        -- directory of the built-in grammars
        builtin = builtin or BUILTIN_DIR,
        -- resolved pathname -> grammar of the imported or extended file
        cache = {},
        -- pathnames of the files being loaded, outermost first
        stack = {},
        -- set of the pathnames in stack
        active = {},
    }, normalize(pathname))
end

return {
    load = load,
}
