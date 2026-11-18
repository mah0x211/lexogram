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
-- lexogram.compile.nfa: Thompson construction of one combined
-- non-deterministic automaton over bytes for all token definitions, cycle
-- detection for fragment references, and a reference simulator. Every
-- traversal of an AST or a graph is iterative with an explicit stack or
-- queue.
--
-- A lookahead (?= p ) or (?! p ) becomes an epsilon edge guarded by a
-- predicate (geps: { to, pred, value }): it can be taken at a position
-- where the predicate, "the input from here starts with a string of p",
-- has the value (true for (?=, false for (?!). The predicates are kept in
-- a registry shared by the machines of a grammar (new_predicates), one per
-- lookahead node; build_predicate builds the machine of p itself, which may
-- register the predicates of nested lookaheads.
local error = error
local pairs = pairs
local tostring = tostring
local pcall = pcall
local ipairs = ipairs
local byte = string.byte
local sort = table.sort
local byte_less = require('lexogram.compat').byte_less
local split_codepoints = require('lexogram.compile.utf8range').split
local get_limit = require('lexogram.compile.limits').get

-- Largest number of states of a machine. Fragments are expanded inline, so
-- a chain of fragments that each use the previous one twice grows
-- exponentially; the limit stops such a construction early.
local MAX_STATES = 200000

-- fragment reference graph

--- collect_refs returns the sorted, distinct names referenced by ref nodes
--- of ast that are keys of fragments.
--- @param ast table
--- @param fragments table
--- @return string[]
local function collect_refs(ast, fragments)
    local names, seen = {}, {}
    local stack = {
        ast,
    }
    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        if node.type == 'ref' then
            local name = node.name
            if fragments[name] ~= nil and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        elseif node.items then
            for i = #node.items, 1, -1 do
                stack[#stack + 1] = node.items[i]
            end
        elseif node.item then
            stack[#stack + 1] = node.item
        end
    end
    sort(names, byte_less)
    return names
end

--- sorted_names returns the keys of fragments in byte order.
--- @param fragments table
--- @return string[]
local function sorted_names(fragments)
    local names = {}
    for name in pairs(fragments) do
        names[#names + 1] = name
    end
    sort(names, byte_less)
    return names
end

--- reach returns the set of names reachable from name in one or more
--- steps along the adjacency lists adj.
--- @param adj table name -> sorted names
--- @param name string
--- @return table set
local function reach(adj, name)
    local seen = {}
    local stack = {
        name,
    }
    while #stack > 0 do
        local v = stack[#stack]
        stack[#stack] = nil
        for _, w in ipairs(adj[v]) do
            if not seen[w] then
                seen[w] = true
                stack[#stack + 1] = w
            end
        end
    end
    return seen
end

--- shortest_cycle returns the shortest cycle from name back to itself that
--- stays inside the set scc, as a list of names starting with name. Among
--- cycles of equal length, the first found in byte order of the adjacency
--- lists is returned.
--- @param adj table
--- @param name string
--- @param scc table set of names
--- @return string[]
local function shortest_cycle(adj, name, scc)
    local parent = {}
    local queue = {
        name,
    }
    local head = 1
    while true do
        local u = queue[head]
        head = head + 1
        for _, w in ipairs(adj[u]) do
            if w == name then
                local path = {}
                while u ~= name do
                    path[#path + 1] = u
                    u = parent[u]
                end
                path[#path + 1] = name
                -- reverse into reference order
                local cycle = {}
                for i = #path, 1, -1 do
                    cycle[#cycle + 1] = path[i]
                end
                return cycle
            elseif scc[w] and parent[w] == nil then
                parent[w] = u
                queue[#queue + 1] = w
            end
        end
    end
end

--- find_cycles returns, for each strongly connected component of the
--- fragment reference graph that contains a cycle, one shortest cycle
--- through the component's smallest name (byte order). Cycles start with
--- that name and are ordered by it. References to names that are not
--- fragments are ignored.
---
--- Enumerating every elementary cycle can produce exponentially many
--- cycles; one cycle per component is enough to report the problem and is
--- bounded by the number of fragments. Complexity: O(V * (V + E)) for V
--- fragments and E distinct references (one forward reachability search
--- per name; fragment graphs are small).
--- @param fragments table fragment name -> AST
--- @return string[][] cycles
local function find_cycles(fragments)
    local names = sorted_names(fragments)
    local adj = {}
    for _, name in ipairs(names) do
        adj[name] = collect_refs(fragments[name], fragments)
    end
    local reachable = {}
    for _, name in ipairs(names) do
        reachable[name] = reach(adj, name)
    end

    local cycles = {}
    local assigned = {}
    -- names are visited in byte order, so the first unassigned member of a
    -- component is its smallest name
    for _, v in ipairs(names) do
        if not assigned[v] and reachable[v][v] then
            local scc = {}
            for _, w in ipairs(names) do
                if w == v or (reachable[v][w] and reachable[w][v]) then
                    scc[w] = true
                    assigned[w] = true
                end
            end
            cycles[#cycles + 1] = shortest_cycle(adj, v, scc)
        end
    end
    return cycles
end

-- construction

-- Sentinel raised when the machine would exceed its state limit.
local TOO_LARGE = {}

--- new_builder returns an empty machine under construction.
--- @param max_states integer
--- @return table
local function new_builder(max_states, preds)
    return {
        max_states = max_states,
        preds = preds,
        count = 0,
        eps = {},
        geps = {},
        edges = {},
        accept = {},
    }
end

--- new_predicates returns an empty registry of predicates: list (id ->
--- { ast }) and index (lookahead body AST -> id).
--- @return table
local function new_predicates()
    return {
        list = {},
        index = {},
    }
end

--- intern returns the id of the predicate of the lookahead body ast,
--- registering it on first use.
--- @param preds table registry
--- @param ast table
--- @return integer
local function intern(preds, ast)
    local id = preds.index[ast]
    if not id then
        id = #preds.list + 1
        preds.list[id] = {
            ast = ast,
        }
        preds.index[ast] = id
    end
    return id
end

--- new_state allocates a state.
--- @param m table
--- @return integer
local function new_state(m)
    if m.count >= m.max_states then
        error(TOO_LARGE, 0)
    end
    m.count = m.count + 1
    return m.count
end

--- add_eps adds an epsilon edge.
--- @param m table
--- @param from integer
--- @param to integer
local function add_eps(m, from, to)
    local list = m.eps[from]
    if not list then
        list = {}
        m.eps[from] = list
    end
    list[#list + 1] = to
end

--- add_geps adds an epsilon edge guarded by the predicate pred having the
--- value value.
--- @param m table
--- @param from integer
--- @param to integer
--- @param pred integer
--- @param value boolean
local function add_geps(m, from, to, pred, value)
    local list = m.geps[from]
    if not list then
        list = {}
        m.geps[from] = list
    end
    list[#list + 1] = {
        to,
        pred,
        value,
    }
end

--- add_edge adds a byte-range edge.
--- @param m table
--- @param from integer
--- @param lo integer
--- @param hi integer
--- @param to integer
local function add_edge(m, from, lo, hi, to)
    local list = m.edges[from]
    if not list then
        list = {}
        m.edges[from] = list
    end
    list[#list + 1] = {
        lo,
        hi,
        to,
    }
end

--- add_chain connects from to to through one transition per position;
--- each position is an array of { lo, hi } ranges. There is at least one
--- position: literals are never empty and UTF-8 sequences have 1 to 4
--- bytes.
--- @param m table
--- @param from integer
--- @param to integer
--- @param positions table[]
local function add_chain(m, from, to, positions)
    local n = #positions
    local cur = from
    for i = 1, n do
        local nxt = to
        if i < n then
            nxt = new_state(m)
        end
        for _, range in ipairs(positions[i]) do
            add_edge(m, cur, range[1], range[2], nxt)
        end
        cur = nxt
    end
end

--- literal_positions returns the chain positions of the bytes of s. With
--- ignore_case, each ASCII letter matches both cases.
--- @param s string
--- @param ignore_case boolean?
--- @return table[]
local function literal_positions(s, ignore_case)
    local positions = {}
    for i = 1, #s do
        local b = byte(s, i)
        local ranges = {
            {
                b,
                b,
            },
        }
        if ignore_case and b >= 65 and b <= 90 then
            ranges[2] = {
                b + 32,
                b + 32,
            }
        elseif ignore_case and b >= 97 and b <= 122 then
            ranges[1] = {
                b - 32,
                b - 32,
            }
            ranges[2] = {
                b,
                b,
            }
        end
        positions[i] = ranges
    end
    return positions
end

--- add_class connects from to to through the members of a class node.
--- @param m table
--- @param from integer
--- @param to integer
--- @param node table class node
local function add_class(m, from, to, node)
    for _, range in ipairs(node.ranges) do
        if node.unit == 'byte' then
            add_edge(m, from, range[1], range[2], to)
        else
            for _, seq in ipairs(split_codepoints(range[1], range[2])) do
                local positions = {}
                for i, pair in ipairs(seq) do
                    positions[i] = {
                        pair,
                    }
                end
                add_chain(m, from, to, positions)
            end
        end
    end
end

--- in_chain returns true if name is in the linked list of fragments being
--- expanded.
--- @param chain table? { name, parent }
--- @param name string
--- @return boolean
local function in_chain(chain, name)
    while chain do
        if chain.name == name then
            return true
        end
        chain = chain.parent
    end
    return false
end

--- compile_task builds one task { node, from, to, chain } and pushes the
--- tasks of its children onto stack.
--- @param m table
--- @param task table
--- @param stack table
--- @param fragments table
local function compile_task(m, task, stack, fragments)
    local node, from, to, chain = task[1], task[2], task[3], task[4]
    local t = node.type
    if t == 'literal' then
        add_chain(m, from, to, literal_positions(node.value))
    elseif t == 'class' then
        add_class(m, from, to, node)
    elseif t == 'seq' then
        local items = node.items
        local cur = from
        for i = 1, #items do
            local nxt = to
            if i < #items then
                nxt = new_state(m)
            end
            stack[#stack + 1] = {
                items[i],
                cur,
                nxt,
                chain,
            }
            cur = nxt
        end
    elseif t == 'choice' then
        for _, item in ipairs(node.items) do
            local s, e = new_state(m), new_state(m)
            add_eps(m, from, s)
            add_eps(m, e, to)
            stack[#stack + 1] = {
                item,
                s,
                e,
                chain,
            }
        end
    elseif t == 'opt' then
        add_eps(m, from, to)
        stack[#stack + 1] = {
            node.item,
            from,
            to,
            chain,
        }
    elseif t == 'star' or t == 'plus' then
        -- the loop uses fresh states so that no edge enters from or leaves
        -- to from inside the construction
        local s, e = new_state(m), new_state(m)
        add_eps(m, from, s)
        add_eps(m, e, s)
        if t == 'star' then
            add_eps(m, s, to)
        else
            add_eps(m, e, to)
        end
        stack[#stack + 1] = {
            node.item,
            s,
            e,
            chain,
        }
    elseif t == 'lookahead' then
        if not m.preds then
            error('lookahead without a predicate registry', 0)
        end
        add_geps(m, from, to, intern(m.preds, node.item), not node.negative)
    elseif t == 'ref' then
        local name = node.name
        local ast = fragments[name]
        if ast == nil then
            error('unknown fragment: ' .. name, 0)
        elseif in_chain(chain, name) then
            error('fragment cycle through ' .. name, 0)
        end
        stack[#stack + 1] = {
            ast,
            from,
            to,
            {
                name = name,
                parent = chain,
            },
        }
    else
        error('unsupported node type: ' .. tostring(t), 0)
    end
end

--- compile_ast connects from to to through the automaton of ast.
--- @param m table
--- @param ast table
--- @param from integer
--- @param to integer
--- @param fragments table
local function compile_ast(m, ast, from, to, fragments)
    local stack = {
        {
            ast,
            from,
            to,
        },
    }
    while #stack > 0 do
        local task = stack[#stack]
        stack[#stack] = nil
        compile_task(m, task, stack, fragments)
    end
end

--- build_machine builds the machine; it raises TOO_LARGE or a message.
--- @param defs table[]
--- @param fragments table
--- @param max_states integer
--- @param preds table? predicate registry
--- @return table machine
local function build_machine(defs, fragments, max_states, preds)
    local m = new_builder(max_states, preds)
    m.start = new_state(m)
    for _, def in ipairs(defs) do
        local s, acc = new_state(m), new_state(m)
        add_eps(m, m.start, s)
        m.accept[acc] = def.id
        if def.literal ~= nil then
            add_chain(m, s, acc, literal_positions(def.literal, def.ignore_case))
        else
            compile_ast(m, def.ast, s, acc, fragments)
        end
    end
    m.max_states = nil
    m.preds = nil
    return m
end

--- build returns the combined automaton of defs. Each definition is either
--- { id, ast } or { id, literal, ignore_case }. Fragments are expanded
--- inline and must be acyclic. The lookaheads of the ASTs are registered in
--- preds, which is required when there are any.
--- @param defs table[]
--- @param fragments table fragment name -> AST
--- @param limits table? { max_states } for tests only; max_states defaults
--- to MAX_STATES
--- @param preds table? predicate registry (new_predicates)
--- @return table? machine { start, count, eps, geps, edges, accept }
--- @return table? err { code = 'automaton_too_large', message }
local function build(defs, fragments, limits, preds)
    local max_states = get_limit(limits, 'max_states', MAX_STATES)
    local ok, res = pcall(build_machine, defs, fragments or {}, max_states,
                          preds)
    if ok then
        return res
    elseif res == TOO_LARGE then
        return nil, {
            code = 'automaton_too_large',
            message = 'the automaton would have more than ' .. max_states ..
                ' states',
        }
    end
    error(res, 2)
end

--- build_predicate returns the machine of the body of the predicate id of
--- preds, whose accepting state has id 1; the lookaheads nested in it are
--- registered in preds.
--- @param id integer
--- @param preds table
--- @param fragments table
--- @param limits table?
--- @return table? machine
--- @return table? err
local function build_predicate(id, preds, fragments, limits)
    return build({
        {
            id = 1,
            ast = preds.list[id].ast,
        },
    }, fragments, limits, preds)
end

--- reverse returns the machine of the strings s whose some suffix is the
--- reverse of a string of machine (Σ* followed by the reverse): the edges
--- are reversed (a guarded edge keeps its guard, since a guard is checked
--- at a position between bytes, the same in both directions), a new start
--- state loops on every byte and enters the old accepting states, and the
--- old start state accepts with id 1. Read backward from the end of an
--- input, it accepts at position i when the input from i starts with a
--- string of machine.
--- @param machine table
--- @return table
local function reverse(machine)
    local m = {
        count = machine.count + 1,
        eps = {},
        geps = {},
        edges = {},
        accept = {},
    }
    local function append(list_of, from, item)
        local list = list_of[from]
        if not list then
            list = {}
            list_of[from] = list
        end
        list[#list + 1] = item
    end
    for from = 1, machine.count do
        for _, to in ipairs(machine.eps[from] or {}) do
            append(m.eps, to, from)
        end
        for _, g in ipairs(machine.geps[from] or {}) do
            append(m.geps, g[1], {
                from,
                g[2],
                g[3],
            })
        end
        for _, e in ipairs(machine.edges[from] or {}) do
            append(m.edges, e[3], {
                e[1],
                e[2],
                from,
            })
        end
    end
    local start = m.count
    m.start = start
    append(m.edges, start, {
        0,
        255,
        start,
    })
    for s = 1, machine.count do
        if machine.accept[s] ~= nil then
            append(m.eps, start, s)
        end
    end
    m.accept[machine.start] = 1
    return m
end

-- simulation

local holds

--- closure adds the epsilon closure of the states in list to set and list,
--- at position pos of the input s: a guarded edge is taken when its
--- predicate has its value there (pred_machines: id -> machine).
--- @param machine table
--- @param list integer[]
--- @param set table
--- @param s string
--- @param pos integer
--- @param pred_machines table?
local function closure(machine, list, set, s, pos, pred_machines)
    local stack = {}
    for i = 1, #list do
        stack[i] = list[i]
    end
    local function push(t)
        if not set[t] then
            set[t] = true
            list[#list + 1] = t
            stack[#stack + 1] = t
        end
    end
    while #stack > 0 do
        local st = stack[#stack]
        stack[#stack] = nil
        for _, t in ipairs(machine.eps[st] or {}) do
            push(t)
        end
        for _, g in ipairs(machine.geps[st] or {}) do
            if holds(pred_machines, g[2], s, pos) == g[3] then
                push(g[1])
            end
        end
    end
end

--- start_list returns the closure of the start state at position pos.
local function start_list(machine, s, pos, pred_machines)
    local list = {}
    list[1] = machine.start
    closure(machine, list, {
        [machine.start] = true,
    }, s, pos, pred_machines)
    return list
end

--- step returns the closure of the states reached from list by the byte at
--- position pos of s.
local function step(machine, list, s, pos, pred_machines)
    local b = byte(s, pos)
    local next_list, next_set = {}, {}
    for _, state in ipairs(list) do
        for _, edge in ipairs(machine.edges[state] or {}) do
            local to = edge[3]
            if b >= edge[1] and b <= edge[2] and not next_set[to] then
                next_set[to] = true
                next_list[#next_list + 1] = to
            end
        end
    end
    closure(machine, next_list, next_set, s, pos + 1, pred_machines)
    return next_list
end

--- holds returns whether the input s from position pos starts with a string
--- of the predicate id (whose machine is pred_machines[id]).
function holds(pred_machines, id, s, pos)
    local machine = pred_machines and pred_machines[id]
    if not machine then
        error('no machine for predicate ' .. tostring(id), 0)
    end
    local list = start_list(machine, s, pos, pred_machines)
    for i = pos, #s + 1 do
        for _, state in ipairs(list) do
            if machine.accept[state] then
                return true
            end
        end
        if i > #s or #list == 0 then
            return false
        end
        list = step(machine, list, s, i, pred_machines)
    end
end

--- accepts returns the sorted ids of the definitions whose accepting state
--- is reached after consuming the whole string s, where s is the whole
--- input (a lookahead sees the end of input after s). pred_machines maps
--- each predicate id to its machine, for machines with lookaheads.
--- @param machine table
--- @param s string
--- @param pred_machines table?
--- @return integer[]
local function accepts(machine, s, pred_machines)
    local list = start_list(machine, s, 1, pred_machines)
    for i = 1, #s do
        list = step(machine, list, s, i, pred_machines)
    end

    local ids, seen = {}, {}
    for _, state in ipairs(list) do
        local id = machine.accept[state]
        if id ~= nil and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    sort(ids)
    return ids
end

return {
    MAX_STATES = MAX_STATES,
    find_cycles = find_cycles,
    new_predicates = new_predicates,
    build = build,
    build_predicate = build_predicate,
    reverse = reverse,
    accepts = accepts,
    holds = holds,
}
