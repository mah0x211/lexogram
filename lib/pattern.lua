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
-- lexogram.pattern: parses a pattern DSL string into an AST. The source is
-- scanned byte by byte with string.byte; pattern errors are returned as
-- { pos, code, message } tables and argument errors are raised. The 'tokens'
-- context allows character classes, builtin classes and fragment references;
-- the 'rules' context allows references to any non-reserved name and ordered
-- choice and possessive repetitions (?+, *+, ++: the node of the repetition
-- has possessive = true) instead. The 'tokens' context allows lookaheads:
-- (?= p ) and (?! p ) give { type = 'lookahead', negative, item }, which
-- consume nothing and cannot be repeated. A count after a primary, {n},
-- {n,} or {n,m}, is expanded into the nodes of the other operators: n
-- copies of the primary, then a plus or star node for {n,}, or nested opt
-- nodes for the m - n optional copies; these repetition nodes have count
-- (the text of the count), and, when a "+" after the count makes them
-- possessive, group, a table that they share. In the 'rules' context, an
-- alias "->" name after a group gives { type = 'alias', item, name,
-- name_pos }: the range of the item is reported as the rule name. In the
-- 'rules' context, "#" before a literal or a name gives { type = 'prefix',
-- pos, item }: a prefix match, which matches the next token or a part at
-- its start (the item must name a token, which lexogram.check verifies).
-- In the 'tokens' context, the names of the captures of a delimited token
-- table may also be given; they resolve to capture nodes.
-- Groups may be nested at most MAX_NESTING levels deep (nesting_too_deep).
local type = type
local error = error
local pcall = pcall
local rawget = rawget
local next = next
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local setmetatable = setmetatable
local getmetatable = getmetatable
local byte = string.byte
local char = string.char
local sub = string.sub
local find = string.find
local concat = table.concat
local sort = table.sort
local utf8 = require('lexogram.utf8')
local encode = utf8.encode
local decode = utf8.decode

-- Byte values of the characters the scanner looks at.
local TAB = 9
local BANG = 33
local LF = 10
local CR = 13
local SPACE = 32
local DQUOTE = 34
local HASH = 35
local LPAREN = 40
local RPAREN = 41
local STAR = 42
local PLUS = 43
local HYPHEN = 45
local SLASH = 47
local COMMA = 44
local ZERO = 48
local NINE = 57
local EQUALS = 61
local GREATER = 62
local QUESTION = 63
local LBRACKET = 91
local BACKSLASH = 92
local RBRACKET = 93
local CARET = 94
local UNDERSCORE = 95
local LOWER_U = 117
local LOWER_X = 120
local LBRACE = 123
local VBAR = 124
local RBRACE = 125

-- Deepest allowed nesting of groups. The parser recurses once per group, so
-- without a limit a deeply nested pattern would exhaust the call depth of
-- the runtime, at a depth that differs between runtimes. The limit keeps
-- the result deterministic on every runtime; it is far below any runtime's
-- call depth limit and far above what any real grammar needs.
local MAX_NESTING = 100

-- Largest count of a repetition {n,m}, and largest number of nodes that the
-- counts of one pattern may add; both keep the expansion of the counts
-- small before any automaton is built.
local MAX_COUNT = 1000
local MAX_EXPANDED = 10000

-- Largest valid Unicode code point and the surrogate range.
local MAX_CODE_POINT = 0x10FFFF
local SURROGATE_MIN = 0xD800
local SURROGATE_MAX = 0xDFFF

-- Kinds of class endpoints. A neutral endpoint (ASCII) fits both units.
local NEUTRAL = 'neutral'
local BYTE = 'byte'
local CODEPOINT = 'codepoint'

-- Values that a class may contain, per unit, as sorted ranges.
local UNIVERSE = {
    byte = {
        {
            0,
            0xFF,
        },
    },
    codepoint = {
        {
            0,
            SURROGATE_MIN - 1,
        },
        {
            SURROGATE_MAX + 1,
            MAX_CODE_POINT,
        },
    },
}

-- Token kinds. A primary token carries its already built AST node.
local EOF = 'eof'
local PRIMARY = 'primary'
local SYMBOLS = {
    [LPAREN] = '(',
    [RPAREN] = ')',
    [LBRACE] = '{',
    [VBAR] = '|',
    [QUESTION] = '?',
    [STAR] = '*',
    [PLUS] = '+',
}
-- Node type produced by each postfix operator.
local POSTFIX = {
    ['?'] = 'opt',
    ['*'] = 'star',
    ['+'] = 'plus',
}

