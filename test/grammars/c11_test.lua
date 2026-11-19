local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')
local without_hook = shared.without_hook

local function compiled(name)
    local c, diagnostics = shared.compile(name or 'lexogram:c11')
    assert.equal(diagnostics, {})
    return c
end

local function parse(source, name)
    local result, err = lexogram.parse(compiled(name), source)
    assert(result,
           err and (err.line .. ':' .. err.column .. ': ' .. err.message))
    return result
end

local SKIPPED = {
    space = true,
    line_comment = true,
    block_comment = true,
    directive = true,
    first_directive = true,
}

-- a node as one line: rule(children) and the text of tokens, without the
-- skipped tokens
local function sx(node)
    if node.children then
        local parts = {}
        for _, child in ipairs(node.children) do
            local s = sx(child)
            if s then
                parts[#parts + 1] = s
            end
        end
        return node.name .. '(' .. table.concat(parts, ' ') .. ')'
    elseif not SKIPPED[node.name] then
        return node.text
    end
end

-- the translation unit of a source as one line
local function unit(source, name)
    for _, node in ipairs(events.tree(parse(source, name))) do
        if node.name == 'translation_unit' then
            return sx(node)
        end
    end
end

-- the lines of the external declarations of a source
local function externals(source)
    local line = unit(source)
    local out = {}
    for item in line:gmatch('external_declaration(%b())') do
        out[#out + 1] = item:sub(2, -2)
    end
    return out
end

-- the line of the right side of x = <expression>; in a function body
local function expression(source)
    local line = externals('void f(void) { x = ' .. source .. '; }')[1]
    return assert(line:match('assignment_operator%(=%) (.*)%)%) ;%)%)%) ' ..
                                 '}%)%)$'))
end

-- the names of the rules with events of a compiled grammar
local function rule_names(c)
    local names = {}
    for _, kind in ipairs(c.kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    table.sort(names)
    return names
end

function testcase.grammar_extends_c99_with_the_rules_of_c11()
    local grammar = assert(shared.load('lexogram:c11'))
    assert.equal(grammar.name, 'c11')
    local added = {}
    local c99 = {}
    for _, name in ipairs(rule_names(compiled('lexogram:c99'))) do
        c99[name] = true
    end
    for _, name in ipairs(rule_names(compiled())) do
        if not c99[name] then
            added[#added + 1] = name
        end
    end
    -- rule names are a public contract with consumers
    assert.equal(added, {
        'alignment_specifier',
        'alignof_expression',
        'atomic_type_specifier',
        'generic_association',
        'generic_selection',
        'static_assert_declaration',
    })
end

function testcase.atomic_is_a_type_specifier_before_a_parenthesis()
    assert.equal(externals(table.concat({
        '_Atomic int a;',
        '_Atomic(T) *b;',
        'int *_Atomic c;',
    }, '\n')), {
        'declaration(type_qualifier(_Atomic) type_specifier(int) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(a)))) ;)',
        'declaration(type_specifier(atomic_type_specifier(_Atomic ( ' ..
            'type_name(type_specifier(typedef_name(T))) ))) ' ..
            'init_declarator_list(init_declarator(declarator(pointer(*) ' ..
            'direct_declarator(b)))) ;)',
        'declaration(type_specifier(int) init_declarator_list(' ..
            'init_declarator(declarator(pointer(* type_qualifier(_Atomic)) ' ..
            'direct_declarator(c)))) ;)',
    })
end

function testcase.the_specifiers_of_c11()
    assert.equal(externals(table.concat({
        'static _Thread_local int n;',
        '_Alignas(16) char d;',
        '_Alignas(T) char e;',
        '_Noreturn void g(void);',
    }, '\n')), {
        'declaration(storage_class_specifier(static) ' ..
            'storage_class_specifier(_Thread_local) type_specifier(int) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(n)))) ;)',
        'declaration(alignment_specifier(_Alignas ( constant_expression(' ..
            'postfix_expression(16)) )) type_specifier(char) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(d)))) ;)',
        -- the type name is tried first
        'declaration(alignment_specifier(_Alignas ( type_name(' ..
            'type_specifier(typedef_name(T))) )) type_specifier(char) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(e)))) ;)',
        'declaration(function_specifier(_Noreturn) type_specifier(void) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(g function_suffix(( parameter_type_list(' ..
            'parameter_declaration(type_specifier(void))) )))))) ;)',
    })
end

function testcase.static_assertions_and_anonymous_members()
    assert.equal(externals(table.concat({
        '_Static_assert(1, "a" "b");',
        'struct S { union { int i; }; _Static_assert(1, "x"); };',
    }, '\n')), {
        'declaration(static_assert_declaration(_Static_assert ( ' ..
            'constant_expression(postfix_expression(1)) , "a" "b" ) ;))',
        'declaration(type_specifier(struct_or_union_specifier(struct S { ' ..
            'struct_declaration(type_specifier(struct_or_union_specifier(' ..
            'union { struct_declaration(type_specifier(int) ' ..
            'struct_declarator_list(struct_declarator(declarator(' ..
            'direct_declarator(i)))) ;) })) ;) struct_declaration(' ..
            'static_assert_declaration(_Static_assert ( constant_expression(' ..
            'postfix_expression(1)) , "x" ) ;)) })) ;)',
    })
end

function testcase.generic_selections_and_alignof()
    assert.equal(expression('_Generic(a, int: 1, T *: 2, default: 3)'),
                 'assignment_expression(postfix_expression(' ..
                     'generic_selection(_Generic ( assignment_expression(' ..
                     'postfix_expression(a)) , generic_association(' ..
                     'type_name(type_specifier(int)) : ' ..
                     'assignment_expression(' ..
                     'postfix_expression(1))) , generic_association(' ..
                     'type_name(type_specifier(typedef_name(T)) ' ..
                     'abstract_declarator(pointer(*))) : ' ..
                     'assignment_expression(postfix_expression(2))) , ' ..
                     'generic_association(default : assignment_expression(' ..
                     'postfix_expression(3))) ))))')
    assert.equal(expression('_Alignof(T) + 1'),
                 'assignment_expression(alignof_expression(_Alignof ( ' ..
                     'type_name(type_specifier(typedef_name(T))) )) ' ..
                     'binary_operator(+) postfix_expression(1))')
end

function testcase.characters_and_strings_have_the_prefixes_of_c11()
    for _, s in ipairs({
        [[u8"a"]],
        [[u"a"]],
        [[U"a"]],
        [[L"a"]],
        [[u'a']],
        [[U'a']],
    }) do
        assert.equal(expression(s),
                     'assignment_expression(postfix_expression(' .. s .. '))')
    end
    -- u8 is no prefix of a character constant in C11
    local result, err = lexogram.parse(compiled(), [[int c = u8'a';]])
    assert.is_nil(result)
    assert.equal(err.code, 'syntax_error')
end

-- the source of a sample file
local function sample(name)
    local f = assert(io.open(name, 'rb'))
    local source = f:read('*a')
    f:close()
    return source
end

function testcase.samples_parse()
    -- a sample of the forms of C11, accepted by clang -std=c11 -pedantic
    local source = sample('c11/sample.c')
    -- parsing takes long under luacov's line hook
    local result = without_hook(parse, source)
    local texts = {}
    local function walk(nodes)
        for _, node in ipairs(nodes) do
            if node.children then
                walk(node.children)
            else
                texts[#texts + 1] = node.text
            end
        end
    end
    walk(events.tree(result))
    assert.equal(table.concat(texts), source)
    -- the sample of C99 is read as by c99, and that of C11 as by c11 with
    -- the forms of macros
    local c99 = sample('c99/sample.c')
    assert.equal(without_hook(unit, c99),
                 without_hook(unit, c99, 'lexogram:c99'))
    assert.equal(without_hook(unit, source, 'lexogram:c11_macro'),
                 without_hook(unit, source))
end

function testcase.c11_macro_reads_the_forms_of_macros()
    assert.equal(unit('char *s = cast(char *, "a" Q "b");',
                      'lexogram:c11_macro'),
                 'translation_unit(external_declaration(declaration(' ..
                     'type_specifier(char) init_declarator_list(' ..
                     'init_declarator(declarator(pointer(*) ' ..
                     'direct_declarator(s)) = initializer(' ..
                     'assignment_expression(postfix_expression(cast ( ' ..
                     'argument_expression_list(type_name(type_specifier(' ..
                     'char) abstract_declarator(pointer(*))) , ' ..
                     'assignment_expression(postfix_expression("a" Q "b"))) ' ..
                     ')))))) ;)))')
end
