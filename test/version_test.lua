local testcase = require('testcase')
local assert = require('assert')
local version = require('lexogram.version')

local SHAPE = 'version must have the form yyyy.mm.dd.n'

-- check that each case { str, message } fails to parse with message
local function check_parse_errors(cases)
    for _, case in ipairs(cases) do
        local v, err = version.parse(case[1])

        assert.is_nil(v)
        assert.equal(err, case[2])
    end
end

-- HISTORY and CURRENT

function testcase.history_and_current()
    assert.equal(version.HISTORY, {
        '2026.11.15.1',
    })
    assert.equal(version.CURRENT, '2026.11.15.1')
end

-- parse

function testcase.parse_returns_version_elements()
    for _, case in ipairs({
        {
            '2026.11.15.1',
            {
                2026,
                11,
                15,
                1,
            },
        },
        {
            '2026.01.05.12',
            {
                2026,
                1,
                5,
                12,
            },
        },
        {
            '0001.12.31.999999999',
            {
                1,
                12,
                31,
                999999999,
            },
        },
        {
            '2024.02.29.1',
            {
                2024,
                2,
                29,
                1,
            },
        },
        {
            '2000.02.29.1',
            {
                2000,
                2,
                29,
                1,
            },
        },
        {
            '2026.04.30.1',
            {
                2026,
                4,
                30,
                1,
            },
        },
    }) do
        local v, err = version.parse(case[1])

        assert.is_nil(err)
        assert.equal(v, case[2])
    end
end

function testcase.parse_returns_error_for_wrong_shape()
    check_parse_errors({
        {
            '',
            SHAPE,
        },
        {
            '2026.11.15',
            SHAPE,
        },
        {
            '2026.11.15.1.1',
            SHAPE,
        },
        {
            '2026.1.15.1',
            SHAPE,
        },
        {
            '2026.11.5.1',
            SHAPE,
        },
        {
            '20260.11.15.1',
            SHAPE,
        },
        {
            '2026.11.15.a',
            SHAPE,
        },
        {
            'v2026.11.15.1',
            SHAPE,
        },
        {
            ' 2026.11.15.1',
            SHAPE,
        },
        {
            '2026.11.15.1 ',
            SHAPE,
        },
        {
            '2026.11.15.1\n',
            SHAPE,
        },
        {
            '2026.11.15.1' .. string.char(0),
            SHAPE,
        },
        {
            '2026.11.15.+1',
            SHAPE,
        },
        {
            '2026-11-15-1',
            SHAPE,
        },
    })
end

function testcase.parse_returns_error_for_invalid_revision()
    check_parse_errors({
        {
            '2026.11.15.01',
            'revision must not have a leading zero',
        },
        {
            '2026.11.15.0',
            'revision must be at least 1',
        },
        {
            '2026.11.15.00',
            'revision must not have a leading zero',
        },
        {
            '2026.11.15.1000000000',
            'revision must have at most 9 digits',
        },
    })
end

function testcase.parse_returns_error_for_invalid_date()
    check_parse_errors({
        {
            '2026.00.15.1',
            'invalid date: month must be 01 to 12',
        },
        {
            '2026.13.15.1',
            'invalid date: month must be 01 to 12',
        },
        {
            '2026.11.00.1',
            'invalid date: day must be 01 to 30 in month 11 of year 2026',
        },
        {
            '2026.01.32.1',
            'invalid date: day must be 01 to 31 in month 1 of year 2026',
        },
        {
            '2026.04.31.1',
            'invalid date: day must be 01 to 30 in month 4 of year 2026',
        },
        {
            '2026.02.29.1',
            'invalid date: day must be 01 to 28 in month 2 of year 2026',
        },
        {
            '1900.02.29.1',
            'invalid date: day must be 01 to 28 in month 2 of year 1900',
        },
        {
            '2100.02.29.1',
            'invalid date: day must be 01 to 28 in month 2 of year 2100',
        },
        {
            '2024.02.30.1',
            'invalid date: day must be 01 to 29 in month 2 of year 2024',
        },
        {
            '0000.01.01.1',
            'invalid date: year must not be 0000',
        },
    })
end

function testcase.parse_raises_for_non_string()
    local err = assert.throws(version.parse, nil)
    assert.match(err, 'str must be string, got nil')

    err = assert.throws(version.parse, 2026)
    assert.match(err, 'str must be string, got number')
end

-- compare

function testcase.compare_orders_by_each_element()
    for _, case in ipairs({
        {
            '2025.12.31.9',
            '2026.01.01.1',
        },
        {
            '2026.01.31.9',
            '2026.02.01.1',
        },
        {
            '2026.02.01.9',
            '2026.02.02.1',
        },
        {
            '2026.02.02.1',
            '2026.02.02.2',
        },
        -- the revision is compared as a number, not as a string
        {
            '2026.02.02.2',
            '2026.02.02.10',
        },
        {
            '2026.02.02.99',
            '2026.02.02.100',
        },
    }) do
        assert.equal(version.compare(case[1], case[2]), -1)
        assert.equal(version.compare(case[2], case[1]), 1)
    end
