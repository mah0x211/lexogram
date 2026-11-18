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
        COMPILED, diagnostics = shared.compile('lexogram:lua53')
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

function testcase.grammar_extends_lua52()
    local grammar = assert(shared.load('lexogram:lua53'))
    local lua52 = assert(shared.load('lexogram:lua52'))

    assert.equal(grammar.name, 'lua53')
    assert.equal(grammar.version, '1.0.0')
    -- the rules of lua52 and no other
    local names = {}
    for _, kind in ipairs(compiled().kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    local expected = {}
    for name in pairs(lua52.rules) do
        if name:sub(1, 1) ~= '_' then
            expected[#expected + 1] = name
        end
    end
    table.sort(names)
    table.sort(expected)
    assert.equal(names, expected)
end

function testcase.integer_division_and_bitwise_operators()
    local b = block('x = a // b & c | d ~ e << 1 >> 2 y = ~a ~= ~~b')
    local exp = b[2][4][2]

    assert.equal(exp, {
        'exp',
        {
            'suffixedexp',
            'a',
        },
        {
            'binop',
            '//',
        },
        {
            'suffixedexp',
            'b',
        },
        {
            'binop',
            '&',
        },
        {
            'suffixedexp',
            'c',
        },
        {
            'binop',
            '|',
        },
        {
            'suffixedexp',
            'd',
        },
        {
            'binop',
            '~',
        },
        {
            'suffixedexp',
            'e',
        },
        {
            'binop',
            '<<',
        },
        '1',
        {
            'binop',
            '>>',
        },
        '2',
    })
    -- "~" as a unary operator, and "~=" as one token
    assert.equal(b[3][4][2], {
        'exp',
        {
            'unop',
            '~',
        },
        {
            'suffixedexp',
            'a',
        },
        {
            'binop',
            '~=',
        },
        {
            'unop',
            '~',
        },
        {
            'unop',
            '~',
        },
        {
            'suffixedexp',
            'b',
        },
    })
end

function testcase.utf8_escapes()
    assert.equal(token_names('x = "\\u{48}\\u{10FFFF}"'), {
        'name:x',
        '=:=',
        'string:"\\u{48}\\u{10FFFF}"',
    })
    for _, source in ipairs({
        'x = "\\u48"',
        'x = "\\u{}"',
        'x = "\\u{48"',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'syntax_error')
    end
end
