local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local cli = require('lexogram.cli')

local WORDS = 'fixtures/cli/words.lua'
local BAD = 'fixtures/cli/bad.lua'
local WARNING = 'warning\tunreachable_rule\trules.unused\t' ..
                    'rules.unused is not reachable from start\n'

-- a file handle that keeps what is written
local function buffer()
    local b = {
        parts = {},
    }
    function b:write(...)
        for i = 1, select('#', ...) do
            self.parts[#self.parts + 1] = select(i, ...)
        end
        return self
    end
    function b:text()
        return table.concat(self.parts)
    end
    return b
end

-- runs the command with args and the standard input stdin, and returns the
-- exit code, the standard output and the standard error
local function run(args, stdin)
    local out, err = buffer(), buffer()
    local code = cli.main(args, {
        stdin = {
            read = function()
                return stdin
            end,
        },
        stdout = out,
        stderr = err,
    })
    return code, out:text(), err:text()
end

-- the content of the file at pathname
local function content(pathname)
    local f = assert(io.open(pathname, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

-- a temporary file with the content text, whose pathname fn receives
local function with_file(text, fn)
    local pathname = os.tmpname()
    local f = assert(io.open(pathname, 'wb'))
    f:write(text)
    f:close()
    local ok, err = pcall(fn, pathname)
    os.remove(pathname)
    assert(ok, err)
end

function testcase.usage_is_written_for_help_and_wrong_uses()
    local code, out, err = run({
        '--help',
    })
    assert.equal(code, 0)
    assert.match(out, '^usage: lexogram check GRAMMAR\n', false)
    assert.equal(err, '')
    for _, args in ipairs({
        {},
        {
            'none',
        },
        {
            'check',
        },
        {
            'check',
            WORDS,
            WORDS,
        },
        {
            'compile',
            WORDS,
            '-o',
        },
        {
            'parse',
            '--format',
            'xml',
            WORDS,
        },
    }) do
        code, out, err = run(args)
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.match(err, '^usage: ', false)
    end
end

function testcase.check_writes_the_diagnostics()
    assert.equal({
        run({
            'check',
            WORDS,
        }),
    }, {
        0,
        WARNING,
        '',
    })
    assert.equal({
        run({
            'check',
            BAD,
        }),
    }, {
        1,
        'error\tundefined_reference\trules.chunk\trules.chunk refers to' ..
            ' undefined token or rule "none"\n',
        '',
    })
    -- a file that cannot be read, and a grammar that cannot be loaded
    local code, out, err = run({
        'check',
        'fixtures/cli/none.lua',
    })
    assert.equal(code, 2)
    assert.equal(out, '')
    assert.match(err, 'fixtures/cli/none.lua', true)
    code, out, err = run({
        'check',
        'lexogram:none',
    })
    assert.equal(code, 1)
    assert.equal(out, '')
    assert.match(err, 'no built-in grammar named "none"', true)
end

function testcase.merge_writes_the_merged_grammar()
    assert.equal({
        run({
            'merge',
            'lexogram:lua52',
        }),
    }, {
        0,
        assert(lexogram.merge('lexogram:lua52')),
        '',
    })
    local code, out, err = run({
        'merge',
        BAD,
    })
    assert.equal(code, 0)
    assert.equal(out, assert(lexogram.merge(BAD)))
    assert.equal(err, '')
    code, out, err = run({
        'merge',
        'lexogram:none',
    })
    assert.equal(code, 1)
    assert.equal(out, '')
    assert.match(err, 'no built-in grammar named "none"', true)
end

function testcase.compile_saves_the_compiled_grammar()
    local compiled = assert(lexogram.compile(assert(lexogram.load(WORDS))))
    local text = assert(lexogram.dump(compiled))
    -- to the standard output, with the warnings on the standard error
    assert.equal({
        run({
            'compile',
            WORDS,
        }),
    }, {
        0,
        text,
        WARNING,
    })
    -- to a file, which the other commands read back
    with_file('', function(pathname)
        assert.equal({
            run({
                'compile',
                '-o',
                pathname,
                WORDS,
            }),
        }, {
            0,
            '',
            WARNING,
        })
        assert.equal(content(pathname), text)
        assert.equal({
            run({
                'check',
                pathname,
            }),
        }, {
            0,
            '',
            '',
        })
        -- the saved grammar has no warnings to write
        local code, out, err = run({
            'parse',
            pathname,
        }, 'ab')
        assert.equal({
            code,
            out,
            err,
        }, {
            0,
            (select(2, run({
                'parse',
                WORDS,
            }, 'ab'))),
            '',
        })
        code, out, err = run({
            'compile',
            pathname,
        })
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.equal(err, pathname .. ': already a compiled grammar\n')
        code, out, err = run({
            'merge',
            pathname,
        })
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.equal(err, pathname .. ': a compiled grammar cannot be merged\n')
    end)
    -- errors of the grammar, and a file that cannot be written
    local code, out, err = run({
        'compile',
        BAD,
    })
    assert.equal(code, 1)
    assert.equal(out, '')
    assert.match(err, 'undefined_reference', true)
    code, out, err = run({
        'compile',
        WORDS,
        '-o',
        'fixtures/cli/none/out.lua',
    })
    assert.equal(code, 2)
    assert.equal(out, '')
    assert.match(err, 'fixtures/cli/none/out.lua', true)
end

function testcase.parse_writes_the_result_as_json()
    local code, out, err = run({
        'parse',
        WORDS,
    }, 'ab, cd')
    assert.equal(code, 0)
    assert.equal(err, WARNING)
    assert.equal(out, table.concat({
        '{"grammar":{"name":"words","version":"1.0.0"},\n',
        '"kinds":[',
        '{"category":"error","name":"INVALID","skip":false},',
        '{"category":"error","name":"ERROR","skip":false},',
        '{"category":"token","name":"space","skip":true},',
        '{"category":"token","name":"word","skip":false},',
        '{"category":"symbol","name":",","skip":false},',
        '{"category":"rule","name":"chunk","skip":false},',
        '{"category":"rule","name":"unused","skip":false}],\n',
        '"events":[2,6,1,6,1,4,1,3,1,5,3,4,1,3,4,5,1,4,5,7,3,6,7,1],\n',
        '"errors":[]}\n',
    }))
    -- the events are those of lexogram.parse
    local compiled = assert(lexogram.compile(assert(lexogram.load(WORDS))))
    local result = assert(lexogram.parse(compiled, 'ab, cd'))
    local events = {}
    for i = 1, result.count * 4 do
        events[i] = result.events[i]
    end
    assert.equal(out:match('"events":%[([^%]]*)%]'), table.concat(events, ','))
end

function testcase.parse_writes_the_result_as_a_tree()
    with_file('ab, cd\n', function(pathname)
        assert.equal({
            run({
                'parse',
                '--format',
                'tree',
                WORDS,
                pathname,
            }),
        }, {
            0,
            table.concat({
                'chunk\n',
                '  word "ab"\n',
                '  ","\n',
                '  space " "\n',
                '  word "cd"\n',
                'space "\\n"\n',
            }),
            WARNING,
        })
    end)
    -- bytes that are not printable ASCII are escaped
    local _, out = run({
        'parse',
        '--format',
        'tree',
        'lexogram:lua51',
    }, 'x = "\226\128\148"')
    assert.match(out, 'string "\\"\\226\\128\\148\\""', true)
end

function testcase.parse_reports_syntax_errors_and_unreadable_sources()
    local code, out, err = run({
        'parse',
        WORDS,
    }, 'ab,')
    assert.equal(code, 1)
    assert.equal(out, '')
    assert.equal(err, WARNING .. '-:1:4: unexpected end of input,' ..
                     ' expected word\n')
    code, out, err = run({
        'parse',
        WORDS,
        'fixtures/cli/none.txt',
    })
    assert.equal(code, 2)
    assert.equal(out, '')
    assert.match(err, 'fixtures/cli/none.txt', true)
    -- a grammar with errors
    code, out, err = run({
        'parse',
        BAD,
    }, 'ab')
    assert.equal(code, 1)
    assert.equal(out, '')
    assert.match(err, 'undefined_reference', true)
end

function testcase.parse_rejects_names_that_json_cannot_carry()
    -- a saved grammar whose kind name was changed into bytes that are not
    -- UTF-8 (the check of a grammar rejects such literals)
    local compiled = assert(lexogram.compile(assert(lexogram.load(WORDS))))
    compiled.kinds[5].name = '\255'
    with_file(assert(lexogram.dump(compiled)), function(pathname)
        local code, out, err = run({
            'parse',
            pathname,
        }, 'ab')
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.match(err, 'invalid UTF-8', true)
    end)
end

-- the lines of the warnings of the mixins of the grammar file pathname
local function mixin_warnings(pathname)
    local _, _, warnings = lexogram.load(pathname)
    local lines = {}
    for _, w in ipairs(warnings) do
        lines[#lines + 1] = w.severity .. '\t' .. w.code .. '\t' .. w.path ..
                                '\t' .. w.message .. '\n'
    end
    assert.not_equal(#lines, 0)
    return table.concat(lines)
end

function testcase.the_warnings_of_mixins_are_written()
    local pathname = 'fixtures/mixins/warn.lua'
    local warnings = mixin_warnings(pathname)
    -- check writes them with the diagnostics, the others to the standard
    -- error
    local code, out, err = run({
        'check',
        pathname,
    })
    assert.equal(code, 0)
    assert.equal(out, warnings)
    assert.equal(err, '')
    for _, args in ipairs({
        {
            'merge',
            pathname,
        },
        {
            'compile',
            pathname,
        },
        {
            'parse',
            pathname,
        },
    }) do
        code, out, err = run(args, 'ab')
        assert.equal(code, 0)
        assert.not_equal(out, '')
        assert.equal(err, warnings)
    end
end

function testcase.files_that_cannot_be_read_or_parsed_are_reported()
    -- a directory cannot be read
    for _, args in ipairs({
        {
            'check',
            'fixtures/cli',
        },
        {
            'merge',
            'fixtures/cli',
        },
        {
            'compile',
            'fixtures/cli',
        },
        {
            'parse',
            'fixtures/cli',
        },
        {
            'parse',
            WORDS,
            'fixtures/cli',
        },
    }) do
        local code, out, err = run(args, 'ab')
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.match(err, 'fixtures/cli', true)
    end
    -- a saved grammar that undump rejects
    with_file('-- Generated by lexogram.dump.\nreturn { format = 0 }\n',
              function(pathname)
        for _, command in ipairs({
            'check',
            'parse',
        }) do
            local code, out, err = run({
                command,
                pathname,
            }, 'ab')
            assert.equal(code, 1)
            assert.equal(out, '')
            assert.match(err, pathname .. ': a compiled grammar of format 0',
                         true)
        end
    end)
    -- a grammar that cannot be loaded or merged
    for _, command in ipairs({
        'merge',
        'compile',
        'parse',
    }) do
        local code, out, err = run({
            command,
            'lexogram:none',
        }, 'ab')
        assert.equal(code, 1)
        assert.equal(out, '')
        assert.match(err, 'no built-in grammar named "none"', true)
    end
end

function testcase.wrong_arguments_are_reported_with_the_usage()
    for _, args in ipairs({
        {
            'merge',
        },
        {
            'compile',
        },
        {
            'compile',
            WORDS,
            WORDS,
        },
        {
            'compile',
            '-o',
            'a',
            '-o',
            'b',
            WORDS,
        },
        {
            'parse',
        },
        {
            'parse',
            WORDS,
            'a',
            'b',
        },
    }) do
        local code, out, err = run(args)
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.match(err, '^usage: ', false)
    end
end

function testcase.json_escapes_the_strings()
    local compiled = assert(lexogram.compile(assert(lexogram.load(WORDS))))
    compiled.kinds[5].name = 'a"b\\c\n\r\t\1\195\169'
    compiled.name, compiled.version = nil, nil
    with_file(assert(lexogram.dump(compiled)), function(pathname)
        local code, out = run({
            'parse',
            pathname,
        }, 'ab')
        assert.equal(code, 0)
        assert.match(out, '^{"grammar":{"name":null,"version":null},', false)
        local name = '"name":"a\\"b\\\\c\\n\\r\\t\\u0001\195\169"'
        assert.match(out, name, true)
    end)
end

function testcase.tree_escapes_the_text_of_tokens()
    local _, out = run({
        'parse',
        '--format',
        'tree',
        'lexogram:lua51',
    }, 'x = "a\\b\tc"\r\n')
    assert.match(out, 'string "\\"a\\\\b\\tc\\""', true)
    assert.match(out, 'space "\\r\\n"', true)
end

function testcase.errors_of_a_result_are_written_as_json()
    -- lexogram.parse that returns errors (recovered syntax errors, which
    -- grammars with recover will give)
    local parse = lexogram.parse
    local errors
    lexogram.parse = function(compiled, source)
        local result = assert(parse(compiled, source))
        result.errors = errors
        return result
    end
    local ok, err = pcall(function()
        errors = {
            {
                code = 'syntax_error',
                line = 1,
                column = 2.5,
                recovered = true,
                expected = {
                    'word',
                },
            },
        }
        local code, out = run({
            'parse',
            WORDS,
        }, 'ab')
        assert.equal(code, 0)
        assert.match(out, '"errors":[{"code":"syntax_error","column":2.5,' ..
                         '"expected":["word"],"line":1,"recovered":true}]}',
                     true)
        -- a value that JSON cannot carry
        errors = {
            print,
        }
        local stderr
        code, out, stderr = run({
            'parse',
            WORDS,
        }, 'ab')
        assert.equal(code, 2)
        assert.equal(out, '')
        assert.match(stderr, 'a value of type function cannot be written' ..
                         ' as JSON', true)
    end)
    lexogram.parse = parse
    assert(ok, err)
end
