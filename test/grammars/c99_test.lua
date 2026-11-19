local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local COMPILED

local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')
local without_hook = shared.without_hook

local function compiled()
    if not COMPILED then
        local diagnostics
        COMPILED, diagnostics = shared.compile('lexogram:c99')
        assert.equal(diagnostics, {})
    end
    return COMPILED
end

local function parse(source)
    local result, err = lexogram.parse(compiled(), source)
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

-- the translation unit of a source (after a leading directive)
local function unit(source)
    for _, node in ipairs(events.tree(parse(source))) do
        if node.name == 'translation_unit' then
            return node
        end
    end
end

-- the lines of the external declarations of a source
local function externals(source)
    local out = {}
    for _, node in ipairs(unit(source).children) do
        if node.name == 'external_declaration' then
            out[#out + 1] = sx(node.children[1])
        end
    end
    return out
end

-- the lines of the block items of a function body
local function items(body)
    local u = unit('void f(void) {\n' .. body .. '\n}')
    local out = {}
    for _, node in ipairs(u.children[1].children[1].children) do
        if node.name == 'compound_statement' then
            for _, item in ipairs(node.children) do
                if item.name == 'block_item' then
                    out[#out + 1] = sx(item.children[1])
                end
            end
        end
    end
    return out
end

-- the line of the right side of x = <expression>;
local function expression(source)
    local line = items('x = ' .. source .. ';')[1]
    return assert(line:match('^statement%(expression_statement%(expression%(' ..
                                 'assignment_expression%(' ..
                                 'postfix_expression%(x%) ' ..
                                 'assignment_operator%(=%) (.*)%)%) ;%)%)$'))
end

function testcase.grammar_compiles_with_the_documented_rule_names()
    local names = {}
    for _, kind in ipairs(compiled().kinds) do
        if kind.category == 'rule' then
            names[#names + 1] = kind.name
        end
    end
    table.sort(names)

    -- rule names are a public contract with consumers
    assert.equal(names, {
        'abstract_declarator',
        'argument_expression_list',
        'assignment_expression',
        'assignment_operator',
        'binary_operator',
        'block_item',
        'cast_expression',
        'compound_literal',
        'compound_statement',
        'conditional',
        'constant_expression',
        'declaration',
        'declarator',
        'designation',
        'designator',
        'direct_abstract_declarator',
        'direct_declarator',
        'enum_specifier',
        'enumerator',
        'expression',
        'expression_statement',
        'external_declaration',
        'function_definition',
        'function_specifier',
        'function_suffix',
        'init_declarator',
        'init_declarator_list',
        'initializer',
        'initializer_list',
        'iteration_statement',
        'jump_statement',
        'labeled_statement',
        'parameter_declaration',
        'parameter_type_list',
        'pointer',
        'postfix_expression',
        'selection_statement',
        'sizeof_expression',
        'statement',
        'storage_class_specifier',
        'struct_declaration',
        'struct_declarator',
        'struct_declarator_list',
        'struct_or_union_specifier',
        'translation_unit',
        'type_name',
        'type_qualifier',
        'type_specifier',
        'typedef_name',
        'unary_operator',
    })
end

function testcase.numbers_are_preprocessing_numbers_of_the_forms_of_constants()
    for _, number in ipairs({
        '0',
        '017',
        '42',
        '0x1F',
        '1u',
        '1L',
        '1ul',
        '1LLU',
        '0x10ull',
        '1.5',
        '.5',
        '1.',
        '1e10',
        '1.5E-3f',
        '2.0L',
        '0x1.8p3',
        '0x1p-2',
        '0x.8P+1f',
    }) do
        assert.equal(expression(number),
                     'assignment_expression(postfix_expression(' .. number ..
                         '))')
    end
    -- a preprocessing number of another form is one invalid token
    for _, number in ipairs({
        '08',
        '1.2.3',
        '0x',
        '0x1p',
        '1lL',
        '1e',
        '0x1e+1',
        '1abc',
    }) do
        local err = failure('int a = ' .. number .. ';')
        assert.equal(err.code, 'invalid_token')
        assert.equal(err.pos, 9)
        assert.equal(err.message, 'invalid number')
    end
end

function testcase.characters_and_strings_have_the_escapes_of_c99()
    for _, s in ipairs({
        [['a']],
        [['\n']],
        [['\'']],
        [['\x41']],
        [['\101']],
        [['é']],
        [[L'b']],
        [['ab']],
        [["a\tb\"\\"]],
        [[L"wide"]],
        [["\?"]],
    }) do
        assert.equal(expression(s),
                     'assignment_expression(postfix_expression(' .. s .. '))')
    end
    -- a line splice inside a string, and adjacent strings
    assert.equal(expression('"a\\\nb" "c"'),
                 'assignment_expression(postfix_expression("a\\\nb" "c"))')
    -- an escape that C99 does not have, and an unclosed string
    assert.equal(failure([[char *s = "\q";]]).code, 'syntax_error')
    local err = failure('char *s = "a;')
    assert.equal(err.code, 'syntax_error')
    -- at the quote, which no token starts, after the trials of the
    -- declaration
    assert.equal(err.pos, 11)
end

function testcase.directives_and_comments_are_skipped()
    assert.equal(externals(table.concat({
        '#include <stdio.h>',
        '  # define A(x) \\',
        '    ((x) + 1)',
        '#define B /* a comment that goes',
        '   on */ 1',
        '#error don\'t /* stop',
        '%:define DIGRAPH "a/*b"',
        '#',
        'int a; // a line comment \\',
        'that goes on',
        '/* a block',
        '   comment */ int b;',
    }, '\n')), {
        'declaration(type_specifier(int) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(a)))) ;)',
        'declaration(type_specifier(int) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(b)))) ;)',
    })
    -- a "#" that is not first on its line is no token
    assert.equal(failure('int a; # define X').code, 'syntax_error')
    -- an unclosed block comment
    local err = failure('int a; /* unclosed')
    assert.equal(err.code, 'unterminated_token')
    assert.equal(err.pos, 8)
end

function testcase.digraphs_are_brackets_and_braces()
    assert.equal(items('int n<:2:> = <%0%>;'), {
        'declaration(type_specifier(int) ' ..
        'init_declarator_list(init_declarator(' ..
            'declarator(direct_declarator(n <: assignment_expression(' ..
            'postfix_expression(2)) :>)) = initializer(<% initializer_list(' ..
            'initializer(assignment_expression(postfix_expression(0)))) ' ..
            '%>))) ;)',
    })
end

function testcase.declarations_tell_type_names_from_declarators()
    assert.equal(items(table.concat({
        'T x;',
        'MACRO T *x;',
        'static const T a[3], *b;',
        'x = 1;',
    }, '\n')), {
        'declaration(type_specifier(typedef_name(T)) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(x)))) ;)',
        'declaration(type_specifier(typedef_name(MACRO)) ' ..
            'type_specifier(typedef_name(T)) init_declarator_list(' ..
            'init_declarator(declarator(pointer(*) direct_declarator(x)))) ;)',
        'declaration(storage_class_specifier(static) type_qualifier(const) ' ..
            'type_specifier(typedef_name(T)) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(a [ ' ..
            'assignment_expression(postfix_expression(3)) ]))) , ' ..
            'init_declarator(declarator(pointer(*) direct_declarator(b)))) ;)',
        'statement(expression_statement(expression(assignment_expression(' ..
            'postfix_expression(x) assignment_operator(=) ' ..
            'assignment_expression(postfix_expression(1)))) ;))',
    })
    -- f(x); is a call; a * b; is a declaration, as T * b; would be
    assert.equal(items('f(x);\nT (x);\na * b;'), {
        'statement(expression_statement(expression(assignment_expression(' ..
            'postfix_expression(f ( argument_expression_list(' ..
            'assignment_expression(postfix_expression(x))) )))) ;))',
        'statement(expression_statement(expression(assignment_expression(' ..
            'postfix_expression(T ( argument_expression_list(' ..
            'assignment_expression(postfix_expression(x))) )))) ;))',
        'declaration(type_specifier(typedef_name(a)) init_declarator_list(' ..
            'init_declarator(declarator(pointer(*) direct_declarator(b)))) ;)',
    })
end

function testcase.declarators_follow_the_forms_of_c99()
    assert.equal(externals(table.concat({
        'int (*fp[2])(void);',
        'char *(*(*x)[3])(void);',
        'LUA_API int (lua_gettop) (lua_State *L);',
        'void h(int n, int m[static n], int k[const *], const T v, ...);',
    }, '\n')), {
        'declaration(type_specifier(int) ' ..
        'init_declarator_list(init_declarator(' ..
            'declarator(direct_declarator(( declarator(pointer(*) ' ..
            'direct_declarator(fp [ ' ..
            'assignment_expression(postfix_expression(2)) ' ..
            '])) ) function_suffix(( ' ..
            'parameter_type_list(parameter_declaration(' ..
            'type_specifier(void))) )))))) ;)',
        'declaration(type_specifier(char) ' ..
        'init_declarator_list(init_declarator(' ..
            'declarator(pointer(*) direct_declarator(( ' ..
            'declarator(pointer(*) ' ..
            'direct_declarator(( declarator(pointer(*) ' ..
            'direct_declarator(x)) ) [ ' ..
            'assignment_expression(postfix_expression(3)) ])) ) ' ..
            'function_suffix(( ' ..
            'parameter_type_list(parameter_declaration(type_specifier(' ..
            'void))) ' ..
            ')))))) ;)',
        'declaration(type_specifier(typedef_name(LUA_API)) ' ..
        'type_specifier(int) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(( ' ..
            'declarator(direct_declarator(lua_gettop)) ) function_suffix(( ' ..
            'parameter_type_list(parameter_declaration(type_specifier(' ..
            'typedef_name(lua_State)) declarator(pointer(*) ' ..
            'direct_declarator(L)))) ' ..
            ')))))) ;)',
        'declaration(type_specifier(void) ' ..
        'init_declarator_list(init_declarator(' ..
            'declarator(direct_declarator(h function_suffix(( ' ..
            'parameter_type_list(' ..
            'parameter_declaration(type_specifier(int) declarator(' ..
            'direct_declarator(n))) , ' ..
            'parameter_declaration(type_specifier(int) ' ..
            'declarator(direct_declarator(m [ static assignment_expression(' ..
            'postfix_expression(n)) ]))) , parameter_declaration(' ..
            'type_specifier(int) declarator(direct_declarator(k [ ' ..
            'type_qualifier(const) * ]))) , parameter_declaration(' ..
            'type_qualifier(const) type_specifier(typedef_name(T)) ' ..
            'declarator(' ..
            'direct_declarator(v))) , ...) )))))) ;)',
    })
    -- a function returns no function, and an identifier in parentheses
    -- needs a suffix
    assert.equal(failure('int f(void)(void);').code, 'syntax_error')
    assert.equal(failure('int (x);').code, 'syntax_error')
end

function testcase.structs_unions_enums_and_initializers()
    assert.equal(externals(table.concat({
        'struct S { int a; unsigned b : 3; int : 0; } s;',
        'enum E { A, B = 2, };',
        'int a[2][3] = { [0][1] = 1, { 2 } };',
        'S s = { .a = 1, .b.c = 2, };',
    }, '\n')), {
        'declaration(type_specifier(struct_or_union_specifier(struct S { ' ..
            'struct_declaration(type_specifier(int) struct_declarator_list(' ..
            'struct_declarator(declarator(direct_declarator(a)))) ;) ' ..
            'struct_declaration(type_specifier(unsigned) ' ..
            'struct_declarator_list(' ..
            'struct_declarator(declarator(direct_declarator(b)) : ' ..
            'constant_expression(postfix_expression(3)))) ;) ' ..
            'struct_declaration(type_specifier(int) struct_declarator_list(' ..
            'struct_declarator(: ' ..
            'constant_expression(postfix_expression(0)))) ;) ' ..
            '})) init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(s)))) ;)',
        'declaration(type_specifier(enum_specifier(enum E { enumerator(A) , ' ..
            'enumerator(B = constant_expression(postfix_expression(2))) , ' ..
            '})) ;)',
        'declaration(type_specifier(int) ' ..
        'init_declarator_list(init_declarator(' ..
            'declarator(direct_declarator(a [ assignment_expression(' ..
            'postfix_expression(2)) ] [ assignment_expression(' ..
            'postfix_expression(3)) ])) = initializer({ initializer_list(' ..
            'designation(designator([ ' ..
            'constant_expression(postfix_expression(0)) ' ..
            ']) designator([ constant_expression(postfix_expression(1)) ]) ' ..
            '=) ' ..
            'initializer(assignment_expression(postfix_expression(1))) , ' ..
            'initializer({ ' ..
            'initializer_list(initializer(assignment_expression(' ..
            'postfix_expression(2)))) })) }))) ;)',
        'declaration(type_specifier(typedef_name(S)) init_declarator_list(' ..
            'init_declarator(declarator(direct_declarator(s)) = ' ..
            'initializer({ ' ..
            'initializer_list(designation(designator(. a) =) initializer(' ..
            'assignment_expression(postfix_expression(1))) , designation(' ..
            'designator(. b) designator(. c) =) initializer(' ..
            'assignment_expression(postfix_expression(2)))) , }))) ;)',
    })
    -- a member needs a declarator in C99
    assert.equal(failure('struct S { int; };').code, 'syntax_error')
end

function testcase.function_definitions()
    assert.equal(externals(table.concat({
        'static inline int f(int a, T *b) { return a; }',
        'int g(a) int a; { }',
    }, '\n')), {
        'function_definition(storage_class_specifier(static) ' ..
            'function_specifier(inline) type_specifier(int) declarator(' ..
            'direct_declarator(f function_suffix(( parameter_type_list(' ..
            'parameter_declaration(type_specifier(int) declarator(' ..
            'direct_declarator(a))) , parameter_declaration(type_specifier(' ..
            'typedef_name(T)) declarator(pointer(*) direct_declarator(b)))) ' ..
            ')))) ' ..
            'compound_statement({ ' ..
            'block_item(statement(jump_statement(return ' ..
            'expression(assignment_expression(postfix_expression(a))) ;))) }))',
        -- an identifier list is read as parameters of type names
        'function_definition(type_specifier(int) ' ..
        'declarator(direct_declarator(' ..
            'g function_suffix(( parameter_type_list(parameter_declaration(' ..
            'type_specifier(typedef_name(a)))) )))) ' ..
            'declaration(type_specifier(' ..
            'int) init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(a)))) ;) compound_statement({ }))',
    })
end

function testcase.statements_have_the_rules_of_c99()
    assert.equal(items(table.concat({
        'l: x++;',
        'switch (x) { case 1: break; default: ; }',
        'if (a) if (b) x; else y;',
        'do x--; while (x);',
        'for (int i = 0; i < n; i++) continue;',
        'for (;;) goto l;',
        'return;',
    }, '\n')), {
        'statement(labeled_statement(l : statement(expression_statement(' ..
            'expression(assignment_expression(postfix_expression(x ++))) ;))))',
        'statement(selection_statement(switch ( expression(' ..
            'assignment_expression(postfix_expression(x))) ) statement(' ..
            'compound_statement({ ' ..
            'block_item(statement(labeled_statement(case ' ..
            'constant_expression(postfix_expression(1)) : statement(' ..
            'jump_statement(break ;))))) ' ..
            'block_item(statement(labeled_statement(' ..
            'default : statement(expression_statement(;))))) }))))',
        -- an else belongs to the nearest if
        'statement(selection_statement(if ( ' ..
        'expression(assignment_expression(' ..
            'postfix_expression(a))) ) statement(selection_statement(if ( ' ..
            'expression(assignment_expression(postfix_expression(b))) ) ' ..
            'statement(expression_statement(expression(' ..
            'assignment_expression(' ..
            'postfix_expression(x))) ;)) else ' ..
            'statement(expression_statement(' ..
            'expression(assignment_expression(postfix_expression(y))) ;))))))',
        'statement(iteration_statement(do statement(expression_statement(' ..
            'expression(assignment_expression(postfix_expression(x --))) ' ..
            ';)) ' ..
            'while ( ' ..
            'expression(assignment_expression(postfix_expression(x))) ) ' ..
            ';))',
        'statement(iteration_statement(for ( ' ..
        'declaration(type_specifier(int) ' ..
            'init_declarator_list(init_declarator(declarator(' ..
            'direct_declarator(' ..
            'i)) = ' ..
            'initializer(assignment_expression(postfix_expression(0))))) ;) ' ..
            'expression(assignment_expression(postfix_expression(i) ' ..
            'binary_operator(<) postfix_expression(n))) ; expression(' ..
            'assignment_expression(postfix_expression(i ++))) ) statement(' ..
            'jump_statement(continue ;))))',
        'statement(iteration_statement(for ( ; ; ) statement(jump_statement(' ..
            'goto l ;))))',
        'statement(jump_statement(return ;))',
    })
end

function testcase.expressions_list_terms_and_operators_flat()
    assert.equal(expression('-a * b + c'),
                 'assignment_expression(unary_operator(-) ' ..
                 'postfix_expression(a) ' ..
                     'binary_operator(*) postfix_expression(b) ' ..
                     'binary_operator(+) ' ..
                     'postfix_expression(c))')
    assert.equal(expression('a ? b : c'),
                 'assignment_expression(postfix_expression(a) conditional(? ' ..
                     'expression(assignment_expression(postfix_expression(' ..
                     'b))) : ' ..
                     'assignment_expression(postfix_expression(c))))')
    assert.equal(expression('++a + b--'),
                 'assignment_expression(++ postfix_expression(a) ' ..
                     'binary_operator(+) postfix_expression(b --))')
    assert.equal(expression('p->a[1].b(2)'),
                 'assignment_expression(postfix_expression(p -> a [ ' ..
                 'expression(' ..
                     'assignment_expression(postfix_expression(1))) ] . b ( ' ..
                     'argument_expression_list(assignment_expression(' ..
                     'postfix_expression(2))) )))')
    assert.equal(expression('(S){ 1 }.a'),
                 'assignment_expression(postfix_expression(compound_literal(' ..
                 '( ' ..
                     'type_name(type_specifier(typedef_name(S))) ) { ' ..
                     'initializer_list(initializer(assignment_expression(' ..
                     'postfix_expression(1)))) }) . a))')
end

function testcase.casts_and_sizeof_are_tried_with_type_names_first()
    assert.equal(expression('(T)a'),
                 'assignment_expression(cast_expression(( type_name(' ..
                     'type_specifier(typedef_name(T))) ) ' ..
                     'postfix_expression(a)))')
    -- (a) - b is a cast too; (a + b) is no type name
    assert.equal(expression('(a) - b'),
                 'assignment_expression(cast_expression(( type_name(' ..
                     'type_specifier(typedef_name(a))) ) unary_operator(-) ' ..
                     'postfix_expression(b)))')
    assert.equal(expression('(a + b)'),
                 'assignment_expression(postfix_expression(( expression(' ..
                     'assignment_expression(postfix_expression(a) ' ..
                     'binary_operator(+) postfix_expression(b))) )))')
    assert.equal(expression('(const char *)s'),
                 'assignment_expression(cast_expression(( type_name(' ..
                     'type_qualifier(const) type_specifier(char) ' ..
                     'abstract_declarator(pointer(*))) ) ' ..
                     'postfix_expression(s)))')
    assert.equal(expression('sizeof(x) + sizeof x + sizeof(*p)'),
                 'assignment_expression(sizeof_expression(sizeof ( ' ..
                 'type_name(' ..
                     'type_specifier(typedef_name(x))) )) ' ..
                     'binary_operator(+) ' ..
                     'sizeof_expression(sizeof postfix_expression(x)) ' ..
                     'binary_operator(+) sizeof_expression(sizeof ' ..
                     'postfix_expression(( expression(assignment_expression(' ..
                     'unary_operator(*) postfix_expression(p))) ))))')
end

function testcase.syntax_errors_stop_the_analysis()
    for _, source in ipairs({
        'int x',
        'int x = ;',
        'void f(void) { return }',
        'void f(void) { if x; }',
        'int f(int a,);',
    }) do
        assert.equal(failure(source).code, 'syntax_error')
    end
end

function testcase.sample_parses()
    -- a sample of the forms of C99, accepted by clang -std=c99 -pedantic
    local f = assert(io.open('c99/sample.c', 'rb'))
    local source = f:read('*a')
    f:close()
    -- parsing takes long under luacov's line hook
    local result = without_hook(parse, source)
    -- the events cover the whole source
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
end
