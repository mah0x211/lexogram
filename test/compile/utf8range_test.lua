local testcase = require('testcase')
local assert = require('assert')
local utf8range = require('lexogram.compile.utf8range')
local utf8 = require('lexogram.utf8')
local unpack = require('lexogram.compat').unpack
local byte = string.byte
local char = string.char

-- a sequence from flat byte bounds: q(lo1, hi1, lo2, hi2, ...)
local function q(...)
    local bounds = {
        ...,
    }
    local seq = {}
    for i = 1, #bounds, 2 do
        seq[#seq + 1] = {
            bounds[i],
            bounds[i + 1],
        }
    end
    return seq
end

-- the sequence that matches only the encoding of cp
local function single(cp)
    local s = assert(utf8.encode(cp))
    local seq = {}
    for i = 1, #s do
        seq[i] = {
            byte(s, i),
            byte(s, i),
        }
    end
    return seq
end

-- exact output

function testcase.split_returns_ascii_and_two_byte_ranges()
    assert.equal(utf8range.split(0, 0x7F), {
        q(0x00, 0x7F),
    })
    assert.equal(utf8range.split(0x80, 0x7FF), {
        q(0xC2, 0xDF, 0x80, 0xBF),
    })
end

function testcase.split_returns_minimal_sequences_for_all_scalar_values()
    assert.equal(utf8range.split(0, 0x10FFFF), {
        q(0x00, 0x7F),
        q(0xC2, 0xDF, 0x80, 0xBF),
        q(0xE0, 0xE0, 0xA0, 0xBF, 0x80, 0xBF),
        q(0xE1, 0xEC, 0x80, 0xBF, 0x80, 0xBF),
        q(0xED, 0xED, 0x80, 0x9F, 0x80, 0xBF),
        q(0xEE, 0xEF, 0x80, 0xBF, 0x80, 0xBF),
        q(0xF0, 0xF0, 0x90, 0xBF, 0x80, 0xBF, 0x80, 0xBF),
        q(0xF1, 0xF3, 0x80, 0xBF, 0x80, 0xBF, 0x80, 0xBF),
        q(0xF4, 0xF4, 0x80, 0x8F, 0x80, 0xBF, 0x80, 0xBF),
    })
end

function testcase.split_returns_ranges_inside_one_block()
    -- U+3042 .. U+3100: E3 81 82 .. E3 84 80
    assert.equal(utf8range.split(0x3042, 0x3100), {
        q(0xE3, 0xE3, 0x81, 0x81, 0x82, 0xBF),
        q(0xE3, 0xE3, 0x82, 0x83, 0x80, 0xBF),
        q(0xE3, 0xE3, 0x84, 0x84, 0x80, 0x80),
    })
end

function testcase.split_splits_at_encoding_length_boundaries()
    assert.equal(utf8range.split(0x700, 0x900), {
        q(0xDC, 0xDF, 0x80, 0xBF),
        q(0xE0, 0xE0, 0xA0, 0xA3, 0x80, 0xBF),
        q(0xE0, 0xE0, 0xA4, 0xA4, 0x80, 0x80),
    })
    assert.equal(utf8range.split(0x41, 0x80), {
        q(0x41, 0x7F),
        q(0xC2, 0xC2, 0x80, 0x80),
    })
    assert.equal(utf8range.split(0xFFFF, 0x10000), {
        q(0xEF, 0xEF, 0xBF, 0xBF, 0xBF, 0xBF),
        q(0xF0, 0xF0, 0x90, 0x90, 0x80, 0x80, 0x80, 0x80),
    })
end

