local testcase = require('testcase')
local assert = require('assert')
local utf8 = require('lexogram.utf8')

-- encode

function testcase.encode_returns_bytes_for_each_sequence_length()
    for _, case in ipairs({
        {
            cp = 0x41,
            bytes = 'A',
        },
        {
            cp = 0xE9,
            bytes = '\195\169',
        },
        {
            cp = 0x3042,
            bytes = '\227\129\130',
        },
        {
            cp = 0x1F600,
            bytes = '\240\159\152\128',
        },
    }) do
        local str, err = utf8.encode(case.cp)

        assert.is_nil(err)
        assert.equal(str, case.bytes)
    end
end

function testcase.encode_returns_bytes_for_boundary_code_points()
    for _, case in ipairs({
        {
            cp = 0,
            bytes = '\0',
        },
        {
            cp = 0x7F,
            bytes = '\127',
        },
        {
            cp = 0x80,
            bytes = '\194\128',
        },
        {
            cp = 0x7FF,
            bytes = '\223\191',
        },
        {
            cp = 0x800,
            bytes = '\224\160\128',
        },
        {
            cp = 0xFFFF,
            bytes = '\239\191\191',
        },
        {
            cp = 0x10000,
            bytes = '\240\144\128\128',
        },
        {
            cp = 0x10FFFF,
            bytes = '\244\143\191\191',
        },
    }) do
        local str, err = utf8.encode(case.cp)

        assert.is_nil(err)
        assert.equal(str, case.bytes)
    end
end

function testcase.encode_accepts_code_points_next_to_surrogates()
    for _, case in ipairs({
        {
            cp = 0xD7FF,
            bytes = '\237\159\191',
        },
        {
            cp = 0xE000,
            bytes = '\238\128\128',
        },
    }) do
        local str, err = utf8.encode(case.cp)

        assert.is_nil(err)
        assert.equal(str, case.bytes)
    end
end

function testcase.encode_rejects_surrogates()
    for _, cp in ipairs({
        0xD800,
        0xDBFF,
        0xDC00,
        0xDFFF,
    }) do
        local str, err = utf8.encode(cp)

        assert.is_nil(str)
        assert.equal(err, 'surrogate code point')
    end
end

function testcase.encode_rejects_out_of_range_code_points()
    for _, cp in ipairs({
        -1,
        0x110000,
        math.huge,
        -math.huge,
    }) do
        local str, err = utf8.encode(cp)

        assert.is_nil(str)
        assert.equal(err, 'code point out of range')
    end
end

function testcase.encode_rejects_non_integer_values()
    for _, case in ipairs({
        {
            value = 1.5,
        },
        {
            value = 0 / 0,
        },
        {
            value = '65',
        },
        {
            value = nil,
        },
        {
            value = {},
        },
        {
            value = true,
        },
        {
            value = print,
        },
    }) do
        local str, err = utf8.encode(case.value)

        assert.is_nil(str)
        assert.equal(err, 'code point must be an integer')
    end
end

function testcase.encode_rejects_missing_argument()
    local str, err = utf8.encode()

    assert.is_nil(str)
    assert.equal(err, 'code point must be an integer')
end

-- decode

function testcase.decode_returns_code_point_and_length()
    for _, case in ipairs({
        {
            s = 'A',
            cp = 0x41,
            len = 1,
        },
        {
            s = '\195\169',
            cp = 0xE9,
            len = 2,
        },
        {
            s = '\227\129\130',
            cp = 0x3042,
            len = 3,
        },
        {
            s = '\240\159\152\128',
            cp = 0x1F600,
            len = 4,
        },
    }) do
        local cp, len = utf8.decode(case.s, 1)

        assert.equal(cp, case.cp)
        assert.equal(len, case.len)
    end
end

function testcase.decode_uses_position_one_by_default()
    local cp, len = utf8.decode('\227\129\130A')

    assert.equal(cp, 0x3042)
    assert.equal(len, 3)
end

function testcase.decode_reads_sequence_at_given_position()
    -- 'A' .. U+3042 .. U+1F600 .. 'B'
    local s = 'A\227\129\130\240\159\152\128B'

    local cp, len = utf8.decode(s, 2)
    assert.equal(cp, 0x3042)
    assert.equal(len, 3)

    cp, len = utf8.decode(s, 5)
    assert.equal(cp, 0x1F600)
    assert.equal(len, 4)

    cp, len = utf8.decode(s, 9)
    assert.equal(cp, 0x42)
    assert.equal(len, 1)
end

function testcase.decode_returns_integral_code_point()
    local cp = utf8.decode('\244\143\191\191')

    assert.equal(cp, math.floor(cp))
    assert.equal(cp, 0x10FFFF)
end

function testcase.decode_returns_boundary_code_points()
    for _, case in ipairs({
        {
            s = '\0',
            cp = 0,
            len = 1,
        },
        {
            s = '\127',
            cp = 0x7F,
            len = 1,
        },
        {
            s = '\194\128',
            cp = 0x80,
            len = 2,
        },
        {
            s = '\223\191',
            cp = 0x7FF,
            len = 2,
        },
        {
            s = '\224\160\128',
            cp = 0x800,
            len = 3,
        },
        {
            s = '\239\191\191',
            cp = 0xFFFF,
            len = 3,
        },
        {
            s = '\240\144\128\128',
            cp = 0x10000,
            len = 4,
        },
        {
            s = '\244\143\191\191',
            cp = 0x10FFFF,
            len = 4,
        },
        {
            s = '\237\159\191',
            cp = 0xD7FF,
            len = 3,
        },
        {
            s = '\238\128\128',
            cp = 0xE000,
            len = 3,
        },
    }) do
        local cp, len = utf8.decode(case.s, 1)

        assert.equal(cp, case.cp)
        assert.equal(len, case.len)
    end
