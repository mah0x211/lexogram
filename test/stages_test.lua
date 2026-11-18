local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local tokenizer = require('lexogram.tokenizer')
local extend = require('lexogram.extend').extend

-- a grammar from fields, with a chunk of numbers ended by ";"
local function grammar(fields)
    local g = {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {},
        symbols = {
            ';',
        },
        skip = {
            'space',
        },
        rules = {
            chunk = '(number ";")*',
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

-- the results of tokenize at the start of source, as an array
local function first_token(compiled, source)
    return {
        tokenizer.tokenize(compiled, source, 1),
    }
end

-- the error of parsing source, as "code pos: message", or "ok"
local function parse_error(compiled, source)
    local result, err = lexogram.parse(compiled, source)
    if result then
        return 'ok'
    end
    return err.code .. ' ' .. err.pos .. ': ' .. err.message
end

-- the error diagnostics of fields, as "code path: message"
local function errors_of(fields)
    local out = {}
    for _, d in ipairs(lexogram.check(grammar(fields))) do
        if d.severity == 'error' then
            out[#out + 1] = d.code .. ' ' .. d.path .. ': ' .. d.message
        end
    end
    return out
end

-- a number of at most three digits, after the leading zeros and with "_"
-- between them, that has no digit 5
local NUMBER = {
    '[0-9] [0-9_]* (?![0-9A-Za-z_])',
    '("0" "_"*)* ([1-9] "_"* ([0-9] "_"*){0,2})?',
    '[^5]+',
}

function testcase.later_patterns_check_the_whole_text_of_the_token()
    local compiled = compiled_of({
        tokens = {
            space = '" "+',
            number = NUMBER,
        },
    })
    -- the first pattern gives the kind and the end; the others must match
    local number = compiled.names.number
    assert.equal(first_token(compiled, '1_2_3;'), {
        number,
        6,
    })
    assert.equal(first_token(compiled, '0001;'), {
        number,
        5,
    })
    -- four digits fail the second pattern
    assert.equal(first_token(compiled, '1_000;'), {
        number,
        6,
        'invalid',
        2,
    })
    -- a digit 5 fails the third pattern; the first failure is reported
    assert.equal(first_token(compiled, '15;'), {
        number,
        3,
        'invalid',
        3,
    })
    assert.equal(first_token(compiled, '5555;'), {
        number,
        5,
        'invalid',
        2,
    })
    assert.equal(parse_error(compiled, '1; 999;'), 'ok')
    assert.equal(parse_error(compiled, '1; 1000;'),
                 'invalid_token 4: invalid number')
end

function testcase.a_lookahead_in_a_check_sees_only_the_token()
    local compiled = compiled_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                -- the end of the token is the end of its input
                '[0-9]* "1" (?![0-9;])',
            },
        },
    })
    assert.is_table(compiled.lexer.predicates)
    assert.equal(parse_error(compiled, '1; 21;'), 'ok')
    assert.equal(parse_error(compiled, '12;'), 'invalid_token 1: invalid number')
    -- the check reads the text only: the input after it does not count
    compiled = compiled_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                '"1" (?=[0-9]) [0-9]+',
            },
        },
    })
    assert.equal(first_token(compiled, '12;'), {
        compiled.names.number,
        3,
    })
    assert.equal(first_token(compiled, '1;'), {
        compiled.names.number,
        2,
        'invalid',
        2,
    })
    -- a lookahead that fails in the middle of the text
    compiled = compiled_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                '"1" (?="2") [0-9]+',
            },
        },
    })
    assert.equal(first_token(compiled, '13;'), {
        compiled.names.number,
        3,
        'invalid',
        2,
    })
end

function testcase.skipped_and_leading_tokens_are_checked()
    local compiled = compiled_of({
        tokens = {
            space = {
                '" "+',
                '" " " "?',
            },
            mark = {
                '"#" [a-z]*',
                '"#" [a-z]{0,2}',
            },
            number = '[0-9]+',
        },
        leading = {
            'mark',
        },
        skip = {
            'space',
            'mark',
        },
    })
    assert.equal(parse_error(compiled, '#ab 1;  2;'), 'ok')
    assert.equal(parse_error(compiled, '1;   2;'),
                 'invalid_token 3: invalid space')
    assert.equal(parse_error(compiled, '#abc 1;'),
                 'invalid_token 1: invalid mark')
end

function testcase.an_array_of_one_pattern_is_the_pattern()
    local array = compiled_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
            },
        },
    })
    local string = compiled_of({
        tokens = {
            space = '" "+',
            number = '[0-9]+',
        },
    })
    assert.is_nil(array.lexer.checks)
    assert.equal(array, string)
