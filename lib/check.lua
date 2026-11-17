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
-- lexogram.check: checks a grammar table and returns diagnostics. It never
-- raises for any input and reads tables only with raw access (next, rawget),
-- so metamethods are never triggered. The checks are organized as passes
-- over a shared context; each pass appends diagnostics, which are sorted
-- into a deterministic order at the end. The passes are: structure (field
-- shapes), names (definitions and plain references), patterns (parsing,
-- references, literals and usage warnings), lexical (the token automaton)
-- and syntax (lookahead decisions); the last two run only when the earlier
-- passes found no error.
local type = type
local next = next
local rawget = rawget
local ipairs = ipairs
local byte = string.byte
local char = string.char
local find = string.find
local gsub = string.gsub
local format = string.format
local concat = table.concat
local sort = table.sort
local floor = math.floor
local byte_less = require('lexogram.compat').byte_less
local resolve_version = require('lexogram.version').resolve
local text = require('lexogram.text')
local escape_key = text.escape
local quote = text.quote
local build_lexer = require('lexogram.compile.lexer').build
local DELIMITED_SETTINGS = require('lexogram.compile.delimited').SETTINGS
local analyze_syntax = require('lexogram.compile.syntax').analyze
local parse_pattern = require('lexogram.pattern').parse

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

-- Values of the nest setting of a delimited token table.
local NEST_VALUES = {
    count = true,
    error = true,
}

--- check_nest checks the nest setting of a delimited token table.
--- @param ctx table
--- @param segments any[]
--- @param value any
local function check_nest(ctx, segments, value)
    local t = type(value)
    if t == 'table' then
        add_error(ctx, 'reserved_item', segments, label(segments) ..
                      ': a table value is reserved for a future version')
    elseif t ~= 'string' then
        add_error(ctx, 'invalid_type', segments,
                  label(segments) .. ' must be string, got ' .. t)
    elseif not NEST_VALUES[value] then
        add_error(ctx, 'invalid_value', segments, label(segments) ..
                      ' must be "count" or "error", got ' .. quote(value))
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
        elseif k == 'nest' then
            check_nest(ctx, segs, v)
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
        if type(k) == 'string' and not DELIMITED_SETTINGS[k] then
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

--- collect_tokens checks the names of tokens and records their kinds. A
--- delimited token table whose name starts with "_" is invalid_name.
--- @param ctx table
--- @param tokens table
--- @param kinds table
local function collect_tokens(ctx, tokens, kinds)
    for k, v in next, tokens do
        if type(k) == 'string' then
            local segs = child(ctx.tokens_segments, k)
            check_name_shape(ctx, segs, k)
            local kind = byte(k, 1) == UNDERSCORE and 'fragment' or 'token'
            if kind == 'fragment' and type(v) == 'table' then
                -- a delimited token table is never a fragment; it is
                -- registered as a token so that a reference to it from a
                -- token pattern is reported as not a fragment
                add_error(ctx, 'invalid_name', segs,
                          label(segs) .. ': a delimited token table cannot be a' ..
                              ' fragment (its name must not start with "_")')
                kind = 'token'
            end
            define(kinds, k, kind)
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

-- patterns pass

-- ASCII case folding table: "A".."Z" to "a".."z". The [A-Z] range of a Lua
-- pattern compares byte values, so folding does not depend on the locale.
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

--- walk calls visit for node and every node below it, depth first.
--- @param node table
--- @param visit function(node)
local function walk(node, visit)
    visit(node)
    local items = node.items
    if items then
        for i = 1, #items do
            walk(items[i], visit)
        end
    elseif node.item then
        walk(node.item, visit)
    end
end

--- parse_at parses the pattern src at segments. A pattern error is added as
--- an error diagnostic; a parsed pattern is appended to ctx.patterns.
--- @param ctx table
--- @param segments any[]
--- @param src string
--- @param context string 'tokens' or 'rules'
--- @param captures table? capture names
--- @param rule string? the rule that owns a rule pattern
local function parse_at(ctx, segments, src, context, captures, rule)
    local ast, err = parse_pattern(src, context, captures)
    if not ast then
        add(ctx, 'error', err.code, segments, err.pos, err.message)
        return
    end
    local list = ctx.patterns
    list[#list + 1] = {
        segments = segments,
        ast = ast,
        rule = rule,
    }
