-- extends sub/inner, named from this file
return {
    mixin = true,
    extends = 'inner',
    lexogram = '2026.11.15.1',
    name = 'outer',
    version = '1.0.0',
    rules = {
        ['=chunk'] = 'other*',
    },
}
