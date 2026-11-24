local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- a grammar with the rules: generic types closed by ">" and a shift
local function grammar(rules)
    return {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z] [a-z0-9]*',
            gt = '">"',
            space = '" "+',
        },
        symbols = {
            '<',
            '>>',
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

-- the warnings of a grammar, as "code path pos: message"
local function warnings_of(g)
    local out = {}
    for _, d in ipairs(lexogram.check(g)) do
        if d.severity == 'warning' then
            out[#out + 1] = d.code .. ' ' .. d.path .. ' ' .. tostring(d.pos) ..
                                ': ' .. d.message
        end
    end
    return out
end

function testcase.a_prefix_match_names_a_literal_or_a_token()
    -- a token and a declared literal
    assert.equal(errors_of({
        chunk = '(type ";")*',
        type = 'name ("<" type #gt)?',
    }), {})
    assert.equal(errors_of({
        chunk = '(type ";")*',
        type = 'name (#"<" type gt)? | name #">>" name',
    }), {})
    -- a rule matches a sequence of tokens, not a part of one token
    assert.equal(errors_of({
        chunk = '(type ";")*',
        type = 'name ("<" type #close)?',
        close = 'gt',
    }), {
        'invalid_reference rules.type 17: rules.type refers to "close",' ..
            ' which is a rule, not a token',
    })
    assert.equal(errors_of({
        chunk = '(type ";")*',
        type = 'name ("<" type #missing)?',
    }), {
        'undefined_reference rules.type 17: rules.type refers to undefined' ..
            ' token "missing"',
    })
    -- the literal must be declared, as any literal of the rules
    assert.equal(errors_of({
        chunk = '(type ";")*',
        type = 'name ("<" type #">=")?',
    }), {
        'undeclared_literal rules.type 17: rules.type refers to undeclared' ..
            ' literal ">="',
    })
    -- a skipped token never reaches the parser
    assert.equal(errors_of({
        chunk = '(type ";")*',
        type = 'name ("<" type #space)?',
    }), {
        'skipped_token rules.type 17: rules.type refers to space, which is' ..
            ' listed in skip and never reaches the parser',
    })
end

function testcase.a_prefix_match_matches_the_token_it_names()
    local compiled = assert(lexogram.compile(grammar({
        chunk = '(type ";" | name #">>" name ";")*',
        type = 'name ("<" type #gt)?',
    })))
    assert.equal(shape(compiled, 'vec<vec<u8> >;'),
                 '(chunk (type vec < (type vec < (type u8 ) > ) > ) ; )')
    assert.equal(shape(compiled, 'a >> b;'), '(chunk a >> b ; )')
end

function testcase.a_prefix_match_that_splits_no_token_is_not_needed()
    -- ">>" starts with gt and with ">", not with "<" or ";"
    assert.equal(warnings_of(grammar({
        chunk = '(name #";" | #"<" name ">>" #gt)*',
    })), {
        'unneeded_prefix rules.chunk 7: rules.chunk: "#" is not needed: no' ..
            ' token that reaches the parser can start with ";" and be longer',
        'unneeded_prefix rules.chunk 14: rules.chunk: "#" is not needed: no' ..
            ' token that reaches the parser can start with "<" and be longer',
    })
    -- a longer name is still a name, which "#name" matches as it is
    local g = grammar({
        chunk = '(#name ";" | name ">>" name gt "<")*',
    })
    assert.equal(warnings_of(g), {
        'unneeded_prefix rules.chunk 2: rules.chunk: "#" is not needed: no' ..
            ' token that reaches the parser can start with name and be longer',
    })
    -- a skipped token never reaches the parser: "--" is a comment
    g = grammar({
        chunk = '(name #"-" name ";" | name ">>" gt "<")*',
    })
    g.tokens.comment = '"--" [^\\n]*'
    g.skip[2] = 'comment'
    g.symbols[4] = '-'
    assert.equal(warnings_of(g), {
        'unneeded_prefix rules.chunk 7: rules.chunk: "#" is not needed: no' ..
            ' token that reaches the parser can start with "-" and be longer',
    })
    -- no longer token starts with a delimited token
    g = grammar({
        chunk = '(#str name ";" | name ">>" gt "<")*',
    })
    g.tokens.str = {
        open = '"\\""',
        close = '"\\""',
    }
    assert.equal(warnings_of(g), {
        'unneeded_prefix rules.chunk 2: rules.chunk: "#" is not needed: no' ..
            ' token that reaches the parser can start with str and be longer',
    })
end

function testcase.a_split_token_is_followed_by_any_token()
    -- the rest of a split ">>" is read again, so the token after ">>" does
    -- not tell the alternatives
    assert.equal(errors_of({
        chunk = 'close*',
        close = '#gt gt name ";" | ">>" name "<"',
    }), {
        'ambiguous_choice rules.close 1: rules.close: alternatives 1 and 2' ..
            ' of the choice can both start with ">>" any token',
    })
    assert.equal(errors_of({
        chunk = '(name (#gt name)* ">>" name ";")*',
    }), {
        'ambiguous_repetition rules.chunk 8: rules.chunk: the repetition can' ..
            ' both continue and end with ">>" any token; rewrite the rule, or' ..
            ' write *+ to always take the element',
    })
    assert.equal(errors_of({
        chunk = '(name (#gt name)*+ ">>" name ";")*',
    }), {})
    -- ">>" alone tells them
    assert.equal(errors_of({
        chunk = 'close*',
        close = '#gt name ";" | ">>" ";"',
    }), {
        'ambiguous_choice rules.close 1: rules.close: alternatives 1 and 2' ..
            ' of the choice can both start with ">>" any token',
    })
    assert.equal(errors_of({
        chunk = 'close*',
        close = '#gt name ";" | "<" ">>" ";"',
    }), {})
end
