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
        COMPILED, diagnostics = shared.compile('lexogram:lua54')
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

function testcase.grammar_extends_lua53()
    local grammar = assert(shared.load('lexogram:lua54'))
    local lua53 = assert(shared.load('lexogram:lua53'))

    assert.equal(grammar.name, 'lua54')
    assert.equal(grammar.version, '5.4.8-1')
    -- the rules of lua53, and attnamelist and attrib
    local names = {}
    for _, kind in ipairs(compiled().kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    local expected = {
        'attnamelist',
        'attrib',
    }
    for name in pairs(lua53.rules) do
        if name:sub(1, 1) ~= '_' then
            expected[#expected + 1] = name
        end
    end
    table.sort(names)
    table.sort(expected)
    assert.equal(names, expected)
    -- the tokens are those of lua53 but the number, which may not touch a
    -- letter, and the code points of \u, which go up to 2^31; the symbols
    -- are those of lua53
    assert.not_equal(grammar.tokens.number, lua53.tokens.number)
    assert.not_equal(grammar.tokens._code_point, lua53.tokens._code_point)
    grammar.tokens.number, grammar.tokens._code_point = nil, nil
    lua53.tokens.number, lua53.tokens._code_point = nil, nil
    assert.equal(grammar.tokens, lua53.tokens)
    assert.equal(grammar.symbols, lua53.symbols)
end

function testcase.local_variables_have_attributes()
    local b = block('local x <const>, y, z < close > = 1, f() local n')

    assert.equal(b[2], {
        'localstat',
        'local',
        {
            'attnamelist',
            'x',
            {
                'attrib',
                '<',
                'const',
                '>',
            },
            ',',
            'y',
            ',',
            'z',
            {
                'attrib',
                '<',
                'close',
                '>',
            },
        },
        '=',
        {
            'explist',
            {
                'exp',
                '1',
            },
            ',',
            {
                'exp',
                {
                    'suffixedexp',
                    'f',
                    {
                        'args',
                        '(',
                        ')',
                    },
                },
            },
        },
    })
    assert.equal(b[3], {
        'localstat',
        'local',
        {
            'attnamelist',
            'n',
        },
    })
    -- the generic for keeps namelist, without attributes
    assert.equal(block('for k, v in pairs(t) do end')[2][3][2], {
        'namelist',
        'k',
        ',',
        'v',
    })
    for _, source in ipairs({
        'for i <const> = 1, 2 do end',
        'local function f <const> () end',
        'local x <const = 1',
        'local x <> = 1',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'syntax_error')
    end
end

function testcase.tokens_of_lua54()
    -- an attribute is "<", a name and ">"
    assert.equal(token_names('local x <const>'), {
        'local:local',
        'name:x',
        '<:<',
        'name:const',
        '>:>',
    })
    -- a \u escape may write any value below 2^31
    assert.equal(token_names('x = "\\u{7FFFFFFF}\\u{0000110000}"'), {
        'name:x',
        '=:=',
        'string:"\\u{7FFFFFFF}\\u{0000110000}"',
    })
    -- a numeral that touches a letter is an invalid number, as in the lexer
    -- of Lua 5.4 (malformed number)
    for _, source in ipairs({
        'x = 3print(1)',
        'x = 0x1p',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'invalid_token')
        assert.equal(err.pos, 5)
        assert.equal(err.message, 'invalid number')
    end
    -- a \u escape of 2^31 is no string
    local result, err = lexogram.parse(compiled(), 'x = "\\u{80000000}"')
    assert.is_nil(result)
    assert.equal(err.code, 'syntax_error')
end

function testcase.other_rules_are_those_of_lua53()
    -- the parser of Lua 5.4 has the operators and priorities of Lua 5.3
    -- (lparser.c), so the rules of expressions, as every rule other than
    -- those of local statements, are those of lua53, whose trees
    -- test/grammars/lua53_expression_test.lua checks
    local rules = assert(shared.load('lexogram:lua54')).rules
    local lua53 = assert(shared.load('lexogram:lua53')).rules
    rules.localstat, rules.attnamelist, rules.attrib = nil, nil, nil
    lua53.localstat = nil
    assert.equal(rules, lua53)
end
