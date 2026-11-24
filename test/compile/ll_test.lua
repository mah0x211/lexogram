local testcase = require('testcase')
local assert = require('assert')
local ll = require('lexogram.compile.ll')
local pattern = require('lexogram.pattern')

local EPS = ll.EPS

-- parse a rule pattern
local function P(src)
    return assert(pattern.parse(src, 'rules'))
end

-- analyze rules (name -> source) with kind ids for literals and tokens
local function analyze(sources, start, ids)
    local rules = {}
    for name, src in pairs(sources) do
        rules[name] = P(src)
    end
    return ll.analyze(rules, start, function(node)
        if node.type == 'literal' then
            return ids[node.value]
        end
        return ids['@' .. node.name]
    end)
end

-- the results of an analysis without the functions and internal sets
local function results(a)
    return {
        nullable = a.nullable,
        first1 = a.first1,
        follow1 = a.follow1,
        first2 = a.first2,
        follow2 = a.follow2,
        left_recursion = a.left_recursion,
    }
end

-- the expression grammar: + = 1, * = 2, ( = 3, ) = 4, id = 5
local EXPR_IDS = {
    ['+'] = 1,
    ['*'] = 2,
    ['('] = 3,
    [')'] = 4,
    ['@id'] = 5,
}
local function expression()
    return analyze({
        e = 't ("+" t)*',
        t = 'f ("*" f)*',
        f = '"(" e ")" | id',
    }, 'e', EXPR_IDS)
end

function testcase.analyze_expression_grammar()
    local a = expression()

    assert.equal(results(a), {
        nullable = {
            e = false,
            t = false,
            f = false,
        },
        first1 = {
            e = {
                3,
                5,
            },
            t = {
                3,
                5,
            },
            f = {
                3,
                5,
            },
        },
        follow1 = {
            e = {
                0,
                4,
            },
            t = {
                0,
                1,
                4,
            },
            f = {
                0,
                1,
                2,
                4,
            },
        },
        first2 = {
            e = {
                {
                    3,
                    3,
                },
                {
                    3,
                    5,
                },
                {
                    5,
                },
                {
                    5,
                    1,
                },
                {
                    5,
                    2,
                },
            },
            t = {
                {
                    3,
                    3,
                },
                {
                    3,
                    5,
                },
                {
                    5,
                },
                {
                    5,
                    2,
                },
            },
            f = {
                {
                    3,
                    3,
                },
                {
                    3,
                    5,
                },
                {
                    5,
                },
            },
        },
        follow2 = {
            e = {
                {
                    0,
                },
                {
                    4,
                    0,
                },
                {
                    4,
                    1,
                },
                {
                    4,
                    2,
                },
                {
                    4,
                    4,
                },
            },
            t = {
                {
                    0,
                },
                {
                    1,
                    3,
                },
                {
                    1,
                    5,
                },
                {
                    4,
                    0,
                },
                {
                    4,
                    1,
                },
                {
                    4,
                    2,
                },
                {
                    4,
                    4,
                },
            },
            f = {
                {
                    0,
                },
                {
                    1,
                    3,
                },
                {
                    1,
                    5,
                },
                {
                    2,
                    3,
                },
                {
                    2,
                    5,
                },
                {
                    4,
                    0,
                },
                {
                    4,
                    1,
                },
                {
                    4,
                    2,
                },
                {
                    4,
                    4,
                },
            },
        },
        left_recursion = {},
    })
end

function testcase.analyze_nullable_chains()
    local a = analyze({
        a = 'b c',
        b = '"x"?',
        c = '"y"*',
    }, 'a', {
        x = 1,
        y = 2,
    })

    assert.equal(results(a), {
        nullable = {
            a = true,
            b = true,
            c = true,
        },
        first1 = {
            a = {
                1,
                2,
            },
            b = {
                1,
            },
            c = {
                2,
            },
        },
        follow1 = {
            a = {
                0,
            },
            b = {
                0,
                2,
            },
            c = {
                0,
            },
        },
        first2 = {
            a = {
                {
                    1,
                },
                {
                    1,
                    2,
                },
                {
                    2,
                },
                {
                    2,
                    2,
                },
            },
            b = {
                {
                    1,
                },
            },
            c = {
                {
                    2,
                },
                {
                    2,
                    2,
                },
            },
        },
        follow2 = {
            a = {
                {
                    0,
                },
            },
            b = {
                {
                    0,
                },
                {
                    2,
                    0,
                },
                {
                    2,
                    2,
                },
            },
            c = {
                {
                    0,
                },
            },
        },
        left_recursion = {},
    })
end

