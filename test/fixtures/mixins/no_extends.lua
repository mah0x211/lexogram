return {
    lexogram = '2026.11.15.1',
    name = 'no_extends',
    version = '1.0.0',
    embeds = {
        'shebang',
    },
    start = 'chunk',
    tokens = {
        name = '[a-z]+',
    },
    rules = {
        chunk = 'name*',
    },
}
