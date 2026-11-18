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
--
-- lexogram.compile.lookahead: the automata of the predicates of the
-- lookaheads of a grammar (see lexogram.compile.nfa) and the lookahead
-- aware reachability used by the diagnostics of the token automaton.
--
-- A predicate p holds at a position when the input from there starts with
-- a string of the lookahead body. Its forward automaton reads from the
-- position: it holds when an accepting state is reached, and does not when
-- the dead state (0) is. States from which no accepting state can be
-- reached are pruned to 0, so that a run stops as soon as the result is
-- known. The distance of a predicate is the largest number of bytes such a
-- run reads (including the runs of the predicates nested in it), or false
-- when it has no bound; such a predicate also has a backward automaton
-- (see lexogram.compile.nfa.reverse), which computes its value at every
-- position of an input in one pass from the end.
--
-- The reachability follows the token automaton from its start: a dispatch
-- state branches on the values of its predicates, each value becoming an
-- obligation on the input after that position (a predicate that must hold
-- tracks a state of its forward automaton that must reach acceptance; one
-- that must not, a state that must never reach it). An ordinary state is
-- reachable when some branch reaches it with obligations that some
-- continuation of the input satisfies.
local next = next
local ipairs = ipairs
local tonumber = tonumber
local floor = math.floor
local sort = table.sort
local concat = table.concat
local char = string.char
local nfa = require('lexogram.compile.nfa')
local dfa = require('lexogram.compile.dfa')

-- Rank of the only definition of a predicate automaton.
local RANK = {
    [1] = 1,
}

