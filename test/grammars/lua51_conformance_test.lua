local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')

-- the test runner executes a test file with its own directory as the
-- working directory; the cases are in lua51/
local CASES = 'lua51/'

-- cases that Lua 5.1 and the grammars treat the same way
local AGREE = {
    'calls',
    'empty_statement',
    'long_brackets',
    'nested_long_comment',
    'nested_long_string',
    'numbers',
    'operators',
    'returns',
    'shebang',
    'statement_after_return',
    'statements',
    'strings',
    'tables',
    'unfinished_string',
}

-- cases that the grammars accept and Lua 5.1 rejects: checks that are not
-- syntax (the target of an assignment, a statement that is not a call, a
-- break outside a loop, "..." outside a vararg function, a decimal escape
-- above 255), tokens that the official lexer rejects as a whole (a
-- malformed number), goto read as two expression statements, and a "("
-- that starts a line after an expression (greedy, where the official
-- parser reports ambiguous syntax)
local WIDER = {
    'ambiguous_call',
    'break_outside',
    'call_as_target',
    'escape_too_large',
    'expression_statement',
    'goto',
    'malformed_number',
    'vararg_outside',
}

--- shell_quote returns s quoted for a POSIX shell.
local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- run returns the output of a shell command.
local function run(command)
    local p = io.popen(command)
    if not p then
        return ''
    end
    local out = p:read('*a')
    p:close()
    return out
end

--- find_luac51 returns the pathname of the luac of Lua 5.1: the value of
--- LEXOGRAM_LUAC51, or one installed by lenv (under LENV_ROOT, or
--- ~/.lenv), or nil.
local function find_luac51()
    local candidates = {}
    candidates[#candidates + 1] = os.getenv('LEXOGRAM_LUAC51')
    local roots = {}
    roots[#roots + 1] = os.getenv('LENV_ROOT')
    if os.getenv('HOME') then
        roots[#roots + 1] = os.getenv('HOME') .. '/.lenv'
    end
    for _, root in ipairs(roots) do
        for pathname in run('ls -d ' .. shell_quote(root) ..
                                '/lua/5.1.*/bin/luac 2>/dev/null'):gmatch(
                            '[^\n]+') do
            candidates[#candidates + 1] = pathname
        end
    end
    for i = 1, #candidates do
        local luac = candidates[i]
        if run(shell_quote(luac) .. ' -v 2>&1'):find('^Lua 5%.1') then
            return luac
        end
    end
    return nil
end

local LUAC = find_luac51()
if not LUAC then
    print('lua51_conformance_test: luac of Lua 5.1 not found;' ..
              ' the comparisons with it are skipped (set LEXOGRAM_LUAC51)')
end

-- run fn with the coverage hook removed: compiling the full grammar takes
-- far too long under luacov's line hook
local function without_hook(fn, ...)
    local hook, mask, count = debug.gethook()
    debug.sethook()
    local res = {
        pcall(fn, ...),
    }
    if hook then
        debug.sethook(hook, mask, count)
    end
    if not res[1] then
        error(res[2], 0)
    end
    return res[2], res[3]
end

local COMPILED = {}
local function compiled(name)
    if not COMPILED[name] then
        local grammar = assert(lexogram.load(name))
        COMPILED[name] = assert(without_hook(lexogram.compile, grammar))
    end
    return COMPILED[name]
end

--- judge returns whether luac, lua51 (with a first "#" line blanked, as
--- the loader of Lua does) and lua51_shebang accept the case name.
local function judge(name)
    local pathname = CASES .. name .. '.lua'
    local f = assert(io.open(pathname, 'rb'))
    local src = f:read('*a')
    f:close()
    local blanked = src:gsub('^#[^\n]*', function(line)
        return (' '):rep(#line)
    end, 1)
    return
        run(shell_quote(LUAC) .. ' -p ' .. shell_quote(pathname) .. ' 2>&1') ==
            '', lexogram.parse(compiled('lexogram:lua51'), blanked) ~= nil,
        lexogram.parse(compiled('lexogram:lua51_shebang'), src) ~= nil
end

function testcase.cases_agree_with_lua51()
    if not LUAC then
        return
    end
    for _, name in ipairs(AGREE) do
        local official, base, shebang = judge(name)
        assert.equal({
            name,
            base,
            shebang,
        }, {
            name,
            official,
            official,
        })
    end
end

function testcase.documented_differences_remain()
    if not LUAC then
        return
    end
    for _, name in ipairs(WIDER) do
        local official, base, shebang = judge(name)
        assert.equal({
            name,
            official,
            base,
            shebang,
        }, {
            name,
            false,
            true,
            true,
        })
    end
end
