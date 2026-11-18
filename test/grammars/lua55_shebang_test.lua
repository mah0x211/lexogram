local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local NAME = 'lexogram:lua55_shebang'
local BOM = '\239\187\191'
local COMPILED, BASE

-- the file is loaded before the test runner moves to its directory, so the
-- helper is found next to the file itself
local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')

local function compiled_of(name)
    local compiled, diagnostics = shared.compile(name)
    assert.equal(diagnostics, {})
    return compiled
end

local function compiled()
    COMPILED = COMPILED or compiled_of(NAME)
    return COMPILED
end

local function base()
    BASE = BASE or compiled_of('lexogram:lua55')
    return BASE
end

-- the names and texts of the tokens of a parse result
local function tokens(result)
    local out = {}
    for i = 1, result.count do
        if events.op(result, i) == events.TOKEN then
            out[#out + 1] = events.name(result, i) .. ':' ..
                                events.text(result, i)
        end
    end
    return out
end

function testcase.grammar_is_lua55_with_a_leading_shebang()
    local grammar = assert(shared.load(NAME))
    local lua55 = assert(shared.load('lexogram:lua55'))

    assert.equal(grammar.name, 'lua55_shebang')
    assert.equal(grammar.version, '5.5.1-1')
    assert.equal(grammar.leading, {
        'shebang',
    })
    -- apart from its name and the shebang token, it is lua55
    grammar.name, grammar.version = lua55.name, lua55.version
    grammar.tokens.shebang = nil
    grammar.leading = nil
    grammar.skip[#grammar.skip] = nil
    assert.equal(grammar, lua55)
end

function testcase.byte_order_mark_and_shebang_are_skipped()
    for _, case in ipairs({
        {
            '#!/usr/bin/env lua\nx = #t',
            'shebang:#!/usr/bin/env lua',
        },
        {
            BOM .. 'x = #t',
            'shebang:' .. BOM,
        },
        {
            BOM .. '#!/usr/bin/env lua\nx = #t',
            'shebang:' .. BOM .. '#!/usr/bin/env lua',
        },
    }) do
        local result = assert(lexogram.parse(compiled(), case[1]))
        local list = tokens(result)
        assert.equal(list[1], case[2])
        -- "#" after the start is the length operator
        assert.equal(list[#list - 1], '#:#')
    end
    -- the official parser, and so lua55, rejects both
    for _, source in ipairs({
        '#!/usr/bin/env lua\nreturn 1',
        BOM .. 'return 1',
    }) do
        local _, err = lexogram.parse(base(), source)
        assert.equal(err.code, 'syntax_error')
    end
    -- a byte order mark after the start is no shebang
    local _, err = lexogram.parse(compiled(), 'x = 1\n' .. BOM)
    assert.equal(err.code, 'syntax_error')
end

function testcase.merged_source_loads_back_into_the_grammar()
    local src = assert(lexogram.merge(NAME))
    local fn = assert((loadstring or load)(src))

    assert.equal(fn(), shared.load(NAME))
end

function testcase.global_declarations_follow_a_shebang()
    -- the leading token is skipped before the contextual keyword
    local result = assert(lexogram.parse(compiled(),
                                         BOM .. '#!/usr/bin/env lua\nglobal x'))
    assert.equal(tokens(result), {
        'shebang:' .. BOM .. '#!/usr/bin/env lua',
        'space:\n',
        'global:global',
        'space: ',
        'name:x',
    })
end
