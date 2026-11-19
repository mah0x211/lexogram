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
    assert.equal(load_err('import_dot'), FIXTURES ..
                     'import_dot.lua:1: invalid import name: "plain.lua"')
end

function testcase.import_reaches_files_below_the_directory()
    local grammar, err = loader.load(FIXTURES .. 'import_slash.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        where = 'sub',
    })
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
            'trailing_slash',
            'sub/',
        },
        {
            'double_slash',
            'sub//leaf',
        },
        {
            'inner_dotdot',
            'sub/../plain',
        },
        {
            'builtin_dotdot',
            'lexogram:../plain',
        },
        {
            'builtin_slash',
            'lexogram:sub/leaf',
        },
        {
            'other_prefix',
            'other:plain',
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

-- extends

local EXTENDS = ROOT .. 'test/fixtures/extends/'

function testcase.extends_merges_into_the_base_through_every_level()
    local grammar, err = loader.load(EXTENDS .. 'grandchild.lua')

    assert.is_nil(err)
    assert.equal(grammar, {
        lexogram = '2026.11.15.1',
        name = 'grandchild',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '[ \\n]+',
            number = 'DIGIT+',
            shebang = '"#" [^\\n]*',
        },
        skip = {
            'space',
            'shebang',
        },
        leading = {
            'shebang',
        },
        rules = {
            chunk = '(name | number)*',
        },
    })
    -- the merged grammar compiles
    local compiled, diagnostics = require('lexogram').compile(grammar)
    assert.is_table(compiled)
    assert.equal(diagnostics, {})
end

function testcase.extends_resolves_names_from_the_file_that_writes_them()
    -- deep extends sub/inner, and sub/inner extends sub/leaf
    assert.equal(loader.load(EXTENDS .. 'deep.lua'), {
        lexogram = '2026.11.15.1',
        name = 'deep',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
        },
        rules = {
            chunk = 'name',
            other = 'name',
        },
    })
    -- a file may import and extend the same grammar
    assert.equal(loader.load(EXTENDS .. 'import_and_extend.lua'),
                 loader.load(EXTENDS .. 'base.lua'))
end

-- the grammar of the test module lexogram.grammars.mini
local function mini()
    return {
        lexogram = '2026.11.15.1',
        name = 'mini',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
        },
        rules = {
            chunk = 'name*',
        },
    }
end

-- run fn with lexogram.grammars.mini defined by package.preload
local function with_mini(fn)
    package.preload['lexogram.grammars.mini'] = function()
        return mini
    end
    local ok, err = pcall(fn)
    package.preload['lexogram.grammars.mini'] = nil
    package.loaded['lexogram.grammars.mini'] = nil
    assert(ok, err)
end

function testcase.extends_reads_built_in_grammars()
    with_mini(function()
        local grammar, err = loader.load(EXTENDS .. 'from_builtin.lua')

        assert.is_nil(err)
        assert.equal(grammar, mini())
        -- a built-in grammar is read by its name, as a new copy each time
        local a = assert(loader.load('lexogram:mini'))
        assert.equal(a, mini())
        a.start = 'changed'
        assert.equal(loader.load('lexogram:mini'), mini())
    end)

    -- no module has that name
    local grammar, err = loader.load(EXTENDS .. 'builtin_missing.lua')
    assert.is_nil(grammar)
    assert.equal(err, EXTENDS .. 'builtin_missing.lua: cannot extend' ..
                     ' "lexogram:none_such": no built-in grammar named' ..
                     ' "none_such" (module lexogram.grammars.none_such not' ..
                     ' found)')
    grammar, err = loader.load('lexogram:none_such')
    assert.is_nil(grammar)
    assert.equal(err, 'lexogram:none_such: no built-in grammar named' ..
                     ' "none_such" (module lexogram.grammars.none_such not' ..
                     ' found)')
end

function testcase.extends_reports_errors()
    local function err_of(name)
        local grammar, err = loader.load(EXTENDS .. name .. '.lua')
        assert.is_nil(grammar)
        return err
    end

    assert.equal(err_of('self'),
                 EXTENDS .. 'self.lua: circular extends: ' .. EXTENDS ..
                     'self.lua -> ' .. EXTENDS .. 'self.lua')
    assert.match(err_of('cycle_a'),
                 EXTENDS .. 'cycle_b.lua: circular' .. ' extends: ' .. EXTENDS ..
                     'cycle_a.lua -> ' .. EXTENDS .. 'cycle_b.lua -> ' ..
                     EXTENDS .. 'cycle_a.lua', true)
    assert.match(err_of('missing'),
                 EXTENDS .. 'missing.lua: cannot extend "nothing": ', true)
    assert.equal(err_of('bad_name'),
                 EXTENDS .. 'bad_name.lua: invalid extends name: "../base"')
    assert.equal(err_of('number_name'),
                 EXTENDS .. 'number_name.lua: invalid extends name: number')
    assert.equal(err_of('bad_merge'),
                 EXTENDS .. 'bad_merge.lua: tokens.name: already exists')
