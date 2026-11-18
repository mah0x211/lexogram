local testcase = require('testcase')
local assert = require('assert')
-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local conformance = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                               'conformance.lua')

-- the test runner executes a test file with its own directory as the
-- working directory; the cases are in luajit/
local CASES = 'luajit/'

-- the version of LuaJIT whose syntax the grammar follows
local LEAST = 1792527310

-- cases that LuaJIT and the grammar treat the same way
local AGREE = {
    'arrow_without_greater',
    'binary_too_long',
    'byte_order_mark_shebang',
    'compound_assignments',
    'compound_of_two',
    'compound_with_space',
    'const',
    'continue',
    'continue_not_last',
    'directive_after_shebang',
    'empty_statements',
    'escape_too_large',
    'escapes',
    'exponent_too_large',
    'expression_statement',
    'floor_division',
    'goto_as_name',
    'goto_label',
    'hash_at_start',
    'invalid_escape',
    'length_at_line_start',
    'line_directive',
    'line_directive_at_start',
    'malformed_line_directive',
    'malformed_number',
    'malformed_suffix',
    'names_with_high_bytes',
    'nested_long_brackets',
    'number_limits',
    'number_suffixes',
    'number_too_large',
    'number_underscores',
    'numbers',
    'operators',
    'safe_navigation',
    'shebang',
    'short_function_statement',
    'short_functions',
    'ternary',
    'ternary_method_in_middle',
}

-- cases that the grammar accepts and LuaJIT rejects: checks that are not
-- syntax (a break or continue outside a loop, a statement that ends with a
-- suffix other than a call, the target of an assignment) and a safe
-- navigation in an assignment of several targets
local WIDER = {
    'break_outside',
    'call_as_target',
    'continue_outside',
    'safe_navigation_parallel',
    'suffix_statement',
}

local LUAJIT = conformance.find_luajit(LEAST, 'LEXOGRAM_LUAJIT',
                                       'luajit_conformance_test')

-- whether LuaJIT and the grammar accept the case name
local function judge(name)
    return conformance.judge_luajit(LUAJIT, 'lexogram:luajit',
                                    CASES .. name .. '.lua')
end

function testcase.cases_agree_with_luajit()
    if not LUAJIT then
        return
    end
    for _, name in ipairs(AGREE) do
        local official, ours = judge(name)
        assert.equal({
            name,
            ours,
        }, {
            name,
            official,
        })
    end
end

function testcase.documented_differences_remain()
    if not LUAJIT then
        return
    end
    for _, name in ipairs(WIDER) do
        local official, ours = judge(name)
        assert.equal({
            name,
            official,
            ours,
        }, {
            name,
            false,
            true,
        })
    end
end
