local testcase = require('testcase')
local assert = require('assert')
local loader = require('lexogram.loader')
local open = io.open
local remove = os.remove
local tmpname = os.tmpname
local dump = string.dump

-- the testcase runner executes a test file with its own directory as the
-- working directory, so the repository root is one level up
local ROOT = '../'
local FIXTURES = ROOT .. 'test/fixtures/loader/'

-- load the fixture name and return the error, which must be a string
local function load_err(name)
    local grammar, err = loader.load(FIXTURES .. name .. '.lua')
    assert.is_nil(grammar)
    assert.is_string(err)
    return err
end

-- return a writable temporary pathname: under .codex/tmp/ when that
-- directory exists (local development), otherwise from os.tmpname
local function tmp_pathname(name)
    local pathname = ROOT .. '.codex/tmp/' .. name
    local f = open(pathname, 'wb')
    if f then
        f:close()
        return pathname
    end
    return tmpname()
end

local function write_file(pathname, content)
    local f = assert(open(pathname, 'wb'))
    assert(f:write(content))
    f:close()
end

-- arguments

function testcase.load_raises_for_non_string_pathname()
    local err = assert.throws(loader.load, nil)
    assert.match(err, 'pathname must be string, got nil')

    err = assert.throws(loader.load, 1)
    assert.match(err, 'pathname must be string, got number')
end

function testcase.load_returns_error_for_pathname_with_nul_byte()
    -- plain.lua exists, so a pathname cut at the NUL byte would load it
    local grammar, err = loader.load(FIXTURES .. 'plain.lua\0.txt')

    assert.is_nil(grammar)
    assert.equal(err, 'pathname must not contain a NUL byte')
end

-- successful loads

function testcase.load_returns_grammar_table()
    local grammar, err = loader.load(FIXTURES .. 'plain.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        name = 'plain',
        list = {
            'a',
            'b',
        },
    })
end

function testcase.load_ignores_extra_return_values()
    local grammar, err = loader.load(FIXTURES .. 'extra_returns.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        value = 1,
    })
end

function testcase.load_returns_fresh_table_on_each_call()
    local first = assert(loader.load(FIXTURES .. 'plain.lua'))
    first.list[1] = 'changed'

    local second = assert(loader.load(FIXTURES .. 'plain.lua'))

    assert.not_rawequal(first, second)
    assert.equal(second.list, {
        'a',
        'b',
    })
end

function testcase.load_provides_pairs_ipairs_and_import()
    local grammar, err = loader.load(FIXTURES .. 'builtins.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        keys = {
            a = 1,
        },
        list = {
            'x',
            'y',
        },
        imported = {
            name = 'plain',
            list = {
                'a',
                'b',
            },
        },
        hyphen = {
            name = 'with-hyphen_1',
        },
    })
end

-- failures

function testcase.load_returns_error_for_unreadable_file()
    local err = load_err('no_such_file')
    assert.match(err, FIXTURES .. 'no_such_file.lua')

    -- a directory cannot be read as a file
    local grammar
    grammar, err = loader.load(ROOT .. 'test/fixtures/loader')
    assert.is_nil(grammar)
    assert.match(err, ROOT .. 'test/fixtures/loader')
end

function testcase.load_returns_error_for_syntax_error()
    local err = load_err('syntax_error')

    assert.match(err, FIXTURES .. 'syntax_error.lua:2:')
end

function testcase.load_rejects_bytecode()
    local pathname = tmp_pathname('loader_bytecode.lua')
    write_file(pathname, dump(function()
        return {}
    end))

    local grammar, err = loader.load(pathname)
    remove(pathname)

    assert.is_nil(grammar)
    assert.match(err, pathname .. ': attempt to load a binary chunk')
end

function testcase.load_returns_error_for_runtime_error()
    local err = load_err('runtime_error')

    assert.match(err, FIXTURES .. 'runtime_error.lua:2: attempt to index')
end

function testcase.load_returns_error_for_undefined_variable()
    local err = load_err('undefined_variable')

    assert.equal(err, FIXTURES ..
                     "undefined_variable.lua:3: undefined variable 'undefined_name'")
end

function testcase.load_returns_error_for_global_assignment()
    assert.equal(load_err('assign_global'), FIXTURES ..
                     "assign_global.lua:2: assignment to global variable 'new_global'")
    assert.equal(load_err('assign_import'), FIXTURES ..
                     "assign_import.lua:1: assignment to global variable 'import'")
    assert.equal(load_err('assign_pairs'), FIXTURES ..
                     "assign_pairs.lua:1: assignment to global variable 'pairs'")
end

function testcase.load_returns_error_for_non_table_result()
    assert.equal(load_err('not_table'), FIXTURES ..
                     'not_table.lua: grammar must return a table, got string')
    assert.equal(load_err('no_return'), FIXTURES ..
                     'no_return.lua: grammar must return a table, got nil')
end

-- import