end

--- parse_delimited parses the open, close and capture definition patterns
--- of a delimited token table.
--- @param ctx table
--- @param segments any[]
--- @param tbl table
local function parse_delimited(ctx, segments, tbl)
    local captures = {}
    for k in next, tbl do
        if type(k) == 'string' and not DELIMITED_SETTINGS[k] then
            captures[k] = true
        end
    end
    for k, v in next, tbl do
        -- every string value is a pattern, except the nest setting
        if type(k) == 'string' and type(v) == 'string' and k ~= 'nest' then
            local names = nil
            if k == 'open' or k == 'close' then
                names = captures
            end
            parse_at(ctx, child(segments, k), v, 'tokens', names)
        end
    end
end

--- parse_all parses every pattern of tokens and rules.
--- @param ctx table
--- @param tokens table?
--- @param rules table?
local function parse_all(ctx, tokens, rules)
    ctx.patterns = {}
    ctx.rule_patterns = {}
    for k, v in next, tokens or ROOT do
        if type(k) == 'string' then
            local segs = child(ctx.tokens_segments, k)
            if type(v) == 'string' then
                parse_at(ctx, segs, v, 'tokens')
            elseif type(v) == 'table' then
                parse_delimited(ctx, segs, v)
            end
        end
    end
    for k, v in next, rules or ROOT do
        if type(k) == 'string' and type(v) == 'string' then
            parse_at(ctx, child(ctx.rules_segments, k), v, 'rules', nil, k)
        end
    end
end

--- collect_literals returns the declared items of symbols and keywords as
--- a list of { segments, value, ignore_case }, or nil if the literal check
--- must be skipped because either field has the wrong type.
--- @param grammar table
--- @return table[]?
local function collect_literals(grammar)
    local items = {}
    for _, name in ipairs({
        'symbols',
        'keywords',
    }) do
        local tbl = rawget(grammar, name)
        if type(tbl) == 'table' then
            local ignore_case = rawget(tbl, 'ignore_case') == true
            for i = 1, array_length(tbl) do
                local v = rawget(tbl, i)
                if type(v) == 'string' and v ~= '' then
                    items[#items + 1] = {
                        segments = {
                            name,
                            i,
                        },
                        value = v,
                        ignore_case = ignore_case,
                    }
                end
            end
        elseif tbl ~= nil then
            return nil
        end
    end
    return items
end

--- new_declarations returns the lookup sets of the declared items.
--- @param items table[] result of collect_literals
--- @return table { exact, folded }
local function new_declarations(items)
    local exact, folded = {}, {}
    for _, item in ipairs(items) do
        exact[item.value] = true
        if item.ignore_case then
            folded[fold(item.value)] = true
        end
    end
    return {
        exact = exact,
        folded = folded,
    }
end

--- add_pattern_error adds an error at the position of node in a pattern.
--- @param ctx table
--- @param entry table parsed pattern
--- @param node table
--- @param code string
--- @param message string
local function add_pattern_error(ctx, entry, node, code, message)
    add(ctx, 'error', code, entry.segments, node.pos,
        label(entry.segments) .. message)
end

--- check_pattern_ref checks a ref node of a pattern: the referenced name
--- must be defined with one of the accepted kinds.
--- @param ctx table
--- @param entry table parsed pattern
--- @param node table ref node
--- @param accepted table set of accepted kinds
--- @param expected string description of the accepted kinds
local function check_pattern_ref(ctx, entry, node, accepted, expected)
    local set = ctx.kinds[node.name]
    if not set then
        add_pattern_error(ctx, entry, node, 'undefined_reference',
                          ' refers to undefined ' .. expected .. ' ' ..
                              quote(node.name))
        return
    end
    for kind in next, set do
        if accepted[kind] then
            return
        end
    end
    add_pattern_error(ctx, entry, node, 'invalid_reference',
                      ' refers to ' .. quote(node.name) .. ', which is ' ..
                          describe_kinds(set) .. ', not a ' .. expected)
