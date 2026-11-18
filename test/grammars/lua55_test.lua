local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local COMPILED

-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')

local function compiled()
    if not COMPILED then
        local diagnostics
        COMPILED, diagnostics = shared.compile('lexogram:lua55')
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

-- the kind names of the tokens of a source
local function token_names(source)
    local result = parse(source)
    local names = {}
    for i = 1, result.count do
        if events.op(result, i) == events.TOKEN then
            local name = events.name(result, i)
            if not SKIPPED[name] then
                names[#names + 1] = name .. ':' .. events.text(result, i)
            end
        end
    end
    return names
end

function testcase.grammar_extends_lua54()
    local grammar = assert(shared.load('lexogram:lua55'))
    local lua54 = assert(shared.load('lexogram:lua54'))

    assert.equal(grammar.name, 'lua55')
    assert.equal(grammar.version, '1.0.0')
    -- the rules of lua54, and globalfunc and globalstat
    local names = {}
    for _, kind in ipairs(compiled().kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    local expected = {
        'globalfunc',
        'globalstat',
    }
    for name in pairs(lua54.rules) do
        if name:sub(1, 1) ~= '_' then
            expected[#expected + 1] = name
        end
    end
    table.sort(names)
    table.sort(expected)
    assert.equal(names, expected)
    -- the tokens and the symbols are those of lua54; global is a
    -- contextual keyword
    assert.equal(grammar.tokens, lua54.tokens)
    assert.equal(grammar.symbols, lua54.symbols)
    assert.equal(grammar.keywords.contextual, {
        'global',
    })
    grammar.keywords.contextual = nil
    assert.equal(grammar.keywords, lua54.keywords)
end

function testcase.globals_are_declared()
    local b = block('global <const> x, y <close> = 1 global * global <const> *')

    assert.equal(b[2], {
        'globalstat',
        'global',
        {
            'attrib',
            '<',
            'const',
            '>',
        },
        'x',
        ',',
        'y',
        {
            'attrib',
            '<',
            'close',
            '>',
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
        'globalstat',
        'global',
        '*',
    })
    assert.equal(b[4], {
        'globalstat',
        'global',
        {
            'attrib',
            '<',
            'const',
            '>',
        },
        '*',
    })
    assert.equal(block('global function f() end')[2], {
        'globalfunc',
        'global',
        'function',
        'f',
        {
            'body',
            '(',
            ')',
            {
                'block',
            },
            'end',
        },
    })
    for _, source in ipairs({
        'global function a.b() end',
        'global <const> * = 1',
        'global < 3',
        'global x <const = 1',
    }) do
        local result = lexogram.parse(compiled(), source)
        -- global function a.b() end is the expression statement global and
        -- the function statement a.b, as global alone is (an expression
        -- statement is accepted, see the differences in lua51)
        assert.equal(result ~= nil, source == 'global function a.b() end')
    end
end

function testcase.global_is_a_name_elsewhere()
    -- the keyword starts a declaration; the other statements read it as
    -- the name it is
    assert.equal(token_names('global global = global.x global(1) local global'),
                 {
        'global:global',
        'name:global',
        '=:=',
        'name:global',
        '.:.',
        'name:x',
        'name:global',
        '(:(',
        'number:1',
        '):)',
        'local:local',
        'name:global',
    })
    assert.equal(block('global = 1')[2][1], 'exprstat')
    assert.equal(block('global "s"')[2][1], 'exprstat')
    assert.equal(block('global:m()')[2][1], 'exprstat')
    assert.equal(block('function global() end')[2][1], 'funcstat')
    -- the tokenizer has no context: it reads the token name
    local kinds = compiled().kinds
    local kind = lexogram.tokenize(compiled(), 'global', 1)
    assert.equal(kinds[kind].name, 'name')
    -- a declaration with a syntax error is no other statement either
    local result, err = lexogram.parse(compiled(), 'global x = 1 +')
    assert.is_nil(result)
    assert.equal(err.code, 'syntax_error')
end

function testcase.local_attributes_may_come_first()
    assert.equal(block('local <const> a, b <close> = 1')[2][3], {
        'attnamelist',
        {
            'attrib',
            '<',
            'const',
            '>',
        },
        'a',
        ',',
        'b',
        {
            'attrib',
            '<',
            'close',
            '>',
        },
    })
    local result, err = lexogram.parse(compiled(), 'local <const> = 1')
    assert.is_nil(result)
    assert.equal(err.code, 'syntax_error')
end

function testcase.the_vararg_parameter_may_have_a_name()
    assert.equal(block('function f(a, ... t) end')[2][4][3], {
        'parlist',
        'a',
        ',',
        '...',
        't',
    })
    assert.equal(block('return function(... args) end')[2][3][2][2][3][3], {
        'parlist',
        '...',
        'args',
    })
    for _, source in ipairs({
        'function f(... t, u) end',
        'function f(t ...) end',
        'function f(... ...) end',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'syntax_error')
    end
end

function testcase.other_rules_are_those_of_lua54()
    -- the parser of Lua 5.5 has the operators and priorities of Lua 5.4
    -- (lparser.c), so the rules of expressions, as every rule other than
    -- those of statements, declarations and parameters, are those of
    -- lua54, whose trees test/grammars/lua53_expression_test.lua checks
    local rules = assert(shared.load('lexogram:lua55')).rules
    local lua54 = assert(shared.load('lexogram:lua54')).rules
    rules._stat, rules._stat_rest = nil, nil
    rules.globalfunc, rules.globalstat = nil, nil
    rules.attnamelist, rules.parlist = nil, nil
    lua54._stat, lua54.attnamelist, lua54.parlist = nil, nil, nil
    assert.equal(rules, lua54)
end