--- prune redirects the transitions and the dispatch targets of d that lead
--- to states from which no accepting state can be reached to the dead
--- state 0.
--- @param d table
local function prune(d)
    local n, nclasses, trans, accept = d.nstates, d.nclasses, d.trans, d.accept
    local dispatch = d.dispatch or {}
    local into = {}
    local function add(t, s)
        local list = into[t]
        if not list then
            list = {}
            into[t] = list
        end
        list[#list + 1] = s
    end
    for s = 1, n do
        local entry = dispatch[s]
        if entry then
            for _, t in ipairs(entry.targets) do
                if t ~= 0 then
                    add(t, s)
                end
            end
        else
            for c = 1, nclasses do
                local t = trans[(s - 1) * nclasses + c]
                if t ~= 0 then
                    add(t, s)
                end
            end
        end
    end
    local live, queue = {}, {}
    for s = 1, n do
        if accept[s] ~= 0 then
            live[s] = true
            queue[#queue + 1] = s
        end
    end
    local head = 1
    while queue[head] do
        for _, s in ipairs(into[queue[head]] or {}) do
            if not live[s] then
                live[s] = true
                queue[#queue + 1] = s
            end
        end
        head = head + 1
    end
    for s = 1, n do
        local entry = dispatch[s]
        if entry then
            for j, t in ipairs(entry.targets) do
                if not live[t] then
                    entry.targets[j] = 0
                end
            end
        else
            for c = 1, nclasses do
                local i = (s - 1) * nclasses + c
                if not live[trans[i]] then
                    trans[i] = 0
                end
            end
        end
    end
end

--- distance returns the largest number of bytes that a run of the pruned
--- forward automaton d reads before its result is known (an accepting or
--- the dead state), counting the distances of the predicates evaluated at
--- its dispatch states (list[p].distance), or false without a bound (a
--- cycle that can lead to acceptance, or a nested predicate without one).
--- @param d table
--- @param list table[] predicate id -> { distance }
--- @return integer|false
local function distance(d, list)
    local nclasses, trans, accept = d.nclasses, d.trans, d.accept
    local dispatch = d.dispatch or {}
    -- color: nil unvisited, 1 on the stack, 2 done; dist[s] when done
    local color, dist = {}, {}
    local function successors(s)
        local out = {}
        local entry = dispatch[s]
        if entry then
            for _, t in ipairs(entry.targets) do
                if t ~= 0 then
                    out[#out + 1] = t
                end
            end
        elseif accept[s] == 0 then
            for c = 1, nclasses do
                local t = trans[(s - 1) * nclasses + c]
                if t ~= 0 then
                    out[#out + 1] = t
                end
            end
        end
        return out
    end
    local stack = {
        {
            1,
            successors(1),
            1,
        },
    }
    color[1] = 1
    while #stack > 0 do
        local frame = stack[#stack]
        local s, kids, i = frame[1], frame[2], frame[3]
        local t = kids[i]
        if t then
            frame[3] = i + 1
            if color[t] == 1 then
                return false
            elseif not color[t] then
                color[t] = 1
                stack[#stack + 1] = {
                    t,
                    successors(t),
                    1,
                }
            end
        else
            stack[#stack] = nil
            color[s] = 2
            local value = 0
            local entry = dispatch[s]
            if entry then
                for _, p in ipairs(entry.preds) do
                    local inner = list[p].distance
                    if inner == false then
                        return false
                    end
                    value = inner > value and inner or value
                end
                for _, k in ipairs(kids) do
                    value = dist[k] > value and dist[k] or value
                end
            elseif accept[s] == 0 then
                for _, k in ipairs(kids) do
                    local v = dist[k] + 1
                    value = v > value and v or value
                end
            end
            dist[s] = value
        end
    end
    return dist[1]
end

--- build returns the automata of the predicates of preds (the registry of
--- lexogram.compile.nfa): list[id] = { forward, distance, backward }, or
--- nil and an automaton_too_large error.
--- @param preds table
--- @param fragments table
--- @param limits table { nfa, dfa }
--- @return table[]? list
--- @return table? err
local function build(preds, fragments, limits)
    local list, machines = {}, {}
    local id = 1
    while preds.list[id] do
        local machine, err = nfa.build_predicate(id, preds, fragments,
                                                 limits.nfa)
        if not machine then
            return nil, err
        end
        local d
        d, err = dfa.build(machine, RANK, limits.dfa)
        if not d then
            return nil, err
        end
        prune(d)
        machines[id] = machine
        list[id] = {
            forward = d,
        }
        id = id + 1
    end
    -- a nested predicate is registered after the one that contains it
    for p = #list, 1, -1 do
        local entry = list[p]
        entry.distance = distance(entry.forward, list)
        if entry.distance == false then
            local d, err = dfa.build(nfa.reverse(machines[p]), RANK, limits.dfa)
            if not d then
                return nil, err
            end
            entry.backward = d
        end
    end
    return list
end

-- reachability

--- obligation_key returns the key of the obligation that the forward
--- automaton of the predicate p reaches (or never reaches) acceptance from
--- its state s.
--- @param p integer
--- @param s integer
--- @return string
local function obligation_key(p, s)
    return p .. '.' .. s
end

--- split_key returns the predicate and the state of an obligation key.
--- @param key string
--- @return integer p
--- @return integer s
local function split_key(key)
    local dot = key:find('.', 1, true)
    return tonumber(key:sub(1, dot - 1)), tonumber(key:sub(dot + 1))
end

--- normalize resolves the dispatch states of the main state s (of d, or
--- nil for obligations only) and of the obligations pos (that must reach
--- acceptance) and neg (that must never reach it), and returns the
--- resulting branches { s, pos, neg }, whose states are ordinary: a
--- satisfied obligation is dropped, and a branch with a violated one is
--- dropped.
--- @param d table?
--- @param s integer?
--- @param pos table set of keys
--- @param neg table set of keys
--- @param list table[] predicates
--- @return table[] branches
local function normalize(d, s, pos, neg, list)
    local out = {}
    local work = {
        {
            s,
            pos,
            neg,
        },
    }
    while #work > 0 do
        local item = work[#work]
        work[#work] = nil
        local ms, mpos, mneg = item[1], item[2], item[3]
        -- find a dispatch to resolve, or a decided obligation
        local entry, kind, key
        local dead = false
        if ms and d.dispatch and d.dispatch[ms] then
            entry, kind = d.dispatch[ms], 'main'
        end
        if not entry then
            for k in next, mpos do
                local p, st = split_key(k)
                local f = list[p].forward
                if st == 0 then
                    dead = true
                    break
                elseif f.accept[st] ~= 0 then
                    entry, kind, key = true, 'done', k
                    break
                elseif f.dispatch and f.dispatch[st] then
                    entry, kind, key = f.dispatch[st], 'pos', k
                    break
                end
            end
        end
        if not entry and not dead then
            for k in next, mneg do
                local p, st = split_key(k)
                local f = list[p].forward
                if st == 0 then
                    entry, kind, key = true, 'drop', k
                    break
                elseif f.accept[st] ~= 0 then
                    dead = true
                    break
                elseif f.dispatch and f.dispatch[st] then
                    entry, kind, key = f.dispatch[st], 'neg', k
                    break
                end
            end
        end
        -- a violated obligation drops the branch
        if not dead then
            if not entry then
                out[#out + 1] = item
            elseif kind == 'done' or kind == 'drop' then
                local set = kind == 'done' and mpos or mneg
                local copy = {}
                for k in next, set do
                    if k ~= key then
                        copy[k] = true
                    end
                end
                if kind == 'done' then
                    work[#work + 1] = {
                        ms,
                        copy,
                        mneg,
                    }
                else
                    work[#work + 1] = {
                        ms,
                        mpos,
                        copy,
                    }
                end
            else
                local p
                if kind ~= 'main' then
                    p = split_key(key)
                end
                for v = 0, 2 ^ #entry.preds - 1 do
                    local npos, nneg = {}, {}
                    for k in next, mpos do
                        npos[k] = true
                    end
                    for k in next, mneg do
                        nneg[k] = true
                    end
                    for j, q in ipairs(entry.preds) do
                        local holds = floor(v / 2 ^ (j - 1)) % 2 == 1
                        if holds then
                            npos[obligation_key(q, 1)] = true
                        else
                            nneg[obligation_key(q, 1)] = true
                        end
                    end
                    local target = entry.targets[v + 1]
                    local ns = ms
                    if kind == 'main' then
                        ns = target
                    elseif kind == 'pos' then
                        npos[key] = nil
                        npos[obligation_key(p, target)] = true
                    else
                        nneg[key] = nil
                        nneg[obligation_key(p, target)] = true
                    end
                    if not (kind == 'main' and target == 0) then
                        work[#work + 1] = {
                            ns,
                            npos,
                            nneg,
                        }
                    end
                end
            end
        end
    end
    return out
end

--- set_key returns a deterministic key of a set of keys.
--- @param set table
--- @return string
local function set_key(set)
    local keys = {}
    for k in next, set do
        keys[#keys + 1] = k
    end
    sort(keys)
    return concat(keys, ',')
end

--- byte_groups returns, for the main state s of d (or nil) and the
--- obligations of pos and neg, one byte for each group of bytes that every
--- automaton involved treats the same way.
--- @param d table?
--- @param pos table
--- @param neg table
--- @param list table[]
--- @return integer[]
local function byte_groups(d, pos, neg, list)
    local automata = {}
    if d then
        automata[1] = d
    end
    for _, set in ipairs({
        pos,
        neg,
    }) do
        for k in next, set do
            local p = split_key(k)
            automata[#automata + 1] = list[p].forward
        end
    end
    local seen, out = {}, {}
    local sig = {}
    for b = 0, 255 do
        for i, a in ipairs(automata) do
            sig[i] = a.classes[b + 1]
        end
        local key = concat(sig, ',', 1, #automata)
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = b
        end
    end
    return out
end

--- advance returns the obligations of set after the byte b.
--- @param set table
--- @param b integer
--- @param list table[]
--- @return table
local function advance(set, b, list)
    local out = {}
    for k in next, set do
        local p, st = split_key(k)
        local f = list[p].forward
        out[obligation_key(p, f.trans[(st - 1) * f.nclasses + f.classes[b + 1]])] =
            true
    end
    return out
end

--- satisfiable returns whether some continuation of the input satisfies
--- the obligations pos and neg (ordinary states), or nil when the search
--- would visit more than max configurations.
--- @param pos table
--- @param neg table
--- @param list table[]
--- @param max integer
--- @param memo table
--- @return boolean?
local function satisfiable(pos, neg, list, max, memo)
    local start = set_key(pos) .. '|' .. set_key(neg)
    if memo[start] ~= nil then
        return memo[start]
    end
    local seen = {
        [start] = true,
    }
    local queue = {
        {
            pos,
            neg,
        },
    }
    local count, head = 1, 1
    local result = false
    while queue[head] do
        local item = queue[head]
        head = head + 1
        if next(item[1]) == nil then
            -- the input may end here: no obligation must still be met
            result = true
            break
        end
        for _, b in ipairs(byte_groups(nil, item[1], item[2], list)) do
            local branches = normalize(nil, nil, advance(item[1], b, list),
                                       advance(item[2], b, list), list)
            for _, branch in ipairs(branches) do
                local key = set_key(branch[2]) .. '|' .. set_key(branch[3])
                if not seen[key] then
                    seen[key] = true
                    count = count + 1
                    if count > max then
                        return nil
                    end
                    queue[#queue + 1] = {
                        branch[2],
                        branch[3],
                    }
                end
            end
        end
    end
    memo[start] = result
    return result
end

--- reachable returns, for each ordinary state of d that some input can
--- reach with the predicates of its dispatch states consistent with that
--- input, the shortest such string (as a byte string), or nil and an
--- automaton_too_large error.
--- @param d table token automaton with dispatch states
--- @param list table[] predicates (result of build)
--- @param max integer largest number of configurations
--- @return table? state -> example string
--- @return table? err
local function reachable(d, list, max)
    local found = {}
    local memo = {}
    local too_large = {
        code = 'automaton_too_large',
        message = 'the analysis of the lookaheads would visit more than ' .. max ..
            ' configurations',
    }
    local seen, queue = {}, {}
    local count = 0
    local function push(branches, path)
        for _, branch in ipairs(branches) do
            local key = branch[1] .. '|' .. set_key(branch[2]) .. '|' ..
                            set_key(branch[3])
            if not seen[key] then
                seen[key] = true
                count = count + 1
                if count > max then
                    return false
                end
                queue[#queue + 1] = {
                    branch[1],
                    branch[2],
                    branch[3],
                    path,
                }
            end
        end
        return true
    end
    if not push(normalize(d, 1, {}, {}, list), '') then
        return nil, too_large
    end
    local head = 1
    while queue[head] do
        local item = queue[head]
        head = head + 1
        local s, pos, neg, path = item[1], item[2], item[3], item[4]
        local ok = satisfiable(pos, neg, list, max, memo)
        if ok == nil then
            return nil, too_large
        elseif ok then
            if found[s] == nil then
                found[s] = path
            end
            for _, b in ipairs(byte_groups(d, pos, neg, list)) do
                local t = d.trans[(s - 1) * d.nclasses + d.classes[b + 1]]
                if t ~= 0 then
                    local branches = normalize(d, t, advance(pos, b, list),
                                               advance(neg, b, list), list)
                    if not push(branches, path .. char(b)) then
                        return nil, too_large
                    end
                end
            end
        end
    end
    return found
end

return {
    build = build,
    reachable = reachable,
}