-- Escapes that decode to a single ASCII byte, in literals and classes.
local SIMPLE_ESCAPES = {
    [BACKSLASH] = BACKSLASH,
    [DQUOTE] = DQUOTE,
    [110] = LF, -- n
    [114] = CR, -- r
    [116] = TAB, -- t
}
-- Escapes that are additionally allowed inside classes.
local CLASS_ESCAPES = {
    [RBRACKET] = RBRACKET,
    [HYPHEN] = HYPHEN,
    [CARET] = CARET,
}

-- Ranges of the builtin classes; each has the byte unit.
local BUILTINS = {
    ALPHA = {
        {
            65,
            90,
        },
        {
            97,
            122,
        },
    },
    DIGIT = {
        {
            48,
            57,
        },
    },
    HEXDIGIT = {
        {
            48,
            57,
        },
        {
            65,
            70,
        },
        {
            97,
            102,
        },
    },
    ANY = {
        {
            0,
            0xFF,
        },
    },
}

-- Metatable that marks a table raised by fail as a pattern error.
local ERROR_MT = {}

--- fail raises a pattern error; parse catches it and returns it.
--- @param pos integer 1-based byte position in the source
--- @param code string
--- @param message string
local function fail(pos, code, message)
    error(setmetatable({
        pos = pos,
        code = code,
        message = message,
    }, ERROR_MT))
end

--- is_eol returns true if b ends a line or the input (nil).
--- @param b integer?
--- @return boolean
local function is_eol(b)
    return b == nil or b == LF or b == CR
end

--- is_name_start returns true if b may start a name.
--- @param b integer
--- @return boolean
local function is_name_start(b)
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == UNDERSCORE
end

--- is_name_char returns true if b may continue a name.
--- @param b integer?
--- @return boolean
local function is_name_char(b)
    return b ~= nil and (is_name_start(b) or (b >= 48 and b <= 57))
end

--- hex_value returns the value of the hex digit b, or nil.
--- @param b integer?
--- @return integer?
local function hex_value(b)
    if b == nil then
        return nil
    elseif b >= 48 and b <= 57 then
        return b - 48
    elseif b >= 65 and b <= 70 then
        return b - 55
    elseif b >= 97 and b <= 102 then
        return b - 87
    end
    return nil
end

--- invalid_escape raises the error for the escape at pos.
--- @param pos integer position of the backslash
local function invalid_escape(pos)
    fail(pos, 'invalid_escape', 'invalid escape sequence')
end

--- read_hex_escape reads the hex byte escape ("x" followed by two hex
--- digits) whose backslash is at pos.
--- @param src string
--- @param pos integer
--- @return integer value
--- @return integer next position after the escape
local function read_hex_escape(src, pos)
    local hi = hex_value(byte(src, pos + 2))
    local lo = hex_value(byte(src, pos + 3))
    if not hi or not lo then
        invalid_escape(pos)
    end
    return hi * 16 + lo, pos + 4
end

--- read_unicode_escape reads the code point escape ("u" followed by hex
--- digits in braces) whose backslash is at pos.
--- @param src string
--- @param pos integer
--- @return integer code point
--- @return integer next position after the escape
local function read_unicode_escape(src, pos)
    if byte(src, pos + 2) ~= LBRACE then
        invalid_escape(pos)
    end

    local i = pos + 3
    local cp = 0
    local d = hex_value(byte(src, i))
    if not d then
        invalid_escape(pos)
    end
    repeat
        -- stop growing once out of range so that long digit runs cannot
        -- lose precision; the value is rejected below anyway
        if cp <= MAX_CODE_POINT then
            cp = cp * 16 + d
        end
        i = i + 1
        d = hex_value(byte(src, i))
    until not d

    if byte(src, i) ~= RBRACE then
        invalid_escape(pos)
    elseif cp > MAX_CODE_POINT or (cp >= SURROGATE_MIN and cp <= SURROGATE_MAX) then
        fail(pos, 'invalid_codepoint',
             'code point is a surrogate or out of range')
    end
    return cp, i + 1
end

--- read_escape reads the escape whose backslash is at pos. The caller makes
--- sure that a byte follows the backslash.
--- @param src string
--- @param pos integer
--- @param extra table? additional single-byte escapes
--- @return integer value
--- @return string kind NEUTRAL, BYTE or CODEPOINT
--- @return integer next position after the escape
local function read_escape(src, pos, extra)
    local b = byte(src, pos + 1)
    local v = SIMPLE_ESCAPES[b] or (extra and extra[b])
    if v then
        return v, NEUTRAL, pos + 2
    elseif b == LOWER_X then
        local next_pos
        v, next_pos = read_hex_escape(src, pos)
        return v, v < 0x80 and NEUTRAL or BYTE, next_pos
    elseif b == LOWER_U then
        local next_pos
        v, next_pos = read_unicode_escape(src, pos)
        return v, CODEPOINT, next_pos
    end
    invalid_escape(pos)
