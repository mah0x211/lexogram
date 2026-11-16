local testcase = require('testcase')
local assert = require('assert')
local check = require('lexogram.check')

-- a small valid grammar that uses every top-level field
local function valid_grammar()
    return {
        lexogram = '2026.11.15.1',
        start = 'expr',
        tokens = {
            number = '[0-9]+',
            comment = {
                open = '"/*"',
                close = '"*/"',
                body = '_text',
            },
        },
        symbols = {
            '+',
            '-',
            ignore_case = false,
        },
        keywords = {
            'if',
            'else',
            ignore_case = true,
        },
        skip = {
            'comment',
        },
        rules = {
            expr = 'number',
        },
        greedy = {
            'expr',
        },
        recover = {
            'expr',
        },
    }
end

-- valid_grammar with the given fields replaced
local function grammar_with(fields)
    local grammar = valid_grammar()
    for k, v in pairs(fields) do
        grammar[k] = v
    end
    return grammar
end

-- an expected error diagnostic
local function err(code, path, message)
    return {
        severity = 'error',
        code = code,
        path = path,
        message = message,
    }
end

function testcase.check_returns_empty_list_for_valid_grammar()
    assert.equal(check.check(valid_grammar()), {})
    -- only the required fields
    assert.equal(check.check({
        lexogram = '2026.11.15.1',
        start = 'expr',
        tokens = {},
        rules = {
            expr = '"x"',
        },
    }), {})
end

-- root

function testcase.check_reports_non_table_grammar_only()
    for _, case in ipairs({
        {
            nil,
            'nil',
        },
        {
            1,
            'number',
        },
        {
            'grammar',
            'string',
        },
        {
            true,
            'boolean',
        },
        {
            print,
            'function',
        },
    }) do
        assert.equal(check.check(case[1]), {
            err('invalid_type', '', 'grammar must be table, got ' .. case[2]),
        })
    end
end

function testcase.check_reports_every_missing_field_in_order()
    assert.equal(check.check({}), {
        err('missing_field', 'lexogram', 'required field lexogram is missing'),
        err('missing_field', 'start', 'required field start is missing'),
        err('missing_field', 'tokens', 'required field tokens is missing'),
        err('missing_field', 'rules', 'required field rules is missing'),
    })
end

function testcase.check_reports_wrong_field_types_without_inner_checks()
    assert.equal(check.check({
        lexogram = 1,
        start = {},
        tokens = 'x',
        rules = 1,
        symbols = true,
        keywords = 1,
        skip = 'a',
        greedy = 1,
        recover = false,
    }), {
        err('invalid_type', 'lexogram', 'lexogram must be string, got number'),
        err('invalid_type', 'start', 'start must be string, got table'),
        err('invalid_type', 'tokens', 'tokens must be table, got string'),
        err('invalid_type', 'symbols', 'symbols must be table, got boolean'),
        err('invalid_type', 'keywords', 'keywords must be table, got number'),
        err('invalid_type', 'skip', 'skip must be table, got string'),
        err('invalid_type', 'rules', 'rules must be table, got number'),
        err('invalid_type', 'greedy', 'greedy must be table, got number'),
        err('invalid_type', 'recover', 'recover must be table, got boolean'),
    })
end

function testcase.check_reports_unknown_top_level_fields()
    local grammar = valid_grammar()
    grammar.foo = 1
    grammar['a b'] = 1
    grammar.Tokens = 1
    grammar[1] = 1
    grammar[-2.5] = 1
    grammar[true] = 1
    grammar[false] = 1
    grammar[{}] = 1
    grammar[print] = 1

    assert.equal(check.check(grammar), {
        err('unknown_field', 'Tokens', 'unknown field Tokens'),
        err('unknown_field', '["a b"]', 'unknown field ["a b"]'),
        err('unknown_field', 'foo', 'unknown field foo'),
        err('unknown_field', '[-2.5]', 'unknown field [-2.5]'),
        err('unknown_field', '[1]', 'unknown field [1]'),
        err('unknown_field', '[false]', 'unknown field [false]'),
        err('unknown_field', '[true]', 'unknown field [true]'),
        err('unknown_field', '[<function>]', 'unknown field [<function>]'),
        err('unknown_field', '[<table>]', 'unknown field [<table>]'),
    })
end

-- lexogram