end

-- mixins

local MIXINS = ROOT .. 'test/fixtures/mixins/'

-- the base grammar of the fixtures of mixins
local function mixin_base()
    return {
        lexogram = '2026.11.15.1',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '[ \\n]+',
        },
        skip = {
            'space',
        },
        rules = {
            chunk = 'name*',
        },
    }
end

function testcase.embeds_applies_mixins_after_the_base()
    local grammar, err, warnings = loader.load(MIXINS .. 'grammar.lua')

    assert.is_nil(err)
    assert.equal(warnings, {})
    -- bom extends shebang: shebang adds the token, bom replaces it
    local expected = mixin_base()
    expected.name = 'grammar'
    expected.version = '1.0.0'
    expected.tokens.shebang = '"\\xEF\\xBB\\xBF" ("#" [^\\n]*)? | "#" [^\\n]*'
    expected.leading = {
        'shebang',
    }
    expected.skip[2] = 'shebang'
    assert.equal(grammar, expected)
    -- the merged grammar compiles
    local compiled, diagnostics = require('lexogram').compile(grammar)
    assert.is_table(compiled)
    assert.equal(diagnostics, {})

    -- a mixin extends a mixin named from its own file
    grammar = assert(loader.load(MIXINS .. 'deep.lua'))
    assert.equal(grammar.rules, {
        chunk = 'other*',
        other = 'name',
    })
end

function testcase.embeds_skips_what_exists_with_warnings()
    local grammar, err, warnings = loader.load(MIXINS .. 'warn.lua')

    assert.is_nil(err)
    -- space adds what the base has; hash replaces what shebang added
    local expected = mixin_base()
    expected.name = 'warn'
    expected.version = '1.0.0'
    expected.tokens.shebang = '"#!" [^\\n]*'
    expected.leading = {
        'shebang',
    }
    expected.skip[2] = 'shebang'
    assert.equal(grammar, expected)
    assert.equal(warnings, {
        {
            severity = 'warning',
            code = 'already_defined',
            path = 'skip',
            message = 'skip already has "space"; it is not added',
            source = MIXINS .. 'space.lua',
        },
        {
            severity = 'warning',
            code = 'already_defined',
            path = 'tokens.space',
            message = 'tokens.space already exists; it is not added',
            source = MIXINS .. 'space.lua',
        },
    })
    -- the warnings of a grammar that is extended are returned too
    local _
    _, err, warnings = loader.load(MIXINS .. 'nested.lua')
    assert.is_nil(err)
    assert.equal(#warnings, 2)
end

function testcase.embeds_applies_the_difference_of_the_grammar_last()
    local grammar = assert(loader.load(MIXINS .. 'own.lua'))
    assert.equal(grammar.tokens.shebang, '"#!" [^\\n]*')
    assert.equal(grammar.skip, {
        'space',
    })
    -- the difference of the grammar itself is as strict as for extends
    local _, err = loader.load(MIXINS .. 'own_adds.lua')
    assert.equal(err, MIXINS .. 'own_adds.lua: leading: already has "shebang"')
end

function testcase.embeds_applies_mixins_to_a_grammar_without_extends()
    local grammar, err, warnings = loader.load(MIXINS .. 'no_extends.lua')

    assert.is_nil(err)
    assert.equal(warnings, {})
    -- the grammar is a complete table, which the mixin is applied to
    assert.equal(grammar, {
        lexogram = '2026.11.15.1',
        name = 'no_extends',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            shebang = '"#" [^\\n]*',
        },
        leading = {
            'shebang',
        },
        skip = {
            'shebang',
        },
        rules = {
            chunk = 'name*',
        },
    })
    local compiled, diagnostics = require('lexogram').compile(grammar)
    assert.is_table(compiled)
    assert.equal(diagnostics, {})
end

