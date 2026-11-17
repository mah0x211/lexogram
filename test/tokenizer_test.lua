local testcase = require('testcase')
local assert = require('assert')
local tokenizer = require('lexogram.tokenizer')
local compile = require('lexogram.compile')
local char = string.char

-- compile grammar fields into a compiled object; it must have no errors
local function compiled_of(fields)
    local grammar = {
        lexogram = '2026.11.15.1',
        start = 'chunk',
        rules = {
            chunk = 'name*',
        },
    }
    for k, v in pairs(fields) do
        grammar[k] = v
    end
    local compiled, diagnostics = compile.compile(grammar)
    for _, d in ipairs(diagnostics) do
        assert.not_equal(d.severity, 'error')
    end
    return assert(compiled)
end

local LUA = compiled_of({
    tokens = {
        name = '(ALPHA | "_") (ALPHA | DIGIT | "_")*',
        number = '_digits ("." _digits)? (("e" | "E") ("+" | "-")? _digits)?' ..
            ' | "0x" HEXDIGIT+',
        _digits = 'DIGIT+',
        string = '"\\"" ([^"\\\\\\n] | "\\\\" ANY)* "\\""',
        space = '[ \\t\\r\\n]+',
        comment = '"--" [^\\n]*',
        long_string = {
            open = '"[" level "["',
            close = '"]" level "]"',
            level = '"="*',
        },
        long_comment = {
            open = '"--[" level "["',
            close = '"]" level "]"',
            level = '"="*',
        },
    },
    symbols = {
        '.',
        '..',
        '...',
        '<',
        '<=',
        '-',
        '[',
        ']',
        '=',
    },
    keywords = {
        'if',
        'then',
        ignore_case = true,
    },
    skip = {
        'space',
    },
})

