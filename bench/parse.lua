-- Analyzer benchmark: parses the whole input with lexogram.parse and
-- reports the number of events. See bench/common.lua for the usage and the
-- input. The default grammar accepts any sequence of tokens, so this
-- measures the analyzer loop and the event array on every token.
local common = dofile((arg[0]:match('^(.-)[^/\\]*$') or '') .. 'common.lua')

local s = common.setup(arg)
local parse, compiled, input = s.lexogram.parse, s.compiled, s.input

local seconds, count = common.best(function()
    local result, err = parse(compiled, input)
    if not result then
        common.fail(
            string.format('%d:%d: %s', err.line, err.column, err.message))
    end
    return result.count
end)

local mb = common.report(s)
print(string.format('events    : %d', count))
print(string.format('best of %d: %.3f s', common.RUNS, seconds))
print(string.format('throughput: %.2f MB/s, %.0f events/s', mb / seconds,
                    count / seconds))
