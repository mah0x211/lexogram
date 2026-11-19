-- Shared parts of the conformance tests of the Lua grammars
-- (test/grammars/lua5x_conformance_test.lua): they compare the cases in
-- test/grammars/lua5x/ with luac -p of the matching Lua version. Loaded
-- with dofile from the directory of the tests.
local lexogram = require('lexogram')

--- shell_quote returns s quoted for a POSIX shell.
--- @param s string
--- @return string
local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- run returns the output of a shell command.
--- @param command string
--- @return string
local function run(command)
    local p = io.popen(command)
    if not p then
        return ''
    end
    local out = p:read('*a')
    p:close()
    return out
end

--- find_luac returns the pathname of the luac of Lua version (such as
--- '5.1'): the value of the environment variable env, or one installed by
--- lenv (under LENV_ROOT, or ~/.lenv), or nil. It prints a notice when
--- there is none.
--- @param version string
--- @param env string
--- @param test string the name of the test, for the notice
--- @return string?
local function find_luac(version, env, test)
    local candidates = {}
    candidates[#candidates + 1] = os.getenv(env)
    local roots = {}
    roots[#roots + 1] = os.getenv('LENV_ROOT')
    if os.getenv('HOME') then
        roots[#roots + 1] = os.getenv('HOME') .. '/.lenv'
    end
    for _, root in ipairs(roots) do
        for pathname in run(
                            'ls -d ' .. shell_quote(root) .. '/lua/' .. version ..
                                '.*/bin/luac 2>/dev/null'):gmatch('[^\n]+') do
            candidates[#candidates + 1] = pathname
        end
    end
    local pattern = '^Lua ' .. version:gsub('%.', '%%.')
    for i = 1, #candidates do
        local luac = candidates[i]
        if run(shell_quote(luac) .. ' -v 2>&1'):find(pattern) then
            return luac
        end
    end
    print(test .. ': luac of Lua ' .. version .. ' not found;' ..
              ' the comparisons with it are skipped (set ' .. env .. ')')
    return nil
end

-- the shared helpers, next to this file
local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')

local COMPILED = {}

--- compiled returns the compiled built-in grammar name.
--- @param name string
--- @return table
local function compiled(name)
    if not COMPILED[name] then
        COMPILED[name] = assert(shared.compile(name))
    end
    return COMPILED[name]
end

--- find_luajit returns the pathname of a LuaJIT 2.1 whose version is at
--- least 2.1.<least> (the time of a change of the syntax): the value of the
--- environment variable env, or one installed by lenv, or nil. It prints a
--- notice when there is none.
--- @param least integer
--- @param env string
--- @param test string the name of the test, for the notice
--- @return string?
local function find_luajit(least, env, test)
    local candidates = {}
    candidates[#candidates + 1] = os.getenv(env)
    local roots = {}
    roots[#roots + 1] = os.getenv('LENV_ROOT')
    if os.getenv('HOME') then
        roots[#roots + 1] = os.getenv('HOME') .. '/.lenv'
    end
    for _, root in ipairs(roots) do
        for pathname in run('ls -d ' .. shell_quote(root) ..
                                '/luajit/*/bin/luajit 2>/dev/null'):gmatch(
                            '[^\n]+') do
            candidates[#candidates + 1] = pathname
        end
    end
    for i = 1, #candidates do
        local luajit = candidates[i]
        local version = run(shell_quote(luajit) .. ' -v 2>&1'):match(
                            '^LuaJIT 2%.1%.(%d+)')
        if version and tonumber(version) >= least then
            return luajit
        end
    end
    print(test .. ': LuaJIT 2.1.' .. least .. ' or later not found;' ..
              ' the comparisons with it are skipped (set ' .. env .. ')')
    return nil
end

-- The script that LuaJIT runs to check the file named by its argument.
local LOADFILE = 'local f, err = loadfile(arg[1]) if not f then' ..
                     ' io.write(err) end'

--- judge_luajit returns whether loadfile of LuaJIT and the grammar accept
--- the case file pathname (the lexer of LuaJIT skips a byte order mark and
--- a shebang line itself, and so does the grammar).
--- @param luajit string
--- @param grammar string a built-in grammar such as 'lexogram:luajit'
--- @param pathname string
--- @return boolean official
--- @return boolean grammar
local function judge_luajit(luajit, grammar, pathname)
    local f = assert(io.open(pathname, 'rb'))
    local src = f:read('*a')
    f:close()
    local official = run('printf %s ' .. shell_quote(LOADFILE) .. ' | ' ..
                             shell_quote(luajit) .. ' - ' ..
                             shell_quote(pathname) .. ' 2>&1') == ''
    return official, lexogram.parse(compiled(grammar), src) ~= nil
end

--- blank_loaded returns src with what the file loader of Lua skips before
--- parsing replaced by spaces: a UTF-8 byte order mark when bom is true
--- (Lua 5.2 and later), and then a first line that starts with "#".
--- @param src string
--- @param bom boolean
--- @return string
local function blank_loaded(src, bom)
    local start = ''
    if bom and src:sub(1, 3) == '\239\187\191' then
        start, src = '   ', src:sub(4)
    end
    src = src:gsub('^#[^\n]*', function(line)
        return (' '):rep(#line)
    end, 1)
    return start .. src
end

--- judge returns whether luac, the grammar base (with what the loader skips
--- blanked) and the grammar loader (which skips it itself) accept the case
--- file pathname.
--- @param luac string
--- @param base string a built-in grammar such as 'lexogram:lua51'
--- @param loader string a built-in grammar such as 'lexogram:lua51_shebang'
--- @param bom boolean the loader skips a byte order mark
--- @param pathname string
--- @return boolean official
--- @return boolean base
--- @return boolean loader
local function judge(luac, base, loader, bom, pathname)
    local f = assert(io.open(pathname, 'rb'))
    local src = f:read('*a')
    f:close()
    local official = run(shell_quote(luac) .. ' -p ' .. shell_quote(pathname) ..
                             ' 2>&1') == ''
    return official,
           lexogram.parse(compiled(base), blank_loaded(src, bom)) ~= nil,
           lexogram.parse(compiled(loader), src) ~= nil
end

return {
    find_luac = find_luac,
    find_luajit = find_luajit,
    judge = judge,
    judge_luajit = judge_luajit,
}
