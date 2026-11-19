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
-- lexogram.compile.ll: grammar analysis for the syntax compiler:
-- nullability, FIRST and FOLLOW sets for k = 1 and k = 2 (strong LL(k)),
-- and left recursion. Every traversal is iterative.
--
-- Terminals are kind ids (positive integers); 0 is the end of input. The
-- caller's terminal(node) maps a literal node, or a ref node naming a token,
-- to its kind id, and returns nil for a ref naming a rule. A kind may have
-- aliases (aliases[id] = { id2, ... }): kinds of the tokens that it also
-- matches, so that its sets have them too (a contextual keyword is a token
-- of its base kind with a given text: a ref to the base kind matches it).
--
-- Sets of terminal strings of length <= k are tables whose keys are
-- encoded strings (key -> true):
--   EPS (-1)           the empty string
--   k = 1: a           the string "a"
--   k = 2: a * BASE    the string "a" (complete only when it ends the
--                      input: a = 0, or the derivation is exactly "a")
--          a * BASE + b + 1  the string "a b"
-- so that numeric order sorts by the first terminal, then a string of
-- length 1 before strings of length 2, then by the second terminal with
-- the end of input (0) first. The output arrays (to_array) list these in
-- that order: k = 1 as kind ids, k = 2 as { a } or { a, b }.
--
-- Example: with id = 1, "(" = 2, the k = 2 set { "1 2", "1", EPS } is the
-- table { [1 * BASE + 3] = true, [1 * BASE] = true, [-1] = true } and its
-- array form is { { 1 }, { 1, 2 } } (EPS is reported as nullable).
--
-- Fixed points: FIRST_k of every rule starts empty and is recomputed from
-- the rule ASTs, in name order, until no set grows; FOLLOW_k likewise,
-- starting from the end of input after start. Sets only grow, and each is
-- bounded by (number of kinds + 1)^k + 1 strings, so the iteration ends;
-- one pass costs O(grammar size * set operations), and in practice a few
-- passes suffice.
local next = next
local ipairs = ipairs
local floor = math.floor
local sort = table.sort
local byte_less = require('lexogram.compat').byte_less
local find_cycles = require('lexogram.compile.nfa').find_cycles

-- The empty string.
local EPS = -1
-- Multiplier of the first terminal in a k = 2 key (2^24); kind ids must be
-- below. It is written as an integer literal: 2 ^ 24 is a float on Lua 5.3
-- and later, which would turn every key and decoded kind id into a float
-- (3.0 instead of 3) and make results differ between runtimes.
local BASE = 16777216

-- string sets

--- single returns the key of the one-terminal string a.
--- @param a integer
--- @param k integer
--- @return integer
local function single(a, k)
    return k == 1 and a or a * BASE
end

