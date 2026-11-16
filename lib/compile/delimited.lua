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
-- lexogram.compile.delimited: checks and compiles delimited token tables
-- ({ open, close, <capture> = pattern, ... }) for lexogram.compile.lexer.
--
-- Runtime contract of a compiled table (the tokenizer is built later):
-- after the open automaton matched at pos, the capture (if any) starts at
-- pos + prefix and ends where the capture automaton, run greedily from
-- there, has no transition; the overlap check makes this exact, because no
-- byte that continues the capture can start the rest of open. The close
-- string is the concatenation of the close parts, with each capture part
-- replaced by the captured bytes. The body ends at the first occurrence of
-- the close string after the open; without one, the token runs to the end
-- of the input.
--
-- The functions take a limits table { nfa = { max_states }, dfa =
-- { max_states } } that is passed to nfa.build and dfa.build (tests only;
-- lexogram.compile.lexer builds it, and empty tables mean the defaults).
local next = next
local rawget = rawget
local ipairs = ipairs
local char = string.char
local concat = table.concat
local sort = table.sort
local huge = math.huge
local byte_less = require('lexogram.compat').byte_less
local parse = require('lexogram.pattern').parse
local quote = require('lexogram.text').quote
local nfa = require('lexogram.compile.nfa')
local dfa = require('lexogram.compile.dfa')

-- Prefix of the synthetic fragment names that stand for captures in the
-- open automaton. A NUL byte never occurs in a user name.
local SYNTHETIC_PREFIX = '\0capture:'

--- pair returns the array { a, b }.
--- @param a any
--- @param b any
--- @return table
local function pair(a, b)
    local t = {}
    t[1], t[2] = a, b
    return t
end

--- triple returns the array { a, b, c }.
--- @param a any
--- @param b any
--- @param c any
--- @return table
local function triple(a, b, c)
    local t = pair(a, b)
    t[3] = c
    return t
end

