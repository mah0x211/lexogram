local testcase = require('testcase')
local assert = require('assert')
local analyzer = require('lexogram.analyzer')
local compile = require('lexogram.compile').compile

local TOKEN, ENTER, EXIT = analyzer.TOKEN, analyzer.ENTER, analyzer.EXIT

-- compile a grammar from fields (a name and a number token and skipped
-- spaces by default) and fail on any error
local function compiled_of(fields)
    local g = {
        lexogram = '2026.11.15.1',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            number = 'DIGIT+',
            space = '[ \\n]+',
        },
        skip = {
            'space',
        },
    }
    for k, v in pairs(fields) do
        g[k] = v
    end
    local compiled, diagnostics = compile(g)
    for _, d in ipairs(diagnostics) do
        assert.equal(d.severity, 'warning', d.message)
    end
    return compiled
end

-- the events of a result as readable rows: { op, kind name, third, fourth }
local function rows(result)
    local kinds, events = result.grammar.kinds, result.events
    local out = {}
    for i = 1, result.count do
        local at = (i - 1) * 4
        local op = ({
            'TOKEN',
            'ENTER',
            'EXIT',
        })[events[at + 1]]
        out[i] = {
            op,
            kinds[events[at + 2]].name,
            events[at + 3],
            events[at + 4],
        }
    end
    return out
end

