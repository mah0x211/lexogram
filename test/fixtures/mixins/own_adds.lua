-- the difference of the grammar itself is checked as for extends
return {
    extends = 'base',
    embeds = {
        'shebang',
    },
    name = 'own_adds',
    version = '1.0.0',
    ['+leading'] = {
        'shebang',
    },
}
