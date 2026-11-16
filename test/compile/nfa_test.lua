local testcase = require('testcase')
local assert = require('assert')
local nfa = require('lexogram.compile.nfa')
local pattern = require('lexogram.pattern')
local char = string.char

-- parse a token pattern
local function P(src)
    return assert(pattern.parse(src, 'tokens'))
end

-- build a machine with one pattern definition (id 1)
local function build1(src, fragments)
    return assert(nfa.build({
        {
            id = 1,
            ast = P(src),
        },
    }, fragments or {}))
end

-- check that machine accepts every string of accepted with {1} and
-- rejects every string of rejected
local function check(machine, accepted, rejected)
    for _, s in ipairs(accepted) do
        assert.equal(nfa.accepts(machine, s), {
            1,
        })
    end
    for _, s in ipairs(rejected) do
        assert.equal(nfa.accepts(machine, s), {})
    end
end

-- structure

function testcase.build_returns_plain_machine()
    local machine = build1('"ab"')

    assert.equal(machine, {
        start = 1,
        count = 4,
        eps = {
            [1] = {
                2,
            },
        },
        edges = {
            [2] = {
                {
                    97,
                    97,
                    4,
                },
            },
            [4] = {
                {
                    98,
                    98,
                    3,
                },
            },
        },
        accept = {
            [3] = 1,
        },
    })
end

function testcase.build_is_deterministic()
    local function make()
        return assert(nfa.build({
            {
                id = 3,
                ast = P('("a" | [b-d]+ | _f)* [\\u{100}-\\u{10FFFF}]?'),
            },
            {
                id = 1,
                literal = 'Key',
                ignore_case = true,
            },
        }, {
            _f = P('"x" _g'),
            _g = P('DIGIT'),
        }))
    end

    assert.equal(make(), make())
end

-- node types

function testcase.build_compiles_literals()
    check(build1('"abc"'), {
        'abc',
    }, {
        '',
        'ab',
        'abcd',
        'abd',
        'ABC',
    })
end

function testcase.build_compiles_byte_classes()
    check(build1('[a-c\\x80-\\xff]'), {
        'a',
        'c',
        char(128),
        char(255),
    }, {
        '',
        'd',
        char(127),
        'ab',
    })
end

function testcase.build_compiles_code_point_classes()
    check(build1('[\\u{e9}-\\u{ff}\\u{3042}]'), {
        char(195, 169),
        char(195, 191),
        char(227, 129, 130),
    }, {
        'a',
        char(195, 168),
        char(196, 128),
        char(195),
        char(227, 129),
    })
end

function testcase.build_accepts_only_valid_utf8_in_negated_code_point_class()
    -- \u{61} makes the class a code point class
    check(build1('[^\\u{61}]'), {
        'b',
        char(0),
        char(127),
        char(194, 128),
        char(195, 169),
        char(237, 159, 191),
        char(238, 128, 128),
        char(240, 159, 152, 128),
        char(244, 143, 191, 191),
    }, {
        '',
        'a',
        'bb',
        -- overlong encodings
        char(193, 161),
        char(192, 128),
        char(224, 128, 128),
        char(240, 128, 128, 128),
        -- surrogates
        char(237, 160, 128),
        char(237, 191, 191),
        -- truncated sequences
        char(195),
        char(227, 129),
        char(240, 159, 152),
        -- invalid bytes and out of range
        char(128),
        char(255),
        char(244, 144, 128, 128),
    })
end

function testcase.build_compiles_sequences_and_choices()
    check(build1('"a" [0-9]'), {
        'a0',
        'a9',
    }, {
        'a',
        '0',
        'aa',
        'a00',
    })
    check(build1('"a" | "bc" | [x-z]'), {
        'a',
        'bc',
        'y',
    }, {
        '',
        'b',
        'abc',
        'w',
    })
end

function testcase.build_compiles_postfix_operators()
    check(build1('"a"?'), {
        '',
        'a',
    }, {
        'aa',
        'b',
    })
    check(build1('"a"*'), {
        '',
        'a',
        'aaa',
    }, {
        'b',
        'ab',
    })
    check(build1('"ab"+'), {
        'ab',
        'abab',
    }, {
        '',
        'a',
        'aba',
    })
