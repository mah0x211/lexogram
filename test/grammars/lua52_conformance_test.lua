local testcase = require('testcase')
local assert = require('assert')
-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local conformance = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                               'conformance.lua')

-- the test runner executes a test file with its own directory as the
-- working directory; the cases are in lua52/
local CASES = 'lua52/'

-- cases that Lua 5.2 and the grammars treat the same way
local AGREE = {
    'break_statement',
    'byte_order_mark',
    'byte_order_mark_shebang',
    'call_on_new_line',
    'empty_statements',
    'escape_too_large',
    'escapes',
    'exponent_then_dots',
    'goto_as_name',
    'goto_label',
    'hex_floats',
    'invalid_escape',
    'malformed_hex_float',
    'malformed_number',
    'nested_long_brackets',
    'number_touching_name',
    'return_semicolon',
    'shebang',
    'short_hex_escape',
    'statement_after_return',
}

-- cases that the grammars accept and Lua 5.2 rejects: checks that are not
-- syntax (the target of an assignment, a statement that is not a call, a
-- break outside a loop, "..." outside a vararg function, and the checks of
-- goto: a missing label, a jump into the scope of a local, a label defined
-- twice)
local WIDER = {
    'break_outside',
    'call_as_target',
    'duplicate_label',
    'expression_statement',
    'goto_into_scope',
    'goto_without_label',
    'vararg_outside',
}

local LUAC = conformance.find_luac('5.2', 'LEXOGRAM_LUAC52',
                                   'lua52_conformance_test')

-- whether luac, lua52 and lua52_shebang accept the case name
local function judge(name)
    return conformance.judge(LUAC, 'lexogram:lua52', 'lexogram:lua52_shebang',
                             true, CASES .. name .. '.lua')
end

function testcase.cases_agree_with_lua52()
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