-- tokenize source completely; each token is "name:text", with "!" appended
-- to an unterminated token and "?" to a token with a forbidden nested open
local function lex(compiled, source)
    local out = {}
    local pos = 1
    while true do
        local kind, stop, problem = tokenizer.tokenize(compiled, source, pos)
        if not kind then
            return out
        end
        local name = compiled.kinds[kind].name
        out[#out + 1] = name .. ':' .. source:sub(pos, stop - 1) ..
                            (problem == 'unterminated' and '!' or '') ..
                            (problem == 'nested' and '?' or '')
        pos = stop
    end
end

-- arguments

function testcase.tokenize_returns_nil_at_end_of_input()
    assert.is_nil(tokenizer.tokenize(LUA, '', 1))
    assert.is_nil(tokenizer.tokenize(LUA, 'abc', 4))
    assert.equal(select('#', tokenizer.tokenize(LUA, 'abc', 4)), 1)
end

function testcase.tokenize_accepts_default_mode()
    assert.equal({
        tokenizer.tokenize(LUA, 'abc', 1, 'default'),
    }, {
        LUA.names.name,
        4,
    })
    assert.equal({
        tokenizer.tokenize(LUA, 'abc', 1, nil),
    }, {
        LUA.names.name,
        4,
    })
end

function testcase.tokenize_raises_for_invalid_arguments()
    for _, case in ipairs({
        {
            {
                nil,
                'a',
                1,
            },
            'compiled must be table, got nil',
        },
        {
            {
                LUA,
                1,
                1,
            },
            'source must be string, got number',
        },
        {
            {
                LUA,
                'a',
                '1',
            },
            'pos must be integer, got string',
        },
        {
            {
                LUA,
                'a',
                1.5,
            },
            'pos must be integer, got number',
        },
        {
            {
                LUA,
                'a',
                0,
            },
            'pos must be in range 1 to 2',
        },
        {
            {
                LUA,
                'a',
                3,
            },
            'pos must be in range 1 to 2',
        },
        {
            {
                LUA,
                'a',
                1,
                'x',
            },
            'mode must be nil or "default"',
        },
    }) do
        local args = case[1]
        local err = assert.throws(tokenizer.tokenize, args[1], args[2], args[3],
                                  args[4])
        assert.match(err, case[2])
    end
end

-- longest match and literal priority

function testcase.tokenize_prefers_longest_match_and_literals()
    assert.equal(lex(LUA, 'if iffy IF iF then'), {
        'if:if',
        'space: ',
        'name:iffy',
        'space: ',
        'if:IF',
        'space: ',
        'if:iF',
        'space: ',
        'then:then',
    })
    assert.equal(lex(LUA, '....< <= <<='), {
        '...:...',
        '.:.',
        '<:<',
        'space: ',
        '<=:<=',
        'space: ',
        '<:<',
        '<=:<=',
    })
end

function testcase.tokenize_reads_numbers_strings_and_comments()
    assert.equal(lex(LUA, '1 1.5 2e10 3.0E-2 0xFf 0x 1..2'), {
        'number:1',
        'space: ',
        'number:1.5',
        'space: ',
        'number:2e10',
        'space: ',
        'number:3.0E-2',
        'space: ',
        'number:0xFf',
        'space: ',
        'number:0',
        'name:x',
        'space: ',
        'number:1',
        '..:..',
        'number:2',
    })
    assert.equal(lex(LUA, '"a\\"b" "c\\\\" "d\nx'), {
        'string:"a\\"b"',
        'space: ',
        'string:"c\\\\"',
        'space: ',
        'INVALID:"',
        'name:d',
        'space:\n',
        'name:x',
    })
    assert.equal(lex(LUA, 'a - b -- c\n-'), {
        'name:a',
        'space: ',
        '-:-',
        'space: ',
        'name:b',
        'space: ',
        'comment:-- c',
        'space:\n',
        '-:-',
    })
end

-- INVALID

function testcase.tokenize_returns_one_byte_invalid_tokens()
    assert.equal(lex(LUA, '@a$b' .. char(255) .. char(195, 169) .. '#'), {
        'INVALID:@',
        'name:a',
        'INVALID:$',
        'name:b',
        'INVALID:' .. char(255),
        'INVALID:' .. char(195),
        'INVALID:' .. char(169),
        'INVALID:#',
    })
    assert.equal({
        tokenizer.tokenize(LUA, 'ab@cd', 3),
    }, {
        1,
        4,
    })
end

-- delimited tokens

function testcase.tokenize_reads_long_strings_and_comments()
    assert.equal(lex(LUA, '[[a]] [==[a]]b]=]c]==] [[]] [=[]=]'), {
        'long_string:[[a]]',
        'space: ',
        'long_string:[==[a]]b]=]c]==]',
        'space: ',
        'long_string:[[]]',
        'space: ',
        'long_string:[=[]=]',
    })
    assert.equal(lex(LUA, '[[ [[nested]] ]]'), {
        'long_string:[[ [[nested]]',
        'space: ',
        ']:]',
        ']:]',
    })
    assert.equal(lex(LUA, '--[[c]] --[=[x]]y]=] -- l\n--x\n-'), {
        'long_comment:--[[c]]',
        'space: ',
        'long_comment:--[=[x]]y]=]',
        'space: ',
        'comment:-- l',
        'space:\n',
        'comment:--x',
        'space:\n',
        '-:-',
    })
    -- an incomplete open falls back to the main automaton
    assert.equal(lex(LUA, '[= [x'), {
        '[:[',
        '=:=',
        'space: ',
        '[:[',
        'name:x',
    })
end

function testcase.tokenize_marks_unterminated_delimited_tokens()
    local source = 'x [==[abc]=]'
    assert.equal({
        tokenizer.tokenize(LUA, source, 3),
    }, {
        LUA.names.long_string,
        #source + 1,
        'unterminated',
    })
    assert.equal(lex(LUA, '--[[ open'), {
        'long_comment:--[[ open!',
    })
    assert.equal(lex(LUA, '[['), {
        'long_string:[[!',
    })
end

function testcase.tokenize_matches_close_starting_with_capture()
    local compiled = compiled_of({
        tokens = {
            heredoc = {
                open = '"<<" tag ":"',
                close = 'tag ">>"',
                tag = 'ALPHA+',
            },
            quoted = {
                open = 'q "{"',
                close = 'q',
                q = '"%" DIGIT',
            },
            tail = {
                open = '"$" tag',
                close = '";" tag',
                tag = 'ALPHA+',
            },
            name = 'ALPHA+',
        },
    })

    -- a capture that is the last item of open may run to the end of input
    assert.equal(lex(compiled, '$abc x;abc'), {
        'tail:$abc x;abc',
    })
    assert.equal(lex(compiled, '$abc'), {
        'tail:$abc!',
    })
    assert.equal(lex(compiled, '<<EOF:a EO>> EOFX EOF>>z'), {
        'heredoc:<<EOF:a EO>> EOFX EOF>>',
        'name:z',
    })
    assert.equal(lex(compiled, '%1{a%2%1b'), {
        'quoted:%1{a%2%1',
        'name:b',
    })
    assert.equal(lex(compiled, '%1{%1'), {
        'quoted:%1{%1',
    })
    assert.equal(lex(compiled, '<<A:A>'), {
        'heredoc:<<A:A>!',
    })
    assert.equal(lex(compiled, '%3{%'), {
        'quoted:%3{%!',
    })
end

-- coverage property

-- tokens from 1 to the end must be consecutive and cover every byte
local function check_cover(compiled, source)
    local pos = 1
    local count = 0
    while true do
        local kind, stop = tokenizer.tokenize(compiled, source, pos)
        if not kind then
            break
        end
        assert.greater(stop, pos)
        assert.less_or_equal(stop, #source + 1)
        assert.is_table(compiled.kinds[kind])
        pos = stop
        count = count + 1
    end
    assert.equal(pos, #source + 1)
    return count
end

function testcase.tokenize_covers_every_byte()
    local source = 'local x = [==[a]]b]==] -- note\n' ..
                       'f("s\\"", 1.5e3, nil..y) --[[ c\n]] x<=y?'
    assert.equal(check_cover(LUA, source), #lex(LUA, source))
    assert.equal(lex(LUA, source), {
        'name:local',
        'space: ',
        'name:x',
        'space: ',
        '=:=',
        'space: ',
        'long_string:[==[a]]b]==]',
        'space: ',
        'comment:-- note',
        'space:\n',
        'name:f',
        'INVALID:(',
        'string:"s\\""',
        'INVALID:,',
        'space: ',
        'number:1.5e3',
        'INVALID:,',
        'space: ',
        'name:nil',
        '..:..',
        'name:y',
        'INVALID:)',
        'space: ',
        'long_comment:--[[ c\n]]',
        'space: ',
        'name:x',
        '<=:<=',
        'name:y',
        'INVALID:?',
    })

    local state = 99
    local function rand(n)
        state = (16807 * state) % 2147483647
        return state % n
    end
    local pieces = {
        'a',
        'Z',
        '1',
        '.',
        '-',
        '[',
        ']',
        '=',
        '"',
        '\\',
        ' ',
        '\n',
        '<',
        'x',
    }
    for _ = 1, 200 do
        local parts = {}
        for i = 1, rand(201) do
            if rand(4) == 0 then
                parts[i] = char(rand(256))
            else
                parts[i] = pieces[rand(#pieces) + 1]
            end
        end
        check_cover(LUA, table.concat(parts))
    end
end

-- nest

local NESTED = compiled_of({
    tokens = {
        name = '[a-z]+',
        space = '" "+',
        -- nested comments as in Rust or OCaml
        block = {
            open = '"/*"',
            close = '"*/"',
            nest = 'count',
        },
        -- a level 0 long bracket that forbids nesting, as in Lua 5.1
        long0 = {
            open = '"[["',
            close = '"]]"',
            nest = 'error',
        },
        -- long brackets with levels that count nesting of the same level
        long = {
            open = '"[" level "["',
            close = '"]" level "]"',
            level = '"="+',
            nest = 'count',
        },
        -- the open is also the close: the close is tried first
        bar = {
            open = '"|"',
            close = '"|"',
            nest = 'count',
        },
    },
    rules = {
        chunk = '(name | block | long0 | long | bar)*',
    },
})

function testcase.tokenize_counts_nested_opens()
    assert.equal(lex(NESTED, '/* a /* b */ c */ x'), {
        'block:/* a /* b */ c */',
        'space: ',
        'name:x',
    })
    assert.equal(lex(NESTED, '/* /* */'), {
        'block:/* /* */!',
    })
    -- only an open with the same captured bytes nests
    assert.equal(lex(NESTED, '[=[ [==[ ]=] x'), {
        'long:[=[ [==[ ]=]',
        'space: ',
        'name:x',
    })
    assert.equal(lex(NESTED, '[=[ [=[ ]=] ]=] x'), {
        'long:[=[ [=[ ]=] ]=]',
        'space: ',
        'name:x',
    })
    assert.equal(lex(NESTED, '|a|b|'), {
        'bar:|a|',
        'name:b',
        'bar:|!',
    })
end

function testcase.tokenize_nests_only_opens_with_the_same_capture()
    local compiled = compiled_of({
        tokens = {
            name = '[a-z]+',
            space = '" "+',
            heredoc = {
                open = '"<<" tag ":"',
                close = 'tag ">>"',
                tag = '[A-Z]+',
                nest = 'count',
            },
        },
        rules = {
            chunk = '(name | heredoc)*',
        },
    })

    -- <<ABD: has a capture of the same length but other bytes: not nested
    assert.equal(lex(compiled, '<<ABC: <<ABD: ABC>> x'), {
        'heredoc:<<ABC: <<ABD: ABC>>',
        'space: ',
        'name:x',
    })
    assert.equal(lex(compiled, '<<ABC: <<ABC: ABC>> ABC>> x'), {
        'heredoc:<<ABC: <<ABC: ABC>> ABC>>',
        'space: ',
        'name:x',
    })
end

function testcase.tokenize_reports_forbidden_nested_opens()
    local source = '[[ a [[ b ]] c'
    -- the token still ends at its first close; the fourth value is the
    -- position of the nested open
    assert.equal({
        tokenizer.tokenize(NESTED, source, 1),
    }, {
        NESTED.names.long0,
        13,
        'nested',
        6,
    })
    assert.equal(lex(NESTED, source), {
        'long0:[[ a [[ b ]]?',
        'space: ',
        'name:c',
    })
    assert.equal(lex(NESTED, '[[ a ]]'), {
        'long0:[[ a ]]',
    })
    -- a forbidden open in an unterminated token is reported as nested
    assert.equal({
        tokenizer.tokenize(NESTED, '[[ [[', 1),
    }, {
        NESTED.names.long0,
        6,
        'nested',
        4,
    })
end

function testcase.compile_keeps_the_nest_setting()
    local nests = {}
    for _, entry in ipairs(NESTED.lexer.delimited) do
        nests[NESTED.kinds[entry.id].name] = entry.nest or 'none'
    end

    assert.equal(nests, {
        block = 'count',
        long0 = 'error',
        long = 'count',
        bar = 'count',
    })
    local plain = compiled_of({
        tokens = {
            name = '[a-z]+',
            long = {
                open = '"[["',
                close = '"]]"',
            },
        },
        rules = {
            chunk = '(name | long)*',
        },
    })
    assert.is_nil(plain.lexer.delimited[1].nest)
end

-- Lua 5.1 long brackets: level 0 rejects a nested [[, the levels with "="
-- do not; the long comment is "--" followed by either, and the line
-- comment is a pattern token. doc is a counted block behind "#".
local PREFIXED = compiled_of({
    tokens = {
        name = '[a-z]+',
        space = '[ \\n]+',
        comment = '"--" [^\\n]*',
        long_string = {
            open = '"[["',
            close = '"]]"',
            nest = 'error',
        },
        long_level = {
            open = '"[" level "["',
            close = '"]" level "]"',
            level = '"="+',
        },
        long_comment = {
            prefix = '"--"',
            match = {
                'long_string',
                'long_level',
            },
        },
        block = {
            open = '"(*"',
            close = '"*)"',
            nest = 'count',
        },
        doc = {
            prefix = '"#"',
            match = {
                'block',
            },
        },
    },
    rules = {
        chunk = '(name | long_string | long_level | block | doc)*',
    },
})

function testcase.tokenize_reads_prefixed_delimited_tokens()
    assert.equal(lex(PREFIXED, '--[[ a ]] x -- y\n--[x\n---[[ z'), {
        'long_comment:--[[ a ]]',
        'space: ',
        'name:x',
        'space: ',
        'comment:-- y',
        'space:\n',
        'comment:--[x',
        'space:\n',
        'comment:---[[ z',
    })
    -- the long comment wins over the longer line comment
    assert.equal(lex(PREFIXED, '--[==[ ]=] ]==] x'), {
        'long_comment:--[==[ ]=] ]==]',
        'space: ',
        'name:x',
    })
    -- the named table is still a token of its own
    assert.equal(lex(PREFIXED, '[[ a ]][=[ b ]=]'), {
        'long_string:[[ a ]]',
        'long_level:[=[ b ]=]',
    })
end

function testcase.tokenize_nests_prefixed_tokens_by_the_named_table()
    -- a nested open is the open of the named table, without the prefix
    assert.equal(lex(PREFIXED, '--[[ a [[ b ]] c'), {
        'long_comment:--[[ a [[ b ]]?',
        'space: ',
        'name:c',
    })
    assert.equal({
        tokenizer.tokenize(PREFIXED, '--[[ a --[[ b ]]', 1),
    }, {
        PREFIXED.names.long_comment,
        17,
        'nested',
        10,
    })
    assert.equal(lex(PREFIXED, '--[=[ [[ ]] ]=]'), {
        'long_comment:--[=[ [[ ]] ]=]',
    })
    assert.equal(lex(PREFIXED, '#(* a (* b *) c #(* d *) *) e'), {
        'doc:#(* a (* b *) c #(* d *) *)',
        'space: ',
        'name:e',
    })
    assert.equal(lex(PREFIXED, '--[=[ a'), {
        'long_comment:--[=[ a!',
    })
end

-- a shebang line as a leading token, and "#" as the length operator
local LEADING = compiled_of({
    tokens = {
        name = '[a-z]+',
        space = '[ \\n]+',
        shebang = '"#" [^\\n]*',
        long = {
            open = '"#["',
            close = '"]"',
        },
    },
    symbols = {
        '#',
    },
    leading = {
        'shebang',
    },
    skip = {
        'shebang',
    },
    rules = {
        chunk = '("#" name | long | name)*',
    },
})

function testcase.tokenize_tries_leading_tokens_at_the_start_only()
    assert.equal(lex(LEADING, '#!/bin/lua\n#t #x'), {
        'shebang:#!/bin/lua',
        'space:\n',
        '#:#',
        'name:t',
        'space: ',
        '#:#',
        'name:x',
    })
    -- at the start, a leading token wins over a literal of the same length
    -- and over the open of a delimited token
    assert.equal(lex(LEADING, '#'), {
        'shebang:#',
    })
    assert.equal(lex(LEADING, '#[a] #[b]'), {
        'shebang:#[a] #[b]',
    })
    -- the start of input only, not the start of a later call
    assert.equal({
        tokenizer.tokenize(LEADING, 'a #[b]', 3),
    }, {
        LEADING.names.long,
        7,
    })
    -- without a match at the start, tokenizing goes on as usual
    assert.equal(lex(LEADING, 'a #b'), {
        'name:a',
        'space: ',
        '#:#',
        'name:b',
    })
end

function testcase.compile_keeps_the_leading_automaton_apart()
    assert.equal(LEADING.lexer.leading.accept[1], 0)
    assert.equal(LEADING.kinds[LEADING.names.shebang], {
        name = 'shebang',
        category = 'token',
        skip = true,
    })
    assert.is_nil(NESTED.lexer.leading)
end
