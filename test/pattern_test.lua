local testcase = require('testcase')
local assert = require('assert')
local pattern = require('lexogram.pattern')

-- helpers that build expected AST nodes

local function lit(pos, value)
    return {
        type = 'literal',
        pos = pos,
        value = value,
    }
end

local function cls(pos, unit, ranges)
    return {
        type = 'class',
        pos = pos,
        unit = unit,
        ranges = ranges,
    }
end

local function ref(pos, name)
    return {
        type = 'ref',
        pos = pos,
        name = name,
    }
end

local function seq(items)
    return {
        type = 'seq',
        pos = items[1].pos,
        items = items,
    }
end

local function choice(items)
    return {
        type = 'choice',
        pos = items[1].pos,
        ordered = false,
        items = items,
    }
end

local function ordered_choice(items)
    return {
        type = 'choice',
        pos = items[1].pos,
        ordered = true,
        items = items,
    }
end

local function postfix(t, item)
    return {
        type = t,
        pos = item.pos,
        item = item,
    }
end

-- parse src in the context (default 'tokens') and return the AST
local function parse_ok(src, context)
    local ast, err = pattern.parse(src, context or 'tokens')
    assert.is_nil(err)
    return ast
end

-- parse src in the context (default 'tokens') and return the error without
-- its message
local function parse_err(src, context)
    local ast, err = pattern.parse(src, context or 'tokens')
    assert.is_nil(ast)
    assert.is_string(err.message)
    assert.not_equal(err.message, '')
    return {
        pos = err.pos,
        code = err.code,
    }
end

-- check that each case { src, pos, code } fails as expected
local function check_errors(cases, context)
    for _, case in ipairs(cases) do
        local err = parse_err(case[1], context)
        assert.equal(err, {
            pos = case[2],
            code = case[3],
        })
    end
end

-- arguments

function testcase.parse_raises_for_non_string_src()
    local err = assert.throws(pattern.parse, 1, 'tokens')
    assert.match(err, 'src must be string, got number')

    err = assert.throws(pattern.parse, nil, 'tokens')
    assert.match(err, 'src must be string, got nil')
end

function testcase.parse_raises_for_invalid_context()
    local err = assert.throws(pattern.parse, '"a"')
    assert.match(err, 'context must be string, got nil')

    err = assert.throws(pattern.parse, '"a"', {})
    assert.match(err, 'context must be string, got table')

    err = assert.throws(pattern.parse, '"a"', 'grammar')
    assert.match(err, 'unsupported context: grammar')

    err = assert.throws(pattern.parse, '"a"', 'TOKENS')
    assert.match(err, 'unsupported context: TOKENS')
end

-- literal

function testcase.parse_returns_literal_node()
    assert.equal(parse_ok('"abc"'), lit(1, 'abc'))
    assert.equal(parse_ok('  "a"'), lit(3, 'a'))
    -- whitespace and punctuation inside quotes are part of the value
    assert.equal(parse_ok('" a\t[(|/@]"'), lit(1, ' a\t[(|/@]'))
end

function testcase.parse_decodes_literal_escapes()
    for _, case in ipairs({
        {
            '"\\\\"',
            '\\',
        },
        {
            '"\\""',
            '"',
        },
        {
            '"\\n\\r\\t"',
            '\n\r\t',
        },
        {
            '"\\x41\\xff\\x00"',
            'A\255\0',
        },
        {
            '"\\u{41}\\u{e9}\\u{3042}\\u{1F600}\\u{0000041}"',
            'A\195\169\227\129\130\240\159\152\128A',
        },
        {
            '"\\u{10FFFF}"',
            '\244\143\191\191',
        },
        {
            '"a\\nb\\x41c"',
            'a\nbAc',
        },
        {
            '"\\x414"',
            'A4',
        },
    }) do
        assert.equal(parse_ok(case[1]), lit(1, case[2]))
    end
end

function testcase.parse_accepts_raw_utf8_in_literal()
    assert.equal(parse_ok('"\195\169\227\129\130x"'),
                 lit(1, '\195\169\227\129\130x'))
end

function testcase.parse_returns_literal_errors()
    check_errors({
        {
            '"abc',
            1,
            'unterminated_literal',
        },
        {
            '"a\nb"',
            1,
            'unterminated_literal',
        },
        {
            '"a\rb"',
            1,
            'unterminated_literal',
        },
        {
            '"a\\',
            1,
            'unterminated_literal',
        },
        {
            '_a "b',
            4,
            'unterminated_literal',
        },
        {
            '""',
            1,
            'empty_literal',
        },
        {
            '"a" ""',
            5,
            'empty_literal',
        },
    })
end

function testcase.parse_returns_invalid_escape_in_literal()
    check_errors({
        {
            '"\\q"',
            2,
            'invalid_escape',
        },
        {
            '"a\\x4"',
            3,
            'invalid_escape',
        },
        {
            '"\\xg0"',
            2,
            'invalid_escape',
        },
        {
            '"\\x4',
            2,
            'invalid_escape',
        },
        {
            '"\\u{4',
            2,
            'invalid_escape',
        },
        {
            '"\\u41"',
            2,
            'invalid_escape',
        },
        {
            '"\\u{}"',
            2,
            'invalid_escape',
        },
        {
            '"\\u{41"',
            2,
            'invalid_escape',
        },
        {
            '"\\u{4g}"',
            2,
            'invalid_escape',
        },
        {
            '"\\]"',
            2,
            'invalid_escape',
        },
        {
            '"\\-"',
            2,
            'invalid_escape',
        },
        {
            '"\\\n"',
            2,
            'invalid_escape',
        },
    })
