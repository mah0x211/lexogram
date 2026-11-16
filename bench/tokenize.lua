-- Tokenizer benchmark.
--
-- usage: lua bench/tokenize.lua [grammar] [files...]
--
-- grammar defaults to bench/grammars/lua51_lexical.lua, and the input to
-- the library sources listed in LIB_FILES (there is no directory walking
-- library, so the list is explicit and must be updated with new modules).
-- The files are concatenated and repeated until the input has at least
-- 2 MB. The grammar is compiled once (the compile time is reported), then
-- the whole input is tokenized from position 1 to the end 5 times and the
-- best run is reported.
--
-- The lexogram modules are loaded from lib/ of this repository (found
-- from the path of this script), not from an installed rock: a searcher
-- inserted before the standard ones maps lexogram to lib/lexogram.lua and
-- lexogram.a.b to lib/a/b.lua. This works the same with Lua 5.1 - 5.5 and
-- LuaJIT, e.g. ~/.lenv/luajit/v2.1/bin/luajit bench/tokenize.lua
local ROOT = arg and arg[0] and arg[0]:match('^(.-)bench[/\\][^/\\]*$') or ''

local LIB_FILES = {
    'lib/check.lua',
    'lib/compat.lua',
    'lib/compile.lua',
    'lib/compile/delimited.lua',
    'lib/compile/dfa.lua',
    'lib/compile/lexer.lua',
    'lib/compile/limits.lua',
    'lib/compile/nfa.lua',
    'lib/compile/utf8range.lua',
    'lib/lexogram.lua',
    'lib/loader.lua',
    'lib/pattern.lua',
    'lib/text.lua',
    'lib/tokenizer.lua',
    'lib/utf8.lua',
    'lib/version.lua',
}
local MIN_INPUT = 2 * 1024 * 1024
local RUNS = 5

-- load lexogram modules from lib/ of this repository
local searchers = package.searchers or package.loaders
table.insert(searchers, 2, function(name)
    local path
    if name == 'lexogram' then
        path = ROOT .. 'lib/lexogram.lua'
    elseif name:sub(1, 9) == 'lexogram.' then
        path = ROOT .. 'lib/' .. name:sub(10):gsub('%.', '/') .. '.lua'
    else
        return nil
    end
    local fn, err = loadfile(path)
    if not fn then
        return '\n\t' .. err
    end
    return fn
end)

local lexogram = require('lexogram')

local function read_file(pathname)
    local f = assert(io.open(pathname, 'rb'))
    local content = assert(f:read('*a'))
    f:close()
    return content
end

local function fail(message)
    io.stderr:write(message, '\n')
    os.exit(1)
end

-- arguments
local grammar_path = arg[1] or ROOT .. 'bench/grammars/lua51_lexical.lua'
local files = {}
for i = 2, #arg do
    files[#files + 1] = arg[i]
end
if #files == 0 then
    for i, name in ipairs(LIB_FILES) do
        files[i] = ROOT .. name
    end
end

-- compile
local grammar, err = lexogram.load(grammar_path)
if not grammar then
    fail(err)
end
local t0 = os.clock()
local compiled, diagnostics = lexogram.compile(grammar)
local compile_time = os.clock() - t0
for _, d in ipairs(diagnostics) do
    io.stderr:write(d.severity, ': ', d.path, ': ', d.message, '\n')
end
if not compiled then
    fail('the grammar has errors')
end

-- input
local parts = {}
for i, pathname in ipairs(files) do
    parts[i] = read_file(pathname)
end
local unit = table.concat(parts, '\n')
if #unit == 0 then
    fail('the input is empty')
end
local copies = {}
local size = 0
repeat
    copies[#copies + 1] = unit
    size = size + #unit + 1
until size >= MIN_INPUT
local input = table.concat(copies, '\n')

-- tokenize
local tokenize = lexogram.tokenize
local function run()
    local pos, count, invalid = 1, 0, 0
    local len = #input
    while pos <= len do
        local kind, stop = tokenize(compiled, input, pos)
        if kind == 1 then
            invalid = invalid + 1
        end
        count = count + 1
        pos = stop
    end
    return count, invalid
end

local best, count, invalid
for _ = 1, RUNS do
    local start = os.clock()
    count, invalid = run()
    local elapsed = os.clock() - start
    if not best or elapsed < best then
        best = elapsed
    end
end

local mb = #input / (1024 * 1024)
print(string.format('runtime   : %s%s', _VERSION,
                    jit and (' (' .. jit.version .. ')') or ''))
print(string.format('grammar   : %s', grammar_path))
print(string.format('compile   : %.3f s', compile_time))
print(string.format('input     : %d bytes (%.2f MB, %d files)', #input, mb,
                    #files))
print(string.format('tokens    : %d (INVALID: %d)', count, invalid))
print(string.format('best of %d: %.3f s', RUNS, best))
print(string.format('throughput: %.2f MB/s, %.0f tokens/s', mb / best,
                    count / best))