function testcase.split_skips_surrogates()
    assert.equal(utf8range.split(0xD000, 0xE000), {
        q(0xED, 0xED, 0x80, 0x9F, 0x80, 0xBF),
        q(0xEE, 0xEE, 0x80, 0x80, 0x80, 0x80),
    })
    assert.equal(utf8range.split(0xD7FF, 0xE000), {
        q(0xED, 0xED, 0x9F, 0x9F, 0xBF, 0xBF),
        q(0xEE, 0xEE, 0x80, 0x80, 0x80, 0x80),
    })
    assert.equal(utf8range.split(0xD800, 0xDFFF), {})
    assert.equal(utf8range.split(0xDABC, 0xDABC), {})
    assert.equal(utf8range.split(0xDC00, 0xE001), {
        q(0xEE, 0xEE, 0x80, 0x80, 0x80, 0x81),
    })
end

function testcase.split_returns_single_code_points_at_boundaries()
    for _, cp in ipairs({
        0,
        0x7F,
        0x80,
        0x7FF,
        0x800,
        0xD7FF,
        0xE000,
        0xFFFF,
        0x10000,
        0x10FFFF,
    }) do
        assert.equal(utf8range.split(cp, cp), {
            single(cp),
        })
    end
    -- the explicit bytes of a few of them
    assert.equal(utf8range.split(0x7FF, 0x7FF), {
        q(0xDF, 0xDF, 0xBF, 0xBF),
    })
    assert.equal(utf8range.split(0x10FFFF, 0x10FFFF), {
        q(0xF4, 0xF4, 0x8F, 0x8F, 0xBF, 0xBF, 0xBF, 0xBF),
    })
end

function testcase.split_returns_fresh_tables()
    local first = utf8range.split(0, 0x7F)
    first[1][1][1] = 0x41

    assert.equal(utf8range.split(0, 0x7F), {
        q(0x00, 0x7F),
    })
end

-- exactness

-- number of scalar values (code points except surrogates) in lo..hi
local function count_scalars(lo, hi)
    local n = hi - lo + 1
    local slo = lo > 0xD800 and lo or 0xD800
    local shi = hi < 0xDFFF and hi or 0xDFFF
    if slo <= shi then
        n = n - (shi - slo + 1)
    end
    return n
end

-- the smallest code point a sequence encodes: the decoding of its lower
-- bounds, which must be a valid encoding
local function first_code_point(seq)
    local bytes = {}
    for i, pair in ipairs(seq) do
        bytes[i] = pair[1]
    end
    return (utf8.decode(char(unpack(bytes))))
end

-- return the first scalar value in lo..hi that is not matched by exactly
-- one of the sequences in by_length (indexed by encoding length), with
-- its match count, or nil
local function find_unmatched(lo, hi, by_length)
    for cp = lo, hi do
        if cp < 0xD800 or cp > 0xDFFF then
            local s = utf8.encode(cp)
            local len = #s
            local matched = 0
            for _, seq in ipairs(by_length[len]) do
                local ok = true
                for i = 1, len do
                    local b = byte(s, i)
                    local pair = seq[i]
                    if b < pair[1] or b > pair[2] then
                        ok = false
                        break
                    end
                end
                if ok then
                    matched = matched + 1
                end
            end
            if matched ~= 1 then
                return cp, matched
            end
        end
    end
    return nil
end

-- run fn(...) with the debug hook removed and return its results. The
-- line hook of luacov makes the exhaustive enumeration about 40 times
-- slower; only test code and lexogram.utf8 (covered by its own tests) run
-- inside, so the coverage of the module under test is unaffected.
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
    return res[2], res[3]
end

