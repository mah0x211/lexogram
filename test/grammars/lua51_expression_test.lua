local testcase = require('testcase')
local assert = require('assert')
-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local trees = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                         'expression.lua')

-- Expression trees built from the event array and the priorities of the
-- Lua 5.1 parser (lparser.c), { left, right }, where a right priority below
-- the left one makes the operator right associative (see expression.lua).
local PRIORITY = {
    ['+'] = {
        6,
        6,
    },
    ['-'] = {
        6,
        6,
    },
    ['*'] = {
        7,
        7,
    },
    ['/'] = {
        7,
        7,
    },
    ['%'] = {
        7,
        7,
    },
    ['^'] = {
        10,
        9,
    },
    ['..'] = {
        5,
        4,
    },
    ['=='] = {
        3,
        3,
    },
    ['~='] = {
        3,
        3,
    },
    ['<'] = {
        3,
        3,
    },
    ['<='] = {
        3,
        3,
    },
    ['>'] = {
        3,
        3,
    },
    ['>='] = {
        3,
        3,
    },
    ['and'] = {
        2,
        2,
    },
    ['or'] = {
        1,
        1,
    },
}
-- the priority of the operand of a unary operator
local UNARY = 8

local tree_of = trees.new('lexogram:lua51', PRIORITY, UNARY)
local without_hook = trees.without_hook

function testcase.trees_follow_priority_and_associativity()
    for _, case in ipairs({
        {
            'a + b * c',
            {
                '+',
                'a',
                {
                    '*',
                    'b',
                    'c',
                },
            },
        },
        {
            'a * b + c',
            {
                '+',
                {
                    '*',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            'a - b - c',
            {
                '-',
                {
                    '-',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            'a .. b .. c',
            {
                '..',
                'a',
                {
                    '..',
                    'b',
                    'c',
                },
            },
        },
        {
            'a ^ b ^ c',
            {
                '^',
                'a',
                {
                    '^',
                    'b',
                    'c',
                },
            },
        },
        {
            '-x ^ 2',
            {
                '-',
                {
                    '^',
                    'x',
                    '2',
                },
            },
        },
        {
            '2 ^ -3',
            {
                '^',
                '2',
                {
                    '-',
                    '3',
                },
            },
        },
        {
            'not a == b',
            {
                '==',
                {
                    'not',
                    'a',
                },
                'b',
            },
        },
        {
            'a or b and c',
            {
                'or',
                'a',
                {
                    'and',
                    'b',
                    'c',
                },
            },
        },
        {
            'a < b == c',
            {
                '==',
                {
                    '<',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            '(a + b) * c',
            {
                '*',
                {
                    '+',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            '#t + f(x) * t.k --[[ note ]] .. "s"',
            {
                '..',
                {
                    '+',
                    {
                        '#',
                        't',
                    },
                    {
                        '*',
                        'f(x)',
                        't.k',
                    },
                },
                '"s"',
            },
        },
    }) do
        assert.equal({
            case[1],
            tree_of(case[1]),
        }, {
            case[1],
            case[2],
        })
    end
end

-- pseudo-random numbers (Park-Miller), identical on every runtime
local SEED = 20261117
local function random(n)
    SEED = (SEED * 16807) % 2147483647
    return SEED % n + 1
end

local OPERATORS = {
    '+',
    '-',
    '*',
    '^',
}

-- a random arithmetic expression as source text
local function expression(depth)
    local parts = {}
    for _ = 1, random(2) - 1 do
        parts[#parts + 1] = '-'
    end
    if depth < 3 and random(4) == 1 then
        parts[#parts + 1] = '(' .. expression(depth + 1) .. ')'
    else
        parts[#parts + 1] = tostring(random(3))
    end
    if depth < 3 and random(2) == 1 then
        parts[#parts + 1] = ' ' .. OPERATORS[random(#OPERATORS)] .. ' '
        parts[#parts + 1] = expression(depth + 1)
    end
    return table.concat(parts)
end

local ARITH = {
    ['+'] = function(a, b)
        return a + b
    end,
    ['-'] = function(a, b)
        return a - b
    end,
    ['*'] = function(a, b)
        return a * b
    end,
    ['^'] = function(a, b)
        return a ^ b
    end,
}

-- the value of a tree of arithmetic expressions
local function evaluate(node)
    if type(node) == 'string' then
        return tonumber(node)
    elseif #node == 2 then
        return -evaluate(node[2])
    end
    return ARITH[node[1]](evaluate(node[2]), evaluate(node[3]))
end

function testcase.trees_evaluate_as_lua_evaluates_the_source()
    without_hook(function()
        for _ = 1, 300 do
            local source = expression(0)
            local expected = assert((loadstring or load)('return ' .. source))()
            local value = evaluate(tree_of(source))
            -- NaN is not equal to itself
            assert(value == expected or value ~= value and expected ~= expected,
                   source .. ': ' .. tostring(value) .. ' ~= ' ..
                       tostring(expected))
        end
    end)
end
