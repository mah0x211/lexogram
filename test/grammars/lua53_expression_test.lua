local testcase = require('testcase')
local assert = require('assert')
-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local trees = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                         'expression.lua')

-- Expression trees built from the event array and the priorities of the
-- Lua 5.3 parser (lparser.c), { left, right }, where a right priority below
-- the left one makes the operator right associative (see expression.lua).
local PRIORITY = {
    ['or'] = {
        1,
        1,
    },
    ['and'] = {
        2,
        2,
    },
    ['<'] = {
        3,
        3,
    },
    ['>'] = {
        3,
        3,
    },
    ['<='] = {
        3,
        3,
    },
    ['>='] = {
        3,
        3,
    },
    ['~='] = {
        3,
        3,
    },
    ['=='] = {
        3,
        3,
    },
    ['|'] = {
        4,
        4,
    },
    ['~'] = {
        5,
        5,
    },
    ['&'] = {
        6,
        6,
    },
    ['<<'] = {
        7,
        7,
    },
    ['>>'] = {
        7,
        7,
    },
    ['..'] = {
        9,
        8,
    },
    ['+'] = {
        10,
        10,
    },
    ['-'] = {
        10,
        10,
    },
    ['*'] = {
        11,
        11,
    },
    ['/'] = {
        11,
        11,
    },
    ['//'] = {
        11,
        11,
    },
    ['%'] = {
        11,
        11,
    },
    ['^'] = {
        14,
        13,
    },
}
-- the priority of the operand of a unary operator
local UNARY = 12

local tree_of = trees.new('lexogram:lua53', PRIORITY, UNARY)
local without_hook = trees.without_hook

function testcase.trees_follow_priority_and_associativity()
    for _, case in ipairs({
        {
            -- each operator above the one before it
            'a | b ~ c & d << e .. f + g * h',
            {
                '|',
                'a',
                {
                    '~',
                    'b',
                    {
                        '&',
                        'c',
                        {
                            '<<',
                            'd',
                            {
                                '..',
                                'e',
                                {
                                    '+',
                                    'f',
                                    {
                                        '*',
                                        'g',
                                        'h',
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        {
            'a // b * c',
            {
                '*',
                {
                    '//',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            'a << b >> c',
            {
                '>>',
                {
                    '<<',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            'a .. b << c',
            {
                '<<',
                {
                    '..',
                    'a',
                    'b',
                },
                'c',
            },
        },
        {
            'a == b | c',
            {
                '==',
                'a',
                {
                    '|',
                    'b',
                    'c',
                },
            },
        },
        {
            -- "~" as a binary and a unary operator, and "~=" as one token
            'a ~= b ~ ~c',
            {
                '~=',
                'a',
                {
                    '~',
                    'b',
                    {
                        '~',
                        'c',
                    },
                },
            },
        },
        {
            '~a & b',
            {
                '&',
                {
                    '~',
                    'a',
                },
                'b',
            },
        },
        {
            '~x ^ 2',
            {
                '~',
                {
                    '^',
                    'x',
                    '2',
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
local SEED = 20261118
local function random(n)
    SEED = (SEED * 16807) % 2147483647
    return SEED % n + 1
end

local OPERATORS = {
    '+',
    '-',
    '*',
    '//',
    '%',
    '&',
    '|',
    '~',
    '<<',
    '>>',
}
local UNARY_OPERATORS = {
    '-',
    '~',
}

-- a random integer expression as source text
local function expression(depth)
    local parts = {}
    if random(3) == 1 then
        parts[#parts + 1] = UNARY_OPERATORS[random(2)]
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

-- the functions of the operators, compiled by the running Lua: nil on a
-- runtime without the operators of Lua 5.3
local FUNCTIONS = (function()
    local src = {
        'return {',
    }
    for _, op in ipairs(OPERATORS) do
        src[#src + 1] = ('[%q] = function(a, b) return a %s b end,'):format(op,
                                                                            op)
    end
    src[#src + 1] = '}, { ["-"] = function(a) return -a end,' ..
                        ' ["~"] = function(a) return ~a end }'
    local fn = (loadstring or load)(table.concat(src, '\n'))
    if fn then
        return {
            fn(),
        }
    end
end)()

-- the value of a tree of integer expressions
local function evaluate(node)
    if type(node) == 'string' then
        return tonumber(node)
    elseif #node == 2 then
        return FUNCTIONS[2][node[1]](evaluate(node[2]))
    end
    return FUNCTIONS[1][node[1]](evaluate(node[2]), evaluate(node[3]))
end

function testcase.trees_evaluate_as_lua_evaluates_the_source()
    if not FUNCTIONS then
        -- the running Lua cannot evaluate the source
        return
    end
    without_hook(function()
        for _ = 1, 300 do
            local source = expression(0)
            local ok, expected = pcall(assert(load('return ' .. source)))
            local ok2, value = pcall(evaluate, tree_of(source))
            -- an integer division or a modulo by zero is an error
            assert.equal({
                source,
                ok2,
                ok2 and value,
            }, {
                source,
                ok,
                ok and expected,
            })
        end
    end)
end
