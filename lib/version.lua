--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- lexogram.version: parses and compares grammar specification versions.
-- Versions are CalVer strings yyyy.mm.dd.n: yyyy, mm and dd are zero-padded
-- to 4, 2 and 2 digits; n is the revision within the date, starts at 1 and
-- is never zero-padded. Comparison is numeric, element by element.
local type = type
local error = error
local tonumber = tonumber
local byte = string.byte
local match = string.match

-- Versions at which the grammar specification changed, ascending. The table
-- is exposed as is; callers are trusted not to modify it.
local HISTORY = {
    '2026.11.15.1',
}

-- Largest number of digits of the revision n.
local MAX_REVISION_DIGITS = 9
-- Byte value of "0".
local ZERO = 48
-- Days in each month of a common year.
local DAYS_IN_MONTH = {
    31,
    28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
}

--- is_leap_year returns true if year is a Gregorian leap year.
--- @param year integer
--- @return boolean
local function is_leap_year(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

--- check_revision returns an error message if the revision digits n are
--- not valid, or nil.
--- @param n string
--- @return string? err
local function check_revision(n)
    if n == '0' then
        return 'revision must be at least 1'
    elseif byte(n, 1) == ZERO then
        return 'revision must not have a leading zero'
    elseif #n > MAX_REVISION_DIGITS then
        return 'revision must have at most ' .. MAX_REVISION_DIGITS .. ' digits'
    end
    return nil
end

--- check_date returns an error message if year, month and day do not form
--- a real calendar date, or nil.
--- @param year integer
--- @param month integer
--- @param day integer
--- @return string? err
local function check_date(year, month, day)
    if year == 0 then
        return 'invalid date: year must not be 0000'
    elseif month < 1 or month > 12 then
        return 'invalid date: month must be 01 to 12'
    end

    local days = DAYS_IN_MONTH[month]
    if month == 2 and is_leap_year(year) then
        days = 29
    end
    if day < 1 or day > days then
        return 'invalid date: day must be 01 to ' .. days .. ' in month ' ..
                   month .. ' of year ' .. year
    end
    return nil
end

--- parse_version parses the version string str.
--- @param str string
--- @return integer[]? version { year, month, day, n }
--- @return string? err
local function parse_version(str)
    local y, m, d, n = match(str, '^(%d%d%d%d)%.(%d%d)%.(%d%d)%.(%d+)$')
    if not y then
        return nil, 'version must have the form yyyy.mm.dd.n'
    end

    local err = check_revision(n)
    if err then
        return nil, err
    end

    local year, month, day = tonumber(y), tonumber(m), tonumber(d)
    err = check_date(year, month, day)
    if err then
        return nil, err
    end
    return {
        year,
        month,
        day,
        tonumber(n),
    }
end

--- compare_parsed compares two parsed versions element by element.
--- @param a integer[]
--- @param b integer[]
--- @return integer -1, 0 or 1
local function compare_parsed(a, b)
    for i = 1, 4 do
        if a[i] < b[i] then
            return -1
        elseif a[i] > b[i] then
            return 1
        end
    end
    return 0
end

--- parse parses the version string str.
--- @param str string
--- @return integer[]? version { year, month, day, n }
--- @return string? err
local function parse(str)
    if type(str) ~= 'string' then
        error('str must be string, got ' .. type(str), 2)
    end
    return parse_version(str)
end

--- parse_argument parses the version string v passed as argument name of
--- a public function, and raises an error at the level of its caller if v
--- is not a valid version string.
--- @param name string
--- @param v any
--- @return integer[]
local function parse_argument(name, v)
    if type(v) ~= 'string' then
        error(name .. ' must be string, got ' .. type(v), 3)
    end

    local parsed, err = parse_version(v)
    if not parsed then
        error(name .. ' must be a valid version: ' .. err, 3)
    end
    return parsed
end

--- compare compares the version strings a and b.
--- @param a string
--- @param b string
--- @return integer -1 if a < b, 0 if a == b, 1 if a > b
local function compare(a, b)
    return compare_parsed(parse_argument('a', a), parse_argument('b', b))
end

--- lookup returns the greatest entry of history that is less than or equal
--- to the parsed version v, or nil if v is below the first entry.
--- @param v integer[]
--- @param history string[] ascending version strings
--- @return string?
local function lookup(v, history)
    for i = #history, 1, -1 do
        if compare_parsed(parse_version(history[i]), v) <= 0 then
            return history[i]
        end
    end
    return nil
end

--- resolve returns the entry of history in effect for the version string
--- str: the greatest entry that is less than or equal to str.
--- @param str any
--- @param history string[]? ascending version strings; defaults to HISTORY.
--- It is intended for tests, and its entries are trusted to be valid. Its
--- last entry is the current version.
--- @return string? spec
--- @return string? code 'invalid_version', 'version_too_new' or
--- 'version_too_old'
--- @return string? message
local function resolve(str, history)
    history = history or HISTORY
    if type(str) ~= 'string' then
        return nil, 'invalid_version',
               'version must be string, got ' .. type(str)
    end

    local v, err = parse_version(str)
    if not v then
        return nil, 'invalid_version',
               'invalid version "' .. str .. '": ' .. err
    end

    local current = history[#history]
    if compare_parsed(v, parse_version(current)) > 0 then
        return nil, 'version_too_new', 'version ' .. str ..
                   ' is newer than the current version ' .. current
    end

    local spec = lookup(v, history)
    if not spec then
        return nil, 'version_too_old', 'version ' .. str ..
                   ' is older than the first version ' .. history[1]
    end
    return spec
end

return {
    HISTORY = HISTORY,
    CURRENT = HISTORY[#HISTORY],
    parse = parse,
    compare = compare,
    resolve = resolve,
}
