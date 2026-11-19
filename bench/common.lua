-- Shared setup of the benchmark scripts (bench/tokenize.lua and
-- bench/parse.lua).
--
-- usage of a script: lua bench/<script>.lua [grammar] [files...]
--
-- grammar is a grammar file or a built-in grammar ("lexogram:lua51") and
-- defaults to bench/grammars/lua51_lexical.lua, and the input to the
-- library sources listed in LIB_FILES (there is no directory walking
-- library, so the list is explicit and must be updated with new modules).
-- Each file is wrapped in do ... end, so that the input is one chunk of
-- Lua, and the files are concatenated and repeated until the input has at
-- least 2 MB. The grammar is loaded and compiled once (both times are
-- reported: a built-in grammar is checked when it is loaded first, and
-- compiling it then copies what that check made), and
-- the measured function runs over the whole input RUNS times; the best run
-- is reported.
--
-- The lexogram modules are loaded from lib/ of this repository (found
-- from the path of the script), not from an installed rock: a searcher
-- inserted before the standard ones maps lexogram to lib/lexogram.lua,
-- lexogram.grammars.x to grammars/x.lua and lexogram.a.b to lib/a/b.lua. This works the same with Lua 5.1 - 5.5 and
-- LuaJIT, e.g. ~/.lenv/luajit/v2.1/bin/luajit bench/parse.lua
-- the repository root: the parent of the directory of the running script
local ROOT = ((arg and arg[0] or ''):match('^(.-)[^/\\]*$') or '') .. '../'

local LIB_FILES = {
    'lib/analyzer.lua',
    'lib/check.lua',
    'lib/compat.lua',
    'lib/compile.lua',
    'lib/compile/codegen.lua',
    'lib/compile/delimited.lua',
    'lib/compile/dfa.lua',
    'lib/compile/lexer.lua',
    'lib/compile/limits.lua',
    'lib/compile/ll.lua',
    'lib/compile/lookahead.lua',
    'lib/compile/nfa.lua',
    'lib/compile/syntax.lua',
    'lib/compile/utf8range.lua',
    'lib/events.lua',
    'lib/extend.lua',
    'lib/grammar.lua',
    'lib/lexogram.lua',
    'lib/loader.lua',
    'lib/pattern.lua',
    'lib/source.lua',
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
    elseif name:sub(1, 18) == 'lexogram.grammars.' then
        -- the built-in grammars ("lexogram:<name>")
        path = ROOT .. 'grammars/' .. name:sub(19) .. '.lua'
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

--- setup compiles the grammar and builds the input from the command line
--- arguments; it exits with status 1 on any error.
--- @param args string[] the command line arguments
--- @return table setup { lexogram, compiled, input, grammar_path, files,
--- load_time, compile_time }
local function setup(args)
    local grammar_path = args[1] or ROOT .. 'bench/grammars/lua51_lexical.lua'
    local files = {}
    for i = 2, #args do
        files[#files + 1] = args[i]
    end
    if #files == 0 then
        for i, name in ipairs(LIB_FILES) do
            files[i] = ROOT .. name
        end
    end

    local t0 = os.clock()
    local grammar, err = lexogram.load(grammar_path)
    if not grammar then
        fail(err)
    end
    local t1 = os.clock()
    local compiled, diagnostics = lexogram.compile(grammar)
    local compile_time = os.clock() - t1
    local load_time = t1 - t0
    for _, d in ipairs(diagnostics) do
        io.stderr:write(d.severity, ': ', d.path, ': ', d.message, '\n')
    end
    if not compiled then
        fail('the grammar has errors')
    end

    -- each file is a block of its own, so that the input is one chunk of
    -- Lua (a file may end with return)
    local parts = {}
    for i, pathname in ipairs(files) do
        parts[i] = 'do\n' .. read_file(pathname) .. '\nend'
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

    return {
        lexogram = lexogram,
        compiled = compiled,
        input = table.concat(copies, '\n'),
        grammar_path = grammar_path,
        files = files,
        load_time = load_time,
        compile_time = compile_time,
    }
end

--- best runs fn RUNS times and returns the shortest CPU time and the
--- results of the last run.
--- @param fn function
--- @return number seconds
--- @return any ... results of fn
local function best(fn)
    local min, results
    for _ = 1, RUNS do
        local start = os.clock()
        results = {
            fn(),
        }
        local elapsed = os.clock() - start
        if not min or elapsed < min then
            min = elapsed
        end
    end
    return min, (table.unpack or unpack)(results)
end

--- report prints the common header of a benchmark result.
--- @param s table result of setup
local function report(s)
    local mb = #s.input / (1024 * 1024)
    print(string.format('runtime   : %s%s', _VERSION,
                        jit and (' (' .. jit.version .. ')') or ''))
    print(string.format('grammar   : %s', s.grammar_path))
    print(string.format('load      : %.3f s', s.load_time))
    print(string.format('compile   : %.3f s', s.compile_time))
    print(string.format('input     : %d bytes (%.2f MB, %d files)', #s.input,
                        mb, #s.files))
    return mb
end

return {
    RUNS = RUNS,
    fail = fail,
    setup = setup,
    best = best,
    report = report,
}
