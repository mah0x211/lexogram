-- words separated by spaces, with an unused rule (a warning)
return {
    lexogram = '2026.11.15.1',
    name = 'words',
    version = '1.0.0',
    start = 'chunk',
    tokens = {
        word = '[a-z]+',
        space = '[ \\n]+',
    },
    symbols = {
        ',',
    },
    skip = {
        'space',
    },
    rules = {
        chunk = 'word ("," word)*',
        unused = 'word',
    },
}
