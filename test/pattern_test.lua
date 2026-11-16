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

local function postfix(t, item)
    return {
        type = t,
        pos = item.pos,
        item = item,
    }
end

-- parse src in the tokens context and return the AST
local function parse_ok(src)
    local ast, err = pattern.parse(src, 'tokens')
    assert.is_nil(err)
    return ast
end

-- parse src in the tokens context and return the error without its message
local function parse_err(src)
    local ast, err = pattern.parse(src, 'tokens')
    assert.is_nil(ast)
    assert.is_string(err.message)
    assert.not_equal(err.message, '')
    return {
        pos = err.pos,
        code = err.code,
    }
end

-- check that each case { src, pos, code } fails as expected
local function check_errors(cases)
    for _, case in ipairs(cases) do
        local err = parse_err(case[1])
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

    err = assert.throws(pattern.parse, '"a"', 'rules')
    assert.match(err, 'unsupported context: rules')
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
            '"a"{',
            4,
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
            '"a"?+',
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
