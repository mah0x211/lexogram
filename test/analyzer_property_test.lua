local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local TOKEN, ENTER = events.TOKEN, events.ENTER

-- a small Lua-like grammar: statements, functions, tables, and expressions
-- whose terms and operators are listed flat inside expr
local COMPILED = assert(lexogram.compile({
    lexogram = '2026.11.15.1',
    start = 'chunk',
    tokens = {
        name = '[A-Za-z_] [A-Za-z0-9_]*',
        number = 'DIGIT+',
        space = '[ \\t\\r\\n]+',
        comment = '"--" [^\\n]*',
        long_comment = {
            open = '"--[" level "["',
            close = '"]" level "]"',
            level = '"="*',
        },
    },
    symbols = {
        '=',
        ',',
        '(',
        ')',
        '{',
        '}',
        '+',
        '-',
        '*',
        '/',
        '>',
        '<',
        '==',
        '#',
    },
    keywords = {
        'local',
        'function',
        'if',
        'then',
        'end',
        'return',
        'not',
        'and',
        'or',
    },
    skip = {
        'space',
        'comment',
        'long_comment',
    },
    rules = {
        chunk = 'block',
        block = 'stat* retstat?',
        stat = '"local" (localfunc | localvars) | "if" expr "then" block "end"',
        localfunc = '"function" name funcbody',
        localvars = 'name ("," name)* ("=" exprlist)?',
        funcbody = '"(" params? ")" block "end"',
        params = 'name ("," name)*',
        retstat = '"return" exprlist?',
        exprlist = 'expr ("," expr)*',
        expr = 'unop* _operand (binop unop* _operand)*',
        unop = '"not" | "-" | "#"',
        binop = '"+" | "-" | "*" | "/" | ">" | "<" | "==" | "and" | "or"',
        _operand = 'name | number | table | "(" expr ")"',
        table = '"{" (field ("," field)*)? "}"',
        field = 'name "=" expr | expr',
    },
}))

local SKIP = {}
for id, kind in ipairs(COMPILED.kinds) do
    SKIP[id] = kind.skip
end

local function parse_ok(source)
    local result, err = lexogram.parse(COMPILED, source)
    assert(result,
           err and (err.line .. ':' .. err.column .. ': ' .. err.message))
    return result
end

