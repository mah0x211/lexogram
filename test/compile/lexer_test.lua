local testcase = require('testcase')
local assert = require('assert')
local lexer = require('lexogram.compile.lexer')
local dfa = require('lexogram.compile.dfa')

-- a grammar with the given tokens, symbols and keywords (the lexer reads
-- only these fields)
local function grammar(tokens, symbols, keywords)
    return {
        lexogram = '2026.11.15.1',
        start = 's',
        tokens = tokens,
        symbols = symbols,
        keywords = keywords,
        rules = {
            s = 's',
        },
    }
end

local function err(code, segments, message)
    return {
        severity = 'error',
        code = code,
        segments = segments,
        message = message,
    }
end

-- run fn(...) with the debug hook removed (see utf8range_test.lua)
local function without_hook(fn, ...)
    local hook, mask, count = debug.gethook()
    debug.sethook()
    local res = {
        pcall(fn, ...),
    }
    if hook then
        debug.sethook(hook, mask, count)
    end
    if not res[1] then
        error(res[2], 0)
    end
    return res[2], res[3]
end

function testcase.build_numbers_definitions()
    local result, diagnostics = lexer.build(grammar({
        num = 'DIGIT+',
        id = 'ALPHA+',
        _d = 'DIGIT',
        str = {
            open = '"\\""',
            close = '"\\""',
        },
    }, {
        '+',
        '-',
    }, {
        'if',
        ignore_case = true,
    }))

    assert.equal(diagnostics, {})
    assert.equal(result.defs, {
        {
            id = 1,
            kind = 'token',
            name = 'id',
            segments = {
                'tokens',
                'id',
            },
        },
        {
            id = 2,
            kind = 'token',
            name = 'num',
            segments = {
                'tokens',
                'num',
            },
        },
        {
            id = 3,
            kind = 'symbol',
            name = '+',
            segments = {
                'symbols',
                1,
            },
        },
        {
            id = 4,
            kind = 'symbol',
            name = '-',
            segments = {
                'symbols',
                2,
            },
        },
        {
            id = 5,
            kind = 'keyword',
            name = 'if',
            segments = {
                'keywords',
                1,
            },
        },
        {
            id = 6,
            kind = 'delimited',
            name = 'str',
            segments = {
                'tokens',
                'str',
            },
        },
    })
    assert.equal(result.delimited.tokens, {
        [6] = {
            close = {
                {
                    literal = '"',
                },
            },
        },
    })

    -- the automaton tokenizes with longest match and literal priority
    local d = result.dfa
    local src = 'ifx+12-IF'
    local tokens = {}
    local pos = 1
    while pos <= #src do
        local id, stop = dfa.longest(d, src, pos)
        tokens[#tokens + 1] = {
            id,
            src:sub(pos, stop - 1),
        }
        pos = stop
    end
    assert.equal(tokens, {
        {
            1,
            'ifx',
        },
        {
            3,
            '+',
        },
        {
            2,
            '12',
        },
        {
            4,
            '-',
        },
        {
            5,
            'IF',
        },
    })
end

