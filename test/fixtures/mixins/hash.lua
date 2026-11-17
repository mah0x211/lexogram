-- replaces what an earlier mixin added
return {
    mixin = true,
    lexogram = '2026.11.15.1',
    name = 'hash',
    version = '1.0.0',
    tokens = {
        ['=shebang'] = '"#!" [^\\n]*',
    },
}