function testcase.analyze_postfix_operators_and_choices()
    local a = analyze({
        s = 'p q r',
        p = '"a"+',
        q = '"b" | "c"?',
        r = '"d" / "e"',
    }, 's', {
        a = 1,
        b = 2,
        c = 3,
        d = 4,
        e = 5,
    })

    assert.equal(a.nullable, {
        s = false,
        p = false,
        q = true,
        r = false,
    })
    assert.equal(a.first1, {
        s = {
            1,
        },
        p = {
            1,
        },
        q = {
            2,
            3,
        },
        r = {
            4,
            5,
        },
    })
    assert.equal(a.follow1, {
        s = {
            0,
        },
        p = {
            2,
            3,
            4,
            5,
        },
        q = {
            4,
            5,
        },
        r = {
            0,
        },
    })
    assert.equal(a.first2, {
        s = {
            {
                1,
                1,
            },
            {
                1,
                2,
            },
            {
                1,
                3,
            },
            {
                1,
                4,
            },
            {
                1,
                5,
            },
        },
        p = {
            {
                1,
            },
            {
                1,
                1,
            },
        },
        q = {
            {
                2,
            },
            {
                3,
            },
        },
        r = {
            {
                4,
            },
            {
                5,
            },
        },
    })
    assert.equal(a.follow2, {
        s = {
            {
                0,
            },
        },
        p = {
            {
                2,
                4,
            },
            {
                2,
                5,
            },
            {
                3,
                4,
            },
            {
                3,
                5,
            },
            {
                4,
                0,
            },
            {
                5,
                0,
            },
        },
        q = {
            {
                4,
                0,
            },
            {
                5,
                0,
            },
        },
        r = {
            {
                0,
            },
        },
    })
end

-- the Lua table constructor shape: name = 1, number = 2, "=" = 3, "(" = 4,
-- ")" = 5, "{" = 6, "}" = 7, "," = 8
function testcase.analyze_table_constructor_needs_two_tokens()
    local a = analyze({
        field = 'name "=" expr | expr',
        expr = 'name ("(" ")")* | number',
        table = '"{" (field ("," field)*)? "}"',
    }, 'table', {
        ['@name'] = 1,
        ['@number'] = 2,
        ['='] = 3,
        ['('] = 4,
        [')'] = 5,
        ['{'] = 6,
        ['}'] = 7,
        [','] = 8,
    })

    assert.equal(a.follow1.field, {
        7,
        8,
    })
    assert.equal(a.follow2.field, {
        {
            7,
            0,
        },
        {
            8,
            1,
        },
        {
            8,
            2,
        },
    })
    assert.equal(a.first2.expr, {
        {
            1,
        },
        {
            1,
            4,
        },
        {
            2,
        },
    })
    assert.equal(a.first2.table, {
        {
            6,
            1,
        },
        {
            6,
            2,
        },
        {
            6,
            7,
        },
    })

    -- the choice of field: both alternatives start with name, and the
    -- second token decides
    local sets = {}
    ll.walk(a, 'field', 2, function(node, cont)
        if node.type == 'choice' then
            for i, alt in ipairs(node.items) do
                sets[i] = ll.to_array(ll.first(a, {
                    alt,
                }, 2, cont), 2)
            end
        end
    end)
    assert.equal(sets, {
        {
            {
                1,
                3,
            },
        },
        {
            {
                1,
                4,
            },
            {
                1,
                7,
            },
            {
                1,
                8,
            },
            {
                2,
                7,
            },
            {
                2,
                8,
            },
        },
    })
    -- one token is not enough
    ll.walk(a, 'field', 1, function(node, cont)
        if node.type == 'choice' then
            for i, alt in ipairs(node.items) do
                sets[i] = ll.to_array(ll.first(a, {
                    alt,
                }, 1, cont), 1)
            end
        end
    end)
    assert.equal(sets, {
        {
            1,
        },
        {
            1,
            2,
        },
    })
end

function testcase.walk_passes_continuations()
    local a = expression()
    local seen = {}
    ll.walk(a, 'e', 1, function(node, cont)
        seen[#seen + 1] = {
            node.type,
            ll.to_array(cont, 1),
        }
    end)

    -- e = t ("+" t)*: the star repeats or exits to FOLLOW1(e)
    assert.equal(seen, {
        {
            'seq',
            {
                0,
                4,
            },
        },
        {
            'ref',
            {
                0,
                1,
                4,
            },
        },
        {
            'star',
            {
                0,
                4,
            },
        },
        {
            'seq',
            {
                0,
                1,
                4,
            },
        },
        {
            'literal',
            {
                3,
                5,
            },
        },
        {
            'ref',
            {
                0,
                1,
                4,
            },
        },
    })
end

