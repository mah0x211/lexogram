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
        ['=greedy'] = {
            'chunk',
        },
        recover = {},
    }).greedy, {
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
