local testcase = require('testcase')
local assert = require('assert')
local compile = require('lexogram.compile')
local check = require('lexogram.check')
local version = require('lexogram.version')

-- a small valid grammar
local function small_grammar()
    return {
        lexogram = '2026.11.15.1',
        start = 'chunk',
        tokens = {
            name = '(ALPHA | "_") (ALPHA | DIGIT | "_")*',
            number = '_digits ("." _digits)?',
            _digits = 'DIGIT+',
            space = '[ \\t\\n]+',
            long_string = {
                open = '"[" level "["',
                close = '"]" level "]"',
                level = '"="*',
            },
        },
        symbols = {
            '=',
            ';',
        },
        keywords = {
            'local',
            'name',
            ignore_case = true,
        },
        skip = {
            'space',
        },
        rules = {
            chunk = 'stat*',
            stat = '"local" name "=" value ";" / "name" ";"',
            value = 'number | long_string | name',
        },
    }
end

-- a realistic Lua-like grammar
local function lua_grammar()
    return {
        lexogram = '2026.11.15.1',
        start = 'chunk',
        tokens = {
            name = '(ALPHA | "_") (ALPHA | DIGIT | "_")*',
            number = '_digits ("." _digits)? (("e" | "E") ("+" | "-")? _digits)?',
            _digits = 'DIGIT+',
            string = '"\\"" ([^"\\\\\\n] | "\\\\" ANY)* "\\""',
            space = '[ \\t\\r\\n]+',
            comment = '"--" [^\\n]*',
            long_string = {
                open = '"[" level "["',
                close = '"]" level "]"',
                level = '"="*',
            },
            long_comment = {
                open = '"--[" level "["',
                close = '"]" level "]"',
                level = '"="*',
            },
        },
        symbols = {
            '=',
            '==',
            '(',
            ')',
            ',',
            '..',
        },
        keywords = {
            'local',
            'return',
            'nil',
        },
        skip = {
            'space',
            'comment',
            'long_comment',
        },
        rules = {
            chunk = 'stat* ("return" exp)?',
            stat = '"local" name "=" exp / name "(" (exp ("," exp)*)? ")"',
            exp = 'term (("==" / "..") term)*',
            term = 'number | string | long_string | name | "nil"',
        },
    }
end

-- longest accepted non-empty prefix of s from pos in a compiled automaton
local function longest(a, s, pos)
    local state, id, stop = 1, nil, nil
    for i = pos, #s do
        state = a.trans[(state - 1) * a.nclasses + a.classes[s:byte(i) + 1]]
        if state == 0 then
            break
        elseif a.accept[state] ~= 0 then
            id, stop = a.accept[state], i + 1
        end
    end
    return id, stop
end

-- the end of the capture by the runtime contract
local function capture_end(a, s, first)
    local state, stop = 1, first
    for i = first, #s do
        state = a.trans[(state - 1) * a.nclasses + a.classes[s:byte(i) + 1]]
        if state == 0 then
            break
        end
        stop = i + 1
    end
    return stop
end

