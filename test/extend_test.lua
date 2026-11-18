local testcase = require('testcase')
local assert = require('assert')
local extend = require('lexogram.extend').extend

-- a base grammar with every kind of field
local function base()
    return {
        lexogram = '2026.11.15.1',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '" "+',
            block = {
                open = '"[["',
                close = '"]]"',
                nest = 'error',
            },
        },
        symbols = {
            '=',
            '-',
        },
        keywords = {
            'local',
            'goto',
        },
        skip = {
            'space',
        },
        rules = {
            chunk = 'stat*',
            stat = '"local" name "=" name',
        },
    }
end

-- the error message of extend(base(), diff)
local function err_of(diff)
    local grammar, err = extend(base(), diff)
    assert.is_nil(grammar)
    assert.is_string(err)
    return err
end

function testcase.extend_applies_each_mark()
    local b = base()
    local grammar = extend(b, {
        extends = 'base',
        lexogram = '2026.11.15.1',
        ['=start'] = 'stat',
        ['+keywords'] = {
            'until',
        },
        ['-keywords'] = {
            'goto',
        },
        ['-symbols'] = {
            '-',
        },
        ['+leading'] = {
            'shebang',
        },
        ['++tokens'] = {
            shebang = '"#" [^\\n]*',
        },
        tokens = {
            ['--block'] = {
                'nest',
            },
            ['=name'] = '[a-z_]+',
        },
        ['--rules'] = {
            'stat',
        },
        ['++rules'] = {
            stat = '"local" name',
            other = 'name',
        },
        rules = {
            ['=chunk'] = '(stat | other)*',
        },
    })

    assert.equal(grammar, {
        lexogram = '2026.11.15.1',
        start = 'stat',
        tokens = {
            name = '[a-z_]+',
            space = '" "+',
            shebang = '"#" [^\\n]*',
            block = {
                open = '"[["',
                close = '"]]"',
            },
        },
        symbols = {
            '=',
        },
        keywords = {
            'local',
            'until',
        },
        skip = {
            'space',
        },
        leading = {
            'shebang',
        },
        rules = {
            chunk = '(stat | other)*',
            stat = '"local" name',
            other = 'name',
        },
    })
    -- the base is not changed, and the result shares no table with it
    assert.equal(b, base())
    grammar.skip[1] = 'changed'
    assert.equal(b.skip[1], 'space')
end

function testcase.extend_keeps_the_base_without_differences()
    assert.equal(extend(base(), {
        extends = 'base',
    }), base())
end

function testcase.extend_enters_tables_and_edits_settings()
    local grammar = extend(base(), {
        ['++keywords'] = {
            ignore_case = true,
        },
        tokens = {
            block = {
                ['=open'] = '"<<"',
            },
        },
    })

    assert.equal(grammar.keywords, {
        'local',
        'goto',
        ignore_case = true,
    })
    assert.equal(grammar.tokens.block.open, '"<<"')
    -- an empty table field exists although the base has none
    assert.equal(extend(base(), {
        ['=recover'] = {
            'chunk',
        },
        leading = {},
    }).recover, {
        'chunk',
    })
end

function testcase.extend_reports_missing_targets_and_existing_additions()
    assert.equal(err_of({
        ['+keywords'] = {
            'goto',
        },
    }), 'keywords: already has "goto"')
    assert.equal(err_of({
        ['-keywords'] = {
            'until',
        },
    }), 'keywords: does not have "until"')
    assert.equal(err_of({
        ['++tokens'] = {
            name = '"x"',
        },
    }), 'tokens.name: already exists')
    assert.equal(err_of({
        ['--rules'] = {
            'none',
        },
    }), 'rules.none: does not exist')
    assert.equal(err_of({
        tokens = {
            ['=none'] = '"x"',
        },
    }), 'tokens.none: does not exist')
    assert.equal(err_of({
        tokens = {
            ['--name'] = {
                'x',
            },
        },
    }), 'tokens.name: is not a table')
    assert.equal(err_of({
        tokens = {
            none = {},
        },
    }), 'tokens.none: does not exist')
    assert.equal(err_of({
        tokens = {
            ['++none'] = {
                nest = 'error',
            },
        },
    }), 'tokens.none: does not exist')
    assert.equal(err_of({
        tokens = {
            block = {
                ['++nest'] = 'count',
            },
        },
    }), '++tokens.block.nest: the value must be a table of fields')
end

