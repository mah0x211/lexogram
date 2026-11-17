local b = import('base')
return {
    extends = 'base',
    name = b.name,
    version = b.version,
    ['=start'] = b.start,
}