function testcase.check_reports_version_problems()
    assert.equal(check.check(grammar_with({
        lexogram = '2026.11.15',
    })), {
        err('invalid_version', 'lexogram', 'invalid version "2026.11.15": ' ..
                'version must have the form yyyy.mm.dd.n'),
    })
    assert.equal(check.check(grammar_with({
        lexogram = '2026.11.15.2',
    })), {
        err('version_too_new', 'lexogram', 'version 2026.11.15.2 is newer ' ..
                'than the current version 2026.11.15.1'),
    })
    assert.equal(check.check(grammar_with({
        lexogram = '2026.11.14.1',
    })), {
        err('version_too_old', 'lexogram', 'version 2026.11.14.1 is older ' ..
                'than the first version 2026.11.15.1'),
    })
end

-- tokens

function testcase.check_reports_token_problems()
    assert.equal(check.check(grammar_with({
        -- skip refers to the comment token, which these tokens replace
        skip = {},
        tokens = {
            a = '"a"',
            b = 1,
            c = true,
            [1] = '"x"',
            [false] = '"y"',
        },
    })), {
        err('invalid_key', 'tokens[1]', 'key tokens[1] must be string'),
        err('invalid_type', 'tokens.b',
            'tokens.b must be string or table, got number'),
        err('invalid_type', 'tokens.c',
            'tokens.c must be string or table, got boolean'),
        err('invalid_key', 'tokens[false]', 'key tokens[false] must be string'),
    })
end

function testcase.check_reports_delimited_token_problems()
    assert.equal(check.check(grammar_with({
        skip = {},
        tokens = {
            no_open = {
                close = '"x"',
            },
            no_close = {
                open = '"x"',
            },
            empty = {},
            bad = {
                open = 1,
                close = {},
                capture = 2,
                text = '_text',
                [1] = '"x"',
            },
        },
    })), {
        err('invalid_key', 'tokens.bad[1]', 'key tokens.bad[1] must be string'),
        err('invalid_type', 'tokens.bad.capture',
            'tokens.bad.capture must be string, got number'),
        err('invalid_type', 'tokens.bad.close',
            'tokens.bad.close must be string, got table'),
        err('invalid_type', 'tokens.bad.open',
            'tokens.bad.open must be string, got number'),
        err('missing_field', 'tokens.empty.close',
            'required field tokens.empty.close is missing'),
        err('missing_field', 'tokens.empty.open',
            'required field tokens.empty.open is missing'),
        err('missing_field', 'tokens.no_close.close',
            'required field tokens.no_close.close is missing'),
        err('missing_field', 'tokens.no_open.open',
            'required field tokens.no_open.open is missing'),
    })
end

-- rules

function testcase.check_reports_rule_problems()
    assert.equal(check.check(grammar_with({
        rules = {
            expr = 'number',
            bad = 1,
            [2] = 'x',
            [true] = 'y',
        },
    })), {
        err('invalid_key', 'rules[2]', 'key rules[2] must be string'),
        err('invalid_type', 'rules.bad', 'rules.bad must be string, got number'),
        err('invalid_key', 'rules[true]', 'key rules[true] must be string'),
    })
end

-- symbols and keywords

function testcase.check_reports_item_array_key_problems()
    for _, name in ipairs({
        'symbols',
        'keywords',
    }) do
        local tbl = {
            'a',
            'b',
            [4] = 'd',
            [7] = 'g',
            [0] = 'z',
            [-1] = 'n',
            [1.5] = 'f',
            [true] = 't',
        }
        tbl[{}] = 'x'

        assert.equal(check.check(grammar_with({
            symbols = {},
            keywords = {},
            [name] = tbl,
        })), {
            err('invalid_key', name .. '[-1]',
                'key ' .. name .. '[-1] is not a valid array index'),
            err('invalid_key', name .. '[0]',
                'key ' .. name .. '[0] is not a valid array index'),
            err('invalid_key', name .. '[1.5]',
                'key ' .. name .. '[1.5] is not a valid array index'),
            err('invalid_key', name .. '[7]',
                'array has a hole: key ' .. name ..
                    '[7] is greater than the item count 4'),
            err('invalid_key', name .. '[true]',
                'key ' .. name .. '[true] is not a valid array index'),
            err('invalid_key', name .. '[<table>]',
                'key ' .. name .. '[<table>] is not a valid array index'),
        })
    end
end

