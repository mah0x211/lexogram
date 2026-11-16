local a = import('counted')
local b = import('counted')
a.list[1] = 'changed'
a.added = true
return {
    a = a,
    b = b,
}
