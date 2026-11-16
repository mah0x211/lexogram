local testcase = require('testcase')
local assert = require('assert')
local compat = require('lexogram.compat')
local open = io.open
local find = string.find
local sub = string.sub
local gmatch = string.gmatch
local match = string.match

-- the testcase runner executes a test file with its own directory as the
-- working directory, so the repository root is one level up
local ROOT = '../'

local function read_file(pathname)
    local f = assert(open(pathname, 'rb'))
    local content = assert(f:read('*a'))
    f:close()
    return content
end

local function module_files()
    local src = read_file(ROOT .. 'rockspecs/lexogram-scm-1.rockspec')
    local env = {}
    local fn = assert(compat.load_text(src, 'rockspec', env))
    fn()

    local files = {}
    for _, pathname in compat.sorted_pairs(env.build.modules) do
        files[#files + 1] = pathname
    end
    return files
end

local FORBIDDEN_LETTERS = {
    x = true,
    z = true,
    u = true,
}

local function find_forbidden_escapes(src)
    local found = {}
    local lineno = 0
    -- backslash runs never span lines, so scan line by line
    for line in gmatch(src .. '\n', '([^\n]*)\n') do
        lineno = lineno + 1
        local pos = 1
        while true do
            local head, tail = find(line, '\\+', pos)
            if not head then
                break
            end
            -- the last backslash of a run is unescaped only when the run
            -- has an odd length
            local letter = sub(line, tail + 1, tail + 1)
            if (tail - head + 1) % 2 == 1 and FORBIDDEN_LETTERS[letter] then
                found[#found + 1] = {
                    line = lineno,
                    escape = '\\' .. letter,
                }
            end
            pos = tail + 1
        end
    end
    return found
end

-- find_forbidden_escapes

function testcase.find_forbidden_escapes_returns_empty_without_escapes()
    local src = 'local s = \'\\n\\t\\065\'\n-- plain comment\n'

    local found = find_forbidden_escapes(src)

    assert.equal(found, {})
end

function testcase.find_forbidden_escapes_reports_each_escape_with_line()
    local src = 'local a = \'\\x41\'\n' .. 'local b = 1\n' ..
                    'local c = \'a\\z  b\'\n' .. 'local d = \'\\u{41}\'\n'

    local found = find_forbidden_escapes(src)

    assert.equal(found, {
        {
            line = 1,
            escape = '\\x',
        },
        {
            line = 3,
            escape = '\\z',
        },
        {
            line = 4,
            escape = '\\u',
        },
    })
end

function testcase.find_forbidden_escapes_ignores_escaped_backslash()
    local src = 'local s = \'\\\\x41 \\\\z \\\\u\'\n'

    local found = find_forbidden_escapes(src)

    assert.equal(found, {})
end

function testcase.find_forbidden_escapes_reports_after_three_backslashes()
    local src = 'local s = \'\\\\\\x41\'\n'

    local found = find_forbidden_escapes(src)

    assert.equal(found, {
        {
            line = 1,
            escape = '\\x',
        },
    })
end

-- module_files

function testcase.module_files_lists_rockspec_modules()
    local files = module_files()

    assert.equal(files, {
        'lib/lexogram.lua',
        'lib/check.lua',
        'lib/compat.lua',
        'lib/compile/utf8range.lua',
        'lib/loader.lua',
        'lib/pattern.lua',
        'lib/utf8.lua',
        'lib/version.lua',
    })
end

-- rules for every module source

function testcase.modules_compile_as_lua_source()
    local failures = {}

    for _, pathname in ipairs(module_files()) do
        local fn, err = compat.load_text(read_file(ROOT .. pathname), pathname,
                                         {})
        if not fn then
            failures[#failures + 1] = pathname .. ': ' .. tostring(err)
        end
    end

    assert.equal(failures, {})
end

function testcase.modules_have_no_forbidden_escapes()
    local violations = {}

    for _, pathname in ipairs(module_files()) do
        for _, v in ipairs(find_forbidden_escapes(read_file(ROOT .. pathname))) do
            violations[#violations + 1] =
                pathname .. ':' .. v.line .. ': ' .. v.escape
        end
    end

    assert.equal(violations, {})
end

function testcase.modules_start_with_license_header()
    local failures = {}

    for _, pathname in ipairs(module_files()) do
        local src = read_file(ROOT .. pathname)
        local first, second = match(src, '^([^\n]*)\n([^\n]*)\n')
        local ok = first == '--' and second ~= nil and
                       find(second,
                            '^%-%- Copyright %(C%) %d%d%d%d Masatoshi Fukunaga$') ~=
                       nil and find(src,
                                    '-- Permission is hereby granted, free of charge, to any person obtaining a copy',
                                    1, true) ~= nil and
                       find(src, '-- THE SOFTWARE.', 1, true) ~= nil
        if not ok then
            failures[#failures + 1] = pathname
        end
    end

    assert.equal(failures, {})
end