function testcase.import_returns_independent_deep_copies()
    local grammar, err = loader.load(FIXTURES .. 'import_twice.lua')

    assert.is_nil(err)
    -- the importer modified its first copy only
    assert.equal(grammar, {
        a = {
            list = {
                'changed',
            },
            added = true,
        },
        b = {
            list = {
                'a',
            },
        },
    })
    assert.not_rawequal(grammar.a.list, grammar.b.list)
end

function testcase.import_executes_file_once_per_load()
    local strlib = getmetatable('').__index
    local count = 0
    strlib.lexogram_loader_test_count = function()
        count = count + 1
    end

    local first, err1 = loader.load(FIXTURES .. 'import_twice.lua')
    local count_after_first = count
    local second, err2 = loader.load(FIXTURES .. 'import_twice.lua')
    strlib.lexogram_loader_test_count = nil

    assert.is_nil(err1)
    assert.is_nil(err2)
    assert.equal(count_after_first, 1)
    -- nothing is cached across load calls
    assert.equal(count, 2)
    assert.not_rawequal(first.b, second.b)
    assert.equal(second.b, {
        list = {
            'a',
        },
    })
end

function testcase.import_preserves_shared_and_cyclic_references()
    local grammar, err = loader.load(FIXTURES .. 'import_shared.lua')
    assert.is_nil(err)

    local keys = {}
    for _, name in ipairs({
        'a',
        'b',
    }) do
        local copy = grammar[name]
        assert.rawequal(copy.x, copy.y)
        assert.equal(copy.x, {
            value = 1,
        })
        assert.rawequal(copy.cyclic.self, copy.cyclic)
        for k, v in pairs(copy) do
            if type(k) == 'table' then
                -- a table key is copied and stays shared with its value
                assert.rawequal(k, v)
                assert.equal(k.name, 'key')
                keys[name] = k
            end
        end
    end
    assert.not_rawequal(grammar.a.x, grammar.b.x)
    assert.not_rawequal(grammar.a.cyclic, grammar.b.cyclic)
    assert.is_table(keys.a)
    assert.is_table(keys.b)
    assert.not_rawequal(keys.a, keys.b)
end

function testcase.import_resolves_relative_to_importing_file()
    local grammar, err = loader.load(FIXTURES .. 'sub/entry.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        middle = {
            leaf = {
                where = 'sub',
            },
        },
    })
end

function testcase.import_returns_error_for_circular_import()
    assert.equal(load_err('self_import'),
                 FIXTURES .. 'self_import.lua: circular import: ' .. FIXTURES ..
                     'self_import.lua -> ' .. FIXTURES .. 'self_import.lua')

    local err = load_err('cycle_a')
    assert.match(err,
                 FIXTURES .. 'cycle_c.lua:1: circular import: ' .. FIXTURES ..
                     'cycle_a.lua -> ' .. FIXTURES .. 'cycle_b.lua -> ' ..
                     FIXTURES .. 'cycle_c.lua -> ' .. FIXTURES .. 'cycle_a.lua')
    -- the chain of failing imports is reported from the top-level file
    assert.match(err, FIXTURES .. 'cycle_a.lua:1: cannot import "cycle_b": ')
end

function testcase.import_returns_error_for_invalid_name()
    assert.equal(load_err('import_number'),
                 FIXTURES .. 'import_number.lua:1: invalid import name: number')
    assert.equal(load_err('import_empty'),
                 FIXTURES .. 'import_empty.lua:1: invalid import name: ""')
    assert.equal(load_err('import_slash'), FIXTURES ..
                     'import_slash.lua:1: invalid import name: "sub/leaf"')
    assert.equal(load_err('import_dot'), FIXTURES ..
                     'import_dot.lua:1: invalid import name: "plain.lua"')
end

function testcase.import_error_names_file_after_tail_call()
    -- "return import(...)" is a tail call, so the line is not available
    assert.equal(load_err('import_dot_tail'), FIXTURES ..
                     'import_dot_tail.lua: invalid import name: "plain.lua"')
end

function testcase.import_returns_error_for_missing_file()
    local err = load_err('import_missing')

    assert.match(err,
                 FIXTURES ..
                     'import_missing.lua:1: cannot import "no_such_file": ' ..
                     FIXTURES .. 'no_such_file.lua')
end

function testcase.import_returns_error_raised_in_imported_file()
    local err = load_err('import_error')
    assert.match(err,
                 FIXTURES ..
                     'import_error.lua:2: cannot import "runtime_error": ' ..
                     FIXTURES .. 'runtime_error.lua:2: attempt to index')

    err = load_err('import_not_table')
    assert.equal(err,
                 FIXTURES ..
                     'import_not_table.lua:1: cannot import "not_table": ' ..
                     FIXTURES ..
                     'not_table.lua: grammar must return a table, got string')

    err = load_err('import_nested_error')
    assert.match(err,
                 FIXTURES ..
                     'import_nested_error.lua:1: cannot import "import_error": ' ..
                     FIXTURES .. 'import_error.lua:2: cannot import')
    assert.match(err, FIXTURES .. 'runtime_error.lua:2: attempt to index')
end

