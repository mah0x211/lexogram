local testcase = require('testcase')
local assert = require('assert')
local lexer = require('lexogram.compile.lexer')
local dfa = require('lexogram.compile.dfa')

-- a grammar with the given tokens, symbols and keywords (the lexer reads
-- only these fields)
local function grammar(tokens, symbols, keywords)
    return {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
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
            kind = 'reserved',
            name = 'INVALID',
        },
        {
            id = 2,
            kind = 'reserved',
            name = 'ERROR',
        },
        {
            id = 3,
            kind = 'token',
            name = 'id',
            segments = {
                'tokens',
                'id',
            },
        },
        {
            id = 4,
            kind = 'token',
            name = 'num',
            segments = {
                'tokens',
                'num',
            },
        },
        {
            id = 5,
            kind = 'symbol',
            name = '+',
            segments = {
                'symbols',
                1,
            },
        },
        {
            id = 6,
            kind = 'symbol',
            name = '-',
            segments = {
                'symbols',
                2,
            },
        },
        {
            id = 7,
            kind = 'keyword',
            name = 'if',
            segments = {
                'keywords',
                1,
            },
        },
        {
            id = 8,
            kind = 'delimited',
            name = 'str',
            segments = {
                'tokens',
                'str',
            },
        },
    })
    assert.equal(result.delimited.tokens, {
        [8] = {
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
            3,
            'ifx',
        },
        {
            5,
            '+',
        },
        {
            4,
            '12',
        },
        {
            6,
            '-',
        },
        {
            7,
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
    -- the DFA of the pattern tokens
    local result, diagnostics = lexer.build(grammar({
        t = '("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 4),
    }), {
        dfa_states = 8,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 8 states'),
    })

    -- the NFA of the pattern tokens
    result, diagnostics = lexer.build(grammar({
        t = '"abcdefgh"',
    }), {
        nfa_states = 5,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the automaton would have more than 5 states'),
    })
end

function testcase.build_reports_lookahead_automata_too_large()
    -- the DFA of a predicate; the token automaton is small
    local result, diagnostics = lexer.build(grammar({
        t = '"x" (?=("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 4) .. ')',
    }), {
        dfa_states = 8,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 8 states'),
    })

    -- the analysis of the lookaheads of the token automaton
    -- obligations made at different positions are at different states of
    -- the automaton of the predicate, so they add up
    local g = grammar({
        t = '("a" (?=[a-z][a-z][a-z] "q"))+',
    })
    result, diagnostics = lexer.build(g, {
        dfa_states = 6,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the analysis of the lookaheads would visit more than 6' ..
                ' configurations'),
    })

    -- and of the leading automaton
    g = grammar({
        x = '"x"',
        t = '("a" (?=[a-z][a-z][a-z] "q"))+',
    })
    g.leading = {
        't',
    }
    result, diagnostics = lexer.build(g, {
        dfa_states = 6,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the analysis of the lookaheads would visit more than 6' ..
                ' configurations'),
    })
end

function testcase.build_raises_for_invalid_limits()
    local g = grammar({
        t = '"t"',
    })
    local msg = assert.throws(lexer.build, g, 'x')
    assert.match(msg, 'limits must be table, got string')
    msg = assert.throws(lexer.build, g, {
        nfa_states = 0,
    })
    assert.match(msg, 'limits.nfa_states must be a positive integer, got 0')
    msg = assert.throws(lexer.build, g, {
        dfa_states = 2.5,
    })
    assert.match(msg, 'limits.dfa_states must be a positive integer, got 2.5')
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

-- leading tokens

function testcase.build_compiles_leading_tokens_apart()
    local g = grammar({
        name = 'ALPHA+',
        shebang = '"#" [^\\n]*',
        bom = '"\\xEF\\xBB\\xBF"',
    }, {
        '#',
    })
    g.leading = {
        'shebang',
        'bom',
    }
    local result, diagnostics = lexer.build(g)

    -- "#" and shebang would conflict if they were in one automaton
    assert.equal(diagnostics, {})
    -- ids: bom 3, name 4, shebang 5, "#" 6
    assert.equal(result.defs[3].leading, true)
    assert.is_nil(result.defs[4].leading)
    assert.equal(result.defs[5].leading, true)
    assert.equal({
        dfa.longest(result.leading, '#!/bin/lua\nx', 1),
    }, {
        5,
        11,
    })
    assert.equal({
        dfa.longest(result.leading, '\239\187\191x', 1),
    }, {
        3,
        4,
    })
    assert.equal({
        dfa.longest(result.leading, 'abc', 1),
    }, {})
    -- the other automaton has no leading token
    assert.equal({
        dfa.longest(result.dfa, '#!x', 1),
    }, {
        6,
        2,
    })

    -- without leading tokens there is no automaton for them
    result = lexer.build(grammar({
        name = 'ALPHA+',
    }))
    assert.is_nil(result.leading)
