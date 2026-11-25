local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')
local extend = require('lexogram.extend').extend

-- a grammar of statements that end with a newline, which is listed in skip:
-- the rules take it where a statement ends, and it is skipped elsewhere (in
-- brackets, on empty lines and after a comment)
local LINES = {
    lexogram = '2026.11.15.1',
    name = 'lines',
    version = '1.0.0',
    start = 'body',
    tokens = {
        name = '[a-z]+',
        ws = '[ \\t]+',
        newline = '"\\n"',
        comment = '"#" [^\\n]*',
    },
    symbols = {
        '=',
        '(',
        ')',
        ',',
        '+',
    },
    skip = {
        'ws',
        'newline',
        'comment',
    },
    rules = {
        body = 'statement*',
        statement = 'simple newline',
        simple = '(name "=")? expr',
        expr = 'term ("+" term)*',
        term = 'primary call*',
        primary = 'name | "(" (expr ("," expr)*)? ")"',
        call = '"(" (expr ("," expr)*)? ")"',
    },
}

-- a grammar whose skipped tokens are spaces and "~", with the given rules
local function tilde(rules)
    return {
        lexogram = '2026.11.15.1',
        name = 'tilde',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            space = '" "+',
            sep = '"~"',
        },
        symbols = {
            'a',
            'b',
            'c',
            'x',
        },
        skip = {
            'space',
            'sep',
        },
        rules = rules,
    }
end