-- tokenize s with the compiled object only; skipped tokens are dropped
local function tokenize(compiled, s)
    local lexer = compiled.lexer
    local out = {}
    local pos = 1
    while pos <= #s do
        local id, stop = longest(lexer.open, s, pos)
        if id then
            local entry
            for _, e in ipairs(lexer.delimited) do
                if e.id == id then
                    entry = e
                end
            end
            local captured = ''
            if entry.capture then
                local first = pos + entry.prefix
                captured =
                    s:sub(first, capture_end(entry.capture, s, first) - 1)
            end
            local parts = {}
            for i, part in ipairs(entry.close) do
                parts[i] = part.literal or captured
            end
            local close = table.concat(parts)
            local at = s:find(close, stop, true)
            stop = at and at + #close or #s + 1
        else
            id, stop = longest(lexer, s, pos)
            if not id then
                id, stop = compiled.names.INVALID, pos + 1
            end
        end
        if not compiled.kinds[id].skip then
            out[#out + 1] = compiled.kinds[id].name .. ':' ..
                                s:sub(pos, stop - 1)
        end
        pos = stop
    end
    return out
end

-- check that v is plain data without metatables, cycles or shared tables;
-- returns a list of problems
local function plain_data_problems(v)
    local problems, seen = {}, {}
    local stack = {
        v,
    }
    while #stack > 0 do
        local t = table.remove(stack)
        if seen[t] then
            problems[#problems + 1] = 'table referenced twice'
        else
            seen[t] = true
            if getmetatable(t) ~= nil then
                problems[#problems + 1] = 'metatable'
            end
            for k, x in pairs(t) do
                local tk, tx = type(k), type(x)
                if tk ~= 'string' and tk ~= 'number' then
                    problems[#problems + 1] = 'key of type ' .. tk
                end
                if tx == 'table' then
                    stack[#stack + 1] = x
                elseif tx ~= 'string' and tx ~= 'number' and tx ~= 'boolean' then
                    problems[#problems + 1] = 'value of type ' .. tx
                end
            end
        end
    end
    return problems
end

function testcase.compile_returns_diagnostics_for_errors()
    local grammar = small_grammar()
    grammar.rules.value = 'number | "?"'

    local compiled, diagnostics = compile.compile(grammar)

    assert.is_nil(compiled)
    assert.equal(diagnostics, check.check(grammar))
    assert.equal(diagnostics[1].code, 'undeclared_literal')
end

function testcase.compile_returns_object_and_warnings()
    local grammar = small_grammar()
    grammar.tokens.unused = '"!"'

    local compiled, diagnostics = compile.compile(grammar)

    assert.is_table(compiled)
    assert.equal(diagnostics, {
        {
            severity = 'warning',
            code = 'unused_token',
            path = 'tokens.unused',
            message = 'tokens.unused is not used by any rule and not listed' ..
                ' in skip',
        },
    })
end

function testcase.compile_returns_kinds_names_and_literals()
    local compiled, diagnostics = compile.compile(small_grammar())

    assert.equal(diagnostics, {})
    assert.equal(compiled.lexogram, version.resolve('2026.11.15.1'))
    assert.equal(compiled.kinds, {
        {
            name = 'INVALID',
            category = 'error',
            skip = false,
        },
        {
            name = 'ERROR',
            category = 'error',
            skip = false,
        },
        {
            name = 'name',
            category = 'token',
            skip = false,
        },
        {
            name = 'number',
            category = 'token',
            skip = false,
        },
        {
            name = 'space',
            category = 'token',
            skip = true,
        },
        {
            name = '=',
            category = 'symbol',
            skip = false,
        },
        {
            name = ';',
            category = 'symbol',
            skip = false,
        },
        {
            name = 'local',
            category = 'keyword',
            skip = false,
        },
        {
            name = 'name',
            category = 'keyword',
            skip = false,
        },
        {
            name = 'long_string',
            category = 'token',
            skip = false,
        },
    })
    assert.equal(compiled.names, {
        INVALID = 1,
        ERROR = 2,
        name = 3,
        number = 4,
        space = 5,
        long_string = 10,
    })
    -- the keyword "name" does not clash with the token name
    assert.equal(compiled.literals, {
        ['='] = 6,
        [';'] = 7,
        ['local'] = 8,
        name = 9,
    })
    assert.equal(compiled.lexer.delimited[1].id, 10)
    assert.equal(compiled.lexer.delimited[1].prefix, 1)
    assert.equal(compiled.lexer.delimited[1].close, {
        {
            literal = ']',
        },
        {
            capture = true,
        },
        {
            literal = ']',
        },
    })
    assert.equal(#compiled.lexer.classes, 256)
    assert.equal(#compiled.lexer.trans,
                 compiled.lexer.nstates * compiled.lexer.nclasses)
    assert.equal(#compiled.lexer.accept, compiled.lexer.nstates)
end

function testcase.compile_returns_resolved_revision()
    local grammar = small_grammar()
    grammar.lexogram = version.CURRENT

    local compiled = assert(compile.compile(grammar))

    -- the entry of the revision history in effect, not the grammar's string
    assert.equal(compiled.lexogram, version.resolve(grammar.lexogram))
    assert.equal(compiled.lexogram, version.HISTORY[#version.HISTORY])
end

function testcase.compile_tokenizes_with_compiled_tables_only()
    local compiled = assert(compile.compile(lua_grammar()))
    local src = 'local x = [==[a]]b]==] -- note\n' ..
                    'f("s\\"", 1.5e3, nil..y) --[[ long\n]] return x==NIL ?'

    assert.equal(tokenize(compiled, src), {
        'local:local',
        'name:x',
        '=:=',
        'long_string:[==[a]]b]==]',
        'name:f',
        '(:(',
        'string:"s\\""',
        ',:,',
        'number:1.5e3',
        ',:,',
        'nil:nil',
        '..:..',
        'name:y',
        '):)',
        'return:return',
        'name:x',
        '==:==',
        'name:NIL',
        'INVALID:?',
    })
end

function testcase.compile_is_deterministic_plain_data()
    local first = assert(compile.compile(lua_grammar()))
    local second = assert(compile.compile(lua_grammar()))

    assert.equal(first, second)
    assert.equal(plain_data_problems(first), {})
    assert.is_nil(first.lexer.accept_sets)
    assert.is_nil(first.lexer.conflicts)
end

function testcase.compile_finds_shared_tables_in_test_helper()
    local shared = {}
    assert.equal(plain_data_problems({
        a = shared,
        b = shared,
    }), {
        'table referenced twice',
    })
    local problems = plain_data_problems(setmetatable({
        f = print,
        [true] = 1,
    }, {}))
    table.sort(problems)
    assert.equal(problems, {
        'key of type boolean',
        'metatable',
        'value of type function',
    })
end

-- a metatable whose metamethods raise if they are ever triggered
local function trap()
    local function fail()
        error('metamethod must not be triggered')
    end
    return {
        __index = fail,
        __newindex = fail,
        __pairs = fail,
        __ipairs = fail,
        __len = fail,
    }
end

function testcase.compile_never_raises()
    for _, v in ipairs({
        1,
        'grammar',
        true,
        print,
        setmetatable({}, trap()),
    }) do
        local ok, compiled, diagnostics = pcall(compile.compile, v)
        assert.is_true(ok)
        assert.is_nil(compiled)
        assert.is_table(diagnostics)
    end
    local ok, compiled = pcall(compile.compile)
    assert.is_true(ok)
    assert.is_nil(compiled)

    -- a valid grammar whose tables have trapping metatables compiles
    local grammar = small_grammar()
    for _, field in ipairs({
        'tokens',
        'symbols',
        'keywords',
        'skip',
        'rules',
    }) do
        setmetatable(grammar[field], trap())
    end
    setmetatable(grammar.tokens.long_string, trap())
    setmetatable(grammar, trap())
    local diagnostics
    ok, compiled, diagnostics = pcall(compile.compile, grammar)
    assert.is_true(ok)
    assert.equal(diagnostics, {})
    assert.equal(rawget(compiled, 'names').long_string, 10)
end
