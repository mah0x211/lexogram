local testcase = require('testcase')
local assert = require('assert')
-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local conformance = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                               'conformance.lua')

-- the test runner executes a test file with its own directory as the
-- working directory; the cases are in lua55/
local CASES = 'lua55/'

-- cases that Lua 5.5 and the grammars treat the same way
local AGREE = {
    'attribute_on_for',
    'attribute_on_function',
    'attributes',
    'break_statement',
    'byte_order_mark',
    'byte_order_mark_shebang',
    'call_on_new_line',
    'empty_statements',
    'escape_too_large',
    'escapes',
    'exponent_then_dots',
    'global_as_name',
    'global_attribute_star_init',
    'global_declarations',
    'global_without_name',
    'goto_as_name',
    'goto_label',
    'hex_floats',
    'integers',
    'invalid_escape',
    'malformed_hex_float',
    'malformed_number',
    'nested_long_brackets',
    'number_touching_name',
    'operators',
    'prefix_attribute',
    'return_semicolon',
    'shebang',
    'short_hex_escape',
    'split_integer_division',
    'split_not_equal',
    'statement_after_return',
    'unclosed_attribute',
    'utf8_empty',
    'utf8_escape',
    'utf8_large',
    'utf8_too_large',
    'utf8_without_brace',
    'vararg_name',
    'vararg_name_not_last',
}

-- cases that the grammars accept and Lua 5.5 rejects: checks that are not
-- syntax (the target of an assignment, a statement that is not a call, a
-- break outside a loop, "..." outside a vararg function, the checks of
-- goto: a missing label, a jump into the scope of a local, a label defined
-- twice, the checks of the attributes: an unknown name, two <close>
-- variables, an assignment to a <const> variable, and the checks of Lua
-- 5.5: an assignment to a for variable or to the vararg parameter, a
-- global declared <close> or assigned when <const>, a name not declared
-- where global declarations are in effect). global function a.b() end is
-- the expression statement global and a function statement, as global
-- alone is
local WIDER = {
    'assign_to_const',
    'assign_to_const_global',
    'assign_to_for_variable',
    'assign_to_vararg_parameter',
    'break_outside',
    'call_as_target',
    'close_global',
    'duplicate_label',
    'expression_statement',
    'global_function_field',
    'goto_into_scope',
    'goto_without_label',
    'two_close',
    'undeclared_global',
    'unknown_attribute',
    'vararg_outside',
}

local LUAC = conformance.find_luac('5.5', 'LEXOGRAM_LUAC55',
                                   'lua55_conformance_test')

-- whether luac, lua55 and lua55_shebang accept the case name
local function judge(name)
    return conformance.judge(LUAC, 'lexogram:lua55', 'lexogram:lua55_shebang',
                             true, CASES .. name .. '.lua')
end

function testcase.cases_agree_with_lua55()
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
