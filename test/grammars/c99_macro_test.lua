local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local events = require('lexogram.events')

local shared = dofile(debug.getinfo(1, 'S').source:match('^@(.-)[^/]*$') ..
                          'shared.lua')
local without_hook = shared.without_hook

local function compiled(name)
    local c, diagnostics = shared.compile(name or 'lexogram:c99_macro')
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

-- the line of the only external declaration of a source
local function external(source)
    for _, node in ipairs(events.tree(parse(source))[1].children) do
        if node.name == 'external_declaration' then
            return sx(node.children[1])
        end
    end
end

-- the line of the right side of x = <expression>; in a function body
local function expression(source)
    local line = external('void f(void) { x = ' .. source .. '; }')
    return assert(line:match('assignment_operator%(=%) (.*)%)%) ;%)%)%) ' ..
                                 '}%)%)$'))
end

function testcase.grammar_extends_c99_with_the_mixin()
    local grammar = assert(shared.load('lexogram:c99_macro'))
    assert.equal(grammar.name, 'c99_macro')
    assert.is_nil(grammar.extends)
    -- the rules with events are those of c99
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
    assert.equal(rule_names(compiled()), rule_names(compiled('lexogram:c99')))
end

function testcase.a_member_may_be_declared_by_a_macro()
    assert.equal(external('struct S { CommonHeader; int a; };'),
                 'declaration(type_specifier(struct_or_union_specifier(' ..
                     'struct S { struct_declaration(type_specifier(' ..
                     'typedef_name(CommonHeader)) ;) struct_declaration(' ..
                     'type_specifier(int) struct_declarator_list(' ..
                     'struct_declarator(declarator(direct_declarator(a)))) ' ..
                     ';) })) ;)')
end

function testcase.an_argument_that_is_no_expression_is_a_type_name()
    assert.equal(expression('cast(char *, s)'),
                 'assignment_expression(postfix_expression(cast ( ' ..
                     'argument_expression_list(type_name(type_specifier(' ..
                     'char) abstract_declarator(pointer(*))) , ' ..
                     'assignment_expression(postfix_expression(s))) )))')
    assert.equal(expression('newvector(L, n, Proto *)'),
                 'assignment_expression(postfix_expression(newvector ( ' ..
                     'argument_expression_list(assignment_expression(' ..
                     'postfix_expression(L)) , assignment_expression(' ..
                     'postfix_expression(n)) , type_name(type_specifier(' ..
                     'typedef_name(Proto)) abstract_declarator(' ..
                     'pointer(*)))) )))')
    -- an argument that is an expression stays one
    assert.equal(expression('f(x)'),
                 'assignment_expression(postfix_expression(f ( ' ..
                     'argument_expression_list(assignment_expression(' ..
                     'postfix_expression(x))) )))')
end

function testcase.macros_may_be_next_to_string_literals()
    assert.equal(expression('"a" LUA_QS "b"'),
                 'assignment_expression(postfix_expression("a" LUA_QS "b"))')
    assert.equal(expression('LUA_QL("x") " b"'),
                 'assignment_expression(postfix_expression(LUA_QL ( ' ..
                     'argument_expression_list(assignment_expression(' ..
                     'postfix_expression("x"))) ) " b"))')
    assert.equal(expression('FMT "x" Y'),
                 'assignment_expression(postfix_expression(FMT "x" Y))')
end

function testcase.other_forms_of_macros_are_errors()
    for _, source in ipairs({
        -- names of macros without a string literal
        'void f(void) { g(A B); }',
        -- an operator or a statement as an argument
        'void f(void) { x = intop(+, a, b); }',
        'void f(void) { TRY(L, g(); ); }',
    }) do
        local result, err = lexogram.parse(compiled(), source)
        assert.is_nil(result)
        assert.equal(err.code, 'syntax_error')
    end
end

function testcase.c99_sources_are_read_as_by_c99()
    local f = assert(io.open('c99/sample.c', 'rb'))
    local source = f:read('*a')
    f:close()
    -- parsing takes long under luacov's line hook
    local with_macros = without_hook(parse, source)
    local plain = without_hook(parse, source, 'lexogram:c99')
    assert.equal(with_macros.count, plain.count)
    for i = 1, plain.count * 4 do
        if with_macros.events[i] ~= plain.events[i] then
            assert.equal({
                i,
                with_macros.events[i],
            }, {
                i,
                plain.events[i],
            })
        end
    end
end
