local testcase = require('testcase')
local assert = require('assert')
local codegen = require('lexogram.compile.codegen')
local compile = require('lexogram.compile').compile
local unpack = require('lexogram.compat').unpack

local MATCH = codegen.MATCH
local CALL = codegen.CALL
local TAILCALL = codegen.TAILCALL
local RET = codegen.RET
local JUMP = codegen.JUMP
local SWITCH = codegen.SWITCH
local TEST = codegen.TEST
local TRY = codegen.TRY
local COMMIT = codegen.COMMIT

-- a grammar with single-letter symbols, a name and a number token and
-- skipped spaces; fields override the defaults
local function grammar(fields)
    local g = {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 's',
        tokens = {
            name = 'ALPHA ALPHA+',
            number = 'DIGIT+',
            space = '" "+',
        },
        skip = {
            'space',
        },
        symbols = {},
    }
    for k, v in pairs(fields) do
        g[k] = v
    end
    return g
end

-- compile g and fail on any error (warnings such as unused tokens of the
-- default token set are allowed)
local function compiled_of(g)
    local compiled, diagnostics = compile(g)
    for _, d in ipairs(diagnostics) do
        assert.equal(d.severity, 'warning', d.message)
    end
    return compiled
end

-- token kinds of a space separated list of token names and literals
local function kinds_of(compiled, src)
    local out = {}
    for word in src:gmatch('%S+') do
        out[#out + 1] = assert(compiled.literals[word] or compiled.names[word],
                               word)
    end
    return out
end

