local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local tokenizer = require('lexogram.tokenizer')

-- a grammar from fields, with a chunk of any tokens
local function grammar(fields)
    local g = {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {},
        rules = {
            chunk = 'name*',
        },
    }
    for k, v in pairs(fields) do
        g[k] = v
    end
    return g
end

-- compile fields; it must have no errors
local function compiled_of(fields)
    local compiled, diagnostics = lexogram.compile(grammar(fields))
    for _, d in ipairs(diagnostics) do
        assert.not_equal(d.severity, 'error')
    end
    return assert(compiled)
end

-- tokenize source completely, through input (an input of source, see
-- lexogram.input) when given; each token is "name:text"
local function lex(compiled, source, input)
    local out = {}
    local pos = 1
    while true do
        local kind, stop = tokenizer.tokenize(compiled, input or source, pos)
        if not kind then
            return out
        end
        out[#out + 1] = compiled.kinds[kind].name .. ':' ..
                            source:sub(pos, stop - 1)
        pos = stop
    end
end

-- the codes of the error diagnostics of fields
local function error_codes(fields)
    local codes = {}
    for _, d in ipairs(lexogram.check(grammar(fields))) do
        if d.severity == 'error' then
            codes[#codes + 1] = d.code
        end
    end
    return codes
end

function testcase.a_number_must_not_touch_a_letter()
    local compiled = compiled_of({
        tokens = {
            number = '[0-9]+ (?![0-9A-Za-z_.])',
            name = '[a-z]+',
            space = '" "+',
        },
        rules = {
            chunk = '(name | number)*',
        },
        skip = {
            'space',
        },
    })
    assert.is_table(compiled.lexer.dispatch)
    assert.equal(compiled.lexer.predicates[1].distance, 1)
    assert.equal(lex(compiled, '12 ab'), {
        'number:12',
        'space: ',
        'name:ab',
    })
    -- no length of 12ab is a number: the digit is INVALID
    assert.equal(lex(compiled, '12ab'), {
        'INVALID:1',
        'INVALID:2',
        'name:ab',
    })
    assert.is_nil(lexogram.parse(compiled, '12ab'))
    assert.is_table(lexogram.parse(compiled, '12 ab'))
end

function testcase.lookaheads_without_a_bound_are_computed_once_per_input()
    local compiled = compiled_of({
        tokens = {
            -- the conditions complement each other: two tokens that can
            -- match the same string under consistent conditions conflict
            a = '"a" (?="a"* "b")',
            b = '"b"',
            x = '"a" (?!"a"* "b")',
        },
        rules = {
            chunk = '(a | b | x)*',
        },
    })
    assert.is_false(compiled.lexer.predicates[1].distance)
    -- an a is a only when a b comes after the a's that follow it
    local input = lexogram.input('aaab')
    assert.equal(lex(compiled, 'aaab', input), {
        'a:a',
        'a:a',
        'a:a',
        'b:b',
    })
    -- the values of the whole input were computed once, and are kept in
    -- the input, which holds its source
    local values = input.values[1]
    assert.equal(#values, #'aaab' + 1)
    lex(compiled, 'aaab', input)
    assert.rawequal(input.values[1], values)
    assert.equal(input.source, 'aaab')
    assert.equal(lex(compiled, 'aaa', lexogram.input('aaa')), {
        'x:a',
        'x:a',
        'x:a',
    })
    -- with a string, each call computes what it needs
    assert.equal(lex(compiled, 'aab'), {
        'a:a',
        'a:a',
        'b:b',
    })
    -- an input is made of a string; tokenize takes a string or an input
    assert.match(select(2, pcall(lexogram.input, 1)),
                 'source must be string, got number', true)
    assert.match(select(2, pcall(tokenizer.tokenize, compiled, {
        source = 'a',
    }, 1)), 'source must be string or input, got table', true)
end

-- the ids of the predicates without a bound of compiled
local function unbounded_predicates(compiled)
    local ids = {}
    for p, entry in ipairs(compiled.lexer.predicates) do
        if entry.distance == false then
            ids[#ids + 1] = p
        end
    end
    assert.greater(#ids, 0)
    return ids
end

function testcase.lookaheads_without_a_bound_are_evaluated_where_needed()
    -- a line break is a space unless "#" and a number follow it
    local compiled = compiled_of({
        tokens = {
            space = '(" " | "\\n" (?!"#" " "* [0-9]))+',
            directive = '"\\n#" " "* [0-9]+',
            name = '[a-z]+',
            hash = '"#"',
        },
        rules = {
            chunk = '(name | hash | directive)*',
        },
        skip = {
            'space',
        },
    })
    local source = ('abcdefgh\n'):rep(50) .. '#x\n#  12\nend'
    local tokens = lex(compiled, source)
    assert.equal(tokens[#tokens - 4], 'hash:#')
    assert.equal(tokens[#tokens - 2], 'directive:\n#  12')
    -- after each line break the scan reads a byte or a few: far less than
    -- the input, so the values of the whole input are not computed
    local input = lexogram.input(source)
    assert.equal(lex(compiled, source, input), tokens)
    for _, p in ipairs(unbounded_predicates(compiled)) do
        assert.is_nil(input.values[p])
        assert.less(input.read[p], #source)
    end
end

function testcase.lookaheads_without_a_bound_are_computed_when_they_read_much()
    local compiled = compiled_of({
        tokens = {
            a = '"a" (?="a"* "b")',
            b = '"b"',
            x = '"a" (?!"a"* "b")',
        },
        rules = {
            chunk = '(a | b | x)*',
        },
    })
    -- each a reads up to the b: the scans would read about the square of
    -- the length, so the values of the whole input are computed once
    local source = ('a'):rep(100) .. 'b' .. ('a'):rep(100)
    local tokens = lex(compiled, source)
    assert.equal(tokens[1], 'a:a')
    assert.equal(tokens[101], 'b:b')
    assert.equal(tokens[102], 'x:a')
    local input = lexogram.input(source)
    assert.equal(lex(compiled, source, input), tokens)
    for _, p in ipairs(unbounded_predicates(compiled)) do
        assert.equal(#input.values[p], #source + 1)
        assert.less_or_equal(input.read[p], #source + 1)
    end
end

function testcase.lookaheads_at_the_start_and_nested_without_a_bound()
    local compiled = compiled_of({
        tokens = {
            -- the start state of the automaton dispatches
            word = '(?![0-9]) [d-z0-9]+',
            number = '[0-9]+',
            -- the backward automaton dispatches on the nested predicate
            a = '"a" (?="a"* "b" (?!"c"))',
            x = '"a" (?!"a"* "b" (?!"c"))',
            b = '"b"',
            c = '"c"',
        },
        rules = {
            chunk = '(word | number | a | x | b | c)*',
        },
    })
    assert.equal(lex(compiled, '1x'), {
        'number:1',
        'word:x',
    })
    assert.equal(lex(compiled, 'aab', lexogram.input('aab')), {
        'a:a',
        'a:a',
        'b:b',
    })
    assert.equal(lex(compiled, 'aabc', lexogram.input('aabc')), {
        'x:a',
        'x:a',
        'b:b',
        'c:c',
    })
end

function testcase.leading_tokens_and_nested_lookaheads()
    local compiled = compiled_of({
        tokens = {
            shebang = '"#" (?!"!") [^\\n]*',
            name = '[a-z]+ (?="." (?![a-z]))',
            word = '[a-z]+ (?!"." (?![a-z]))',
            dot = '"."',
        },
        leading = {
            'shebang',
        },
        skip = {
            'shebang',
        },
        rules = {
            chunk = '(name | word | dot)*',
        },
    })
    assert.equal(lex(compiled, '#x'), {
        'shebang:#x',
    })
    assert.equal(lex(compiled, '#!x'), {
        'INVALID:#',
        'INVALID:!',
        'word:x',
    })
    -- a name is a word followed by a dot that is not followed by a letter
    assert.equal(lex(compiled, 'ab.cd.'), {
        'word:ab',
        'dot:.',
        'name:cd',
        'dot:.',
    })
end

function testcase.conflicts_count_only_consistent_lookaheads()
    -- a token and the same token under a condition conflict where the
    -- condition holds
    assert.equal(error_codes({
        tokens = {
            a = '"a" (?="b")',
            x = '"a"',
        },
        rules = {
            chunk = '(a | x)*',
        },
    }), {
        'token_conflict',
    })
    -- "a" cannot be followed by both "b" and "c"
    assert.equal(error_codes({
        tokens = {
            ab = '"a" (?="b")',
            ac = '"a" (?="c")',
        },
        rules = {
            chunk = '(ab | ac)*',
        },
    }), {})
    -- but by "b" and by one of "b" or "c"
    local diagnostics = lexogram.check(grammar({
        tokens = {
            ab = '"a" (?="b")',
            ax = '"a" (?=[bc])',
        },
        rules = {
            chunk = '(ab | ax)*',
        },
    }))
    assert.equal(#diagnostics, 1)
    assert.equal(diagnostics[1].code, 'token_conflict')
    assert.equal(diagnostics[1].message, 'tokens.ax can match the same' ..
                     ' string as tokens.ab, e.g. "a"')
    -- a token that matches the empty string where its lookahead holds
    assert.equal(error_codes({
        tokens = {
            name = '(?="x") "y"?',
        },
    }), {
        'empty_match',
    })
    assert.equal(error_codes({
        tokens = {
            name = '(?="a") (?="b") "y"?',
            word = '[a-z]+',
        },
        rules = {
            chunk = 'word*',
        },
    }), {})
end

function testcase.lookaheads_are_not_allowed_in_rules_and_delimited_tokens()
    local diagnostics = lexogram.check(grammar({
        tokens = {
            name = '[a-z]+',
            _end = '(?!"x")',
            str = {
                open = '"\\"" _end',
                close = '"\\""',
            },
            com = {
                open = '"("',
                close = '")" (?=" ")',
            },
        },
        rules = {
            chunk = 'name* (?=name)',
        },
    }))
    local found = {}
    for _, d in ipairs(diagnostics) do
        found[#found + 1] = {
            d.code,
            d.path,
            d.pos,
        }
    end
    assert.equal(found, {
        {
            'lookahead_not_allowed',
            'rules.chunk',
            7,
        },
    })
    -- the rules pass stops the check; without it the tokens are checked
    diagnostics = lexogram.check(grammar({
        tokens = {
            name = '[a-z]+',
            _end = '_end2',
            _end2 = '(?!"x")',
            str = {
                open = '"\\"" _end',
                close = '"\\""',
            },
            com = {
                open = '"("',
                close = '")" (?=" ")',
            },
        },
    }))
    found = {}
    for _, d in ipairs(diagnostics) do
        if d.severity == 'error' then
            found[#found + 1] = {
                d.code,
                d.path,
                d.pos,
                d.message,
            }
        end
    end
    assert.equal(found, {
        {
            'lookahead_not_allowed',
            'tokens.com.close',
            5,
            'tokens.com.close: a lookahead is not allowed in a delimited' ..
                ' token table',
        },
        {
            'lookahead_not_allowed',
            'tokens.str.open',
            6,
            'tokens.str.open: a lookahead is not allowed in a delimited' ..
                ' token table (through _end)',
        },
    })
    -- the prefix of a prefixed table
    assert.equal(error_codes({
        tokens = {
            name = '[a-z]+',
            str = {
                open = '"\\""',
                close = '"\\""',
            },
            raw = {
                prefix = '(?!"x") "r"',
                match = {
                    'str',
                },
            },
        },
    }), {
        'lookahead_not_allowed',
    })
end