function testcase.check_reports_array_hole_for_every_key_beyond_count()
    assert.equal(check.check(grammar_with({
        symbols = {
            [2] = 'b',
            [3] = 'c',
        },
    })), {
        err('invalid_key', 'symbols[3]',
            'array has a hole: key symbols[3] is greater than the item count 2'),
    })
    assert.equal(check.check(grammar_with({
        symbols = {
            [5] = 'e',
            [9] = 'i',
        },
    })), {
        err('invalid_key', 'symbols[5]',
            'array has a hole: key symbols[5] is greater than the item count 2'),
        err('invalid_key', 'symbols[9]',
            'array has a hole: key symbols[9] is greater than the item count 2'),
    })
end

function testcase.check_reports_item_problems()
    for _, name in ipairs({
        'symbols',
        'keywords',
    }) do
        assert.equal(check.check(grammar_with({
            symbols = {},
            keywords = {},
            [name] = {
                'a',
                {},
                1,
                '',
                'a',
                false,
                'a',
                '',
            },
        })), {
            err('reserved_item', name .. '[2]',
                name .. '[2]: table items are reserved for a future version'),
            err('invalid_type', name .. '[3]',
                name .. '[3] must be string, got number'),
            err('empty_item', name .. '[4]', name .. '[4] must not be empty'),
            err('duplicate_item', name .. '[5]',
                name .. '[5] duplicates the item at index 1'),
            err('invalid_type', name .. '[6]',
                name .. '[6] must be string, got boolean'),
            err('duplicate_item', name .. '[7]',
                name .. '[7] duplicates the item at index 1'),
            err('empty_item', name .. '[8]', name .. '[8] must not be empty'),
        })
    end
end

function testcase.check_reports_item_settings_problems()
    for _, name in ipairs({
        'symbols',
        'keywords',
    }) do
        assert.equal(check.check(grammar_with({
            symbols = {},
            keywords = {},
            [name] = {
                'a',
                ignore_case = 'yes',
                other = true,
                n = 1,
            },
        })), {
            err('invalid_type', name .. '.ignore_case',
                name .. '.ignore_case must be boolean, got string'),
            err('unknown_field', name .. '.n', 'unknown field ' .. name .. '.n'),
            err('unknown_field', name .. '.other',
                'unknown field ' .. name .. '.other'),
        })
    end
end

function testcase.check_reports_keywords_duplicating_symbols()
    assert.equal(check.check(grammar_with({
        symbols = {
            '+',
            'and',
            '-',
            'or',
        },
        keywords = {
            'or',
            'if',
            'and',
            'or',
            'AND',
        },
    })), {
        err('duplicate_item', 'keywords[1]',
            'keywords[1] duplicates the item at symbols[4]'),
        err('duplicate_item', 'keywords[3]',
            'keywords[3] duplicates the item at symbols[2]'),
        -- a later occurrence is reported only within keywords
        err('duplicate_item', 'keywords[4]',
            'keywords[4] duplicates the item at index 1'),
    })
end

function testcase.check_skips_cross_duplicates_without_both_tables()
    assert.equal(check.check(grammar_with({
        symbols = 'x',
        keywords = {
            'x',
        },
    })), {
        err('invalid_type', 'symbols', 'symbols must be table, got string'),
    })
    local grammar = valid_grammar()
    grammar.symbols = nil
    assert.equal(check.check(grammar), {})
end

-- skip, greedy and recover

function testcase.check_reports_name_list_problems()
    local kinds = {
        skip = 'token',
        greedy = 'rule',
        recover = 'rule',
    }
    for _, name in ipairs({
        'skip',
        'greedy',
        'recover',
    }) do
        assert.equal(check.check(grammar_with({
            [name] = {
                'a',
                'a',
                '',
                {},
                2,
                [7] = 'g',
                [0] = 'z',
                [true] = 't',
                ignore_case = true,
                x = 'y',
            },
        })), {
            err('invalid_key', name .. '[0]',
                'key ' .. name .. '[0] is not a valid array index'),
            -- the names pass also checks every string item as a reference
            err('undefined_reference', name .. '[1]',
                name .. '[1] refers to undefined ' .. kinds[name] .. ' "a"'),
            err('duplicate_item', name .. '[2]',
                name .. '[2] duplicates the item at index 1'),
            err('undefined_reference', name .. '[2]',
                name .. '[2] refers to undefined ' .. kinds[name] .. ' "a"'),
            err('empty_item', name .. '[3]', name .. '[3] must not be empty'),
            err('invalid_type', name .. '[4]',
                name .. '[4] must be string, got table'),
            err('invalid_type', name .. '[5]',
                name .. '[5] must be string, got number'),
            err('invalid_key', name .. '[7]',
                'array has a hole: key ' .. name ..
                    '[7] is greater than the item count 6'),
            err('unknown_field', name .. '.ignore_case',
                'unknown field ' .. name .. '.ignore_case'),
            err('unknown_field', name .. '.x', 'unknown field ' .. name .. '.x'),
            err('invalid_key', name .. '[true]',
                'key ' .. name .. '[true] is not a valid array index'),
        })
    end
