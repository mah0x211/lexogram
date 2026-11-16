local testcase = require('testcase')
local assert = require('assert')
local delimited = require('lexogram.compile.delimited')
local nfa = require('lexogram.compile.nfa')
local dfa = require('lexogram.compile.dfa')
local pattern = require('lexogram.pattern')

local function build_dfa(src)
    local machine = assert(nfa.build({
        {
            id = 1,
            ast = assert(pattern.parse(src, 'tokens')),
        },
    }, {}))
    return assert(dfa.build(machine, {
        2,
    }))
end

function testcase.examples_returns_shortest_strings()
    local d = build_dfa('"ab" | "b" [c-e] "!"')
    local example = delimited.examples(d)

    assert.equal(example(1), '')
    assert.equal(example(dfa.run(d, 'a')), 'a')
    assert.equal(example(dfa.run(d, 'ab')), 'ab')
    -- the smallest byte of each class is used
    assert.equal(example(dfa.run(d, 'be')), 'bc')
    assert.equal(example(dfa.run(d, 'be!')), 'ab')
end

function testcase.analyze_returns_compiled_table()
    local diagnostics = {}
    local entry, err = delimited.analyze('long', {
        open = '"[" level "["',
        close = '"]" level "]"',
        level = '"="*',
    }, {}, diagnostics)

    assert.is_nil(err)
    assert.equal(diagnostics, {})
    assert.equal(entry.name, 'long')
    assert.equal(entry.token.prefix, 1)
    assert.equal(entry.token.close, {
        {
            literal = ']',
        },
        {
            capture = true,
        },
        {
            literal = ']',
        },
    })
    -- the capture is replaced by a reference to a synthetic fragment
    assert.equal(entry.open.items[2].type, 'ref')
    assert.equal(entry.open.items[2].name, entry.synthetic)
    assert.equal(entry.capture_ast.type, 'star')
    assert.equal(dfa.run(entry.token.capture, '==='), 1)
end

function testcase.analyze_handles_capture_only_open()
    local diagnostics = {}
    local entry = delimited.analyze('tag', {
        open = 'tag',
        close = 'tag',
        tag = '"<" ALPHA+ ">"',
    }, {}, diagnostics)

    assert.equal(diagnostics, {})
    assert.equal(entry.token.prefix, 0)
    assert.equal(entry.open, {
        type = 'ref',
        pos = 0,
        name = entry.synthetic,
    })
    assert.equal(entry.token.close, {
        {
            capture = true,
        },
    })
end

function testcase.analyze_returns_table_without_capture()
    local diagnostics = {}
    local entry = delimited.analyze('c', {
        open = '"/*"',
        close = '"*/"',
    }, {}, diagnostics)

    assert.equal(diagnostics, {})
    assert.is_nil(entry.synthetic)
    assert.equal(entry.token, {
        close = {
            {
                literal = '*/',
            },
        },
    })
end
