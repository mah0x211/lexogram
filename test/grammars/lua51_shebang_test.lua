local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- the test runner executes a test file with its own directory as the
-- working directory
local ROOT = '../../'
local NAME = 'lexogram:lua51_shebang'
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

local function compiled_of(pathname)
    local grammar = assert(lexogram.load(pathname))
    local compiled, diagnostics = without_hook(lexogram.compile, grammar)
    assert.equal(diagnostics, {})
    return compiled
end

local function compiled()
    COMPILED = COMPILED or compiled_of(NAME)
    return COMPILED
end

local function base()
    BASE = BASE or compiled_of('lexogram:lua51')
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

function testcase.grammar_is_lua51_with_a_leading_shebang()
    local grammar = assert(lexogram.load(NAME))
    local lua51 = assert(lexogram.load('lexogram:lua51'))

    assert.equal(grammar.tokens.shebang, ' "#" [^\\n]* ')
    assert.equal(grammar.leading, {
        'shebang',
    })
    assert.equal(grammar.name, 'lua51_shebang')
    assert.equal(grammar.version, '1.0.0')
    -- apart from its name and the shebang token, it is lua51
    grammar.name, grammar.version = lua51.name, lua51.version
    grammar.tokens.shebang = nil
    grammar.leading = nil
    grammar.skip[#grammar.skip] = nil
    assert.equal(grammar, lua51)
end

function testcase.first_line_starting_with_hash_is_skipped()
    local result = assert(lexogram.parse(compiled(),
                                         '#!/usr/bin/env lua\nlocal n = #t'))

    assert.equal(tokens(result), {
        'shebang:#!/usr/bin/env lua',
        'space:\n',
        'local:local',
        'space: ',
        'name:n',
        'space: ',
        '=:=',
        'space: ',
        '#:#',
        'name:t',
    })
    -- a lone "#" is a shebang line too, as in the loader
    assert(lexogram.parse(compiled(), '#'))
    -- the official parser, and so lua51, rejects the line
    local _, err = lexogram.parse(base(), '#!/usr/bin/env lua\nreturn 1')
    assert.equal(err.code, 'syntax_error')
end

function testcase.sources_without_a_shebang_parse_as_in_lua51()
    local source = 'local t = { 1, 2 }\nreturn #t'
    local a = assert(lexogram.parse(compiled(), source))
    local b = assert(lexogram.parse(base(), source))

    assert.equal(tokens(a), tokens(b))
    -- "#" is the length operator except at the start
    local _, err = lexogram.parse(compiled(), 'x = 1\n#!y')
    assert.equal(err.code, 'syntax_error')
end

function testcase.merged_source_loads_back_into_the_grammar()
    local src = assert(lexogram.merge(NAME))
    local fn = assert((loadstring or load)(src))

    assert.equal(fn(), lexogram.load(NAME))
end

function testcase.lua51_is_a_built_in_grammar()
    -- a grammar file extends the module installed with the library
    assert.equal(lexogram.load(ROOT .. 'test/fixtures/extends/from_lua51.lua'),
                 lexogram.load('lexogram:lua51'))
end