end

--- skip_utf8 validates the raw UTF-8 sequence at pos and returns its code
--- point and the position after it.
--- @param src string
--- @param pos integer
--- @return integer cp
--- @return integer next position
local function skip_utf8(src, pos)
    local cp, len = decode(src, pos)
    if not cp then
        fail(pos, 'invalid_utf8', 'invalid UTF-8 sequence: ' .. tostring(len))
    end
    return cp, pos + len
end

-- literal

--- unterminated_literal raises the error for the literal opened at start.
--- @param start integer
local function unterminated_literal(start)
    fail(start, 'unterminated_literal', 'literal is not terminated')
end

--- decode_literal_escape decodes the escape at pos into a byte string.
--- @param p table parser state
--- @param start integer position of the opening quote
--- @param pos integer position of the backslash
--- @return string bytes
--- @return integer next position
local function decode_literal_escape(p, start, pos)
    if pos == p.len then
        unterminated_literal(start)
    end
    local v, kind, next_pos = read_escape(p.src, pos)
    if kind == CODEPOINT then
        return encode(v), next_pos
    end
    return char(v), next_pos
end

--- scan_literal scans the literal whose opening quote is at start.
--- @param p table parser state
--- @param start integer
--- @return table node
local function scan_literal(p, start)
    local src = p.src
    local parts = {}
    -- raw bytes are copied in runs; run is the start of the current run
    local run = start + 1
    local i = run
    while true do
        local b = byte(src, i)
        if is_eol(b) then
            unterminated_literal(start)
        elseif b == DQUOTE then
            break
        elseif b == BACKSLASH then
            parts[#parts + 1] = sub(src, run, i - 1)
            parts[#parts + 1], i = decode_literal_escape(p, start, i)
            run = i
        elseif b < 0x80 then
            i = i + 1
        else
            local _
            _, i = skip_utf8(src, i)
        end
    end
    parts[#parts + 1] = sub(src, run, i - 1)

    local value = concat(parts)
    if value == '' then
        fail(start, 'empty_literal', 'literal is empty')
    end
    p.pos = i + 1
    return {
        type = 'literal',
        pos = start,
        value = value,
    }
end

-- class

--- normalize sorts ranges and merges overlapping or adjacent ones.
--- @param ranges table
--- @return table
local function normalize(ranges)
    sort(ranges, function(a, b)
        return a[1] < b[1]
    end)

    local out = {}
    for _, r in ipairs(ranges) do
        local last = out[#out]
        if last and r[1] <= last[2] + 1 then
            if r[2] > last[2] then
                last[2] = r[2]
            end
        else
            out[#out + 1] = {
                r[1],
                r[2],
            }
        end
    end
    return out
end

--- subtract returns the parts of universe that ranges do not cover. Both
--- arguments must be sorted, non-overlapping and non-adjacent; so is the
--- result.
--- @param universe table
--- @param ranges table
--- @return table
local function subtract(universe, ranges)
    local out = {}
    local k = 1
    for _, u in ipairs(universe) do
        local cur, hi = u[1], u[2]
        -- skip ranges that end below this part of the universe
        while ranges[k] and ranges[k][2] < cur do
            k = k + 1
        end
        local m = k
        while ranges[m] and ranges[m][1] <= hi do
            if ranges[m][1] > cur then
                out[#out + 1] = {
                    cur,
                    ranges[m][1] - 1,
                }
            end
            cur = ranges[m][2] + 1
            m = m + 1
        end
        if cur <= hi then
            out[#out + 1] = {
                cur,
                hi,
            }
        end
    end
    return out
end

--- unterminated_class raises the error for the class opened at start.
--- @param start integer
local function unterminated_class(start)
    fail(start, 'unterminated_class', 'character class is not terminated')
end

--- invalid_range raises the error for a bad range or hyphen at pos.
--- @param pos integer
--- @param message string
local function invalid_range(pos, message)
    fail(pos, 'invalid_range', message)
end

--- note_kind records the kind of a class endpoint and rejects a class that
--- mixes byte and code point endpoints.
--- @param st table class state
--- @param kind string
--- @param pos integer position of the endpoint
local function note_kind(st, kind, pos)
    if kind == BYTE then
        st.has_byte = true
    elseif kind == CODEPOINT then
        st.has_cp = true
    end
    if st.has_byte and st.has_cp then
        fail(pos, 'mixed_class',
             'character class mixes byte and code point elements')
    end
end

--- read_endpoint reads one class endpoint at pos.
--- @param p table parser state
--- @param st table class state
--- @param pos integer
--- @return integer value
--- @return integer next position
local function read_endpoint(p, st, pos)
    local src = p.src
    local b = byte(src, pos)
    local v, kind, next_pos
    if b == BACKSLASH then
        if pos == p.len then
            unterminated_class(st.start)
        end
        v, kind, next_pos = read_escape(src, pos, CLASS_ESCAPES)
    elseif b < 0x80 then
        v, kind, next_pos = b, NEUTRAL, pos + 1
    else
        v, next_pos = skip_utf8(src, pos)
        kind = CODEPOINT
    end
    note_kind(st, kind, pos)
    return v, next_pos
end

--- scan_class_element scans a single character or a range at pos and adds
--- it to the class state.
--- @param p table parser state
--- @param st table class state
--- @param pos integer
--- @return integer next position
local function scan_class_element(p, st, pos)
    local lo, i = read_endpoint(p, st, pos)
    local hi = lo
    if byte(p.src, i) == HYPHEN then
        local b = byte(p.src, i + 1)
        if is_eol(b) then
            unterminated_class(st.start)
        elseif b == RBRACKET then
            invalid_range(i, 'hyphen must be followed by a range end')
        elseif b == HYPHEN then
            invalid_range(i + 1, 'unescaped hyphen in character class')
        end
        hi, i = read_endpoint(p, st, i + 1)
        if lo > hi then
            invalid_range(pos, 'range start is greater than range end')
        end
    end
    st.ranges[#st.ranges + 1] = {
        lo,
        hi,
    }
    return i
end

--- build_class returns the class node for the scanned class state.
--- @param st table class state
--- @param negate boolean
--- @return table node
local function build_class(st, negate)
    local unit = st.has_cp and CODEPOINT or BYTE
    local universe = UNIVERSE[unit]
    local ranges = subtract(universe, normalize(st.ranges))
    if negate then
        if #ranges == 0 then
            fail(st.start, 'empty_class', 'negated character class is empty')
        end
    else
        -- the complement of the complement drops values outside the
        -- universe, such as surrogates spanned by a code point range
        ranges = subtract(universe, ranges)
    end
    return {
        type = 'class',
        pos = st.start,
        unit = unit,
        ranges = ranges,
    }
end

--- scan_class scans the class whose opening bracket is at start.
--- @param p table parser state
--- @param start integer
--- @return table node
local function scan_class(p, start)
    local src = p.src
    local i = start + 1
    local negate = byte(src, i) == CARET
    if negate then
        i = i + 1
    end

    local st = {
        start = start,
        ranges = {},
        has_byte = false,
        has_cp = false,
    }
    while true do
        local b = byte(src, i)
        if is_eol(b) then
            unterminated_class(start)
        elseif b == RBRACKET then
            break
        elseif b == HYPHEN then
            invalid_range(i, 'unescaped hyphen in character class')
        end
        i = scan_class_element(p, st, i)
    end

    if #st.ranges == 0 then
        fail(start, 'empty_class', 'character class is empty')
    end
    p.pos = i + 1
    return build_class(st, negate)
end

-- names

--- copy_ranges returns a deep copy of ranges.
--- @param ranges table
--- @return table
local function copy_ranges(ranges)
    local out = {}
    for i, r in ipairs(ranges) do
        out[i] = {
            r[1],
            r[2],
        }
    end
    return out
end

--- reject_tokens_reference raises invalid_reference for a name that is
--- neither a builtin, a fragment nor a capture.
--- @param p table parser state
--- @param name string
--- @param pos integer
local function reject_tokens_reference(p, name, pos)
    if p.captures then
        fail(pos, 'invalid_reference',
             'only fragment names (starting with "_") and capture names may' ..
                 ' be referenced: ' .. name)
    end
    fail(pos, 'invalid_reference',
         'only fragment names (starting with "_") may be referenced: ' .. name)
end

--- resolve_tokens_name returns the node for a name in the tokens context:
--- a builtin class, a fragment reference or, if the name is in the
--- captures table of the parser state, a capture.
--- @param p table parser state
--- @param name string
--- @param pos integer
--- @return table node
local function resolve_tokens_name(p, name, pos)
    if byte(name, 1) == UNDERSCORE then
        return {
            type = 'ref',
            pos = pos,
            name = name,
        }
    elseif not find(name, '^[A-Z][A-Z0-9_]*$') then
        if p.captures and rawget(p.captures, name) then
            return {
                type = 'capture',
                pos = pos,
                name = name,
            }
        end
        reject_tokens_reference(p, name, pos)
    elseif not BUILTINS[name] then
        fail(pos, 'unknown_builtin', 'unknown builtin class: ' .. name)
    end
    return {
        type = 'class',
        pos = pos,
        unit = BYTE,
        ranges = copy_ranges(BUILTINS[name]),
    }
end

--- resolve_rules_name returns the reference node for a name in the rules
--- context. All-uppercase names are reserved.
--- @param _ table parser state
--- @param name string
--- @param pos integer
--- @return table node
local function resolve_rules_name(_, name, pos)
    if find(name, '^[A-Z][A-Z0-9_]*$') then
        fail(pos, 'reserved_name', 'all-uppercase names are reserved: ' .. name)
    end
    return {
        type = 'ref',
        pos = pos,
        name = name,
    }
end

--- reject_class rejects a character class in a context without classes.
--- The class body is not scanned.
--- @param _ table parser state
--- @param pos integer position of the "["
local function reject_class(_, pos)
    fail(pos, 'class_not_allowed',
         'character class is not allowed in this context')
end

--- reject_possessive rejects a possessive repetition in a context without
--- them.
--- @param _ table parser state
--- @param pos integer position of the "+" after the postfix operator
local function reject_possessive(_, pos)
    fail(pos, 'possessive_not_allowed',
         'possessive repetition (?+, *+, ++) is not allowed in this context')
end

--- accept_possessive accepts a possessive repetition.
local function accept_possessive()
end

--- reject_lookahead rejects a lookahead in a context without them.
--- @param _ table parser state
--- @param pos integer position of the "("
local function reject_lookahead(_, pos)
    fail(pos, 'lookahead_not_allowed',
         'lookahead (?= or (?! is not allowed in this context')
end

--- accept_lookahead accepts a lookahead.
local function accept_lookahead()
end

--- reject_ordered_choice rejects "/" in a context without ordered choice.
--- @param _ table parser state
--- @param pos integer
local function reject_ordered_choice(_, pos)
    fail(pos, 'ordered_choice_not_allowed',
         'ordered choice "/" is not allowed in this context')
end

--- reject_alias rejects an alias in a context without them.
--- @param _ table parser state
--- @param pos integer position of the "->"
local function reject_alias(_, pos)
    fail(pos, 'alias_not_allowed', 'alias "->" is not allowed in this context')
end

--- accept_alias accepts an alias.
local function accept_alias()
end

--- reject_prefix rejects a prefix match in a context without them.
--- @param _ table parser state
--- @param pos integer position of the "#"
local function reject_prefix(_, pos)
    fail(pos, 'prefix_not_allowed',
         'prefix match "#" is not allowed in this context')
end

--- accept_prefix makes "#" the current token.
--- @param p table parser state
--- @param pos integer
local function accept_prefix(p, pos)
    p.kind, p.pos = '#', pos + 1
end

--- accept_ordered_choice makes "/" the current token.
--- @param p table parser state
--- @param pos integer
local function accept_ordered_choice(p, pos)
    p.kind, p.pos = '/', pos + 1
end

-- Context dependent behavior. Each context defines how names resolve, how a
-- class ("[") is handled, how "/" and "#" are handled and whether a
-- possessive repetition and a lookahead are allowed.
local CONTEXTS = {
    tokens = {
        resolve_name = resolve_tokens_name,
        scan_class = scan_class,
        on_slash = reject_ordered_choice,
        on_possessive = reject_possessive,
        on_lookahead = accept_lookahead,
        on_alias = reject_alias,
        on_prefix = reject_prefix,
    },
    rules = {
        resolve_name = resolve_rules_name,
        scan_class = reject_class,
        on_slash = accept_ordered_choice,
        on_possessive = accept_possessive,
        on_lookahead = reject_lookahead,
        on_alias = accept_alias,
        on_prefix = accept_prefix,
    },
}

-- lexer

--- skip_space returns the first position at or after pos that is not
--- whitespace.
--- @param src string
--- @param pos integer
--- @return integer
local function skip_space(src, pos)
    local b = byte(src, pos)
    while b == SPACE or b == TAB or b == LF or b == CR do
        pos = pos + 1
        b = byte(src, pos)
    end
    return pos
end

--- scan_name scans the name that starts at start.
--- @param p table parser state
--- @param start integer
--- @return table node
local function scan_name(p, start)
    local i = start + 1
    while is_name_char(byte(p.src, i)) do
        i = i + 1
    end
    p.pos = i
    return p.context.resolve_name(p, sub(p.src, start, i - 1), start)
end

--- advance scans the next token and stores it in p.kind, p.tpos (its
--- position) and p.node (the node of a primary token).
--- @param p table parser state
local function advance(p)
    local i = skip_space(p.src, p.pos)
    local b = byte(p.src, i)
    p.tpos = i
    p.node = nil
    if b == nil then
        p.kind = EOF
    elseif b == DQUOTE then
        p.kind, p.node = PRIMARY, scan_literal(p, i)
    elseif b == LBRACKET then
        p.kind, p.node = PRIMARY, p.context.scan_class(p, i)
    elseif is_name_start(b) then
        p.kind, p.node = PRIMARY, scan_name(p, i)
    elseif SYMBOLS[b] then
        p.kind, p.pos = SYMBOLS[b], i + 1
    elseif b == SLASH then
        p.context.on_slash(p, i)
    elseif b == HASH then
        p.context.on_prefix(p, i)
    elseif b == HYPHEN and byte(p.src, i + 1) == GREATER then
        p.kind, p.pos = '->', i + 2
    else
        fail(i, 'unexpected_char', 'unexpected character')
    end
end

-- parser

-- Choice separators and whether they make the choice ordered.
local SEPARATORS = {
    ['|'] = false,
    ['/'] = true,
}

local parse_choice

--- missing_operand raises the error for an operand expected at the current
--- token.
--- @param p table parser state
local function missing_operand(p)
    fail(p.tpos, 'missing_operand', 'operand is missing')
end

--- parse_group parses "(" choice ")" and returns the inner node, or a
--- lookahead "(?=" choice ")" or "(?!" choice ")" ("(?" must be followed
--- directly by "=" or "!").
--- @param p table parser state
--- @return table node
local function parse_group(p)
    local open = p.tpos
    -- the limit is checked before anything after the "(" is scanned, so the
    -- error is the first one from the left
    if p.depth >= MAX_NESTING then
        fail(open, 'nesting_too_deep',
             'groups are nested deeper than ' .. MAX_NESTING .. ' levels')
    end
    p.depth = p.depth + 1
    -- p.pos is the position right after the "("
    local negative
    if byte(p.src, p.pos) == QUESTION then
        local b = byte(p.src, p.pos + 1)
        if b == EQUALS or b == BANG then
            p.context.on_lookahead(p, open)
            negative = b == BANG
            p.pos = p.pos + 2
        end
    end
    advance(p)
    local node = parse_choice(p)
    if p.kind ~= ')' then
        fail(open, 'unbalanced_paren', '"(" is not closed')
    end
    p.depth = p.depth - 1
    advance(p)
    if negative ~= nil then
        node = {
            type = 'lookahead',
            pos = open,
            negative = negative,
            item = node,
        }
    end
    return node
end

--- copy_node returns a deep copy of the AST node, so that each copy of a
--- repeated primary is a node of its own; a table that the node refers to
--- more than once (the group of a possessive count inside it) stays one
--- table in the copy.
--- @param node table
--- @param seen table? original -> copy
--- @return table
local function copy_node(node, seen)
    seen = seen or {}
    if seen[node] then
        return seen[node]
    end
    local out = {}
    seen[node] = out
    for k, v in next, node do
        out[k] = type(v) == 'table' and copy_node(v, seen) or v
    end
    return out
end

--- count_nodes returns the number of nodes of the AST node.
--- @param node table
--- @return integer
local function count_nodes(node)
    local n = 1
    if node.items then
        for _, item in ipairs(node.items) do
            n = n + count_nodes(item)
        end
    elseif node.item then
        n = n + count_nodes(node.item)
    end
    return n
end

--- scan_count returns the decimal number at pos of the source of p and the
--- position after it, or nil and pos if there is no digit there.
--- @param p table parser state
--- @param pos integer
--- @return integer?
--- @return integer
local function scan_count(p, pos)
    local i = pos
    local b = byte(p.src, i)
    while b and b >= ZERO and b <= NINE do
        i = i + 1
        b = byte(p.src, i)
    end
    if i == pos then
        return nil, pos
    elseif i - pos > 4 then
        -- more digits than MAX_COUNT has: too large whatever they are
        return MAX_COUNT + 1, i
    end
    return tonumber(sub(p.src, pos, i - 1)), i
end

--- expand_count returns the nodes of node repeated min to max times (max
--- nil: without a limit).
--- @param node table
--- @param min integer
--- @param max integer?
--- @param count string the text of the count, such as "{2,4}"
--- @param possessive boolean
--- @return table
local function expand_count(node, min, max, count, possessive)
    local group = possessive and {
        count = count,
    } or nil
    local function repetition(t, item)
        return {
            type = t,
            pos = node.pos,
            item = item,
            count = count,
            possessive = possessive or nil,
            group = group,
        }
    end
    local items = {}
    local function add(item)
        items[#items + 1] = #items == 0 and item or copy_node(item)
    end
    if max == nil then
        for _ = 1, min - 1 do
            add(node)
        end
        items[#items + 1] = repetition(min == 0 and 'star' or 'plus',
                                       #items == 0 and node or copy_node(node))
    else
        for _ = 1, min do
            add(node)
        end
        local tail
        for _ = 1, max - min do
            local item = copy_node(node)
            if tail then
                item = {
                    type = 'seq',
                    pos = node.pos,
                    items = {
                        item,
                        tail,
                    },
                }
            end
            tail = repetition('opt', item)
        end
        if tail then
            items[#items + 1] = tail
        end
    end
    if #items == 1 then
        return items[1]
    end
    return {
        type = 'seq',
        pos = node.pos,
        items = items,
    }
end

--- parse_count parses a count {n}, {n,} or {n,m} (p.pos is right after the
--- "{"), which a "+" right after it makes possessive, and returns node
--- repeated as it says.
--- @param p table parser state
--- @param node table
--- @return table
local function parse_count(p, node)
    local open = p.tpos
    local min, i = scan_count(p, p.pos)
    if not min then
        fail(i, 'invalid_repetition', 'a count is expected after "{"')
    end
    local max = min
    if byte(p.src, i) == COMMA then
        max, i = scan_count(p, i + 1)
    end
    if byte(p.src, i) ~= RBRACE then
        fail(open, 'invalid_repetition', '"{" is not closed by "}"')
    elseif max == 0 then
        fail(open, 'invalid_repetition',
             'a repetition of zero times matches nothing')
    elseif max and min > max then
        fail(open, 'invalid_repetition',
             'the least count of a repetition is larger than the largest')
    elseif min > MAX_COUNT or (max and max > MAX_COUNT) then
        fail(open, 'invalid_repetition',
             'a count of a repetition is larger than ' .. MAX_COUNT)
    end
    local count = sub(p.src, open, i)
    i = i + 1
    local possessive = false
    if byte(p.src, i) == PLUS then
        p.context.on_possessive(p, i)
        if max == min then
            fail(i, 'invalid_repetition',
                 'a repetition of a fixed count cannot be possessive')
        end
        possessive = true
        i = i + 1
    end
    local size = count_nodes(node) * (max or min + 1)
    p.expanded = p.expanded + size
    if p.expanded > MAX_EXPANDED then
        fail(open, 'invalid_repetition',
             'the counts of repetitions make' .. ' the pattern larger than ' ..
                 MAX_EXPANDED .. ' nodes')
    end
    p.pos = i
    return expand_count(node, min, max, count, possessive)
end

--- parse_alias parses the name after "->" (the current token) and returns
--- node aliased to it.
--- @param p table parser state
--- @param node table
--- @return table
local function parse_alias(p, node)
    p.context.on_alias(p, p.tpos)
    local arrow = p.tpos
    advance(p)
    local name = p.node
    if p.kind ~= PRIMARY or name.type ~= 'ref' then
        fail(arrow, 'invalid_alias', 'a rule name is expected after "->"')
    end
    advance(p)
    return {
        type = 'alias',
        pos = node.pos,
        item = node,
        name = name.name,
        name_pos = name.pos,
    }
end

--- parse_prefix parses "#" (the current token) and the literal or the name
--- after it, and returns the prefix node.
--- @param p table parser state
--- @return table node
local function parse_prefix(p)
    local hash = p.tpos
    advance(p)
    if p.kind ~= PRIMARY then
        fail(p.tpos, 'invalid_prefix',
             'a literal or a name is expected after "#"')
    end
    local node = {
        type = 'prefix',
        pos = hash,
        item = p.node,
    }
    advance(p)
    return node
end

--- parse_repeat parses a primary, or a prefix match "#" primary, with an
--- optional postfix operator, which a "+" right after it makes possessive
--- (?+, *+, ++), or with a count (see parse_count). It returns nil if the
--- current token cannot start a primary.
--- @param p table parser state
--- @return table? node
local function parse_repeat(p)
    local node
    local grouped = p.kind == '('
    if p.kind == PRIMARY then
        node = p.node
        advance(p)
    elseif p.kind == '#' then
        node = parse_prefix(p)
    elseif grouped then
        node = parse_group(p)
    else
        return nil
    end

    if p.kind == '->' then
        -- the range of an alias is always written in parentheses
        if not grouped then
            fail(p.tpos, 'invalid_alias',
                 'an alias follows a group: write (p)->name')
        end
        node = parse_alias(p, node)
        if POSTFIX[p.kind] or p.kind == '{' or p.kind == '->' then
            fail(p.tpos, 'repeated_postfix',
                 'postfix operator follows an alias; write ((p)->name)*')
        end
        return node
    end
    local t = POSTFIX[p.kind]
    if (t or p.kind == '{') and node.type == 'lookahead' then
        fail(p.tpos, 'invalid_lookahead', 'a lookahead cannot be repeated')
    elseif p.kind == '{' then
        node = parse_count(p, node)
        advance(p)
        if POSTFIX[p.kind] or p.kind == '{' or p.kind == '->' then
            fail(p.tpos, 'repeated_postfix',
                 'postfix operator follows another postfix operator')
        end
    elseif t then
        node = {
            type = t,
            pos = node.pos,
            item = node,
        }
        -- p.pos is the position right after the postfix operator
        if byte(p.src, p.pos) == PLUS then
            p.context.on_possessive(p, p.pos)
            node.possessive = true
            p.pos = p.pos + 1
        end
        advance(p)
        if POSTFIX[p.kind] or p.kind == '{' or p.kind == '->' then
            fail(p.tpos, 'repeated_postfix',
                 'postfix operator follows another postfix operator')
        end
    end
    return node
end

--- parse_sequence parses one or more repeats.
--- @param p table parser state
--- @return table node
local function parse_sequence(p)
    local items = {
        parse_repeat(p),
    }
    if not items[1] then
        missing_operand(p)
    end
    local node = parse_repeat(p)
    while node do
        items[#items + 1] = node
        node = parse_repeat(p)
    end
    if #items == 1 then
        return items[1]
    end
    return {
        type = 'seq',
        pos = items[1].pos,
        items = items,
    }
end

--- parse_choice parses sequences separated by "|" or by "/". The first
--- separator decides the kind of the choice; the other one is mixed_choice.
--- @param p table parser state
--- @return table node
function parse_choice(p)
    local items = {
        parse_sequence(p),
    }
    local sep = p.kind
    local ordered = SEPARATORS[sep]
    if ordered == nil then
        return items[1]
    end
    while SEPARATORS[p.kind] ~= nil do
        if p.kind ~= sep then
            fail(p.tpos, 'mixed_choice', 'choice mixes "|" and "/"')
        end
        advance(p)
        items[#items + 1] = parse_sequence(p)
    end
    return {
        type = 'choice',
        pos = items[1].pos,
        ordered = ordered,
        items = items,
    }
end

--- parse_pattern parses the whole source.
--- @param p table parser state
--- @return table node
local function parse_pattern(p)
    advance(p)
    if p.kind == EOF then
        fail(1, 'missing_operand', 'pattern is empty')
    end
    local node = parse_choice(p)
    if p.kind ~= EOF then
        fail(p.tpos, 'unbalanced_paren', '")" has no matching "("')
    end
    return node
end

--- parse parses the pattern src in the given context.
--- @param src string
--- @param context string 'tokens' or 'rules'
--- @param captures table? capture names of a delimited token table (tokens
--- context only); a name n is a capture if captures[n] is truthy, and it
--- resolves to a { type = 'capture', pos, name } node
--- @return table? ast
--- @return table? err { pos, code, message }
local function parse(src, context, captures)
    if type(src) ~= 'string' then
        error('src must be string, got ' .. type(src), 2)
    elseif type(context) ~= 'string' then
        error('context must be string, got ' .. type(context), 2)
    elseif not CONTEXTS[context] then
        error('unsupported context: ' .. context, 2)
    elseif captures ~= nil then
        if type(captures) ~= 'table' then
            error('captures must be table, got ' .. type(captures), 2)
        elseif context ~= 'tokens' then
            error('captures are only allowed in the tokens context', 2)
        end
    end

    local ok, res = pcall(parse_pattern, {
        src = src,
        len = #src,
        pos = 1,
        -- current nesting depth of groups
        depth = 0,
        -- number of nodes that the counts of repetitions added
        expanded = 0,
        context = CONTEXTS[context],
        captures = captures,
    })
    if ok then
        return res
    elseif getmetatable(res) ~= ERROR_MT then
        -- not a pattern error: an internal failure, propagate it as is
        error(res, 0)
    end
    return nil, setmetatable(res, nil)
end

return {
    parse = parse,
}
