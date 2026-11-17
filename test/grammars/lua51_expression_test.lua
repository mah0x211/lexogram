local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- The grammar lists the terms and operators of an expression flat (rules
-- unop and binop inside exp). This test builds expression trees from the
-- event array, the kind table and a table of operator priorities alone, as
-- a consumer would, without reading the source again: the priorities are
-- those of the Lua 5.1 parser (lparser.c), { left, right }, where a right
-- priority below the left one makes the operator right associative.
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

local COMPILED

-- run fn with the coverage hook removed: compiling the full grammar takes
-- far too long under luacov's line hook
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

local function compiled()
    if not COMPILED then
        local grammar = assert(lexogram.load('lexogram:lua51'))
        COMPILED = assert(without_hook(lexogram.compile, grammar))
    end
    return COMPILED
end

-- the numbers of the events directly inside the rule of the ENTER event
-- i, without skipped tokens
local function children(result, i)
    local kinds = result.grammar.kinds
    local list = {}
    for j in events.children(result, i) do
        if not kinds[events.kind(result, j)].skip then
            list[#list + 1] = j
        end
    end
    return list
end

local build

-- the tree of an operand: a parenthesized expression is built in turn, any
-- other operand is its text
local function operand(result, i)
    if events.name(result, i) == 'suffixedexp' then
        local list = children(result, i)
        if #list == 3 and events.text(result, list[1]) == '(' and
            events.name(result, list[2]) == 'exp' then
            return build(result, list[2])
        end
    end
    return events.text(result, i)
end

-- the items of the exp of the ENTER event i: { op = <operator>, unary =
-- <boolean> } for an operator, { event = <number> } for an operand
local function items_of(result, i)
    local items = {}
    for _, j in ipairs(children(result, i)) do
        local name = events.name(result, j)
        if name == 'unop' or name == 'binop' then
            items[#items + 1] = {
                op = events.text(result, children(result, j)[1]),
                unary = name == 'unop',
            }
        else
            items[#items + 1] = {
                event = j,
            }
        end
    end
    return items
end

-- precedence climbing over items from pos, as subexpr of lparser.c: it
-- returns the tree of the expression whose binary operators have a left
-- priority above limit, and the position after it
local function climb(result, items, pos, limit)
    local node
    local item = items[pos]
    if item.unary then
        local inner
        inner, pos = climb(result, items, pos + 1, UNARY)
        node = {
            item.op,
            inner,
        }
    else
        node = operand(result, item.event)
        pos = pos + 1
    end
    item = items[pos]
    while item and PRIORITY[item.op][1] > limit do
        local right
        right, pos = climb(result, items, pos + 1, PRIORITY[item.op][2])
        node = {
            item.op,
            node,
            right,
        }
        item = items[pos]
    end
    return node, pos
end

-- the tree of the exp of the ENTER event i: { op, operand } for a unary
-- operator, { op, left, right } for a binary one, and text for an operand
function build(result, i)
    local items = items_of(result, i)
    local node, pos = climb(result, items, 1, 0)
    assert.equal(pos, #items + 1)
    return node
end

-- the tree of the expression source
local function tree_of(source)
    local result = assert(lexogram.parse(compiled(), 'return ' .. source))
    for i = 1, result.count do
        if events.op(result, i) == events.ENTER and events.name(result, i) ==
            'exp' then
            return build(result, i)
        end
    end
end

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
