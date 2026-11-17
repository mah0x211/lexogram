-- a mixin that extends a mixin
return {
    mixin = true,
    extends = 'shebang',
    lexogram = '2026.11.15.1',
    name = 'bom',
    version = '1.0.0',
    tokens = {
        ['=shebang'] = '"\\xEF\\xBB\\xBF" ("#" [^\\n]*)? | "#" [^\\n]*',
    },
}