end

function testcase.parse_returns_invalid_codepoint_in_literal()
    check_errors({
        {
            '"\\u{D800}"',
            2,
            'invalid_codepoint',
        },
        {
            '"a\\u{DFFF}"',
            3,
            'invalid_codepoint',
        },
        {
            '"\\u{110000}"',
            2,
            'invalid_codepoint',
        },
        {
            '"\\u{FFFFFFFFFFFFFFFFFFFF}"',
            2,
            'invalid_codepoint',
        },
    })
end

function testcase.parse_returns_invalid_utf8_in_literal()
    check_errors({
        {
            '"ab\255"',
            4,
            'invalid_utf8',
        },
        {
            '"a\195"',
            3,
            'invalid_utf8',
        },
        {
            '"\237\160\128"',
            2,
            'invalid_utf8',
        },
        {
            '"\192\128"',
            2,
            'invalid_utf8',
        },
    })
end

-- class

function testcase.parse_returns_byte_class()
    assert.equal(parse_ok('[abc]'), cls(1, 'byte', {
        {
            97,
            99,
        },
    }))
    assert.equal(parse_ok(' [a-z0-9_]'), cls(2, 'byte', {
        {
            48,
            57,
        },
        {
            95,
            95,
        },
        {
            97,
            122,
        },
    }))
end

function testcase.parse_normalizes_class_ranges()
    for _, case in ipairs({
        -- overlapping
        {
            '[d-fa-ec]',
            {
                {
                    97,
                    102,
                },
            },
        },
        -- adjacent
        {
            '[a-cd-f]',
            {
                {
                    97,
                    102,
                },
            },
        },
        -- contained
        {
            '[a-zb-cz]',
            {
                {
                    97,
                    122,
                },
            },
        },
        -- disjoint, out of order
        {
            '[xa]',
            {
                {
                    97,
                    97,
                },
                {
                    120,
                    120,
                },
            },
        },
    }) do
        assert.equal(parse_ok(case[1]), cls(1, 'byte', case[2]))
    end
end

function testcase.parse_decodes_class_escapes()
    assert.equal(parse_ok('[\\]\\-\\^\\\\\\"\\n\\r\\t]'), cls(1, 'byte', {
        {
            9,
            10,
        },
        {
            13,
            13,
        },
        {
            34,
            34,
        },
        {
            45,
            45,
        },
        {
            92,
            94,
        },
    }))
    assert.equal(parse_ok('[\\x41-\\x43]'), cls(1, 'byte', {
        {
            65,
            67,
        },
    }))
end

function testcase.parse_treats_special_characters_in_class_as_ordinary()
    assert.equal(parse_ok('["[(]'), cls(1, 'byte', {
        {
            34,
            34,
        },
        {
            40,
            40,
        },
        {
            91,
            91,
        },
    }))
    -- "^" is ordinary unless it is the first character
    assert.equal(parse_ok('[a^]'), cls(1, 'byte', {
        {
            94,
            94,
        },
        {
            97,
            97,
        },
    }))
    assert.equal(parse_ok('[\\^a]'), cls(1, 'byte', {
        {
            94,
            94,
        },
        {
            97,
            97,
        },
    }))
end

function testcase.parse_classifies_high_byte_escapes_as_byte()
    assert.equal(parse_ok('[\\x80-\\xff]'), cls(1, 'byte', {
        {
            128,
            255,
        },
    }))
    assert.equal(parse_ok('[a\\xC0]'), cls(1, 'byte', {
        {
            97,
            97,
        },
        {
            192,
            192,
        },
    }))
end

function testcase.parse_classifies_code_point_elements()
    for _, case in ipairs({
        {
            '[\\u{41}]',
            {
                {
                    65,
                    65,
                },
            },
        },
        {
            '[\195\169]',
            {
                {
                    233,
                    233,
                },
            },
        },
        {
            '[a-\195\169]',
            {
                {
                    97,
                    233,
                },
            },
        },
        {
            '[\\x41\\u{3042}]',
            {
                {
                    65,
                    65,
                },
                {
                    0x3042,
                    0x3042,
                },
            },
        },
        {
            '[\\u{10000}-\\u{10FFFF}]',
            {
                {
                    0x10000,
                    0x10FFFF,
                },
            },
        },
    }) do
        assert.equal(parse_ok(case[1]), cls(1, 'codepoint', case[2]))
    end
end

function testcase.parse_removes_surrogates_from_code_point_ranges()
    assert.equal(parse_ok('[\\u{D000}-\\u{E000}]'), cls(1, 'codepoint', {
        {
            0xD000,
            0xD7FF,
        },
        {
            0xE000,
            0xE000,
        },
    }))
end

function testcase.parse_resolves_negated_byte_class()
    assert.equal(parse_ok('[^a]'), cls(1, 'byte', {
        {
            0,
            96,
        },
        {
            98,
            255,
        },
    }))
    assert.equal(parse_ok('[^\\x00-\\x7f]'), cls(1, 'byte', {
        {
            128,
            255,
        },
    }))
    assert.equal(parse_ok('[^\\x80-\\xff]'), cls(1, 'byte', {
        {
            0,
            127,
        },
    }))
    assert.equal(parse_ok('[^^]'), cls(1, 'byte', {
        {
            0,
            93,
        },
        {
            95,
            255,
        },
    }))
