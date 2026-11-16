local testcase = require('testcase')
local assert = require('assert')
local compat = require('lexogram.compat')

-- unpack

function testcase.unpack_returns_all_elements_of_list()
    local list = {
        'a',
        'b',
        'c',
    }

    local n = select('#', compat.unpack(list))
    local values = {
        compat.unpack(list),
    }

    assert.equal(n, 3)
    assert.equal(values, {
        'a',
        'b',
        'c',
    })
end

function testcase.unpack_honors_range()
    local list = {
        'a',
        'b',
        'c',
        'd',
    }

    local n = select('#', compat.unpack(list, 2, 3))
    local values = {
        compat.unpack(list, 2, 3),
    }

    assert.equal(n, 2)
    assert.equal(values, {
        'b',
        'c',
    })
end

function testcase.unpack_is_builtin_function()
    -- compat.unpack is a reference to the built-in function, not a wrapper
    assert.rawequal(compat.unpack, unpack or table.unpack)
end

-- load_text

function testcase.load_text_returns_function_bound_to_env()
    local env = {
        greeting = 'hello',
    }

    local fn, err = compat.load_text('return greeting', 'env_chunk', env)

    assert.is_nil(err)
    assert.is_function(fn)
    assert.equal(fn(), 'hello')
end

function testcase.load_text_assigns_globals_into_env()
    local env = {}

    local fn, err = compat.load_text('lexogram_compat_test_global = 42',
                                     'assign_chunk', env)
    fn()

    assert.is_nil(err)
    assert.equal(env.lexogram_compat_test_global, 42)
    assert.is_nil(rawget(_G, 'lexogram_compat_test_global'))
end

function testcase.load_text_does_not_modify_env_metatable()
    local env = {}

    local fn = compat.load_text('return 1', 'meta_chunk', env)
    fn()

    assert.is_nil(getmetatable(env))
    assert.empty(env)
end

function testcase.load_text_reads_undefined_global_as_nil()
    local env = {}

    local fn, err = compat.load_text('return print', 'undefined_chunk', env)

    assert.is_nil(err)
    assert.is_nil(fn())
end

function testcase.load_text_chunk_returns_multiple_values()
    local env = {}

    local fn, err = compat.load_text('return 1, nil, 3', 'multi_chunk', env)
    local n = select('#', fn())
    local values = {
        fn(),
    }

    assert.is_nil(err)
    assert.equal(n, 3)
    assert.equal(values[1], 1)
    assert.is_nil(values[2])
    assert.equal(values[3], 3)
end

function testcase.load_text_accepts_empty_source()
    local env = {}

    local fn, err = compat.load_text('', 'empty_chunk', env)

    assert.is_nil(err)
    assert.equal(select('#', fn()), 0)
end

function testcase.load_text_returns_error_on_syntax_error()
    local env = {}

    local fn, err = compat.load_text('return +', 'syntax_chunk', env)

    assert.is_nil(fn)
    assert.is_string(err)
    assert.match(err, 'syntax_chunk')
end

function testcase.load_text_rejects_binary_chunk()
    local env = {}
    local bin = string.dump(function()
    end)

    local fn, err = compat.load_text(bin, 'binary_chunk', env)

    assert.is_nil(fn)
    assert.match(err, 'binary_chunk: attempt to load a binary chunk')
end

function testcase.load_text_rejects_source_starting_with_esc_byte()
    local env = {}

    local fn, err = compat.load_text('\27return 1', 'esc_chunk', env)

    assert.is_nil(fn)
    assert.match(err, 'esc_chunk: attempt to load a binary chunk')
end

function testcase.load_text_raises_error_on_invalid_src()
    local err = assert.throws(compat.load_text, 123, 'chunk', {})

    assert.match(err, 'src must be string, got number')
end

function testcase.load_text_raises_error_on_invalid_chunkname()
    local err = assert.throws(compat.load_text, 'return 1', nil, {})

    assert.match(err, 'chunkname must be string, got nil')
end

function testcase.load_text_raises_error_on_invalid_env()
    local err = assert.throws(compat.load_text, 'return 1', 'chunk', 'env')

    assert.match(err, 'env must be table, got string')
