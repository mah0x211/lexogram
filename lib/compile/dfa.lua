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
-- lexogram.compile.dfa: turns the combined automaton of lexogram.compile.nfa
-- into a minimal deterministic automaton over byte equivalence classes,
-- with flat transition arrays for the runtime and the accept information
-- needed for longest match and conflict diagnosis. Every traversal is
-- iterative.
local ipairs = ipairs
local concat = table.concat
local sort = table.sort
local byte = string.byte

-- Largest number of DFA states built by the subset construction. Some
-- patterns (e.g. ("a" | "b")* "a" ("a" | "b") ... ) need exponentially many
-- states; the limit stops such a construction early.
local MAX_STATES = 50000

--- byte_classes splits the bytes 0..255 into classes at every edge
--- boundary of the machine, so that each edge covers whole classes.
--- @param machine table
--- @return integer[] class_of byte + 1 -> class
--- @return integer nclasses
local function byte_classes(machine)
    local boundary = {}
    for s = 1, machine.count do
        for _, edge in ipairs(machine.edges[s] or {}) do
            boundary[edge[1]] = true
            boundary[edge[2] + 1] = true
        end
    end
    local class_of = {}
    local n = 0
    for b = 0, 255 do
        if b == 0 or boundary[b] then
            n = n + 1
        end
        class_of[b + 1] = n
    end
    return class_of, n
end

