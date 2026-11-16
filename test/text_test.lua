local testcase = require('testcase')
local assert = require('assert')
local text = require('lexogram.text')

function testcase.escape_keeps_printable_ascii()
    assert.equal(text.escape(''), '')
    assert.equal(text.escape('abc XYZ 019 _-+'), 'abc XYZ 019 _-+')
    assert.equal(text.escape('~!@#$%^&*()[]{}'), '~!@#$%^&*()[]{}')
end

function testcase.escape_escapes_quote_and_backslash()
    assert.equal(text.escape('a"b'), 'a\\"b')
    assert.equal(text.escape('a\\b'), 'a\\\\b')
    assert.equal(text.escape('"\\"'), '\\"\\\\\\"')
end

function testcase.escape_writes_control_and_high_bytes_as_decimal()
    assert.equal(text.escape(string.char(0, 1, 9, 10, 13, 31)),
                 '\\000\\001\\009\\010\\013\\031')
    assert.equal(text.escape(string.char(127, 128, 255)), '\\127\\128\\255')
    assert.equal(text.escape('a' .. string.char(195, 169) .. 'b'),
                 'a\\195\\169b')
    -- 32 and 126 are plain
    assert.equal(text.escape(string.char(32, 126)), ' ~')
end

function testcase.quote_encloses_escaped_string()
    assert.equal(text.quote(''), '""')
    assert.equal(text.quote('if'), '"if"')
    assert.equal(text.quote('a"\n'), '"a\\"\\010"')
end
