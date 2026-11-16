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
local concat = table.concat
local getinfo = debug.getinfo
local load_text = require('lexogram.compat').load_text

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

--- new_import returns the import function for the file at pathname.
--- An import can only reach <name>.lua in the directory of the importing
--- file: the name must match ^[A-Za-z0-9_-]+$, so it cannot contain a
--- separator ("/" or "\"), ".", ":", whitespace, control characters or a
--- NUL byte, and therefore cannot be "..", an absolute path, a drive or a
--- path that a C library would truncate.
--- @param state table state of the current top-level load
--- @param pathname string the importing file
--- @return function
local function new_import(state, pathname)
    local dir = dirname(pathname)
    return function(name)
        if type(name) ~= 'string' or not find(name, '^[A-Za-z0-9_-]+$') then
            raise_import_error(pathname,
                               'invalid import name: ' .. describe_name(name))
        end

        local resolved = dir .. name .. '.lua'
        if state.active[resolved] then
            raise_import_error(pathname, 'circular import: ' ..
                                   concat(state.stack, ' -> ') .. ' -> ' ..
                                   resolved)
        end

        local tbl = state.cache[resolved]
        if not tbl then
            local err
            tbl, err = load_file(state, resolved)
            if not tbl then
                raise_import_error(pathname, 'cannot import ' ..
                                       describe_name(name) .. ': ' .. err)
            end
            state.cache[resolved] = tbl
        end
        return deep_copy(tbl, {})
    end
end

--- run_chunk runs the compiled grammar fn of the file at pathname while
--- the file is marked as being loaded.
--- @param state table
--- @param pathname string
--- @param fn function
--- @return boolean ok
--- @return any result or error
local function run_chunk(state, pathname, fn)
    local stack = state.stack
    state.active[pathname] = true
    stack[#stack + 1] = pathname
    local ok, res = pcall(fn)
    stack[#stack] = nil
    state.active[pathname] = nil
    return ok, res
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

    local ok, res = run_chunk(state, pathname, fn)
    if not ok then
        return nil, tostring(res)
    elseif type(res) ~= 'table' then
        return nil,
               pathname .. ': grammar must return a table, got ' .. type(res)
    end
    return res
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

--- load loads the grammar file at pathname and returns the table it
--- returns. Imported files are executed at most once per call. The
--- pathname is normalized first and the normalized form is used everywhere,
--- including in error messages.
--- @param pathname string
--- @return table? grammar
--- @return string? err
local function load(pathname)
    if type(pathname) ~= 'string' then
        error('pathname must be string, got ' .. type(pathname), 2)
    elseif find(pathname, '\0', 1, true) then
        -- the C library would cut the pathname at the NUL byte and open a
        -- different file than the caller validated
        return nil, 'pathname must not contain a NUL byte'
    end

    return load_file({
        -- resolved pathname -> table returned by the imported file
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
