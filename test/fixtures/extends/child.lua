return {
    extends = 'base',
    ['++tokens'] = {
        number = 'DIGIT+',
    },
    rules = {
        ['=chunk'] = '(name | number)*',
    },
}