function testcase.first_of_sequences_with_continuation()
    local a = expression()
    local none = {
        [EPS] = true,
    }
    -- the end of input as a k = 2 continuation is the key 0 ({ 0 })
    local eoi = {
        [0] = true,
    }

    assert.equal(ll.to_array(ll.first(a, {
        P('"*" f'),
    }, 2, none), 2), {
        {
            2,
            3,
        },
        {
            2,
            5,
        },
    })
    -- a nullable element: the continuation shows through
    local s = ll.first(a, {
        P('f?'),
    }, 2, eoi)
    assert.equal(ll.to_array(s, 2), {
        {
            0,
        },
        {
            3,
            3,
        },
        {
            3,
            5,
        },
        {
            5,
            0,
        },
    })
    assert.is_nil(s[EPS])
    -- without a continuation the empty string remains
    s = ll.first(a, {
        P('f?'),
    }, 1, none)
    assert.is_true(s[EPS])
    assert.equal(ll.to_array(s, 1), {
        3,
        5,
    })
    -- several nodes, truncated at two tokens
    assert.equal(ll.to_array(ll.first(a, {
        P('"("'),
        P('"(" "("'),
        P('t'),
    }, 2, eoi), 2), {
        {
            3,
            3,
        },
    })
    assert.equal(ll.to_array(ll.first(a, {
        P('"+"?'),
        P('"*"?'),
        P('t'),
    }, 1, eoi), 1), {
        1,
        2,
        3,
        5,
    })
end

function testcase.concat_truncates_and_ends_at_end_of_input()
    local B = ll.BASE
    -- "5" . { "1 3", end } = { "5 1", "5 0" }
    assert.equal(ll.to_array(ll.concat({
        [5 * B] = true,
    }, {
        [1 * B + 4] = true,
        [0] = true,
    }, 2), 2), {
        {
            5,
            0,
        },
        {
            5,
            1,
        },
    })
    -- the end of input is complete
    assert.equal(ll.to_array(ll.concat({
        [0] = true,
    }, {
        [1 * B] = true,
    }, 2), 2), {
        {
            0,
        },
    })
end

function testcase.analyze_reports_left_recursion()
    local ids = {
        x = 1,
        y = 2,
        z = 3,
        w = 4,
        v = 5,
    }
    assert.equal(analyze({
        a = 'a "x" | "y"',
    }, 'a', ids).left_recursion, {
        {
            'a',
        },
    })
    assert.equal(analyze({
        a = '"x"? a | "y"',
    }, 'a', ids).left_recursion, {
        {
            'a',
        },
    })
    assert.equal(analyze({
        a = 'b',
        b = 'a "y" | "z"',
    }, 'a', ids).left_recursion, {
        {
            'a',
            'b',
        },
    })
    assert.equal(analyze({
        a = '"x" a | "y"',
    }, 'a', ids).left_recursion, {})
    -- a nullable rule before the call
    assert.equal(analyze({
        a = 'n a "x" | "y"',
        n = '"z"*',
    }, 'a', ids).left_recursion, {
        {
            'a',
        },
    })
    -- two components
    assert.equal(analyze({
        s = 'a c',
        a = 'b | "z"',
        b = 'a "y"',
        c = 'c "w" | "v"',
    }, 's', ids).left_recursion, {
        {
            'a',
            'b',
        },
        {
            'c',
        },
    })
end

function testcase.analyze_is_deterministic()
    local function run()
        return results(analyze({
            field = 'name "=" expr | expr',
            expr = 'name ("(" ")")* | number',
            table = '"{" (field ("," field)*)? "}"',
        }, 'table', {
            ['@name'] = 1,
            ['@number'] = 2,
            ['='] = 3,
            ['('] = 4,
            [')'] = 5,
            ['{'] = 6,
            ['}'] = 7,
            [','] = 8,
        }))
    end

    assert.equal(run(), run())
end

function testcase.analyze_counts_the_tokens_that_a_prefix_match_splits()
    local rules = {
        s = P('#">" "x" | "y"'),
    }
    local ids = {
        ['>'] = 1,
        ['>>'] = 2,
        ['x'] = 3,
        ['y'] = 4,
    }
    local function terminal(node)
        return ids[node.value]
    end
    -- ">" as it is, then "x"; a split ">>", then any token
    local a = ll.analyze(rules, 's', terminal, nil, function(node)
        assert.equal(node.type, 'prefix')
        return {
            2,
        }
    end)
    assert.equal(a.first1.s, {
        1,
        2,
        4,
    })
    assert.equal(a.first2.s, {
        {
            1,
            3,
        },
        {
            2,
            ll.ANY,
        },
        {
            4,
        },
    })
    -- without the prefix function, a prefix match splits no token
    a = ll.analyze(rules, 's', terminal)
    assert.equal(a.first1.s, {
        1,
        4,
    })
end