function testcase.embeds_reports_errors()
    local function err_of(name)
        local grammar, err = loader.load(MIXINS .. name .. '.lua')
        assert.is_nil(grammar)
        assert.is_string(err)
        return err
    end

    assert.equal(err_of('twice'),
                 MIXINS .. 'twice.lua: cannot embed "' .. MIXINS ..
                     'shebang.lua": it is already embedded through "' .. MIXINS ..
                     'bom.lua"')
    assert.equal(err_of('not_mixin'), MIXINS ..
                     'not_mixin.lua: cannot embed "base": it is not a mixin')
    assert.equal(err_of('extends_mixin'),
                 MIXINS .. 'extends_mixin.lua: cannot extend "shebang": it is' ..
                     ' a mixin (embed it with embeds)')
    assert.equal(err_of('no_extends_error'),
                 MIXINS .. 'no_extends_error.lua: ' .. MIXINS ..
                     'removes.lua: rules.none: does not exist')
    local through = '": it is already embedded through "'
    assert.equal(err_of('no_extends_twice'),
                 MIXINS .. 'no_extends_twice.lua: cannot embed "' .. MIXINS ..
                     'shebang.lua' .. through .. MIXINS .. 'bom.lua"')
    assert.equal(err_of('bad_embeds'),
                 MIXINS .. 'bad_embeds.lua: embeds must' ..
                     ' be a non-empty array of names')
    assert.equal(err_of('bad_embeds_name'), MIXINS .. 'bad_embeds_name.lua:' ..
                     ' invalid embeds name: "../shebang"')
    assert.match(err_of('missing'),
                 MIXINS .. 'missing.lua: cannot embed "nothing": ', true)
    assert.match(err_of('embed_cycle'),
                 MIXINS .. 'cycle_b.lua: circular extends: ' .. MIXINS ..
                     'embed_cycle.lua -> ' .. MIXINS .. 'cycle_a.lua -> ' ..
                     MIXINS .. 'cycle_b.lua -> ' .. MIXINS .. 'cycle_a.lua',
                 true)
    -- an error of a mixin names the mixin
    assert.equal(err_of('mixin_error'),
                 MIXINS .. 'mixin_error.lua: ' .. MIXINS ..
                     'removes.lua: rules.none: does not exist')
    assert.equal(err_of('imports_mixin'), MIXINS .. 'imports_mixin.lua:1:' ..
                     ' cannot import "shebang": it is a mixin')
end

function testcase.mixins_are_checked_and_not_loaded_as_grammars()
    local function err_of(name)
        local grammar, err = loader.load(MIXINS .. name .. '.lua')
        assert.is_nil(grammar)
        assert.is_string(err)
        return err
    end

    assert.equal(err_of('shebang'), MIXINS .. 'shebang.lua: a mixin is not a' ..
                     ' grammar (embed it with embeds)')
    assert.equal(err_of('bad_mixin'),
                 MIXINS .. 'bad_mixin.lua: name: required' ..
                     ' field name is missing\n' .. MIXINS ..
                     'bad_mixin.lua: version: version must match' ..
                     ' ^[0-9A-Za-z._+-]+$, got "1 0"')
    assert.equal(err_of('bad_shape'), MIXINS .. 'bad_shape.lua: +skip: the' ..
                     ' value must be an array of items')
    assert.equal(err_of('mixin_extends_grammar'),
                 MIXINS .. 'mixin_extends_grammar.lua: cannot extend "base":' ..
                     ' it is not a mixin')
end

function testcase.embeds_reads_built_in_mixins()
    local new = require('lexogram.grammar')
    package.preload['lexogram.grammars.mini_shebang'] = function()
        return assert(new({
            mixin = true,
            lexogram = '2026.11.15.1',
            name = 'mini_shebang',
            version = '1.0.0',
            ['++tokens'] = {
                shebang = '"#" [^\\n]*',
            },
            ['+leading'] = {
                'shebang',
            },
            ['+skip'] = {
                'shebang',
            },
        }))
    end
    with_mini(function()
        local grammar, err, warnings = loader.load(MIXINS .. 'from_builtin.lua')
        assert.is_nil(err)
        assert.equal(warnings, {})
        local expected = mini()
        expected.name = 'from_builtin'
        expected.tokens.shebang = '"#" [^\\n]*'
        expected.leading = {
            'shebang',
        }
        expected.skip = {
            'shebang',
        }
        assert.equal(grammar, expected)
        -- a built-in mixin is no grammar either
        grammar, err = loader.load('lexogram:mini_shebang')
        assert.is_nil(grammar)
        assert.equal(err, 'lexogram:mini_shebang: a mixin is not a grammar' ..
                         ' (embed it with embeds)')
    end)
    package.preload['lexogram.grammars.mini_shebang'] = nil
    package.loaded['lexogram.grammars.mini_shebang'] = nil
end