end

function testcase.compare_returns_zero_for_equal_versions()
    assert.equal(version.compare('2026.11.15.1', '2026.11.15.1'), 0)
end

function testcase.compare_raises_for_invalid_versions()
    local err = assert.throws(version.compare, nil, '2026.11.15.1')
    assert.match(err, 'a must be string, got nil')

    err = assert.throws(version.compare, '2026.11.15.1', 1)
    assert.match(err, 'b must be string, got number')

    err = assert.throws(version.compare, '2026.11.15', '2026.11.15.1')
    assert.match(err, 'a must be a valid version: ' .. SHAPE)

    err = assert.throws(version.compare, '2026.11.15.1', '2026.02.30.1')
    assert.match(err, 'b must be a valid version: invalid date: ')
end

-- resolve

function testcase.resolve_returns_current_for_current_version()
    local spec, code, message = version.resolve('2026.11.15.1')

    assert.equal(spec, '2026.11.15.1')
    assert.is_nil(code)
    assert.is_nil(message)
end

function testcase.resolve_returns_error_for_too_new_version()
    for _, str in ipairs({
        '2026.11.15.2',
        '2027.01.01.1',
    }) do
        local spec, code, message = version.resolve(str)

        assert.is_nil(spec)
        assert.equal(code, 'version_too_new')
        assert.equal(message, 'version ' .. str ..
                         ' is newer than the current version 2026.11.15.1')
    end
end

function testcase.resolve_returns_error_for_too_old_version()
    local spec, code, message = version.resolve('2026.11.14.9')

    assert.is_nil(spec)
    assert.equal(code, 'version_too_old')
    assert.equal(message, 'version 2026.11.14.9 is older than the first ' ..
                     'version 2026.11.15.1')
end

function testcase.resolve_returns_error_for_invalid_version()
    local spec, code, message = version.resolve('2026.11.15.01')
    assert.is_nil(spec)
    assert.equal(code, 'invalid_version')
    assert.equal(message, 'invalid version "2026.11.15.01": ' ..
                     'revision must not have a leading zero')

    spec, code, message = version.resolve('latest')
    assert.is_nil(spec)
    assert.equal(code, 'invalid_version')
    assert.equal(message, 'invalid version "latest": ' .. SHAPE)

    for _, v in ipairs({
        {
            20261115,
            'number',
        },
        {
            {},
            'table',
        },
    }) do
        spec, code, message = version.resolve(v[1])
        assert.is_nil(spec)
        assert.equal(code, 'invalid_version')
        assert.equal(message, 'version must be string, got ' .. v[2])
    end

    spec, code, message = version.resolve(nil)
    assert.is_nil(spec)
    assert.equal(code, 'invalid_version')
    assert.equal(message, 'version must be string, got nil')
end

function testcase.resolve_uses_custom_history()
    local history = {
        '2026.01.01.1',
        '2026.03.01.2',
        '2026.03.01.10',
        '2027.06.30.1',
    }

    for _, case in ipairs({
        -- exact entries
        {
            '2026.01.01.1',
            '2026.01.01.1',
        },
        {
            '2026.03.01.2',
            '2026.03.01.2',
        },
        {
            '2026.03.01.10',
            '2026.03.01.10',
        },
        {
            '2027.06.30.1',
            '2027.06.30.1',
        },
        -- values between entries
        {
            '2026.01.01.2',
            '2026.01.01.1',
        },
        {
            '2026.03.01.1',
            '2026.01.01.1',
        },
        {
            '2026.03.01.9',
            '2026.03.01.2',
        },
        {
            '2027.06.29.99',
            '2026.03.01.10',
        },
    }) do
        local spec, code, message = version.resolve(case[1], history)

        assert.is_nil(code)
        assert.is_nil(message)
        assert.equal(spec, case[2])
    end

    -- below the first entry
    local spec, code, message = version.resolve('2025.12.31.1', history)
    assert.is_nil(spec)
    assert.equal(code, 'version_too_old')
    assert.equal(message, 'version 2025.12.31.1 is older than the first ' ..
                     'version 2026.01.01.1')

    -- above the last entry, which is the current version of that history
    spec, code, message = version.resolve('2027.06.30.2', history)
    assert.is_nil(spec)
    assert.equal(code, 'version_too_new')
    assert.equal(message, 'version 2027.06.30.2 is newer than the current ' ..
                     'version 2027.06.30.1')
end