end

-- path strings

function testcase.check_renders_escaped_string_keys()
    local key = 'a"b\\c' .. string.char(1, 31, 127, 128, 255) .. ' d'
    assert.equal(check.check(grammar_with({
        symbols = {
            [key] = 1,
            ['1abc'] = 1,
            [''] = 1,
            ['a-b'] = 1,
            _ok9 = 1,
        },
    })), {
        err('unknown_field', 'symbols[""]', 'unknown field symbols[""]'),
        err('unknown_field', 'symbols["1abc"]', 'unknown field symbols["1abc"]'),
        err('unknown_field', 'symbols._ok9', 'unknown field symbols._ok9'),
        err('unknown_field', 'symbols["a\\"b\\\\c\\001\\031\\127\\128\\255 d"]',
            'unknown field symbols["a\\"b\\\\c\\001\\031\\127\\128\\255 d"]'),
        err('unknown_field', 'symbols["a-b"]', 'unknown field symbols["a-b"]'),
    })
end

function testcase.check_renders_number_boolean_and_other_keys()
    local tokens = {
        [3] = 'x',
        [-7] = 'x',
        [0.5] = 'x',
        [2 ^ 60] = 'x',
        [1 / 0] = 'x',
        [-1 / 0] = 'x',
        [true] = 'x',
        [false] = 'x',
    }
    tokens[{}] = 'x'
    tokens[print] = 'x'

    local paths = {}
    for i, d in ipairs(check.check(grammar_with({
        skip = {},
        tokens = tokens,
    }))) do
        assert.equal(d.code, 'invalid_key')
        paths[i] = d.path
    end

    assert.equal(paths, {
        'tokens[' .. string.format('%.17g', -1 / 0) .. ']',
        'tokens[-7]',
        'tokens[0.5]',
        'tokens[3]',
        'tokens[1152921504606846976]',
        'tokens[' .. string.format('%.17g', 1 / 0) .. ']',
        'tokens[false]',
        'tokens[true]',
        'tokens[<function>]',
        'tokens[<table>]',
    })
end

-- order

-- build a table by assigning the pairs in the given order
local function build(pairs_list)
    local tbl = {}
    for _, kv in ipairs(pairs_list) do
        tbl[kv[1]] = kv[2]
    end
    return tbl
end