-- check that the sequences of lo..hi are well-formed, ordered and match
-- exactly the encodings of the scalar values in lo..hi; return a list of
-- problems (empty when exact)
local function check_exact(lo, hi)
    local problems = {}
    local seqs = utf8range.split(lo, hi)
    local by_length = {
        {},
        {},
        {},
        {},
    }
    local total = 0
    local prev = -1
    for _, seq in ipairs(seqs) do
        local count = 1
        for _, pair in ipairs(seq) do
            if pair[1] < 0 or pair[2] > 255 or pair[1] > pair[2] then
                problems[#problems + 1] = 'malformed pair'
            end
            count = count * (pair[2] - pair[1] + 1)
        end
        if #seq < 1 or #seq > 4 then
            problems[#problems + 1] = 'malformed sequence'
        else
            local list = by_length[#seq]
            list[#list + 1] = seq
        end
        total = total + count
        local first = first_code_point(seq)
        if not first or first <= prev then
            problems[#problems + 1] = 'not ordered'
        end
        prev = first or prev
    end

    -- (b) the sequences match as many byte strings as there are scalars
    if total ~= count_scalars(lo, hi) then
        problems[#problems + 1] = 'matched count ' .. total
    end

    -- (a) every scalar value is matched by exactly one sequence
    local cp, matched = without_hook(find_unmatched, lo, hi, by_length)
    if cp then
        problems[#problems + 1] = string.format('U+%04X matched %d times', cp,
                                                matched)
    end
    return problems
end

function testcase.split_is_exact_on_boundary_ranges()
    for _, range in ipairs({
        {
            0,
            0,
        },
        {
            0,
            0x80,
        },
        {
            0x7F,
            0x80,
        },
        {
            0x3F,
            0x40,
        },
        {
            0x7FF,
            0x800,
        },
        {
            0x7C0,
            0x83F,
        },
        {
            0xFFF,
            0x1000,
        },
        {
            0x81,
            0xFFFE,
        },
        {
            0xD7FF,
            0xD800,
        },
        {
            0xDFFF,
            0xE000,
        },
        {
            0xD7FF,
            0xE000,
        },
        {
            0xD800,
            0xDFFF,
        },
        {
            0xC000,
            0xF000,
        },
        {
            0xFFFF,
            0x10000,
        },
        {
            0xFFC0,
            0x1003F,
        },
        {
            0x3FFFF,
            0x40000,
        },
        {
            0x3FFC1,
            0x4003E,
        },
        {
            0x10000,
            0x10FFFF,
        },
        {
            0xFFFFF,
            0x100000,
        },
        {
            0x10FFFF,
            0x10FFFF,
        },
        {
            0x7FE,
            0x10001,
        },
    }) do
        assert.equal(check_exact(range[1], range[2]), {})
    end
end

function testcase.split_is_exact_on_full_range()
    assert.equal(check_exact(0, 0x10FFFF), {})
end

function testcase.split_is_exact_on_pseudo_random_ranges()
    -- Park-Miller LCG: products stay below 2^53, so every runtime computes
    -- the same sequence
    local state = 20261116
    local function nextint()
        state = (16807 * state) % 2147483647
        return state
    end

    for _ = 1, 200 do
        local lo = nextint() % 0x110000
        local width = nextint() % (2 ^ (nextint() % 17))
        local hi = lo + width
        if hi > 0x10FFFF then
            hi = 0x10FFFF
        end
        assert.equal(check_exact(lo, hi), {})
    end
end

-- arguments

function testcase.split_raises_for_invalid_arguments()
    for _, case in ipairs({
        {
            {
                nil,
                1,
            },
            'lo must be integer, got nil',
        },
        {
            {
                '1',
                1,
            },
            'lo must be integer, got string',
        },
        {
            {
                1.5,
                2,
            },
            'lo must be integer, got 1.5',
        },
        {
            {
                0 / 0,
                2,
            },
            'lo must be integer, got ',
        },
        {
            {
                -1,
                2,
            },
            'lo must be in range 0 to 1114111 (0x10FFFF), got -1',
        },
        {
            {
                0,
                0x110000,
            },
            'hi must be in range 0 to 1114111 (0x10FFFF), got 1114112',
        },
        {
            {
                0,
                1 / 0,
            },
            'hi must be in range 0 to 1114111 (0x10FFFF), got ',
        },
        {
            {
                0,
                {},
            },
            'hi must be integer, got table',
        },
        {
            {
                0,
                2.25,
            },
            'hi must be integer, got 2.25',
        },
        {
            {
                0x42,
                0x41,
            },
            'lo must not be greater than hi',
        },
    }) do
        local err = assert.throws(utf8range.split, case[1][1], case[1][2])
        assert.match(err, case[2])
    end
end
