-- the difference of the grammar itself comes after the mixins
return {
    extends = 'base',
    embeds = {
        'shebang',
    },
    name = 'own',
    version = '1.0.0',
    tokens = {
        ['=shebang'] = '"#!" [^\\n]*',
    },
    ['-skip'] = {
        'shebang',
    },
}
