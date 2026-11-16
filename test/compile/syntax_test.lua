local testcase = require('testcase')
local assert = require('assert')
local syntax = require('lexogram.compile.syntax')
local lexer = require('lexogram.compile.lexer')
local check = require('lexogram.check')

-- a grammar from fields, with a name token and whitespace by default
local function grammar(fields)
    local g = {
        lexogram = '2026.11.15.1',
        start = 's',
        tokens = {
            name = 'ALPHA+',
            space = '" "+',
        },
        skip = {
            'space',
        },
    }
    for k, v in pairs(fields) do
        g[k] = v
    end
    return g
end

-- run the syntax analysis of g; ids maps kind names (token names and
-- literal strings) to kind ids
local function analyze(g)
    local lexed = assert(lexer.build(g))
    local ids = {}
    for _, def in ipairs(lexed.defs) do
        ids[def.name] = def.id
    end
    local result, diagnostics = syntax.analyze(g, lexed)
    return result, diagnostics, ids
end

local function at(severity, code, segments, pos, message)
    return {
        severity = severity,
        code = code,
        segments = segments,
        pos = pos,
        message = message,
    }
end

-- the Lua table constructor shape
local function table_grammar()
    return grammar({
        start = 'table',
        tokens = {
            name = 'ALPHA+',
            number = 'DIGIT+',
            space = '" "+',
        },
        symbols = {
            '=',
            '(',
            ')',
            '{',
            '}',
            ',',
        },
        rules = {
            field = 'name "=" expr | expr',
            expr = 'name ("(" ")")* | number',
            table = '"{" (field ("," field)*)? "}"',
        },
    })
end

function testcase.analyze_resolves_choice_with_two_tokens()
    local g = table_grammar()
    assert.equal(check.check(g), {})

    local result, diagnostics, ids = analyze(g)

    assert.equal(diagnostics, {})
    assert.equal(result.decisions[result.rules.field], {
        type = 'choice',
        first = {
            [ids.number] = 2,
        },
        second = {
            [ids.name] = {
                [ids['=']] = 1,
                [ids['(']] = 2,
                [ids['}']] = 2,
                [ids[',']] = 2,
            },
        },
    })
    -- the optional field list of table: entered on the first token of a
    -- field, with no second token needed
    local opt = result.rules.table.items[2]
    assert.equal(result.decisions[opt], {
        type = 'opt',
        enter = {
            [ids.name] = true,
            [ids.number] = true,
        },
        second = {},
    })
    -- ("(" ")")* in expr: "(" enters, "}" and "," exit
    local star = result.rules.expr.items[1].items[2]
    assert.equal(result.decisions[star], {
        type = 'star',
        enter = {
            [ids['(']] = true,
        },
        second = {},
    })
    assert.is_table(result.analysis.first1.field)
end

function testcase.analyze_resolves_choice_with_one_token()
    local result, diagnostics, ids = analyze(grammar({
        symbols = {
            'a',
            'b',
        },
        rules = {
            s = '"a" name | "b"',
        },
    }))

    assert.equal(diagnostics, {})
    assert.equal(result.decisions[result.rules.s], {
        type = 'choice',
        first = {
            [ids.a] = 1,
            [ids.b] = 2,
        },
        second = {},
    })
end