end

function testcase.decode_ignores_bytes_after_the_sequence()
    -- the byte after the sequence is invalid but is not consumed
    local cp, len = utf8.decode('\195\169\255', 1)

    assert.equal(cp, 0xE9)
    assert.equal(len, 2)
end

function testcase.decode_rejects_position_out_of_range()
    for _, case in ipairs({
        {
            s = 'abc',
            pos = 0,
        },
        {
            s = 'abc',
            pos = -1,
        },
        {
            s = 'abc',
            pos = 4,
        },
        {
            s = '\227\129\130',
            pos = 4,
        },
        {
            s = '',
            pos = 1,
        },
    }) do
        local cp, err = utf8.decode(case.s, case.pos)

        assert.is_nil(cp)
        assert.equal(err, 'position out of range')
    end
end

function testcase.decode_rejects_empty_string_with_default_position()
    local cp, err = utf8.decode('')

    assert.is_nil(cp)
    assert.equal(err, 'position out of range')
end

function testcase.decode_rejects_invalid_lead_bytes()
    for _, s in ipairs({
        '\128',
        '\191',
        '\192\128',
        '\193\191',
        '\245\128\128\128',
        '\255',
    }) do
        local cp, err = utf8.decode(s, 1)

        assert.is_nil(cp)
        assert.equal(err, 'invalid lead byte')
    end
end

function testcase.decode_rejects_continuation_byte_in_middle_of_sequence()
    -- position 2 points at the second byte of U+3042
    local cp, err = utf8.decode('\227\129\130', 2)

    assert.is_nil(cp)
    assert.equal(err, 'invalid lead byte')
end

function testcase.decode_rejects_truncated_sequences()
    for _, s in ipairs({
        '\195',
        '\227',
        '\227\129',
        '\240',
        '\240\159',
        '\240\159\152',
    }) do
        local cp, err = utf8.decode(s, 1)

        assert.is_nil(cp)
        assert.equal(err, 'truncated sequence')
    end
end

function testcase.decode_reports_truncation_before_invalid_continuation()
    -- 'A' is not a continuation byte, but the sequence is also cut off
    local cp, err = utf8.decode('\227A', 1)

    assert.is_nil(cp)
    assert.equal(err, 'truncated sequence')
end

function testcase.decode_rejects_invalid_continuation_bytes()
    for _, s in ipairs({
        -- 2-byte sequence, second byte
        '\195A',
        '\195\192',
        -- 3-byte sequence, second and third byte
        '\227A\130',
        '\227\129A',
        '\227\129\255',
        -- 4-byte sequence, second, third and fourth byte
        '\240A\152\128',
        '\240\159A\128',
        '\240\159\152A',
        '\240\159\152\195',
    }) do
        local cp, err = utf8.decode(s, 1)

        assert.is_nil(cp)
        assert.equal(err, 'invalid continuation byte')
    end
end

function testcase.decode_reports_invalid_continuation_before_overlong()
    -- overlong lead 0xE0 followed by a bad continuation byte
    local cp, err = utf8.decode('\224\128A', 1)

    assert.is_nil(cp)
    assert.equal(err, 'invalid continuation byte')
end

function testcase.decode_rejects_overlong_encodings()
    for _, s in ipairs({
        '\224\128\128',
        '\224\159\191',
        '\240\128\128\128',
        '\240\143\191\191',
    }) do
        local cp, err = utf8.decode(s, 1)

        assert.is_nil(cp)
        assert.equal(err, 'overlong encoding')
    end
end

function testcase.decode_rejects_surrogates()
    for _, s in ipairs({
        '\237\160\128',
        '\237\191\191',
    }) do
        local cp, err = utf8.decode(s, 1)

        assert.is_nil(cp)
        assert.equal(err, 'surrogate code point')
    end
end

function testcase.decode_rejects_code_points_above_maximum()
    for _, s in ipairs({
        '\244\144\128\128',
        '\244\191\191\191',
    }) do
        local cp, err = utf8.decode(s, 1)

        assert.is_nil(cp)
        assert.equal(err, 'code point out of range')
    end
end

function testcase.decode_raises_error_on_non_string_s()
    local err = assert.throws(utf8.decode, 65, 1)
    assert.match(err, 's must be string, got number')

    err = assert.throws(utf8.decode, nil)
    assert.match(err, 's must be string, got nil')

    err = assert.throws(utf8.decode, {}, 1)
    assert.match(err, 's must be string, got table')
end

function testcase.decode_raises_error_on_non_integer_pos()
    local err = assert.throws(utf8.decode, 'abc', '1')
    assert.match(err, 'pos must be integer, got string')

    err = assert.throws(utf8.decode, 'abc', 1.5)
    assert.match(err, 'pos must be integer, got number')

    err = assert.throws(utf8.decode, 'abc', false)
    assert.match(err, 'pos must be integer, got boolean')

    err = assert.throws(utf8.decode, 'abc', {})
    assert.match(err, 'pos must be integer, got table')
end

-- round trip

function testcase.decode_of_encode_returns_original_code_point()
    for _, cp in ipairs({
        0,
        0x41,
        0x7F,
        0x80,
        0xE9,
        0x7FF,
        0x800,
        0x3042,
        0xD7FF,
        0xE000,
        0xFFFD,
        0xFFFF,
        0x10000,
        0x1F600,
        0x10FFFF,
    }) do
        local str = assert(utf8.encode(cp))

        local decoded, len = utf8.decode(str, 1)

        assert.equal(decoded, cp)
        assert.equal(len, #str)
    end
end
