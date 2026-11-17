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
--
-- tools/conformance.lua: compares the sources that a grammar accepts with
-- the sources that the official compiler accepts (luac -p). Run it on a
-- machine with luac installed; it is not a module of the library.
--
--   lua tools/conformance.lua [--strip-bom] [--strip-shebang] <grammar>
--       <luac> [file ...]
--
-- <grammar> is a grammar file or a built-in grammar ("lexogram:lua51"),
-- <luac> the compiler of the matching Lua version. The files are read from
-- the arguments, or one per line from the standard input. Before parsing,
-- --strip-bom blanks a UTF-8 byte order mark at the start, as the file
-- loader of Lua 5.2 and later does, and --strip-shebang a first line that
-- starts with "#" (after the byte order mark), as the file loader of every
-- version does; use them for a grammar without such a leading token.
--
-- Each disagreement is printed as "lexogram-only <file>" (the grammar
-- accepts what luac rejects) or "official-only <file>" (the grammar
-- rejects what luac accepts), followed by a summary line. The exit status
-- is 1 when a file is official-only: the grammar must accept every valid
-- source, while lexogram-only files are the documented wider acceptance.
local lexogram = require('lexogram')

--- shell_quote returns s quoted for a POSIX shell.
--- @param s string
--- @return string
local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- official_accepts returns true if luac accepts the file at pathname.
--- @param luac string
--- @param pathname string
--- @return boolean
local function official_accepts(luac, pathname)
    local p = assert(io.popen(shell_quote(luac) .. ' -p ' ..
                                  shell_quote(pathname) .. ' 2>&1'))
    local out = p:read('*a')
    p:close()
    return out == ''
end

--- main runs the comparison and returns the exit status.
--- @param args string[]
--- @return integer
local function main(args)
    local bom, shebang = false, false
    while args[1] == '--strip-bom' or args[1] == '--strip-shebang' do
        if args[1] == '--strip-bom' then
            bom = true
        else
            shebang = true
        end
        table.remove(args, 1)
    end
    local name, luac = args[1], args[2]
    if not name or not luac then
        io.stderr:write('usage: lua tools/conformance.lua [--strip-bom]' ..
                            ' [--strip-shebang] <grammar> <luac> [file ...]\n')
        return 2
    end
    local grammar = assert(lexogram.load(name))
    local compiled, diagnostics = lexogram.compile(grammar)
    if not compiled then
        io.stderr:write(name .. ': ' .. diagnostics[1].message .. '\n')
        return 2
    end

    local files = {}
    for i = 3, #args do
        files[#files + 1] = args[i]
    end
    if #files == 0 then
        for line in io.lines() do
            files[#files + 1] = line
        end
    end

    local agree, wider, narrower, missing = 0, 0, 0, 0
    for _, pathname in ipairs(files) do
        local f = io.open(pathname, 'rb')
        if not f then
            missing = missing + 1
            print('missing ' .. pathname)
        else
            local src = f:read('*a')
            f:close()
            local start = ''
            if bom and src:sub(1, 3) == '\239\187\191' then
                start, src = '   ', src:sub(4)
            end
            if shebang then
                src = src:gsub('^#[^\n]*', function(line)
                    return (' '):rep(#line)
                end, 1)
            end
            src = start .. src
            local ours = lexogram.parse(compiled, src) ~= nil
            local theirs = official_accepts(luac, pathname)
            if ours == theirs then
                agree = agree + 1
            elseif ours then
                wider = wider + 1
                print('lexogram-only ' .. pathname)
            else
                narrower = narrower + 1
                print('official-only ' .. pathname)
            end
        end
    end
    print(('agree %d lexogram-only %d official-only %d missing %d'):format(
              agree, wider, narrower, missing))
    return narrower > 0 and 1 or 0
end

os.exit(main({
    ...,
}))
