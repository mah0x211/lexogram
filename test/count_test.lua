local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')

-- a grammar from fields that replace those of the default
local function grammar(fields)
    local g = {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '" "+',
        },
        symbols = {
            ';',
        },
        skip = {
            'space',
        },
        rules = {
            chunk = 'name*',
        },
    }
    for k, v in pairs(fields) do
        g[k] = v
    end
    return g
end

-- the severity, code and message of each diagnostic of fields
local function diagnostics_of(fields)
    local out = {}
    for _, d in ipairs(lexogram.check(grammar(fields))) do
        out[#out + 1] = d.severity .. ' ' .. d.code .. ': ' .. d.message
    end
    return out
end

function testcase.counts_repeat_tokens_and_rules()
    local compiled = assert(lexogram.compile(grammar({
        tokens = {
            name = '[a-z]+',
            space = '" "+',
            hex = '"#" HEXDIGIT{2}',
            code = '[A-Z]{2,3}',
        },
        rules = {
            chunk = 'stat*',
            stat = 'name{1,2} ";" | hex{2,} ";" | code{3} ";"',
        },
    })))
    for _, source in ipairs({
        'a ;',
        'a b ;',
        '#0f #10 #ff ;',
        'AB CDE FG ;',
    }) do
        assert.is_table(lexogram.parse(compiled, source))
    end
    for _, source in ipairs({
        'a b c ;',
        '#0f ;',
        'AB CD ;',
        '#0 #10 ;',
        'A BC DE ;',
    }) do
        assert.is_nil(lexogram.parse(compiled, source))
    end
end

function testcase.ambiguous_counts_are_told_by_their_count()
    -- an optional copy of name{1,3} can be taken or skipped before two
    -- names; the error is reported once
    assert.equal(diagnostics_of({
        rules = {
            chunk = 'name{1,3} name name ";"',
        },
    }), {
        'error ambiguous_repetition: rules.chunk: the repetition can both' ..
            ' continue and end with name name; rewrite the rule, or write {1,3}+' ..
            ' to always take the element',
    })
    -- a possessive count that some copy needs is not warned about
    assert.equal(diagnostics_of({
        rules = {
            chunk = 'name{1,3}+ name name ";"',
        },
    }), {})
    -- one that no copy needs is, once
    assert.equal(diagnostics_of({
        rules = {
            chunk = 'name{1,3}+ ";"',
        },
    }), {
        'warning unneeded_possessive: rules.chunk: {1,3}+ is not needed:' ..
            ' the repetition is never ambiguous',
    })
    assert.equal(diagnostics_of({
        rules = {
            chunk = 'name{2,}+ ";"',
        },
    }), {
        'warning unneeded_possessive: rules.chunk: {2,}+ is not needed:' ..
            ' the repetition is never ambiguous',
    })
end

function testcase.diagnostics_of_copies_are_reported_once()
    assert.equal(diagnostics_of({
        rules = {
            chunk = '("end" undefined){3}',
        },
    }), {
        'error undeclared_literal: rules.chunk refers to undeclared literal' ..
            ' "end"',
        'error undefined_reference: rules.chunk refers to undefined token or' ..
            ' rule "undefined"',
    })
end