end

-- Kinds a token pattern and a rule pattern may refer to.
local TOKEN_REFS = {
    fragment = true,
}
local RULE_REFS = {
    token = true,
    rule = true,
}

--- visit_token_pattern records the fragments used by a token pattern and
--- checks its references.
--- @param ctx table
--- @param entry table parsed pattern
--- @param usage table
local function visit_token_pattern(ctx, entry, usage)
    walk(entry.ast, function(node)
        if node.type == 'ref' then
            usage.fragments[node.name] = true
            check_pattern_ref(ctx, entry, node, TOKEN_REFS, 'fragment')
        end
    end)
end

--- visit_rule_pattern records the names and literals used by a rule
--- pattern and checks its references and, unless usage.declarations is
--- nil, its literals.
--- @param ctx table
--- @param entry table parsed pattern
--- @param usage table
local function visit_rule_pattern(ctx, entry, usage)
    local edges = usage.edges[entry.rule] or {}
    usage.edges[entry.rule] = edges
    local decl = usage.declarations
    walk(entry.ast, function(node)
        if node.type == 'ref' then
            usage.names[node.name] = true
            edges[#edges + 1] = node.name
            check_pattern_ref(ctx, entry, node, RULE_REFS, 'token or rule')
        elseif node.type == 'literal' then
            local v = node.value
            usage.literals[v] = true
            usage.folded[fold(v)] = true
            if decl and not decl.exact[v] and not decl.folded[fold(v)] then
                add_pattern_error(ctx, entry, node, 'undeclared_literal',
                                  ' refers to undeclared literal ' .. quote(v))
            end
        end
    end)
end

--- reachable_rules returns the set of rules reachable from start through
--- references in rule patterns. It is called only for a grammar without
--- errors, so start is a string that names a rule.
--- @param start string
--- @param rules table
--- @param edges table rule name -> referenced names
--- @return table
local function reachable_rules(start, rules, edges)
    local seen = {}
    local queue = {
        start,
    }
    seen[start] = true
    local head = 1
    while queue[head] do
        for _, name in ipairs(edges[queue[head]] or ROOT) do
            if not seen[name] and rawget(rules, name) ~= nil then
                seen[name] = true
                queue[#queue + 1] = name
            end
        end
        head = head + 1
    end
    return seen
end

--- has_error returns true if any error diagnostic has been added.
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

--- add_warning appends a warning diagnostic without a position.
--- @param ctx table
--- @param code string
--- @param segments any[]
--- @param message string
local function add_warning(ctx, code, segments, message)
    add(ctx, 'warning', code, segments, nil, label(segments) .. message)
end

--- warn_unused_tokens reports unused tokens and fragments.
--- @param ctx table
--- @param tokens table
--- @param usage table
local function warn_unused_tokens(ctx, tokens, usage)
    local skipped = {}
    local skip = table_field(ctx.grammar, 'skip') or ROOT
    for i = 1, array_length(skip) do
        local v = rawget(skip, i)
        if v ~= nil then
            skipped[v] = true
        end
    end
    -- warnings are only emitted without errors, so every key is a string
    for k in next, tokens do
        local segs = child(ctx.tokens_segments, k)
        if byte(k, 1) == UNDERSCORE then
            if not usage.fragments[k] then
                add_warning(ctx, 'unused_fragment', segs,
                            ' is not used by any token pattern')
            end
        elseif not usage.names[k] and not skipped[k] then
            add_warning(ctx, 'unused_token', segs,
                        ' is not used by any rule and not listed in skip')
        end
    end
end

--- warn_unused_literals reports items of symbols and keywords that no rule
--- literal matches.
--- @param ctx table
--- @param items table[] result of collect_literals
--- @param usage table
local function warn_unused_literals(ctx, items, usage)
    for _, item in ipairs(items) do
        local v = item.value
        if not usage.literals[v] and
            not (item.ignore_case and usage.folded[fold(v)]) then
            add_warning(ctx, 'unused_literal', item.segments,
                        ' ' .. quote(v) .. ' is not used by any rule')
        end
    end
end

--- warn_unreachable_rules reports rules not reachable from start.
--- @param ctx table
--- @param rules table
--- @param usage table
local function warn_unreachable_rules(ctx, rules, usage)
    local start = rawget(ctx.grammar, 'start')
    local seen = reachable_rules(start, rules, usage.edges)
    for k in next, rules do
        if not seen[k] then
            add_warning(ctx, 'unreachable_rule', child(ctx.rules_segments, k),
                        ' is not reachable from start')
        end
    end
end

--- check_patterns parses every pattern, checks the references and literals
--- of the parsed patterns and, if the grammar has no error, reports unused
--- definitions and unreachable rules. References and literals are checked
--- only when both tokens and rules are tables.
--- @param ctx table
local function check_patterns(ctx)
    local grammar = ctx.grammar
    local tokens = table_field(grammar, 'tokens')
    local rules = table_field(grammar, 'rules')
    parse_all(ctx, tokens, rules)
    if not tokens or not rules then
        return
    end

    local items = collect_literals(grammar)
    local usage = {
        declarations = items and new_declarations(items),
        fragments = {},
        names = {},
        literals = {},
        folded = {},
        edges = {},
    }
    for _, entry in ipairs(ctx.patterns) do
        if entry.rule then
            visit_rule_pattern(ctx, entry, usage)
        else
            visit_token_pattern(ctx, entry, usage)
        end
    end

    if has_error(ctx) then
        return
    end
    warn_unused_tokens(ctx, tokens, usage)
    -- items is not nil here: a symbols or keywords field of the wrong type
    -- is an error
    warn_unused_literals(ctx, items, usage)
    warn_unreachable_rules(ctx, rules, usage)
end

-- lexical pass

--- check_lexical builds the token automaton and adds its diagnostics. It
--- runs only for a grammar without errors, which lexogram.compile.lexer
--- requires.
--- @param ctx table
local function check_lexical(ctx)
    if has_error(ctx) then
        return
    end
    local result, diagnostics = build_lexer(ctx.grammar)
    ctx.lexer = result
    for _, d in ipairs(diagnostics) do
        add(ctx, d.severity, d.code, d.segments, d.pos, d.message)
    end
end

-- syntax pass

--- check_syntax computes the lookahead decisions of the rules and adds the
--- syntax diagnostics. It runs only for a grammar without errors whose
--- token automaton was built.
--- @param ctx table
local function check_syntax(ctx)
    if has_error(ctx) or not ctx.lexer then
        return
    end
    local result, diagnostics = analyze_syntax(ctx.grammar, ctx.lexer)
    ctx.syntax = result
    for _, d in ipairs(diagnostics) do
        add(ctx, d.severity, d.code, d.segments, d.pos, d.message)
    end
end

-- Passes run in order over the shared context of a grammar table.
local PASSES = {
    check_structure,
    check_names,
    check_patterns,
    check_lexical,
    check_syntax,
}

--- run checks grammar and returns its sorted diagnostics together with the
--- results of the lexical and syntax passes, which lexogram.compile reuses
--- instead of building them again. It never raises. It is internal to the
--- library; use check.
--- @param grammar any
--- @return table[] diagnostics { severity, code, path, pos, message }
--- @return table? lexer result of lexogram.compile.lexer.build, if built
--- @return table? syntax result of lexogram.compile.syntax.analyze, if built
local function run(grammar)
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
    return out, ctx.lexer, ctx.syntax
end

--- check checks grammar and returns its diagnostics, sorted. It never
--- raises.
--- @param grammar any
--- @return table[] diagnostics { severity, code, path, pos, message }
local function check(grammar)
    return (run(grammar))
end

return {
    check = check,
    run = run,
}
