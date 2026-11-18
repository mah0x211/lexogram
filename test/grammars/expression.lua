-- Shared parts of the expression tests of the Lua grammars
-- (test/grammars/lua5x_expression_test.lua). A Lua grammar lists the terms
-- and operators of an expression flat (rules unop and binop inside exp);
-- these functions build expression trees from the event array, the kind
-- table and a table of operator priorities alone, as a consumer would,
-- without reading the source again. Loaded with dofile from the directory
-- of the tests.
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- the shared helpers, next to this file
local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')
local without_hook = shared.without_hook

--- new returns the function tree_of(source) of the built-in grammar name,
--- which parses "return " .. source and returns the tree of its first
--- expression: { op, operand } for a unary operator, { op, left, right }
--- for a binary one, and the text of any other operand. priority maps each
--- binary operator to its priorities { left, right }, as in lparser.c,
--- where a right priority below the left one makes the operator right
--- associative; unary is the priority of the operand of a unary operator.
--- @param name string
--- @param priority table
--- @param unary integer
--- @return function tree_of
local function new(name, priority, unary)
    local COMPILED

    local function compiled()
        if not COMPILED then
            COMPILED = assert(shared.compile(name))
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
            local rule = events.name(result, j)
            if rule == 'unop' or rule == 'binop' then
                items[#items + 1] = {
                    op = events.text(result, children(result, j)[1]),
                    unary = rule == 'unop',
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
            inner, pos = climb(result, items, pos + 1, unary)
            node = {
                item.op,
                inner,
            }
        else
            node = operand(result, item.event)
            pos = pos + 1
        end
        item = items[pos]
        while item and priority[item.op][1] > limit do
            local right
            right, pos = climb(result, items, pos + 1, priority[item.op][2])
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

    return tree_of
end

return {
    new = new,
    without_hook = without_hook,
}
