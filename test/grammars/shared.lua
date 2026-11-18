-- Shared helpers of the tests that use full grammars (the built-in Lua
-- grammars and the grammars of bench/grammars). Loaded with dofile from the
-- directory of the tests; every file that loads it gets the same table, so
-- that what it keeps lasts for the whole test run.
--
-- Under luacov's line hook, checking and compiling a full grammar takes
-- far too long: the first lexogram.load of a built-in grammar checks it
-- and every grammar it extends (each built-in module checks its grammar
-- when it is required), and lexogram.compile checks the grammar again
-- before it compiles it. These run without the hook here. They are run on
-- the small grammars of the unit tests under the hook, so the coverage
-- does not depend on them.
local lexogram = require('lexogram')
local unpack = unpack or table.unpack

-- the key under which the helpers are kept for the files that load them
-- later
local KEY = 'lexogram test helpers: test/grammars/shared.lua'
if package.loaded[KEY] then
    return package.loaded[KEY]
end

--- pack returns the arguments as an array with their number as n.
--- @return table
local function pack(...)
    return {
        n = select('#', ...),
        ...,
    }
end

--- without_hook returns the results of fn(...) run with the coverage hook
--- removed; an error of fn is raised again.
--- @param fn function
--- @return any ...
local function without_hook(fn, ...)
    local hook, mask, count = debug.gethook()
    debug.sethook()
    -- n counts the results that are nil at the end too
    local res = pack(pcall(fn, ...))
    if hook then
        debug.sethook(hook, mask, count)
    end
    if not res[1] then
        error(res[2], 0)
    end
    return unpack(res, 2, res.n)
end

--- copy returns a deep copy of v (shared references are kept shared).
--- @param v any
--- @param seen table
--- @return any
local function copy(v, seen)
    if type(v) ~= 'table' then
        return v
    elseif seen[v] then
        return seen[v]
    end
    local out = {}
    seen[v] = out
    for k, val in next, v do
        out[copy(k, seen)] = copy(val, seen)
    end
    return out
end

--- load returns the results of lexogram.load(name) run without the hook.
--- @param name string a built-in grammar such as 'lexogram:lua51', or a
--- pathname
--- @return table? grammar
--- @return string? err
--- @return table? warnings
local function load(name)
    return without_hook(lexogram.load, name)
end

-- name -> { compiled, diagnostics } of the grammars compiled so far
local COMPILED = {}

--- compile returns the result of lexogram.compile of the grammar that
--- lexogram.load(name) returns, run without the hook. name is the key of
--- the result as given (a pathname is relative to the working directory of
--- the test that gives it, so the same one is always given the same way).
--- A grammar is compiled once for the whole test run, since compile gives
--- the same result for the same grammar (see
--- compile_is_deterministic_plain_data in test/compile_test.lua); each call
--- returns a new copy of the result, so that no test sees what another one
--- changed.
--- @param name string
--- @return table? compiled
--- @return table diagnostics
local function compile(name)
    local entry = COMPILED[name]
    if not entry then
        local grammar = assert(load(name))
        local compiled, diagnostics = without_hook(lexogram.compile, grammar)
        entry = {
            compiled,
            diagnostics,
        }
        COMPILED[name] = entry
    end
    return copy(entry[1], {}), copy(entry[2], {})
end

local helpers = {
    without_hook = without_hook,
    load = load,
    compile = compile,
}
package.loaded[KEY] = helpers
return helpers