-- the problems of an event array: lossless coverage, ENTER/EXIT matching
-- and nesting, ranges inside the enclosing range, and skipped tokens never
-- directly after an ENTER or directly before an EXIT
local function problems_of(result)
    local ev, problems = result.events, {}
    local pos, stack = 1, {}
    local previous
    for i = 1, result.count do
        local at = (i - 1) * 4
        local op, kind, third, fourth = ev[at + 1], ev[at + 2], ev[at + 3],
                                        ev[at + 4]
        if op == TOKEN then
            if third ~= pos or fourth <= third then
                problems[#problems + 1] = 'gap at ' .. i
            end
            pos = fourth
            if SKIP[kind] and previous == ENTER then
                problems[#problems + 1] = 'skip after enter at ' .. i
            end
        elseif op == ENTER then
            local parent = stack[#stack]
            if parent and third < ev[(parent - 1) * 4 + 3] then
                problems[#problems + 1] = 'starts before parent at ' .. i
            end
            stack[#stack + 1] = i
        else
            if stack[#stack] ~= fourth or ev[(fourth - 1) * 4 + 4] ~= i then
                problems[#problems + 1] = 'mismatch at ' .. i
            end
            stack[#stack] = nil
            if previous == TOKEN and SKIP[ev[(i - 2) * 4 + 2]] then
                problems[#problems + 1] = 'skip before exit at ' .. i
            end
            local parent = stack[#stack]
            local parent_exit = parent and ev[(parent - 1) * 4 + 4]
            if parent_exit and parent_exit < i then
                problems[#problems + 1] = 'parent closed before ' .. i
            end
        end
        previous = op
    end
    if pos ~= #result.source + 1 or #stack > 0 then
        problems[#problems + 1] = 'incomplete'
    end
    return problems
end

-- the tree of a result without skipped tokens, as nested arrays: a rule is
-- { name, child... } and a token is its text
local function shape(nodes)
    local out = {}
    for _, node in ipairs(nodes) do
        if node.children then
            local inner = shape(node.children)
            table.insert(inner, 1, node.name)
            out[#out + 1] = inner
        elseif not (node.name == 'space' or node.name == 'comment' or node.name ==
            'long_comment') then
            out[#out + 1] = node.text
        end
    end
    return out
end

local function expr_shape(source)
    local tree = shape(events.tree(parse_ok('return ' .. source)))
    -- chunk > block > retstat > exprlist > expr
    return tree[1][2][2][3][2]
end

function testcase.expression_terms_and_operators_are_flat()
    -- the second example of the spec: no nesting by precedence
    assert.equal(expr_shape('a + b * c'), {
        'expr',
        'a',
        {
            'binop',
            '+',
        },
        'b',
        {
            'binop',
            '*',
        },
        'c',
    })
end

function testcase.prefix_and_binary_minus_get_their_own_rules()
    assert.equal(expr_shape('-a - -b'), {
        'expr',
        {
            'unop',
            '-',
        },
        'a',
        {
            'binop',
            '-',
        },
        {
            'unop',
            '-',
        },
        'b',
    })
end

function testcase.parses_the_initial_example_of_the_adr()
    local source = table.concat({
        'local a',
        'local a, b, c',
        'local a, b, c = 1, 2, 3',
        'local function f(x, y)',
        '    if x > y then',
        '        return { value = (x + y) }',
        '    end',
        '    return x',
        'end',
        '',
    }, '\n')

    local result = parse_ok(source)

    assert.equal(problems_of(result), {})
    local tree = shape(events.tree(result))
    local block = tree[1][2]
    assert.equal(block[1], 'block')
    -- four statements: three local declarations and the local function
    assert.equal(#block, 5)
    local funcbody = block[5][3][4]
    assert.equal(funcbody[1], 'funcbody')
    assert.equal(funcbody[3], {
        'params',
        'x',
        ',',
        'y',
    })
    -- the if statement returns a table whose field is name "=" expr
    local ret = funcbody[5][2][5][2]
    assert.equal(ret, {
        'retstat',
        'return',
        {
            'exprlist',
            {
                'expr',
                {
                    'table',
                    '{',
                    {
                        'field',
                        'value',
                        '=',
                        {
                            'expr',
                            '(',
                            {
                                'expr',
                                'x',
                                {
                                    'binop',
                                    '+',
                                },
                                'y',
                            },
                            ')',
                        },
                    },
                    '}',
                },
            },
        },
    })
end

-- pseudo-random numbers (Park-Miller), identical on every runtime
local SEED = 20261117
local function random(n)
    SEED = (SEED * 16807) % 2147483647
    return SEED % n + 1
end

local SEPARATORS = {
    ' ',
    '  ',
    '\n',
    '\t',
    ' -- note\n',
    ' --[[ c ]] ',
    -- a leading space: after a "-" token, "--" would start a line comment
    ' --[==[ ]] ]=] ]==]',
    '\r\n',
}

-- a random expression of the grammar as a list of tokens
local function expression(depth, out)
    for _ = 1, random(3) - 1 do
        out[#out + 1] = ({
            'not',
            '-',
            '#',
        })[random(3)]
    end
    local pick = random(depth > 3 and 2 or 4)
    if pick == 1 then
        out[#out + 1] = ({
            'a',
            'b1',
            '_x',
        })[random(3)]
    elseif pick == 2 then
        out[#out + 1] = tostring(random(1000))
    elseif pick == 3 then
        out[#out + 1] = '('
        expression(depth + 1, out)
        out[#out + 1] = ')'
    else
        out[#out + 1] = '{'
        for i = 1, random(3) - 1 do
            if i > 1 then
                out[#out + 1] = ','
            end
            if random(2) == 1 then
                out[#out + 1] = 'k'
                out[#out + 1] = '='
            end
            expression(depth + 1, out)
        end
        out[#out + 1] = '}'
    end
    if random(3) == 1 then
        out[#out + 1] = ({
            '+',
            '-',
            '*',
            '/',
            '>',
            '<',
            '==',
            'and',
            'or',
        })[random(9)]
        expression(depth + 1, out)
    end
end

-- a random program: local declarations with random separators
local function program()
    local tokens = {}
    for _ = 1, random(4) do
        tokens[#tokens + 1] = 'local'
        tokens[#tokens + 1] = 'v'
        tokens[#tokens + 1] = '='
        expression(0, tokens)
    end
    local parts = {}
    if random(2) == 1 then
        parts[1] = SEPARATORS[random(#SEPARATORS)]
    end
    for i, token in ipairs(tokens) do
        parts[#parts + 1] = token
        if i < #tokens or random(2) == 1 then
            parts[#parts + 1] = SEPARATORS[random(#SEPARATORS)]
        end
    end
    return table.concat(parts)
end

-- run fn with the coverage hook removed: the random programs take far
-- too long under luacov's line hook, and the library lines they run are
-- covered by the other tests
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
    return res[2]
end

function testcase.random_programs_keep_every_property()
    without_hook(function()
        for _ = 1, 300 do
            local source = program()
            local result = parse_ok(source)

            assert.equal(problems_of(result), {}, source)
            -- the tokens rebuild the source
            local texts = {}
            for i = 1, result.count do
                if events.op(result, i) == TOKEN then
                    texts[#texts + 1] = events.text(result, i)
                end
            end
            assert.equal(table.concat(texts), source)
            -- the same input gives the same array
            assert.equal(parse_ok(source).events, result.events)
        end
    end)
end
