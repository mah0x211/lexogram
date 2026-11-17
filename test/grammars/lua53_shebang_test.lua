local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local NAME = 'lexogram:lua53_shebang'
local BOM = '\239\187\191'
local COMPILED, BASE

-- run fn with the coverage hook removed: compiling the full grammar takes
-- far too long under luacov's line hook
local function without_hook(fn, ...)
    local hook, mask, count = debug.gethook()
    debug.sethook()
    local res = {
        pcall(fn, ...),
    }
    if hook then
        debug.sethook(hook, mask, count)
    end
    if not res[1] then
        error(res[2], 0)
    end
    return res[2], res[3]
end

local function compiled_of(name)
    local grammar = assert(lexogram.load(name))
    local compiled, diagnostics = without_hook(lexogram.compile, grammar)
    assert.equal(diagnostics, {})
    return compiled
end

local function compiled()
    COMPILED = COMPILED or compiled_of(NAME)
    return COMPILED
end

local function base()
    BASE = BASE or compiled_of('lexogram:lua53')
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

function testcase.grammar_is_lua53_with_a_leading_shebang()
    local grammar = assert(lexogram.load(NAME))
    local lua53 = assert(lexogram.load('lexogram:lua53'))

    assert.equal(grammar.name, 'lua53_shebang')
    assert.equal(grammar.version, '1.0.0')
    assert.equal(grammar.leading, {
        'shebang',
    })
    -- apart from its name and the shebang token, it is lua53
    grammar.name, grammar.version = lua53.name, lua53.version
    grammar.tokens.shebang = nil
    grammar.leading = nil
    grammar.skip[#grammar.skip] = nil
    assert.equal(grammar, lua53)
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
    -- the official parser, and so lua53, rejects both
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

    assert.equal(fn(), lexogram.load(NAME))
end