--- closure returns the sorted epsilon closure of the states in list.
--- @param machine table
--- @param list integer[] distinct states; extended in place
--- @return integer[]
local function closure(machine, list)
    local seen, stack = {}, {}
    for i, s in ipairs(list) do
        seen[s] = true
        stack[i] = s
    end
    while #stack > 0 do
        local s = stack[#stack]
        stack[#stack] = nil
        for _, t in ipairs(machine.eps[s] or {}) do
            if not seen[t] then
                seen[t] = true
                list[#list + 1] = t
                stack[#stack + 1] = t
            end
        end
    end
    sort(list)
    return list
end

--- accept_ids returns the sorted distinct ids accepted by the NFA states
--- in set.
--- @param machine table
--- @param set integer[]
--- @return integer[]
local function accept_ids(machine, set)
    local ids, seen = {}, {}
    for _, s in ipairs(set) do
        local id = machine.accept[s]
        if id ~= nil and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    sort(ids)
    return ids
end

--- moves returns, for each class, the distinct NFA states reached from set
--- by one byte of that class (classes without a target are absent).
--- @param machine table
--- @param set integer[]
--- @param class_of integer[]
--- @return table class -> integer[]
local function moves(machine, set, class_of)
    local buckets, seen = {}, {}
    for _, s in ipairs(set) do
        for _, edge in ipairs(machine.edges[s] or {}) do
            local to = edge[3]
            for c = class_of[edge[1] + 1], class_of[edge[2] + 1] do
                local bucket = buckets[c]
                if not bucket then
                    bucket = {}
                    buckets[c] = bucket
                    seen[c] = {}
                end
                if not seen[c][to] then
                    seen[c][to] = true
                    bucket[#bucket + 1] = to
                end
            end
        end
    end
    return buckets
end

--- subset_construction builds the DFA over classes. States are numbered
--- in discovery order (start = 1); the dead state is 0.
--- @param machine table
--- @param class_of integer[]
--- @param nclasses integer
--- @return table? dfa { n, trans (state -> class -> state), sets }
local function subset_construction(machine, class_of, nclasses)
    local initial = {}
    initial[1] = machine.start
    local start = closure(machine, initial)
    local index = {
        [concat(start, ',')] = 1,
    }
    local sets = {
        start,
    }
    local trans = {}
    local head = 1
    while sets[head] do
        local row = {}
        local buckets = moves(machine, sets[head], class_of)
        for c = 1, nclasses do
            local target = 0
            if buckets[c] then
                local set = closure(machine, buckets[c])
                local key = concat(set, ',')
                target = index[key]
                if not target then
                    if #sets >= MAX_STATES then
                        return nil
                    end
                    sets[#sets + 1] = set
                    target = #sets
                    index[key] = target
                end
            end
            row[c] = target
        end
        trans[head] = row
        head = head + 1
    end
    return {
        n = #sets,
        trans = trans,
        sets = sets,
    }
end

--- minimize partitions the states with Moore's algorithm, starting from
--- the partition by accept set. Each round assigns every state a block by
--- its current block and the blocks of its targets; it stops when a round
--- does not split any block. Blocks are numbered by first appearance in
--- state order, so the result is deterministic. Complexity: O(n * k) per
--- round for n states and k classes, at most n rounds (O(n^2 * k) in the
--- worst case; few rounds in practice).
--- @param n integer
--- @param trans table state -> class -> state
--- @param keys string[] accept set key of each state
--- @param nclasses integer
--- @return integer[] block state -> block
--- @return integer nblocks
local function minimize(n, trans, keys, nclasses)
    local block, nblocks = {}, 0
    local index = {}
    for s = 1, n do
        local b = index[keys[s]]
        if not b then
            nblocks = nblocks + 1
            b = nblocks
            index[keys[s]] = b
        end
        block[s] = b
    end

    while true do
        local next_block, count = {}, 0
        index = {}
        local sig = {}
        for s = 1, n do
            sig[1] = block[s]
            local row = trans[s]
            for c = 1, nclasses do
                local t = row[c]
                sig[c + 1] = t == 0 and 0 or block[t]
            end
            local key = concat(sig, ',')
            local b = index[key]
            if not b then
                count = count + 1
                b = count
                index[key] = b
            end
            next_block[s] = b
        end
        block = next_block
        if count == nblocks then
            return block, nblocks
        end
        nblocks = count
    end
end

--- renumber orders the blocks breadth-first from the start block, visiting
--- classes in ascending order, and returns the minimized transition table.
--- @param raw table result of subset_construction
--- @param block integer[]
--- @param nclasses integer
--- @return table rows new state -> class -> new state
--- @return integer[] members new state -> a raw state of that block
local function renumber(raw, block, nclasses)
    -- a representative raw state of each block
    local rep = {}
    for s = raw.n, 1, -1 do
        rep[block[s]] = s
    end
    local number = {
        [block[1]] = 1,
    }
    local members = {
        1,
    }
    local rows = {}
    local head = 1
    while members[head] do
        local row = {}
        local raw_row = raw.trans[members[head]]
        for c = 1, nclasses do
            local t = raw_row[c]
            local target = 0
            if t ~= 0 then
                local b = block[t]
                target = number[b]
                if not target then
                    members[#members + 1] = rep[b]
                    target = #members
                    number[b] = target
                end
            end
            row[c] = target
        end
        rows[head] = row
        head = head + 1
    end
    return rows, members
end

--- merge_classes merges classes whose columns are identical in rows and
--- numbers the merged classes by their smallest byte.
--- @param rows table state -> class -> state
--- @param class_of integer[]
--- @param nclasses integer
--- @return integer[] classes byte + 1 -> merged class
--- @return integer[] first merged class -> an original class
local function merge_classes(rows, class_of, nclasses)
    local column_key = {}
    local col = {}
    for c = 1, nclasses do
        for s = 1, #rows do
            col[s] = rows[s][c]
        end
        column_key[c] = concat(col, ',')
    end
    local merged, first, index = {}, {}, {}
    local classes = {}
    for b = 0, 255 do
        local c = class_of[b + 1]
        local m = merged[c]
        if not m then
            m = index[column_key[c]]
            if not m then
                first[#first + 1] = c
                m = #first
                index[column_key[c]] = m
            end
            merged[c] = m
        end
        classes[b + 1] = m
    end
    return classes, first
end

--- resolve returns the winner of an accept set and, if several ids share
--- the lowest rank, those ids. The winner is then the smallest of them.
--- @param ids integer[] sorted
--- @param rank table id -> rank
--- @return integer winner (0 when ids is empty)
--- @return integer[]? tied
local function resolve(ids, rank)
    local best, tied = nil, {}
    for _, id in ipairs(ids) do
        local r = rank[id]
        if best == nil or r < best then
            best = r
            tied = {
                id,
            }
        elseif r == best then
            tied[#tied + 1] = id
        end
    end
    if best == nil then
        return 0, nil
    elseif #tied > 1 then
        return tied[1], tied
    end
    return tied[1], nil
end

--- build returns the minimal DFA of machine. rank maps each definition id
--- to a positive integer; on equal match length the lowest rank wins. When
--- several ids share the lowest rank in a state, the state is listed in
--- conflicts and accept holds the smallest of those ids.
--- @param machine table result of nfa.build
--- @param rank table id -> rank
--- @return table? d { nstates, nclasses, classes, trans, accept,
--- accept_sets, conflicts }
--- @return table? err { code = 'automaton_too_large', message }
local function build(machine, rank)
    local class_of, nclasses = byte_classes(machine)
    local raw = subset_construction(machine, class_of, nclasses)
    if not raw then
        return nil, {
            code = 'automaton_too_large',
            message = 'the deterministic automaton would have more than ' ..
                MAX_STATES .. ' states',
        }
    end

    local sets_ids, keys = {}, {}
    for s = 1, raw.n do
        sets_ids[s] = accept_ids(machine, raw.sets[s])
        keys[s] = concat(sets_ids[s], ',')
    end
    local block = minimize(raw.n, raw.trans, keys, nclasses)
    local rows, members = renumber(raw, block, nclasses)
    local classes, first = merge_classes(rows, class_of, nclasses)

    local nstates, nmerged = #rows, #first
    local trans, accept, accept_sets, conflicts = {}, {}, {}, {}
    for s = 1, nstates do
        local row = rows[s]
        for m = 1, nmerged do
            trans[(s - 1) * nmerged + m] = row[first[m]]
        end
        local ids = sets_ids[members[s]]
        accept_sets[s] = ids
        local winner, tied = resolve(ids, rank)
        accept[s] = winner
        if tied then
            conflicts[#conflicts + 1] = {
                state = s,
                ids = tied,
            }
        end
    end
    return {
        nstates = nstates,
        nclasses = nmerged,
        classes = classes,
        trans = trans,
        accept = accept,
        accept_sets = accept_sets,
        conflicts = conflicts,
    }
end

--- run returns the state after consuming the whole string str from state
--- 1, or 0 if the dead state is reached.
--- @param d table
--- @param str string
--- @return integer
local function run(d, str)
    local s, nclasses, classes, trans = 1, d.nclasses, d.classes, d.trans
    for i = 1, #str do
        s = trans[(s - 1) * nclasses + classes[byte(str, i) + 1]]
        if s == 0 then
            return 0
        end
    end
    return s
end

--- longest returns the winning id of the longest non-empty prefix of str
--- starting at pos that is accepted, and the position just after it, or
--- nil if there is none. An accepting start state (empty match) is
--- ignored.
--- @param d table
--- @param str string
--- @param pos integer
--- @return integer? id
--- @return integer? stop
local function longest(d, str, pos)
    local s, nclasses, classes, trans = 1, d.nclasses, d.classes, d.trans
    local accept = d.accept
    local id, stop
    for i = pos, #str do
        s = trans[(s - 1) * nclasses + classes[byte(str, i) + 1]]
        if s == 0 then
            break
        elseif accept[s] ~= 0 then
            id, stop = accept[s], i + 1
        end
    end
    return id, stop
end

return {
    build = build,
    run = run,
    longest = longest,
}
