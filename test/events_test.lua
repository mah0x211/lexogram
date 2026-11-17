local testcase = require('testcase')
local assert = require('assert')
local events = require('lexogram.events')
local lexogram = require('lexogram')

-- a result of lexogram.parse for source, with a small statement grammar
local function parsed(source)
    local compiled = assert(lexogram.compile({
        lexogram = '2026.11.15.1',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            number = 'DIGIT+',
            space = '[ \\t\\r\\n]+',
        },
        skip = {
            'space',
        },
        symbols = {
            '=',
            '(',
            ')',
        },
        keywords = {
            'local',
        },
        rules = {
            chunk = 'stat*',
            stat = '"local" name "=" _value',
            _value = 'number | call',
            call = 'name "(" ")"',
        },
    }))
    return assert(lexogram.parse(compiled, source))
end

-- a minimal result object for the line functions
local function source_only(source)
    return {
        source = source,
        events = {},
        count = 0,
    }
end

-- lines

function testcase.line_starts_counts_lf_crlf_and_lone_cr()
    assert.equal(events.line_starts(''), {
        1,
    })
    assert.equal(events.line_starts('abc'), {
        1,
    })
    assert.equal(events.line_starts('a\nb\r\nc\rd'), {
        1,
        3,
        6,
        8,
    })
    -- a trailing break starts an empty last line; CR CR is two breaks
    assert.equal(events.line_starts('a\n'), {
        1,
        3,
    })
    assert.equal(events.line_starts('\r\r\n\n'), {
        1,
        2,
        4,
        5,
    })
end

function testcase.position_returns_line_and_byte_column()
    local result = source_only('ab\ncd\r\nef\rg')

    -- LuaFormatter off
    for _, case in ipairs({
        -- pos, line, column
        { 1, 1, 1 },
        { 3, 1, 3 },   -- the LF ends line 1
        { 4, 2, 1 },
        { 6, 2, 3 },   -- CR of CRLF
        { 7, 2, 4 },   -- the LF of CRLF belongs to line 2
        { 8, 3, 1 },
        { 11, 4, 1 },
        { 12, 4, 2 },  -- the end of input
    }) do
        -- LuaFormatter on
        local line, column = events.position(result, case[1])
        assert.equal({
            line,
            column,
        }, {
            case[2],
            case[3],
        })
    end
    -- the table of line starts is kept in the result
    assert.equal(result.lines, {
        1,
        4,
        8,
        11,
    })
end

function testcase.column_codepoints_counts_code_points()
    -- "あ" is 3 bytes, "é" is 2 bytes
    local result = source_only('x\n\227\129\130\195\169y')

    assert.equal({
        events.column_codepoints(result, 3),
    }, {
        2,
        1,
    })
    assert.equal({
        events.column_codepoints(result, 6),
    }, {
        2,
        2,
    })
    assert.equal({
        events.column_codepoints(result, 8),
    }, {
        2,
        3,
    })
    assert.equal({
        events.column_codepoints(result, 9),
    }, {
        2,
        4,
    })
    -- the byte column of the same position
    assert.equal({
        events.position(result, 8),
    }, {
        2,
        6,
    })
end

function testcase.line_functions_raise_for_invalid_arguments()
    local result = source_only('ab')

    local err = assert.throws(events.position, {}, 1)
    assert.match(err, 'result must be a result of lexogram.parse')
    err = assert.throws(events.position, result, 0)
    assert.match(err, 'pos must be an integer from 1 to 3')
    err = assert.throws(events.column_codepoints, result, 4)
    assert.match(err, 'pos must be an integer from 1 to 3')
    err = assert.throws(events.position, result, 1.5)
    assert.match(err, 'pos must be an integer from 1 to 3')
end

-- events

function testcase.readers_return_event_fields()
    local result = parsed('local a = f()')
    -- 1 ENTER chunk, 2 ENTER stat, 3 TOKEN local, 4 TOKEN space, 5 TOKEN
    -- name, 6 TOKEN space, 7 TOKEN =, 8 TOKEN space, 9 ENTER call,
    -- 10 TOKEN name, 11 TOKEN (, 12 TOKEN ), 13 EXIT call, 14 EXIT stat,
    -- 15 EXIT chunk
    assert.equal(result.count, 15)

    assert.equal(events.op(result, 1), events.ENTER)
    assert.equal(events.op(result, 3), events.TOKEN)
    assert.equal(events.op(result, 13), events.EXIT)
    assert.equal(events.kind(result, 9), result.grammar.names.call)
    assert.equal({
        events.name(result, 3),
    }, {
        'local',
        'keyword',
    })
    assert.equal({
        events.name(result, 9),
    }, {
        'call',
        'rule',
    })
    assert.equal({
        events.range(result, 5),
    }, {
        7,
        8,
    })
    assert.equal({
        events.range(result, 9),
    }, {
        11,
        14,
    })
    assert.equal({
        events.range(result, 13),
    }, {
        11,
        14,
    })
    assert.equal(events.text(result, 2), 'local a = f()')
    assert.equal(events.text(result, 9), 'f()')
    assert.equal(events.text(result, 4), ' ')
    assert.equal(events.match(result, 9), 13)
    assert.equal(events.match(result, 13), 9)
    assert.is_nil(events.match(result, 5))
end

function testcase.children_iterates_direct_children()
    local result = parsed('local a = f() local b = 1')

    local top = {}
    for j in events.children(result, 1) do
        top[#top + 1] = events.name(result, j)
    end
    -- the two stats and the space between them
    assert.equal(top, {
        'stat',
        'space',
        'stat',
    })

    local inside = {}
    for j in events.children(result, 2) do
        inside[#inside + 1] = events.text(result, j)
    end
    assert.equal(inside, {
        'local',
        ' ',
        'a',
        ' ',
        '=',
        ' ',
        'f()',
    })

    local err = assert.throws(events.children, result, 3)
    assert.match(err, 'event 3 is not an ENTER')
end

function testcase.tree_builds_nested_nodes_from_events_alone()
    local result = parsed(' local a = 1')

    assert.equal(events.tree(result), {
        {
            name = 'space',
            text = ' ',
        },
        {
            name = 'chunk',
            children = {
                {
                    name = 'stat',
                    children = {
                        {
                            name = 'local',
                            text = 'local',
                        },
                        {
                            name = 'space',
                            text = ' ',
                        },
                        {
                            name = 'name',
                            text = 'a',
                        },
                        {
                            name = 'space',
                            text = ' ',
                        },
                        {
                            name = '=',
                            text = '=',
                        },
                        {
                            name = 'space',
                            text = ' ',
                        },
                        {
                            name = 'number',
                            text = '1',
                        },
                    },
                },
            },
        },
    })
end

function testcase.readers_raise_for_invalid_arguments()
    local result = parsed('local a = 1')

    local err = assert.throws(events.op, result, 0)
    assert.match(err, 'i must be an event number from 1 to ' .. result.count)
    err = assert.throws(events.text, result, result.count + 1)
    assert.match(err, 'i must be an event number from 1 to ' .. result.count)
    err = assert.throws(events.kind, nil, 1)
    assert.match(err, 'result must be a result of lexogram.parse')
    err = assert.throws(events.tree, 'x')
    assert.match(err, 'result must be a result of lexogram.parse')
end
