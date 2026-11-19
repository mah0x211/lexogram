-- a grammar without extends whose mixin removes what it does not have
return {
    lexogram = '2026.11.15.1',
    name = 'no_extends_error',
    version = '1.0.0',
    embeds = {
        'removes',
    },
    start = 'chunk',
    tokens = {
        name = '[a-z]+',
    },
    rules = {
        chunk = 'name*',
    },
}
