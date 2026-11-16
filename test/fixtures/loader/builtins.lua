local keys = {}
for k, v in pairs({
    a = 1,
}) do
    keys[k] = v
end
local list = {}
for i, v in ipairs({
    'x',
    'y',
}) do
    list[i] = v
end
return {
    keys = keys,
    list = list,
    imported = import('plain'),
    hyphen = import('with-hyphen_1'),
}
