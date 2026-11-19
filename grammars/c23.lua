--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- C23 grammar for lexogram. doc/grammars/c23.md describes it in Markdown.
--
-- The grammar extends "lexogram:c11" with the changes of the syntax of C23
-- (ISO/IEC 9899:2024, Annex A); the rest, and the choices made where C
-- cannot be parsed without knowing which identifiers name types, are those
-- of c11.
--
--   extends   'lexogram:c11'
--   name      'c23', the built-in grammar "lexogram:c23" (module
--             lexogram.grammars.c23)
--   version   '2024-1', the year of the standard and the revision of the
--             grammar
--
-- keywords
--
-- alignas, alignof, bool, constexpr, false, nullptr, static_assert,
-- thread_local, true, typeof, typeof_unqual, _BitInt, _Decimal32,
-- _Decimal64 and _Decimal128 are added; _Alignas, _Alignof, _Bool,
-- _Static_assert and _Thread_local stay as their other spellings.
--
-- tokens
--
--   identifier          a byte from 80 to FF is a character of a name too
--                       (the characters of Unicode that C23 allows, not
--                       checked)
--   number              digit separators (1'000), binary integers (0b101),
--                       the suffixes wb and uwb of bit-precise integers and
--                       df, dd and dl of decimal floating constants
--   character_constant  the prefix u8 is added
--
-- rules
--
--   member_declaration, member_declarator_list, member_declarator
--                       the names of C23 for struct_declaration,
--                       struct_declarator_list and struct_declarator
--   typeof_specifier    typeof or typeof_unqual ( expression or type_name
--                       ), a type specifier (the expression is tried
--                       first, so that typeof(a[0]) is no array type)
--   braced_initializer  { initializer_list ,? } or {}
--   enum_type_specifier : and the type of an enumeration
--   label               a label, which may also end a block or come before
--                       a declaration in it
--   unlabeled_statement, primary_block
--                       the statements as C23 groups them
--
-- _BitInt ( constant_expression ), bool and the decimal floating types are
-- type specifiers, constexpr and thread_local storage classes, true, false
-- and nullptr operands, the message of a static assertion may be left out,
-- a parameter list may be "..." alone, and a compound literal may have
-- storage classes. A function definition has no declarations between its
-- declarator and its body (C23 has no identifier lists).
return assert(require('lexogram.grammar')({
    extends = 'lexogram:c11',
    lexogram = '2026.11.15.1',
    name = 'c23',
    version = '2024-1',
    ['+keywords'] = {
        'alignas',
        'alignof',
        'bool',
        'constexpr',
        'false',
        'nullptr',
        'static_assert',
        'thread_local',
        'true',
        'typeof',
        'typeof_unqual',
        '_BitInt',
        '_Decimal32',
        '_Decimal64',
        '_Decimal128',
    },
    ['++tokens'] = {
        -- digits with separators
        _dec = [[ DIGIT ("'"? DIGIT)* ]],
        _hex = [[ HEXDIGIT ("'"? HEXDIGIT)* ]],
    },
    tokens = {
        ['=_nondigit'] = [[ [A-Za-z_\x80-\xFF] | _ucn ]],
        ['=number'] = {
            [[
                "."? DIGIT
                ([0-9A-Za-z_.] | [eEpP] ("+" | "-") | "'" [0-9A-Za-z_] | _ucn)*
            ]],
            [[ _integer_constant | _floating_constant ]],
        },
        ['=_integer_constant'] = [[
            (
                [1-9] ("'"? DIGIT)* | "0" ("'"? [0-7])*
                | "0" [xX] _hex | "0" [bB] [01] ("'"? [01])*
            )
            (
                [uU] (_long | "wb" | "WB")?
                | (_long | "wb" | "WB") [uU]?
            )?
        ]],
        ['=_floating_constant'] = [[
            (
                (_dec? "." _dec | _dec ".") _exponent?
                | _dec _exponent
            ) ([fFlL] | "df" | "dd" | "dl" | "DF" | "DD" | "DL")?
            | "0" [xX] (_hex? "." _hex | _hex "."?) [pP] ("+" | "-")? _dec
              [fFlL]?
        ]],
        ['=_exponent'] = [[ [eE] ("+" | "-")? _dec ]],
        ['=character_constant'] = [[
            ("u8" | [LuU])? "'" ([^'\\\n\r] | _escape)+ "'"
        ]],
    },
    ['--rules'] = {
        'struct_declaration',
        'struct_declarator_list',
        'struct_declarator',
    },
    ['++rules'] = {
        member_declaration = [[
            _qualifier_or_keyword_type _struct_rest
            | type_specifier _struct_rest
            | static_assert_declaration
        ]],
        member_declarator_list = [[
            member_declarator ("," member_declarator)*
        ]],
        member_declarator = [[
            declarator (":" constant_expression)? | ":" constant_expression
        ]],
        typeof_specifier = [[
            ("typeof" | "typeof_unqual") "(" (expression / type_name) ")"
        ]],
        braced_initializer = [[ _lbrace (initializer_list ","?)? _rbrace ]],
        -- the underlying type of an enumeration is an integer type, which
        -- no structure, union or enumeration is
        enum_type_specifier = [[ ":" _integer_specifier++ ]],
        _integer_specifier = [[
            (
                "char" | "short" | "int" | "long" | "signed" | "unsigned"
                | "bool" | "_Bool" | typeof_specifier
            )->type_specifier
            | type_specifier | _plain_qualifier
        ]],
        label = [[
            identifier ":" | "case" constant_expression ":" | "default" ":"
        ]],
        unlabeled_statement = [[
            expression_statement | primary_block | jump_statement
        ]],
        primary_block = [[
            compound_statement | selection_statement | iteration_statement
        ]],
    },
    rules = {
        ['=_struct_body'] = [[ _lbrace member_declaration+ _rbrace ]],
        ['=_struct_declarator_list'] = [[ member_declarator_list ]],
        ['=storage_class_specifier'] = [[
            "typedef" | "extern" | "static" | "thread_local" | "_Thread_local"
            | "auto" | "register" | "constexpr"
        ]],
        ['=_type_keyword'] = [[
            "void" | "char" | "short" | "int" | "long" | "float" | "double"
            | "signed" | "unsigned" | "bool" | "_Bool" | "_Complex"
            | "_Imaginary" | "_BitInt" "(" constant_expression ")"
            | "_Decimal32" | "_Decimal64" | "_Decimal128"
            | struct_or_union_specifier | enum_specifier | typeof_specifier
        ]],
        ['=alignment_specifier'] = [[
            ("alignas" | "_Alignas") "(" (type_name / constant_expression) ")"
        ]],
        ['=alignof_expression'] = [[
            ("alignof" | "_Alignof") "(" type_name ")"
        ]],
        ['=static_assert_declaration'] = [[
            ("static_assert" | "_Static_assert")
            "(" constant_expression ("," _strings)? ")" ";"
        ]],
        ['=enum_specifier'] = [[
            "enum"
            (
                identifier enum_type_specifier?+ _enum_body?
                | enum_type_specifier? _enum_body
            )
        ]],
        ['=initializer'] = [[ assignment_expression | braced_initializer ]],
        ['=compound_literal'] = [[
            "(" storage_class_specifier* type_name ")" braced_initializer
        ]],
        ['=parameter_type_list'] = [[
            parameter_declaration ("," parameter_declaration)* ("," "...")?
            | "..."
        ]],
        ['=_function_rest'] = [[
            _keyword_specifier _function_rest
            | (
                (declarator compound_statement)
                / (type_specifier _function_rest)
            )
        ]],
        ['=statement'] = [[ labeled_statement | unlabeled_statement ]],
        ['=labeled_statement'] = [[ label statement ]],
        ['=block_item'] = [[ declaration / (unlabeled_statement | label) ]],
        ['=_primary_expression'] = [[
            identifier | number | character_constant | _strings
            | "true" | "false" | "nullptr"
            | generic_selection | (compound_literal / "(" expression ")")
        ]],
    },
}))
