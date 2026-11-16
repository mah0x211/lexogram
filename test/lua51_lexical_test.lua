local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')

-- the testcase runner executes a test file with its own directory as the
-- working directory, so the repository root is one level up
local ROOT = '../'
-- the grammar, its compiled object and diagnostics, loaded on first use (the working
-- directory is only set while the tests run)
local GRAMMAR, COMPILED, DIAGNOSTICS

local function load_grammar()
    if not COMPILED then
        GRAMMAR = assert(lexogram.load(ROOT ..
                                           'bench/grammars/lua51_lexical.lua'))
        -- compile runs check and returns its diagnostics
        COMPILED, DIAGNOSTICS = lexogram.compile(GRAMMAR)
    end
end

-- library sources tokenized here; a subset is enough, because the line
-- hook of the coverage run makes tokenizing slow (bench/tokenize.lua
-- tokenizes every library source and reports the INVALID count)
local LIB_FILES = {
    'lib/compile/limits.lua',
    'lib/compile/utf8range.lua',
    'lib/lexogram.lua',
    'lib/text.lua',
    'lib/tokenizer.lua',
    'lib/utf8.lua',
}

-- tokenize source completely, including skipped tokens; each token is
-- { kind name, text }, with true as a third element when unterminated
local function lex(source)
    load_grammar()
    local out = {}
    local pos = 1
    while true do
        local kind, stop, unterminated =
            lexogram.tokenize(COMPILED, source, pos)
        if not kind then
            return out
        end
        out[#out + 1] = {
            COMPILED.kinds[kind].name,
            source:sub(pos, stop - 1),
            unterminated,
        }
        pos = stop
    end
end

-- tokens from a compact list { name1, text1, name2, text2, ... }
local function tokens(list)
    local out = {}
    for i = 1, #list, 2 do
        out[#out + 1] = {
            list[i],
            list[i + 1],
        }
    end
    return out
end

