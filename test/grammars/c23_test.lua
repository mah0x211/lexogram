local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')
local without_hook = shared.without_hook

local function compiled(name)
    local c, diagnostics = shared.compile(name or 'lexogram:c23')
    assert.equal(diagnostics, {})
    return c
end

local function parse(source, name)
    local result, err = lexogram.parse(compiled(name), source)
    assert(result,
           err and (err.line .. ':' .. err.column .. ': ' .. err.message))
    return result
end

-- the error of a source that does not parse
local function failure(source)
    local result, err = lexogram.parse(compiled(), source)
    assert.is_nil(result)
    return err
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
    local out = {}
    for item in unit(source):gmatch('external_declaration(%b())') do
        out[#out + 1] = item:sub(2, -2)
    end
    return out
end

-- the lines of the block items of a function body
local function items(body)
    local out = {}
    local line = externals('void f(void) {\n' .. body .. '\n}')[1]
    for item in line:gmatch('block_item(%b())') do
        out[#out + 1] = item:sub(2, -2)
    end
    return out
end

-- the line of the right side of x = <expression>; in a function body
local function expression(source)
    local line = items('x = ' .. source .. ';')[1]
    return assert(line:match('assignment_operator%(=%) (.*)%)%) ;%)%)$'))
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

function testcase.grammar_extends_c11_with_the_rules_of_c23()
    local grammar = assert(shared.load('lexogram:c23'))
    assert.equal(grammar.name, 'c23')
    local c11, c23 = {}, {}
    for _, name in ipairs(rule_names(compiled('lexogram:c11'))) do
        c11[name] = true
    end
    local added = {}
    for _, name in ipairs(rule_names(compiled())) do
        c23[name] = true
        if not c11[name] then
            added[#added + 1] = name
        end
    end
    local removed = {}
    for _, name in ipairs(rule_names(compiled('lexogram:c11'))) do
        if not c23[name] then
            removed[#removed + 1] = name
        end
    end
    -- rule names are a public contract with consumers
    assert.equal(added, {
        'braced_initializer',
        'enum_type_specifier',
        'label',
        'member_declaration',
        'member_declarator',
        'member_declarator_list',
        'primary_block',
        'typeof_specifier',
        'unlabeled_statement',
    })
    assert.equal(removed, {
        'struct_declaration',
        'struct_declarator',
        'struct_declarator_list',
    })
end

function testcase.numbers_have_the_forms_of_c23()
    for _, number in ipairs({
        "1'000",
        "0b1'01",
        '0B11',
        "0x1'F",
        "07'7",
        '10wb',
        '10uwb',
        '10WBU',
        "1'000.5e1'0",
        '1.5df',
        '1e3DL',
        '2.0dd',
    }) do
        assert.equal(expression(number),
                     'assignment_expression(postfix_expression(' .. number ..
                         '))')
    end
    for _, number in ipairs({
        '0b2',
        '2dd',
        '1wbl',
    }) do
        local err = failure('int a = ' .. number .. ';')
        assert.equal(err.code, 'invalid_token')
        assert.equal(err.message, 'invalid number')
    end
end

function testcase.keywords_constants_and_names_of_c23()
    assert.equal(expression('true + false'),
                 'assignment_expression(postfix_expression(true) ' ..
                     'binary_operator(+) postfix_expression(false))')
    assert.equal(expression('nullptr'),
                 'assignment_expression(postfix_expression(nullptr))')
    assert.equal(expression("u8'a'"),
                 "assignment_expression(postfix_expression(u8'a'))")
    -- a byte from 80 on is a character of a name
    assert.equal(expression('caf\195\169'),
                 'assignment_expression(postfix_expression(caf\195\169))')
    assert.equal(externals(table.concat({
        'constexpr int a = 1;',
        'thread_local bool b;',
        'alignas(8) char c;',
        '_BitInt(12) d;',
    }, '\n')), {
        'declaration(storage_class_specifier(constexpr) ' ..
            'type_specifier(int) init_declarator_list(init_declarator(' ..
            'declarator(direct_declarator(a)) = initializer(' ..
            'assignment_expression(postfix_expression(1))))) ;)',
        'declaration(storage_class_specifier(thread_local) ' ..
            'type_specifier(bool) init_declarator_list(init_declarator(' ..
            'declarator(direct_declarator(b)))) ;)',
        'declaration(alignment_specifier(alignas ( constant_expression(' ..
            'postfix_expression(8)) )) type_specifier(char) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(c)))) ;)',
        'declaration(type_specifier(_BitInt ( constant_expression(' ..
            'postfix_expression(12)) )) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(d)))) ;)',
    })
end

function testcase.typeof_tries_the_expression_first()
    assert.equal(externals('typeof(a[0]) x;\ntypeof_unqual(const int) y;'), {
        'declaration(type_specifier(typeof_specifier(typeof ( expression(' ..
            'assignment_expression(postfix_expression(a [ expression(' ..
            'assignment_expression(postfix_expression(0))) ]))) ))) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(x)))) ;)',
        'declaration(type_specifier(typeof_specifier(typeof_unqual ( ' ..
            'type_name(type_qualifier(const) type_specifier(int)) ))) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(y)))) ;)',
    })
end

function testcase.members_enumerations_initializers_and_parameters()
    assert.equal(externals(table.concat({
        'struct S { int a; };',
        'enum E : unsigned char { A };',
        'int e[2] = {};',
        'void v(...);',
        'static_assert(1);',
    }, '\n')), {
        'declaration(type_specifier(struct_or_union_specifier(struct S { ' ..
            'member_declaration(type_specifier(int) member_declarator_list(' ..
            'member_declarator(declarator(direct_declarator(a)))) ;) })) ;)',
        'declaration(type_specifier(enum_specifier(enum E ' ..
            'enum_type_specifier(: type_specifier(unsigned) ' ..
            'type_specifier(char)) { enumerator(A) })) ;)',
        'declaration(type_specifier(int) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(e [ ' ..
            'assignment_expression(postfix_expression(2)) ])) = ' ..
            'initializer(braced_initializer({ })))) ;)',
        'declaration(type_specifier(void) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(v function_suffix(' ..
            '( parameter_type_list(...) )))))) ;)',
        'declaration(static_assert_declaration(static_assert ( ' ..
            'constant_expression(postfix_expression(1)) ) ;))',
    })
    assert.equal(expression('(static int[]){ 1 }'),
                 'assignment_expression(postfix_expression(' ..
                     'compound_literal(( storage_class_specifier(static) ' ..
                     'type_name(type_specifier(int) abstract_declarator(' ..
                     'direct_abstract_declarator([ ]))) ) ' ..
                     'braced_initializer({ initializer_list(initializer(' ..
                     'assignment_expression(postfix_expression(1)))) }))))')
    -- C23 has no identifier lists
    assert.equal(failure('int g(a) int a; { }').code, 'syntax_error')
end

function testcase.labels_may_end_a_block_and_precede_declarations()
    assert.equal(items('l: x = 1; m: int y; n:'), {
        'label(l :)',
        'unlabeled_statement(expression_statement(expression(' ..
            'assignment_expression(postfix_expression(x) ' ..
            'assignment_operator(=) assignment_expression(' ..
            'postfix_expression(1)))) ;))',
        'label(m :)',
        'declaration(type_specifier(int) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(y)))) ;)',
        'label(n :)',
    })
    -- the statement of an if may be labeled
    assert.equal(items('if (x) l: y;')[1],
                 'unlabeled_statement(primary_block(selection_statement(' ..
                     'if ( expression(assignment_expression(' ..
                     'postfix_expression(x))) ) statement(labeled_statement(' ..
                     'label(l :) statement(unlabeled_statement(' ..
                     'expression_statement(expression(assignment_expression(' ..
                     'postfix_expression(y))) ;))))))))')
end

-- the source of a sample file
local function sample(name)
    local f = assert(io.open(name, 'rb'))
    local source = f:read('*a')
    f:close()
    return source
end

function testcase.samples_parse()
    -- a sample of the forms of C23, accepted by clang -std=c23 -pedantic
    local source = sample('c23/sample.c')
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
    -- the sample of C11 parses, and c23_macro reads that of C23 as c23
    without_hook(parse, sample('c11/sample.c'))
    assert.equal(without_hook(unit, source, 'lexogram:c23_macro'),
                 without_hook(unit, source))
end

function testcase.c23_macro_reads_the_forms_of_macros()
    assert.equal(unit('struct S { CommonHeader; };\nchar *s = Q("a") "b";',
                      'lexogram:c23_macro'),
                 'translation_unit(external_declaration(declaration(' ..
                     'type_specifier(struct_or_union_specifier(struct S { ' ..
                     'member_declaration(type_specifier(typedef_name(' ..
                     'CommonHeader)) ;) })) ;)) external_declaration(' ..
                     'declaration(type_specifier(char) init_declarator_list(' ..
                     'init_declarator(declarator(pointer(*) ' ..
                     'direct_declarator(s)) = initializer(' ..
                     'assignment_expression(postfix_expression(Q ( ' ..
                     'argument_expression_list(assignment_expression(' ..
                     'postfix_expression("a"))) ) "b"))))) ;)))')
end
