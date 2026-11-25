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
-- lexogram.compile.codegen: turns the rules and the lookahead decisions of
-- lexogram.compile.syntax into the instruction array that the analyzer
-- runs. Code generation is iterative (explicit work stack).
--
-- Instructions (code is one flat array of integers; an instruction is an
-- opcode followed by its operands; addresses are indexes into code):
--   MATCH k      consume a token of kind k (0 is the end of input), or fail
--   CALL r       call rule r: push the return address, then run the rule
--                (a rule with a kind emits ENTER before and EXIT after)
--   TAILCALL r   like CALL, but reuse the current frame: only generated in
--                rules without a kind (names starting with "_"), when the
--                call is followed by nothing but RET, so the stack does not
--                grow
--   RET          return from the rule
--   JUMP a       continue at address a
--   SWITCH d     unordered choice: decisions[d].first[t] is the address for
--                the next token t; for a token in decisions[d].second, the
--                token after it selects the address instead; no entry is a
--                syntax error (the expected tokens are the keys of both)
--   TEST d a     opt, star or plus: enter the element (continue) when the
--                next token t is in decisions[d].enter and, if t is a key of
--                decisions[d].second, the token after it is in second[t];
--                otherwise continue at address a
--   TRY d a      ordered choice: if the next token is not in
--                decisions[d].first, continue at address a; otherwise push a
--                backtrack point resuming at a and continue
--   COMMIT       pop the innermost backtrack point (the alternative matched)
--   PREFIX k     prefix match "#X" of the kind k of X: consume a token of
--                kind k, or else split the next token: when the automaton
--                lexer.prefixes[k] accepts a part of its text shorter than
--                it, from its start, the longest such part is written as a
--                token of kind k and the rest is tokenized again; or fail
--
-- In a second map of a decision (see lexogram.compile.syntax), the key ANY
-- stands for any token after a token that a prefix match splits.
--
-- A star is "L: TEST d E; <item>; JUMP L; E:", a plus is "L: <item>;
-- TEST d E; JUMP L; E:" and an opt is "TEST d E; <item>; E:". An unordered
-- choice is "SWITCH d" followed by its alternatives, each but the last
-- ending with "JUMP end". An ordered choice is, for each alternative but
-- the last, "TRY d next; <alternative>; COMMIT; JUMP end; next:", followed
-- by the last alternative.
local type = type
local next = next
local ipairs = ipairs
local select = select
local sort = table.sort
local byte = string.byte
local byte_less = require('lexogram.compat').byte_less

-- Opcodes.
local MATCH = 1
local CALL = 2
local TAILCALL = 3
local RET = 4
local JUMP = 5
local SWITCH = 6
local TEST = 7
local TRY = 8
local COMMIT = 9
local PREFIX = 10
-- The kind id of any token in a second map: lexogram.compile.ll.ANY (not
-- required here, so that the analyzer does not load the analysis).
local ANY = 16777214
-- Number of operands of each opcode.
local OPERANDS = {
    [MATCH] = 1,
    [CALL] = 1,
    [TAILCALL] = 1,
    [RET] = 0,
    [JUMP] = 1,
    [SWITCH] = 1,
    [TEST] = 2,
    [TRY] = 2,
    [COMMIT] = 0,
    [PREFIX] = 1,
}
-- Byte value of "_", which starts the name of a rule without a kind.
local UNDERSCORE = 95

--- copy_set returns a copy of a set { [t] = true }.
--- @param set table
--- @return table
local function copy_set(set)
    local out = {}
    for k in next, set do
        out[k] = true
    end
    return out
end

--- array_set returns the set of the values of an array.
--- @param list table
--- @return table
local function array_set(list)
    local out = {}
    for _, v in ipairs(list) do
        out[v] = true
    end
    return out
end

-- emission

--- emit appends values to the code of g and returns the address of the
--- first one.
--- @param g table generator state
--- @param ... integer
--- @return integer
local function emit(g, ...)
    local code = g.code
    local at = #code + 1
    local n = select('#', ...)
    for i = 1, n do
        code[at + i - 1] = (select(i, ...))
    end
    return at