function testcase.extend_reports_malformed_differences()
    assert.equal(err_of({
        ['+skip'] = 'comment',
    }), '+skip: the value must be an array of items')
    assert.equal(err_of({
        ['-skip'] = {
            x = 'space',
        },
    }), '-skip: the value must be an array of items')
    assert.equal(err_of({
        ['++tokens'] = {
            'x',
        },
    }), '++tokens: the value must be a table of fields')
    assert.equal(err_of({
        ['--tokens'] = {
            1,
        },
    }), '--tokens: the value must be an array of names')
    assert.equal(err_of({
        ['--tokens'] = 'name',
    }), '--tokens: the value must be an array of names')
    assert.equal(err_of({
        start = 'stat',
    }), 'start: a value without a mark must be a table' ..
                     ' (write =start to replace the value)')
    assert.equal(err_of({
        ['=rules'] = {},
        rules = {},
    }), 'rules: =rules and rules cannot be used together')
    assert.equal(err_of({
        ['+-skip'] = {},
    }), 'key "+-skip" has an invalid mark')
    assert.equal(err_of({
        ['='] = {},
    }), 'key "=" has an invalid mark')
    assert.equal(err_of({
        tokens = {
            [1] = {},
        },
    }), 'tokens: key 1 must be a string')
    assert.equal(err_of({
        ['+foo'] = {},
    }), '+foo: unknown field')
    assert.equal(err_of({
        ['++start'] = {},
    }), 'start: is not a table')
end

function testcase.extend_applies_removals_before_additions()
    -- removing and adding the same item or field gives a fresh copy
    local grammar = extend(base(), {
        ['-skip'] = {
            'space',
        },
        ['+skip'] = {
            'space',
        },
        ['--tokens'] = {
            'block',
        },
        ['++tokens'] = {
            block = {
                open = '"("',
                close = '")"',
            },
        },
    })

    assert.equal(grammar.skip, {
        'space',
    })
    assert.equal(grammar.tokens.block, {
        open = '"("',
        close = '")"',
    })
end

function testcase.extend_does_not_inherit_name_and_version()
    local b = base()
    b.name = 'base'
    b.version = '1.2.3'

    local grammar = extend(b, {
        extends = 'base',
    })
    assert.is_nil(grammar.name)
    assert.is_nil(grammar.version)

    grammar = extend(b, {
        extends = 'base',
        name = 'derived',
        version = '1.0.0',
    })
    assert.equal(grammar.name, 'derived')
    assert.equal(grammar.version, '1.0.0')
    -- they are written without a mark: there is nothing to replace
    assert.equal(select(2, extend(b, {
        ['=name'] = 'x',
    })), 'name: does not exist')
end

-- mixins

local validate = require('lexogram.extend').validate
local embeds = require('lexogram.extend').embeds

-- a chain of one mixin
local function chain(source, diff)
    return {
        {
            source = source,
            diff = diff,
        },
    }
end

function testcase.extend_applies_mixins_before_the_difference()
    local grammar, err, warnings = extend(base(), {
        extends = 'base',
        embeds = {
            'a',
        },
        name = 'derived',
        tokens = {
            ['=number'] = 'DIGIT+ ("." DIGIT+)?',
        },
    }, {
        {
            {
                source = 'a',
                diff = {
                    mixin = true,
                    lexogram = '0.0.0',
                    name = 'a',
                    version = '9.9.9',
                    ['++tokens'] = {
                        number = 'DIGIT+',
                    },
                },
            },
            {
                source = 'b',
                diff = {
                    mixin = true,
                    extends = 'a',
                    ['+skip'] = {
                        'number',
                    },
                },
            },
        },
    })

    assert.is_nil(err)
    assert.equal(warnings, {})
    -- the metadata of the mixins is not taken
    assert.equal(grammar.lexogram, '2026.11.15.1')
    assert.equal(grammar.name, 'derived')
    assert.is_nil(grammar.version)
    assert.is_nil(grammar.mixin)
    assert.is_nil(grammar.embeds)
    -- the chain is applied in order, then the difference of the grammar
    assert.equal(grammar.tokens.number, 'DIGIT+ ("." DIGIT+)?')
    assert.equal(grammar.skip, {
        'space',
        'number',
    })
end