-- pathname normalization

function testcase.load_normalizes_pathname_in_messages()
    -- repeated separators are collapsed
    local grammar, err = loader.load(ROOT ..
                                         'test/fixtures/loader//no_such_file.lua')
    assert.is_nil(grammar)
    assert.match(err, '^%.%./test/fixtures/loader/no_such_file%.lua: ', false)

    -- "." segments are dropped, also in the circular import chain
    grammar, err = loader.load('./' .. ROOT ..
                                   'test/fixtures/./loader/self_import.lua')
    assert.is_nil(grammar)
    assert.equal(err,
                 FIXTURES .. 'self_import.lua: circular import: ' .. FIXTURES ..
                     'self_import.lua -> ' .. FIXTURES .. 'self_import.lua')
end

function testcase.load_keeps_parent_segments()
    local grammar, err = loader.load(FIXTURES .. 'sub/../no_such_file.lua')

    assert.is_nil(grammar)
    assert.match(err, '^%.%./test/fixtures/loader/sub/%.%./no_such_file%.lua: ',
                 false)
end

function testcase.load_returns_grammar_through_unnormalized_pathname()
    for _, pathname in ipairs({
        ROOT .. 'test//fixtures/./loader/plain.lua',
        './' .. FIXTURES .. 'plain.lua/',
        FIXTURES .. 'sub/../plain.lua',
    }) do
        local grammar, err = loader.load(pathname)

        assert.is_nil(err)
        assert.equal(grammar, {
            name = 'plain',
            list = {
                'a',
                'b',
            },
        })
    end

    -- imports resolve against the normalized pathname
    local grammar, err = loader.load('.//' .. FIXTURES .. './/sub/./entry.lua')
    assert.is_nil(err)
    assert.equal(grammar, {
        middle = {
            leaf = {
                where = 'sub',
            },
        },
    })
end

function testcase.load_normalizes_empty_pathname()
    -- the result names a directory, which cannot be loaded as a grammar
    for _, case in ipairs({
        {
            '',
            '^%.: ',
        },
        {
            './',
            '^%.: ',
        },
        {
            '//',
            '^/: ',
        },
    }) do
        local grammar, err = loader.load(case[1])

        assert.is_nil(grammar)
        assert.match(err, case[2], false)
    end
end

-- directory traversal through import

-- load the loader module again with io.open wrapped so that every pathname
-- opened after the module is loaded is recorded; the module keeps the
-- wrapper it captured. rawset avoids luacheck's read-only field warning.
local function load_spied_loader()
    local io_open = io.open
    local recording = false
    local opened = {}
    rawset(io, 'open', function(pathname, ...)
        if recording then
            opened[#opened + 1] = pathname
        end
        return io_open(pathname, ...)
    end)
    local saved = package.loaded['lexogram.loader']
    package.loaded['lexogram.loader'] = nil
    local ok, spied = pcall(require, 'lexogram.loader')
    package.loaded['lexogram.loader'] = saved
    rawset(io, 'open', io_open)
    assert(ok, spied)
    recording = true
    return spied, opened
end

function testcase.import_rejects_names_that_leave_the_directory()
    local dir = FIXTURES .. 'traversal/'
    for _, case in ipairs({
        {
            'dotdot',
            '..',
        },
        {
            'parent_plain',
            '../plain',
        },
        {
            'slash',
            'sub/leaf',
        },
        {
            'backslash',
            'sub\\leaf',
        },
        {
            'absolute',
            '/etc/passwd',
        },
        {
            'extension',
            'plain.lua',
        },
        {
            'nul',
            'plain' .. string.char(0),
        },
        {
            'nul_traversal',
            'plain' .. string.char(0) .. '/../x',
        },
        {
            'newline',
            'plain\n',
        },
        {
            'leading_space',
            ' plain',
        },
        {
            'trailing_space',
            'plain ',
        },
        {
            'empty',
            '',
        },
        {
            'drive',
            'C:plain',
        },
    }) do
        local spied, opened = load_spied_loader()
        local pathname = dir .. case[1] .. '.lua'

        local grammar, err = spied.load(pathname)

        assert.is_nil(grammar)
        assert.equal(err,
                     pathname .. ':1: invalid import name: "' .. case[2] .. '"')
        -- only the importing file itself was opened
        assert.equal(opened, {
            pathname,
        })
    end
end

function testcase.import_does_not_reach_valid_grammar_outside_directory()
    -- plain.lua exists one level above traversal/, and traversal/plain
    -- exists without the extension (reachable only by NUL truncation), yet
    -- neither is returned
    assert.is_table(loader.load(FIXTURES .. 'plain.lua'))
    assert.is_table(loader.load(FIXTURES .. 'traversal/plain'))

    for _, name in ipairs({
        'parent_plain',
        'nul',
        'nul_traversal',
    }) do
        local grammar, err = loader.load(
                                 FIXTURES .. 'traversal/' .. name .. '.lua')

        assert.is_nil(grammar)
        assert.match(err, 'invalid import name')
    end
end
