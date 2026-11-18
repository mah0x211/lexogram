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

-- lookaheads

-- build the NFA and the DFA of defs with their predicates; returns the DFA,
-- the machine and the machines of the predicates
local function build_lookahead(defs, fragments)
    local preds = nfa.new_predicates()
    local machine = assert(nfa.build(defs, fragments or {}, nil, preds))
    local machines = {}
    local id = 1
    while preds.list[id] do
        machines[id] = assert(nfa.build_predicate(id, preds, fragments or {}))
        id = id + 1
    end
    local rank = {}
    for _, def in ipairs(defs) do
        rank[def.id] = def.literal and 1 or 2
    end
    return assert(dfa.build(machine, rank)), machine, machines
end

-- the valuation function of the predicates over the whole input str, as
-- the NFA simulator evaluates them
local function valuation_of(machines, str)
    return function(preds, pos)
        local v = 0
        for j, p in ipairs(preds) do
            if nfa.holds(machines, p, str, pos) then
                v = v + 2 ^ (j - 1)
            end
        end
        return v
    end
end

function testcase.build_resolves_lookaheads_with_dispatch_states()
    local d = build_lookahead({
        {
            id = 1,
            ast = P('"x" (?!"a") [a-z]'),
        },
    })
    -- the state after "x" dispatches on the predicate "a"
    local after_x = d.trans[d.classes[string.byte('x') + 1]]
    assert.equal(d.dispatch[after_x].preds, {
        1,
    })
    assert.equal(#d.dispatch[after_x].targets, 2)
    assert.equal(d.accept[after_x], 0)
    -- without lookaheads there is no dispatch
    assert.is_nil(build1('"x" [a-z]').dispatch)
end

function testcase.build_matches_nfa_with_lookaheads_on_all_short_strings()
    local defs = {
        {
            id = 1,
            ast = P('"x" (?!("ab" | "ac")) [a-c]*'),
        },
        {
            id = 2,
            ast = P('"a" (?="a"* "b") [ab]'),
        },
        {
            id = 3,
            ast = P('[a-c]+ (?![a-c])'),
        },
        {
            id = 4,
            ast = P('"x" (?="a" (?!"b")) "a" [a-c]?'),
        },
        {
            id = 5,
            literal = 'ab',
        },
    }
    local d, machine, machines = build_lookahead(defs)
    local alphabet = {
        'a',
        'b',
        'c',
        'x',
    }
    without_hook(function()
        local strings = {
            '',
        }
        local head = 1
        while strings[head] do
            local str = strings[head]
            head = head + 1
            local s = dfa.run(d, str, valuation_of(machines, str))
            assert.equal({
                str,
                s == 0 and {} or d.accept_sets[s],
            }, {
                str,
                nfa.accepts(machine, str, machines),
            })
            if #str < 6 then
                for _, c in ipairs(alphabet) do
                    strings[#strings + 1] = str .. c
                end
            end
        end
    end)
end

function testcase.build_stops_at_state_limit_with_lookaheads()
    local preds = nfa.new_predicates()
    local machine = assert(nfa.build({
        {
            id = 1,
            ast = P('"x" (?!"a") [a-z]'),
        },
    }, {}, nil, preds))
    -- the dispatch state after "x" does not fit, then one of its targets
    for _, max in ipairs({
        1,
        2,
    }) do
        local d, err = dfa.build(machine, {
            1,
        }, {
            max_states = max,
        })
        assert.is_nil(d)
        assert.equal(err.code, 'automaton_too_large')
    end
end

function testcase.longest_evaluates_lookaheads_after_the_token()
    -- the longest length at which the lookahead holds: in 12a, the 1 is
    -- followed by 2, which is no letter
    local d, _, machines = build_lookahead({
        {
            id = 1,
            ast = P('[0-9]+ (?![a-z])'),
        },
    })
    local strict, _, strict_machines = build_lookahead({
        {
            id = 1,
            ast = P('[0-9]+ (?![0-9a-z])'),
        },
    })
    for _, case in ipairs({
        {
            d,
            machines,
            '12 a',
            1,
            3,
        },
        {
            d,
            machines,
            '12a',
            1,
            2,
        },
        {
            d,
            machines,
            '1',
            1,
            2,
        },
        {
            strict,
            strict_machines,
            '12a',
        },
        {
            strict,
            strict_machines,
            '12 a',
            1,
            3,
        },
    }) do
        local str = case[3]
        local id, stop =
            dfa.longest(case[1], str, 1, valuation_of(case[2], str))
        assert.equal({
            str,
            id,
            stop,
        }, {
            str,
            case[4],
            case[5],
        })
    end
end

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
    assert.equal(dfa.MAX_STATES, 50000)

    local machine = assert(nfa.build({
        {
            id = 1,
            ast = P('"ab"'),
        },
    }, {}))
    -- the subset construction finds the start and the states after "a"
    -- and after "b"
    assert.equal(assert(dfa.build(machine, {
        [1] = 2,
    }, {
        max_states = 3,
    })).nstates, 3)
    local d, err = dfa.build(machine, {
        [1] = 2,
    }, {
        max_states = 2,
    })
    assert.is_nil(d)
    assert.equal(err, {
        code = 'automaton_too_large',
        message = 'the deterministic automaton would have more than 2 states',
    })

    -- a pattern that needs exponentially many states
    machine = assert(nfa.build({
        {
            id = 1,
            ast = P('("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 6)),
        },
    }, {}))
    d, err = dfa.build(machine, {
        [1] = 2,
    }, {
        max_states = 100,
    })
    assert.is_nil(d)
    assert.equal(err.message,
                 'the deterministic automaton would have more than 100 states')
    assert.equal(assert(dfa.build(machine, {
        [1] = 2,
    }, {})).nstates, 128)
end

function testcase.build_raises_for_invalid_limits()
    local machine = assert(nfa.build({
        {
            id = 1,
            ast = P('"a"'),
        },
    }, {}))
    local err = assert.throws(dfa.build, machine, {
        [1] = 2,
    }, true)
    assert.match(err, 'limits must be table, got boolean')
    err = assert.throws(dfa.build, machine, {
        [1] = 2,
    }, {
        max_states = 0,
    })
    assert.match(err, 'limits.max_states must be a positive integer, got 0')
end

-- true if the automaton d accepts the whole string str
local function accepts(d, str)
    local s = dfa.run(d, str)
    return s ~= 0 and d.accept[s] ~= 0
end

function testcase.intersect_accepts_what_every_automaton_accepts()
    local list = {
        (build1('[a-c]+')),
        (build1('([a-c][a-c])+')),
        (build1('[^b]*')),
    }
    local d = assert(dfa.intersect(list))
    assert.is_nil(d.dispatch)
    -- every string over a, b, c, d of length 0 to 4
    local alphabet = {
        'a',
        'b',
        'c',
        'd',
    }
    local strings = {
        '',
    }
    for _ = 1, 4 do
        for i = #strings, 1, -1 do
            local s = strings[i]
            if #s == #strings[#strings] then
                for _, c in ipairs(alphabet) do
                    strings[#strings + 1] = s .. c
                end
            end
        end
    end
    for _, s in ipairs(strings) do
        local all = true
        for _, a in ipairs(list) do
            all = all and accepts(a, s)
        end
        assert.equal(accepts(d, s), all, s)
    end

    -- the limit of the states
    local _, err = dfa.intersect({
        (build1('([ab]{4})+')),
        (build1('([ab]{5})+')),
    }, {
        max_states = 9,
    })
    assert.equal(err, {
        code = 'automaton_too_large',
        message = 'the deterministic automaton would have more than 9 states',
    })
end
