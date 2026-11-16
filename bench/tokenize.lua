-- Tokenizer benchmark: tokenizes the whole input from position 1 to the
-- end with lexogram.tokenize. See bench/common.lua for the usage and the
-- input.
local common = dofile((arg[0]:match('^(.-)[^/\\]*$') or '') .. 'common.lua')

local s = common.setup(arg)
local tokenize, compiled, input = s.lexogram.tokenize, s.compiled, s.input

local seconds, count, invalid = common.best(function()
    local pos, n, bad = 1, 0, 0
    local len = #input
    while pos <= len do
        local kind, stop = tokenize(compiled, input, pos)
        if kind == 1 then
            bad = bad + 1
        end
        n = n + 1
        pos = stop
    end
    return n, bad
end)

local mb = common.report(s)
print(string.format('tokens    : %d (INVALID: %d)', count, invalid))
print(string.format('best of %d: %.3f s', common.RUNS, seconds))
print(string.format('throughput: %.2f MB/s, %.0f tokens/s', mb / seconds,
                    count / seconds))