end

--- add_decision appends a decision and returns its index.
--- @param g table
--- @param decision table
--- @return integer
local function add_decision(g, decision)
    local list = g.decisions
    list[#list + 1] = decision
    return #list
end

--- push pushes tasks onto the work stack so that they run in the given
--- order.
--- @param stack table
--- @param tasks table[]
local function push(stack, tasks)
    for i = #tasks, 1, -1 do
        stack[#stack + 1] = tasks[i]
    end
end

--- switch_tasks returns the tasks of an unordered choice.
--- @param g table
--- @param node table
--- @param decision table decision of lexogram.compile.syntax
--- @return table[]
local function switch_tasks(g, node, decision)
    local d = add_decision(g, {})
    emit(g, SWITCH, d)
    local starts, jumps = {}, {}
    local tasks = {}
    local n = #node.items
    for i, item in ipairs(node.items) do
        tasks[#tasks + 1] = function()
            starts[i] = #g.code + 1
        end
        tasks[#tasks + 1] = item
        if i < n then
            tasks[#tasks + 1] = function()
                jumps[#jumps + 1] = emit(g, JUMP, 0)
            end
        end
    end
    tasks[#tasks + 1] = function()
        local stop = #g.code + 1
        for _, at in ipairs(jumps) do
            g.code[at + 1] = stop
        end
        local first, second = {}, {}
        for t, i in next, decision.first do
            first[t] = starts[i]
        end
        for t, map in next, decision.second do
            local out = {}
            for b, i in next, map do
                out[b] = starts[i]
            end
            second[t] = out
        end
        g.decisions[d] = {
            first = first,
            second = second,
        }
    end
    return tasks
end

--- try_tasks returns the tasks of an ordered choice.
--- @param g table
--- @param node table
--- @param decision table decision of lexogram.compile.syntax
--- @return table[]
local function try_tasks(g, node, decision)
    local jumps = {}
    local tasks = {}
    local n = #node.items
    for i, item in ipairs(node.items) do
        if i < n then
            local try_at
            tasks[#tasks + 1] = function()
                local d = add_decision(g, {
                    first = array_set(decision.first[i]),
                })
                try_at = emit(g, TRY, d, 0)
            end
            tasks[#tasks + 1] = item
            tasks[#tasks + 1] = function()
                emit(g, COMMIT)
                jumps[#jumps + 1] = emit(g, JUMP, 0)
                g.code[try_at + 2] = #g.code + 1
            end
        else
            tasks[#tasks + 1] = item
        end
    end
    tasks[#tasks + 1] = function()
        local stop = #g.code + 1
        for _, at in ipairs(jumps) do
            g.code[at + 1] = stop
        end
    end
    return tasks
end

--- test_decision returns the TEST decision data of a repetition decision.
--- @param decision table decision of lexogram.compile.syntax
--- @return table
local function test_decision(decision)
    local second = {}
    for t, map in next, decision.second do
        second[t] = copy_set(map)
    end
    return {
        enter = copy_set(decision.enter),
        second = second,
    }
end

--- repeat_tasks returns the tasks of an opt, star or plus node.
--- @param g table
--- @param node table
--- @param decision table decision of lexogram.compile.syntax
--- @return table[]
local function repeat_tasks(g, node, decision)
    local d = add_decision(g, test_decision(decision))
    local t = node.type
    if t == 'plus' then
        local loop = #g.code + 1
        return {
            node.item,
            function()
                local test = emit(g, TEST, d, 0)
                emit(g, JUMP, loop)
                g.code[test + 2] = #g.code + 1
            end,
        }
    end
    local loop = #g.code + 1
    local test = emit(g, TEST, d, 0)
    return {
        node.item,
        function()
            if t == 'star' then
                emit(g, JUMP, loop)
            end
            g.code[test + 2] = #g.code + 1
        end,
    }
end

--- node_tasks emits the code that a node needs before its children and
--- returns the tasks that follow (children and patching functions).
--- @param g table
--- @param node table
--- @return table[]?
local function node_tasks(g, node)
    local t = node.type
    if t == 'literal' then
        emit(g, MATCH, g.terminal(node))
    elseif t == 'ref' then
        local kind = g.terminal(node)
        if kind then
            emit(g, MATCH, kind)
        else
            emit(g, CALL, g.index[node.name])
        end
    elseif t == 'seq' then
        return node.items
    elseif t == 'prefix' then
        emit(g, PREFIX, g.terminal(node.item))
    elseif t == 'choice' and node.ordered then
        return try_tasks(g, node, g.source[node])
    elseif t == 'choice' then
        return switch_tasks(g, node, g.source[node])
    else
        return repeat_tasks(g, node, g.source[node])
    end
end

--- emit_rule emits the code of one rule followed by RET.
--- @param g table
--- @param ast table
local function emit_rule(g, ast)
    local stack = {
        ast,
    }
    while #stack > 0 do
        local task = stack[#stack]
        stack[#stack] = nil
        if type(task) == 'function' then
            task()
        else
            local tasks = node_tasks(g, task)
            if tasks then
                push(stack, tasks)
            end
        end
    end
    emit(g, RET)
end

--- tail_calls turns the CALLs of a rule without a kind that are followed
--- only by RET (directly or through JUMPs) into TAILCALLs.
--- @param code integer[]
--- @param from integer first address of the rule
--- @param to integer last address of the rule
local function tail_calls(code, from, to)
    local at = from
    while at <= to do
        local op = code[at]
        if op == CALL then
            local after = at + 2
            -- JUMPs only go forward to the end of a construct or back to a
            -- loop head; a backward JUMP leads to a TEST, never to RET
            while code[after] == JUMP and code[after + 1] > after do
                after = code[after + 1]
            end
            if code[after] == RET then
                code[at] = TAILCALL
            end
        end
        at = at + 1 + OPERANDS[op]
    end
end

--- generate returns the syntax part of the compiled object. A rule of an
--- alias (see lexogram.compile.syntax, result.alias_of) has the kind of the
--- rule it names, and adds no kind.
--- @param result table result of lexogram.compile.syntax.analyze
--- @param start string the start rule
--- @param first_kind integer the kind id of the first rule with a kind
--- @return table syntax { start, rules, code, decisions }
--- @return table[] kinds array of { id, name } of the rules with a kind
local function generate(result, start, first_kind)
    local names = {}
    for name in next, result.rules do
        names[#names + 1] = name
    end
    sort(names, byte_less)

    local index, rules, kinds = {}, {}, {}
    local kind_of = {}
    for i, name in ipairs(names) do
        index[name] = i
        local kind = 0
        if byte(name, 1) ~= UNDERSCORE then
            kind = first_kind + #kinds
            kinds[#kinds + 1] = {
                id = kind,
                name = name,
            }
            kind_of[name] = kind
        end
        rules[i] = {
            name = name,
            kind = kind,
        }
    end
    -- the rule of an alias is reported with the kind of the aliased rule
    local alias_of = result.alias_of or {}
    for i, name in ipairs(names) do
        local aliased = alias_of[name]
        if aliased then
            rules[i].kind = kind_of[aliased]
        end
    end

    local g = {
        code = {},
        decisions = {},
        index = index,
        source = result.decisions,
        terminal = result.analysis.terminal,
    }
    for i, name in ipairs(names) do
        local entry = #g.code + 1
        rules[i].entry = entry
        emit_rule(g, result.rules[name])
        if rules[i].kind == 0 then
            tail_calls(g.code, entry, #g.code)
        end
    end
    return {
        start = index[start],
        rules = rules,
        code = g.code,
        decisions = g.decisions,
    }, kinds
end

return {
    MATCH = MATCH,
    CALL = CALL,
    TAILCALL = TAILCALL,
    RET = RET,
    JUMP = JUMP,
    SWITCH = SWITCH,
    TEST = TEST,
    TRY = TRY,
    COMMIT = COMMIT,
    PREFIX = PREFIX,
    ANY = ANY,
    OPERANDS = OPERANDS,
    generate = generate,
}
