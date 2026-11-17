return {
    extends = 'child',
    ['++tokens'] = {
        shebang = '"#" [^\\n]*',
    },
    ['+leading'] = {
        'shebang',
    },
    ['+skip'] = {
        'shebang',
    },
}
