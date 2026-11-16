local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local loader = require('lexogram.loader')
local check = require('lexogram.check')
local compile = require('lexogram.compile')

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

function testcase.check_is_the_check_function()
    assert.rawequal(lexogram.check, check.check)
end

function testcase.check_returns_diagnostics_of_loaded_grammar()
    local grammar = assert(lexogram.load(ROOT ..
                                             'test/fixtures/loader/plain.lua'))

    local diagnostics = lexogram.check(grammar)

    assert.equal(diagnostics, {
        {
            severity = 'error',
            code = 'missing_field',
            path = 'lexogram',
            message = 'required field lexogram is missing',
        },
        {
            severity = 'error',
            code = 'missing_field',
            path = 'start',
            message = 'required field start is missing',
        },
        {
            severity = 'error',
            code = 'missing_field',
            path = 'tokens',
            message = 'required field tokens is missing',
        },
        {
            severity = 'error',
            code = 'missing_field',
            path = 'rules',
            message = 'required field rules is missing',
        },
        {
            severity = 'error',
            code = 'unknown_field',
            path = 'list',
            message = 'unknown field list',
        },
        {
            severity = 'error',
            code = 'unknown_field',
            path = 'name',
            message = 'unknown field name',
        },
    })
end

function testcase.compile_is_the_compile_function()
    assert.rawequal(lexogram.compile, compile.compile)
end