end

function testcase.parse_resolves_negated_code_point_class()
    assert.equal(parse_ok('[^\\u{41}]'), cls(1, 'codepoint', {
        {
            0,
            64,
        },
        {
            66,
            0xD7FF,
        },
        {
            0xE000,
            0x10FFFF,
        },
    }))
    assert.equal(parse_ok('[^\\u{0}-\\u{D7FF}]'), cls(1, 'codepoint', {
        {
            0xE000,
            0x10FFFF,
        },
    }))
    assert.equal(parse_ok('[^\\u{E000}-\\u{10FFFF}]'), cls(1, 'codepoint', {
        {
            0,
            0xD7FF,
        },
    }))
    assert.equal(parse_ok('[^\\u{D000}-\\u{E000}]'), cls(1, 'codepoint', {
        {
            0,
            0xCFFF,
        },
        {
            0xE001,
            0x10FFFF,
        },
    }))
end

function testcase.parse_returns_class_structure_errors()
    check_errors({
        {
            '[]',
            1,
            'empty_class',
        },
        {
            '[^]',
            1,
            'empty_class',
        },
        {
            '[^\\x00-\\xff]',
            1,
            'empty_class',
        },
        {
            '[^\\u{0}-\\u{D7FF}\\u{E000}-\\u{10FFFF}]',
            1,
            'empty_class',
        },
        {
            '[abc',
            1,
            'unterminated_class',
        },
        {
            '[a\n]',
            1,
            'unterminated_class',
        },
        {
            '[a\r]',
            1,
            'unterminated_class',
        },
        {
            '[a-',
            1,
            'unterminated_class',
        },
        {
            '[a-\n]',
            1,
            'unterminated_class',
        },
        {
            '[\\',
            1,
            'unterminated_class',
        },
        {
            '[a-\\',
            1,
            'unterminated_class',
        },
        {
            '[^',
            1,
            'unterminated_class',
        },
        {
            '_a [b',
            4,
            'unterminated_class',
        },
    })
end

function testcase.parse_returns_invalid_range()
    check_errors({
        {
            '[-a]',
            2,
            'invalid_range',
        },
        {
            '[a-]',
            3,
            'invalid_range',
        },
        {
            '[a-z-9]',
            5,
            'invalid_range',
        },
        {
            '[^-a]',
            3,
            'invalid_range',
        },
        {
            '[a--z]',
            4,
            'invalid_range',
        },
        {
            '[z-a]',
            2,
            'invalid_range',
        },
        {
            '[ab-a]',
            3,
            'invalid_range',
        },
        {
            '[\\u{100}-\\u{41}]',
            2,
            'invalid_range',
        },
    })
end

function testcase.parse_returns_class_element_errors()
    check_errors({
        {
            '[\\xff\\u{100}]',
            6,
            'mixed_class',
        },
        {
            '[\\u{100}\\xff]',
            9,
            'mixed_class',
        },
        {
            '[\\x80-\\u{100}]',
            7,
            'mixed_class',
        },
        {
            '[\195\169\\x80]',
            4,
            'mixed_class',
        },
        {
            '[\\q]',
            2,
            'invalid_escape',
        },
        {
            '[\\x4]',
            2,
            'invalid_escape',
        },
        {
            '[\\u{DFFF}]',
            2,
            'invalid_codepoint',
        },
        {
            '[a\255]',
            3,
            'invalid_utf8',
        },
    })
end

-- names

function testcase.parse_expands_builtin_classes()
    assert.equal(parse_ok('ALPHA'), cls(1, 'byte', {
        {
            65,
            90,
        },
        {
            97,
            122,
        },
    }))
    assert.equal(parse_ok('  DIGIT'), cls(3, 'byte', {
        {
            48,
            57,
        },
    }))
    assert.equal(parse_ok('HEXDIGIT'), cls(1, 'byte', {
        {
            48,
            57,
        },
        {
            65,
            70,
        },
        {
            97,
            102,
        },
    }))
    assert.equal(parse_ok('ANY'), cls(1, 'byte', {
        {
            0,
            255,
        },
    }))
end

function testcase.parse_returns_fresh_builtin_ranges()
    local ast = parse_ok('DIGIT')
    ast.ranges[1][1] = 0

    assert.equal(parse_ok('DIGIT').ranges, {
        {
            48,
            57,
        },
    })
end

function testcase.parse_returns_fragment_reference()
    assert.equal(parse_ok('_frag'), ref(1, '_frag'))
    assert.equal(parse_ok('_'), ref(1, '_'))
    assert.equal(parse_ok(' _A1_b'), ref(2, '_A1_b'))
end

function testcase.parse_ends_name_at_non_name_character()
    assert.equal(parse_ok('_a_b9 _c'), seq({
        ref(1, '_a_b9'),
        ref(7, '_c'),
    }))
    assert.equal(parse_ok('DIGIT"a"'), seq({
        cls(1, 'byte', {
            {
                48,
                57,
            },
        }),
        lit(6, 'a'),
    }))
end

