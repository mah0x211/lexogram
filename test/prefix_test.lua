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

-- the tokens of source as "text:kind", skipped tokens left out, after
-- checking that the tokens cover the source in order
local function tokens_of(compiled, source)
    local result = assert(lexogram.parse(compiled, source))
    local out, at = {}, 1
    for i = 1, result.count do
        if events.op(result, i) == events.TOKEN then
            local start, stop = events.range(result, i)
            assert.equal(start, at)
            at = stop
            if events.name(result, i) ~= 'space' then
                out[#out + 1] = events.text(result, i) .. ':' ..
                                    events.name(result, i)
            end
        end
    end
    assert.equal(at, #source + 1)
    return table.concat(out, ' ')
end

-- a grammar of types closed by ">" and of shifts
local function types(rules)
    local g = grammar(rules)
    g.tokens.gt = nil
    g.symbols = {
        '<',
        '>',
        '>>',
        '>=',
        '>>=',
        '>>>',
        '=',
        ',',
        ';',
    }
    return g
end

function testcase.a_prefix_match_splits_a_longer_token()
    local compiled = assert(lexogram.compile(types({
        chunk = '(type ("=" name)? ";" | name ">>" name ";")*',
        type = 'name (#"<" type ("," type)* #">")?',
    })))
    assert.equal(shape(compiled, 'vec<vec<u8>>;'),
                 '(chunk (type vec < (type vec < (type u8 ) > ) > ) ; )')
    -- the parts are tokens of the kind of the prefix match
    assert.equal(tokens_of(compiled, 'vec<vec<u8>>;'),
                 'vec:name <:< vec:name <:< u8:name >:> >:> ;:;')
    assert.equal(tokens_of(compiled, 'vec<u8>= x;'),
                 'vec:name <:< u8:name >:> =:= x:name ;:;')
    assert.equal(tokens_of(compiled, 'vec<vec<u8>>= x;'),
                 'vec:name <:< vec:name <:< u8:name >:> >:> =:= x:name ;:;')
    assert.equal(tokens_of(compiled, 'a<b<c<d>>>;'),
                 'a:name <:< b:name <:< c:name <:< d:name >:> >:> >:> ;:;')
    assert.equal(tokens_of(compiled, 'a<b, c<d>>;'),
                 'a:name <:< b:name ,:, c:name <:< d:name >:> >:> ;:;')
    -- a shift is no prefix match
    assert.equal(tokens_of(compiled, 'a >> b;'), 'a:name >>:>> b:name ;:;')
    -- one ">" too many
    local _, err = lexogram.parse(compiled, 'vec<vec<u8>>>;')
    assert.equal(err.message, 'unexpected ">", expected "=", ";"')
    assert.equal(err.pos, 13)
end

function testcase.a_rewind_puts_back_the_token_that_was_split()
    -- without ">>=", ">>=" is ">>" "=", and ">=" is read from the rest of a
    -- split ">>": the tokens read after ">>" are dropped
    local function compile(rules)
        local g = types(rules)
        table.remove(g.symbols, 5)
        return assert(lexogram.compile(g))
    end
    local compiled = compile({
        chunk = 'stat*',
        stat = 'name ">>" "=" name "," / name #">" ">=" ";"',
    })
    assert.equal(tokens_of(compiled, 'a>>=b,'), 'a:name >>:>> =:= b:name ,:,')
    assert.equal(tokens_of(compiled, 'a>>=;'), 'a:name >:> >=:>= ;:;')
    -- the first alternative splits ">>" and fails: the second one reads
    -- ">>" again
    compiled = compile({
        chunk = 'stat*',
        stat = 'name #">" ">" "," / name ">>" name ";"',
    })
    assert.equal(tokens_of(compiled, 'a>>b;'), 'a:name >>:>> b:name ;:;')
    assert.equal(tokens_of(compiled, 'a>>,'), 'a:name >:> >:> ,:,')
    -- the tokens read after ">>" before the split come back on a rewind
    compiled = compile({
        chunk = 'stat*',
        stat = '(name ">>" "=" "," / name #">" ">=" ";") / name ">>" "=" name',
    })
    assert.equal(tokens_of(compiled, 'a>>=b'), 'a:name >>:>> =:= b:name')
    assert.equal(tokens_of(compiled, 'a>>=,'), 'a:name >>:>> =:= ,:,')
    assert.equal(tokens_of(compiled, 'a>>=;'), 'a:name >:> >=:>= ;:;')
end

function testcase.a_possessive_repetition_enters_on_a_token_to_split()
    local compiled = assert(lexogram.compile(types({
        chunk = '(name (#">" ">" name)*+ (">>" name)? ";")*',
    })))
    assert.equal(tokens_of(compiled, 'a >>b ;'), 'a:name >:> >:> b:name ;:;')
    assert.equal(tokens_of(compiled, 'a ;'), 'a:name ;:;')
end

function testcase.a_prefix_match_of_a_token_takes_its_longest_part()
    -- gt is ">", shadowed by nothing but ">>"
    local compiled = assert(lexogram.compile(grammar({
        chunk = '(type ";" | name ">>" name ";")*',
        type = 'name ("<" type #gt)?',
    })))
    assert.equal(tokens_of(compiled, 'a<b<c>>;'),
                 'a:name <:< b:name <:< c:name >:gt >:gt ;:;')
    -- the lookaheads of the token see the input after the part
    local g = grammar({
        chunk = '(type ";" | name ">>" name ";")*',
        type = 'name ("<" type (#joint | gt))?',
    })
    g.tokens.joint = '">" (?=">")'
    g.tokens.gt = '">" (?!">")'
    compiled = assert(lexogram.compile(g))
    assert.equal(tokens_of(compiled, 'a<b<c>>;'),
                 'a:name <:< b:name <:< c:name >:joint >:gt ;:;')
    assert.equal(tokens_of(compiled, 'a<b>;'), 'a:name <:< b:name >:gt ;:;')
end

function testcase.a_prefix_match_of_a_keyword_splits_a_name()
    -- blanks do not separate words: "doi" is "do" "i"
    local g = grammar({
        chunk = '(#"do" name ";")*',
    })
    g.keywords = {
        'do',
    }
    local compiled = assert(lexogram.compile(g))
    assert.equal(tokens_of(compiled, 'doi;do j;'),
                 'do:do i:name ;:; do:do j:name ;:;')
    -- with ignore_case, every spelling
    g.keywords.ignore_case = true
    compiled = assert(lexogram.compile(g))
    assert.equal(tokens_of(compiled, 'DOi;Do j;'),
                 'DO:do i:name ;:; Do:do j:name ;:;')
end

function testcase.a_dumped_grammar_keeps_its_prefix_matches()
    local compiled = assert(lexogram.compile(types({
        chunk = '(type ";")*',
        type = 'name (#"<" type #">")?',
    })))
    local again = assert(lexogram.undump(assert(lexogram.dump(compiled))))
    assert.equal(tokens_of(again, 'a<b<c>>;'),
                 'a:name <:< b:name <:< c:name >:> >:> ;:;')
end

function testcase.a_prefix_match_of_a_delimited_token_matches_it_as_it_is()
    local g = grammar({
        chunk = '(#str ";")*',
    })
    g.tokens.str = {
        open = '"\\""',
        close = '"\\""',
    }
    local compiled = assert(lexogram.compile(g))
    assert.is_nil(compiled.lexer.prefixes)
    assert.equal(tokens_of(compiled, '"a";'), '"a":str ;:;')
    local _, err = lexogram.parse(compiled, 'a;')
    assert.equal(err.message, 'unexpected name, expected end of input, str')
end

function testcase.a_prefix_match_fails_on_a_token_without_its_part()
    local compiled = assert(lexogram.compile(types({
        chunk = '(name #">" (">" | ">=") ";")*',
    })))
    assert.equal(tokens_of(compiled, 'a>>;'), 'a:name >:> >:> ;:;')
    assert.equal(tokens_of(compiled, 'a>>=;'), 'a:name >:> >=:>= ;:;')
    local _, err = lexogram.parse(compiled, 'a ;')
    assert.equal(err.message, 'unexpected ";", expected ">"')
    assert.equal(err.pos, 3)
end

function testcase.a_prefix_match_splits_a_contextual_keyword()
    local g = grammar({
        chunk = '("<" #"g" name ";" | #name ";")*',
    })
    g.keywords = {
        'g',
        contextual = {
            'global',
        },
    }
    local compiled = assert(lexogram.compile(g))
    -- "global" is read as the keyword where a rule expects it, and is a
    -- name here: "g" takes its start
    assert.equal(tokens_of(compiled, '< gx ; < global ;'),
                 '<:< g:g x:name ;:; <:< g:g lobal:name ;:;')
    -- "#name" takes a contextual keyword as a name, as it is
    assert.equal(tokens_of(compiled, 'global ;'), 'global:name ;:;')
end
