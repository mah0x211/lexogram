local testcase = require('testcase')
local assert = require('assert')
local nfa = require('lexogram.compile.nfa')
local dfa = require('lexogram.compile.dfa')
local lookahead = require('lexogram.compile.lookahead')
local pattern = require('lexogram.pattern')
local byte = string.byte

local LIMITS = {
    nfa = {
        max_states = nfa.MAX_STATES,
    },
    dfa = {
        max_states = dfa.MAX_STATES,
    },
}

-- parse a token pattern
local function P(src)
    return assert(pattern.parse(src, 'tokens'))
end

-- the predicate registry of the token automaton of the pattern
local function preds_of(src)
    local preds = nfa.new_predicates()
    assert(nfa.build({
        {
            id = 1,
            ast = P(src),
        },
    }, {}, nil, preds))
    return preds
end

-- build the token automaton of the patterns (ids 1, 2, ...) with its
-- predicates; returns the DFA, the predicates (lookahead.build) and the
-- machines of the predicates
local function build(...)
    local defs, rank = {}, {}
    for i, src in ipairs({
        ...,
    }) do
        defs[i] = {
            id = i,
            ast = P(src),
        }
        rank[i] = 1
    end
    local preds = nfa.new_predicates()
    local machine = assert(nfa.build(defs, {}, nil, preds))
    local d = assert(dfa.build(machine, rank))
    local list = assert(lookahead.build(preds, {}, LIMITS))
    local machines = {}
    for id = 1, #list do
        machines[id] = assert(nfa.build_predicate(id, preds, {}))
    end
    return d, list, machines
end

function testcase.build_measures_the_distance_of_each_predicate()
    local _, list = build('"x" (?!"a")', '"y" (?=("ab" | "ac"))',
                          '"z" (?="a"* "b")', '"w" (?="a" (?!"b"))',
                          '"v" (?="a" (?!"b"* "c"))', '"u" (?="a"?)')
    local distances = {}
    for id, entry in ipairs(list) do
        distances[id] = entry.distance
    end
    -- the predicates of the tokens come first, then the nested ones
    assert.equal(distances, {
        1,
        2,
        false,
        2,
        false,
        0,
        1,
        false,
    })
    -- a predicate without a bound has a backward automaton
    assert.is_table(list[3].backward)
    assert.is_nil(list[1].backward)
end

function testcase.build_prunes_states_that_cannot_accept()
    local _, list = build('"x" (?="ab")')
    local f = list[1].forward
    local after_a = f.trans[f.classes[byte('a') + 1]]
    assert.not_equal(after_a, 0)
    -- after "a", only "b" can still lead to acceptance
    assert.equal(f.trans[(after_a - 1) * f.nclasses + f.classes[byte('x') + 1]],
                 0)
    assert.not_equal(f.trans[(after_a - 1) * f.nclasses +
                         f.classes[byte('b') + 1]], 0)
end

