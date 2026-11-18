local f = x -> x + 1
local g = |a, b| -> a + b
local h = || -> do return 1 end
local k = |...| -> ...
f(x -> x, y)
