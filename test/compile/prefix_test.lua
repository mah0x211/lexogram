local testcase = require('testcase')
local assert = require('assert')
local lexer = require('lexogram.compile.lexer')
local prefix = require('lexogram.compile.prefix')

-- the lexer of a grammar with the given fields (the lexer reads only the
-- tokens, the literals and leading)
local function build(fields, prefixed)
    local g = {
        lexogram = '2026.11.15.1',
        name = 'test',
        version = '1.0.0',
        start = 's',
        rules = {
            s = 's',
        },
    }
    for k, v in pairs(fields) do
        g[k] = v
    end
    local result, diagnostics = lexer.build(g, nil, prefixed)
    assert(result, diagnostics[1] and diagnostics[1].message)
    return result
end

-- the names of the kinds of the set ids, sorted
local function names(result, ids)
    local out = {}
    for id in pairs(ids) do
        out[#out + 1] = result.defs[id].name
    end
    table.sort(out)
    return out
end

-- the names of the kinds that a literal can split, sorted
local function split_by(result, text, ignore_case)
    return names(result, prefix.longer(result, prefix.literal_automaton(text,
                                                                        ignore_case)))
end

-- the kind id of the definition named name
local function id_of(result, name)
    for _, def in ipairs(result.defs) do
        if def.name == name then
            return def.id
        end
    end
end

-- the strings of the automaton d up to n bytes over the bytes of alphabet
local function strings(d, alphabet, n)
    local out = {}
    local function walk(s, text)
        if d.accept[s] > 0 then
            out[#out + 1] = text
        end
        if #text < n then
            for i = 1, #alphabet do
                local b = alphabet:byte(i)
                local t = d.trans[(s - 1) * d.nclasses + d.classes[b + 1]]
                if t ~= 0 then
                    walk(t, text .. alphabet:sub(i, i))
                end
            end
        end
    end
    walk(1, '')
    table.sort(out)
    return out
end

function testcase.literal_automaton_accepts_the_text()
    local d = prefix.literal_automaton('a>')
    assert.equal(strings(d, 'aA>b', 3), {
        'a>',
    })
    -- with ignore_case, each spelling of the letters
    d = prefix.literal_automaton('If', true)
    assert.equal(strings(d, 'iIfFx', 3), {
        'IF',
        'If',
        'iF',
        'if',
    })
end

function testcase.longer_finds_the_literals_that_start_with_a_literal()
    local result = build({
        tokens = {
            name = 'ALPHA+',
        },
        symbols = {
            '<',
            '>',
            '>>',
            '>=',
            '>>=',
        },
    })
    assert.equal(split_by(result, '>'), {
        '>=',
        '>>',
        '>>=',
    })
    assert.equal(split_by(result, '>>'), {
        '>>=',
    })
    -- no longer token starts with "<"
    assert.equal(split_by(result, '<'), {})
end

function testcase.longer_finds_the_pattern_tokens_that_start_with_a_keyword()
    local result = build({
        tokens = {
            name = '[a-z]+',
            number = 'DIGIT+',
        },
        keywords = {
            'if',
        },
    })
    -- "ifx" is a name
    assert.equal(split_by(result, 'if'), {
        'name',
    })
    -- "IFX" is no token, but "ifx" is: with ignore_case, every spelling
    assert.equal(split_by(result, 'IF', true), {
        'name',
    })
    assert.equal(split_by(result, 'IF'), {})
end

function testcase.longer_reads_a_pattern_token_by_its_own_automaton()
    local result = build({
        tokens = {
            gt = '">"+',
            ge = '">"+ "="',
        },
    }, {
        gt = true,
    })
    -- only the tokens named in prefixed have an automaton of their own
    assert.is_nil(result.prefixes[id_of(result, 'ge')])
    -- each run of ">" can go on into a longer gt or a ge
    local d = result.prefixes[id_of(result, 'gt')]
    assert.equal(names(result, prefix.longer(result, d)), {
        'ge',
        'gt',
    })
end

function testcase.longer_takes_every_target_of_a_dispatch_state()
    local result = build({
        tokens = {
            gt_joint = '">" (?=[>=])',
            gt = '">" (?![>=])',
            shr = '">>"',
        },
    }, {
        gt_joint = true,
    })
    local d = result.prefixes[id_of(result, 'gt_joint')]
    assert.equal(names(result, prefix.longer(result, d)), {
        'shr',
    })
end

function testcase.longer_finds_the_leading_and_the_delimited_tokens()
    local result = build({
        tokens = {
            shebang = '"#!" [^\\n]*',
            hash = '"#"',
            long_string = {
                open = '"[["',
                close = '"]]"',
            },
        },
        symbols = {
            '[',
        },
        leading = {
            'shebang',
        },
    })
    -- "#" can start a shebang at the start of the input
    assert.equal(split_by(result, '#'), {
        'shebang',
    })
    -- "[" ends inside the open "[["
    assert.equal(split_by(result, '['), {
        'long_string',
    })
    -- the open "[[" ends inside "[[x": the text may go on into the body
    assert.equal(split_by(result, '[[x'), {
        'long_string',
    })
end