--- examples returns a function that gives the shortest string reaching a
--- DFA state, found breadth-first from state 1 over classes in ascending
--- order, using the smallest byte of each class.
--- @param d table
--- @return function(s) string
local function examples(d)
    local rep = {}
    for b = 0, 255 do
        local c = d.classes[b + 1]
        if rep[c] == nil then
            rep[c] = b
        end
    end
    local parent, via = {}, {}
    parent[1] = 0
    local queue = {}
    queue[1] = 1
    local head = 1
    while queue[head] do
        local s = queue[head]
        for c = 1, d.nclasses do
            local t = d.trans[(s - 1) * d.nclasses + c]
            if t ~= 0 and parent[t] == nil then
                parent[t] = s
                via[t] = rep[c]
                queue[#queue + 1] = t
            end
        end
        head = head + 1
    end
    return function(s)
        local bytes = {}
        while s ~= 1 do
            bytes[#bytes + 1] = via[s]
            s = parent[s]
        end
        local out = {}
        for i = #bytes, 1, -1 do
            out[#out + 1] = char(bytes[i])
        end
        return concat(out)
    end
end

-- lengths

--- utf8_length returns the length of the UTF-8 encoding of cp.
--- @param cp integer
--- @return integer
local function utf8_length(cp)
    if cp < 0x80 then
        return 1
    elseif cp < 0x800 then
        return 2
    elseif cp < 0x10000 then
        return 3
    end
    return 4
end

--- children returns the nodes a node's length depends on.
--- @param node table
--- @param fragments table
--- @param capdefs table capture name -> AST
--- @return table[]
local function children(node, fragments, capdefs)
    if node.items then
        return node.items
    elseif node.item then
        local kids = {}
        kids[1] = node.item
        return kids
    elseif node.type == 'ref' then
        return {
            fragments[node.name],
        }
    elseif node.type == 'capture' then
        return {
            capdefs[node.name],
        }
    end
    return {}
end

--- class_lengths returns the byte lengths of a class node.
--- @param node table
--- @return integer min
--- @return integer max
local function class_lengths(node)
    if node.unit == 'byte' then
        return 1, 1
    end
    local min, max = 4, 1
    for _, range in ipairs(node.ranges) do
        local lo, hi = utf8_length(range[1]), utf8_length(range[2])
        min = lo < min and lo or min
        max = hi > max and hi or max
    end
    return min, max
end

--- combine returns the byte lengths of node from those of its children.
--- @param node table
--- @param kids table[]
--- @param res table node -> { min, max }
--- @return table { min, max }
local function combine(node, kids, res)
    local t = node.type
    if t == 'literal' then
        return pair(#node.value, #node.value)
    elseif t == 'class' then
        return pair(class_lengths(node))
    elseif t == 'seq' then
        local min, max = 0, 0
        for _, kid in ipairs(kids) do
            min, max = min + res[kid][1], max + res[kid][2]
        end
        return pair(min, max)
    elseif t == 'choice' then
        local min, max = huge, 0
        for _, kid in ipairs(kids) do
            local r = res[kid]
            min = r[1] < min and r[1] or min
            max = r[2] > max and r[2] or max
        end
        return pair(min, max)
    end
    local r = res[kids[1]]
    if t == 'opt' then
        return pair(0, r[2])
    end
    local max = r[2] == 0 and 0 or huge
    if t == 'star' then
        return pair(0, max)
    elseif t == 'plus' then
        return pair(r[1], max)
    end
    -- ref and capture have the lengths of their definition
    return r
end

--- lengths returns the minimum and maximum byte length of the strings
--- matched by root, expanding fragments and captures. It is computed in
--- post-order with an explicit stack.
--- @param root table
--- @param fragments table
--- @param capdefs table
--- @return integer min
--- @return number max (math.huge when unbounded)
local function lengths(root, fragments, capdefs)
    local res = {}
    local stack = {}
    stack[1] = root
    while #stack > 0 do
        -- a node is combined once all its children have results; a node
        -- that is reached again is simply combined again
        local node = stack[#stack]
        local kids = children(node, fragments, capdefs)
        local pending = false
        for i = #kids, 1, -1 do
            if not res[kids[i]] then
                stack[#stack + 1] = kids[i]
                pending = true
            end
        end
        if not pending then
            res[node] = combine(node, kids, res)
            stack[#stack] = nil
        end
    end
    return res[root][1], res[root][2]
end

-- analysis of one table

--- add_error appends an error diagnostic.
--- @param diagnostics table[]
--- @param code string
--- @param segments any[]
--- @param pos integer?
--- @param message string
local function add_error(diagnostics, code, segments, pos, message)
    diagnostics[#diagnostics + 1] = {
        severity = 'error',
        code = code,
        segments = segments,
        pos = pos,
        message = message,
    }
end

--- capture_nodes returns the capture nodes of ast in source order.
--- @param ast table
--- @return table[]
local function capture_nodes(ast)
    local found = {}
    local stack = {}
    stack[1] = ast
    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        if node.type == 'capture' then
            found[#found + 1] = node
        elseif node.items then
            for i = #node.items, 1, -1 do
                stack[#stack + 1] = node.items[i]
            end
        elseif node.item then
            stack[#stack + 1] = node.item
        end
    end
    return found
end

--- top_items returns the items of the top-level sequence of ast (ast itself
--- when it is not a sequence).
--- @param ast table
--- @return table[]
local function top_items(ast)
    if ast.type == 'seq' then
        return ast.items
    end
    return {
        ast,
    }
end

--- check_open_captures checks how open uses captures and returns the index
--- of the capture in the top-level items, or nil.
--- @param a table analysis state
--- @return integer? index
local function check_open_captures(a)
    local items = top_items(a.open)
    local direct = {}
    for i, item in ipairs(items) do
        direct[item] = i
    end
    local index
    for n, node in ipairs(capture_nodes(a.open)) do
        if n > 1 then
            add_error(a.diagnostics, 'invalid_delimiter', a.open_segments,
                      node.pos,
                      a.label .. '.open may refer to only one' ..
                          ' capture, but refers to ' .. quote(node.name) ..
                          ' again')
        elseif not direct[node] then
            add_error(a.diagnostics, 'invalid_delimiter', a.open_segments,
                      node.pos,
                      a.label .. '.open must refer to capture ' ..
                          quote(node.name) ..
                          ' as an item of its top-level sequence')
        else
            index = direct[node]
            a.capture_name = node.name
        end
        a.used[node.name] = true
    end
    return index
end

--- check_prefix checks that the items before the capture have a fixed
--- length and returns that length.
--- @param a table
--- @param index integer
--- @return integer? prefix
local function check_prefix(a, index)
    local items = top_items(a.open)
    local prefix = 0
    for i = 1, index - 1 do
        local min, max = lengths(items[i], a.fragments, a.capdefs)
        if min ~= max then
            add_error(a.diagnostics, 'invalid_delimiter', a.open_segments,
                      items[i].pos,
                      a.label .. '.open must have a fixed length before' ..
                          ' capture ' .. quote(a.capture_name))
            return nil
        end
        prefix = prefix + min
    end
    return prefix
end

--- check_close checks close and returns its parts, or nil.
--- @param a table
--- @return table[]? parts
local function check_close(a)
    local parts, ok = {}, true
    for _, item in ipairs(top_items(a.close)) do
        if item.type == 'literal' then
            parts[#parts + 1] = {
                literal = item.value,
            }
        elseif item.type ~= 'capture' then
            add_error(a.diagnostics, 'invalid_delimiter', a.close_segments,
                      item.pos, a.label ..
                          '.close may contain only literals and captures')
            ok = false
        elseif item.name ~= a.capture_name then
            add_error(a.diagnostics, 'invalid_delimiter', a.close_segments,
                      item.pos,
                      a.label .. '.close refers to capture ' .. quote(item.name) ..
                          ', which open does not capture')
            ok = false
        else
            parts[#parts + 1] = {
                capture = true,
            }
        end
    end
    return ok and parts or nil
end

--- check_unused reports capture definitions that open does not use.
--- @param a table
local function check_unused(a)
    for _, name in ipairs(a.capture_keys) do
        if not a.used[name] then
            add_error(a.diagnostics, 'invalid_delimiter',
                      triple('tokens', a.name, name), nil, a.label .. '.' ..
                          name ..
                          ' is a capture definition that open does not use')
        end
    end
end

--- single_dfa returns the DFA of ast as the only definition.
--- @param ast table
--- @param fragments table
--- @param limits table { nfa, dfa }
--- @return table? d
--- @return table? err
local function single_dfa(ast, fragments, limits)
    local machine, err = nfa.build({
        {
            id = 1,
            ast = ast,
        },
    }, fragments, limits.nfa)
    if not machine then
        return nil, err
    end
    return dfa.build(machine, {
        1,
    }, limits.dfa)
end

--- continuation_bytes returns the set of bytes with a transition out of
--- an accepting state of d.
--- @param d table
--- @return table set
local function continuation_bytes(d)
    local set = {}
    for s = 1, d.nstates do
        if d.accept[s] ~= 0 then
            for b = 0, 255 do
                if d.trans[(s - 1) * d.nclasses + d.classes[b + 1]] ~= 0 then
                    set[b] = true
                end
            end
        end
    end
    return set
end

--- check_overlap checks that no byte continuing the capture can start the
--- rest of open, and returns the capture DFA.
--- @param a table
--- @param index integer
--- @param node table capture node
--- @return table? capture DFA
--- @return table? err automaton_too_large
local function check_overlap(a, index, node)
    local capture, err = single_dfa(a.capdefs[a.capture_name], a.fragments,
                                    a.limits)
    if not capture then
        return nil, err
    end
    local items = top_items(a.open)
    if index == #items then
        return capture
    end
    local rest = {}
    for i = index + 1, #items do
        rest[#rest + 1] = items[i]
    end
    local follow
    follow, err = single_dfa({
        type = 'seq',
        pos = rest[1].pos,
        items = rest,
    }, a.fragments, a.limits)
    if not follow then
        return nil, err
    end
    local cont = continuation_bytes(capture)
    for b = 0, 255 do
        if cont[b] and follow.trans[follow.classes[b + 1]] ~= 0 then
            add_error(a.diagnostics, 'capture_overlap', a.open_segments,
                      node.pos,
                      a.label .. '.open: capture ' .. quote(a.capture_name) ..
                          ' can continue with a byte that can start the rest' ..
                          ' of open, e.g. ' .. quote(char(b)))
            break
        end
    end
    return capture
end

--- inline returns open with its capture replaced by a reference to a
--- synthetic fragment, and that fragment's name.
--- @param a table
--- @param index integer?
--- @return table ast
local function inline(a, index)
    if not index then
        return a.open
    end
    local ref = {
        type = 'ref',
        pos = 0,
        name = SYNTHETIC_PREFIX .. a.name,
    }
    if a.open.type ~= 'seq' then
        return ref
    end
    local items = {}
    for i, item in ipairs(a.open.items) do
        items[i] = i == index and ref or item
    end
    return {
        type = 'seq',
        pos = a.open.pos,
        items = items,
    }
end

--- new_analysis returns the state for analyzing the table name.
--- @param name string
--- @param tbl table
--- @param fragments table
--- @param diagnostics table[]
--- @return table
local function new_analysis(name, tbl, fragments, diagnostics)
    local captures, keys, capdefs = {}, {}, {}
    for k in next, tbl do
        if k ~= 'open' and k ~= 'close' then
            captures[k] = true
            keys[#keys + 1] = k
        end
    end
    sort(keys, byte_less)
    for _, k in ipairs(keys) do
        capdefs[k] = parse(rawget(tbl, k), 'tokens')
    end
    return {
        name = name,
        label = 'tokens.' .. name,
        open = parse(rawget(tbl, 'open'), 'tokens', captures),
        close = parse(rawget(tbl, 'close'), 'tokens', captures),
        open_segments = triple('tokens', name, 'open'),
        close_segments = triple('tokens', name, 'close'),
        capture_keys = keys,
        capdefs = capdefs,
        fragments = fragments,
        diagnostics = diagnostics,
        used = {},
    }
end

--- check_empty reports an open or a close that can match the empty string.
--- @param a table
--- @param parts table[]?
--- @return boolean true if there is an error
local function check_empty(a, parts)
    local found = false
    if lengths(a.open, a.fragments, a.capdefs) == 0 then
        add_error(a.diagnostics, 'empty_match', a.open_segments, nil,
                  a.label .. '.open matches the empty string')
        found = true
    end
    if parts and lengths(a.close, a.fragments, a.capdefs) == 0 then
        add_error(a.diagnostics, 'empty_match', a.close_segments, nil,
                  a.label .. '.close matches the empty string')
        found = true
    end
    return found
end

--- analyze checks the delimited token table name and returns its compiled
--- parts when it has no error.
--- @param name string
--- @param tbl table
--- @param fragments table user fragments
--- @param diagnostics table[]
--- @param limits table { nfa, dfa }
--- @return table? entry { name, open, synthetic, capture_ast, token }
--- @return table? err automaton_too_large
local function analyze(name, tbl, fragments, diagnostics, limits)
    local before = #diagnostics
    local a = new_analysis(name, tbl, fragments, diagnostics)
    a.limits = limits
    local index = check_open_captures(a)
    local prefix
    if index then
        prefix = check_prefix(a, index)
    end
    local parts = check_close(a)
    check_unused(a)
    if #diagnostics > before or check_empty(a, parts) then
        return nil
    end

    local capture, err
    if index then
        capture, err = check_overlap(a, index, top_items(a.open)[index])
        if not capture then
            return nil, err
        elseif #diagnostics > before then
            return nil
        end
    end
    return {
        name = name,
        open = inline(a, index),
        synthetic = index and SYNTHETIC_PREFIX .. name,
        capture_ast = index and a.capdefs[a.capture_name],
        token = {
            prefix = prefix,
            capture = capture,
            close = parts,
        },
    }
end

--- build_open builds the DFA of all opens of entries (ids from ids) and
--- reports opens that can match the same string.
--- @param entries table[] results of analyze
--- @param ids table name -> id
--- @param fragments table user fragments
--- @param diagnostics table[]
--- @param limits table { nfa, dfa }
--- @return table? d
--- @return table? err automaton_too_large
local function build_open(entries, ids, fragments, diagnostics, limits)
    local all = {}
    for k, v in next, fragments do
        all[k] = v
    end
    local defs, rank, names = {}, {}, {}
    for i, entry in ipairs(entries) do
        local id = ids[entry.name]
        defs[i] = {
            id = id,
            ast = entry.open,
        }
        rank[id] = 1
        names[id] = entry.name
        if entry.synthetic then
            all[entry.synthetic] = entry.capture_ast
        end
    end
    local machine, err = nfa.build(defs, all, limits.nfa)
    if not machine then
        return nil, err
    end
    local d
    d, err = dfa.build(machine, rank, limits.dfa)
    if not d then
        return nil, err
    end

    local example = examples(d)
    local seen = {}
    -- opens never match the empty string, so state 1 accepts nothing
    for s = 2, d.nstates do
        local set = d.accept_sets[s]
        for i = 1, #set do
            for j = i + 1, #set do
                local key = set[i] .. ',' .. set[j]
                if not seen[key] then
                    seen[key] = true
                    -- ids are in name order, so set[j] is the later name
                    local later = names[set[j]]
                    add_error(diagnostics, 'delimiter_conflict',
                              triple('tokens', later, 'open'), nil,
                              'tokens.' .. later .. '.open can match the' ..
                                  ' same string as tokens.' .. names[set[i]] ..
                                  '.open, e.g. ' .. quote(example(s)))
                end
            end
        end
    end
    return d
end

return {
    examples = examples,
    analyze = analyze,
    build_open = build_open,
}
