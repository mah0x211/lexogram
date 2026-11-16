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
-- to an unterminated token
local function lex(compiled, source)
    local out = {}
    local pos = 1
    while true do
        local kind, stop, unterminated =
            tokenizer.tokenize(compiled, source, pos)
        if not kind then
            return out
        end
        local name = compiled.kinds[kind].name
        out[#out + 1] = name .. ':' .. source:sub(pos, stop - 1) ..
                            (unterminated and '!' or '')
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
        true,
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