-- run the backward automaton of the predicate p over str and return the
-- value at each position 1 .. #str + 1, evaluating nested predicates with
-- the NFA simulator
local function backward_values(list, machines, p, str)
    local d = list[p].backward
    local function valuate(preds, pos)
        local v = 0
        for j, q in ipairs(preds) do
            if nfa.holds(machines, q, str, pos) then
                v = v + 2 ^ (j - 1)
            end
        end
        return v
    end
    local function resolve(s, pos)
        local entry = d.dispatch and d.dispatch[s]
        if entry then
            return entry.targets[valuate(entry.preds, pos) + 1]
        end
        return s
    end
    local values = {}
    local s = resolve(1, #str + 1)
    values[#str + 1] = d.accept[s] ~= 0
    for i = #str, 1, -1 do
        s = d.trans[(s - 1) * d.nclasses + d.classes[byte(str, i) + 1]]
        s = resolve(s, i)
        values[i] = d.accept[s] ~= 0
    end
    return values
end

function testcase.backward_automata_give_the_value_at_every_position()
    local _, list, machines = build('"z" (?="a"* "b")',
                                    '"v" (?="a" (?!"b"* "c"))')
    for _, str in ipairs({
        'aab',
        'aaa',
        'baab',
        'abbc',
        'abbd',
        '',
        'zaab',
    }) do
        for _, p in ipairs({
            1,
            2,
            3,
        }) do
            if list[p].backward then
                local values = backward_values(list, machines, p, str)
                for i = 1, #str + 1 do
                    assert.equal({
                        str,
                        p,
                        i,
                        values[i],
                    }, {
                        str,
                        p,
                        i,
                        nfa.holds(machines, p, str, i),
                    })
                end
            end
        end
    end
end

-- whether some reachable state of d accepts every id of ids
local function both(d, found, ids)
    for s in pairs(found) do
        local set = {}
        for _, id in ipairs(d.accept_sets[s]) do
            set[id] = true
        end
        local all = true
        for _, id in ipairs(ids) do
            all = all and set[id] == true
        end
        if all then
            return true
        end
    end
    return false
end

function testcase.reachable_keeps_only_consistent_predicates()
    -- "a" cannot be followed by both "b" and "c"
    local d, list = build('"a" (?="b")', '"a" (?="c")')
    local found = assert(lookahead.reachable(d, list, 1000))
    assert.is_false(both(d, found, {
        1,
        2,
    }))
    assert.is_true(both(d, found, {
        1,
    }))
    -- but by "b" and by one of "b" or "c"
    d, list = build('"a" (?="b")', '"a" (?=[bc])')
    found = assert(lookahead.reachable(d, list, 1000))
    assert.is_true(both(d, found, {
        1,
        2,
    }))
    -- obligations go on after the bytes that create them: after "ab", one
    -- needs "c" next and the other no "d", which "abc" satisfies
    d, list = build('"a" (?="bc") [a-z]', '"a" (?!"bd") [a-z]')
    found = assert(lookahead.reachable(d, list, 1000))
    assert.is_true(both(d, found, {
        1,
        2,
    }))
    -- "c" and "d" next cannot both hold
    d, list = build('"a" (?="bc") [a-z]', '"a" (?="bd") [a-z]')
    found = assert(lookahead.reachable(d, list, 1000))
    assert.is_false(both(d, found, {
        1,
        2,
    }))
    -- the example is the shortest string that reaches the state
    for s, example in pairs(found) do
        if both(d, {
            [s] = true,
        }, {
            1,
        }) then
            assert.equal(example, 'ab')
        end
    end
end

function testcase.build_stops_at_the_limits()
    -- the machine of a predicate
    local list, err = lookahead.build(preds_of('"x" (?="ab")'), {}, {
        nfa = {
            max_states = 3,
        },
        dfa = LIMITS.dfa,
    })
    assert.is_nil(list)
    assert.equal(err.code, 'automaton_too_large')
    -- a backward automaton can be larger than the forward one: it keeps
    -- the bytes read up to the "a" at a distance of five
    local preds = preds_of('"x" (?="a" [ab][ab][ab][ab] "a" [^x]* "x")')
    list = assert(lookahead.build(preds, {}, LIMITS))
    assert.equal(list[1].forward.nstates, 8)
    assert.equal(list[1].backward.nstates, 49)
    list, err = lookahead.build(preds, {}, {
        nfa = LIMITS.nfa,
        dfa = {
            max_states = 20,
        },
    })
    assert.is_nil(list)
    assert.equal(err.code, 'automaton_too_large')
    assert.match(err.message, 'more than 20 states', true)
end

function testcase.reachable_stops_at_its_limit()
    local d, list = build('"a" (?="b"* "c") [a-z]*')
    local found, err = lookahead.reachable(d, list, 2)
    assert.is_nil(found)
    assert.equal(err.code, 'automaton_too_large')
    -- at the start state, and in the check that the obligations of a
    -- configuration can be met (four bytes)
    d, list = build('(?="bbbb") "b"')
    for _, max in ipairs({
        1,
        2,
    }) do
        found, err = lookahead.reachable(d, list, max)
        assert.is_nil(found)
        assert.equal(err.message,
                     'the analysis of the lookaheads would' ..
                         ' visit more than ' .. max .. ' configurations')
    end
    assert.is_table(lookahead.reachable(d, list, 5))
end
