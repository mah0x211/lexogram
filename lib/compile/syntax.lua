--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- lexogram.compile.syntax: the lookahead decision of every decision point
-- of the rules and the syntax diagnostics. The grammar must have passed the
-- earlier passes of lexogram.check without errors, and lexer_result must
-- be the result of lexogram.compile.lexer.build for it.
--
-- Decision data (result.decisions, keyed by the AST node of the decision
-- in result.rules; plain tables of kind ids, 0 being the end of input):
--   unordered choice: { type = 'choice', first = { [t] = i }, second =
--     { [t] = { [b] = i } } }: the next token t selects alternative i;
--     for a token shared by several alternatives, the token b after it
--     selects the alternative instead (strong LL(2)).
--   ordered choice: { type = 'ordered', first = { [i] = { t, ... } } }:
--     the sorted FIRST1 of each alternative, followed by what follows the
--     choice; the runtime tries the alternatives in order and skips one
--     whose set does not contain the next token.
--   opt, star, plus: { type = 'opt' | 'star' | 'plus', enter = { [t] =
--     true }, second = { [t] = { [b] = true } }, greedy = <example key>? }:
--     the element is entered on a token of enter; for a token that can
--     also follow the element (exit), only on a second token b of second.
--     greedy is set when some 2-token string both enters and exits: the
--     runtime enters (greedy); the key (see lexogram.compile.ll) is an
--     example string. Such a repetition must be possessive (?+, *+, ++),
--     which declares that the greedy choice is intended; otherwise it is
--     the error ambiguous_repetition. A possessive repetition that is not
--     ambiguous is warned about (unneeded_possessive).
local next = next
local rawget = rawget
local ipairs = ipairs
local type = type
local floor = math.floor
local gsub = string.gsub
local char = string.char
local concat = table.concat
local sort = table.sort
local byte_less = require('lexogram.compat').byte_less
local parse = require('lexogram.pattern').parse
local quote = require('lexogram.text').quote
local ll = require('lexogram.compile.ll')

local EPS = ll.EPS
local BASE = ll.BASE

-- ASCII case folding table: "A".."Z" to "a".."z" (byte ranges in Lua
-- patterns compare byte values, so this does not depend on the locale).
local FOLD = {}
for b = 65, 90 do
    FOLD[char(b)] = char(b + 32)
end

--- fold returns s with ASCII upper case letters folded to lower case.
--- @param s string
--- @return string
local function fold(s)
    return (gsub(s, '[A-Z]', FOLD))
end

--- pair returns the array { a, b }.
--- @param a any
--- @param b any
--- @return table
local function pair(a, b)
    local t = {}
    t[1], t[2] = a, b
    return t
end

--- add_diagnostic appends a diagnostic.
--- @param ctx table
--- @param severity string
--- @param code string
--- @param segments any[]
--- @param pos integer?
--- @param message string
local function add_diagnostic(ctx, severity, code, segments, pos, message)
    local list = ctx.diagnostics
    list[#list + 1] = {
        severity = severity,
        code = code,
        segments = segments,
        pos = pos,
        message = message,
    }
end

-- terminals

