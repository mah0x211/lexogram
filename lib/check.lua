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
-- lexogram.check: checks a grammar table and returns diagnostics. It never
-- raises for any input and reads tables only with raw access (next, rawget),
-- so metamethods are never triggered. The checks are organized as passes
-- over a shared context; each pass appends diagnostics, which are sorted
-- into a deterministic order at the end.
local type = type
local next = next
local rawget = rawget
local ipairs = ipairs
local byte = string.byte
local sub = string.sub
local find = string.find
local format = string.format
local concat = table.concat
local sort = table.sort
local floor = math.floor
local byte_less = require('lexogram.compat').byte_less
local resolve_version = require('lexogram.version').resolve

-- Name patterns. They mirror lexogram.pattern: a name is what its scanner
-- accepts as a name, and an all-uppercase name is a builtin class there.
local NAME_PATTERN = '^[A-Za-z_][A-Za-z0-9_]*$'
local RESERVED_PATTERN = '^[A-Z][A-Z0-9_]*$'
-- Byte value of "_", which starts a fragment name.
local UNDERSCORE = 95

-- Integral number keys in [-2^63, 2^63) are formatted with %d, which
-- every runtime supports in that range (as a 64-bit integer).
local INTEGER_LIMIT = 2 ^ 63

-- Segments of the grammar itself (the root path).
local ROOT = {}
-- Top-level fields in their sort order.
local ROOT_ORDER = {
    lexogram = 1,
    start = 2,
    tokens = 3,
    symbols = 4,
    keywords = 5,
    skip = 6,
    rules = 7,
    greedy = 8,
    recover = 9,
}
-- Required fields of a delimited token table.
local DELIMITERS = {
    'open',
    'close',
}
-- Top-level fields that must be present, in the order they are reported.
local REQUIRED_FIELDS = {
    'lexogram',
    'start',
    'tokens',
    'rules',
}

-- path strings

--- is_integral_key returns true if the number k is formatted with %d.
--- @param k number
--- @return boolean
local function is_integral_key(k)
    return k == floor(k) and k >= -INTEGER_LIMIT and k < INTEGER_LIMIT
end

