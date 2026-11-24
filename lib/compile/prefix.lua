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
-- lexogram.compile.prefix: the kinds of the tokens that a prefix match of
-- the rules ("#X") can split: the tokens that can start with a part that X
-- matches and be longer than that part. X is a literal (its text, compared
-- after ASCII folding with ignore_case) or a pattern token (its own
-- automaton). The kinds are found on the automata of the lexer: the token
-- automaton, the automaton of the leading tokens and the automaton of the
-- opens of the delimited tokens. They are an over-approximation: every
-- target of a dispatch state is taken (whatever its predicates give), and
-- a kind counts when one of its strings can be longer than the part, even
-- if a longer match of another kind would win there. Every traversal is
-- iterative.
local next = next
local ipairs = ipairs
local byte = string.byte

-- Byte values of the ASCII letters.
local UPPER_A, UPPER_Z = 65, 90
local LOWER_A, LOWER_Z = 97, 122

--- literal_automaton returns an automaton (of the shape of
--- lexogram.compile.dfa) that accepts exactly text, with accept 1, or
--- each spelling of text that differs in the case of ASCII letters with
--- ignore_case.
--- @param text string
--- @param ignore_case boolean?
--- @return table
local function literal_automaton(text, ignore_case)
    -- the bytes that each position accepts
    local accepted = {}
    for i = 1, #text do
        local b = byte(text, i)
        local set = {
            [b] = true,
        }
        if ignore_case and b >= UPPER_A and b <= UPPER_Z then
            set[b + 32] = true
        elseif ignore_case and b >= LOWER_A and b <= LOWER_Z then
            set[b - 32] = true
        end
        accepted[i] = set
    end
    -- class 1 for the bytes that the text does not have, one class for each
    -- byte that it has
    local classes, class_byte, nclasses = {}, {}, 1
    for b = 0, 255 do
        classes[b + 1] = 1
    end
    for _, set in ipairs(accepted) do
        for b in next, set do
            if classes[b + 1] == 1 then
                nclasses = nclasses + 1
                classes[b + 1] = nclasses
                class_byte[nclasses] = b
            end
        end
    end
    -- state i has matched the first i - 1 bytes
    local nstates = #text + 1
    local trans, accept = {}, {}
    for s = 1, nstates do
        accept[s] = s == nstates and 1 or 0
        for c = 1, nclasses do
            local set = accepted[s]
            local t = 0
            if set and c > 1 and set[class_byte[c]] then
                t = s + 1
            end
            trans[(s - 1) * nclasses + c] = t
        end
    end
    return {
        nstates = nstates,
        nclasses = nclasses,
        classes = classes,
        trans = trans,
        accept = accept,
    }
end

--- expand returns the states that state s of d stands for: the targets of
--- a dispatch state (without the dead state), or s itself.
--- @param d table
--- @param s integer
--- @return integer[]
local function expand(d, s)
    local entry = d.dispatch and d.dispatch[s]
    if not entry then
        return {
            s,
        }
    end
    local out, seen = {}, {}
    for _, t in ipairs(entry.targets) do
        if t ~= 0 and not seen[t] then
            seen[t] = true
            out[#out + 1] = t
        end
    end
    return out
end

--- reach returns the accept values (> 0) of the states of d reachable from
--- state s after at least min bytes (0 or 1), memoized in memo.
--- @param d table
--- @param s integer a state that is not a dispatch state
--- @param min integer
--- @param memo table min -> state -> set
--- @return table value -> true
local function reach(d, s, min, memo)
    local cache = memo[min]
    if cache[s] then
        return cache[s]
    end
    local out, seen, stack = {}, {}, {}
    local function visit(t)
        for _, u in ipairs(expand(d, t)) do
            if not seen[u] then
                seen[u] = true
                stack[#stack + 1] = u
                if d.accept[u] > 0 then
                    out[d.accept[u]] = true
                end
            end
        end
    end
    local function successors(t)
        for c = 1, d.nclasses do
            local u = d.trans[(t - 1) * d.nclasses + c]
            if u ~= 0 then
                visit(u)
            end
        end
    end
    if min == 0 then
        visit(s)
    else
        successors(s)
    end
    while #stack > 0 do
        local t = stack[#stack]
        stack[#stack] = nil
        successors(t)
    end
    cache[s] = out
    return out
end

--- product calls visit(x_state, m_state) once for each pair of states of
--- the automata x and m that one same string of one byte or more reaches
--- from their start states (dispatch states expanded).
--- @param x table
--- @param m table
--- @param visit function(x_state, m_state)
local function product(x, m, visit)
    -- a class of the pair for each distinct pair of classes of a byte
    local reps, index = {}, {}
    for b = 1, 256 do
        local key = x.classes[b] * (m.nclasses + 1) + m.classes[b]
        if not index[key] then
            index[key] = true
            reps[#reps + 1] = {
                x.classes[b],
                m.classes[b],
            }
        end
    end
    local width = m.nstates + 1
    local seen, stack = {}, {}
    local function reached(sx, sm)
        for _, ex in ipairs(expand(x, sx)) do
            for _, em in ipairs(expand(m, sm)) do
                local key = ex * width + em
                if not seen[key] then
                    seen[key] = true
                    visit(ex, em)
                    stack[#stack + 1] = {
                        ex,
                        em,
                    }
                end
            end
        end
    end
    local function successors(sx, sm)
        for _, rep in ipairs(reps) do
            local nx = x.trans[(sx - 1) * x.nclasses + rep[1]]
            local nm = m.trans[(sm - 1) * m.nclasses + rep[2]]
            if nx ~= 0 and nm ~= 0 then
                reached(nx, nm)
            end
        end
    end
    for _, ex in ipairs(expand(x, 1)) do
        for _, em in ipairs(expand(m, 1)) do
            successors(ex, em)
        end
    end
    while #stack > 0 do
        local pair = stack[#stack]
        stack[#stack] = nil
        successors(pair[1], pair[2])
    end
end

--- longer returns the kind ids of the tokens that can start with a part
--- that the automaton x matches and be longer than that part.
--- @param lexer table result of lexogram.compile.lexer.build
--- @param x table automaton of X (accept > 0 where X matches)
--- @return table kind id -> true
local function longer(lexer, x)
    local out = {}
    -- pattern tokens and literals: a string of x, then one byte or more
    for _, m in ipairs({
        lexer.dfa,
        lexer.leading,
    }) do
        local memo = {
            [0] = {},
            {},
        }
        product(x, m, function(sx, sm)
            if x.accept[sx] > 0 then
                for id in next, reach(m, sm, 1, memo) do
                    out[id] = true
                end
            end
        end)
    end
    -- delimited tokens: x ends inside an open, or an open ends inside a
    -- string of x (then x may go on into the body)
    local delimited = lexer.delimited
    if delimited and #delimited.entries > 0 then
        local m, entries = delimited.open, delimited.entries
        local memo = {
            [0] = {},
            {},
        }
        product(x, m, function(sx, sm)
            if m.accept[sm] > 0 then
                out[entries[m.accept[sm]].id] = true
            end
            if x.accept[sx] > 0 then
                for v in next, reach(m, sm, 0, memo) do
                    out[entries[v].id] = true
                end
            end
        end)
    end
    return out
end

return {
    literal_automaton = literal_automaton,
    longer = longer,
}
