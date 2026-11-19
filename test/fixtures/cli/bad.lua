-- a rule that refers to an undefined token
return {
    lexogram = '2026.11.15.1',
    name = 'bad',
    version = '1.0.0',
    start = 'chunk',
    tokens = {
        word = '[a-z]+',
    },
    rules = {
        chunk = 'word none',
    },
}