end

function testcase.build_compiles_nested_postfix_through_groups()
    check(build1('("a" "b"?)*'), {
        '',
        'a',
        'ab',
        'aab',
        'aba',
        'abab',
    }, {
        'b',
        'abb',
        'ba',
    })
    check(build1('(("a"+)? "b")+'), {
        'b',
        'ab',
        'aab',
        'bab',
        'aabb',
    }, {
        '',
        'a',
        'ba',
    })
    check(build1('("x"*)*'), {
        '',
        'x',
        'xxx',
    }, {
        'y',
    })
end

function testcase.build_compiles_builtins()
    check(build1('DIGIT+'), {
        '0',
        '123',
    }, {
        '',
        'a',
        '1a',
    })
    check(build1('ANY'), {
        char(0),
        'a',
        char(255),
    }, {
        '',
        'ab',
    })
end

-- literal definitions

function testcase.build_compiles_literal_definitions()
    local machine = assert(nfa.build({
        {
            id = 1,
            literal = 'if',
        },
        {
            id = 2,
            literal = 'If-' .. char(200),
            ignore_case = true,
        },
        {
            id = 3,
            literal = '@[`{',
            ignore_case = true,
        },
    }, {}))

    assert.equal(nfa.accepts(machine, 'if'), {
        1,
    })
    assert.equal(nfa.accepts(machine, 'IF'), {})
    for _, s in ipairs({
        'IF-',
        'iF-',
        'if-',
        'If-',
    }) do
        assert.equal(nfa.accepts(machine, s .. char(200)), {
            2,
        })
    end
    -- non-letters and high bytes stay exact
    assert.equal(nfa.accepts(machine, 'IF_' .. char(200)), {})
    assert.equal(nfa.accepts(machine, 'IF-' .. char(232)), {})
    assert.equal(nfa.accepts(machine, '@[`{'), {
        3,
    })
    assert.equal(nfa.accepts(machine, '`{@['), {})
    assert.equal(nfa.accepts(machine, '@{`['), {})
end

function testcase.build_returns_every_matching_id()
    local machine = assert(nfa.build({
        {
            id = 4,
            ast = P('[a-z]+'),
        },
        {
            id = 2,
            literal = 'if',
        },
        {
            id = 7,
            literal = 'IF',
            ignore_case = true,
        },
    }, {}))

    assert.equal(nfa.accepts(machine, 'if'), {
        2,
        4,
        7,
    })
    assert.equal(nfa.accepts(machine, 'If'), {
        7,
    })
    assert.equal(nfa.accepts(machine, 'xy'), {
        4,
    })
    assert.equal(nfa.accepts(machine, ''), {})
end

-- fragments

function testcase.build_expands_fragments()
    local fragments = {
        _d = P('DIGIT'),
        _a = P('_b "x"'),
        _b = P('"y" | _d'),
        _u = P('[\\u{3042}-\\u{3043}]'),
    }

    check(build1('_d+', fragments), {
        '1',
        '42',
    }, {
        '',
        'a',
    })
    check(build1('_a', fragments), {
        'yx',
        '7x',
    }, {
        'x',
        'y',
        'yy',
    })
    check(build1('_d "." _d', fragments), {
        '1.2',
    }, {
        '1.',
        '12',
        '1.23',
    })
    check(build1('_u+ "!"', fragments), {
        char(227, 129, 130) .. '!',
        char(227, 129, 130, 227, 129, 131) .. '!',
    }, {
        '!',
        char(227, 129, 132) .. '!',
    })
end

