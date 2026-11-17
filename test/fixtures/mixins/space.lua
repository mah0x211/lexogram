-- adds what the base already has
return {
    mixin = true,
    lexogram = '2026.11.15.1',
    name = 'space',
    version = '1.0.0',
    ['++tokens'] = {
        space = '" "+',
    },
    ['+skip'] = {
        'space',
    },
}