end

function testcase.the_checks_are_automata_by_kind()
    local compiled = compiled_of({
        tokens = {
            space = '" "+',
            number = NUMBER,
        },
    })
    local checks = compiled.lexer.checks
    local count = 0
    for id, list in pairs(checks) do
        count = count + 1
        assert.equal(id, compiled.names.number)
        assert.equal(#list, 2)
        for _, a in ipairs(list) do
            assert.is_number(a.nstates)
            assert.is_table(a.trans)
        end
    end
    assert.equal(count, 1)
end

function testcase.conflicts_are_checked_with_the_first_pattern()
    -- the checks exclude each other, but the first patterns are the same
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                '"1"+',
            },
            other = {
                '[0-9]+',
                '"2"+',
            },
        },
        rules = {
            chunk = '((number | other) ";")*',
        },
    }), {
        'token_conflict tokens.other: tokens.other can match the same' ..
            ' string as tokens.number, e.g. "0"',
    })
end

function testcase.the_array_is_checked()
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                1,
                x = '"a"',
            },
        },
    }), {
        'invalid_type tokens.number[2]: tokens.number[2] must be string, got' ..
            ' number',
        'unknown_field tokens.number.x: unknown field tokens.number.x (a' ..
            ' token written as an array of patterns has no fields)',
    })
    -- each pattern is parsed and checked where it is
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                '"(',
                '_none',
            },
        },
    }), {
        'unterminated_literal tokens.number[2]: literal is not terminated',
        'undefined_reference tokens.number[3]: tokens.number[3] refers to' ..
            ' undefined fragment "_none"',
    })
    -- a table with a key of a delimited token table is one
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            number = '[0-9]+',
            block = {
                '"x"',
                open = '"[["',
                close = '"]]"',
            },
        },
    }), {
        'invalid_key tokens.block[1]: key tokens.block[1] must be string',
    })
end

function testcase.an_array_is_no_delimited_token()
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
            },
            prefixed = {
                prefix = '"u"',
                match = {
                    'number',
                },
            },
        },
    }), {
        'invalid_reference tokens.prefixed.match[1]:' ..
            ' tokens.prefixed.match[1] refers to "number", which is not a' ..
            ' delimited token table with open and close',
    })
end

function testcase.a_check_must_match_a_non_empty_string()
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                '(?="1")',
            },
        },
    }), {
        'unmatchable_pattern tokens.number[2]: tokens.number[2] matches no' ..
            ' non-empty string, so every token of tokens.number fails it',
    })
end

function testcase.marks_change_the_array()
    local base = grammar({
        tokens = {
            space = '" "+',
            number = {
                '[0-9]+',
                '[0-9]{1,3}',
            },
        },
    })
    local added = assert(extend(base, {
        tokens = {
            ['+number'] = {
                '[^5]+',
            },
        },
    }))
    assert.equal(added.tokens.number, {
        '[0-9]+',
        '[0-9]{1,3}',
        '[^5]+',
    })
    local removed = assert(extend(base, {
        tokens = {
            ['-number'] = {
                '[0-9]{1,3}',
            },
        },
    }))
    assert.equal(removed.tokens.number, {
        '[0-9]+',
    })
    -- a pattern string is not an array
    local grammar_, err = extend(base, {
        tokens = {
            ['+space'] = {
                '" "',
            },
        },
    })
    assert.is_nil(grammar_)
    assert.match(err, 'tokens.space', false)
end

-- numbers of two forms, each with its limit: at most three decimal digits
-- with an exponent of one digit, or at most two hexadecimal digits
local FORMS = {
    space = '" "+',
    _dec = {
        '[0-9]+',
        '[0-9]{1,3}',
    },
    _exp = {
        '"e" [0-9]+',
        '"e" [0-9]',
    },
    _hex = {
        '"0x" [0-9a-f]+',
        '"0x" [0-9a-f]{1,2}',
    },
    number = '(_hex | _dec _exp?) (?![0-9a-z])',
}

