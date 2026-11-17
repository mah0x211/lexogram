return {
    lexogram = '2026.11.15.1',
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
