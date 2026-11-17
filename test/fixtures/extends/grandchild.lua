return {
    extends = 'child',
    name = 'grandchild',
    version = '1.0.0',
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
