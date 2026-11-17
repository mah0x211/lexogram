-- a mixin: a difference without a base
return {
    mixin = true,
    lexogram = '2026.11.15.1',
    name = 'shebang',
    version = '1.0.0',
    ['++tokens'] = {
        shebang = '"#" [^\\n]*',
    },
    ['+leading'] = {
        'shebang',
    },
    ['+skip'] = {
        'shebang',
    },
}
