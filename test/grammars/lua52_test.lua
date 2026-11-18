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
        COMPILED, diagnostics = shared.compile('lexogram:lua52')
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

function testcase.grammar_extends_lua51()
    local grammar = assert(shared.load('lexogram:lua52'))

    assert.equal(grammar.name, 'lua52')
    assert.equal(grammar.version, '5.2.4-1')
    assert.is_nil(grammar.rules._laststat)
    assert.is_nil(grammar.tokens.long_string.nest)
    local names = {}
    for _, kind in ipairs(compiled().kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    table.sort(names)
    -- the rules of lua51 and labelstat and gotostat
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
        'gotostat',
        'ifstat',
        'labelstat',
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

function testcase.goto_labels_and_break_are_statements()
    local b = block(table.concat({
        'goto done',
        'while x do break; y = 1 end',
        '::done::',
    }, '\n'))

    assert.equal(b[2], {
        'gotostat',
        'goto',
        'done',
    })
    -- break may be followed by other statements
    assert.equal(b[3][5], {
        'block',
        {
            'breakstat',
            'break',
        },
        ';',
        {
            'exprstat',
            {
                'suffixedexp',
                'y',
            },
            '=',
            {
                'explist',
                {
                    'exp',
                    '1',
                },
            },
        },
    })
    assert.equal(b[4], {
        'labelstat',
        '::',
        'done',
        '::',
    })
end

function testcase.empty_statements_and_return_with_a_semicolon()
    local b = block(';; local a = 1 ; return a;')

    assert.equal(b, {
        'block',
        ';',
        ';',
        {
            'localstat',
            'local',
            {
                'namelist',
                'a',
            },
            '=',
            {
                'explist',
                {
                    'exp',
                    '1',
                },
            },
        },
        ';',
        {
            'retstat',
            'return',
            {
                'explist',
                {
                    'exp',
                    {
                        'suffixedexp',
                        'a',
                    },
                },
            },
            ';',
        },
    })
end

function testcase.tokens_of_lua52()
    assert.equal(token_names('x = { 0x1.8p3, 0xA.Fp-2, 0x.8, 0x10 }'), {
        'name:x',
        '=:=',
        '{:{',
        'number:0x1.8p3',
        ',:,',
        'number:0xA.Fp-2',
        ',:,',
        'number:0x.8',
        ',:,',
        'number:0x10',
        '}:}',
    })
    -- the escapes of Lua 5.2, \z skipping a line break
    assert.equal(token_names('x = "\\x41\\65\\z\n  \\t\\a\\\\\\""'), {
        'name:x',
        '=:=',
        'string:"\\x41\\65\\z\n  \\t\\a\\\\\\""',
    })
    -- goto is a keyword, and "::" a symbol
    assert.equal(token_names('goto l ::l::'), {
        'goto:goto',
        'name:l',
        ':::::',
        'name:l',
        ':::::',
    })
    -- a [[ inside a long bracket of level 0 is ordinary text
    assert.equal(token_names('x = [[ a [[ b ]] --[[ c [[ d ]]'), {
        'name:x',
        '=:=',
        'long_string:[[ a [[ b ]]',
    })
end

function testcase.invalid_escapes_are_rejected()
    for _, source in ipairs({
        'x = "\\q"',
        'x = "\\x4"',
        "x = '\\u'",
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'syntax_error')
    end
end
