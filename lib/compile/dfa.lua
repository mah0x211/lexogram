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
--
-- Guarded epsilon edges (lookaheads) are resolved at compile time: a set
-- of NFA states from which guarded edges are reachable becomes a dispatch
-- state, which consumes nothing and selects, by the values of those
-- predicates at the current position, one of its targets: the closure
-- under that valuation, an ordinary state. dispatch[s] = { preds, targets }
-- (targets[v + 1] for the valuation v, whose bit j - 1 is the value of
-- preds[j]); a dispatch state has no transitions and accepts nothing. The
-- runtime only evaluates the predicates.
local ipairs = ipairs
local next = next
local floor = math.floor
local concat = table.concat
local sort = table.sort
local byte = string.byte
local get_limit = require('lexogram.compile.limits').get

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

--- guards_of returns the sorted distinct predicates of the guarded edges
--- reachable from set through epsilon and guarded edges.
--- @param machine table
--- @param set integer[] closed under epsilon edges
--- @return integer[]
local function guards_of(machine, set)
    local geps = machine.geps
    if not geps or next(geps) == nil then
        return {}
    end
    local seen, stack, preds, found = {}, {}, {}, {}
    for i, s in ipairs(set) do
        seen[s] = true
        stack[i] = s
    end
    while #stack > 0 do
        local s = stack[#stack]
        stack[#stack] = nil
        for _, t in ipairs(machine.eps[s] or {}) do
            if not seen[t] then
                seen[t] = true
                stack[#stack + 1] = t
            end
        end
        for _, g in ipairs(geps[s] or {}) do
            if not found[g[2]] then
                found[g[2]] = true
                preds[#preds + 1] = g[2]
            end
            if not seen[g[1]] then
                seen[g[1]] = true
                stack[#stack + 1] = g[1]
            end
        end
    end
    sort(preds)
    return preds
end

--- guarded_closure returns the sorted closure of set through epsilon edges
--- and the guarded edges whose predicate has its value in the valuation v
--- of preds (bit j - 1 of v is the value of preds[j]).
--- @param machine table
--- @param set integer[]
--- @param preds integer[]
--- @param v integer
--- @return integer[]
local function guarded_closure(machine, set, preds, v)
    local value = {}
    for j, p in ipairs(preds) do
        value[p] = floor(v / 2 ^ (j - 1)) % 2 == 1
    end
    local list, seen, stack = {}, {}, {}
    for i, s in ipairs(set) do
        seen[s] = true
        list[i] = s
        stack[i] = s
    end
    local geps = machine.geps
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
        for _, g in ipairs(geps[s] or {}) do
            if value[g[2]] == g[3] and not seen[g[1]] then
                seen[g[1]] = true
                list[#list + 1] = g[1]
                stack[#stack + 1] = g[1]
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
--- in discovery order (start = 1); the dead state is 0. A set from which
--- guarded edges are reachable becomes a dispatch state (see above).
--- @param machine table
--- @param class_of integer[]
--- @param nclasses integer
--- @param max_states integer
--- @return table? dfa { n, trans (state -> class -> state), sets, dispatch
--- (state -> { preds, targets }) }
local function subset_construction(machine, class_of, nclasses, max_states)
    local index, sets, dispatch = {}, {}, {}
    local full = false

    -- intern returns the state of the ordinary set (closed under the edges
    -- it takes), or nil when the limit is reached
    local function intern(set)
        local key = concat(set, ',')
        local s = index[key]
        if not s then
            if #sets >= max_states then
                full = true
                return nil
            end
            sets[#sets + 1] = set
            s = #sets
            index[key] = s
        end
        return s
    end

    -- intern_pre returns the state of the set reached by consuming bytes
    -- (closed under epsilon edges only): a dispatch state when guarded
    -- edges are reachable from it
    local function intern_pre(set)
        local preds = guards_of(machine, set)
        if #preds == 0 then
            return intern(set)
        end
        local key = 'D' .. concat(set, ',')
        local s = index[key]
        if not s then
            if #sets >= max_states then
                full = true
                return nil
            end
            sets[#sets + 1] = set
            s = #sets
            index[key] = s
            dispatch[s] = {
                preds = preds,
            }
        end
        return s
    end

    -- the state that each set of NFA states reached by a byte leads to, by
    -- the key of the set: many classes of a state reach the same set, whose
    -- closure is computed once
    local reached = {}

    local initial = {}
    initial[1] = machine.start
    -- the start state always fits: max_states is at least 1
    intern_pre(closure(machine, initial))
    local trans = {}
    local head = 1
    while sets[head] do
        local row = {}
        local d = dispatch[head]
        if d then
            local targets = {}
            for v = 0, 2 ^ #d.preds - 1 do
                targets[v + 1] = intern(guarded_closure(machine, sets[head],
                                                        d.preds, v))
                if full then
                    return nil
                end
            end
            d.targets = targets
            for c = 1, nclasses do
                row[c] = 0
            end
        else
            local buckets = moves(machine, sets[head], class_of)
            for c = 1, nclasses do
                local target = 0
                local bucket = buckets[c]
                if bucket then
                    sort(bucket)
                    local key = concat(bucket, ',')
                    target = reached[key]
                    if not target then
                        target = intern_pre(closure(machine, bucket))
                        if full then
                            return nil
                        end
                        reached[key] = target
                    end
                end
                row[c] = target
            end
        end
        trans[head] = row
        head = head + 1
    end
    return {
        n = #sets,
        trans = trans,
        sets = sets,
        dispatch = dispatch,
    }
end

--- minimize partitions the states with Hopcroft's algorithm, starting from
--- the partition by key (the accept set, or the predicates of a dispatch
--- state): it splits the blocks by the predecessors of a block on one
--- symbol until no block splits, keeping only the smaller half of a split
--- to split by. The symbols are the byte classes and, for a dispatch state,
--- the indexes of its targets; a missing transition, or one to the dead
--- state 0, goes to a dead state of its own block. The coarsest partition
--- is unique, so the result is the same as that of the rounds of Moore's
--- algorithm; blocks are numbered by first appearance in state order, so
--- it is deterministic. Complexity: O(n * k * log n) for n states and k
--- symbols.
--- @param n integer
--- @param trans table state -> class -> state
--- @param keys string[] initial key of each state
--- @param nclasses integer
--- @param dispatch table state -> { preds, targets }
--- @return integer[] block state -> block
--- @return integer nblocks
local function minimize(n, trans, keys, nclasses, dispatch)
    local dead = n + 1
    local nsym = nclasses
    for _, d in next, dispatch do
        if nclasses + #d.targets > nsym then
            nsym = nclasses + #d.targets
        end
    end

    -- the predecessors of each state on each symbol, as linked lists:
    -- head[(a - 1) * dead + t] is the first edge to t on a
    local head, link, from = {}, {}, {}
    local nedges = 0
    for s = 1, n do
        local d = dispatch[s]
        local row, targets = trans[s], d and d.targets
        for a = 1, nsym do
            local t
            if targets then
                t = a > nclasses and targets[a - nclasses] or 0
            else
                t = a <= nclasses and row[a] or 0
            end
            if not t or t == 0 then
                t = dead
            end
            nedges = nedges + 1
            local h = (a - 1) * dead + t
            from[nedges], link[nedges] = s, head[h]
            head[h] = nedges
        end
    end
    -- the dead state goes to itself on every symbol
    for a = 1, nsym do
        nedges = nedges + 1
        local h = (a - 1) * dead + dead
        from[nedges], link[nedges] = dead, head[h]
        head[h] = nedges
    end

    -- blocks are ranges of elems: block b is elems[first[b] .. first[b] +
    -- size[b] - 1]; place[s] is the index of s in elems
    local elems, place, block_of, first, size = {}, {}, {}, {}, {}
    local nblocks = 0
    local index, members = {}, {}
    for s = 1, n do
        local b = index[keys[s]]
        if not b then
            nblocks = nblocks + 1
            b = nblocks
            index[keys[s]] = b
            members[b] = {}
        end
        local list = members[b]
        list[#list + 1] = s
    end
    nblocks = nblocks + 1
    members[nblocks] = {
        dead,
    }
    local at = 0
    for b = 1, nblocks do
        first[b], size[b] = at + 1, #members[b]
        for _, s in ipairs(members[b]) do
            at = at + 1
            elems[at], place[s], block_of[s] = s, at, b
        end
    end

    -- the splitters (block, symbol) to process, and which are pending
    local wblock, wsym, wtop = {}, {}, 0
    local pending = {}
    local function push(b, a)
        wtop = wtop + 1
        wblock[wtop], wsym[wtop] = b, a
        pending[(b - 1) * nsym + a] = true
    end
    for b = 1, nblocks do
        for a = 1, nsym do
            push(b, a)
        end
    end

    local marked, touched, splitter = {}, {}, {}
    while wtop > 0 do
        local b, a = wblock[wtop], wsym[wtop]
        wtop = wtop - 1
        pending[(b - 1) * nsym + a] = nil
        -- the members of b first: marking moves states inside their blocks,
        -- b among them
        local count = size[b]
        for i = 1, count do
            splitter[i] = elems[first[b] + i - 1]
        end
        -- mark the predecessors on a by moving them to the front of their
        -- blocks (a state has one target on a, so it is marked once)
        local ntouched = 0
        local base = (a - 1) * dead
        for i = 1, count do
            local e = head[base + splitter[i]]
            while e do
                local s = from[e]
                local y = block_of[s]
                local m = marked[y]
                if not m then
                    m = 0
                    ntouched = ntouched + 1
                    touched[ntouched] = y
                end
                local p, q = place[s], first[y] + m
                local other = elems[q]
                elems[q], place[s] = s, q
                elems[p], place[other] = other, p
                marked[y] = m + 1
                e = link[e]
            end
        end
        -- split each block that has marked and unmarked states: the marked
        -- ones become a new block
        for j = 1, ntouched do
            local y = touched[j]
            local m = marked[y]
            marked[y] = nil
            if m < size[y] then
                nblocks = nblocks + 1
                local z = nblocks
                first[z], size[z] = first[y], m
                first[y], size[y] = first[y] + m, size[y] - m
                for i = first[z], first[z] + m - 1 do
                    block_of[elems[i]] = z
                end
                for c = 1, nsym do
                    if pending[(y - 1) * nsym + c] then
                        push(z, c)
                    elseif size[z] <= size[y] then
                        push(z, c)
                    else
                        push(y, c)
                    end
                end
            end
        end
    end

    -- number the blocks by first appearance in state order
    local block, number, count = {}, {}, 0
    for s = 1, n do
        local b = block_of[s]
        local r = number[b]
        if not r then
            count = count + 1
            r = count
            number[b] = r
        end
        block[s] = r
    end
    return block, count
end

--- renumber orders the blocks breadth-first from the start block, visiting
--- classes in ascending order (the targets of a dispatch state in
--- valuation order), and returns the minimized transition table.
--- @param raw table result of subset_construction
--- @param block integer[]
--- @param nclasses integer
--- @return table rows new state -> class -> new state
--- @return integer[] members new state -> a raw state of that block
--- @return table dispatch new state -> { preds, targets }
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
    local rows, dispatch = {}, {}
    local function number_of(t)
        local b = block[t]
        local target = number[b]
        if not target then
            members[#members + 1] = rep[b]
            target = #members
            number[b] = target
        end
        return target
    end
    local head = 1
    while members[head] do
        local row = {}
        local raw_row = raw.trans[members[head]]
        local d = raw.dispatch[members[head]]
        if d then
            local targets = {}
            for j, t in ipairs(d.targets) do
                targets[j] = number_of(t)
            end
            local preds = {}
            for j, p in ipairs(d.preds) do
                preds[j] = p
            end
            dispatch[head] = {
                preds = preds,
                targets = targets,
            }
        end
        for c = 1, nclasses do
            local t = raw_row[c]
            row[c] = t == 0 and 0 or number_of(t)
        end
        rows[head] = row
        head = head + 1
    end
    return rows, members, dispatch
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
--- @param limits table? { max_states } for tests only; max_states defaults
--- to MAX_STATES
--- @return table? d { nstates, nclasses, classes, trans, accept,
--- accept_sets, conflicts, dispatch } (dispatch only with guarded edges)
--- @return table? err { code = 'automaton_too_large', message }
local function build(machine, rank, limits)
    local max_states = get_limit(limits, 'max_states', MAX_STATES)
    local class_of, nclasses = byte_classes(machine)
    local raw = subset_construction(machine, class_of, nclasses, max_states)
    if not raw then
        return nil, {
            code = 'automaton_too_large',
            message = 'the deterministic automaton would have more than ' ..
                max_states .. ' states',
        }
    end

    local sets_ids, keys = {}, {}
    for s = 1, raw.n do
        local d = raw.dispatch[s]
        if d then
            sets_ids[s] = {}
            keys[s] = 'D' .. concat(d.preds, ',')
        else
            sets_ids[s] = accept_ids(machine, raw.sets[s])
            keys[s] = 'A' .. concat(sets_ids[s], ',')
        end
    end
    local block = minimize(raw.n, raw.trans, keys, nclasses, raw.dispatch)
    local rows, members, dispatch = renumber(raw, block, nclasses)
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
        dispatch = next(dispatch) ~= nil and dispatch or nil,
    }
end

--- intersect returns the product of the automata of list (results of
--- build without dispatch states): an automaton of the same shape that
--- accepts a string, with accept 1, when every automaton of list accepts
--- it. Only the state tuples reachable from the start are built.
--- @param list table[]
--- @param limits table? { max_states }; max_states defaults to MAX_STATES
--- @return table? d { nstates, nclasses, classes, trans, accept }
--- @return table? err automaton_too_large
local function intersect(list, limits)
    local max_states = get_limit(limits, 'max_states', MAX_STATES)
    local n = #list
    -- a class of the product for each distinct tuple of classes of a byte
    local classes, reps, index = {}, {}, {}
    local nclasses = 0
    for b = 1, 256 do
        local parts = {}
        for i = 1, n do
            parts[i] = list[i].classes[b]
        end
        local key = concat(parts, ',')
        local c = index[key]
        if not c then
            nclasses = nclasses + 1
            c = nclasses
            index[key] = c
            reps[c] = parts
        end
        classes[b] = c
    end

    local tuples, states, trans, accept = {}, {}, {}, {}
    local start = {}
    for i = 1, n do
        start[i] = 1
    end
    tuples[1] = start
    states[concat(start, ',')] = 1
    local head = 1
    while tuples[head] do
        local t = tuples[head]
        local accepts = 1
        for i = 1, n do
            if list[i].accept[t[i]] == 0 then
                accepts = 0
                break
            end
        end
        accept[head] = accepts
        for c = 1, nclasses do
            local next_tuple = {}
            for i = 1, n do
                local d = list[i]
                local x = d.trans[(t[i] - 1) * d.nclasses + reps[c][i]]
                if x == 0 then
                    next_tuple = nil
                    break
                end
                next_tuple[i] = x
            end
            local target = 0
            if next_tuple then
                local key = concat(next_tuple, ',')
                target = states[key]
                if not target then
                    if #tuples >= max_states then
                        return nil, {
                            code = 'automaton_too_large',
                            message = 'the deterministic automaton would' ..
                                ' have more than ' .. max_states .. ' states',
                        }
                    end
                    tuples[#tuples + 1] = next_tuple
                    target = #tuples
                    states[key] = target
                end
            end
            trans[(head - 1) * nclasses + c] = target
        end
        head = head + 1
    end
    return {
        nstates = #tuples,
        nclasses = nclasses,
        classes = classes,
        trans = trans,
        accept = accept,
    }
end

--- resolve_dispatch returns s, or the target of the dispatch state s for
--- the values that valuate(preds, pos) gives (the valuation number).
--- @param d table
--- @param s integer
--- @param pos integer
--- @param valuate function?
--- @return integer
local function resolve_dispatch(d, s, pos, valuate)
    local dispatch = d.dispatch
    local entry = dispatch and dispatch[s]
    if entry then
        return entry.targets[valuate(entry.preds, pos) + 1]
    end
    return s
end

--- run returns the state after consuming the whole string str from state
--- 1, or 0 if the dead state is reached. valuate(preds, pos) gives the
--- valuation of the predicates of a dispatch state at a position.
--- @param d table
--- @param str string
--- @param valuate function?
--- @return integer
local function run(d, str, valuate)
    local nclasses, classes, trans = d.nclasses, d.classes, d.trans
    local s = resolve_dispatch(d, 1, 1, valuate)
    for i = 1, #str do
        s = trans[(s - 1) * nclasses + classes[byte(str, i) + 1]]
        if s == 0 then
            return 0
        end
        s = resolve_dispatch(d, s, i + 1, valuate)
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
--- @param valuate function? see run
--- @return integer? id
--- @return integer? stop
local function longest(d, str, pos, valuate)
    local nclasses, classes, trans = d.nclasses, d.classes, d.trans
    local accept = d.accept
    local s = resolve_dispatch(d, 1, pos, valuate)
    local id, stop
    for i = pos, #str do
        s = trans[(s - 1) * nclasses + classes[byte(str, i) + 1]]
        if s == 0 then
            break
        end
        s = resolve_dispatch(d, s, i + 1, valuate)
        if accept[s] ~= 0 then
            id, stop = accept[s], i + 1
        end
    end
    return id, stop
end

return {
    MAX_STATES = MAX_STATES,
    build = build,
    intersect = intersect,
    run = run,
    longest = longest,
}