-- check the invariants of an event array: the tokens cover the source in
-- order without gaps, ENTER and EXIT match and nest, and their positions
-- agree with the tokens inside; returns a list of problems
local function problems_of(result)
    local events, source = result.events, result.source
    local problems = {}
    local pos = 1
    local stack = {}
    if #events ~= result.count * 4 then
        problems[#problems + 1] = 'array length'
    end
    for i = 1, result.count do
        local at = (i - 1) * 4
        local op, kind, third, fourth = events[at + 1], events[at + 2],
                                        events[at + 3], events[at + 4]
        if op == TOKEN then
            if third ~= pos or fourth <= third then
                problems[#problems + 1] = 'token ' .. i .. ' does not follow'
            end
            pos = fourth
        elseif op == ENTER then
            stack[#stack + 1] = i
            local exit_at = (fourth - 1) * 4
            if events[exit_at + 1] ~= EXIT or events[exit_at + 4] ~= i or
                events[exit_at + 2] ~= kind then
                problems[#problems + 1] = 'enter ' .. i .. ' mismatch'
            end
        elseif op == EXIT then
            if stack[#stack] ~= fourth then
                problems[#problems + 1] = 'exit ' .. i .. ' does not nest'
            end
            stack[#stack] = nil
            local start = events[(fourth - 1) * 4 + 3]
            if third < start then
                problems[#problems + 1] = 'exit ' .. i .. ' before enter'
            end
            -- the range lies within the range of the enclosing rule
            local parent = stack[#stack]
            if parent and start < events[(parent - 1) * 4 + 3] then
                problems[#problems + 1] = 'exit ' .. i .. ' starts outside'
            end
            local parent_exit = parent and events[(parent - 1) * 4 + 4]
            if parent_exit and third > events[(parent_exit - 1) * 4 + 3] then
                problems[#problems + 1] = 'exit ' .. i .. ' stops outside'
            end
        else
            problems[#problems + 1] = 'op ' .. tostring(op)
        end
    end
    if pos ~= #source + 1 then
        problems[#problems + 1] = 'tokens end at ' .. pos
    end
    if #stack > 0 then
        problems[#problems + 1] = 'unclosed enter'
    end
    return problems
end

-- parse and assert success and the invariants
local function parse_ok(compiled, source)
    local result, err = analyzer.parse(compiled, source)
    assert(result, err and err.message)
    assert.equal(problems_of(result), {})
    return result
end

-- run fn with the coverage hook removed (the deep input tests take far
-- too long under luacov's line hook; the analyzer lines they run are
-- covered by the other tests)
local function without_hook(fn, ...)
    local hook, mask, count = debug.gethook()
    debug.sethook()
    local res = {
        pcall(fn, ...),
    }
    if hook then
        debug.sethook(hook, mask, count)
    end
    if not res[1] then
        error(res[2], 0)
    end
    return res[2], res[3]
end

-- the grammar of the spec example
local function local_grammar()
    return compiled_of({
        tokens = {
            name = '[a-z]+',
            number = 'DIGIT+',
            whitespace = '" "+',
        },
        skip = {
            'whitespace',
        },
        symbols = {
            '=',
            ',',
        },
        keywords = {
            'local',
        },
        rules = {
            chunk = 'block',
            block = 'localstat*',
            localstat = '"local" name ("=" exprlist)?',
            exprlist = 'expr ("," expr)*',
            expr = 'number | name',
        },
    })
end

function testcase.parse_returns_spec_example()
    local compiled = local_grammar()

    local result = parse_ok(compiled, 'local a = 1')

    assert.equal(result.source, 'local a = 1')
    assert.equal(result.errors, {})
    assert.equal(result.grammar, compiled)
    assert.equal(result.count, 17)
    assert.equal(rows(result), {
        {
            'ENTER',
            'chunk',
            1,
            17,
        },
        {
            'ENTER',
            'block',
            1,
            16,
        },
        {
            'ENTER',
            'localstat',
            1,
            15,
        },
        {
            'TOKEN',
            'local',
            1,
            6,
        },
        {
            'TOKEN',
            'whitespace',
            6,
            7,
        },
        {
            'TOKEN',
            'name',
            7,
            8,
        },
        {
            'TOKEN',
            'whitespace',
            8,
            9,
        },
        {
            'TOKEN',
            '=',
            9,
            10,
        },
        {
            'TOKEN',
            'whitespace',
            10,
            11,
        },
        {
            'ENTER',
            'exprlist',
            11,
            14,
        },
        {
            'ENTER',
            'expr',
            11,
            13,
        },
        {
            'TOKEN',
            'number',
            11,
            12,
        },
        {
            'EXIT',
            'expr',
            12,
            11,
        },
        {
            'EXIT',
            'exprlist',
            12,
            10,
        },
        {
            'EXIT',
            'localstat',
            12,
            3,
        },
        {
            'EXIT',
            'block',
            12,
            2,
        },
        {
            'EXIT',
            'chunk',
            12,
            1,
        },
    })
end

function testcase.parse_places_skipped_tokens_outside_rule_ranges()
    local compiled = local_grammar()

    local result = parse_ok(compiled, '  local a  ')

    -- leading spaces precede the first ENTER; trailing spaces follow the
    -- last EXIT; rule ranges span from the first to the last valid token
    assert.equal(rows(result), {
        {
            'TOKEN',
            'whitespace',
            1,
            3,
        },
        {
            'ENTER',
            'chunk',
            3,
            10,
        },
        {
            'ENTER',
            'block',
            3,
            9,
        },
        {
            'ENTER',
            'localstat',
            3,
            8,
        },
        {
            'TOKEN',
            'local',
            3,
            8,
        },
        {
            'TOKEN',
            'whitespace',
            8,
            9,
        },
        {
            'TOKEN',
            'name',
            9,
            10,
        },
        {
            'EXIT',
            'localstat',
            10,
            4,
        },
        {
            'EXIT',
            'block',
            10,
            3,
        },
        {
            'EXIT',
            'chunk',
            10,
            2,
        },
        {
            'TOKEN',
            'whitespace',
            10,
            12,
        },
    })
end

function testcase.parse_places_empty_rules_at_the_next_token()
    local compiled = local_grammar()

    -- an empty block: it starts and stops at the end of input, after the
    -- spaces, which precede the ENTERs
    local result = parse_ok(compiled, '  ')

    assert.equal(rows(result), {
        {
            'TOKEN',
            'whitespace',
            1,
            3,
        },
        {
            'ENTER',
            'chunk',
            3,
            5,
        },
        {
            'ENTER',
            'block',
            3,
            4,
        },
        {
            'EXIT',
            'block',
            3,
            3,
        },
        {
            'EXIT',
            'chunk',
            3,
            2,
        },
    })
end

function testcase.parse_extends_rules_over_empty_rules_inside()
    local compiled = compiled_of({
        symbols = {
            '!',
        },
        rules = {
            chunk = 'p name',
            p = 'name mark',
            mark = '"!"?',
        },
    })

    -- mark is empty and starts at b, after the spaces; p ends there too so
    -- that mark stays inside it
    local result = parse_ok(compiled, 'a  b')

    assert.equal(rows(result), {
        {
            'ENTER',
            'chunk',
            1,
            9,
        },
        {
            'ENTER',
            'p',
            1,
            7,
        },
        {
            'TOKEN',
            'name',
            1,
            2,
        },
        {
            'TOKEN',
            'space',
            2,
            4,
        },
        {
            'ENTER',
            'mark',
            4,
            6,
        },
        {
            'EXIT',
            'mark',
            4,
            5,
        },
        {
            'EXIT',
            'p',
            4,
            2,
        },
        {
            'TOKEN',
            'name',
            4,
            5,
        },
        {
            'EXIT',
            'chunk',
            5,
            1,
        },
    })
end

function testcase.parse_writes_no_events_for_rules_starting_with_underscore()
    local compiled = compiled_of({
        symbols = {
            '(',
            ')',
            ',',
        },
        rules = {
            chunk = '"(" _args ")"',
            _args = '(name ("," name)*)?',
        },
    })

    local result = parse_ok(compiled, '(a, b)')

    assert.equal(rows(result), {
        {
            'ENTER',
            'chunk',
            1,
            8,
        },
        {
            'TOKEN',
            '(',
            1,
            2,
        },
        {
            'TOKEN',
            'name',
            2,
            3,
        },
        {
            'TOKEN',
            ',',
            3,
            4,
        },
        {
            'TOKEN',
            'space',
            4,
            5,
        },
        {
            'TOKEN',
            'name',
            5,
            6,
        },
        {
            'TOKEN',
            ')',
            6,
            7,
        },
        {
            'EXIT',
            'chunk',
            7,
            1,
        },
    })
end

function testcase.parse_rewinds_failed_ordered_alternatives()
    local compiled = compiled_of({
        symbols = {
            '=',
            '(',
            ')',
            ';',
        },
        rules = {
            chunk = 'stat*',
            stat = 'assign / call',
            assign = 'name "=" name ";"',
            call = 'name "(" ")" ";"',
        },
    })

    local result = parse_ok(compiled, 'f ( ) ; a = b ;')

    -- the failed assign attempt for "f ( )" leaves no events, and the
    -- space it had read is written once
    assert.equal(rows(result), {
        {
            'ENTER',
            'chunk',
            1,
            25,
        },
        {
            'ENTER',
            'stat',
            1,
            12,
        },
        {
            'ENTER',
            'call',
            1,
            11,
        },
        {
            'TOKEN',
            'name',
            1,
            2,
        },
        {
            'TOKEN',
            'space',
            2,
            3,
        },
        {
            'TOKEN',
            '(',
            3,
            4,
        },
        {
            'TOKEN',
            'space',
            4,
            5,
        },
        {
            'TOKEN',
            ')',
            5,
            6,
        },
        {
            'TOKEN',
            'space',
            6,
            7,
        },
        {
            'TOKEN',
            ';',
            7,
            8,
        },
        {
            'EXIT',
            'call',
            8,
            3,
        },
        {
            'EXIT',
            'stat',
            8,
            2,
        },
        {
            'TOKEN',
            'space',
            8,
            9,
        },
        {
            'ENTER',
            'stat',
            9,
            24,
        },
        {
            'ENTER',
            'assign',
            9,
            23,
        },
        {
            'TOKEN',
            'name',
            9,
            10,
        },
        {
            'TOKEN',
            'space',
            10,
            11,
        },
        {
            'TOKEN',
            '=',
            11,
            12,
        },
        {
            'TOKEN',
            'space',
            12,
            13,
        },
        {
            'TOKEN',
            'name',
            13,
            14,
        },
        {
            'TOKEN',
            'space',
            14,
            15,
        },
        {
            'TOKEN',
            ';',
            15,
            16,
        },
        {
            'EXIT',
            'assign',
            16,
            15,
        },
        {
            'EXIT',
            'stat',
            16,
            14,
        },
        {
            'EXIT',
            'chunk',
            16,
            1,
        },
    })
end

function testcase.parse_skips_alternatives_that_cannot_start()
    local compiled = compiled_of({
        symbols = {
            'x',
        },
        rules = {
            chunk = 'stat',
            stat = 'tagged / plain',
            tagged = '"x" name',
            plain = 'name',
        },
    })

    -- the next token cannot start tagged, so plain is tried directly
    local result = parse_ok(compiled, 'a')

    assert.equal(rows(result)[3], {
        'ENTER',
        'plain',
        1,
        5,
    })
end

function testcase.parse_drops_events_of_a_longer_failed_alternative()
    local compiled = compiled_of({
        symbols = {
            '!',
        },
        rules = {
            chunk = 'stat',
            stat = 'deep / flat',
            deep = 'p',
            p = 'q',
            q = 'r',
            r = 's',
            s = 'name "!"',
            flat = 'name',
        },
    })

    -- deep writes six events before it fails; flat needs fewer in total
    local result = parse_ok(compiled, 'a')

    assert.equal(result.count, 7)
    assert.equal(#result.events, 28)
    assert.equal(rows(result)[3], {
        'ENTER',
        'flat',
        1,
        5,
    })
end

function testcase.parse_decides_with_two_tokens_and_greedy_rules()
    local compiled = compiled_of({
        symbols = {
            '{',
            '}',
            '=',
            ',',
        },
        keywords = {
            'if',
            'then',
            'else',
        },
        greedy = {
            'stat',
        },
        rules = {
            chunk = 'stat*',
            stat = '"if" name "then" stat ("else" stat)? | table',
            table = '"{" (field ("," field)*)? "}"',
            field = 'name "=" name | name',
        },
    })

    local result = parse_ok(compiled, '{a = b, c}')
    local fields = {}
    for _, row in ipairs(rows(result)) do
        if row[1] == 'ENTER' and row[2] == 'field' then
            fields[#fields + 1] = row[3]
        end
    end
    assert.equal(fields, {
        2,
        9,
    })

    -- the else belongs to the inner if: the inner if ends after the else
    -- branch (31) together with the outer one; only the then branch of the
    -- inner if ends before it (23)
    result = parse_ok(compiled, 'if a then if b then {} else {}')
    local stats = {}
    for _, row in ipairs(rows(result)) do
        if row[1] == 'EXIT' and row[2] == 'stat' then
            stats[#stats + 1] = row[3]
        end
    end
    assert.equal(stats, {
        23,
        31,
        31,
        31,
    })
end

function testcase.parse_reports_syntax_errors()
    local compiled = local_grammar()
    local kinds = compiled.names
    local lit = compiled.literals

    for _, case in ipairs({
        {
            'local = 1',
            7,
            lit['='],
            {
                kinds.name,
            },
            'unexpected "=", expected name',
        },
        {
            'local a = ',
            11,
            0,
            {
                kinds.name,
                kinds.number,
            },
            'unexpected end of input, expected name, number',
        },
        {
            'local a 1',
            9,
            kinds.number,
            {
                0,
                lit['='],
                lit['local'],
            },
            'unexpected number, expected end of input, "=", "local"',
        },
        {
            'local a @',
            9,
            kinds.INVALID,
            {
                0,
                lit['='],
                lit['local'],
            },
            'unexpected INVALID, expected end of input, "=", "local"',
        },
    }) do
        local result, err = analyzer.parse(compiled, case[1])
        assert.is_nil(result)
        assert.equal(err, {
            code = 'syntax_error',
            pos = case[2],
            line = 1,
            column = case[2],
            actual = case[3],
            expected = case[4],
            message = case[5],
        })
    end
end

function testcase.parse_reports_line_and_column_of_errors()
    -- the default space token includes line breaks
    local compiled = compiled_of({
        symbols = {
            '=',
        },
        keywords = {
            'local',
        },
        rules = {
            chunk = '("local" name "=" number)*',
        },
    })
    local result, err = analyzer.parse(compiled, 'local a = 1\nlocal b =\n  =')

    assert.is_nil(result)
    assert.equal(err.pos, 25)
    assert.equal(err.line, 3)
    assert.equal(err.column, 3)
    assert.equal(err.message, 'unexpected "=", expected number')
end

function testcase.parse_reports_errors_after_failed_alternatives()
    local compiled = compiled_of({
        symbols = {
            '=',
            '(',
            ')',
        },
        rules = {
            chunk = 'stat*',
            stat = 'name "=" name / name "(" ")"',
        },
    })

    -- both alternatives fail; the error comes from the last one
    local result, err = analyzer.parse(compiled, 'f x')

    assert.is_nil(result)
    assert.equal(err.pos, 3)
    assert.equal(err.message, 'unexpected name, expected "("')
end

function testcase.parse_reports_unterminated_tokens()
    local compiled = compiled_of({
        tokens = {
            name = '[a-z]+',
            space = '" "+',
            long = {
                open = '"[" level "["',
                close = '"]" level "]"',
                level = '"="*',
            },
        },
        rules = {
            chunk = '(name | long)*',
        },
    })
    parse_ok(compiled, 'a [=[ x ]] ]=] b')

    local result, err = analyzer.parse(compiled, 'a [=[ x ]]')

    assert.is_nil(result)
    assert.equal(err, {
        code = 'unterminated_token',
        pos = 3,
        line = 1,
        column = 3,
        actual = compiled.names.long,
        expected = {},
        message = 'unterminated long',
    })
end

function testcase.parse_handles_deep_input_without_the_lua_stack()
    local compiled = compiled_of({
        symbols = {
            '(',
            ')',
            ',',
        },
        rules = {
            chunk = 'group',
            group = '"(" group? ")"',
        },
    })
    local n = 20000
    local result = without_hook(parse_ok, compiled,
                                string.rep('(', n) .. string.rep(')', n))
    assert.equal(result.count, 2 * n + 2 * n + 2)

    compiled = compiled_of({
        symbols = {
            '(',
            ')',
            ',',
        },
        rules = {
            chunk = '"(" _items ")"',
            _items = 'name ("," _items)?',
        },
    })
    -- a short list with the hook on: _items tail-calls itself
    assert.equal(parse_ok(compiled, '(a,b,c)').count, 2 + 2 + 5)
    local items = {}
    for i = 1, n do
        items[i] = 'a'
    end
    result = without_hook(parse_ok, compiled,
                          '(' .. table.concat(items, ',') .. ')')
    assert.equal(result.count, 2 + 2 + 2 * n - 1)
end

function testcase.parse_raises_for_invalid_arguments()
    local compiled = local_grammar()

    local err = assert.throws(analyzer.parse, nil, '')
    assert.match(err, 'compiled must be table, got nil')
    err = assert.throws(analyzer.parse, compiled, 1)
    assert.match(err, 'source must be string, got number')
end

function testcase.parse_reports_forbidden_nested_opens()
    local compiled = compiled_of({
        tokens = {
            name = '[a-z]+',
            space = '[ \\n]+',
            long = {
                open = '"[["',
                close = '"]]"',
                nest = 'error',
            },
        },
        rules = {
            chunk = '(name | long)*',
        },
    })
    parse_ok(compiled, 'a [[ b ]] c')

    local result, err = analyzer.parse(compiled, 'a\n[[ b [[ c ]]')

    assert.is_nil(result)
    assert.equal(err, {
        code = 'nested_delimiter',
        pos = 8,
        line = 2,
        column = 6,
        actual = compiled.names.long,
        expected = {},
        message = 'nested delimiter in long',
    })
end

function testcase.parse_skips_a_leading_token()
    local compiled = compiled_of({
        tokens = {
            name = '[a-z]+',
            space = '[ \\n]+',
            shebang = '"#" [^\\n]*',
        },
        symbols = {
            '#',
        },
        leading = {
            'shebang',
        },
        skip = {
            'space',
            'shebang',
        },
        rules = {
            chunk = '("#"? name)*',
        },
    })

    -- the shebang line is a skipped token before the first rule
    assert.equal(rows(parse_ok(compiled, '#!x\n#a')), {
        {
            'TOKEN',
            'shebang',
            1,
            4,
        },
        {
            'TOKEN',
            'space',
            4,
            5,
        },
        {
            'ENTER',
            'chunk',
            5,
            6,
        },
        {
            'TOKEN',
            '#',
            5,
            6,
        },
        {
            'TOKEN',
            'name',
            6,
            7,
        },
        {
            'EXIT',
            'chunk',
            7,
            3,
        },
    })
end
