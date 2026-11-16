local testcase = require('testcase')
local assert = require('assert')
local nfa = require('lexogram.compile.nfa')
local dfa = require('lexogram.compile.dfa')
local pattern = require('lexogram.pattern')
local char = string.char

-- parse a token pattern
local function P(src)
    return assert(pattern.parse(src, 'tokens'))
end

-- build the NFA and the DFA of defs; literal definitions get rank 1 and
-- pattern definitions rank 2
local function build(defs, fragments)
    local machine = assert(nfa.build(defs, fragments or {}))
    local rank = {}
    for _, def in ipairs(defs) do
        rank[def.id] = def.literal and 1 or 2
    end
    return assert(dfa.build(machine, rank)), machine
end

-- the DFA of a single pattern token (id 1)
local function build1(src)
    return build({
        {
            id = 1,
            ast = P(src),
        },
    })
end

-- accept set of the DFA after str
local function dfa_accepts(d, str)
    local s = dfa.run(d, str)
    if s == 0 then
        return {}
    end
    return d.accept_sets[s]
end

-- run fn(...) with the debug hook removed (see utf8range_test.lua)
local function without_hook(fn, ...)
    local hook, mask, count = debug.gethook()
    debug.sethook()
    local res = {
        pcall(fn, ...),
    }
    if hook then
        debug.sethook(hook, mask, count)
    end
    if not res[1] then
        error(res[2], 0)
    end
    return res[2], res[3]
end

-- a lexer-like set of definitions
local HIRAGANA_A = char(227, 129, 130)
local function lexer_defs()
    return {
        {
            id = 1,
            ast = P('(ALPHA | "_") (ALPHA | DIGIT | "_")*'),
        },
        {
            id = 2,
            ast = P('_digits ("." _digits)?'),
        },
        {
            id = 3,
            ast = P('"\\"" ([^"\\\\] | "\\\\" ANY)* "\\""'),
        },
        {
            id = 4,
            ast = P('[\\u{3042}-\\u{3093}]+'),
        },
        {
            id = 10,
            literal = 'if',
        },
        {
            id = 11,
            literal = 'AND',
            ignore_case = true,
        },
        {
            id = 12,
            literal = '.',
        },
        {
            id = 13,
            literal = '..',
        },
        {
            id = 14,
            literal = '...',
        },
        {
            id = 15,
            literal = 'and',
        },
    }, {
        _digits = P('DIGIT+'),
    }
end

-- structure

function testcase.build_returns_flat_plain_tables()
    local d = build1('"ab"')

    assert.equal(d, {
        nstates = 3,
        nclasses = 3,
        classes = (function()
            local classes = {}
            for b = 0, 255 do
                classes[b + 1] = (b == 97 and 2) or (b == 98 and 3) or 1
            end
            return classes
        end)(),
        trans = {
            0,
            2,
            0,
            0,
            0,
            3,
            0,
            0,
            0,
        },
        accept = {
            0,
            0,
            1,
        },
        accept_sets = {
            {},
            {},
            {
                1,
            },
        },
        conflicts = {},
    })
end

function testcase.build_is_deterministic()
    local function make()
        local defs, fragments = lexer_defs()
        return build(defs, fragments)
    end

    assert.equal(make(), make())
end

-- differential test against the NFA

-- Park-Miller LCG (products stay below 2^53)
local function new_prng(seed)
    local state = seed
    return function(n)
        state = (16807 * state) % 2147483647
        return state % n + 1
    end
end