--- concat returns the truncated concatenation s . t of two sets.
--- @param s table
--- @param t table
--- @param k integer
--- @return table
local function concat(s, t, k)
    local out = {}
    -- for the strings of one terminal in s: the first terminals of the
    -- strings of t, as the numbers to add to their keys, and whether t has
    -- the empty string, made once
    local heads, empty
    for x in next, s do
        if x == EPS then
            for y in next, t do
                out[y] = true
            end
        elseif k == 1 or x == 0 or x % BASE ~= 0 then
            -- complete: length k, or ends the input
            out[x] = true
        else
            if not heads then
                heads, empty = {}, false
                local seen = {}
                for y in next, t do
                    if y == EPS then
                        empty = true
                    else
                        -- the first terminal of y (k = 2 keys)
                        local h = floor(y / BASE) + 1
                        if not seen[h] then
                            seen[h] = true
                            heads[#heads + 1] = h
                        end
                    end
                end
            end
            if empty then
                out[x] = true
            end
            for i = 1, #heads do
                out[x + heads[i]] = true
            end
        end
    end
    return out
end

--- union adds the strings of t to s and returns the number added.
--- @param s table
--- @param t table
--- @return integer
local function union(s, t)
    local added = 0
    for y in next, t do
        if not s[y] then
            s[y] = true
            added = added + 1
        end
    end
    return added
end

--- to_array returns the strings of s, except EPS, as a sorted array: kind
--- ids for k = 1, { a } or { a, b } for k = 2.
--- @param s table
--- @param k integer
--- @return table
local function to_array(s, k)
    local keys = {}
    for x in next, s do
        if x ~= EPS then
            keys[#keys + 1] = x
        end
    end
    sort(keys)
    if k == 1 then
        return keys
    end
    local out = {}
    for i, x in ipairs(keys) do
        local a, rest = floor(x / BASE), x % BASE
        out[i] = rest == 0 and {
            a,
        } or {
            a,
            rest - 1,
        }
    end
    return out
end

-- FIRST of nodes

--- star_first returns FIRST_k of X* from s = FIRST_k(X).
--- @param s table
--- @param k integer
--- @return table
local function star_first(s, k)
    local r = {
        [EPS] = true,
    }
    while union(r, concat(s, r, k)) > 0 do
    end
    return r
end

--- children returns the child nodes of node that its FIRST depends on.
--- @param node table
--- @return table[]
local function children(node)
    if node.items then
        return node.items
    elseif node.item then
        local kids = {}
        kids[1] = node.item
        return kids
    end
    return {}
end

--- combine returns FIRST_k of node from the FIRST_k of its children.
--- @param a table analysis
--- @param node table
--- @param res table node -> set
--- @param k integer
--- @param sets table rule -> FIRST_k set
--- @return table
local function combine(a, node, res, k, sets)
    local t = node.type
    if t == 'literal' or t == 'ref' then
        local id = a.terminal(node)
        if id then
            local out = {
                [single(id, k)] = true,
            }
            local extra = a.aliases[id]
            if extra then
                for _, x in ipairs(extra) do
                    out[single(x, k)] = true
                end
            end
            return out
        end
        -- a rule: its current FIRST_k (a copy, since sets grow)
        local copy = {}
        union(copy, sets[node.name])
        return copy
    elseif t == 'seq' then
        local acc = {
            [EPS] = true,
        }
        for _, item in ipairs(node.items) do
            acc = concat(acc, res[item], k)
        end
        return acc
    elseif t == 'choice' then
        local out = {}
        for _, item in ipairs(node.items) do
            union(out, res[item])
        end
        return out
    end
    local s = res[node.item]
    if t == 'opt' then
        local out = {
            [EPS] = true,
        }
        union(out, s)
        return out
    elseif t == 'star' then
        return star_first(s, k)
    end
    -- plus
    return concat(s, star_first(s, k), k)
end

--- node_first returns FIRST_k of node with the rule sets sets, computed in
--- post-order with an explicit stack. With the final sets of the analysis
--- (a.first_sets[k], once compute_first has made them), the sets of the
--- nodes are kept in a.node_sets[k] and computed once; the callers do not
--- change the sets returned.
--- @param a table analysis
--- @param root table
--- @param k integer
--- @param sets table rule -> FIRST_k set
--- @return table
local function node_first(a, root, k, sets)
    local res = sets == a.first_sets[k] and a.node_sets[k]
    if res then
        local s = res[root]
        if s then
            return s
        end
    else
        res = {}
    end
    local stack = {}
    stack[1] = root
    while #stack > 0 do
        local node = stack[#stack]
        local kids = children(node)
        local pending = false
        for i = #kids, 1, -1 do
            if not res[kids[i]] then
                stack[#stack + 1] = kids[i]
                pending = true
            end
        end
        if not pending then
            res[node] = combine(a, node, res, k, sets)
            stack[#stack] = nil
        end
    end
    return res[root]
end

--- first returns FIRST_k of the concatenation of nodes followed by the
--- continuation set cont (e.g. a FOLLOW_k set; { [EPS] = true } for none).
--- @param a table analysis
--- @param nodes table[] AST nodes
--- @param k integer 1 or 2
--- @param cont table
--- @return table set
local function first(a, nodes, k, cont)
    local acc = {
        [EPS] = true,
    }
    for _, node in ipairs(nodes) do
        acc = concat(acc, node_first(a, node, k, a.first_sets[k]), k)
    end
    return concat(acc, cont, k)
end

-- walking rules

--- walk_node calls visit(node, cont) for root and every node below it, in
--- preorder, where cont is FIRST_k of what follows the node inside the
--- rule, concatenated with the continuation cont of root.
--- @param a table analysis
--- @param root table
--- @param k integer
--- @param cont table
--- @param visit function(node, cont)
--- @param sets table rule -> FIRST_k set
local function walk_node(a, root, k, cont, visit, sets)
    local stack = {}
    stack[1] = {
        root,
        cont,
    }
    while #stack > 0 do
        local entry = stack[#stack]
        stack[#stack] = nil
        local node, c = entry[1], entry[2]
        visit(node, c)
        local t = node.type
        if t == 'seq' then
            local items = node.items
            for i = #items, 1, -1 do
                stack[#stack + 1] = {
                    items[i],
                    c,
                }
                -- what follows the first item is not needed
                if i > 1 then
                    c = concat(node_first(a, items[i], k, sets), c, k)
                end
            end
        elseif t == 'choice' then
            for i = #node.items, 1, -1 do
                stack[#stack + 1] = {
                    node.items[i],
                    c,
                }
            end
        elseif t == 'opt' then
            stack[#stack + 1] = {
                node.item,
                c,
            }
        elseif t == 'star' or t == 'plus' then
            -- after one element, another element or the exit follows
            local s = node_first(a, node.item, k, sets)
            stack[#stack + 1] = {
                node.item,
                concat(star_first(s, k), c, k),
            }
        end
    end
end

--- walk calls visit(node, cont) for every node of the rule's AST, in
--- preorder, where cont is FIRST_k of what follows the node: the rest of
--- the rule, then FOLLOW_k of the rule. For a decision point:
---   choice:          alternative i is taken on first(a, { alt_i }, k, cont)
---   opt, star, plus: (visit the node itself) the element is taken on
---                    first(a, { node.item }, k, item_cont), where
---                    item_cont is the cont that walk passes to node.item,
---                    and skipped (exit) on cont
--- @param a table analysis
--- @param rule string
--- @param k integer 1 or 2
--- @param visit function(node, cont)
local function walk(a, rule, k, visit)
    walk_node(a, a.rules[rule], k, a.follow_sets[k][rule], visit,
              a.first_sets[k])
end

-- fixed points

--- compute_first computes FIRST_k of every rule.
--- @param a table analysis
--- @param k integer
--- @return table rule -> set
local function compute_first(a, k)
    local sets = {}
    for _, name in ipairs(a.names) do
        sets[name] = {}
    end
    local changed = true
    while changed do
        changed = false
        for _, name in ipairs(a.names) do
            local s = node_first(a, a.rules[name], k, sets)
            if union(sets[name], s) > 0 then
                changed = true
            end
        end
    end
    return sets
end

--- compute_follow computes FOLLOW_k of every rule.
--- @param a table analysis
--- @param k integer
--- @return table rule -> set
local function compute_follow(a, k)
    local sets = {}
    for _, name in ipairs(a.names) do
        sets[name] = {}
    end
    -- the end of input follows start
    sets[a.start][single(0, k)] = true
    local changed = true
    local function visit(node, cont)
        if node.type == 'ref' and not a.terminal(node) and
            union(sets[node.name], cont) > 0 then
            changed = true
        end
    end
    while changed do
        changed = false
        for _, name in ipairs(a.names) do
            local cont = {}
            union(cont, sets[name])
            walk_node(a, a.rules[name], k, cont, visit, a.first_sets[k])
        end
    end
    return sets
end

--- leftmost_calls returns, for each rule, a synthetic AST (a choice of
--- refs) of the rules it calls at a leftmost position: everything before
--- the call in its sequence is nullable.
--- @param a table analysis
--- @return table rule -> AST
local function leftmost_calls(a)
    local graph = {}
    local nullable_sets = a.first_sets[1]
    for _, name in ipairs(a.names) do
        local calls = {}
        local stack = {}
        stack[1] = a.rules[name]
        while #stack > 0 do
            local node = stack[#stack]
            stack[#stack] = nil
            if node.type == 'ref' then
                if not a.terminal(node) then
                    calls[#calls + 1] = {
                        type = 'ref',
                        name = node.name,
                    }
                end
            elseif node.type == 'seq' then
                -- items up to and including the first non-nullable one
                for _, item in ipairs(node.items) do
                    stack[#stack + 1] = item
                    if not node_first(a, item, 1, nullable_sets)[EPS] then
                        break
                    end
                end
            elseif node.items then
                for _, item in ipairs(node.items) do
                    stack[#stack + 1] = item
                end
            elseif node.item then
                stack[#stack + 1] = node.item
            end
        end
        graph[name] = {
            type = 'choice',
            items = calls,
        }
    end
    return graph
end

--- analyze analyzes the rules of a grammar.
--- @param rules table rule name -> AST (rules context)
--- @param start string the start rule
--- @param terminal function(node) kind id of a literal or token ref, nil
--- for a rule ref
--- @param aliases table? kind id -> array of the kind ids it also matches
--- @return table analysis {
---   nullable  = rule -> boolean,
---   first1, follow1 = rule -> sorted kind ids (follow1 may contain 0),
---   first2, follow2 = rule -> sorted { a } / { a, b } arrays,
---   left_recursion = array of cycles (arrays of rule names),
---   first_sets, follow_sets = k -> rule -> key set (with EPS), used by
---   first and walk,
---   node_sets = k -> node -> FIRST_k key set, kept by first and walk }
local function analyze(rules, start, terminal, aliases)
    local names = {}
    for name in next, rules do
        names[#names + 1] = name
    end
    sort(names, byte_less)

    local a = {
        rules = rules,
        start = start,
        terminal = terminal,
        aliases = aliases or {},
        names = names,
        first_sets = {},
        follow_sets = {},
        -- k -> node -> FIRST_k set (see node_first)
        node_sets = {
            {},
            {},
        },
    }
    for k = 1, 2 do
        a.first_sets[k] = compute_first(a, k)
        a.follow_sets[k] = compute_follow(a, k)
    end

    a.nullable, a.first1, a.follow1, a.first2, a.follow2 = {}, {}, {}, {}, {}
    for _, name in ipairs(names) do
        a.nullable[name] = a.first_sets[1][name][EPS] == true
        a.first1[name] = to_array(a.first_sets[1][name], 1)
        a.follow1[name] = to_array(a.follow_sets[1][name], 1)
        a.first2[name] = to_array(a.first_sets[2][name], 2)
        a.follow2[name] = to_array(a.follow_sets[2][name], 2)
    end
    a.left_recursion = find_cycles(leftmost_calls(a))
    return a
end

return {
    EPS = EPS,
    BASE = BASE,
    analyze = analyze,
    first = first,
    walk = walk,
    concat = concat,
    to_array = to_array,
}