function testcase.analyze_reports_ambiguous_choices()
    local result, diagnostics = analyze(grammar({
        symbols = {
            'x',
            'y',
            'z',
        },
        rules = {
            s = 'name | "x" "y" | "x" "y" "z" | name "x"?',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('error', 'ambiguous_choice', {
            'rules',
            's',
        }, 1, 'rules.s: alternatives 1 and 4 of the choice can both start' ..
               ' with name end of input'),
        at('error', 'ambiguous_choice', {
            'rules',
            's',
        }, 1, 'rules.s: alternatives 2 and 3 of the choice can both start' ..
               ' with "x" "y"'),
    })
end

function testcase.analyze_reports_nullable_alternatives_as_ambiguous()
    local result, diagnostics = analyze(grammar({
        symbols = {
            'x',
            'y',
        },
        rules = {
            s = '"x"? | "y"?',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('error', 'ambiguous_choice', {
            'rules',
            's',
        }, 1, 'rules.s: alternatives 1 and 2 of the choice can both start' ..
               ' with end of input'),
    })
end

function testcase.analyze_accepts_overlapping_ordered_choices()
    local result, diagnostics, ids = analyze(grammar({
        symbols = {
            'x',
            'y',
            'z',
        },
        rules = {
            s = '"x" "y" / "x" "z" / "y"?',
        },
    }))

    assert.equal(diagnostics, {})
    assert.equal(result.decisions[result.rules.s], {
        type = 'ordered',
        first = {
            {
                ids.x,
            },
            {
                ids.x,
            },
            -- a nullable alternative includes what follows the choice
            {
                0,
                ids.y,
            },
        },
    })
end

-- the dangling else: stat = "if" expr "then" stat ("else" stat)? | other
local function dangling_else(greedy)
    return grammar({
        start = 'stat',
        symbols = {
            ';',
        },
        keywords = {
            'if',
            'then',
            'else',
        },
        rules = {
            stat = '"if" expr "then" stat ("else" stat)? | ";"',
            expr = 'name',
        },
        greedy = greedy,
    })
end

function testcase.analyze_words_repetition_greedy_spots()
    local _, diagnostics = analyze(grammar({
        symbols = {
            'x',
            'y',
            'z',
        },
        rules = {
            s = '("x" "y")* "x" "y" "z"',
        },
    }))

    assert.equal(diagnostics, {
        at('warning', 'undeclared_greedy', {
            'rules',
            's',
        }, 2, 'rules.s: the repetition can both continue and end with' ..
               ' "x" "y"; rewrite the rule or add s to greedy to always' ..
               ' take the element'),
    })
end

function testcase.analyze_warns_about_undeclared_greedy_spots()
    local result, diagnostics, ids = analyze(dangling_else())

    assert.equal(diagnostics, {
        at('warning', 'undeclared_greedy', {
            'rules',
            'stat',
        }, 24, 'rules.stat: the optional element can both be taken and' ..
               ' skipped with "else" ";"; rewrite the rule or add stat to' ..
               ' greedy to always take the element'),
    })
    local opt = result.rules.stat.items[1].items[5]
    local decision = result.decisions[opt]
    assert.equal(decision.enter, {
        [ids['else']] = true,
    })
    assert.equal(decision.second, {
        [ids['else']] = {
            [ids['if']] = true,
            [ids[';']] = true,
        },
    })
    assert.is_number(decision.greedy)

    -- declared as greedy
    result, diagnostics = analyze(dangling_else({
        'stat',
    }))
    assert.is_table(result)
    assert.equal(diagnostics, {})
end

function testcase.analyze_warns_about_unneeded_greedy()
    local result, diagnostics = analyze(dangling_else({
        'stat',
        'expr',
    }))

    assert.is_table(result)
    assert.equal(diagnostics, {
        at('warning', 'unneeded_greedy', {
            'greedy',
            2,
        }, nil, 'greedy[2] "expr" has no greedy repetition'),
    })
end

function testcase.analyze_reports_nullable_repetitions()
    local result, diagnostics = analyze(grammar({
        symbols = {
            'x',
            'y',
        },
        rules = {
            s = '("x"?)* "y" a+',
            a = '"x"?',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('error', 'nullable_repetition', {
            'rules',
            's',
        }, 2, 'rules.s: the repeated element can match the empty string'),
        at('error', 'nullable_repetition', {
            'rules',
            's',
        }, 13, 'rules.s: the repeated element can match the empty string'),
    })
end

function testcase.analyze_reports_skipped_tokens()
    local result, diagnostics = analyze(grammar({
        rules = {
            s = 'name space name',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('error', 'skipped_token', {
            'rules',
            's',
        }, 6, 'rules.s refers to space, which is listed in skip and never' ..
               ' reaches the parser'),
    })
end

function testcase.analyze_stops_after_left_recursion()
    local result, diagnostics = analyze(grammar({
        symbols = {
            'x',
            'y',
        },
        rules = {
            s = 's "x" | "y" | "y"',
        },
    }))

    assert.is_nil(result)
    -- the ambiguous choice is not reported
    assert.equal(diagnostics, {
        at('error', 'left_recursion', {
            'rules',
            's',
        }, nil, 'rule s is left-recursive: s -> s'),
    })
end

function testcase.analyze_stops_after_nonterminating_rules()
    local result, diagnostics = analyze(grammar({
        symbols = {
            'x',
        },
        rules = {
            s = 'a | name | name',
            a = '"x" a',
        },
    }))

    assert.is_nil(result)
    assert.equal(diagnostics, {
        at('error', 'nonterminating_rule', {
            'rules',
            'a',
        }, nil, 'rules.a derives no finite token string, so it can never' ..
               ' finish matching'),
    })
end

function testcase.analyze_maps_literals_through_ignore_case()
    local result, diagnostics, ids = analyze(grammar({
        keywords = {
            'IF',
            ignore_case = true,
        },
        rules = {
            s = '"if" name | name',
        },
    }))

    assert.equal(diagnostics, {})
    assert.equal(result.decisions[result.rules.s], {
        type = 'choice',
        first = {
            [ids.IF] = 1,
            [ids.name] = 2,
        },
        second = {},
    })
end
