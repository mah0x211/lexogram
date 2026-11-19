local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

-- a grammar with the contextual keyword global, from fields that replace
-- those of the default
local function grammar(fields)
    local g = {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 'chunk',
        tokens = {
            name = '[a-z]+',
            space = '" "+',
        },
        symbols = {
            '=',
            ';',
        },
        keywords = {
            'do',
            'end',
            contextual = {
                'global',
            },
        },
        skip = {
            'space',
        },
        rules = {
            chunk = 'stat*',
            stat = 'globalstat / other',
            other = '";" | name "=" name | "do" chunk "end"',
            globalstat = '"global" name',
        },
    }
    for k, v in pairs(fields or {}) do
        g[k] = v
    end
    return g
end

-- compile fields; it must have no errors
local function compiled_of(fields)
    local compiled, diagnostics = lexogram.compile(grammar(fields))
    for _, d in ipairs(diagnostics) do
        assert.not_equal(d.severity, 'error')
    end
    return assert(compiled)
end

-- the events of source as a string: "(rule", ")" and "kind:text" (skipped
-- tokens left out), or the message of the error
local function events_of(compiled, source)
    local result, err = lexogram.parse(compiled, source)
    if not result then
        return err.message
    end
    local out = {}
    local list = result.events
    for i = 0, result.count - 1 do
        local op, k = list[i * 4 + 1], list[i * 4 + 2]
        local kind = compiled.kinds[k]
        if op == events.ENTER then
            out[#out + 1] = '(' .. kind.name
        elseif op == events.EXIT then
            out[#out + 1] = ')'
        elseif not kind.skip then
            out[#out + 1] = kind.name .. ':' ..
                                source:sub(list[i * 4 + 3], list[i * 4 + 4] - 1)
        end
    end
    return table.concat(out, ' ')
end

-- the code and the path of each error diagnostic of fields
local function errors_of(fields)
    local out = {}
    for _, d in ipairs(lexogram.check(grammar(fields))) do
        if d.severity == 'error' then
            out[#out + 1] = {
                d.code,
                d.path,
            }
        end
    end
    return out
end

function testcase.a_contextual_keyword_is_a_name_elsewhere()
    local compiled = compiled_of()
    -- the keyword where the rules expect it, with the kind of the keyword
    assert.equal(events_of(compiled, 'global x'),
                 '(chunk (stat (globalstat global:global name:x ) ) )')
    -- the declaration fails at "=": the statement is tried again as other
    assert.equal(events_of(compiled, 'global = y'),
                 '(chunk (stat (other name:global =:= name:y ) ) )')
    assert.equal(events_of(compiled, 'x = global'),
                 '(chunk (stat (other name:x =:= name:global ) ) )')
    assert.equal(events_of(compiled, 'do global global end'),
                 '(chunk (stat (other do:do (chunk (stat (globalstat' ..
                     ' global:global name:global ) ) ) end:end ) ) )')
    -- a name of the same length is not the keyword
    assert.equal(events_of(compiled, 'globex = y'),
                 '(chunk (stat (other name:globex =:= name:y ) ) )')
    -- a keyword that is not expected is reported as its base token
    assert.equal(events_of(compiled, 'x = y global'),
                 'unexpected end of input, expected name, "="')
    assert.equal(events_of(compiled, 'x global'),
                 'unexpected name, expected "="')
end

function testcase.a_contextual_keyword_is_a_kind_of_its_own()
    local compiled = compiled_of()
    local id = compiled.literals.global
    local kind = compiled.kinds[id]
    assert.equal(kind.name, 'global')
    assert.equal(kind.category, 'keyword')
    assert.equal(kind.base, compiled.names.name)
    assert.is_nil(kind.ignore_case)
    -- it follows the keywords
    assert.equal(id, compiled.literals['end'] + 1)
    assert.is_nil(compiled.kinds[compiled.literals['do']].base)
    -- the tokenizer has no context: it reads the base token
    assert.equal(lexogram.tokenize(compiled, 'global', 1), compiled.names.name)
end

function testcase.ignore_case_applies_to_contextual_keywords()
    local compiled = compiled_of({
        tokens = {
            name = '[A-Za-z]+',
            space = '" "+',
        },
        keywords = {
            'do',
            'end',
            ignore_case = true,
            contextual = {
                'global',
            },
        },
    })
    assert.is_true(compiled.kinds[compiled.literals.global].ignore_case)
    assert.equal(events_of(compiled, 'GloBal x'),
                 '(chunk (stat (globalstat global:GloBal name:x ) ) )')
end

function testcase.choices_that_overlap_on_a_contextual_keyword_are_ambiguous()
    -- a name can be global: without an order, the choice is ambiguous
    -- where two tokens do not tell the alternatives apart
    local diagnostics = lexogram.check(grammar({
        rules = {
            chunk = 'stat*',
            stat = 'globalstat | other',
            other = '";" | name name | "do" chunk "end"',
            globalstat = '"global" name',
        },
    }))
    assert.equal(#diagnostics, 2)
    assert.equal(diagnostics[1].code, 'unused_literal')
    assert.equal(diagnostics[2].code, 'ambiguous_choice')
    assert.equal(diagnostics[2].message,
                 'rules.stat: alternatives 1 and 2 of the choice can both' ..
                     ' start with "global" name')
    -- an optional name before the keyword: two tokens tell them apart
    assert.equal(errors_of({
        rules = {
            chunk = 'name? "global"',
        },
    }), {})
    -- but not before global global, where a name can be global too
    assert.equal(errors_of({
        rules = {
            chunk = 'name? "global" name',
        },
    }), {
        {
            'ambiguous_repetition',
            'rules.chunk',
        },
    })
end

function testcase.contextual_keywords_are_checked()
    -- an item of contextual must be a string that is no other item
    assert.equal(errors_of({
        symbols = {
            '=',
            ';',
            'up',
        },
        keywords = {
            'do',
            'end',
            contextual = {
                'do',
                'up',
                'global',
                'global',
                '',
                {},
            },
        },
    }), {
        {
            'duplicate_item',
            'keywords.contextual[1]',
        },
        {
            'duplicate_item',
            'keywords.contextual[2]',
        },
        {
            'duplicate_item',
            'keywords.contextual[4]',
        },
        {
            'empty_item',
            'keywords.contextual[5]',
        },
        {
            'reserved_item',
            'keywords.contextual[6]',
        },
    })
    -- contextual is an array, in keywords only
    assert.equal(errors_of({
        symbols = {
            '=',
            ';',
            contextual = {
                'up',
            },
        },
        keywords = {
            'do',
            'end',
            contextual = {
                'global',
                x = 1,
            },
        },
    }), {
        {
            'unknown_field',
            'symbols.contextual',
        },
        {
            'unknown_field',
            'keywords.contextual.x',
        },
    })
    assert.equal(errors_of({
        keywords = {
            'do',
            'end',
            contextual = 'global',
        },
    }), {
        {
            'invalid_type',
            'keywords.contextual',
        },
        {
            'undeclared_literal',
            'rules.globalstat',
        },
    })
    -- a contextual keyword is a declared literal
    local warnings = {}
    for _, d in ipairs(lexogram.check(grammar({
        keywords = {
            'do',
            'end',
            contextual = {
                'global',
                'local',
            },
        },
    }))) do
        warnings[#warnings + 1] = d.code .. ' ' .. d.path
    end
    assert.equal(warnings, {
        'unused_literal keywords.contextual[2]',
    })
end

function testcase.a_contextual_keyword_is_read_as_exactly_one_token()
    local diagnostics = lexogram.check(grammar({
        keywords = {
            'do',
            'end',
            contextual = {
                'global',
                'global2',
            },
        },
        rules = {
            chunk = 'stat*',
            stat = 'globalstat / other',
            other = '";" | name "=" name | "do" chunk "end" | "global2"',
            globalstat = '"global" name',
        },
    }))
    assert.equal(#diagnostics, 1)
    assert.equal(diagnostics[1].code, 'invalid_contextual')
    assert.equal(diagnostics[1].path, 'keywords.contextual[2]')
    assert.equal(diagnostics[1].message,
                 'keywords.contextual[2] must be read as exactly one' ..
                     ' pattern token, which it stands for; it is read as none')
    -- each token where the lookaheads of the other one may not hold
    diagnostics = lexogram.check(grammar({
        tokens = {
            name = '[a-z]+ (?!"!")',
            bang = '[a-z]+ (?="!")',
            mark = '"!"',
            space = '" "+',
        },
    }))
    assert.equal(#diagnostics, 3)
    assert.equal(diagnostics[3].code, 'invalid_contextual')
    assert.match(diagnostics[3].message,
                 'it is read as tokens.bang or tokens.name', true)
    -- a token listed in skip never reaches the parser
    assert.equal(errors_of({
        tokens = {
            name = '[A-Z]+',
            word = '[a-z]+',
            space = '" "+',
        },
        skip = {
            'space',
            'word',
        },
    }), {
        {
            'invalid_contextual',
            'keywords.contextual[1]',
        },
    })
end