function testcase.build_matches_nfa_on_pseudo_random_strings()
    local defs, fragments = lexer_defs()
    local d, machine = build(defs, fragments)
    local alphabet = {
        'a',
        'i',
        'f',
        'n',
        'd',
        'A',
        'N',
        'D',
        '_',
        '1',
        '9',
        '.',
        '"',
        '\\',
        ' ',
        HIRAGANA_A,
        char(227, 130, 147),
        char(227),
        char(129),
        char(130),
        char(128),
        char(255),
    }
    -- the comparison runs without the luacov hook (see without_hook)
    without_hook(function()
        local rand = new_prng(4242)
        for _ = 1, 3000 do
            local parts = {}
            for i = 1, rand(7) - 1 do
                parts[i] = alphabet[rand(#alphabet)]
            end
            local s = table.concat(parts)
            assert.equal(dfa_accepts(d, s), nfa.accepts(machine, s))
        end
    end)
end

function testcase.build_matches_nfa_on_all_short_strings()
    local defs, fragments = lexer_defs()
    local d, machine = build(defs, fragments)
    local alphabet = {
        'a',
        'N',
        '1',
        '.',
        '"',
        '\\',
        char(227),
        char(129),
    }
    local strings = {
        '',
    }
    local head = 1
    while strings[head] do
        local s = strings[head]
        assert.equal(dfa_accepts(d, s), nfa.accepts(machine, s))
        if #s < 3 then
            for _, c in ipairs(alphabet) do
                strings[#strings + 1] = s .. c
            end
        end
        head = head + 1
    end
    assert.equal(#strings, 1 + 8 + 64 + 512)
end

function testcase.build_matches_nfa_for_code_point_and_byte_classes()
    local d, machine = build({
        {
            id = 1,
            ast = P('[^\\u{61}]+'),
        },
        {
            id = 2,
            ast = P('[\\x80-\\xff]+'),
        },
        {
            id = 3,
            ast = P('ANY'),
        },
    })
    local alphabet = {
        'a',
        'b',
        char(0),
        char(128),
        char(191),
        char(194),
        char(224),
        char(237),
        char(160),
        char(240),
        char(144),
        char(244),
        char(255),
    }
    -- the comparison runs without the luacov hook (see without_hook)
    without_hook(function()
        local rand = new_prng(77)
        for _ = 1, 2000 do
            local parts = {}
            for i = 1, rand(6) - 1 do
                parts[i] = alphabet[rand(#alphabet)]
            end
            local s = table.concat(parts)
            assert.equal(dfa_accepts(d, s), nfa.accepts(machine, s))
        end
    end)
end

-- minimality

function testcase.build_returns_minimal_state_counts()
    -- the dead state is not counted
    assert.equal(build1('"a"* "b"').nstates, 2)
    assert.equal(build1('"ab"').nstates, 3)
    assert.equal(build1('"a" | "aa"').nstates, 3)
    assert.equal(build1('"ab" | "cb"').nstates, 3)
    -- equivalent patterns give the same minimal automaton
    local d1 = build1('("a" | "b")*')
    local d2 = build1('("a"* "b"*)*')
    assert.equal(d1.nstates, 1)
    assert.equal(d1, d2)
end

function testcase.build_keeps_states_with_different_accept_sets()
    -- the states after "a" and "c" both reach an accepting state with "b",
    -- but different ids are accepted there
    local d = build({
        {
            id = 1,
            ast = P('"ab"'),
        },
        {
            id = 2,
            ast = P('"cb"'),
        },
    })

    assert.equal(d.nstates, 5)
    assert.equal(dfa_accepts(d, 'ab'), {
        1,
    })
    assert.equal(dfa_accepts(d, 'cb'), {
        2,
    })
end

-- classes

function testcase.build_merges_byte_classes()
    local d = build({
        {
            id = 1,
            ast = P('[a-z]'),
        },
        {
            id = 2,
            ast = P('"0"'),
        },
    })

    assert.equal(d.nclasses, 3)
    assert.equal(#d.classes, 256)
    assert.equal(d.classes[1], 1)
    assert.equal(d.classes[48 + 1], 2)
    assert.equal(d.classes[49 + 1], 1)
    assert.equal(d.classes[97 + 1], 3)
    assert.equal(d.classes[122 + 1], 3)
    assert.equal(d.classes[123 + 1], 1)
    assert.equal(d.classes[256], 1)
    assert.equal(#d.trans, d.nstates * d.nclasses)

    -- "a" and "b" have identical columns
    d = build1('"a" | "b"')
    assert.equal(d.nclasses, 2)
    assert.equal(d.classes[97 + 1], d.classes[98 + 1])
end

-- accept resolution

function testcase.build_prefers_literals_and_longest_matches()
    local defs, fragments = lexer_defs()
    local d = build(defs, fragments)

    -- literal beats pattern token on equal length
    assert.equal(dfa_accepts(d, 'if'), {
        1,
        10,
    })
    assert.equal(d.accept[dfa.run(d, 'if')], 10)
    assert.equal({
        dfa.longest(d, 'if', 1),
    }, {
        10,
        3,
    })
    -- longest match beats rank
    assert.equal({
        dfa.longest(d, 'iffy', 1),
    }, {
        1,
        5,
    })
end

function testcase.build_reports_conflicts()
    -- two pattern tokens matching the same strings
    local d = build({
        {
            id = 1,
            ast = P('[a-z]+'),
        },
        {
            id = 2,
            ast = P('"x" [a-z]*'),
        },
    })
    assert.equal(d.conflicts, {
        {
            state = dfa.run(d, 'x'),
            ids = {
                1,
                2,
            },
        },
    })
    assert.equal(dfa.run(d, 'x'), dfa.run(d, 'xyz'))
    assert.equal(d.accept[dfa.run(d, 'x')], 1)

    -- two literals through ignore_case
    local defs, fragments = lexer_defs()
    d = build(defs, fragments)
    local s = dfa.run(d, 'and')
    assert.equal(d.accept_sets[s], {
        1,
        11,
        15,
    })
    assert.equal(d.conflicts, {
        {
            state = s,
            ids = {
                11,
                15,
            },
        },
    })
    assert.equal(d.accept[s], 11)
end

function testcase.build_ignores_ties_below_the_winning_rank()
    local d = build({
        {
            id = 1,
            ast = P('[a-z]+'),
        },
        {
            id = 2,
            ast = P('"if" [a-z]*'),
        },
        {
            id = 10,
            literal = 'if',
        },
    })

    local s_if, s_ifx = dfa.run(d, 'if'), dfa.run(d, 'ifx')
    assert.equal(d.accept_sets[s_if], {
        1,
        2,
        10,
    })
    assert.equal(d.accept[s_if], 10)
    -- only the state after "ifx" (and longer) is a conflict
    assert.equal(d.conflicts, {
        {
            state = s_ifx,
            ids = {
                1,
                2,
            },
        },
    })
end

-- run and longest

function testcase.run_returns_states()
    local d = build1('"ab"')

    assert.equal(dfa.run(d, ''), 1)
    assert.equal(dfa.run(d, 'a'), 2)
    assert.equal(dfa.run(d, 'ab'), 3)
    assert.equal(dfa.run(d, 'abc'), 0)
    assert.equal(dfa.run(d, 'b'), 0)
end

function testcase.longest_returns_longest_match()
    local defs, fragments = lexer_defs()
    local d = build(defs, fragments)
    local src = 'abc 123 1.5x "a\\"b" ' .. HIRAGANA_A .. HIRAGANA_A ..
                    'z ... ..x AnD'

    for _, case in ipairs({
        {
            1,
            1,
            4,
        },
        {
            2,
            1,
            4,
        },
        {
            5,
            2,
            8,
        },
        {
            9,
            2,
            12,
        },
        {
            12,
            1,
            13,
        },
        {
            14,
            3,
            20,
        },
        {
            21,
            4,
            27,
        },
        {
            29,
            14,
            32,
        },
        {
            30,
            13,
            32,
        },
        {
            33,
            13,
            35,
        },
        {
            37,
            11,
            40,
        },
    }) do
        assert.equal({
            dfa.longest(d, src, case[1]),
        }, {
            case[2],
            case[3],
        })
    end
    -- no match
    assert.equal({
        dfa.longest(d, src, 4),
    }, {})
    assert.equal({
        dfa.longest(d, src, #src + 1),
    }, {})
    assert.equal({
        dfa.longest(d, char(227, 129), 1),
    }, {})
end

function testcase.longest_ignores_empty_matches()
    local d = build1('"a"*')

    assert.equal(d.accept[1], 1)
    assert.equal({
        dfa.longest(d, 'b', 1),
    }, {})
    assert.equal({
        dfa.longest(d, 'aab', 1),
    }, {
        1,
        3,
    })
end

-- size limit

function testcase.build_stops_at_state_limit()
    local machine = assert(nfa.build({
        {
            id = 1,
            ast = P('("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 16)),
        },
    }, {}))

    local d, err = without_hook(dfa.build, machine, {
        [1] = 2,
    })

    assert.is_nil(d)
    assert.equal(err, {
        code = 'automaton_too_large',
        message = 'the deterministic automaton would have more than 50000 states',
    })
end
