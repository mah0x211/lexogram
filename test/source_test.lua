local testcase = require('testcase')
local assert = require('assert')
local write = require('lexogram.source').write

-- load the source text and return the table it returns
local function reload(src)
    local fn = assert((loadstring or load)(src))
    return fn()
end

function testcase.write_orders_fields_and_keys()
    local src = assert(write({
        rules = {
            chunk = 'stat*',
            ['end'] = 'x',
            ['two words'] = 'y',
        },
        start = 'chunk',
        tokens = {
            block = {
                level = '"="*',
                nest = 'count',
                close = '"]" level "]"',
                open = '"[" level "["',
            },
            name = '[a-z]+',
        },
        lexogram = '2026.11.15.1',
        keywords = {
            'local',
            ignore_case = true,
        },
        [1] = 'item',
        [true] = 1.5,
        [false] = 0,
        [2.5] = 2,
        [-1] = 3,
    }, {
        'first line',
        'second line',
    }))

    assert.equal(src, table.concat({
        "-- first line",
        "-- second line",
        "return {",
        "    'item',",
        "    lexogram = '2026.11.15.1',",
        "    start = 'chunk',",
        "    tokens = {",
        "        block = {",
        "            open = '\"[\" level \"[\"',",
        "            close = '\"]\" level \"]\"',",
        "            nest = 'count',",
        "            level = '\"=\"*',",
        "        },",
        "        name = '[a-z]+',",
        "    },",
        "    keywords = {",
        "        'local',",
        "        ignore_case = true,",
        "    },",
        "    rules = {",
        "        chunk = 'stat*',",
        "        ['end'] = 'x',",
        "        ['two words'] = 'y',",
        "    },",
        "    [-1] = 3,",
        "    [2.5] = 2,",
        "    [false] = 0,",
        "    [true] = 1.5,",
        "}",
        "",
    }, '\n'))
end

function testcase.write_chooses_how_to_write_each_string()
    local strings = {
        'plain',
        "it's",
        '"#" [^\\n]*',
        'a]]b]=]',
        'ends with ]',
        "a']]b",
        "x']",
        "q']=]]",
        'line\nbreak\ttab',
        '\nleading newline',
        'carriage\rreturn',
        'nul\0and\1bell\127',
        '\\',
        '',
        'caf\195\169',
    }
    local src = assert(write({
        list = strings,
    }, {}))

    assert.equal(reload(src), {
        list = strings,
    })
    -- the literal of each string
    assert.match(src, "    'plain',\n", true)
    assert.match(src, "    [[it's]],\n", true)
    assert.match(src, '    [["#" [^\\n]*]],\n', true)
    -- no quote or backslash: the brackets inside need no long brackets
    assert.match(src, "    'a]]b]=]',\n", true)
    assert.match(src, "    'ends with ]',\n", true)
    -- the lowest level whose close is not inside nor made at the end
    assert.match(src, "    [=[a']]b]=],\n", true)
    assert.match(src, "    [=[x']]=],\n", true)
    assert.match(src, "    [==[q']=]]]==],\n", true)
    assert.match(src, "    [[line\nbreak\ttab]],\n", true)
    assert.match(src, "    '\\nleading newline',\n", true)
    assert.match(src, "    'carriage\\rreturn',\n", true)
    assert.match(src, "    'nul\\000and\\001bell\\127',\n", true)
    assert.match(src, "    [[\\]],\n", true)
    assert.match(src, "    '',\n", true)
    assert.match(src, "    'caf\195\169',\n", true)
end

function testcase.write_writes_numbers_and_empty_tables()
    local src = assert(write({
        a = {},
        n = {
            1,
            -3,
            0.25,
            2 ^ 60,
        },
    }, {}))

    assert.equal(reload(src), {
        a = {},
        n = {
            1,
            -3,
            0.25,
            2 ^ 60,
        },
    })
    assert.match(src, '    a = {},\n', true)
end

function testcase.write_reports_values_it_cannot_write()
    local cyclic = {}
    cyclic.self = cyclic
    for _, case in ipairs({
        {
            {
                tokens = {
                    f = print,
                },
            },
            'tokens.f: a value of type function cannot be written',
        },
        {
            {
                rules = cyclic,
            },
            'rules.self: a table refers to itself',
        },
        {
            {
                cyclic,
            },
            '[1].self: a table refers to itself',
        },
        {
            {
                [{}] = 1,
            },
            '[table: ',
        },
        {
            {
                [{}] = 1,
                [{}] = 2,
            },
            '[table: ',
        },
        {
            {
                n = 1 / 0,
            },
            'n: the number inf cannot be written',
        },
    }) do
        local src, err = write(case[1], {})
        assert.is_nil(src)
        assert.match(err, case[2], true)
    end
    -- the same table twice is written twice
    local shared = {
        'a',
    }
    assert.equal(reload(assert(write({
        x = shared,
        y = shared,
    }, {}))), {
        x = {
            'a',
        },
        y = {
            'a',
        },
    })
end

function testcase.write_keeps_each_header_line_a_comment()
    local src = assert(write({}, {
        'from a\nreturn os.exit()\r',
    }))

    assert.equal(src, '-- from a\\010return os.exit()\\013\nreturn {}\n')
    assert.equal(reload(src), {})
end