--- escape_key returns the string key s escaped for a ["..."] segment.
--- Backslash and double quote are escaped with a backslash; bytes below
--- 32, 127 and bytes 128 or above are written as \ddd.
--- @param s string
--- @return string
local function escape_key(s)
    local parts = {}
    -- plain bytes are copied in runs; run is the start of the current run
    local run = 1
    for i = 1, #s do
        local b = byte(s, i)
        local esc
        if b == 92 or b == 34 then
            esc = '\\' .. sub(s, i, i)
        elseif b < 32 or b >= 127 then
            esc = format('\\%03d', b)
        end
        if esc then
            parts[#parts + 1] = sub(s, run, i - 1)
            parts[#parts + 1] = esc
            run = i + 1
        end
    end
    parts[#parts + 1] = sub(s, run)
    return concat(parts)
end

--- key_segment returns the path segment string of key k.
--- @param k any
--- @param first boolean true for the first segment of a path
--- @return string
local function key_segment(k, first)
    local t = type(k)
    if t == 'string' then
        if not find(k, NAME_PATTERN) then
            return '["' .. escape_key(k) .. '"]'
        elseif first then
            return k
        end
        return '.' .. k
    elseif t == 'number' then
        if is_integral_key(k) then
            return format('[%d]', k)
        end
        return '[' .. format('%.17g', k) .. ']'
    elseif t == 'boolean' then
        return k and '[true]' or '[false]'
    end
    return '[<' .. t .. '>]'
end

--- path_string returns the path string of the key segments.
--- @param segments any[]
--- @return string
local function path_string(segments)
    local parts = {}
    for i = 1, #segments do
        parts[i] = key_segment(segments[i], i == 1)
    end
    return concat(parts)
end

-- ordering

--- compare_numbers returns -1, 0 or 1.
--- @param a number
--- @param b number
--- @return integer
local function compare_numbers(a, b)
    return a < b and -1 or (a > b and 1 or 0)
end

--- compare_strings returns -1, 0 or 1 in byte order.
--- @param a string
--- @param b string
--- @return integer
local function compare_strings(a, b)
    return a == b and 0 or (byte_less(a, b) and -1 or 1)
end

--- key_class returns the rank of the class of key k. At the root, known
--- fields come first, then other strings, numbers, booleans and other
--- types; below the root, numbers come before strings.
--- @param k any
--- @param root boolean
--- @return integer
local function key_class(k, root)
    local t = type(k)
    if t == 'string' then
        if root and ROOT_ORDER[k] then
            return 0
        end
        return root and 1 or 2
    elseif t == 'number' then
        return root and 2 or 1
    elseif t == 'boolean' then
        return 3
    end
    return 4
end

--- compare_keys compares two path segments. Keys of a type with no order
--- (e.g. two tables) compare by type name only.
--- @param a any
--- @param b any
--- @param root boolean true for the first segment
--- @return integer -1, 0 or 1
local function compare_keys(a, b, root)
    local ca, cb = key_class(a, root), key_class(b, root)
    if ca ~= cb then
        return compare_numbers(ca, cb)
    elseif ca == 0 then
        return compare_numbers(ROOT_ORDER[a], ROOT_ORDER[b])
    end

    local t = type(a)
    if t == 'string' then
        return compare_strings(a, b)
    elseif t == 'number' then
        return compare_numbers(a, b)
    elseif t == 'boolean' then
        return compare_numbers(a and 1 or 0, b and 1 or 0)
    end
    return compare_strings(t, type(b))
end

--- compare_segments compares two paths element by element; a path that is
--- a prefix of another sorts first.
--- @param a any[]
--- @param b any[]
--- @return integer -1, 0 or 1
local function compare_segments(a, b)
    local na, nb = #a, #b
    for i = 1, (na < nb and na or nb) do
        local c = compare_keys(a[i], b[i], i == 1)
        if c ~= 0 then
            return c
        end
    end
    return compare_numbers(na, nb)
end

--- diagnostic_less orders diagnostics by path, pos (nil first), code and
--- emission index.
--- @param a table
--- @param b table
--- @return boolean
local function diagnostic_less(a, b)
    local c = compare_segments(a.segments, b.segments)
    if c == 0 then
        -- positions are 1-based, so 0 places a missing pos first
        c = compare_numbers(a.pos or 0, b.pos or 0)
    end
    if c == 0 then
        c = compare_strings(a.code, b.code)
    end
    if c == 0 then
        c = compare_numbers(a.index, b.index)
    end
    return c < 0
end

-- context

--- add appends a diagnostic to the context.
--- @param ctx table
--- @param severity string 'error' or 'warning'
--- @param code string
--- @param segments any[] keys from the root
--- @param pos integer? position inside a pattern string
--- @param message string
local function add(ctx, severity, code, segments, pos, message)
    local list = ctx.diagnostics
    list[#list + 1] = {
        severity = severity,
        code = code,
        segments = segments,
        pos = pos,
        message = message,
        index = #list + 1,
    }
end

--- add_error appends an error diagnostic without a position.
--- @param ctx table
--- @param code string
--- @param segments any[]
--- @param message string
local function add_error(ctx, code, segments, message)
    add(ctx, 'error', code, segments, nil, message)
end

--- child returns a new segment array: segments followed by key.
--- @param segments any[]
--- @param key any
--- @return any[]
local function child(segments, key)
    local out = {}
    for i = 1, #segments do
        out[i] = segments[i]
    end
    out[#out + 1] = key
    return out
end

--- label returns the name of the location for messages.
--- @param segments any[]
--- @return string
local function label(segments)
    if #segments == 0 then
        return 'grammar'
    end
    return path_string(segments)
end

--- expect_type adds invalid_type unless value has the expected type.
--- @param ctx table
--- @param segments any[]
--- @param value any
--- @param expected string
--- @return boolean ok
local function expect_type(ctx, segments, value, expected)
    local t = type(value)
    if t == expected then
        return true
    end
    add_error(ctx, 'invalid_type', segments,
              label(segments) .. ' must be ' .. expected .. ', got ' .. t)
    return false
end

--- string_key_required adds invalid_key for a key that must be a string.
--- @param ctx table
--- @param segments any[] path of the key
local function string_key_required(ctx, segments)
    add_error(ctx, 'invalid_key', segments,
              'key ' .. label(segments) .. ' must be string')
end

-- structure pass: field shapes

--- check_lexogram checks the version field.
--- @param ctx table
--- @param segments any[]
--- @param value string
local function check_lexogram(ctx, segments, value)
    local spec, code, message = resolve_version(value)
    if not spec then
        add_error(ctx, code, segments, message)
    end
end

--- check_delimited checks a delimited token table.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
local function check_delimited(ctx, segments, tbl)
    for i = 1, #DELIMITERS do
        local name = DELIMITERS[i]
        if rawget(tbl, name) == nil then
            local segs = child(segments, name)
            add_error(ctx, 'missing_field', segs,
                      'required field ' .. label(segs) .. ' is missing')
        end
    end
    for k, v in next, tbl do
        local segs = child(segments, k)
        if type(k) ~= 'string' then
            string_key_required(ctx, segs)
        else
            expect_type(ctx, segs, v, 'string')
        end
    end
end

--- check_tokens checks the tokens table.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
local function check_tokens(ctx, segments, tbl)
    for k, v in next, tbl do
        local segs = child(segments, k)
        local t = type(v)
        if type(k) ~= 'string' then
            string_key_required(ctx, segs)
        elseif t == 'table' then
            check_delimited(ctx, segs, v)
        elseif t ~= 'string' then
            add_error(ctx, 'invalid_type', segs,
                      label(segs) .. ' must be string or table, got ' .. t)
        end
    end
end

--- check_rules checks the rules table.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
local function check_rules(ctx, segments, tbl)
    for k, v in next, tbl do
        local segs = child(segments, k)
        if type(k) ~= 'string' then
            string_key_required(ctx, segs)
        else
            expect_type(ctx, segs, v, 'string')
        end
    end
end

--- is_positive_integer returns true if k is a positive integral number.
--- @param k any
--- @return boolean
local function is_positive_integer(k)
    return type(k) == 'number' and k >= 1 and k == floor(k)
end

--- array_length returns the number of positive integer keys of tbl, which
--- is the length of its array part when the array has no hole.
--- @param tbl table
--- @return integer n
local function array_length(tbl)
    local n = 0
    for k in next, tbl do
        if is_positive_integer(k) then
            n = n + 1
        end
    end
    return n
end

--- scan_array_keys checks the keys of an array table and returns the
--- length n of its array part (keys 1..n). String keys are passed to
--- on_string_key; other keys that are not in 1..n are invalid_key.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
--- @param on_string_key function(ctx, segments, key, value)
--- @return integer n
local function scan_array_keys(ctx, segments, tbl, on_string_key)
    local n = array_length(tbl)

    for k, v in next, tbl do
        local segs = child(segments, k)
        if is_positive_integer(k) then
            if k > n then
                add_error(ctx, 'invalid_key', segs,
                          'array has a hole: key ' .. label(segs) ..
                              ' is greater than the item count ' .. n)
            end
        elseif type(k) == 'string' then
            on_string_key(ctx, segs, k, v)
        else
            add_error(ctx, 'invalid_key', segs,
                      'key ' .. label(segs) .. ' is not a valid array index')
        end
    end
    return n
end

--- check_item checks the item v at index i of an array table and records
--- its first occurrence in first.
--- @param ctx table
--- @param segments any[] path of the item
--- @param v any
--- @param i integer
--- @param first table
--- @param reserved boolean true if table items are reserved_item
local function check_item(ctx, segments, v, i, first, reserved)
    local t = type(v)
    if t == 'table' and reserved then
        add_error(ctx, 'reserved_item', segments, label(segments) ..
                      ': table items are reserved for a future version')
    elseif t ~= 'string' then
        add_error(ctx, 'invalid_type', segments,
                  label(segments) .. ' must be string, got ' .. t)
    elseif v == '' then
        add_error(ctx, 'empty_item', segments,
                  label(segments) .. ' must not be empty')
    elseif first[v] then
        add_error(ctx, 'duplicate_item', segments, label(segments) ..
                      ' duplicates the item at index ' .. first[v])
    else
        first[v] = i
    end
end

--- check_items checks the items 1..n of an array table and returns a map
--- from each item to the index of its first occurrence. An index without a
--- value (the array has a hole, reported as invalid_key) is skipped.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
--- @param n integer
--- @param reserved boolean true if table items are reserved_item
--- @return table first
local function check_items(ctx, segments, tbl, n, reserved)
    local first = {}
    for i = 1, n do
        local v = rawget(tbl, i)
        if v ~= nil then
            check_item(ctx, child(segments, i), v, i, first, reserved)
        end
    end
    return first
end

--- check_item_setting checks a string key in the hash part of symbols or
--- keywords; only ignore_case is allowed.
--- @param ctx table
--- @param segments any[]
--- @param key string
--- @param value any
local function check_item_setting(ctx, segments, key, value)
    if key == 'ignore_case' then
        expect_type(ctx, segments, value, 'boolean')
    else
        add_error(ctx, 'unknown_field', segments,
                  'unknown field ' .. label(segments))
    end
end

--- reject_setting reports a string key in an array of names.
--- @param ctx table
--- @param segments any[]
local function reject_setting(ctx, segments)
    add_error(ctx, 'unknown_field', segments,
              'unknown field ' .. label(segments))
end

--- check_item_list checks symbols or keywords and returns its array
--- length n and the first occurrence map of its items.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
--- @return table items { tbl, n, first }
local function check_item_list(ctx, segments, tbl)
    local n = scan_array_keys(ctx, segments, tbl, check_item_setting)
    return {
        tbl = tbl,
        n = n,
        first = check_items(ctx, segments, tbl, n, true),
    }
end

--- check_name_list checks skip, greedy or recover.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
local function check_name_list(ctx, segments, tbl)
    local n = scan_array_keys(ctx, segments, tbl, reject_setting)
    check_items(ctx, segments, tbl, n, false)
end

--- check_cross_duplicates reports keywords items that also are symbols.
--- Only the first occurrence of an item in keywords is reported; later
--- occurrences are already duplicate_item within keywords.
--- @param ctx table
--- @param keywords table result of check_item_list for keywords
--- @param symbols table result of check_item_list for symbols
local function check_cross_duplicates(ctx, keywords, symbols)
    local kw_first, sym_first = keywords.first, symbols.first
    -- visit by index so that the emission order is deterministic
    for i = 1, keywords.n do
        local v = rawget(keywords.tbl, i)
        if kw_first[v] == i and sym_first[v] then
            local segs = {
                'keywords',
                i,
            }
            add_error(ctx, 'duplicate_item', segs, label(segs) ..
                          ' duplicates the item at symbols[' .. sym_first[v] ..
                          ']')
        end
    end
end

-- structure pass: root

-- Expected type and check function of each top-level field, in the order
-- the fields are checked.
local FIELDS = {
    {
        name = 'lexogram',
        type = 'string',
        check = check_lexogram,
    },
    {
        name = 'start',
        type = 'string',
    },
    {
        name = 'tokens',
        type = 'table',
        check = check_tokens,
    },
    {
        name = 'symbols',
        type = 'table',
        check = check_item_list,
    },
    {
        name = 'keywords',
        type = 'table',
        check = check_item_list,
    },
    {
        name = 'skip',
        type = 'table',
        check = check_name_list,
    },
    {
        name = 'rules',
        type = 'table',
        check = check_rules,
    },
    {
        name = 'greedy',
        type = 'table',
        check = check_name_list,
    },
    {
        name = 'recover',
        type = 'table',
        check = check_name_list,
    },
}

--- check_structure checks the top-level keys and the shape of each field.
--- @param ctx table
local function check_structure(ctx)
    local grammar = ctx.grammar
    for k in next, grammar do
        if type(k) ~= 'string' or not ROOT_ORDER[k] then
            local segs = {
                k,
            }
            add_error(ctx, 'unknown_field', segs,
                      'unknown field ' .. label(segs))
        end
    end

    for i = 1, #REQUIRED_FIELDS do
        local name = REQUIRED_FIELDS[i]
        if rawget(grammar, name) == nil then
            add_error(ctx, 'missing_field', {
                name,
            }, 'required field ' .. name .. ' is missing')
        end
    end

    local results = {}
    for i = 1, #FIELDS do
        local field = FIELDS[i]
        local v = rawget(grammar, field.name)
        local segs = child(ROOT, field.name)
        if v ~= nil and expect_type(ctx, segs, v, field.type) and field.check then
            results[field.name] = field.check(ctx, segs, v)
        end
    end

    if results.symbols and results.keywords then
        check_cross_duplicates(ctx, results.keywords, results.symbols)
    end
end

-- names pass

--- quote returns the string s in double quotes, escaped like a path key.
--- @param s string
--- @return string
local function quote(s)
    return '"' .. escape_key(s) .. '"'
end

--- table_field returns the field name of grammar if it is a table, or nil.
--- @param grammar table
--- @param name string
--- @return table?
local function table_field(grammar, name)
    local v = rawget(grammar, name)
    if type(v) == 'table' then
        return v
    end
    return nil
end

--- check_name_shape adds invalid_name or reserved_name for the name at
--- segments and returns true if the name is valid and not reserved.
--- @param ctx table
--- @param segments any[]
--- @param name string
--- @return boolean
local function check_name_shape(ctx, segments, name)
    if not find(name, NAME_PATTERN) then
        add_error(ctx, 'invalid_name', segments, label(segments) .. ': ' ..
                      quote(name) .. ' is not a valid name')
        return false
    elseif find(name, RESERVED_PATTERN) then
        add_error(ctx, 'reserved_name', segments,
                  label(segments) .. ': ' .. quote(name) ..
                      ' is reserved (all-uppercase names are builtins)')
        return false
    end
    return true
end

--- check_captures checks the capture names of a delimited token table.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
local function check_captures(ctx, segments, tbl)
    for k in next, tbl do
        if type(k) == 'string' and k ~= 'open' and k ~= 'close' then
            local segs = child(segments, k)
            if byte(k, 1) == UNDERSCORE then
                add_error(ctx, 'invalid_name', segs,
                          label(segs) .. ': capture name ' .. quote(k) ..
                              ' must not start with "_", which is' ..
                              ' ambiguous with a fragment reference')
            else
                check_name_shape(ctx, segs, k)
            end
        end
    end
end

--- define records that name is defined with the given kind.
--- @param kinds table name -> set of kinds
--- @param name string
--- @param kind string 'token', 'fragment' or 'rule'
local function define(kinds, name, kind)
    local set = kinds[name]
    if not set then
        set = {}
        kinds[name] = set
    end
    set[kind] = true
end

--- collect_tokens checks the names of tokens and records their kinds.
--- @param ctx table
--- @param tokens table
--- @param kinds table
local function collect_tokens(ctx, tokens, kinds)
    for k, v in next, tokens do
        if type(k) == 'string' then
            local segs = child(ctx.tokens_segments, k)
            check_name_shape(ctx, segs, k)
            define(kinds, k, byte(k, 1) == UNDERSCORE and 'fragment' or 'token')
            if type(v) == 'table' then
                check_captures(ctx, segs, v)
            end
        end
    end
end

--- collect_rules checks the names of rules, reports names also defined in
--- tokens and records their kinds.
--- @param ctx table
--- @param rules table
--- @param tokens table?
--- @param kinds table
local function collect_rules(ctx, rules, tokens, kinds)
    for k in next, rules do
        if type(k) == 'string' then
            local segs = child(ctx.rules_segments, k)
            if check_name_shape(ctx, segs, k) and tokens and rawget(tokens, k) ~=
                nil then
                add_error(ctx, 'duplicate_name', segs,
                          label(segs) .. ': ' .. quote(k) ..
                              ' is already defined at ' ..
                              path_string(child(ctx.tokens_segments, k)))
            end
            define(kinds, k, 'rule')
        end
    end
end

-- Kinds in the order they are named in messages.
local KIND_ORDER = {
    'token',
    'fragment',
    'rule',
}

--- describe_kinds returns the kinds in set, each with "a", joined with
--- " and " (e.g. "a fragment and a rule").
--- @param set table
--- @return string
local function describe_kinds(set)
    local names = {}
    for i = 1, #KIND_ORDER do
        if set[KIND_ORDER[i]] then
            names[#names + 1] = 'a ' .. KIND_ORDER[i]
        end
    end
    return concat(names, ' and ')
end

--- check_reference checks that the name referenced at segments is defined
--- with the expected kind.
--- @param ctx table
--- @param segments any[]
--- @param name string
--- @param expected string 'token' or 'rule'
local function check_reference(ctx, segments, name, expected)
    local set = ctx.kinds[name]
    if not set then
        add_error(ctx, 'undefined_reference', segments, label(segments) ..
                      ' refers to undefined ' .. expected .. ' ' .. quote(name))
    elseif not set[expected] then
        add_error(ctx, 'invalid_reference', segments,
                  label(segments) .. ' refers to ' .. quote(name) ..
                      ', which is ' .. describe_kinds(set) .. ', not a ' ..
                      expected)
    end
end

--- check_reference_list checks the string items of the array field name.
--- @param ctx table
--- @param name string
--- @param expected string 'token' or 'rule'
local function check_reference_list(ctx, name, expected)
    local list = table_field(ctx.grammar, name)
    if not list then
        return
    end
    local segments = child(ROOT, name)
    for i = 1, array_length(list) do
        local v = rawget(list, i)
        if type(v) == 'string' and v ~= '' then
            check_reference(ctx, child(segments, i), v, expected)
        end
    end
end

--- check_names checks definition names, the shared namespace of tokens and
--- rules, capture names and the plain references in start, skip, greedy
--- and recover. Malformed fields, keys and items are skipped silently; the
--- structure pass reports them. References are not checked unless both
--- tokens and rules are tables.
--- @param ctx table
local function check_names(ctx)
    local grammar = ctx.grammar
    local tokens = table_field(grammar, 'tokens')
    local rules = table_field(grammar, 'rules')
    ctx.tokens_segments = child(ROOT, 'tokens')
    ctx.rules_segments = child(ROOT, 'rules')
    ctx.kinds = {}
    if tokens then
        collect_tokens(ctx, tokens, ctx.kinds)
    end
    if rules then
        collect_rules(ctx, rules, tokens, ctx.kinds)
    end

    -- references are checked only against a complete namespace; with tokens
    -- or rules malformed every reference could be reported as undefined
    if not tokens or not rules then
        return
    end
    local start = rawget(grammar, 'start')
    if type(start) == 'string' then
        check_reference(ctx, child(ROOT, 'start'), start, 'rule')
    end
    check_reference_list(ctx, 'skip', 'token')
    check_reference_list(ctx, 'greedy', 'rule')
    check_reference_list(ctx, 'recover', 'rule')
end

-- Passes run in order over the shared context of a grammar table. Later
-- passes (pattern checks) are appended here.
local PASSES = {
    check_structure,
    check_names,
}

--- check checks grammar and returns its diagnostics, sorted. It never
--- raises.
--- @param grammar any
--- @return table[] diagnostics { severity, code, path, pos, message }
local function check(grammar)
    local ctx = {
        grammar = grammar,
        diagnostics = {},
    }
    if expect_type(ctx, ROOT, grammar, 'table') then
        for i = 1, #PASSES do
            PASSES[i](ctx)
        end
    end

    local list = ctx.diagnostics
    sort(list, diagnostic_less)
    local out = {}
    for i, d in ipairs(list) do
        out[i] = {
            severity = d.severity,
            code = d.code,
            path = path_string(d.segments),
            pos = d.pos,
            message = d.message,
        }
    end
    return out
end

return {
    check = check,
}
