local testcase = require('testcase')
local assert = require('assert')
local grammar = require('lexogram.grammar')

-- a complete grammar
local function base()
    return {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '" "+',
        },
        skip = {
            'space',
        },
        rules = {
            chunk = 'name*',
        },
    }
end

-- the function of the built-in grammar base
local function builtin_base()
    local g = base()
    g.name = 'base'
    return g
end

-- define the module lexogram.grammars.<name> to return value, run fn and
-- remove the module again
local function with_module(name, value, fn)
    local module = 'lexogram.grammars.' .. name
    package.preload[module] = function()
        return value
    end
    local ok, err = pcall(fn)
    package.preload[module] = nil
    package.loaded[module] = nil
    assert(ok, err)
end

function testcase.new_returns_a_function_of_new_copies()
    local def = base()
    local fn, err, diagnostics = grammar(def)

    assert.is_nil(err)
    assert.equal(diagnostics, {})
    assert.is_function(fn)
    local a = fn()
    assert.equal(a, base())
    -- neither the definition nor a result changes the others
    a.tokens.name = 'changed'
    def.start = 'changed'
    assert.equal(fn(), base())
    -- the chunk is named after the grammar
    assert.equal(debug.getinfo(fn, 'S').source, '=lexogram.grammar:test@1.0.0')
    -- each call runs the table constructors again
    assert.not_rawequal(fn(), fn())
    assert.not_rawequal(fn().tokens, fn().tokens)
    assert.rawequal(grammar.new, grammar.new)
end

function testcase.new_merges_a_grammar_that_extends_a_built_in_one()
    with_module('base', builtin_base, function()
        local fn = assert(grammar({
            extends = 'lexogram:base',
            name = 'derived',
            version = '2.0.0',
            ['++tokens'] = {
                number = 'DIGIT+',
            },
            rules = {
                ['=chunk'] = '(name | number)*',
            },
        }))
        local expected = base()
        expected.name = 'derived'
        expected.version = '2.0.0'
        expected.tokens.number = 'DIGIT+'
        expected.rules.chunk = '(name | number)*'

        assert.equal(fn(), expected)
    end)
end