-- a grammar with many problems, built with keys in the given order
local function messy_grammar(reverse)
    local function ordered(list)
        if not reverse then
            return build(list)
        end
        local out = {}
        for i = #list, 1, -1 do
            out[#out + 1] = list[i]
        end
        return build(out)
    end

    return ordered({
        {
            'lexogram',
            'bad',
        },
        {
            'zzz',
            1,
        },
        {
            'aaa',
            1,
        },
        {
            5,
            1,
        },
        {
            true,
            1,
        },
        {
            'tokens',
            ordered({
                {
                    'b',
                    1,
                },
                {
                    'a',
                    {},
                },
                {
                    2,
                    'x',
                },
                {
                    'c',
                    ordered({
                        {
                            'open',
                            1,
                        },
                        {
                            'close',
                            2,
                        },
                    }),
                },
            }),
        },
        {
            'symbols',
            ordered({
                {
                    1,
                    'x',
                },
                {
                    2,
                    'x',
                },
                {
                    3,
                    '',
                },
                {
                    'other',
                    1,
                },
            }),
        },
        {
            'keywords',
            ordered({
                {
                    1,
                    'x',
                },
                {
                    2,
                    'y',
                },
                {
                    'ignore_case',
                    1,
                },
            }),
        },
        {
            'recover',
            ordered({
                {
                    1,
                    1,
                },
                {
                    'k',
                    1,
                },
            }),
        },
    })
end

function testcase.check_returns_deterministic_order()
    local expected = {
        err('invalid_version', 'lexogram', 'invalid version "bad": ' ..
                'version must have the form yyyy.mm.dd.n'),
        err('missing_field', 'start', 'required field start is missing'),
        err('invalid_key', 'tokens[2]', 'key tokens[2] must be string'),
        err('missing_field', 'tokens.a.close',
            'required field tokens.a.close is missing'),
        err('missing_field', 'tokens.a.open',
            'required field tokens.a.open is missing'),
        err('invalid_type', 'tokens.b',
            'tokens.b must be string or table, got number'),
        err('invalid_type', 'tokens.c.close',
            'tokens.c.close must be string, got number'),
        err('invalid_type', 'tokens.c.open',
            'tokens.c.open must be string, got number'),
        err('duplicate_item', 'symbols[2]',
            'symbols[2] duplicates the item at index 1'),
        err('empty_item', 'symbols[3]', 'symbols[3] must not be empty'),
        err('unknown_field', 'symbols.other', 'unknown field symbols.other'),
        err('duplicate_item', 'keywords[1]',
            'keywords[1] duplicates the item at symbols[1]'),
        err('invalid_type', 'keywords.ignore_case',
            'keywords.ignore_case must be boolean, got number'),
        err('missing_field', 'rules', 'required field rules is missing'),
        err('invalid_type', 'recover[1]',
            'recover[1] must be string, got number'),
        err('unknown_field', 'recover.k', 'unknown field recover.k'),
        err('unknown_field', 'aaa', 'unknown field aaa'),
        err('unknown_field', 'zzz', 'unknown field zzz'),
        err('unknown_field', '[5]', 'unknown field [5]'),
        err('unknown_field', '[true]', 'unknown field [true]'),
    }

    assert.equal(check.check(messy_grammar(false)), expected)
    assert.equal(check.check(messy_grammar(true)), expected)
end

function testcase.check_orders_unordered_keys_by_type_name()
    local grammar = valid_grammar()
    grammar[print] = 1
    grammar[{}] = 1
    grammar[{}] = 1
    grammar[coroutine.create(print)] = 1

    local paths = {}
    for i, d in ipairs(check.check(grammar)) do
        paths[i] = d.path
    end

    assert.equal(paths, {
        '[<function>]',
        '[<table>]',
        '[<table>]',
        '[<thread>]',
    })
end

-- robustness

-- a metatable whose metamethods raise if they are ever triggered
local function trap()
    local function fail()
        error('metamethod must not be triggered')
    end
    return {
        __index = fail,
        __newindex = fail,
        __pairs = fail,
        __ipairs = fail,
        __len = fail,
        __eq = fail,
        __lt = fail,
        __le = fail,
        __concat = fail,
        __tostring = fail,
        __call = fail,
    }
end

function testcase.check_does_not_trigger_metamethods()
    local grammar = valid_grammar()
    -- optional fields are absent so that a missing key would hit __index
    grammar.greedy = nil
    grammar.recover = nil
    for _, name in ipairs({
        'tokens',
        'symbols',
        'keywords',
        'skip',
        'rules',
    }) do
        setmetatable(grammar[name], trap())
    end
    setmetatable(grammar.tokens.comment, trap())
    setmetatable(grammar, trap())

    assert.equal(check.check(grammar), {})

    -- values with metatables are reported by their type only
    local bad = valid_grammar()
    bad.start = setmetatable({}, trap())
    bad.symbols[1] = setmetatable({}, trap())
    setmetatable(bad, trap())
    assert.equal(check.check(bad), {
        err('invalid_type', 'start', 'start must be string, got table'),
        err('reserved_item', 'symbols[1]',
            'symbols[1]: table items are reserved for a future version'),
    })
end

function testcase.check_handles_cyclic_tables()
    local grammar = valid_grammar()
    local tokens = {}
    tokens.loop = tokens
    grammar.tokens = tokens
    grammar.skip = nil
    grammar.self = grammar

    assert.equal(check.check(grammar), {
        err('missing_field', 'tokens.loop.close',
            'required field tokens.loop.close is missing'),
        err('invalid_type', 'tokens.loop.loop',
            'tokens.loop.loop must be string, got table'),
        err('missing_field', 'tokens.loop.open',
            'required field tokens.loop.open is missing'),
        err('unknown_field', 'self', 'unknown field self'),
    })
end

function testcase.check_never_raises()
    local odd = {
        {},
        setmetatable({}, trap()),
        {
            lexogram = setmetatable({}, trap()),
            start = print,
            tokens = coroutine.create(print),
            rules = io.stdout,
        },
        {
            lexogram = '2026.11.15.1' .. string.char(0),
            start = '',
            tokens = {
                [io.stdout] = io.stdout,
                [0 / 1] = 0 / 0,
            },
            rules = {
                [1 / 0] = 1 / 0,
            },
            symbols = {
                [2 ^ 70] = 'x',
                [-2 ^ 70] = 'y',
            },
        },
    }
    for _, v in ipairs(odd) do
        local ok, res = pcall(check.check, v)
        assert.is_true(ok)
        assert.is_table(res)
    end
end

-- names pass

-- a minimal valid grammar with the given fields replaced
local function names_grammar(fields)
    local grammar = {
        lexogram = '2026.11.15.1',
        start = 'expr',
        tokens = {},
        rules = {
            expr = '"x"',
        },
    }
    for k, v in pairs(fields) do
        grammar[k] = v
    end
    return grammar
end

function testcase.check_accepts_valid_names()
    assert.equal(check.check(names_grammar({
        tokens = {
            a = '"a"',
            _a = '"b"',
            A1b = '"c"',
            _ABC = '"d"',
            _ = '"e"',
            aB_9 = '"f"',
        },
        rules = {
            expr = 'a',
            r_1 = 'expr',
            _rule = 'expr',
            Rule = 'expr',
        },
    })), {})
end

function testcase.check_reports_invalid_names()
    local eacute = string.char(195, 169)
    local function names()
        return {
            ['1a'] = '"x"',
            ['a b'] = '"x"',
            ['a-b'] = '"x"',
            [''] = '"x"',
            [eacute] = '"x"',
        }
    end

    local expected = {}
    for _, field in ipairs({
        'tokens',
        'rules',
    }) do
        for _, case in ipairs({
            {
                '[""]',
                '""',
            },
            {
                '["1a"]',
                '"1a"',
            },
            {
                '["a b"]',
                '"a b"',
            },
            {
                '["a-b"]',
                '"a-b"',
            },
            {
                '["\\195\\169"]',
                '"\\195\\169"',
            },
        }) do
            local path = field .. case[1]
            expected[#expected + 1] = err('invalid_name', path, path .. ': ' ..
                                              case[2] .. ' is not a valid name')
        end
    end
    local rules = names()
    rules.expr = '"x"'

    assert.equal(check.check(names_grammar({
        tokens = names(),
        rules = rules,
    })), expected)
end

function testcase.check_reports_reserved_names()
    assert.equal(check.check(names_grammar({
        tokens = {
            NUMBER = '[0-9]+',
            A = '"a"',
            A_1 = '"b"',
        },
        rules = {
            expr = 'NUMBER',
            EXPR = 'expr',
        },
    })), {
        err('reserved_name', 'tokens.A',
            'tokens.A: "A" is reserved (all-uppercase names are builtins)'),
        err('reserved_name', 'tokens.A_1',
            'tokens.A_1: "A_1" is reserved (all-uppercase names are builtins)'),
        err('reserved_name', 'tokens.NUMBER', 'tokens.NUMBER: "NUMBER" is ' ..
                'reserved (all-uppercase names are builtins)'),
        err('reserved_name', 'rules.EXPR',
            'rules.EXPR: "EXPR" is reserved (all-uppercase names are builtins)'),
    })
end

function testcase.check_reports_names_defined_in_tokens_and_rules()
    assert.equal(check.check(names_grammar({
        tokens = {
            x = '"x"',
            NUM = '[0-9]',
            ['a b'] = '"y"',
        },
        rules = {
            expr = 'x',
            x = 'expr',
            NUM = 'expr',
            ['a b'] = 'expr',
        },
    })), {
        err('reserved_name', 'tokens.NUM',
            'tokens.NUM: "NUM" is reserved (all-uppercase names are builtins)'),
        err('invalid_name', 'tokens["a b"]',
            'tokens["a b"]: "a b" is not a valid name'),
        err('reserved_name', 'rules.NUM',
            'rules.NUM: "NUM" is reserved (all-uppercase names are builtins)'),
        err('invalid_name', 'rules["a b"]',
            'rules["a b"]: "a b" is not a valid name'),
        err('duplicate_name', 'rules.x',
            'rules.x: "x" is already defined at tokens.x'),
    })
end

function testcase.check_reports_capture_names()
    assert.equal(check.check(names_grammar({
        tokens = {
            x = '"x"',
            str = {
                open = '"\\""',
                close = '"\\""',
                body = '_text',
                Body2 = '_text',
                ['1x'] = '_text',
                BODY = '_text',
                _frag = '_text',
                -- capture names may coincide with token and rule names
                x = '_text',
                expr = '_text',
            },
        },
    })), {
        err('invalid_name', 'tokens.str["1x"]',
            'tokens.str["1x"]: "1x" is not a valid name'),
        err('reserved_name', 'tokens.str.BODY', 'tokens.str.BODY: "BODY" is ' ..
                'reserved (all-uppercase names are builtins)'),
        err('invalid_name', 'tokens.str._frag',
            'tokens.str._frag: capture name "_frag" must not start with "_",' ..
                ' which is ambiguous with a fragment reference'),
    })
end

function testcase.check_reports_start_references()
    local rules = {
        expr = '"x"',
        _rule = 'expr',
    }
    local tokens = {
        num = '[0-9]+',
        _digits = '[0-9]+',
    }
    for _, case in ipairs({
        {
            'expr',
            {},
        },
        {
            '_rule',
            {},
        },
        {
            'chunk',
            {
                err('undefined_reference', 'start',
                    'start refers to undefined rule "chunk"'),
            },
        },
        {
            'num',
            {
                err('invalid_reference', 'start',
                    'start refers to "num", which is a token, not a rule'),
            },
        },
        {
            '_digits',
            {
                err('invalid_reference', 'start',
                    'start refers to "_digits",' ..
                        ' which is a fragment, not a rule'),
            },
        },
    }) do
        assert.equal(check.check(names_grammar({
            start = case[1],
            tokens = tokens,
            rules = rules,
        })), case[2])
    end
end

function testcase.check_reports_skip_references()
    assert.equal(check.check(names_grammar({
        tokens = {
            ws = '[ ]+',
            comment = {
                open = '"#"',
                close = '"\\n"',
            },
            _digits = '[0-9]+',
        },
        skip = {
            'ws',
            'comment',
            'nope',
            '_digits',
            'expr',
            'nope',
        },
    })), {
        err('undefined_reference', 'skip[3]',
            'skip[3] refers to undefined token "nope"'),
        err('invalid_reference', 'skip[4]',
            'skip[4] refers to "_digits", which is a fragment, not a token'),
        err('invalid_reference', 'skip[5]',
            'skip[5] refers to "expr", which is a rule, not a token'),
        err('duplicate_item', 'skip[6]',
            'skip[6] duplicates the item at index 3'),
        err('undefined_reference', 'skip[6]',
            'skip[6] refers to undefined token "nope"'),
    })
end

function testcase.check_reports_greedy_and_recover_references()
    for _, name in ipairs({
        'greedy',
        'recover',
    }) do
        assert.equal(check.check(names_grammar({
            tokens = {
                ws = '[ ]+',
                _f = '"f"',
            },
            rules = {
                expr = '"x"',
                _r = 'expr',
            },
            [name] = {
                'expr',
                '_r',
                'nope',
                'ws',
                '_f',
            },
        })), {
            err('undefined_reference', name .. '[3]',
                name .. '[3] refers to undefined rule "nope"'),
            err('invalid_reference', name .. '[4]',
                name .. '[4] refers to "ws", which is a token, not a rule'),
            err('invalid_reference', name .. '[5]',
                name .. '[5] refers to "_f", which is a fragment, not a rule'),
        })
    end
end

function testcase.check_counts_invalid_definitions_as_defined()
    assert.equal(check.check(names_grammar({
        start = 'ALPHA',
        tokens = {
            WS = '[ ]+',
        },
        rules = {
            expr = '"x"',
            ALPHA = 'expr',
            ['a b'] = 'expr',
        },
        skip = {
            'WS',
        },
        greedy = {
            'a b',
        },
        -- an undefined name is reported whatever its shape
        recover = {
            'NOPE',
            '1x',
        },
    })), {
        err('reserved_name', 'tokens.WS',
            'tokens.WS: "WS" is reserved (all-uppercase names are builtins)'),
        err('reserved_name', 'rules.ALPHA', 'rules.ALPHA: "ALPHA" is ' ..
                'reserved (all-uppercase names are builtins)'),
        err('invalid_name', 'rules["a b"]',
            'rules["a b"]: "a b" is not a valid name'),
        err('undefined_reference', 'recover[1]',
            'recover[1] refers to undefined rule "NOPE"'),
        err('undefined_reference', 'recover[2]',
            'recover[2] refers to undefined rule "1x"'),
    })
end

function testcase.check_treats_duplicate_name_as_both_kinds()
    assert.equal(check.check(names_grammar({
        start = 'x',
        tokens = {
            x = '"x"',
            _f = '"f"',
        },
        rules = {
            expr = '"x"',
            x = 'expr',
            _f = 'expr',
        },
        skip = {
            'x',
            '_f',
        },
        greedy = {
            'x',
            '_f',
        },
    })), {
        err('invalid_reference', 'skip[2]', 'skip[2] refers to "_f", ' ..
                'which is a fragment and a rule, not a token'),
        err('duplicate_name', 'rules._f',
            'rules._f: "_f" is already defined at tokens._f'),
        err('duplicate_name', 'rules.x',
            'rules.x: "x" is already defined at tokens.x'),
    })
end

function testcase.check_names_pass_tolerates_malformed_fields()
    -- fields of the wrong type
    assert.equal(check.check({
        lexogram = '2026.11.15.1',
        start = {},
        tokens = 'x',
        rules = 1,
        skip = 'a',
        greedy = 1,
        recover = true,
    }), {
        err('invalid_type', 'start', 'start must be string, got table'),
        err('invalid_type', 'tokens', 'tokens must be table, got string'),
        err('invalid_type', 'skip', 'skip must be table, got string'),
        err('invalid_type', 'rules', 'rules must be table, got number'),
        err('invalid_type', 'greedy', 'greedy must be table, got number'),
        err('invalid_type', 'recover', 'recover must be table, got boolean'),
    })

    -- missing fields: references are not checked without tokens and rules
    assert.equal(check.check({
        lexogram = '2026.11.15.1',
        start = 'nope',
        skip = {
            'nope',
        },
        greedy = {
            'nope',
        },
    }), {
        err('missing_field', 'tokens', 'required field tokens is missing'),
        err('missing_field', 'rules', 'required field rules is missing'),
    })
    assert.equal(check.check(names_grammar({
        start = 'nope',
        tokens = 1,
    })), {
        err('invalid_type', 'tokens', 'tokens must be table, got number'),
    })

    -- non-string keys and items
    assert.equal(check.check(names_grammar({
        tokens = {
            [1] = '"x"',
            ws = '[ ]',
            str = {
                open = '"a"',
                close = '"b"',
                [2] = '_text',
            },
        },
        rules = {
            [true] = 'x',
            expr = '"x"',
        },
        skip = {
            1,
            {},
            '',
            'ws',
        },
        recover = {
            false,
        },
    })), {
        err('invalid_key', 'tokens[1]', 'key tokens[1] must be string'),
        err('invalid_key', 'tokens.str[2]', 'key tokens.str[2] must be string'),
        err('invalid_type', 'skip[1]', 'skip[1] must be string, got number'),
        err('invalid_type', 'skip[2]', 'skip[2] must be string, got table'),
        err('empty_item', 'skip[3]', 'skip[3] must not be empty'),
        err('invalid_key', 'rules[true]', 'key rules[true] must be string'),
        err('invalid_type', 'recover[1]',
            'recover[1] must be string, got boolean'),
    })
end

function testcase.check_orders_structure_and_name_diagnostics()
    assert.equal(check.check({
        lexogram = '2026.11.15.1',
        start = 'num',
        tokens = {
            num = 1,
            WS = '[ ]',
            ['bad name'] = '"x"',
        },
        symbols = {
            '+',
            '+',
        },
        skip = {
            'expr',
            'missing',
        },
        rules = {
            expr = 'num',
            num = 2,
        },
        extra = true,
    }), {
        -- start = 'num' is fine: num is also a rule (duplicate_name below)
        err('reserved_name', 'tokens.WS',
            'tokens.WS: "WS" is reserved (all-uppercase names are builtins)'),
        err('invalid_name', 'tokens["bad name"]',
            'tokens["bad name"]: "bad name" is not a valid name'),
        err('invalid_type', 'tokens.num',
            'tokens.num must be string or table, got number'),
        err('duplicate_item', 'symbols[2]',
            'symbols[2] duplicates the item at index 1'),
        err('invalid_reference', 'skip[1]',
            'skip[1] refers to "expr", which is a rule, not a token'),
        err('undefined_reference', 'skip[2]',
            'skip[2] refers to undefined token "missing"'),
        err('duplicate_name', 'rules.num',
            'rules.num: "num" is already defined at tokens.num'),
        err('invalid_type', 'rules.num', 'rules.num must be string, got number'),
        err('unknown_field', 'extra', 'unknown field extra'),
    })
end
