local shared = {
    value = 1,
}
local cyclic = {}
cyclic.self = cyclic
local key = {
    name = 'key',
}
return {
    x = shared,
    y = shared,
    cyclic = cyclic,
    [key] = key,
}