--- new_terminal returns the terminal function for ll.analyze: the kind id
--- of a literal (exact match first, otherwise an ignore_case item equal
--- after ASCII folding) or of a token ref, nil for a rule ref. It also
--- returns the kind names for messages and the aliases for ll.analyze: a
--- pattern token that a contextual keyword is read as matches the keyword.
--- @param grammar table
--- @param defs table[] lexer definitions
--- @return function terminal
--- @return table names kind id -> printable name
--- @return table aliases kind id -> kind ids
local function new_terminal(grammar, defs)
    local tokens, exact, folded, names, aliases = {}, {}, {}, {}, {}
    for _, def in ipairs(defs) do
        local kind = def.kind
        if kind == 'token' or kind == 'delimited' then
            tokens[def.name] = def.id
            names[def.id] = def.name
        elseif kind == 'symbol' or kind == 'keyword' or kind == 'contextual' then
            exact[def.name] = def.id
            names[def.id] = quote(def.name)
            if rawget(rawget(grammar, def.segments[1]), 'ignore_case') == true then
                folded[fold(def.name)] = def.id
            end
            if kind == 'contextual' then
                local list = aliases[def.base] or {}
                list[#list + 1] = def.id
                aliases[def.base] = list
            end
        end
    end
    names[0] = 'end of input'
    return function(node)
        if node.type == 'literal' then
            return exact[node.value] or folded[fold(node.value)]
        end
        return tokens[node.name]
    end, names, aliases
end

--- render returns a k = 2 key (see lexogram.compile.ll) as kind names.
--- @param names table
--- @param key integer
--- @return string
local function render(names, key)
    local a, rest = floor(key / BASE), key % BASE
    if rest == 0 then
        return names[a]
    end
    return names[a] .. ' ' .. names[rest - 1]
end

--- smallest returns the smallest key in s, or nil.
--- @param s table
--- @return integer?
local function smallest(s)
    local min
    for k in next, s do
        if min == nil or k < min then
            min = k
        end
    end
    return min
end

--- intersect returns the keys of s that are in t.
--- @param s table
--- @param t table
--- @return table
local function intersect(s, t)
    local out = {}
    for k in next, s do
        if t[k] then
            out[k] = true
        end
    end
    return out
end

-- rules

--- extract_aliases replaces each alias node of the rules (p->name) by a
--- reference to a rule of its own, which matches p: it is named "_" ..
--- rule .. "->" .. serial ("_chunk->1"), which no grammar can write (a
--- name has no "-"), and it is reported with the kind of the aliased rule.
--- It returns the aliased rule of each such rule and the rule of the
--- grammar each comes from. The traversal is iterative; the rules are
--- visited in name order, so the names are the same on every runtime.
--- @param names string[] sorted rule names
--- @param rules table name -> AST; changed in place
--- @return table alias_of rule -> aliased rule
--- @return table origin rule -> rule of the grammar
local function extract_aliases(names, rules)
    local alias_of, origin = {}, {}
    local queue = {}
    for i, name in ipairs(names) do
        queue[i] = name
    end
    local serial = 0
    local head = 1
    while queue[head] do
        local name = queue[head]
        head = head + 1
        local owner = origin[name] or name
        local function lift(node)
            serial = serial + 1
            local rule = '_' .. owner .. '->' .. serial
            rules[rule] = node.item
            alias_of[rule] = node.name
            origin[rule] = owner
            queue[#queue + 1] = rule
            return {
                type = 'ref',
                pos = node.pos,
                name = rule,
            }
        end
        if rules[name].type == 'alias' then
            rules[name] = lift(rules[name])
        end
        local stack = {
            rules[name],
        }
        while #stack > 0 do
            local node = stack[#stack]
            stack[#stack] = nil
            local items = node.items
            if items then
                for i, item in ipairs(items) do
                    if item.type == 'alias' then
                        items[i] = lift(item)
                    else
                        stack[#stack + 1] = item
                    end
                end
            elseif node.item then
                if node.item.type == 'alias' then
                    node.item = lift(node.item)
                else
                    stack[#stack + 1] = node.item
                end
            end
        end
    end
    return alias_of, origin
end

--- shown returns the rule of the grammar that a rule comes from (itself, or
--- the rule where the alias that made it is written), for diagnostics.
--- @param ctx table
--- @param name string
--- @return string
local function shown(ctx, name)
    return ctx.origin[name] or name
end

--- parse_rules returns the sorted rule names and their ASTs.
--- @param grammar table
--- @return string[] names
--- @return table rules name -> AST
local function parse_rules(grammar)
    local rules, names = {}, {}
    for name, src in next, rawget(grammar, 'rules') do
        names[#names + 1] = name
        rules[name] = parse(src, 'rules')
    end
    sort(names, byte_less)
    return names, rules
end

--- preorder returns the nodes of ast in preorder.
--- @param ast table
--- @return table[]
local function preorder(ast)
    local out = {}
    local stack = {}
    stack[1] = ast
    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        out[#out + 1] = node
        if node.items then
            for i = #node.items, 1, -1 do
                stack[#stack + 1] = node.items[i]
            end
        elseif node.item then
            stack[#stack + 1] = node.item
        end
    end
    return out
end

--- check_skipped reports references to tokens listed in skip.
--- @param ctx table
local function check_skipped(ctx)
    local skipped = {}
    local skip = rawget(ctx.grammar, 'skip')
    if type(skip) == 'table' then
        for _, name in next, skip do
            skipped[name] = true
        end
    end
    for _, name in ipairs(ctx.names) do
        for _, node in ipairs(preorder(ctx.rules[name])) do
            if node.type == 'ref' and skipped[node.name] and ctx.terminal(node) then
                add_diagnostic(ctx, 'error', 'skipped_token',
                               pair('rules', shown(ctx, name)), node.pos,
                               'rules.' .. shown(ctx, name) .. ' refers to ' ..
                                   node.name ..
                                   ', which is listed in skip and never' ..
                                   ' reaches the parser')
            end
        end
    end
end

--- productive_node returns true if root derives a finite token string,
--- given the productive rules prod. It is computed in post-order with an
--- explicit stack.
--- @param root table
--- @param prod table rule -> true
--- @param terminal function
--- @return boolean
local function productive_node(root, prod, terminal)
    local res = {}
    local stack = {}
    stack[1] = root
    while #stack > 0 do
        local node = stack[#stack]
        local kids = node.items
        if not kids then
            kids = {}
            kids[1] = node.item
        end
        local pending = false
        for i = #kids, 1, -1 do
            if res[kids[i]] == nil then
                stack[#stack + 1] = kids[i]
                pending = true
            end
        end
        if not pending then
            local t, v = node.type
            if t == 'literal' or t == 'ref' then
                v = terminal(node) ~= nil or prod[node.name] == true
            elseif t == 'opt' or t == 'star' then
                v = true
            elseif t == 'plus' or t == 'prefix' then
                v = res[node.item]
            else
                -- seq: every item; choice: some alternative
                v = t == 'seq'
                for _, kid in ipairs(kids) do
                    if res[kid] ~= v then
                        v = not v
                        break
                    end
                end
            end
            res[node] = v
            stack[#stack] = nil
        end
    end
    return res[root]
end

--- productive_rules returns the set of rules that derive a finite token
--- string (a fixed point: a rule is productive once its AST is, given the
--- rules found so far).
--- @param ctx table
--- @return table rule -> true
local function productive_rules(ctx)
    local prod = {}
    local changed = true
    while changed do
        changed = false
        for _, name in ipairs(ctx.names) do
            if not prod[name] and
                productive_node(ctx.rules[name], prod, ctx.terminal) then
                prod[name] = true
                changed = true
            end
        end
    end
    return prod
end

--- check_termination reports left recursion and rules that derive no
--- finite token string; it returns true if it found any.
--- @param ctx table
--- @return boolean
local function check_termination(ctx)
    local a = ctx.analysis
    local before = #ctx.diagnostics
    for _, cycle in ipairs(a.left_recursion) do
        -- the rules of aliases are shown as the rules they are written in,
        -- once
        local list = {}
        for _, name in ipairs(cycle) do
            local rule = shown(ctx, name)
            if rule ~= list[#list] then
                list[#list + 1] = rule
            end
        end
        if #list > 1 and list[#list] == list[1] then
            list[#list] = nil
        end
        cycle = list
        add_diagnostic(ctx, 'error', 'left_recursion', pair('rules', cycle[1]),
                       nil,
                       'rule ' .. cycle[1] .. ' is left-recursive: ' ..
                           concat(cycle, ' -> ') .. ' -> ' .. cycle[1])
    end
    local prod = productive_rules(ctx)
    for _, name in ipairs(ctx.names) do
        if not prod[name] then
            add_diagnostic(ctx, 'error', 'nonterminating_rule',
                           pair('rules', shown(ctx, name)), nil,
                           'rules.' .. shown(ctx, name) ..
                               ' derives no finite token string, so it can' ..
                               ' never finish matching')
        end
    end
    return #ctx.diagnostics > before
end

-- decisions

--- continuations returns, for every node of the rule, the continuation
--- sets for k = 1 and k = 2 passed by ll.walk.
--- @param a table analysis
--- @param name string
--- @return table node -> { cont1, cont2 }
local function continuations(a, name)
    local conts = {}
    ll.walk(a, name, 1, function(node, cont)
        conts[node] = pair(cont, nil)
    end)
    ll.walk(a, name, 2, function(node, cont)
        conts[node][2] = cont
    end)
    return conts
end

--- choice_decision computes the decision of an unordered choice and
--- reports ambiguous pairs of alternatives.
--- @param ctx table
--- @param name string
--- @param node table
--- @param conts table
--- @return table decision
local function choice_decision(ctx, name, node, conts)
    local a = ctx.analysis
    local cont = conts[node]
    local first1, first2 = {}, {}
    for i, alt in ipairs(node.items) do
        first1[i] = ll.first(a, {
            alt,
        }, 1, cont[1])
        first2[i] = ll.first(a, {
            alt,
        }, 2, cont[2])
    end
    for i = 1, #node.items do
        for j = i + 1, #node.items do
            local shared = smallest(intersect(first2[i], first2[j]))
            if shared then
                add_diagnostic(ctx, 'error', 'ambiguous_choice',
                               pair('rules', shown(ctx, name)), node.pos,
                               'rules.' .. shown(ctx, name) .. ': alternatives ' ..
                                   i .. ' and ' .. j ..
                                   ' of the choice can both' .. ' start with ' ..
                                   render(ctx.names_of, shared))
            end
        end
    end

    local first, second = {}, {}
    local owners = {}
    for i, set in ipairs(first1) do
        for t in next, set do
            owners[t] = (owners[t] or 0) + 1
            first[t] = i
        end
    end
    for t, n in next, owners do
        if n > 1 then
            first[t] = nil
            local map = {}
            for i, set in ipairs(first2) do
                for key in next, set do
                    if floor(key / BASE) == t and key % BASE ~= 0 then
                        map[key % BASE - 1] = i
                    end
                end
            end
            second[t] = map
        end
    end
    return {
        type = 'choice',
        first = first,
        second = second,
    }
end

--- ordered_decision computes the decision of an ordered choice.
--- @param ctx table
--- @param node table
--- @param conts table
--- @return table decision
local function ordered_decision(ctx, node, conts)
    local first = {}
    for i, alt in ipairs(node.items) do
        first[i] = ll.to_array(ll.first(ctx.analysis, {
            alt,
        }, 1, conts[node][1]), 1)
    end
    return {
        type = 'ordered',
        first = first,
    }
end

-- The operator of each repetition node type.
local OPERATORS = {
    opt = '?',
    star = '*',
    plus = '+',
}

--- repeat_decision computes the decision of an opt, star or plus node,
--- reports a repeated element that can match the empty string and an
--- ambiguous repetition that is not possessive, and records a possessive
--- repetition that is not ambiguous.
--- @param ctx table
--- @param name string
--- @param node table
--- @param conts table
--- @return table decision
local function repeat_decision(ctx, name, node, conts)
    local a = ctx.analysis
    local item = node.item
    -- a repetition of a nullable element is also ambiguous; only the cause
    -- is reported, and the ambiguity of the repetition is not
    local nullable = node.type ~= 'opt' and ll.first(a, {
        item,
    }, 1, {
        [EPS] = true,
    })[EPS]
    if nullable then
        add_diagnostic(ctx, 'error', 'nullable_repetition',
                       pair('rules', shown(ctx, name)), node.pos,
                       'rules.' .. shown(ctx, name) .. ': the repeated element' ..
                           ' can match the empty string')
    end

    local enter1 = ll.first(a, {
        item,
    }, 1, conts[item][1])
    local exit1 = conts[node][1]
    local enter2 = ll.first(a, {
        item,
    }, 2, conts[item][2])
    local second = {}
    for t in next, intersect(enter1, exit1) do
        local map = {}
        for key in next, enter2 do
            if floor(key / BASE) == t and key % BASE ~= 0 then
                map[key % BASE - 1] = true
            end
        end
        second[t] = map
    end
    local greedy = smallest(intersect(enter2, conts[node][2]))
    -- a repetition of a count {n,m} is told by its count, and the nodes of
    -- a possessive count share a group, which needs the "+" when any of
    -- them is ambiguous
    local count = node.count
    local operator = count or OPERATORS[node.type]
    local what = (node.type == 'opt' and not count) and 'optional element' or
                     'repetition'
    if node.group and greedy then
        node.group.needed = true
    end
    if not nullable and greedy and not node.possessive then
        add_diagnostic(ctx, 'error', 'ambiguous_repetition',
                       pair('rules', shown(ctx, name)), node.pos,
                       'rules.' .. shown(ctx, name) .. ': the ' .. what ..
                           (what == 'optional element' and
                               ' can both be taken and skipped' or
                               ' can both continue and end') .. ' with ' ..
                           render(ctx.names_of, greedy) ..
                           '; rewrite the rule, or write ' .. operator ..
                           '+ to always take the element')
    elseif not nullable and node.possessive and not greedy then
        local unneeded = ctx.unneeded
        unneeded[#unneeded + 1] = {
            rule = shown(ctx, name),
            node = node,
            message = 'rules.' .. shown(ctx, name) .. ': ' .. operator ..
                '+ is not' .. ' needed: the ' .. what .. ' is never ambiguous',
        }
    end
    return {
        type = node.type,
        enter = enter1,
        second = second,
        greedy = greedy,
    }
end

--- compute_decisions computes the decisions of every rule.
--- @param ctx table
--- @return table node -> decision
local function compute_decisions(ctx)
    local decisions = {}
    for _, name in ipairs(ctx.names) do
        local conts = continuations(ctx.analysis, name)
        for _, node in ipairs(preorder(ctx.rules[name])) do
            local t = node.type
            if t == 'choice' and node.ordered then
                decisions[node] = ordered_decision(ctx, node, conts)
            elseif t == 'choice' then
                decisions[node] = choice_decision(ctx, name, node, conts)
            elseif t == 'opt' or t == 'star' or t == 'plus' then
                decisions[node] = repeat_decision(ctx, name, node, conts)
            end
        end
    end
    return decisions
end

--- warn_unneeded warns about the possessive repetitions that are not
--- ambiguous. It runs only for a grammar without errors, since warnings
--- are reported only then.
--- @param ctx table
local function warn_unneeded(ctx)
    for _, u in ipairs(ctx.unneeded) do
        local group = u.node.group
        if not (group and group.needed) then
            add_diagnostic(ctx, 'warning', 'unneeded_possessive',
                           pair('rules', u.rule), u.node.pos, u.message)
        end
    end
end

--- has_error returns true if ctx has an error diagnostic.
--- @param ctx table
--- @return boolean
local function has_error(ctx)
    for _, d in ipairs(ctx.diagnostics) do
        if d.severity == 'error' then
            return true
        end
    end
    return false
end

--- analyze computes the decisions and the syntax diagnostics of grammar.
--- @param grammar table a grammar that passed the earlier checks
--- @param lexer_result table result of lexogram.compile.lexer.build
--- @return table? result { analysis, rules, decisions }, nil on error
--- @return table[] diagnostics { severity, code, segments, pos, message }
local function analyze(grammar, lexer_result)
    local names, rules = parse_rules(grammar)
    local alias_of, origin = extract_aliases(names, rules)
    if next(alias_of) then
        names = {}
        for name in next, rules do
            names[#names + 1] = name
        end
        sort(names, byte_less)
    end
    local terminal, names_of, aliases = new_terminal(grammar, lexer_result.defs)
    local ctx = {
        grammar = grammar,
        names = names,
        rules = rules,
        terminal = terminal,
        names_of = names_of,
        origin = origin,
        diagnostics = {},
        unneeded = {},
    }
    check_skipped(ctx)
    ctx.analysis =
        ll.analyze(rules, rawget(grammar, 'start'), terminal, aliases)
    if check_termination(ctx) then
        return nil, ctx.diagnostics
    end
    local decisions = compute_decisions(ctx)
    if has_error(ctx) then
        return nil, ctx.diagnostics
    end
    warn_unneeded(ctx)
    return {
        analysis = ctx.analysis,
        rules = rules,
        alias_of = alias_of,
        decisions = decisions,
    }, ctx.diagnostics
end

return {
    analyze = analyze,
}