function testcase.parse_returns_name_errors()
    check_errors({
        {
            'FOO',
            1,
            'unknown_builtin',
        },
        {
            '"a" A1_',
            5,
            'unknown_builtin',
        },
        {
            'DIGIT_X',
            1,
            'unknown_builtin',
        },
        {
            'ident',
            1,
            'invalid_reference',
        },
        {
            'Foo',
            1,
            'invalid_reference',
        },
        {
            '"a" aBC',
            5,
            'invalid_reference',
        },
    })
end

-- sequence, choice and postfix operators

function testcase.parse_returns_sequence()
    assert.equal(parse_ok('"a" "b" "c"'), seq({
        lit(1, 'a'),
        lit(5, 'b'),
        lit(9, 'c'),
    }))
    assert.equal(parse_ok('"a""b"'), seq({
        lit(1, 'a'),
        lit(4, 'b'),
    }))
end

function testcase.parse_returns_choice()
    assert.equal(parse_ok('"a" | "b" | "c"'), choice({
        lit(1, 'a'),
        lit(7, 'b'),
        lit(13, 'c'),
    }))
    assert.equal(parse_ok('"a"|"b"'), choice({
        lit(1, 'a'),
        lit(5, 'b'),
    }))
end

function testcase.parse_returns_postfix_operators()
    assert.equal(parse_ok('"a"?'), postfix('opt', lit(1, 'a')))
    assert.equal(parse_ok('"a"*'), postfix('star', lit(1, 'a')))
    assert.equal(parse_ok(' "a" +'), postfix('plus', lit(2, 'a')))
    assert.equal(parse_ok('_x*'), postfix('star', ref(1, '_x')))
end

function testcase.parse_applies_precedence()
    -- postfix binds tighter than concatenation, which binds tighter than
    -- choice
    assert.equal(parse_ok('"a" "b"* | "c"'), choice({
        seq({
            lit(1, 'a'),
            postfix('star', lit(5, 'b')),
        }),
        lit(12, 'c'),
    }))
    assert.equal(parse_ok('"a" | "b" "c"+'), choice({
        lit(1, 'a'),
        seq({
            lit(7, 'b'),
            postfix('plus', lit(11, 'c')),
        }),
    }))
end

function testcase.parse_groups_without_node()
    assert.equal(parse_ok('("a")'), lit(2, 'a'))
    assert.equal(parse_ok('(("a"))'), lit(3, 'a'))
    assert.equal(parse_ok('("a" "b")*'), postfix('star', seq({
        lit(2, 'a'),
        lit(6, 'b'),
    })))
    assert.equal(parse_ok('("a"*)*'),
                 postfix('star', postfix('star', lit(2, 'a'))))
end

function testcase.parse_does_not_flatten_groups()
    assert.equal(parse_ok('"a" ("b" "c")'), seq({
        lit(1, 'a'),
        seq({
            lit(6, 'b'),
            lit(10, 'c'),
        }),
    }))
    assert.equal(parse_ok('("a" | "b") | "c"'), choice({
        choice({
            lit(2, 'a'),
            lit(8, 'b'),
        }),
        lit(15, 'c'),
    }))
    assert.equal(parse_ok('("a" | "b") "c"'), seq({
        choice({
            lit(2, 'a'),
            lit(8, 'b'),
        }),
        lit(13, 'c'),
    }))
end

function testcase.parse_ignores_whitespace()
    assert.equal(parse_ok(' \t\r\n"a"\n\t|\r "b" '), choice({
        lit(5, 'a'),
        lit(13, 'b'),
    }))
    assert.equal(parse_ok('( "a" ) *'), postfix('star', lit(3, 'a')))
end

-- other errors

function testcase.parse_returns_unexpected_char()
    check_errors({
        {
            '@',
            1,
            'unexpected_char',
        },
        {
            '"a" ;',
            5,
            'unexpected_char',
        },
        {
            '\195\169',
            1,
            'unexpected_char',
        },
        {
            '"a" }',
            5,
            'unexpected_char',
        },
        {
            '1',
            1,
            'unexpected_char',
        },
        {
            ']',
            1,
            'unexpected_char',
        },
        {
            '"a" | \0',
            7,
            'unexpected_char',
        },
    })
end

function testcase.parse_returns_ordered_choice_not_allowed()
    check_errors({
        {
            '"a" / "b"',
            5,
            'ordered_choice_not_allowed',
        },
        {
            '/',
            1,
            'ordered_choice_not_allowed',
        },
        {
            '"a" /',
            5,
            'ordered_choice_not_allowed',
        },
    })
end

function testcase.parse_returns_unbalanced_paren()
    check_errors({
        {
            '("a"',
            1,
            'unbalanced_paren',
        },
        {
            '"a" ("b" | "c"',
            5,
            'unbalanced_paren',
        },
        {
            '(("a")',
            1,
            'unbalanced_paren',
        },
        {
            '"a")',
            4,
            'unbalanced_paren',
        },
        {
            '("a"))',
            6,
            'unbalanced_paren',
        },
    })
end

