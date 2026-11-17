return {
    lexogram = '2026.11.15.1',
    name = 'base',
    version = '1.0.0',
    start = 'chunk',
    tokens = {
        name = '[a-z]+',
        space = '[ \\n]+',
    },
    skip = {
        'space',
    },
    rules = {
        chunk = 'name*',
    },
}