-- the events of source as "(rule" and token texts, with ")" after the last
-- one of a rule, a skipped token as "<kind>" and the kinds in hide left
-- out; the TOKEN events must cover the source
local function shape(compiled, source, hide)
    local result = assert(lexogram.parse(compiled, source))
    local out, text = {}, {}
    for i = 1, result.count do
        local op = events.op(result, i)
        if op == events.ENTER then
            out[#out + 1] = '(' .. events.name(result, i)
        elseif op == events.EXIT then
            out[#out] = out[#out] .. ')'
        else
            local name = events.name(result, i)
            text[#text + 1] = events.text(result, i)
            if not (hide and hide[name]) then
                if compiled.kinds[events.kind(result, i)].skip then
                    out[#out + 1] = '<' .. name .. '>'
                else
                    out[#out + 1] = events.text(result, i)
                end
            end
        end
    end
    assert.equal(table.concat(text), source)
    return table.concat(out, ' ')
end

-- the message of the error of source
local function failure(compiled, source)
    local result, err = lexogram.parse(compiled, source)
    assert.is_nil(result)
    return err.message
end

function testcase.a_rule_takes_a_skipped_token_where_it_can()
    local c = assert(lexogram.compile(LINES))
    local hide = {
        ws = true,
    }

    -- a newline ends a statement, so the next line is the next statement
    assert.equal(shape(c, 'f\n(x)\n', hide),
                 '(body (statement (simple (expr (term (primary f)))) <newline>)' ..
                     ' (statement (simple (expr (term (primary ( (expr (term' ..
                     ' (primary x))) ))))) <newline>))')
    -- in brackets no rule takes it, so the call goes on
    assert.equal(shape(c, '(f\n(x))\n', hide),
                 '(body (statement (simple (expr (term (primary ( (expr (term' ..
                     ' (primary f) <newline> (call ( (expr (term (primary x)))' ..
                     ' )))) ))))) <newline>))')
    assert.equal(shape(c, 'x = (a,\nb)\n', hide),
                 '(body (statement (simple x = (expr (term (primary ( (expr' ..
                     ' (term (primary a))) , <newline> (expr (term (primary b)))' ..
                     ' ))))) <newline>))')
    -- the newlines of empty lines and after a comment are skipped
    assert.equal(shape(c, 'x = a\n\n# note\ny = b\n', hide),
                 '(body (statement (simple x = (expr (term (primary a))))' ..
                     ' <newline>) <newline> <comment> <newline> (statement' ..
                     ' (simple y = (expr (term (primary b)))) <newline>))')
    -- a statement cannot go on after its newline
    assert.equal(failure(c, 'x = a\n+ b\n'),
                 'unexpected "+", expected end of input, name, "("')
    assert.equal(failure(c, 'x'),
                 'unexpected end of input, expected newline, "(", "+"')
end

function testcase.a_skipped_token_can_be_a_token_of_the_rules()
    -- white space between selectors is a combinator, and is skipped around
    -- the other combinators
    local g = {
        lexogram = '2026.11.15.1',
        name = 'selectors',
        version = '1.0.0',
        start = 'selector',
        tokens = {
            name = '[a-z]+',
            ws = '[ \\t\\n]+',
        },
        symbols = {
            '>',
            '+',
            '~',
        },
        skip = {
            'ws',
        },
        rules = {
            selector = 'compound (combinator compound)* ws?',
            compound = 'name',
            combinator = 'ws? (">" | "+" | "~") ws? | ws',
        },
    }
    local c = assert(lexogram.compile(g))

    assert.equal(shape(c, 'a b'),
                 '(selector (compound a) (combinator <ws>)' .. ' (compound b))')
    assert.equal(shape(c, 'a > b'),
                 '(selector (compound a) (combinator <ws> >' ..
                     ' <ws>) (compound b))')
    assert.equal(shape(c, 'a>b'),
                 '(selector (compound a) (combinator >) (compound b))')
    -- no rule takes the space before the first selector; the last one is
    -- taken by ws?
    assert.equal(shape(c, ' a b '), '<ws> (selector (compound a) (combinator' ..
                     ' <ws>) (compound b) <ws>)')
end

function testcase.lookahead_counts_the_skipped_tokens_that_reach_the_rules()
    -- the second token after a skipped one that the rules take
    local c = assert(lexogram.compile(tilde({
        chunk = 'sep "a" | sep "b"',
    })))
    assert.equal(shape(c, '~b'), '(chunk <sep> b)')
    assert.equal(shape(c, '~ a'), '(chunk <sep> <space> a)')

    -- a skipped token as the second token after one of the rules
    c = assert(lexogram.compile(LINES))
    local hide = {
        ws = true,
    }
    assert.equal(shape(c, 'x\ny = z\n', hide),
                 '(body (statement (simple (expr (term (primary x))))' ..
                     ' <newline>) (statement (simple y = (expr (term (primary' ..
                     ' z)))) <newline>))')
end

function testcase.lookahead_follows_the_rules_without_consuming()
    -- the token is taken after an empty alternative of an ordered choice
    local c = assert(lexogram.compile(tilde({
        chunk = '("b"? / "c") sep "a"',
    })))
    assert.equal(shape(c, '~a'), '(chunk <sep> a)')
    assert.equal(shape(c, 'b~a'), '(chunk b <sep> a)')

    -- and after a rule without events that ends with an empty call
    c = assert(lexogram.compile(tilde({
        chunk = '_body sep "c"',
        _body = '"a"? _opt',
        _opt = '"b"?',
    })))
    assert.equal(shape(c, '~c'), '(chunk <sep> c)')
    assert.equal(shape(c, 'ab~c'), '(chunk a b <sep> c)')

    -- the second token after "b", where the repetition of r goes on or r
    -- ends: after r returns, through a tail call and an empty alternative,
    -- the rules expect "a"; inside it, through a call that returns empty,
    -- they take "~"
    c = assert(lexogram.compile(tilde({
        chunk = '_part',
        _part = 'r _tail',
        r = '"a" (_q "b" sep "c")+',
        _q = '"x"?',
        _tail = '("c"? / "a") "b" "a"',
    })))
    assert.equal(shape(c, 'ab~cb~cba'), '(chunk (r a b <sep> c b <sep> c) b a)')
    assert.equal(shape(c, 'ab~cxb~cba'),
                 '(chunk (r a b <sep> c x b <sep> c) b a)')
    assert.equal(shape(c, 'ab~cab a'), '(chunk (r a b <sep> c) a b <space> a)')

    -- no rule takes "~" after "a": the token after it decides
    c = assert(lexogram.compile(tilde({
        chunk = '("a" "b" | "a" "c") sep?',
    })))
    assert.equal(shape(c, 'a~b'), '(chunk a <sep> b)')
    assert.equal(shape(c, 'ac~'), '(chunk a c <sep>)')
end

function testcase.a_skipped_token_taken_by_a_rule_is_in_its_range()
    local c = assert(lexogram.compile(tilde({
        chunk = '"a" tail',
        tail = 'sep "b"',
    })))

    -- the space before "~" is skipped before the rule, the one after it is
    -- between its tokens
    assert.equal(shape(c, 'a ~ b'), '(chunk a <space> (tail <sep> <space> b))')
    assert.equal(shape(c, 'a~b'), '(chunk a (tail <sep> b))')
end

function testcase.an_ordered_choice_tries_an_alternative_from_its_start()
    -- "~" is taken only by the second alternative; the first one is still
    -- tried, as in a parsing expression grammar, and skips it
    local c = assert(lexogram.compile(tilde({
        chunk = '"a" "c" / sep "a" "b"',
    })))

    assert.equal(shape(c, '~a c'), '(chunk <sep> a <space> c)')
    assert.equal(shape(c, '~a b'), '(chunk <sep> a <space> b)')
end

function testcase.a_repetition_decides_from_what_follows_it_too()
    -- a possessive repetition stops where what follows it takes the skipped
    -- token, as an element that cannot start with it is not taken
    local c = assert(lexogram.compile(tilde({
        chunk = '"a"++ sep "b"',
    })))
    assert.equal(shape(c, 'aa~b'), '(chunk a a <sep> b)')
    assert.equal(failure(c, 'aa~a~b'), 'unexpected "a", expected "b"')

    c = assert(lexogram.compile(tilde({
        chunk = '"a"++ sep "a"',
    })))
    assert.equal(shape(c, 'aa~a'), '(chunk a a <sep> a)')

    -- an optional element is not taken after a skipped token that what
    -- follows takes (the compilation does not report such a grammar yet)
    c = assert(lexogram.compile(tilde({
        chunk = '"a" "b"? sep "c"',
    })))
    assert.equal(shape(c, 'a~c'), '(chunk a <sep> c)')
    assert.equal(shape(c, 'ab~c'), '(chunk a b <sep> c)')
    assert.equal(failure(c, 'a~b~c'), 'unexpected "b", expected "c"')
end

function testcase.a_rule_can_take_a_leading_token_listed_in_skip()
    -- a shebang line is taken where the rules can start with it, also as
    -- the first token of a rule
    local g = {
        lexogram = '2026.11.15.1',
        name = 'script',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '[ \\n]+',
            shebang = '"#!" [^\\n]*',
        },
        leading = {
            'shebang',
        },
        skip = {
            'space',
            'shebang',
        },
        rules = {
            chunk = 'shebang? name*',
        },
    }
    local c = assert(lexogram.compile(g))
    assert.equal(shape(c, '#!x\na b'), '(chunk <shebang> <space> a <space> b)')
    assert.equal(shape(c, 'a b'), '(chunk a <space> b)')

    g.rules.chunk = 'name*'
    g.rules.head = 'shebang name'
    g.start = 'top'
    g.rules.top = 'head? chunk'
    c = assert(lexogram.compile(g))
    assert.equal(shape(c, '#!x\na b'),
                 '(top (head <shebang> <space> a) <space> (chunk b))')
    assert.equal(shape(c, 'a b'), '(top (chunk a <space> b))')
end

function testcase.a_prefix_match_does_not_split_a_skipped_token()
    -- the comment starts with "<", but a prefix match splits no skipped
    -- token, also one that the rules refer to: the alternatives are told
    -- apart by their first tokens
    local g = {
        lexogram = '2026.11.15.1',
        name = 'notes',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '" "+',
            comment = '"<!" [^>]* ">"',
        },
        symbols = {
            '<',
        },
        skip = {
            'space',
            'comment',
        },
        rules = {
            chunk = 'item*',
            item = '#"<" name | comment name',
        },
    }
    local c = assert(lexogram.compile(g))
    local hide = {
        space = true,
    }

    assert.equal(shape(c, '<a <!x> b', hide),
                 '(chunk (item < a) (item <comment> b))')
end

function testcase.a_derived_grammar_can_refer_to_a_skipped_token_of_its_base()
    local base = {
        lexogram = '2026.11.15.1',
        name = 'base',
        version = '1.0.0',
        start = 'body',
        tokens = {
            name = '[a-z]+',
            ws = '[ \\t]+',
            newline = '"\\n"',
        },
        symbols = {
            '=',
        },
        skip = {
            'ws',
            'newline',
        },
        rules = {
            body = 'statement*',
            statement = 'name "=" name',
        },
    }
    local hide = {
        ws = true,
    }

    -- the derived rules end a statement with the newline of the base
    local g = assert(extend(base, {
        extends = 'base',
        name = 'lines',
        version = '1.0.0',
        rules = {
            ['=statement'] = 'name "=" name newline',
        },
    }))
    local c = assert(lexogram.compile(g))
    assert.equal(shape(c, 'x = a\n\ny = b\n', hide),
                 '(body (statement x = a <newline>) <newline> (statement y =' ..
                     ' b <newline>))')

    -- removed from skip, the newline is a token of the rules everywhere
    g = assert(extend(base, {
        extends = 'base',
        name = 'lines',
        version = '1.0.0',
        ['-skip'] = {
            'newline',
        },
        rules = {
            ['=statement'] = 'name "=" name newline',
        },
    }))
    c = assert(lexogram.compile(g))
    assert.equal(failure(c, 'x = a\n\ny = b\n'),
                 'unexpected newline, expected end of input, name')
end