function testcase.parse_returns_missing_operand()
    check_errors({
        {
            '',
            1,
            'missing_operand',
        },
        {
            ' \t\r\n',
            1,
            'missing_operand',
        },
        {
            '()',
            2,
            'missing_operand',
        },
        {
            '"a" |',
            6,
            'missing_operand',
        },
        {
            '"a" |  ',
            8,
            'missing_operand',
        },
        {
            '| "a"',
            1,
            'missing_operand',
        },
        {
            '"a" || "b"',
            6,
            'missing_operand',
        },
        {
            '*"a"',
            1,
            'missing_operand',
        },
        {
            '(*)',
            2,
            'missing_operand',
        },
        {
            '"a" (|"b")',
            6,
            'missing_operand',
        },
        {
            ')',
            1,
            'missing_operand',
        },
        {
            '(',
            2,
            'missing_operand',
        },
    })
end

function testcase.parse_returns_repeated_postfix()
    check_errors({
        {
            '"a"**',
            5,
            'repeated_postfix',
        },
        {
            '"a"+*',
            5,
            'repeated_postfix',
        },
        {
            '"a" * ?',
            7,
            'repeated_postfix',
        },
    })
end

function testcase.parse_reads_possessive_repetitions_in_rules()
    for _, case in ipairs({
        {
            'a?+',
            'opt',
        },
        {
            'a*+',
            'star',
        },
        {
            'a++',
            'plus',
        },
    }) do
        local ast = parse_ok(case[1], 'rules')
        assert.equal(ast.type, case[2])
        assert.is_true(ast.possessive)
        assert.equal(ast.item.name, 'a')
    end
    -- a group, and the next element after a possessive repetition
    local ast = parse_ok('(a b)*+ c', 'rules')
    assert.equal(ast.items[1].type, 'star')
    assert.is_true(ast.items[1].possessive)
    assert.equal(ast.items[2].name, 'c')
    -- a possessive repetition takes no further operator
    assert.equal(parse_err('a?++', 'rules'), {
        pos = 4,
        code = 'repeated_postfix',
    })
    -- the "+" must follow the operator directly
    assert.is_nil(parse_ok('a*', 'rules').possessive)
    assert.equal(parse_err('a* +', 'rules'), {
        pos = 4,
        code = 'repeated_postfix',
    })
    -- tokens are matched by longest match, where a possessive repetition
    -- means nothing
    check_errors({
        {
            '"a"*+',
            5,
            'possessive_not_allowed',
        },
        {
            '"a"?+',
            5,
            'possessive_not_allowed',
        },
    })
end

-- a repetition node of a count, with count and, when possessive, group
local function counted(t, item, count, group)
    return {
        type = t,
        pos = item.pos,
        item = item,
        count = count,
        possessive = group and true or nil,
        group = group,
    }
end

