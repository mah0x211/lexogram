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

function testcase.build_ignores_delimited_tokens()
    local result, diagnostics = lexer.build(grammar({
        comment = {
            open = '"/*"',
            close = '"*/"',
        },
        n = 'DIGIT+',
    }))

    assert.equal(diagnostics, {})
    assert.equal(#result.defs, 1)
    assert.equal(result.defs[1].name, 'n')
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