function testcase.new_reports_errors_of_the_check()
    local def = base()
    def.rules.chunk = 'name* other'
    local fn, err, diagnostics = grammar(def)

    assert.is_nil(fn)
    assert.equal(err, 'rules.chunk: rules.chunk refers to undefined token' ..
                     ' or rule "other"')
    assert.equal(diagnostics[1].code, 'undefined_reference')

    -- one line for each error
    def.start = 1
    fn, err = grammar(def)
    assert.is_nil(fn)
    assert.equal(select(2, err:gsub('\n', '')) + 1, 2)
    -- warnings are no errors, and are returned with the function
    def = base()
    def.rules.unused = 'name'
    fn, err, diagnostics = grammar(def)
    assert.is_function(fn)
    assert.is_nil(err)
    assert.equal(#diagnostics, 1)
    assert.equal(diagnostics[1].severity, 'warning')
    assert.equal(diagnostics[1].code, 'unreachable_rule')
end

function testcase.new_reports_errors_of_extends()
    local function err_of(def)
        local fn, err, diagnostics = grammar(def)
        assert.is_nil(fn)
        assert.is_nil(diagnostics)
        return err
    end

    assert.equal(err_of('x'), 'grammar must be a table, got string')
    assert.equal(err_of({
        extends = 'base',
    }), 'extends must name a built-in grammar ("lexogram:<name>"), got base')
    assert.equal(err_of({
        extends = 'lexogram:none_such',
    }), 'cannot extend "lexogram:none_such": no built-in grammar named' ..
                     ' "none_such" (module lexogram.grammars.none_such not found)')
    with_module('base', builtin_base, function()
        assert.equal(err_of({
            extends = 'lexogram:base',
            ['++tokens'] = {
                name = '"x"',
            },
        }), 'tokens.name: already exists')
    end)
end

function testcase.builtin_reports_modules_of_other_shapes()
    with_module('table', base(), function()
        assert.equal(select(2, grammar.builtin('table')),
                     'module lexogram.grammars.table must return a function,' ..
                         ' got table')
    end)
    with_module('string', function()
        return 'x'
    end, function()
        assert.equal(select(2, grammar.builtin('string')),
                     'module lexogram.grammars.string must return a function' ..
                         ' that returns a table, got string')
    end)
    -- the module must define the grammar of its name
    with_module('other', function()
        return base()
    end, function()
        assert.equal(select(2, grammar.builtin('other')),
                     'module lexogram.grammars.other defines the grammar test')
    end)
    -- other errors of require are passed on as they are
    package.preload['lexogram.grammars.broken'] = function()
        error('broken module', 0)
    end
    local g, err = grammar.builtin('broken')
    package.preload['lexogram.grammars.broken'] = nil
    assert.is_nil(g)
    assert.equal(err, 'broken module')
end

function testcase.built_in_grammars_have_no_warnings()
    -- the built-in grammars are the modules installed by the rockspec; the
    -- test runner executes a test file with its own directory as the
    -- working directory
    local f = assert(io.open('../rockspecs/lexogram-scm-1.rockspec'))
    local spec = f:read('*a')
    f:close()
    local modules = {}
    for module in spec:gmatch('"(lexogram%.grammars%.[%w_]+)"') do
        modules[#modules + 1] = module
    end
    assert(#modules > 0)

    -- record what lexogram.grammar returns while the modules are loaded
    -- again; the check runs without the coverage hook, under which it takes
    -- far too long
    local returned = {}
    local loaded = {}
    package.loaded['lexogram.grammar'] = setmetatable({
        new = grammar.new,
        builtin = grammar.builtin,
    }, {
        __call = function(_, def)
            local fn, err, diagnostics = grammar(def)
            returned[#returned + 1] = {
                def.name,
                diagnostics,
            }
            return fn, err, diagnostics
        end,
    })
    for _, module in ipairs(modules) do
        loaded[module] = package.loaded[module]
        package.loaded[module] = nil
    end
    local hook, mask, count = debug.gethook()
    debug.sethook()
    local ok, err = pcall(function()
        for _, module in ipairs(modules) do
            require(module)
        end
    end)
    if hook then
        debug.sethook(hook, mask, count)
    end
    package.loaded['lexogram.grammar'] = grammar
    for _, module in ipairs(modules) do
        package.loaded[module] = loaded[module]
    end
    assert(ok, err)

    assert.equal(#returned, #modules)
    for _, r in ipairs(returned) do
        assert.equal(r, {
            r[1],
            {},
        })
    end
end

-- mixins

-- a mixin that adds a number token
local function number_mixin()
    return {
        mixin = true,
        lexogram = '2026.11.15.1',
        name = 'number',
        version = '1.0.0',
        ['++tokens'] = {
            number = 'DIGIT+',
        },
        rules = {
            ['=chunk'] = '(name | number)*',
        },
    }
end

-- a mixin that extends the mixin number
local function hex_mixin()
    return {
        mixin = true,
        extends = 'lexogram:number',
        lexogram = '2026.11.15.1',
        name = 'hex',
        version = '1.0.0',
        tokens = {
            ['=number'] = '"0x" HEXDIGIT+ | DIGIT+',
        },
    }
end

-- define base, number and hex as built-in modules and run fn
local function with_mixins(fn)
    with_module('base', builtin_base, function()
        with_module('number', assert(grammar(number_mixin())), function()
            with_module('hex', assert(grammar(hex_mixin())), fn)
        end)
    end)
end

function testcase.new_defines_a_mixin()
    with_module('number', assert(grammar(number_mixin())), function()
        local fn, err, diagnostics = grammar(hex_mixin())

        assert.is_nil(err)
        assert.equal(diagnostics, {})
        -- a new copy of the mixin as written
        assert.equal(fn(), hex_mixin())
        assert.not_rawequal(fn(), fn())
        assert.equal(debug.getinfo(fn, 'S').source,
                     '=lexogram.grammar:hex@1.0.0')
        -- the chain of a built-in mixin
        local chain, _, kind = grammar.builtin_value('number')
        assert.equal(kind, 'mixin')
        assert.equal(chain, {
            {
                source = 'lexogram:number',
                diff = number_mixin(),
            },
        })
    end)
end

function testcase.builtin_value_reports_errors_of_the_chain_of_a_mixin()
    -- a built-in module that returns the mixin def as it is, as one that
    -- does not define it with lexogram.grammar can
    local function raw(make, extends)
        return function()
            local def = make()
            def.extends = extends
            return def
        end
    end
    local function err_of(name)
        local value, err = grammar.builtin_value(name)
        assert.is_nil(value)
        return err
    end
    with_module('base', builtin_base, function()
        for _, case in ipairs({
            {
                'number',
                'extends must name a built-in mixin ("lexogram:<name>"),' ..
                    ' got number',
            },
            {
                'lexogram:none',
                'cannot extend "lexogram:none": no built-in grammar named' ..
                    ' "none" (module lexogram.grammars.none not found)',
            },
            {
                'lexogram:base',
                'cannot extend "lexogram:base": it is not a mixin',
            },
        }) do
            with_module('hex', raw(hex_mixin, case[1]), function()
                assert.equal(err_of('hex'), case[2])
            end)
        end
        -- the error of a mixin that it extends
        with_module('number', raw(number_mixin, 'lexogram:base'), function()
            with_module('hex', raw(hex_mixin, 'lexogram:number'), function()
                assert.equal(err_of('hex'),
                             'cannot extend "lexogram:base": it is not a mixin')
            end)
        end)
    end)
end

function testcase.new_reports_errors_of_a_mixin()
    local function err_of(def)
        local fn, err, diagnostics = grammar(def)
        assert.is_nil(fn)
        return err, diagnostics
    end

    -- the metadata
    local def = number_mixin()
    def.name, def.mixin, def.embeds = nil, false, {
        'lexogram:x',
    }
    local err, diagnostics = err_of(def)
    assert.equal(err, 'name: required field name is missing\n' ..
                     'embeds: a mixin cannot embed mixins\n' ..
                     'mixin: mixin must be true, got false')
    assert.equal(#diagnostics, 3)
    -- the shape of the difference
    def = number_mixin()
    def['+skip'] = 'number'
    assert.equal(err_of(def), '+skip: the value must be an array of items')
    -- the mixin it extends
    def = hex_mixin()
    def.extends = 'number'
    assert.equal(err_of(def), 'extends must name a built-in mixin' ..
                     ' ("lexogram:<name>"), got number')
    def.extends = 'lexogram:none_such'
    assert.match(err_of(def),
                 'cannot extend "lexogram:none_such": no built-in' ..
                     ' grammar named "none_such"', true)
    with_module('base', builtin_base, function()
        def.extends = 'lexogram:base'
        assert.equal(err_of(def),
                     'cannot extend "lexogram:base": it is not a mixin')
    end)
    -- a value that has no source text
    def = number_mixin()
    def['=start'] = print
    assert.match(err_of(def), 'start', true)
end

function testcase.new_embeds_built_in_mixins()
    with_mixins(function()
        local fn, err, diagnostics = grammar({
            extends = 'lexogram:base',
            embeds = {
                'lexogram:hex',
            },
            name = 'derived',
            version = '1.0.0',
            ['++rules'] = {
                unused = 'name',
            },
        })

        assert.is_nil(err)
        local expected = base()
        expected.name = 'derived'
        expected.tokens.number = '"0x" HEXDIGIT+ | DIGIT+'
        expected.rules.chunk = '(name | number)*'
        expected.rules.unused = 'name'
        assert.equal(fn(), expected)
        assert.equal(#diagnostics, 1)
        assert.equal(diagnostics[1].code, 'unreachable_rule')

        -- the warnings of the mixins come before those of the check
        with_module('numbers', function()
            local g = base()
            g.name = 'numbers'
            g.tokens.number = 'DIGIT+'
            return g
        end, function()
            fn, err, diagnostics = grammar({
                extends = 'lexogram:numbers',
                embeds = {
                    'lexogram:number',
                },
                name = 'derived',
                version = '1.0.0',
                ['++rules'] = {
                    unused = 'name',
                },
            })
        end)
        assert.is_nil(err)
        assert.is_function(fn)
        assert.equal(diagnostics[1], {
            severity = 'warning',
            code = 'already_defined',
            path = 'tokens.number',
            message = 'tokens.number already exists; it is not added',
            source = 'lexogram:number',
        })
        assert.equal(diagnostics[2].code, 'unreachable_rule')
        assert.equal(#diagnostics, 2)
    end)
end

function testcase.new_reports_errors_of_embeds()
    local function err_of(def)
        local fn, err = grammar(def)
        assert.is_nil(fn)
        return err
    end

    with_mixins(function()
        local def = base()
        def.embeds = {
            'lexogram:number',
        }
        assert.equal(err_of(def), 'embeds needs extends')
        def = {
            extends = 'lexogram:base',
            name = 'derived',
            version = '1.0.0',
        }
        def.embeds = 'lexogram:number'
        assert.equal(err_of(def), 'embeds must be a non-empty array of names')
        def.embeds = {
            'number',
        }
        assert.equal(err_of(def), 'embeds must name built-in mixins' ..
                         ' ("lexogram:<name>"), got number')
        def.embeds = {
            'lexogram:base',
        }
        assert.equal(err_of(def),
                     'cannot embed "lexogram:base": it is not a mixin')
        def.embeds = {
            'lexogram:none_such',
        }
        assert.match(err_of(def), 'cannot embed "lexogram:none_such": no' ..
                         ' built-in grammar named "none_such"', true)
        def.embeds = {
            'lexogram:number',
            'lexogram:hex',
        }
        assert.equal(err_of(def), 'cannot embed "lexogram:number": it is' ..
                         ' already embedded through "lexogram:hex"')
        assert.equal(err_of({
            extends = 'lexogram:number',
            name = 'derived',
            version = '1.0.0',
        }), 'cannot extend "lexogram:number": it is a mixin' ..
                         ' (embed it with embeds)')
    end)
end