function testcase.build_reports_fragment_recursion()
    local result, diagnostics = lexer.build(grammar({
        a = '_x',
        _x = '"x" _x?',
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('fragment_recursion', {
            'tokens',
            '_x',
        }, 'fragment _x is recursive: _x -> _x'),
    })

    -- stops before building: the empty match of e is not reported
    result, diagnostics = lexer.build(grammar({
        a = '_b',
        e = '"e"*',
        _b = '"b" _a?',
        _a = '_b',
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('fragment_recursion', {
            'tokens',
            '_a',
        }, 'fragment _a is recursive: _a -> _b -> _a'),
    })
end

function testcase.build_reports_automaton_too_large()
    local result, diagnostics = without_hook(lexer.build, grammar({
        t = '("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 16),
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 50000 states'),
    })
end

function testcase.build_reports_nfa_too_large()
    local tokens = {
        t = '_f20',
        _f1 = '"x"',
    }
    for i = 2, 20 do
        tokens['_f' .. i] = '_f' .. (i - 1) .. ' _f' .. (i - 1)
    end

    local result, diagnostics = without_hook(lexer.build, grammar(tokens))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the automaton would have more than 200000 states'),
    })
end

function testcase.build_reports_empty_match()
    local result, diagnostics = lexer.build(grammar({
        a = '"a"*',
        b = '("x")?',
        c = '"c"',
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('empty_match', {
            'tokens',
            'a',
        }, 'tokens.a matches the empty string'),
        err('empty_match', {
            'tokens',
            'b',
        }, 'tokens.b matches the empty string'),
    })
end

function testcase.build_reports_token_conflicts()
    local result, diagnostics = lexer.build(grammar({
        name = '[a-z]+',
        kx = '"x" DIGIT?',
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('token_conflict', {
            'tokens',
            'name',
        }, 'tokens.name can match the same string as tokens.kx, e.g. "x"'),
    })

    -- reported even where a literal wins
    result, diagnostics = lexer.build(grammar({
        name = '[a-z]+',
        word = '"if" | "of"',
    }, nil, {
        'if',
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('token_conflict', {
            'tokens',
            'word',
        }, 'tokens.word can match the same string as tokens.name, e.g. "if"'),
    })

    -- several pairs, each reported once
    result, diagnostics = lexer.build(grammar({
        a = '[a-c]+',
        b = '[b-d]+',
        c = '[c-e]+',
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('token_conflict', {
            'tokens',
            'b',
        }, 'tokens.b can match the same string as tokens.a, e.g. "b"'),
        err('token_conflict', {
            'tokens',
            'c',
        }, 'tokens.c can match the same string as tokens.a, e.g. "c"'),
        err('token_conflict', {
            'tokens',
            'c',
        }, 'tokens.c can match the same string as tokens.b, e.g. "c"'),
    })
end

function testcase.build_reports_literal_conflicts()
    local result, diagnostics = lexer.build(grammar({}, {
        '+',
        'and',
    }, {
        'AND',
        'Or',
        'oR',
        ignore_case = true,
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        -- in the order of the first conflicting state
        err('literal_conflict', {
            'keywords',
            3,
        }, 'keywords[3] can match the same string as keywords[2], e.g. "OR"'),
        err('literal_conflict', {
            'keywords',
            1,
        }, 'keywords[1] can match the same string as symbols[2], e.g. "and"'),
    })
end

function testcase.build_warns_about_tokens_never_adopted()
    local result, diagnostics = lexer.build(grammar({
        kw = '"if"',
        name = '[a-z]+',
    }, nil, {
        'if',
    }))

    -- kw and name both match "if", which is a token conflict instead
    assert.is_nil(result)
    assert.equal(#diagnostics, 1)
    assert.equal(diagnostics[1].code, 'token_conflict')

    result, diagnostics = lexer.build(grammar({
        kw = '"if"',
        num = 'DIGIT+',
    }, nil, {
        'if',
    }))
    assert.is_table(result)
    assert.equal(diagnostics, {
        {
            severity = 'warning',
            code = 'never_adopted',
            segments = {
                'tokens',
                'kw',
            },
            message = 'tokens.kw is never adopted: it is always shadowed' ..
                ' by a literal or a longer match',
        },
    })
end

function testcase.build_reports_no_warning_with_errors()
    local result, diagnostics = lexer.build(grammar({
        kw = '"if"',
        e = '"e"*',
    }, nil, {
        'if',
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('empty_match', {
            'tokens',
            'e',
        }, 'tokens.e matches the empty string'),
    })
end

-- delimited tokens

local function lua_long(prefix)
    return {
        open = '"' .. prefix .. '[" level "["',
        close = '"]" level "]"',
        level = '"="*',
    }
end

-- the capture bytes by the runtime contract: from pos + prefix, run the
-- capture automaton greedily until it has no transition
local function extract_capture(token, s, pos)
    local d = token.capture
    local first = pos + token.prefix
    local state, stop = 1, first
    for i = first, #s do
        state = d.trans[(state - 1) * d.nclasses + d.classes[s:byte(i) + 1]]
        if state == 0 then
            break
        end
        stop = i + 1
    end
    return s:sub(first, stop - 1)
end

function testcase.build_compiles_lua_long_strings_and_comments()
    local result, diagnostics = lexer.build(grammar({
        name = 'ALPHA+',
        long_string = lua_long(''),
        long_comment = lua_long('--'),
    }, {
        '-',
    }))

    assert.equal(diagnostics, {})
    assert.equal(result.defs[3], {
        id = 3,
        kind = 'delimited',
        name = 'long_comment',
        segments = {
            'tokens',
            'long_comment',
        },
    })
    assert.equal(result.defs[4].name, 'long_string')

    local tokens = result.delimited.tokens
    assert.equal(tokens[3].prefix, 3)
    assert.equal(tokens[4].prefix, 1)
    assert.equal(tokens[4].close, {
        {
            literal = ']',
        },
        {
            capture = true,
        },
        {
            literal = ']',
        },
    })

    local open = result.delimited.open
    for _, case in ipairs({
        {
            '[[',
            4,
            3,
        },
        {
            '[==[ x',
            4,
            5,
        },
        {
            '--[[',
            3,
            5,
        },
        {
            '--[=[',
            3,
            6,
        },
    }) do
        assert.equal({
            dfa.longest(open, case[1], 1),
        }, {
            case[2],
            case[3],
        })
    end
    for _, s in ipairs({
        '[=',
        '[x',
        '--',
        'x[[',
    }) do
        assert.equal({
            dfa.longest(open, s, 1),
        }, {})
    end

    assert.equal(extract_capture(tokens[4], '[==[ x ]==]', 1), '==')
    assert.equal(extract_capture(tokens[3], 'a --[=[', 3), '=')
    assert.equal(extract_capture(tokens[4], '[[', 1), '')
end

function testcase.build_compiles_delimited_tokens_with_captures_at_the_ends()
    local result, diagnostics = lexer.build(grammar({
        heredoc = {
            open = '"<<" tag',
            close = '"\\n" tag',
            tag = 'ALPHA+',
        },
        quoted = {
            open = 'q "{"',
            close = '"}" q',
            q = '"q" DIGIT?',
        },
    }))

    assert.equal(diagnostics, {})
    assert.equal(result.delimited.tokens[1].prefix, 2)
    assert.equal(result.delimited.tokens[2].prefix, 0)
    assert.equal(extract_capture(result.delimited.tokens[1], '<<EOF\n', 1),
                 'EOF')
    assert.equal(extract_capture(result.delimited.tokens[2], 'q7{', 1), 'q7')
    assert.equal({
        dfa.longest(result.delimited.open, '<<EOF', 1),
    }, {
        1,
        6,
    })
end

-- a diagnostic with segments and pos
local function at(code, segments, pos, message)
    return {
        severity = 'error',
        code = code,
        segments = segments,
        pos = pos,
        message = message,
    }
end

function testcase.build_reports_invalid_delimiters()
    local result, diagnostics = lexer.build(grammar({
        twice = {
            open = 'a "x" a',
            close = 'a',
            a = '"a"',
        },
        nested = {
            open = '"x" (a | "y")',
            close = '"x"',
            a = '"a"',
        },
        two = {
            open = 'a b',
            close = '"x"',
            a = '"a"',
            b = '"b"',
        },
        variable = {
            open = '"x"+ a',
            close = '"y"',
            a = '"a"',
        },
        bad_close = {
            open = '"x" a',
            close = '"]" (a | "z") "]"*',
            a = '"a"',
        },
        foreign = {
            open = '"x"',
            close = '"y" b',
            b = '"b"',
        },
        unused = {
            open = '"u" a',
            close = '"v"',
            a = '"a"',
            extra = '"e"',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('invalid_delimiter', {
            'tokens',
            'bad_close',
            'close',
        }, 6, 'tokens.bad_close.close may contain only literals and captures'),
        at('invalid_delimiter', {
            'tokens',
            'bad_close',
            'close',
        }, 15, 'tokens.bad_close.close may contain only literals and captures'),
        at('invalid_delimiter', {
            'tokens',
            'foreign',
            'close',
        }, 5,
           'tokens.foreign.close refers to capture "b", which open does not capture'),
        at('invalid_delimiter', {
            'tokens',
            'foreign',
            'b',
        }, nil,
           'tokens.foreign.b is a capture definition that open does not use'),
        at('invalid_delimiter', {
            'tokens',
            'nested',
            'open',
        }, 6, 'tokens.nested.open must refer to capture "a" as an item of' ..
               ' its top-level sequence'),
        at('invalid_delimiter', {
            'tokens',
            'twice',
            'open',
        }, 7, 'tokens.twice.open may refer to only one capture, but refers' ..
               ' to "a" again'),
        at('invalid_delimiter', {
            'tokens',
            'two',
            'open',
        }, 3, 'tokens.two.open may refer to only one capture, but refers' ..
               ' to "b" again'),
        at('invalid_delimiter', {
            'tokens',
            'unused',
            'extra',
        }, nil,
           'tokens.unused.extra is a capture definition that open does not use'),
        at('invalid_delimiter', {
            'tokens',
            'variable',
            'open',
        }, 1, 'tokens.variable.open must have a fixed length before capture "a"'),
    })
end

function testcase.build_checks_fixed_length_with_code_point_classes()
    local result, diagnostics = lexer.build(grammar({
        mixed = {
            open = '[a\\u{e9}] a',
            close = '"x"',
            a = '"a"',
        },
        same = {
            open = '[\\u{e9}-\\u{ff}] _two a',
            close = '"y" a',
            a = '"!"',
        },
        _two = '[\\u{100}-\\u{7ff}] | "ab"',
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('invalid_delimiter', {
            'tokens',
            'mixed',
            'open',
        }, 1, 'tokens.mixed.open must have a fixed length before capture "a"'),
    })

    result, diagnostics = lexer.build(grammar({
        same = {
            open = '[\\u{e9}-\\u{ff}] _two a',
            close = '"y" a',
            a = '"!"',
        },
        three = {
            open = '[\\u{3042}-\\u{3093}] _two _two a',
            close = '"z" a',
            a = '"?"',
        },
        four = {
            open = '[\\u{10000}-\\u{10FFFF}]? "abcd" a',
            close = '"w" a',
            a = '"#"',
        },
        _two = '[\\u{100}-\\u{7ff}] | "ab"',
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('invalid_delimiter', {
            'tokens',
            'four',
            'open',
        }, 1, 'tokens.four.open must have a fixed length before capture "a"'),
    })

    result, diagnostics = lexer.build(grammar({
        same = {
            open = '[\\u{e9}-\\u{ff}] _two a',
            close = '"y" a',
            a = '"!"',
        },
        three = {
            open = '[\\u{3042}-\\u{3093}] _two _two a',
            close = '"z" a',
            a = '"?"',
        },
        four = {
            open = '[\\u{10000}-\\u{10FFFF}] a',
            close = '"w" a',
            a = '"#"',
        },
        _two = '[\\u{100}-\\u{7ff}] | "ab"',
    }))
    assert.equal(diagnostics, {})
    assert.equal(result.delimited.tokens[1].prefix, 4)
    assert.equal(result.delimited.tokens[2].prefix, 4)
    assert.equal(result.delimited.tokens[3].prefix, 7)
end

function testcase.build_reports_empty_delimiters()
    local result, diagnostics = lexer.build(grammar({
        empty_open = {
            open = '"x"?',
            close = '"y"',
        },
        empty_close = {
            open = '"[" level "["',
            close = 'level',
            level = '"="*',
        },
        -- a capture definition may match the empty string
        fine = {
            open = '"<" level "<"',
            close = '">" level ">"',
            level = '"="*',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'empty_match',
            segments = {
                'tokens',
                'empty_close',
                'close',
            },
            message = 'tokens.empty_close.close matches the empty string',
        },
        {
            severity = 'error',
            code = 'empty_match',
            segments = {
                'tokens',
                'empty_open',
                'open',
            },
            message = 'tokens.empty_open.open matches the empty string',
        },
    })
end

function testcase.build_reports_capture_overlap()
    local result, diagnostics = lexer.build(grammar({
        same = {
            open = '"[" level "="',
            close = '"]"',
            level = '"="*',
        },
        choice = {
            open = '"(" level ("=" | "[")',
            close = '")"',
            level = '"="*',
        },
        -- the item after the capture is optional, so the next one counts
        skip = {
            open = '"{" level "!"? "="',
            close = '"}"',
            level = '"="*',
        },
        fine = {
            open = '"<" level "<"',
            close = '">"',
            level = '"="*',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('capture_overlap', {
            'tokens',
            'choice',
            'open',
        }, 5, 'tokens.choice.open: capture "level" can continue with a byte' ..
               ' that can start the rest of open, e.g. "="'),
        at('capture_overlap', {
            'tokens',
            'same',
            'open',
        }, 5, 'tokens.same.open: capture "level" can continue with a byte' ..
               ' that can start the rest of open, e.g. "="'),
        at('capture_overlap', {
            'tokens',
            'skip',
            'open',
        }, 5, 'tokens.skip.open: capture "level" can continue with a byte' ..
               ' that can start the rest of open, e.g. "="'),
    })
end

function testcase.build_reports_delimiter_conflicts()
    local result, diagnostics = lexer.build(grammar({
        long = lua_long(''),
        short = {
            open = '"[["',
            close = '"]]"',
        },
        other = {
            open = '"<"',
            close = '">"',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'delimiter_conflict',
            segments = {
                'tokens',
                'short',
                'open',
            },
            message = 'tokens.short.open can match the same string as' ..
                ' tokens.long.open, e.g. "[["',
        },
    })
end

function testcase.build_allows_delimited_tokens_overlapping_other_tokens()
    local result, diagnostics = lexer.build(grammar({
        long = lua_long(''),
        bracket = '"[" "["?',
    }, {
        '[[',
    }))

    assert.equal(diagnostics, {})
    assert.is_table(result)
end

function testcase.build_reports_delimited_too_large()
    local result, diagnostics = without_hook(lexer.build, grammar({
        t = {
            open = '"x" c',
            close = '"y"',
            c = '("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 16),
        },
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 50000 states'),
    })

    -- the open automaton alone is too large
    result, diagnostics = without_hook(lexer.build, grammar({
        t = {
            open = '("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 16),
            close = '"y"',
        },
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 50000 states'),
    })

    -- the NFA of a capture definition is too large
    local tokens = {
        t = {
            open = '"x" c',
            close = '"y"',
            c = '_f20',
        },
        _f1 = '"x"',
    }
    for i = 2, 20 do
        tokens['_f' .. i] = '_f' .. (i - 1) .. ' _f' .. (i - 1)
    end
    result, diagnostics = without_hook(lexer.build, grammar(tokens))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the automaton would have more than 200000 states'),
    })

    -- the rest of open after the capture is too large
    result, diagnostics = without_hook(lexer.build, grammar({
        t = {
            open = '"x" c "y"',
            close = '"y"',
            c = '"c"',
        },
        u = {
            open = '"u" c ("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 16),
            close = '"y"',
            c = '"c"',
        },
    }))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 50000 states'),
    })
end