end

function testcase.build_checks_leading_tokens_among_themselves()
    local g = grammar({
        a = '"#" [a-z]*',
        b = '"#" [0-9]*',
        c = '"x" | "y"',
        e = '"z"*',
    })
    g.leading = {
        'a',
        'b',
        'e',
    }
    local result, diagnostics = lexer.build(g)

    assert.is_nil(result)
    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'empty_match',
            segments = {
                'tokens',
                'e',
            },
            message = 'tokens.e matches the empty string',
        },
        {
            severity = 'error',
            code = 'token_conflict',
            segments = {
                'tokens',
                'b',
            },
            message = 'tokens.b can match the same string as tokens.a,' ..
                ' e.g. "#"',
        },
    })

    -- a leading token may match what an ordinary token or a literal does
    g = grammar({
        name = 'ALPHA+',
        word = 'ALPHA+',
    }, {
        'abc',
    })
    g.leading = {
        'word',
    }
    result, diagnostics = lexer.build(g)
    assert.is_table(result)
    assert.equal(diagnostics, {})
end

function testcase.build_reports_leading_automaton_too_large()
    -- the DFA of the leading tokens; the other automaton is small
    local g = grammar({
        x = '"x"',
        t = '("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 4),
    })
    g.leading = {
        't',
    }
    local result, diagnostics = lexer.build(g, {
        dfa_states = 8,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the deterministic automaton would have more than 8 states'),
    })

    -- the NFA of the leading tokens
    g.tokens.t = '"abcdefgh"'
    result, diagnostics = lexer.build(g, {
        nfa_states = 5,
    })
    assert.is_nil(result)
    assert.equal(diagnostics, {
        err('automaton_too_large', {
            'tokens',
        }, 'the automaton would have more than 5 states'),
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
    assert.equal(result.defs[5], {
        id = 5,
        kind = 'delimited',
        name = 'long_comment',
        segments = {
            'tokens',
            'long_comment',
        },
    })
    assert.equal(result.defs[6].name, 'long_string')

    local tokens = result.delimited.tokens
    assert.equal(tokens[5].prefix, 3)
    assert.equal(tokens[6].prefix, 1)
    assert.equal(tokens[6].close, {
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

    -- the open automaton accepts the indexes of the entries, which are in
    -- kind id order
    assert.equal(result.delimited.entries, {
        {
            id = 5,
            token = tokens[5],
            inner = 1,
        },
        {
            id = 6,
            token = tokens[6],
            inner = 2,
        },
    })
    local open = result.delimited.open
    for _, case in ipairs({
        {
            '[[',
            2,
            3,
        },
        {
            '[==[ x',
            2,
            5,
        },
        {
            '--[[',
            1,
            5,
        },
        {
            '--[=[',
            1,
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

    assert.equal(extract_capture(tokens[6], '[==[ x ]==]', 1), '==')
    assert.equal(extract_capture(tokens[5], 'a --[=[', 3), '=')
    assert.equal(extract_capture(tokens[6], '[[', 1), '')
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
    assert.equal(result.delimited.tokens[3].prefix, 2)
    assert.equal(result.delimited.tokens[4].prefix, 0)
    assert.equal(extract_capture(result.delimited.tokens[3], '<<EOF\n', 1),
                 'EOF')
    assert.equal(extract_capture(result.delimited.tokens[4], 'q7{', 1), 'q7')
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
    assert.equal(result.delimited.tokens[3].prefix, 4)
    assert.equal(result.delimited.tokens[4].prefix, 4)
    assert.equal(result.delimited.tokens[5].prefix, 7)
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

-- the delimited token tables of Lua long brackets of level 0 and of the
-- levels with "=", and the long comment as a prefixed table naming both
local function lua_brackets(prefix)
    return {
        long_string = {
            open = '"[["',
            close = '"]]"',
            nest = 'error',
        },
        long_level = {
            open = '"[" level "["',
            close = '"]" level "]"',
            level = '"="+',
        },
        long_comment = {
            prefix = prefix,
            match = {
                'long_string',
                'long_level',
            },
        },
    }
end

function testcase.build_compiles_prefixed_delimited_tokens()
    local result, diagnostics = lexer.build(grammar(lua_brackets('"--"')))

    assert.equal(diagnostics, {})
    -- kind ids by name: long_comment 3, long_level 4, long_string 5; the
    -- entries of long_comment follow its match
    local entries = result.delimited.entries
    local summary = {}
    for i, entry in ipairs(entries) do
        summary[i] = {
            entry.id,
            entry.inner,
            entry.token.prefix,
            entry.token.nest,
        }
    end
    assert.equal(summary, {
        {
            3,
            4,
            nil,
            'error',
        },
        {
            3,
            3,
            3,
        },
        {
            4,
            3,
            1,
        },
        {
            5,
            4,
            nil,
            'error',
        },
    })
    -- the close of a named table is shared by the entry of the prefix
    assert.equal(entries[2].token.close, entries[3].token.close)
    assert.equal(extract_capture(entries[2].token, '--[==[', 1), '==')
    -- only the tables with open and close are in tokens
    assert.equal(result.delimited.tokens[3], nil)

    local open = result.delimited.open
    for _, case in ipairs({
        {
            '--[[',
            1,
            5,
        },
        {
            '--[=[',
            2,
            6,
        },
        {
            '[=[',
            3,
            4,
        },
        {
            '[[',
            4,
            3,
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
        '--',
        '--[',
        '---[[',
    }) do
        assert.equal({
            dfa.longest(open, s, 1),
        }, {})
    end
end

function testcase.build_allows_a_variable_prefix_without_captures()
    local tokens = lua_brackets('"-"+')
    tokens.long_comment.match[2] = nil
    local result, diagnostics = lexer.build(grammar(tokens))

    assert.equal(diagnostics, {})
    assert.equal({
        dfa.longest(result.delimited.open, '---[[', 1),
    }, {
        1,
        6,
    })
end

function testcase.build_reports_prefixed_table_problems()
    -- a prefix with a variable length before a capture
    local result, diagnostics = lexer.build(grammar(lua_brackets('"-"+')))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'invalid_delimiter',
            segments = {
                'tokens',
                'long_comment',
                'prefix',
            },
            message = 'tokens.long_comment.prefix must have a fixed length,' ..
                ' because tokens.long_level has a capture',
        },
    })

    -- a prefix that matches the empty string
    result, diagnostics = lexer.build(grammar(lua_brackets('"-"*')))
    assert.is_nil(result)
    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'empty_match',
            segments = {
                'tokens',
                'long_comment',
                'prefix',
            },
            message = 'tokens.long_comment.prefix matches the empty string',
        },
    })

    -- a named table with errors gives no entry and no other error
    local tokens = lua_brackets('"--"')
    tokens.long_level.close = '"]" "="* "]"'
    result, diagnostics = lexer.build(grammar(tokens))
    assert.is_nil(result)
    assert.equal(#diagnostics, 1)
    assert.equal(diagnostics[1].segments, {
        'tokens',
        'long_level',
        'close',
    })
end

function testcase.build_reports_prefixed_table_conflicts()
    local tokens = lua_brackets('"--"')
    tokens.other = {
        open = '"--[["',
        close = '"]]"',
    }
    -- a second table with the same open as long_string: its conflict is
    -- reported once, not again for the two entries of long_comment (the
    -- order is the order of the automaton states)
    tokens.square = {
        open = '"[["',
        close = '"]]"',
    }
    tokens.long_comment.match[3] = 'square'
    local result, diagnostics = lexer.build(grammar(tokens))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'delimiter_conflict',
            segments = {
                'tokens',
                'square',
                'open',
            },
            message = 'tokens.square.open can match the same string as' ..
                ' tokens.long_string.open, e.g. "[["',
        },
        {
            severity = 'error',
            code = 'delimiter_conflict',
            segments = {
                'tokens',
                'other',
                'open',
            },
            message = 'tokens.other.open can match the same string as' ..
                ' tokens.long_comment.prefix, e.g. "--[["',
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
    local blowup = '("a" | "b")* "a"' .. string.rep(' ("a" | "b")', 3)
    local long = '"' .. string.rep('x', 20) .. '"'
    for _, case in ipairs({
        -- the DFA and the NFA of a capture definition
        {
            {
                open = '"x" c',
                close = '"y"',
                c = blowup,
            },
            'dfa_states',
        },
        {
            {
                open = '"x" c',
                close = '"y"',
                c = long,
            },
            'nfa_states',
        },
        -- the DFA and the NFA of the rest of open after the capture
        {
            {
                open = '"x" c ' .. blowup,
                close = '"y"',
                c = '"c"',
            },
            'dfa_states',
        },
        {
            {
                open = '"x" c ' .. long,
                close = '"y"',
                c = '"c"',
            },
            'nfa_states',
        },
        -- the DFA and the NFA of the open automaton
        {
            {
                open = blowup,
                close = '"y"',
            },
            'dfa_states',
        },
        {
            {
                open = long,
                close = '"y"',
            },
            'nfa_states',
        },
    }) do
        local result, diagnostics = lexer.build(grammar({
            t = case[1],
        }), {
            [case[2]] = 10,
        })
        assert.is_nil(result)
        assert.equal(diagnostics, {
            err('automaton_too_large', {
                'tokens',
            }, case[2] == 'dfa_states' and
                    'the deterministic automaton would have more than 10 states' or
                    'the automaton would have more than 10 states'),
        })
    end
end
