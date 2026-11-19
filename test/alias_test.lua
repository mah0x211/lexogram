local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- a grammar with the rules
local function grammar(rules)
    return {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '" "+',
        },
        symbols = {
            '(',
            ')',
            '{',
            '}',
            '?',
            ':',
            ';',
        },
        skip = {
            'space',
        },
        rules = rules,
    }
end

-- the events of source as "(rule", ")" and token texts, skipped tokens left
-- out
local function shape(compiled, source)
    local result = assert(lexogram.parse(compiled, source))
    local out = {}
    for i = 1, result.count do
        local op = events.op(result, i)
        if op == events.ENTER then
            out[#out + 1] = '(' .. events.name(result, i)
        elseif op == events.EXIT then
            out[#out + 1] = ')'
        elseif events.name(result, i) ~= 'space' then
            out[#out + 1] = events.text(result, i)
        end
    end
    return table.concat(out, ' ')
end

-- the errors of the rules, as "code path pos: message"
local function errors_of(rules)
    local out = {}
    for _, d in ipairs(lexogram.check(grammar(rules))) do
        if d.severity == 'error' then
            out[#out + 1] = d.code .. ' ' .. d.path .. ' ' .. tostring(d.pos) ..
                                ': ' .. d.message
        end
    end
    return out
end

-- the names of the rule kinds of a compiled object
local function rule_kinds(compiled)
    local names = {}
    for _, kind in ipairs(compiled.kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    return names
end

function testcase.an_alias_is_reported_as_the_rule_it_names()
    local compiled = assert(lexogram.compile(grammar({
        chunk = '(call | (name "{" "}")->call)* ";"',
        call = 'name "(" ")"',
    })))
    -- f() and g {} are both a call
    assert.equal(shape(compiled, 'f() g {} ;'),
                 '(chunk (call f ( ) ) (call g { } ) ; )')
    -- no kind is added for an alias
    assert.equal(rule_kinds(compiled), {
        'call',
        'chunk',
    })
end

function testcase.an_alias_of_a_rule_without_a_kind_shows_its_range()
    -- a rule without a kind called last (a tail call) is reported too
    local compiled = assert(lexogram.compile(grammar({
        chunk = 'stat*',
        stat = 'name ("?" _middle ":" name)? ";"',
        _middle = '(_operand)->stat',
        _operand = 'name',
    })))
    assert.equal(shape(compiled, 'a ? b : c ; d ;'),
                 '(chunk (stat a ? (stat b ) : c ; ) (stat d ; ) )')
end

function testcase.an_alias_can_be_optional()
    local compiled = assert(lexogram.compile(grammar({
        chunk = '((name)->call)? ";"',
        call = 'name "(" ")"',
    })))
    assert.equal(shape(compiled, 'f ;'), '(chunk (call f ) ; )')
    assert.equal(shape(compiled, ';'), '(chunk ; )')
end

function testcase.an_alias_of_a_rule_with_a_kind_contains_it()
    local compiled = assert(lexogram.compile(grammar({
        chunk = '(item)->list ";"',
        item = 'name',
        list = '"(" ")"',
    })))
    assert.equal(shape(compiled, 'a ;'), '(chunk (list (item a ) ) ; )')
end

function testcase.aliases_name_rules_with_a_kind()
    assert.equal(errors_of({
        chunk = '(name)->none (name)->_x (name)->name ";"',
        _x = 'name',
    }), {
        'undefined_reference rules.chunk 9: rules.chunk aliases undefined' ..
            ' rule "none"',
        'invalid_reference rules.chunk 22: rules.chunk aliases "_x", which' ..
            ' is a rule without a kind, not a rule with a kind',
        'invalid_reference rules.chunk 33: rules.chunk aliases "name",' ..
            ' which is a token, not a rule with a kind',
    })
end

function testcase.a_rule_named_by_an_alias_only_is_used()
    -- x gives the kind and is never matched: no unreachable_rule
    local _, diagnostics = lexogram.compile(grammar({
        chunk = '(name)->x ";"',
        x = '"(" ")"',
    }))
    for _, d in ipairs(diagnostics) do
        assert.not_equal(d.code, 'unreachable_rule')
    end
end

function testcase.warnings_inside_aliases_name_their_rule()
    local found = {}
    for _, d in ipairs(lexogram.check(grammar({
        chunk = '(name*+)->x ";"',
        x = 'name',
    }))) do
        if d.code == 'unneeded_possessive' then
            found[#found + 1] = d.path
        end
    end
    assert.equal(found, {
        'rules.chunk',
    })
end

function testcase.diagnostics_inside_aliases_name_their_rule()
    assert.equal(errors_of({
        chunk = '(name name | name name)->x ";"',
        x = 'name',
    }), {
        'ambiguous_choice rules.chunk 2: rules.chunk: alternatives 1 and 2' ..
            ' of the choice can both start with name name',
    })
    assert.equal(errors_of({
        chunk = '(chunk ";")->x',
        x = 'name',
    }), {
        'left_recursion rules.chunk nil: rule chunk is left-recursive:' ..
            ' chunk -> chunk',
        'nonterminating_rule rules.chunk nil: rules.chunk derives no finite' ..
            ' token string, so it can never finish matching',
    })
    -- a cycle through the rule of an alias names each rule once
    assert.equal(errors_of({
        chunk = '(other ";")->x',
        other = 'chunk ";"',
        x = 'name',
    }), {
        'left_recursion rules.chunk nil: rule chunk is left-recursive:' ..
            ' chunk -> other -> chunk',
        'nonterminating_rule rules.chunk nil: rules.chunk derives no finite' ..
            ' token string, so it can never finish matching',
        'nonterminating_rule rules.other nil: rules.other derives no finite' ..
            ' token string, so it can never finish matching',
    })
    -- the copies of a count with an alias are reported once
    assert.equal(errors_of({
        chunk = '(undefined)->x{2} ";"',
        x = 'name',
    }), {
        'repeated_postfix rules.chunk 15: postfix operator follows an' ..
            ' alias; write ((p)->name)*',
    })
    assert.equal(errors_of({
        chunk = '((undefined)->x){2} ";"',
        x = 'name',
    }), {
        'undefined_reference rules.chunk 3: rules.chunk refers to undefined' ..
            ' token or rule "undefined"',
    })
end
