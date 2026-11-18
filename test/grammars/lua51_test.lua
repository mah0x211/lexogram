local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- the test runner executes a test file with its own directory as the
-- working directory (only while the tests run), so the grammar is loaded
-- on first use
local ROOT = '../../'
local COMPILED

-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')
local without_hook = shared.without_hook

local function compiled()
    if not COMPILED then
        local diagnostics
        COMPILED, diagnostics = shared.compile('lexogram:lua51')
        assert.equal(diagnostics, {})
    end
    return COMPILED
end

local function parse(source)
    local result, err = lexogram.parse(compiled(), source)
    assert(result,
           err and (err.line .. ':' .. err.column .. ': ' .. err.message))
    return result
end

-- skipped tokens are left out of shapes
local SKIPPED = {
    space = true,
    comment = true,
    long_comment = true,
}

-- the shape of a node list: a rule is { name, child... }, a token is its
-- text
local function shape(nodes)
    local out = {}
    for _, node in ipairs(nodes) do
        if node.children then
            local inner = shape(node.children)
            table.insert(inner, 1, node.name)
            out[#out + 1] = inner
        elseif not SKIPPED[node.name] then
            out[#out + 1] = node.text
        end
    end
    return out
end

-- the shape of the block of a chunk
local function block(source)
    return shape(events.tree(parse(source)))[1][2]
end

-- the names of the children of a shape that are rules
local function rule_names(node)
    local out = {}
    for i = 2, #node do
        if type(node[i]) == 'table' then
            out[#out + 1] = node[i][1]
        end
    end
    return out
end

function testcase.grammar_compiles_with_the_documented_rule_names()
    local names = {}
    for _, kind in ipairs(compiled().kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    table.sort(names)

    -- rule names are a public contract with consumers
    assert.equal(names, {
        'args',
        'binop',
        'block',
        'body',
        'breakstat',
        'chunk',
        'dostat',
        'exp',
        'explist',
        'exprstat',
        'forlist',
        'fornum',
        'forstat',
        'funcname',
        'funcstat',
        'functiondef',
        'ifstat',
        'listfield',
        'localfunc',
        'localstat',
        'namelist',
        'parlist',
        'recfield',
        'repeatstat',
        'retstat',
        'suffixedexp',
        'tableconstructor',
        'unop',
        'whilestat',
    })
end

function testcase.statements_have_their_own_rules()
    local b = block(table.concat({
        'x = 1',
        'f(x)',
        'do end',
        'while x do end',
        'repeat until x',
        'if x then elseif y then else end',
        'for i = 1, 2 do end',
        'for k, v in pairs(t) do end',
        'function a.b:c() end',
        'local function g() end',
        'local p, q = 1',
        'return x;',
    }, '\n'))

    assert.equal(rule_names(b), {
        'exprstat',
        'exprstat',
        'dostat',
        'whilestat',
        'repeatstat',
        'ifstat',
        'forstat',
        'forstat',
        'funcstat',
        'localfunc',
        'localstat',
        'retstat',
    })
    -- an assignment and a call are told apart by the "=" token inside
    assert.equal(b[2], {
        'exprstat',
        {
            'suffixedexp',
            'x',
        },
        '=',
        {
            'explist',
            {
                'exp',
                '1',
            },
        },
    })
    assert.equal(b[3], {
        'exprstat',
        {
            'suffixedexp',
            'f',
            {
                'args',
                '(',
                {
                    'explist',
                    {
                        'exp',
                        {
                            'suffixedexp',
                            'x',
                        },
                    },
                },
                ')',
            },
        },
    })
    -- statements include their keywords; for reads "for" before fornum
    -- or forlist, which need three tokens to tell apart
    assert.equal(b[8][2], 'for')
    assert.equal(rule_names(b[8]), {
        'fornum',
    })
    assert.equal(rule_names(b[9]), {
        'forlist',
    })
    assert.equal(b[11][2], 'local')
    assert.equal(b[11][3], 'function')
    assert.equal(b[12][2], 'local')
    assert.equal(rule_names(block('while true do break end')[2][5]), {
        'breakstat',
    })
end

function testcase.table_fields_have_their_own_rules()
    local b = block('t = { [1] = a, k = b, c; d, }')
    local tc = b[2][4][2][2]

    assert.equal(tc[1], 'tableconstructor')
    assert.equal(rule_names(tc), {
        'recfield',
        'recfield',
        'listfield',
        'listfield',
    })
    -- the kind of a recfield is told by its first token
    assert.equal(tc[3][2], '[')
    assert.equal(tc[5][2], 'k')
end

function testcase.call_arguments_are_told_by_their_first_token()
    local b = block('f() f{} f"s" f[[s]] o:m(1)')
    local firsts = {}
    for i = 2, #b do
        local call = b[i][2]
        local args = call[#call]
        firsts[#firsts + 1] = args[2]
    end

    assert.equal(firsts, {
        '(',
        {
            'tableconstructor',
            '{',
            '}',
        },
        '"s"',
        '[[s]]',
        '(',
    })
    -- a method call keeps ":" and the name before its args
    assert.equal(b[6][2], {
        'suffixedexp',
        'o',
        ':',
        'm',
        {
            'args',
            '(',
            {
                'explist',
                {
                    'exp',
                    '1',
                },
            },
            ')',
        },
    })
end

function testcase.expressions_list_terms_and_operators_flat()
    local b = block('x = not a .. b ^ -c == #d')
    local exp = b[2][4][2]

    assert.equal(exp, {
        'exp',
        {
            'unop',
            'not',
        },
        {
            'suffixedexp',
            'a',
        },
        {
            'binop',
            '..',
        },
        {
            'suffixedexp',
            'b',
        },
        {
            'binop',
            '^',
        },
        {
            'unop',
            '-',
        },
        {
            'suffixedexp',
            'c',
        },
        {
            'binop',
            '==',
        },
        {
            'unop',
            '#',
        },
        {
            'suffixedexp',
            'd',
        },
    })
end

function testcase.functions_and_varargs()
    local b = block('local f = function(a, b, ...) return ... end')
    local fd = b[2][5][2][2]

    assert.equal(fd[1], 'functiondef')
    assert.equal(fd[3][3], {
        'parlist',
        'a',
        ',',
        'b',
        ',',
        '...',
    })
    assert.equal(block('function f(...) end')[2][4][3], {
        'parlist',
        '...',
    })
end

function testcase.a_parenthesis_after_an_expression_is_a_call()
    -- as in the official parser, the "(" on the next line continues the
    -- expression as call arguments (the possessive _suffix*+ of
    -- suffixedexp)
    local b = block('a = b\n(f)()')

    assert.equal(rule_names(b), {
        'exprstat',
    })
end

function testcase.numbers_follow_the_lua_5_1_lexer()
    -- the run that the lexer reads must be one number (malformed number)
    for _, source in ipairs({
        'x = 3e',
        'x = 1..2',
        'x = 3print',
        'x = 0x1p+4',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'invalid_token')
        assert.equal(err.pos, 5)
        assert.equal(err.message, 'invalid number')
    end
    -- an exponent ends the dots: 1e5 .. x
    parse('x = 1e5..x')
end

function testcase.long_brackets_follow_the_lua_5_1_lexer()
    -- level 0: an inner [[ is an error, as in Lua 5.1
    local result, err = lexogram.parse(compiled(), 'x = [[ a [[ b ]]')
    assert.is_nil(result)
    assert.equal(err.code, 'nested_delimiter')
    assert.equal(err.pos, 10)
    -- a long comment reads its body as a long string does
    result, err = lexogram.parse(compiled(), '--[[ a [[ b ]]\nx = 1')
    assert.is_nil(result)
    assert.equal(err.code, 'nested_delimiter')
    assert.equal(err.pos, 8)
    assert.equal(block('--[=[ [[ ]=] x = 1 --[[ y ]]')[2][2][2], 'x')

    -- levels with "=": an inner open of any level is text
    local b = block('x = [=[ a [=[ [[ b ]=] y = [==[ ]] ]==]')
    assert.equal(b[2][4][2][2], '[=[ a [=[ [[ b ]=]')
    assert.equal(b[3][4][2][2], '[==[ ]] ]==]')
    -- a level 0 string may contain levels with "="
    assert.equal(block('x = [[ [=[ ]=] ]]')[2][4][2][2], '[[ [=[ ]=] ]]')
    -- both kinds are call arguments
    assert.equal(block('f[=[s]=]')[2][2][3], {
        'args',
        '[=[s]=]',
    })
end

function testcase.library_sources_parse()
    -- the library is written in Lua 5.1 compatible code
    for _, path in ipairs({
        'lib/analyzer.lua',
        'lib/check.lua',
        'lib/compile/dfa.lua',
        'lib/compile/ll.lua',
        'lib/pattern.lua',
        'grammars/lua51.lua',
    }) do
        local f = assert(io.open(ROOT .. path, 'rb'))
        local source = f:read('*a')
        f:close()
        -- parsing whole files takes far too long under luacov's line hook,
        -- and the library lines it runs are covered by the other tests
        without_hook(parse, source)
    end
end