function testcase.grammar_compiles_without_diagnostics()
    load_grammar()
    -- the diagnostics of check, which compile returns: none at all
    assert.equal(DIAGNOSTICS, {})
    assert.is_table(COMPILED)
    assert.is_table(GRAMMAR)
    -- reserved, pattern tokens, symbols, keywords, delimited tokens, rules
    assert.equal(#COMPILED.kinds, 2 + 5 + 26 + 21 + 2 + 2)
end

function testcase.numbers()
    assert.equal(lex('3 3.0 3.1416 314.16e-2 0.31416E1 0xff 0x56 .5 5.'),
                 tokens({
        'number',
        '3',
        'space',
        ' ',
        'number',
        '3.0',
        'space',
        ' ',
        'number',
        '3.1416',
        'space',
        ' ',
        'number',
        '314.16e-2',
        'space',
        ' ',
        'number',
        '0.31416E1',
        'space',
        ' ',
        'number',
        '0xff',
        'space',
        ' ',
        'number',
        '0x56',
        'space',
        ' ',
        'number',
        '.5',
        'space',
        ' ',
        'number',
        '5.',
    }))
    for _, case in ipairs({
        {
            '1e5',
            {
                'number',
                '1e5',
            },
        },
        {
            '1.5e+10',
            {
                'number',
                '1.5e+10',
            },
        },
        {
            'x1',
            {
                'name',
                'x1',
            },
        },
        {
            '1x',
            {
                'number',
                '1',
                'name',
                'x',
            },
        },
        {
            '0x',
            {
                'number',
                '0',
                'name',
                'x',
            },
        },
        {
            'a.b',
            {
                'name',
                'a',
                '.',
                '.',
                'name',
                'b',
            },
        },
        {
            'a..b',
            {
                'name',
                'a',
                '..',
                '..',
                'name',
                'b',
            },
        },
        {
            'a...b',
            {
                'name',
                'a',
                '...',
                '...',
                'name',
                'b',
            },
        },
        -- divergences from the Lua 5.1 lexer, which reports these as
        -- malformed numbers
        {
            '1..2',
            {
                'number',
                '1.',
                'number',
                '.2',
            },
        },
        {
            '3e',
            {
                'number',
                '3',
                'name',
                'e',
            },
        },
    }) do
        assert.equal(lex(case[1]), tokens(case[2]))
    end
end

function testcase.short_strings()
    for _, case in ipairs({
        {
            '"a\\"b"',
            {
                'string',
                '"a\\"b"',
            },
        },
        {
            "'it\\'s'",
            {
                'string',
                "'it\\'s'",
            },
        },
        {
            '"\\65\\066"',
            {
                'string',
                '"\\65\\066"',
            },
        },
        -- a backslash-newline continues the string
        {
            '"a\\\nb"',
            {
                'string',
                '"a\\\nb"',
            },
        },
        -- an unterminated short string: the quote is INVALID and the rest
        -- is tokenized normally (the Lua 5.1 lexer reports an error)
        {
            '"abc\nx',
            {
                'INVALID',
                '"',
                'name',
                'abc',
                'space',
                '\n',
                'name',
                'x',
            },
        },
    }) do
        assert.equal(lex(case[1]), tokens(case[2]))
    end
end

function testcase.long_brackets()
    for _, case in ipairs({
        {
            '[[x]]',
            {
                'long_string',
                '[[x]]',
            },
        },
        {
            '[==[a]]b]==]',
            {
                'long_string',
                '[==[a]]b]==]',
            },
        },
        {
            '--[[c]]',
            {
                'long_comment',
                '--[[c]]',
            },
        },
        {
            '--[==[c]=]c]==]',
            {
                'long_comment',
                '--[==[c]=]c]==]',
            },
        },
        {
            '--[ not long',
            {
                'comment',
                '--[ not long',
            },
        },
        -- the Lua 5.1 lexer reports an invalid long string delimiter
        {
            '[=x',
            {
                '[',
                '[',
                '=',
                '=',
                'name',
                'x',
            },
        },
    }) do
        assert.equal(lex(case[1]), tokens(case[2]))
    end
    assert.equal(lex('[==[ open'), {
        {
            'long_string',
            '[==[ open',
            true,
        },
    })
end

function testcase.operators()
    for _, case in ipairs({
        {
            'a<=b',
            {
                'name',
                'a',
                '<=',
                '<=',
                'name',
                'b',
            },
        },
        {
            'a<b',
            {
                'name',
                'a',
                '<',
                '<',
                'name',
                'b',
            },
        },
        {
            'a==b',
            {
                'name',
                'a',
                '==',
                '==',
                'name',
                'b',
            },
        },
        {
            'a=b',
            {
                'name',
                'a',
                '=',
                '=',
                'name',
                'b',
            },
        },
        {
            'a~=b',
            {
                'name',
                'a',
                '~=',
                '~=',
                'name',
                'b',
            },
        },
        {
            '~',
            {
                'INVALID',
                '~',
            },
        },
        {
            '#t',
            {
                '#',
                '#',
                'name',
                't',
            },
        },
        {
            '-1',
            {
                '-',
                '-',
                'number',
                '1',
            },
        },
        {
            '--x',
            {
                'comment',
                '--x',
            },
        },
        {
            '- -x',
            {
                '-',
                '-',
                'space',
                ' ',
                '-',
                '-',
                'name',
                'x',
            },
        },
    }) do
        assert.equal(lex(case[1]), tokens(case[2]))
    end
end

function testcase.library_sources_tokenize_without_invalid_tokens()
    load_grammar()
    for _, name in ipairs(LIB_FILES) do
        local f = assert(io.open(ROOT .. name, 'rb'))
        local source = assert(f:read('*a'))
        f:close()

        local pos, invalid = 1, {}
        while true do
            local kind, stop = lexogram.tokenize(COMPILED, source, pos)
            if not kind then
                break
            end
            assert.greater(stop, pos)
            if kind == COMPILED.names.INVALID then
                invalid[#invalid + 1] = name .. ':' .. pos
            end
            pos = stop
        end
        assert.equal(pos, #source + 1)
        assert.equal(invalid, {})
    end
end
