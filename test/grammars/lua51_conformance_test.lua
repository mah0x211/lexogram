local testcase = require('testcase')
local assert = require('assert')
-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local conformance = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                               'conformance.lua')

-- the test runner executes a test file with its own directory as the
-- working directory; the cases are in lua51/
local CASES = 'lua51/'

-- cases that Lua 5.1 and the grammars treat the same way
local AGREE = {
    'calls',
    'empty_statement',
    'escape_too_large',
    'exponent_then_dots',
    'hex_exponent',
    'long_brackets',
    'malformed_number',
    'nested_long_comment',
    'nested_long_string',
    'number_touching_name',
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
-- break outside a loop, "..." outside a vararg function), goto read as two
-- expression statements, and a "(" that starts a line after an expression
-- (the possessive _suffix*+ of suffixedexp, where the official parser
-- reports ambiguous syntax)
local WIDER = {
    'ambiguous_call',
    'break_outside',
    'call_as_target',
    'expression_statement',
    'goto',
    'vararg_outside',
}

local LUAC = conformance.find_luac('5.1', 'LEXOGRAM_LUAC51',
                                   'lua51_conformance_test')

-- whether luac, lua51 and lua51_shebang accept the case name
local function judge(name)
    return conformance.judge(LUAC, 'lexogram:lua51', 'lexogram:lua51_shebang',
                             false, CASES .. name .. '.lua')
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