function testcase.build_raises_for_invalid_input()
    local err = assert.throws(nfa.build, {
        {
            id = 1,
            ast = P('"a" _nope'),
        },
    }, {})
    assert.match(err, 'unknown fragment: _nope')

    err = assert.throws(nfa.build, {
        {
            id = 1,
            ast = assert(pattern.parse('"a" level', 'tokens', {
                level = true,
            })),
        },
    }, {})
    assert.match(err, 'unsupported node type: capture')

    -- a cycle that find_cycles would report
    err = assert.throws(nfa.build, {
        {
            id = 1,
            ast = P('_a'),
        },
    }, {
        _a = P('"x" _b'),
        _b = P('_a?'),
    })
    assert.match(err, 'fragment cycle through _a')
end

function testcase.build_stops_at_state_limit()
    assert.equal(nfa.MAX_STATES, 200000)

    -- start, entry, accept and one state between "a" and "b"
    local defs = {
        {
            id = 1,
            ast = P('"ab"'),
        },
    }
    assert.equal(assert(nfa.build(defs, {}, {
        max_states = 4,
    })).count, 4)
    local machine, err = nfa.build(defs, {}, {
        max_states = 3,
    })
    assert.is_nil(machine)
    assert.equal(err, {
        code = 'automaton_too_large',
        message = 'the automaton would have more than 3 states',
    })

    -- a chain of fragments that doubles at each level
    local fragments = {
        _f1 = P('"x"'),
    }
    for i = 2, 8 do
        fragments['_f' .. i] = P('_f' .. (i - 1) .. ' _f' .. (i - 1))
    end
    machine, err = nfa.build({
        {
            id = 1,
            ast = P('_f8'),
        },
    }, fragments, {
        max_states = 100,
    })
    assert.is_nil(machine)
    assert.equal(err.message, 'the automaton would have more than 100 states')
    -- an empty limits table means the default
    machine = assert(nfa.build({
        {
            id = 1,
            ast = P('_f8'),
        },
    }, fragments, {}))
    assert.equal(nfa.accepts(machine, string.rep('x', 128)), {
        1,
    })
end

function testcase.build_raises_for_invalid_limits()
    local defs = {
        {
            id = 1,
            ast = P('"a"'),
        },
    }
    local err = assert.throws(nfa.build, defs, {}, 'x')
    assert.match(err, 'limits must be table, got string')
    for _, v in ipairs({
        0,
        -1,
        1.5,
        '3',
    }) do
        err = assert.throws(nfa.build, defs, {}, {
            max_states = v,
        })
        assert.match(err,
                     'limits.max_states must be a positive integer, got ' ..
                         tostring(v))
    end
end

-- find_cycles

function testcase.find_cycles_returns_empty_list_without_cycles()
    assert.equal(nfa.find_cycles({}), {})
    assert.equal(nfa.find_cycles({
        _a = P('_b _c'),
        _b = P('_c+'),
        _c = P('"c"'),
    }), {})
end

function testcase.find_cycles_reports_cycles()
    -- self loop
    assert.equal(nfa.find_cycles({
        _a = P('"a" _a?'),
    }), {
        {
            '_a',
        },
    })
    -- two-cycle, starting at the smallest name
    assert.equal(nfa.find_cycles({
        _b = P('_a'),
        _a = P('_b'),
    }), {
        {
            '_a',
            '_b',
        },
    })
    -- three-cycle in reference order
    assert.equal(nfa.find_cycles({
        _x = P('_m'),
        _m = P('_c'),
        _c = P('_x'),
    }), {
        {
            '_c',
            '_x',
            '_m',
        },
    })
end

function testcase.find_cycles_reports_one_cycle_per_component()
    -- two disjoint cycles, a cycle reached from an acyclic fragment, and
    -- references to unknown names
    assert.equal(nfa.find_cycles({
        _start = P('_p _unknown'),
        _p = P('_q | _nope'),
        _q = P('_p'),
        _z = P('_y'),
        _y = P('_z _z'),
        _lone = P('"l"'),
    }), {
        {
            '_p',
            '_q',
        },
        {
            '_y',
            '_z',
        },
    })
    -- a component with several cycles reports the shortest one through its
    -- smallest name
    assert.equal(nfa.find_cycles({
        _a = P('_c | _b'),
        _b = P('_c'),
        _c = P('_a'),
    }), {
        {
            '_a',
            '_c',
        },
    })
end
