local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')

local BOM = '\239\187\191'
local COMPILED

local function compiled()
    if not COMPILED then
        local diagnostics
        COMPILED, diagnostics = shared.compile('lexogram:luajit')
        assert.equal(diagnostics, {})
    end
    return COMPILED
end

-- the names and texts of every token of a source, skipped ones included
local function tokens(source)
    local result, err = lexogram.parse(compiled(), source)
    assert(result,
           err and (err.line .. ':' .. err.column .. ': ' .. err.message))
    local list = {}
    for i = 1, result.count do
        if events.op(result, i) == events.TOKEN then
            list[#list + 1] = events.name(result, i) .. ':' ..
                                  events.text(result, i)
        end
    end
    return list
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

-- the shapes of the statements of a source
local function statements(source)
    local result, err = lexogram.parse(compiled(), source)
    assert(result,
           err and (err.line .. ':' .. err.column .. ': ' .. err.message))
    local block = shape(events.tree(result))[1][2]
    table.remove(block, 1)
    return block
end

-- the kind names of the tokens of a source, skipped ones left out
local function kinds(source)
    local out = {}
    for _, t in ipairs(tokens(source)) do
        local name = t:match('^([^:]*):')
        if not SKIPPED[name] then
            out[#out + 1] = t
        end
    end
    return out
end

-- whether the grammar accepts each source
local function accepts(sources)
    local out = {}
    for i, source in ipairs(sources) do
        out[i] = lexogram.parse(compiled(), source) ~= nil
    end
    return out
end

function testcase.grammar_extends_lua51()
    local grammar = assert(shared.load('lexogram:luajit'))
    local lua51 = assert(shared.load('lexogram:lua51'))

    assert.equal(grammar.name, 'luajit')
    assert.equal(grammar.version, '2.1.1792527310-1')
    assert.equal(grammar.leading, {
        'shebang',
        'first_line_directive',
    })
    assert.equal(grammar.skip, {
        'space',
        'comment',
        'long_comment',
        'line_directive',
        'shebang',
        'first_line_directive',
    })
    -- the rules of lua51, with statements of their own
    local added = {
        'labelstat',
        'gotostat',
        'conststat',
        'continuestat',
        '_assignment',
        'ternary',
        '_middle',
        '_simpleexp_nocolon',
        '_suffix_nocolon',
        'shortfunc',
    }
    for _, name in ipairs(added) do
        assert.is_nil(lua51.rules[name])
        assert.is_string(grammar.rules[name])
        grammar.rules[name] = nil
    end
    for _, name in ipairs({
        'block',
        '_stat',
        '_laststat',
        'exprstat',
        'exp',
        'unop',
        'binop',
        '_simpleexp',
        '_suffix',
    }) do
        assert.not_equal(grammar.rules[name], lua51.rules[name])
        grammar.rules[name], lua51.rules[name] = nil, nil
    end
    assert.equal(grammar.rules, lua51.rules)
    assert.equal(grammar.keywords.contextual, {
        'goto',
        'const',
        'continue',
    })
end

function testcase.statements_of_luajit()
    assert.equal(statements('goto l ::l:: const x = 1 const function f() end'),
                 {
        {
            'gotostat',
            'goto',
            'l',
        },
        {
            'labelstat',
            '::',
            'l',
            '::',
        },
        {
            'conststat',
            'const',
            {
                'namelist',
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
        },
        {
            'conststat',
            'const',
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
        },
    })
    -- continue ends a block, as return and break do
    assert.equal(statements('for i = 1, 2 do continue; end')[1][3][8], {
        'block',
        {
            'continuestat',
            'continue',
        },
        ';',
    })
    -- empty statements anywhere
    assert.equal(statements(';; x = 1 ;; return ;;'), {
        ';',
        ';',
        {
            'exprstat',
            'x',
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
        ';',
        {
            'retstat',
            'return',
        },
        ';',
        ';',
    })
end

function testcase.assignments_and_calls()
    -- the first target or the call is not wrapped in suffixedexp: a name or
    -- a parenthesized expression alone is no statement
    assert.equal(statements('a.b(1) x, y.z = 1, 2 a ..= "s" a ~= 1'), {
        {
            'exprstat',
            'a',
            '.',
            'b',
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
        },
        {
            'exprstat',
            'x',
            ',',
            {
                'suffixedexp',
                'y',
                '.',
                'z',
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
                    '2',
                },
            },
        },
        {
            'exprstat',
            'a',
            '..=',
            {
                'exp',
                '"s"',
            },
        },
        {
            'exprstat',
            'a',
            '~=',
            {
                'exp',
                '1',
            },
        },
    })
    assert.equal(accepts({
        'x',
        '(x)',
        'a + = 1',
        'a ^= 2',
        'a, b += 1',
        'x.y',
    }), {
        false,
        false,
        false,
        false,
        false,
        -- a statement that ends with a suffix other than a call is
        -- accepted (see the differences)
        true,
    })
end

function testcase.goto_const_and_continue_are_names_elsewhere()
    assert.equal(kinds('goto = continue(const) const.x = goto'), {
        'name:goto',
        '=:=',
        'name:continue',
        '(:(',
        'name:const',
        '):)',
        'name:const',
        '.:.',
        'name:x',
        '=:=',
        'name:goto',
    })
    -- the name after goto, and the names of a const declaration
    assert.equal(kinds('goto continue const goto = 1'), {
        'goto:goto',
        'name:continue',
        'const:const',
        'name:goto',
        '=:=',
        'number:1',
    })
    -- continue is a statement only at the end of a block
    assert.equal(accepts({
        'while x do continue; y = 1 end',
        'while x do continue y end',
        'while x do continue = 1 end',
    }), {
        false,
        false,
        true,
    })
end

function testcase.names_have_the_bytes_from_80()
    assert.equal(tokens('caf\195\169 = \128x'), {
        'name:caf\195\169',
        'space: ',
        '=:=',
        'space: ',
        'name:\128x',
    })
end

function testcase.numbers_are_read_as_the_lexer_reads_them()
    local valid = {
        '3',
        '3.',
        '.5',
        '1e3',
        '1E+3',
        '1.5e-3',
        '08',
        '0x1F',
        '0x.8p1',
        '0x1p-2',
        '0B101',
        '1_000',
        '1_',
        '0_x1F',
        '1e_+_5',
        '1__.5',
        '1LL',
        '1ull',
        '1LLU',
        '1_L_L',
        '0x10ULL',
        '0b1LL',
        '2i',
        '1.5i',
        '0x1p4i',
        '0b11i',
        '18446744073709551615LL',
        '0xFFFFFFFFFFFFFFFFLL',
        '0b' .. ('1'):rep(64),
        '1e1048575',
        '0001e0001048575',
    }
    local invalid = {
        '1U',
        '1L',
        '1.5LL',
        '1e3LL',
        '1LLi',
        '0b2',
        '0b1.1',
        '0b1e2',
        '0b',
        '0x',
        '1e',
        '1..2',
        '1e5..x',
        '0x1p',
        '3print',
        '1i2',
        '0x.p1',
        '18446744073709551616LL',
        '0x1FFFFFFFFFFFFFFFFLL',
        '0b' .. ('1'):rep(65),
        '1e1048576',
        '3\195\169',
    }
    local function wrapped(list)
        local out = {}
        for i, n in ipairs(list) do
            out[i] = 'x = ' .. n
        end
        return out
    end
    for i, ok in ipairs(accepts(wrapped(valid))) do
        assert.is_true(ok, valid[i])
    end
    for i, ok in ipairs(accepts(wrapped(invalid))) do
        assert.is_false(ok, invalid[i])
    end
    -- the run that the lexer reads must be one number (malformed number)
    for _, source in ipairs({
        'x = 3print',
        'x = 1e1048576',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'invalid_token')
        assert.equal(err.pos, 5)
        assert.equal(err.message, 'invalid number')
    end
    -- a number is one token, with its underscores
    assert.equal(tokens('x=1_000LL'), {
        'name:x',
        '=:=',
        'number:1_000LL',
    })
    -- the sign after the exponent mark of a hexadecimal number ends it: e
    -- is a digit there
    assert.equal(tokens('x=0x1e+1'), {
        'name:x',
        '=:=',
        'number:0x1e',
        '+:+',
        'number:1',
    })
end

function testcase.strings_and_long_strings()
    assert.equal(accepts({
        'x = "\\u{10FFFF}\\x41\\z  \\065"',
        'x = "\\u{110000}"',
        'x = "\\q"',
        'x = "\\256"',
        'x = [[a[[b]]',
    }), {
        true,
        false,
        false,
        false,
        true,
    })
end

function testcase.line_directives_are_skipped()
    assert.equal(tokens('x = 1\n# 10 "file.lua"\ny = 2'), {
        'name:x',
        'space: ',
        '=:=',
        'space: ',
        'number:1',
        'line_directive:\n# 10 "file.lua"',
        'space:\n',
        'name:y',
        'space: ',
        '=:=',
        'space: ',
        'number:2',
    })
    -- at the start, and after a byte order mark
    assert.equal(tokens(BOM .. '#\t7\nx = 1')[1],
                 'first_line_directive:' .. BOM .. '#\t7')
    -- a "#" that starts a line without a number is the length operator
    assert.equal(tokens('x =\n#t')[5], '#:#')
    assert.equal(accepts({
        -- a malformed directive, one not at the start of a line, and one
        -- right after the shebang line
        'x = 1\n# 10 x\n',
        'x = 1\n  # 10\n',
        '#!lua\n# 2\nx = 1',
        -- a name in single quotes, and one that goes to the next line
        'x = 1\n# 7 \'f\'\n',
        'x = 1\n# 5 "a\\z\n b"\n',
        -- the largest line number
        'x = 1\n#2147483379\n',
        'x = 1\n#2147483380\n',
        'x = 1\n# 5 "a\\z  b"\n',
    }), {
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
    })
    -- a larger line number makes the directive invalid (malformed line
    -- number directive)
    local result, err = lexogram.parse(compiled(), 'x = 1\n# 99999999999\n')
    assert.is_nil(result)
    assert.equal(err.code, 'invalid_token')
    assert.equal(err.pos, 6)
    assert.equal(err.message, 'invalid line_directive')
end

function testcase.shebang_and_byte_order_mark_are_skipped()
    assert.equal(tokens('#!/usr/bin/env luajit\r\nx = #t')[1],
                 'shebang:#!/usr/bin/env luajit\r\n')
    assert.equal(tokens(BOM .. 'x = 1')[1], 'shebang:' .. BOM)
    assert.equal(tokens(BOM .. '#!lua\nx = 1')[1],
                 'shebang:' .. BOM .. '#!lua\n')
    assert.equal(accepts({
        '#x\nx = 1',
        'x = 1\n#!lua',
        -- a second byte order mark is a part of a name
        BOM .. BOM .. 'return 1',
    }), {
        false,
        false,
        false,
    })
end

function testcase.ternary_operators()
    -- the operands of the middle are suffixedexp as elsewhere, and ":" in
    -- the middle is no method call
    assert.equal(statements('x = c ? a : m()')[1][4][2], {
        'exp',
        {
            'suffixedexp',
            'c',
        },
        {
            'ternary',
            '?',
            {
                'suffixedexp',
                'a',
            },
            ':',
            {
                'exp',
                {
                    'suffixedexp',
                    'm',
                    {
                        'args',
                        '(',
                        ')',
                    },
                },
            },
        },
    })
    assert.equal(accepts({
        'x = c ? a:m() : b',
        'x = c ? (a:m()) : b',
        'x = c ? t[a:m()] : f(a:m())',
        'x = c ? f -> f : g',
        'x = c ? x ? y : 1 : w',
        'x = c ? x ? y : z:m() : w',
        'x = c ? a?.:m() : d',
        'x = c ? a : b ? d : e',
    }), {
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
    })
end

function testcase.short_functions_and_safe_navigation()
    assert.equal(statements('y = |a| -> a?.b:m?.() ?? !z')[1][4][2][2], {
        'shortfunc',
        '|',
        {
            'parlist',
            'a',
        },
        '|',
        '->',
        {
            'exp',
            {
                'suffixedexp',
                'a',
                '?.',
                'b',
                ':',
                'm',
                '?.',
                {
                    'args',
                    '(',
                    ')',
                },
            },
            {
                'binop',
                '??',
            },
            {
                'unop',
                '!',
            },
            {
                'suffixedexp',
                'z',
            },
        },
    })
    assert.equal(accepts({
        'f = x -> x + 1',
        'f = || -> do return 1 end',
        'f = |...| -> ...',
        'g(x -> x, y)',
        'x -> 1',
        'x = |x -> x',
        'x = a?.[1] .. a?.(1) .. a?."s"',
        'x = a ?. b',
        'x = a ~> b',
        'x = ~a & b | c ~ d << 1 >> 2 ~>> 3 != e',
    }), {
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        -- ?. is one token, around which white space may be
        true,
        false,
        true,
    })
end