function testcase.parse_expands_counts_of_repetitions()
    local a = lit(1, 'a')
    -- n copies
    assert.equal(parse_ok('"a"{3}'), seq({
        a,
        a,
        a,
    }))
    assert.equal(parse_ok('"a"{1}'), a)
    -- n copies, the last one repeated without a limit
    assert.equal(parse_ok('"a"{2,}'), seq({
        a,
        counted('plus', a, '{2,}'),
    }))
    assert.equal(parse_ok('"a"{0,}'), counted('star', a, '{0,}'))
    -- n copies, then m - n nested optional copies
    assert.equal(parse_ok('"a"{1,3}'), seq({
        a,
        counted('opt', seq({
            a,
            counted('opt', a, '{1,3}'),
        }), '{1,3}'),
    }))
    assert.equal(parse_ok('"a"{0,1}'), counted('opt', a, '{0,1}'))
    -- each copy is a node of its own
    local ast = parse_ok('("a" "b"){2}')
    assert.not_rawequal(ast.items[1], ast.items[2])
    assert.equal(ast.items[1], ast.items[2])
    -- after a group, with white space before it, and nested
    assert.equal(parse_ok('(DIGIT) {2}').type, 'seq')
    ast = parse_ok('("a"{2}){3}')
    assert.equal(#ast.items, 3)
    assert.equal(#ast.items[3].items, 2)
    -- a repetition counted
    assert.equal(parse_ok('("a"+){2}'), seq({
        postfix('plus', lit(2, 'a')),
        postfix('plus', lit(2, 'a')),
    }))
    -- in rules, possessive
    local group = {
        count = '{2,}',
    }
    assert.equal(parse_ok('a{2,}+', 'rules'), seq({
        ref(1, 'a'),
        counted('plus', ref(1, 'a'), '{2,}', group),
    }))
    ast = parse_ok('a{0,2}+', 'rules')
    assert.rawequal(ast.group, ast.item.items[2].group)
    -- the copies of a possessive count keep a group each
    ast = parse_ok('(a{0,2}+){2}', 'rules')
    local first, second = ast.items[1], ast.items[2]
    assert.rawequal(first.group, first.item.items[2].group)
    assert.rawequal(second.group, second.item.items[2].group)
    assert.not_rawequal(first.group, second.group)
end

function testcase.parse_rejects_invalid_counts()
    check_errors({
        {
            '"a"{}',
            5,
            'invalid_repetition',
        },
        {
            '"a"{,2}',
            5,
            'invalid_repetition',
        },
        {
            '"a"{ 2}',
            5,
            'invalid_repetition',
        },
        {
            '"a"{2 }',
            4,
            'invalid_repetition',
        },
        {
            '"a"{2',
            4,
            'invalid_repetition',
        },
        {
            '"a"{0}',
            4,
            'invalid_repetition',
        },
        {
            '"a"{0,0}',
            4,
            'invalid_repetition',
        },
        {
            '"a"{3,2}',
            4,
            'invalid_repetition',
        },
        {
            '"a"{1001}',
            4,
            'invalid_repetition',
        },
        {
            '"a"{1,99999}',
            4,
            'invalid_repetition',
        },
        -- the counts would make more than 10000 nodes
        {
            '("a"{100}){101}',
            11,
            'invalid_repetition',
        },
        -- another postfix operator, and a lookahead
        {
            '"a"{2}?',
            7,
            'repeated_postfix',
        },
        {
            '"a"?{2}',
            5,
            'repeated_postfix',
        },
        {
            '"a"{2}{3}',
            7,
            'repeated_postfix',
        },
        {
            '(?="a"){2}',
            8,
            'invalid_lookahead',
        },
        -- a possessive count in tokens
        {
            '"a"{2,}+',
            8,
            'possessive_not_allowed',
        },
        {
            '{2}',
            1,
            'missing_operand',
        },
    })
    -- a fixed count repeats nothing to make possessive
    assert.equal(parse_err('a{2}+', 'rules'), {
        pos = 5,
        code = 'invalid_repetition',
    })
end

function testcase.parse_reads_aliases_in_rules()
    -- a group or a reference, reported as a rule
    assert.equal(parse_ok('(a b)->c', 'rules'), {
        type = 'alias',
        pos = 2,
        item = seq({
            ref(2, 'a'),
            ref(4, 'b'),
        }),
        name = 'c',
        name_pos = 8,
    })
    assert.equal(parse_ok('(x) -> c d', 'rules'), seq({
        {
            type = 'alias',
            pos = 2,
            item = ref(2, 'x'),
            name = 'c',
            name_pos = 8,
        },
        ref(10, 'd'),
    }))
    -- nested, and over a count
    local ast = parse_ok('((a)->b){2}', 'rules')
    assert.equal(ast.type, 'seq')
    assert.equal(ast.items[2].type, 'alias')
    assert.not_rawequal(ast.items[1], ast.items[2])
    check_errors({
        -- the range of an alias is written in parentheses
        {
            'a->c',
            2,
            'invalid_alias',
        },
        {
            'a b->c',
            4,
            'invalid_alias',
        },
        -- a repetition of an alias is written with a group around it
        {
            '(a)->c*',
            7,
            'repeated_postfix',
        },
        {
            '(a)->c{2}',
            7,
            'repeated_postfix',
        },
        {
            '(a)->b->c',
            7,
            'repeated_postfix',
        },
        -- an alias of a repetition, too
        {
            'a*->c',
            3,
            'repeated_postfix',
        },
        {
            'a{2}->c',
            5,
            'repeated_postfix',
        },
        -- a rule name must follow
        {
            '(a)->',
            4,
            'invalid_alias',
        },
        {
            '(a)->"x"',
            4,
            'invalid_alias',
        },
        {
            '(a)->(b)',
            4,
            'invalid_alias',
        },
    }, 'rules')
    -- tokens are no rules
    check_errors({
        {
            '("a")->c',
            6,
            'alias_not_allowed',
        },
        -- a "-" alone is still no operator
        {
            '"a" - "b"',
            5,
            'unexpected_char',
        },
    })
end

function testcase.parse_reads_lookaheads_in_tokens()
    local ast = parse_ok('"x" (?!("ab" | "ac")) (?= DIGIT "-"*)')
    assert.equal(ast.type, 'seq')
    local neg, pos = ast.items[2], ast.items[3]
    assert.equal(neg.type, 'lookahead')
    assert.is_true(neg.negative)
    assert.equal(neg.pos, 5)
    assert.equal(neg.item.type, 'choice')
    assert.equal(pos.type, 'lookahead')
    assert.is_false(pos.negative)
    assert.equal(pos.item.type, 'seq')
    -- nested, and inside a repetition
    ast = parse_ok('("a" (?="b" (?!"c")))*')
    assert.equal(ast.type, 'star')
    local inner = ast.item.items[2]
    assert.equal(inner.type, 'lookahead')
    assert.equal(inner.item.items[2].type, 'lookahead')
    -- a group that starts with "?" is not a lookahead
    assert.equal(parse_err('(? "a")'), {
        pos = 2,
        code = 'missing_operand',
    })
    check_errors({
        -- a lookahead consumes nothing, so repeating it means nothing
        {
            '(?="a")*',
            8,
            'invalid_lookahead',
        },
        {
            '(?=)',
            4,
            'missing_operand',
        },
        {
            '(?="a"',
            1,
            'unbalanced_paren',
        },
    })
    -- rules choose with token lookahead instead
    assert.equal(parse_err('a (?=b)', 'rules'), {
        pos = 3,
        code = 'lookahead_not_allowed',
    })
end

function testcase.parse_reports_first_error_from_left()
    check_errors({
        {
            '"" @',
            1,
            'empty_literal',
        },
        {
            '@ ""',
            1,
            'unexpected_char',
        },
        {
            '("a" @',
            6,
            'unexpected_char',
        },
        {
            '*""',
            1,
            'missing_operand',
        },
    })
end

-- rules context

function testcase.parse_accepts_both_contexts()
    assert.equal(parse_ok('"a"', 'tokens'), lit(1, 'a'))
    assert.equal(parse_ok('"a"', 'rules'), lit(1, 'a'))
end

function testcase.rules_returns_reference_for_each_name_shape()
    for _, case in ipairs({
        {
            'ident',
            1,
        },
        {
            'Foo',
            1,
        },
        {
            'aBC',
            1,
        },
        {
            'foo_BAR9',
            1,
        },
        {
            '_operand',
            1,
        },
        {
            '_',
            1,
        },
        {
            '_ABC',
            1,
        },
        {
            '  expr',
            3,
        },
    }) do
        local name = case[1]:match('^%s*(.*)$')
        assert.equal(parse_ok(case[1], 'rules'), ref(case[2], name))
    end
end

function testcase.rules_parses_literals_as_in_tokens()
    assert.equal(parse_ok('"[a-z]" "\\u{41}\\n"', 'rules'), seq({
        lit(1, '[a-z]'),
        lit(9, 'A\n'),
    }))
end

function testcase.rules_returns_reserved_name()
    check_errors({
        {
            'DIGIT',
            1,
            'reserved_name',
        },
        {
            'ANY',
            1,
            'reserved_name',
        },
        {
            'FOO',
            1,
            'reserved_name',
        },
        {
            'A1_',
            1,
            'reserved_name',
        },
        {
            'expr  NUM',
            7,
            'reserved_name',
        },
    }, 'rules')
end

function testcase.rules_returns_class_not_allowed()
    check_errors({
        {
            '[a-z]',
            1,
            'class_not_allowed',
        },
        {
            'a "b" [',
            7,
            'class_not_allowed',
        },
        -- the class body is not scanned, so its own errors do not show
        {
            'a [',
            3,
            'class_not_allowed',
        },
        {
            '[]',
            1,
            'class_not_allowed',
        },
        {
            'a | ([^\\q])',
            6,
            'class_not_allowed',
        },
    }, 'rules')
end

function testcase.rules_returns_ordered_choice()
    assert.equal(parse_ok('a / b', 'rules'), ordered_choice({
        ref(1, 'a'),
        ref(5, 'b'),
    }))
    assert.equal(parse_ok('a/"b" / _c', 'rules'), ordered_choice({
        ref(1, 'a'),
        lit(3, 'b'),
        ref(9, '_c'),
    }))
    assert.equal(parse_ok('a | b | c', 'rules'), choice({
        ref(1, 'a'),
        ref(5, 'b'),
        ref(9, 'c'),
    }))
end

function testcase.rules_returns_mixed_choice()
    check_errors({
        {
            '"a" | "b" / "c"',
            11,
            'mixed_choice',
        },
        {
            'a / b | c',
            7,
            'mixed_choice',
        },
        {
            'a | b | c / d',
            11,
            'mixed_choice',
        },
        {
            '(a / b | c)',
            8,
            'mixed_choice',
        },
    }, 'rules')
end

function testcase.rules_allows_mixing_through_groups()
    assert.equal(parse_ok('("a" | "b") / "c"', 'rules'), ordered_choice({
        choice({
            lit(2, 'a'),
            lit(8, 'b'),
        }),
        lit(15, 'c'),
    }))
    assert.equal(parse_ok('"a" | ("b" / "c")', 'rules'), choice({
        lit(1, 'a'),
        ordered_choice({
            lit(8, 'b'),
            lit(14, 'c'),
        }),
    }))
end

function testcase.rules_applies_precedence()
    assert.equal(parse_ok('a b* / c', 'rules'), ordered_choice({
        seq({
            ref(1, 'a'),
            postfix('star', ref(3, 'b')),
        }),
        ref(8, 'c'),
    }))
    assert.equal(parse_ok('a / b+ c?', 'rules'), ordered_choice({
        ref(1, 'a'),
        seq({
            postfix('plus', ref(5, 'b')),
            postfix('opt', ref(8, 'c')),
        }),
    }))
end

function testcase.rules_parses_realistic_rule()
    assert.equal(parse_ok('unop* _operand (binop unop* _operand)*', 'rules'),
                 seq({
        postfix('star', ref(1, 'unop')),
        ref(7, '_operand'),
        postfix('star', seq({
            ref(17, 'binop'),
            postfix('star', ref(23, 'unop')),
            ref(29, '_operand'),
        })),
    }))
end

function testcase.rules_returns_shared_errors()
    check_errors({
        {
            '',
            1,
            'missing_operand',
        },
        {
            '"a" /',
            6,
            'missing_operand',
        },
        {
            '/ "a"',
            1,
            'missing_operand',
        },
        {
            '"a" // "b"',
            6,
            'missing_operand',
        },
        {
            'a | / b',
            5,
            'missing_operand',
        },
        {
            '(a / b',
            1,
            'unbalanced_paren',
        },
        {
            'a / b)',
            6,
            'unbalanced_paren',
        },
        {
            'a*++',
            4,
            'repeated_postfix',
        },
        {
            'a / ""',
            5,
            'empty_literal',
        },
        {
            'a @',
            3,
            'unexpected_char',
        },
        {
            '"\\q"',
            2,
            'invalid_escape',
        },
    }, 'rules')
end

-- captures

local function capture(pos, name)
    return {
        type = 'capture',
        pos = pos,
        name = name,
    }
end

local CAPTURES = {
    level = true,
    body = 1,
}

-- parse src in the tokens context with captures and return the AST
local function parse_captures(src, captures)
    local ast, err = pattern.parse(src, 'tokens', captures or CAPTURES)
    assert.is_nil(err)
    return ast
end

-- parse src in the tokens context with captures and return the error
local function parse_captures_err(src, captures)
    local ast, err = pattern.parse(src, 'tokens', captures or CAPTURES)
    assert.is_nil(ast)
    return err
end

function testcase.parse_resolves_capture_names()
    assert.equal(parse_captures('level'), capture(1, 'level'))
    assert.equal(parse_captures('  body'), capture(3, 'body'))
    assert.equal(parse_captures('"--[" level "["'), seq({
        lit(1, '--['),
        capture(7, 'level'),
        lit(13, '['),
    }))
    assert.equal(parse_captures('level*'), postfix('star', capture(1, 'level')))
    assert.equal(parse_captures('"a" (level | "b")?'), seq({
        lit(1, 'a'),
        postfix('opt', choice({
            capture(6, 'level'),
            lit(14, 'b'),
        })),
    }))
end

function testcase.parse_keeps_fragments_and_builtins_with_captures()
    assert.equal(parse_captures('_frag DIGIT level'), seq({
        ref(1, '_frag'),
        cls(7, 'byte', {
            {
                48,
                57,
            },
        }),
        capture(13, 'level'),
    }))
    -- names of builtin or fragment shape never resolve to captures
    assert.equal(parse_captures('_level', {
        _level = true,
    }), ref(1, '_level'))
    assert.equal(parse_captures_err('LEVEL', {
        LEVEL = true,
    }), {
        pos = 1,
        code = 'unknown_builtin',
        message = 'unknown builtin class: LEVEL',
    })
end

function testcase.parse_rejects_names_that_are_not_captures()
    local message = 'only fragment names (starting with "_") and capture' ..
                        ' names may be referenced: '
    assert.equal(parse_captures_err('level other'), {
        pos = 7,
        code = 'invalid_reference',
        message = message .. 'other',
    })
    -- an empty captures table changes only the message
    assert.equal(parse_captures_err('level', {}), {
        pos = 1,
        code = 'invalid_reference',
        message = message .. 'level',
    })
    -- a false value is not a capture
    assert.equal(parse_captures_err('level', {
        level = false,
    }), {
        pos = 1,
        code = 'invalid_reference',
        message = message .. 'level',
    })
    -- without captures the message is unchanged
    local ast, err = pattern.parse('level', 'tokens')
    assert.is_nil(ast)
    assert.equal(err, {
        pos = 1,
        code = 'invalid_reference',
        message = 'only fragment names (starting with "_") may be referenced: level',
    })
end

function testcase.parse_reads_captures_without_metamethods()
    local captures = setmetatable({
        level = true,
    }, {
        __index = function()
            error('__index must not be called')
        end,
    })

    assert.equal(parse_captures('level', captures), capture(1, 'level'))
    assert.equal(parse_captures_err('other', captures).code, 'invalid_reference')
end

function testcase.parse_raises_for_invalid_captures()
    local err = assert.throws(pattern.parse, 'level', 'tokens', 'level')
    assert.match(err, 'captures must be table, got string')

    err = assert.throws(pattern.parse, 'level', 'tokens', false)
    assert.match(err, 'captures must be table, got boolean')

    err = assert.throws(pattern.parse, 'a', 'rules', {})
    assert.match(err, 'captures are only allowed in the tokens context')

    -- nil means no captures in both contexts
    assert.equal(parse_ok('a', 'rules'), ref(1, 'a'))
    local ast = pattern.parse('a', 'rules', nil)
    assert.equal(ast, ref(1, 'a'))
end

-- nesting limit

local function nested(depth, inner)
    return string.rep('(', depth) .. inner .. string.rep(')', depth)
end

function testcase.parse_accepts_100_nested_groups()
    assert.equal(parse_ok(nested(100, '"a"')), lit(101, 'a'))
    assert.equal(parse_ok(nested(100, 'a'), 'rules'), ref(101, 'a'))
    -- the depth returns to zero after a group is closed
    assert.equal(parse_ok(nested(100, '"a"') .. ' ' .. nested(100, '"b"')),
                 seq({
        lit(101, 'a'),
        lit(305, 'b'),
    }))
end

function testcase.parse_returns_nesting_too_deep()
    check_errors({
        {
            nested(101, '"a"'),
            101,
            'nesting_too_deep',
        },
        {
            '"x" ' .. nested(101, '"a"'),
            105,
            'nesting_too_deep',
        },
        -- the nesting error is found before a later syntax error
        {
            string.rep('(', 101) .. '"a" @ ""',
            101,
            'nesting_too_deep',
        },
    })
    check_errors({
        {
            nested(101, 'a'),
            101,
            'nesting_too_deep',
        },
    }, 'rules')

    local ast, err = pattern.parse(nested(101, '"a"'), 'tokens')
    assert.is_nil(ast)
    assert.equal(err.message, 'groups are nested deeper than 100 levels')
end

function testcase.parse_returns_error_for_very_deep_nesting()
    for _, context in ipairs({
        'tokens',
        'rules',
    }) do
        local ok, ast, err = pcall(pattern.parse, string.rep('(', 100000),
                                   context)

        assert.is_true(ok)
        assert.is_nil(ast)
        assert.equal(err, {
            pos = 101,
            code = 'nesting_too_deep',
            message = 'groups are nested deeper than 100 levels',
        })
    end
end
