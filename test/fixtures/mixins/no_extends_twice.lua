-- a grammar without extends that embeds shebang twice
return {
    lexogram = '2026.11.15.1',
    name = 'no_extends_twice',
    version = '1.0.0',
    embeds = {
        'bom',
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