function testcase.extend_skips_what_mixins_add_twice_with_warnings()
    local grammar, err, warnings = extend(base(), {}, {
        chain('a', {
            ['+keywords'] = {
                'goto',
                'until',
            },
            ['++tokens'] = {
                name = '"x"',
                number = 'DIGIT+',
            },
        }),
        chain('b', {
            ['++tokens'] = {
                number = 'HEXDIGIT+',
            },
            tokens = {
                ['=space'] = '"\\t"+',
            },
        }),
        chain('c', {
            tokens = {
                ['=space'] = '"\\n"+',
            },
        }),
    })

    assert.is_nil(err)
    -- an addition keeps what exists, wherever it comes from
    assert.equal(grammar.keywords, {
        'local',
        'goto',
        'until',
    })
    assert.equal(grammar.tokens.name, '[a-z]+')
    assert.equal(grammar.tokens.number, 'DIGIT+')
    -- a replacement replaces what an earlier mixin wrote
    assert.equal(grammar.tokens.space, '"\\n"+')
    assert.equal(warnings, {
        {
            severity = 'warning',
            code = 'already_defined',
            path = 'keywords',
            message = 'keywords already has "goto"; it is not added',
            source = 'a',
        },
        {
            severity = 'warning',
            code = 'already_defined',
            path = 'tokens.name',
            message = 'tokens.name already exists; it is not added',
            source = 'a',
        },
        {
            severity = 'warning',
            code = 'already_defined',
            path = 'tokens.number',
            message = 'tokens.number already exists; it is not added',
            source = 'b',
        },
    })
end

function testcase.extend_reports_errors_of_mixins()
    local function mixin_err_of(diff, mixins)
        local grammar, err = extend(base(), diff, mixins)
        assert.is_nil(grammar)
        return err
    end

    -- the other marks work as for extends, and the error names the mixin
    assert.equal(mixin_err_of({}, {
        chain('a', {
            ['--rules'] = {
                'none',
            },
        }),
    }), 'a: rules.none: does not exist')
    assert.equal(mixin_err_of({}, {
        chain('a', {
            tokens = {
                ['=none'] = '"x"',
            },
        }),
    }), 'a: tokens.none: does not exist')
    -- the difference of the grammar itself stays strict
    assert.equal(mixin_err_of({
        ['++tokens'] = {
            number = 'DIGIT+',
        },
    }, {
        chain('a', {
            ['++tokens'] = {
                number = 'DIGIT+',
            },
        }),
    }), 'tokens.number: already exists')
end

function testcase.extend_reports_mixins_embedded_twice()
    local a = {
        source = 'a',
        diff = {},
    }
    local b = {
        source = 'b',
        diff = {},
    }
    local c = {
        source = 'c',
        diff = {},
    }
    local function embed_err_of(...)
        local grammar, err = extend(base(), {}, {
            ...,
        })
        assert.is_nil(grammar)
        return err
    end

    assert.equal(embed_err_of({
        a,
    }, {
        a,
    }), 'cannot embed "a" twice')
    -- b extends a
    assert.equal(embed_err_of({
        a,
    }, {
        a,
        b,
    }), 'cannot embed "a": it is already embedded through "b"')
    assert.equal(embed_err_of({
        a,
        b,
    }, {
        a,
    }), 'cannot embed "a": it is already embedded through "b"')
    -- b and c extend a
    assert.equal(embed_err_of({
        a,
        b,
    }, {
        a,
        c,
    }), 'cannot embed "a" twice: through "b" and "c"')
end

function testcase.validate_checks_the_shape_of_a_mixin()
    -- the targets need not exist, and the metadata is left out
    assert.is_nil(validate({
        mixin = true,
        extends = 'other',
        lexogram = '2026.11.15.1',
        name = 'm',
        version = '1.0.0',
        ['--rules'] = {
            'none',
        },
        tokens = {
            ['=none'] = '"x"',
            block = {
                ['++nest'] = {
                    x = 1,
                },
            },
        },
    }))
    assert.equal(validate({
        ['+skip'] = 'space',
    }), '+skip: the value must be an array of items')
    assert.equal(validate({
        ['+foo'] = {},
    }), '+foo: unknown field')
    assert.equal(validate({
        start = 'x',
    }), 'start: a value without a mark must be a table' ..
                     ' (write =start to replace the value)')
    assert.equal(validate({
        tokens = {
            block = {
                ['--nest'] = 'x',
            },
        },
    }), '--tokens.block.nest: the value must be an array of names')
    assert.equal(validate({
        tokens = {
            [1] = {},
        },
    }), 'tokens: key 1 must be a string')
end

function testcase.embeds_returns_the_names()
    assert.equal(embeds({
        embeds = {
            'a',
            'b',
        },
    }), {
        'a',
        'b',
    })
    for _, v in ipairs({
        'a',
        {},
        {
            x = 'a',
        },
    }) do
        local names, err = embeds({
            embeds = v,
        })
        assert.is_nil(names)
        assert.equal(err, 'embeds must be a non-empty array of names')
    end
end