-- a reference recognizer for the instructions: returns true if the token
-- kinds are accepted, and the largest call stack depth it used
local function recognize(compiled, kinds)
    local syntax = compiled.syntax
    local code, decisions = syntax.code, syntax.decisions
    local pos = 1
    local function peek(i)
        return kinds[pos + i - 1] or 0
    end
    local stack, tries = {}, {}
    local depth = 0
    local pc = syntax.rules[syntax.start].entry
    local function fail()
        local try = table.remove(tries)
        if not try then
            return false
        end
        pos, pc = try.pos, try.resume
        stack = {}
        for i = 1, #try.stack do
            stack[i] = try.stack[i]
        end
        return true
    end
    while true do
        local op = code[pc]
        local ok = true
        if op == MATCH then
            if peek(1) == code[pc + 1] then
                pos = pos + 1
                pc = pc + 2
            else
                ok = fail()
            end
        elseif op == CALL or op == TAILCALL then
            if op == CALL then
                stack[#stack + 1] = pc + 2
                depth = math.max(depth, #stack)
            end
            pc = syntax.rules[code[pc + 1]].entry
        elseif op == RET then
            if #stack == 0 then
                if peek(1) == 0 then
                    return true, depth
                end
                ok = fail()
            else
                pc = table.remove(stack)
            end
        elseif op == JUMP then
            pc = code[pc + 1]
        elseif op == SWITCH then
            local d = decisions[code[pc + 1]]
            local second = d.second[peek(1)]
            local to
            if second then
                to = second[peek(2)]
            else
                to = d.first[peek(1)]
            end
            if to then
                pc = to
            else
                ok = fail()
            end
        elseif op == TEST then
            local d = decisions[code[pc + 1]]
            local enter = d.enter[peek(1)]
            if enter and d.second[peek(1)] then
                enter = d.second[peek(1)][peek(2)]
            end
            if enter then
                pc = pc + 3
            else
                pc = code[pc + 2]
            end
        elseif op == TRY then
            local d = decisions[code[pc + 1]]
            if d.first[peek(1)] then
                local saved = {}
                for i = 1, #stack do
                    saved[i] = stack[i]
                end
                tries[#tries + 1] = {
                    pos = pos,
                    resume = code[pc + 2],
                    stack = saved,
                }
                pc = pc + 3
            else
                pc = code[pc + 2]
            end
        else
            assert.equal(op, COMMIT)
            table.remove(tries)
            pc = pc + 1
        end
        if not ok then
            return false, depth
        end
    end
end

local function accepts(compiled, src)
    return (recognize(compiled, kinds_of(compiled, src)))
end

function testcase.generate_emits_each_construct()
    local compiled = compiled_of(grammar({
        symbols = {
            'a',
            'b',
            'c',
            'd',
            'x',
        },
        rules = {
            s = '"a" _b? ("c" | "d")* "x"+ ("a" "b" / "a" "c")',
            _b = '"b" s',
        },
    }))
    local a, b, c, d, x = 6, 7, 8, 9, 10
    assert.equal(compiled.literals, {
        a = a,
        b = b,
        c = c,
        d = d,
        x = x,
    })

    local syntax = compiled.syntax
    assert.equal(syntax.start, 2)
    assert.equal(syntax.rules, {
        {
            name = '_b',
            kind = 0,
            entry = 1,
        },
        {
            name = 's',
            kind = 11,
            entry = 6,
        },
    })
    -- LuaFormatter off
    assert.equal(syntax.code, {
        -- _b: "b" s (tail call: _b has no kind)
        MATCH, b,           -- 1
        TAILCALL, 2,        -- 3
        RET,                -- 5
        -- s
        MATCH, a,           -- 6
        TEST, 1, 13,        -- 8: _b?
        CALL, 1,            -- 11
        TEST, 2, 26,        -- 13: ("c" | "d")*
        SWITCH, 3,          -- 16
        MATCH, c,           -- 18
        JUMP, 24,           -- 20
        MATCH, d,           -- 22
        JUMP, 13,           -- 24
        MATCH, x,           -- 26: "x"+
        TEST, 4, 33,        -- 28
        JUMP, 26,           -- 31
        TRY, 5, 43,         -- 33: "a" "b" / "a" "c"
        MATCH, a,           -- 36
        MATCH, b,           -- 38
        COMMIT,             -- 40
        JUMP, 47,           -- 41
        MATCH, a,           -- 43
        MATCH, c,           -- 45
        RET,                -- 47
    })
    -- LuaFormatter on
    assert.equal(syntax.decisions, {
        {
            enter = {
                [b] = true,
            },
            second = {},
        },
        {
            enter = {
                [c] = true,
                [d] = true,
            },
            second = {},
        },
        {
            first = {
                [c] = 18,
                [d] = 22,
            },
            second = {},
        },
        {
            enter = {
                [x] = true,
            },
            second = {},
        },
        {
            first = {
                [a] = true,
            },
        },
    })
end

function testcase.generate_keeps_calls_in_rules_with_a_kind()
    local compiled = compiled_of(grammar({
        symbols = {
            'a',
            ',',
        },
        rules = {
            s = 'item ("," s)?',
            item = '"a"',
        },
    }))
    local code = compiled.syntax.code
    -- item = 1 (entry 1), s = 2 (entry 4): s has a kind, so the call of s
    -- in tail position stays a CALL (its EXIT must follow)
    -- LuaFormatter off
    assert.equal(code, {
        MATCH, 6,           -- 1: item
        RET,                -- 3
        CALL, 1,            -- 4: s
        TEST, 1, 13,        -- 6
        MATCH, 7,           -- 9
        CALL, 2,            -- 11
        RET,                -- 13
    })
    -- LuaFormatter on
end

function testcase.generate_tail_calls_through_forward_jumps()
    local compiled = compiled_of(grammar({
        symbols = {
            'a',
            'x',
            'z',
        },
        rules = {
            s = '_r "z"',
            _r = 'item | "x"',
            item = '"a"',
        },
    }))
    -- rules by name: _r = 1 (entry 1), item = 2, s = 3; the call of item
    -- is followed by JUMP end and RET, so it becomes a tail call
    assert.equal(compiled.syntax.rules[1].name, '_r')
    -- LuaFormatter off
    assert.equal({
        unpack(compiled.syntax.code, 1, 9),
    }, {
        SWITCH, 1,          -- 1
        TAILCALL, 2,        -- 3
        JUMP, 9,            -- 5
        MATCH, 7,           -- 7
        RET,                -- 9
    })
    -- LuaFormatter on
    assert.is_true(accepts(compiled, 'a z'))
    assert.is_true(accepts(compiled, 'x z'))
end

function testcase.generate_records_second_token_decisions()
    local compiled = compiled_of(grammar({
        symbols = {
            '=',
            '(',
            ')',
            '{',
            '}',
            ',',
        },
        start = 'table',
        rules = {
            field = 'name "=" expr | expr',
            expr = 'name ("(" ")")* | number',
            table = '"{" (field ("," field)*)? "}"',
        },
    }))
    local syntax = compiled.syntax
    local name, number = compiled.names.name, compiled.names.number
    local lit = compiled.literals
    -- rules by name: expr, field, table; field starts with a SWITCH
    local field = syntax.rules[2]
    assert.equal(field.name, 'field')
    assert.equal(syntax.code[field.entry], SWITCH)
    local switch = syntax.decisions[syntax.code[field.entry + 1]]
    local alt1 = field.entry + 2
    assert.equal(syntax.code[alt1], MATCH)
    assert.equal(syntax.code[alt1 + 1], name)
    -- alternative 1 is MATCH name, MATCH "=", CALL expr, JUMP end
    assert.equal(syntax.code[alt1 + 6], JUMP)
    local alt2 = alt1 + 8
    assert.equal(switch.first, {
        [number] = alt2,
    })
    assert.equal(switch.second, {
        [name] = {
            [lit['=']] = alt1,
            [lit['(']] = alt2,
            [lit[',']] = alt2,
            [lit['}']] = alt2,
        },
    })

    assert.is_true(accepts(compiled, '{ }'))
    assert.is_true(accepts(compiled, '{ name = number , number }'))
    assert.is_true(accepts(compiled, '{ name ( ) ( ) , name = name }'))
    assert.is_false(accepts(compiled, '{ = }'))
    assert.is_false(accepts(compiled, '{ name = }'))
    assert.is_false(accepts(compiled, '{ name , }'))
end

function testcase.generate_runs_possessive_repetitions_and_ordered_choices()
    local compiled = compiled_of(grammar({
        keywords = {
            'if',
            'then',
            'else',
        },
        symbols = {
            '=',
            '(',
            ')',
        },
        rules = {
            s = 'stat*',
            stat = '"if" name "then" stat ("else" stat)?+ | call',
            call = 'name "=" name / name "(" ")"',
        },
    }))

    assert.is_true(accepts(compiled, ''))
    assert.is_true(accepts(compiled, 'if name then name ( ) else name = name'))
    -- possessive: the else belongs to the inner if, and both parse
    assert.is_true(accepts(compiled,
                           'if name then if name then name ( ) else name ( )'))
    -- the ordered choice backtracks from the first alternative
    assert.is_true(accepts(compiled, 'name ( ) name = name'))
    assert.is_false(accepts(compiled, 'name ('))
    assert.is_false(accepts(compiled, 'else'))
end

function testcase.generate_tail_calls_do_not_grow_the_stack()
    local compiled = compiled_of(grammar({
        symbols = {
            '[',
            ']',
            ',',
        },
        rules = {
            s = '"[" _items "]"',
            _items = 'name ("," _items)?',
        },
    }))
    local words = {
        '[',
    }
    for i = 1, 200 do
        words[#words + 1] = i > 1 and ', name' or 'name'
    end
    words[#words + 1] = ']'

    local ok, depth = recognize(compiled,
                                kinds_of(compiled, table.concat(words, ' ')))

    assert.is_true(ok)
    assert.equal(depth, 1)
end

function testcase.generate_is_deterministic()
    local function build()
        return compiled_of(grammar({
            symbols = {
                'a',
                'b',
            },
            rules = {
                s = '(_x | "b")* "a"?',
                _x = '"a" "b"',
            },
        })).syntax
    end

    assert.equal(build(), build())
end