function testcase.a_fragment_written_as_an_array_matches_all_its_patterns()
    local compiled = compiled_of({
        tokens = FORMS,
    })
    local number = compiled.names.number
    -- the first patterns choose the token; the others check it
    for _, source in ipairs({
        '123;',
        '0xff;',
        '12e3;',
    }) do
        assert.equal(first_token(compiled, source), {
            number,
            #source,
        })
    end
    for _, source in ipairs({
        '1234;',
        '0xfff;',
        '12e34;',
        '1234e3;',
    }) do
        assert.equal(first_token(compiled, source), {
            number,
            #source,
            'invalid',
            1,
        })
    end
    assert.equal(parse_error(compiled, '1; 0x1f; 9e9;'), 'ok')
    assert.equal(parse_error(compiled, '1; 0x1ff;'),
                 'invalid_token 4: invalid number')
    -- the check of the first pattern is first in the checks of the kind
    local checks = compiled.lexer.checks[number]
    assert.is_table(checks.first)
    assert.equal(#checks, 0)
end

function testcase.fragments_written_as_arrays_nest_and_are_reached_through_others()
    local compiled = compiled_of({
        tokens = {
            space = '" "+',
            _width = {
                '[0-9]+',
                '[0-9]{1,4}',
            },
            -- at most four digits, without a leading zero; it is built
            -- after _width, which it refers to and which comes later by name
            _digits = {
                '_width',
                '[1-9] [0-9]*',
            },
            _plain = '_digits',
            number = '_plain (?![0-9])',
        },
    })
    assert.equal(parse_error(compiled, '12; 9999;'), 'ok')
    assert.equal(parse_error(compiled, '012;'),
                 'invalid_token 1: invalid number')
    assert.equal(parse_error(compiled, '12345;'),
                 'invalid_token 1: invalid number')
end

function testcase.checks_and_lookaheads_match_the_intersection()
    -- a later pattern of a token
    local compiled = compiled_of({
        tokens = {
            space = '" "+',
            _two = {
                '[0-9]+',
                '[0-9]{1,2}',
            },
            number = {
                '[0-9]+',
                '_two',
            },
        },
    })
    assert.equal(first_token(compiled, '123;'), {
        compiled.names.number,
        4,
        'invalid',
        2,
    })
    -- the body of a lookahead
    compiled = compiled_of({
        tokens = {
            space = '" "+',
            _two = {
                '[0-9]+',
                '[0-9]{1,2}',
            },
            number = '"#" (?=_two ";") [0-9]+',
        },
    })
    assert.equal(parse_error(compiled, '#12;'), 'ok')
    assert.equal(first_token(compiled, '#123;'), {
        1,
        2,
    })
    -- the check of the first pattern comes before the later patterns
    compiled = compiled_of({
        tokens = {
            space = '" "+',
            _two = {
                '[0-9]+',
                '[0-9]{1,2}',
            },
            number = {
                '_two',
                '[0-8]+',
            },
        },
    })
    assert.equal(first_token(compiled, '999;'), {
        compiled.names.number,
        4,
        'invalid',
        1,
    })
    assert.equal(first_token(compiled, '99;'), {
        compiled.names.number,
        3,
        'invalid',
        2,
    })
end

function testcase.a_token_without_such_fragments_has_no_check()
    local compiled = compiled_of({
        tokens = {
            space = '" "+',
            _d = '[0-9]',
            number = '_d+',
        },
    })
    assert.is_nil(compiled.lexer.checks)
end

function testcase.fragments_written_as_arrays_are_checked()
    -- no lookahead, also through another fragment
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            _g = '"a" (?="b")',
            _f = {
                '[0-9]+ ("x" (?!"y"))?',
                '[0-9]+ _g?',
            },
            number = '_f',
        },
    }), {
        'lookahead_not_allowed tokens._f[1]: tokens._f[1]: a lookahead is' ..
            ' not allowed in a fragment written as an array of patterns',
        'lookahead_not_allowed tokens._f[2]: tokens._f[2]: a lookahead is' ..
            ' not allowed in a fragment written as an array of patterns' ..
            ' (through _g)',
    })
    -- a fragment that no string matches is reported by itself
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            _f = {
                '[0-9]+',
                '[a-z]+',
            },
            number = '_f',
        },
    }), {
        'unmatchable_pattern tokens._f: tokens._f matches no non-empty' ..
            ' string: no string matches all its patterns',
    })
    -- not in a delimited token table
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            _f = {
                '[0-9]+',
                '[0-9]',
            },
            number = '[0-9]+',
            str = {
                open = '"<" _f',
                close = '">"',
            },
        },
    }), {
        'invalid_reference tokens.str.open: tokens.str.open: a fragment' ..
            ' written as an array of patterns is not allowed in a delimited' ..
            ' token table (through _f)',
    })
    -- cycles go through every pattern
    assert.equal(errors_of({
        tokens = {
            space = '" "+',
            _f = {
                '[0-9]+',
                '_g',
            },
            _g = '_f',
            number = '_f',
        },
    }), {
        'fragment_recursion tokens._f: fragment _f is recursive: _f -> _g ->' ..
            ' _f',
    })
end
