local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local loader = require('lexogram.loader')

-- the testcase runner executes a test file with its own directory as the
-- working directory, so the repository root is one level up
local ROOT = '../'

function testcase.load_is_the_loader_function()
    assert.rawequal(lexogram.load, loader.load)
end

function testcase.load_loads_grammar_file()
    local grammar, err = lexogram.load(ROOT .. 'test/fixtures/loader/plain.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        name = 'plain',
        list = {
            'a',
            'b',
        },
    })
end