end

-- sorted_keys

function testcase.sorted_keys_returns_numbers_before_strings()
    local tbl = {
        b = true,
        [2] = true,
        a = true,
        [1] = true,
    }

    local keys = compat.sorted_keys(tbl)

    assert.equal(keys, {
        1,
        2,
        'a',
        'b',
    })
end

function testcase.sorted_keys_sorts_numbers_ascending()
    local tbl = {
        [3] = true,
        [-1.5] = true,
        [0] = true,
        [2.25] = true,
        [-10] = true,
        [1] = true,
    }

    local keys = compat.sorted_keys(tbl)

    assert.equal(keys, {
        -10,
        -1.5,
        0,
        1,
        2.25,
        3,
    })
end

function testcase.sorted_keys_sorts_strings_in_byte_order()
    local tbl = {
        ['\200'] = true,
        ab = true,
        b = true,
        a = true,
        B = true,
        z = true,
        [''] = true,
    }

    local keys = compat.sorted_keys(tbl)

    assert.equal(keys, {
        '',
        'B',
        'a',
        'ab',
        'b',
        'z',
        '\200',
    })
end

function testcase.sorted_keys_returns_empty_array_for_empty_table()
    local keys = compat.sorted_keys({})

    assert.is_table(keys)
    assert.empty(keys)
end

function testcase.sorted_keys_returns_new_table_and_keeps_input_unchanged()
    local tbl = {
        'x',
        'y',
        key = 'value',
    }

    local keys = compat.sorted_keys(tbl)

    assert.not_rawequal(keys, tbl)
    assert.equal(keys, {
        1,
        2,
        'key',
    })
    assert.equal(tbl, {
        'x',
        'y',
        key = 'value',
    })
end

function testcase.sorted_keys_raises_error_on_boolean_key()
    local tbl = {
        [true] = 1,
    }

    local err = assert.throws(compat.sorted_keys, tbl)

    assert.match(err, 'unsupported key type: boolean')
end

function testcase.sorted_keys_raises_error_on_table_key()
    local tbl = {
        [{}] = 1,
    }

    local err = assert.throws(compat.sorted_keys, tbl)

    assert.match(err, 'unsupported key type: table')
end

function testcase.sorted_keys_raises_error_on_non_table()
    local err = assert.throws(compat.sorted_keys, 'not a table')

    assert.match(err, 'tbl must be table, got string')
end

-- sorted_pairs

function testcase.sorted_pairs_visits_pairs_in_sorted_keys_order()
    local tbl = {
        b = 'B',
        [2] = 'two',
        a = 'A',
        [-1] = 'minus one',
    }

    local visited = {}
    for k, v in compat.sorted_pairs(tbl) do
        visited[#visited + 1] = {
            k,
            v,
        }
    end

    assert.equal(visited, {
        {
            -1,
            'minus one',
        },
        {
            2,
            'two',
        },
        {
            'a',
            'A',
        },
        {
            'b',
            'B',
        },
    })
end

function testcase.sorted_pairs_fixes_keys_at_call_and_reads_values_on_visit()
    local tbl = {
        a = 1,
        b = 2,
    }

    local visited = {}
    for k, v in compat.sorted_pairs(tbl) do
        visited[#visited + 1] = {
            k,
            v,
        }
        -- a key added after the call is not visited; a changed value is seen
        tbl.c = 3
        tbl.b = 20
    end

    assert.equal(visited, {
        {
            'a',
            1,
        },
        {
            'b',
            20,
        },
    })
end

function testcase.sorted_pairs_visits_nothing_for_empty_table()
    local count = 0
    for _ in compat.sorted_pairs({}) do
        count = count + 1
    end

    assert.equal(count, 0)
end

function testcase.sorted_pairs_raises_error_on_unsupported_key_type()
    local tbl = {
        [true] = 1,
    }

    local err = assert.throws(compat.sorted_pairs, tbl)

    assert.match(err, 'unsupported key type: boolean')
end

function testcase.sorted_pairs_raises_error_on_non_table()
    local err = assert.throws(compat.sorted_pairs, 123)

    assert.match(err, 'tbl must be table, got number')
end
