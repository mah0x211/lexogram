local global = 1
global = 2
global.x, global[1] = global, global
global(1) global "s" global {} global:m()
function global() end
::global:: goto global
