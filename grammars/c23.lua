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
-- The symbol :: is added, for the names of attributes.
--
-- rules
--
--   attribute_specifier_sequence, attribute_specifier, attribute_list,
--   attribute, attribute_argument_clause
--                       attributes, [[ name, prefix::name(arguments) ]],
--                       where C23 places them: at the start of
--                       declarations, function definitions, members,
--                       parameters, statements and labels; after the
--                       specifiers, the identifier, the array and function
--                       suffixes and each * of declarators; after struct,
--                       union and enum; after the names of enumerators.
--                       The arguments are any tokens with balanced
--                       brackets.
--   attribute_declaration
--                       attributes alone and ;, a declaration
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
    ['+symbols'] = {
        '::',
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
        -- attributes: [[ name, prefix::name(arguments) ]], whose arguments
        -- are any tokens with balanced parentheses, brackets and braces
        attribute_specifier_sequence = [[ attribute_specifier+ ]],
        attribute_specifier = [[
            _lbracket _lbracket attribute_list _rbracket _rbracket
        ]],
        attribute_list = [[ attribute? ("," attribute?)* ]],
        attribute = [[
            _attribute_name ("::" _attribute_name)? attribute_argument_clause?
        ]],
        -- a keyword in an attribute is a name
        _attribute_name = [[ identifier | _keyword ]],
        attribute_argument_clause = [[ "(" _balanced_token* ")" ]],
        _balanced_token = [[
            "(" _balanced_token* ")" | _lbracket _balanced_token* _rbracket
            | _lbrace _balanced_token* _rbrace
            | identifier | number | character_constant | string_literal
            | "." | "->" | "++" | "--" | "&" | "*" | "+" | "-" | "~" | "!"
            | "/" | "%" | "<<" | ">>" | "<" | ">" | "<=" | ">=" | "==" | "!="
            | "^" | "|" | "&&" | "||" | "?" | ":" | "::" | ";" | "..." | "="
            | "*=" | "/=" | "%=" | "+=" | "-=" | "<<=" | ">>=" | "&=" | "^="
            | "|=" | "," | _keyword
        ]],
        -- the keywords of c23
        _keyword = [[
            "auto" | "break" | "case" | "char" | "const" | "continue"
            | "default" | "do" | "double" | "else" | "enum" | "extern"
            | "float" | "for" | "goto" | "if" | "inline" | "int" | "long"
            | "register" | "restrict" | "return" | "short" | "signed"
            | "sizeof" | "static" | "struct" | "switch" | "typedef" | "union"
            | "unsigned" | "void" | "volatile" | "while" | "_Bool"
            | "_Complex" | "_Imaginary" | "_Alignas" | "_Alignof" | "_Atomic"
            | "_Generic" | "_Noreturn" | "_Static_assert" | "_Thread_local"
            | "alignas" | "alignof" | "bool" | "constexpr" | "false"
            | "nullptr" | "static_assert" | "thread_local" | "true" | "typeof"
            | "typeof_unqual" | "_BitInt" | "_Decimal32" | "_Decimal64"
            | "_Decimal128"
        ]],
        attribute_declaration = [[ attribute_specifier_sequence ";" ]],
        -- the rest of a declaration with attributes before its specifiers,
        -- which has declarators
        _declarators_rest = [[
            _keyword_specifier _declarators_rest
            | attribute_specifier_sequence init_declarator_list ";"
            | (
                (init_declarator_list ";")
                / (type_specifier _declarators_rest)
            )
        ]],
        member_declaration = [[
            attribute_specifier_sequence?
            (_qualifier_or_keyword_type | type_specifier) _struct_rest
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
            attribute_specifier_sequence?
            (identifier ":" | "case" constant_expression ":" | "default" ":")
        ]],
        -- two tokens do not tell the attributes of an expression statement
        -- from those of the others, so it is tried first
        unlabeled_statement = [[
            expression_statement
            / attribute_specifier_sequence? (primary_block | jump_statement)
        ]],
        primary_block = [[
            compound_statement | selection_statement | iteration_statement
        ]],
    },
    rules = {
        ['=_struct_body'] = [[ _lbrace member_declaration+ _rbrace ]],
        ['=struct_or_union_specifier'] = [[
            ("struct" | "union") attribute_specifier_sequence?
            (identifier _struct_body? | _struct_body)
        ]],
        ['=_struct_rest'] = [[
            _qualifier_or_keyword_type _struct_rest
            | attribute_specifier_sequence _struct_declarators ";"
            | (
                (_struct_declarators ";")
                / (type_specifier _struct_rest)
            )
        ]],
        ['=function_definition'] = [[
            attribute_specifier_sequence?
            (_keyword_specifier | type_specifier) _function_rest
        ]],
        -- a declaration with attributes before its specifiers has
        -- declarators; two tokens do not tell those attributes from an
        -- attribute declaration, which is tried last
        ['=declaration'] = [[
            (
                (_keyword_specifier | type_specifier) _declaration_rest
                | attribute_specifier_sequence
                  (_keyword_specifier | type_specifier) _declarators_rest
                | static_assert_declaration
            )
            / attribute_declaration
        ]],
        ['=_declaration_rest'] = [[
            _keyword_specifier _declaration_rest
            | attribute_specifier_sequence init_declarator_list? ";"
            | (
                (init_declarator_list? ";")
                / (type_specifier _declaration_rest)
            )
        ]],
        ['=direct_declarator'] = [[
            identifier attribute_specifier_sequence? _suffixes
            | "(" _parenthesized
        ]],
        -- two tokens after an identifier do not tell attributes from an
        -- array suffix, so the identifier without suffixes is tried first
        ['=_parenthesized'] = [[
            (
                ((identifier attribute_specifier_sequence?)->direct_declarator)
                ->declarator ")" _required_suffixes
                / ((identifier attribute_specifier_sequence? _required_suffixes)
                  ->direct_declarator)->declarator ")" _suffixes
            )
            | (pointer direct_declarator)->declarator ")" _suffixes
            | (("(" _parenthesized)->direct_declarator)->declarator ")"
              _suffixes
        ]],
        ['=pointer'] = [[
            ("*" attribute_specifier_sequence? type_qualifier*)+
        ]],
        ['=_array_suffix'] = [[
            _lbracket _array_size? _rbracket attribute_specifier_sequence?
        ]],
        ['=function_suffix'] = [[
            "(" parameter_type_list? ")" attribute_specifier_sequence?
        ]],
        ['=parameter_declaration'] = [[
            attribute_specifier_sequence?
            _nontype_specifier* _type_part _parameter_rest?
        ]],
        ['=_parameter_rest'] = [[
            _keyword_specifier _parameter_rest?
            | attribute_specifier_sequence (declarator / abstract_declarator)?
            | (
                declarator / abstract_declarator
                / (type_specifier _parameter_rest?)
            )
        ]],
        -- the tokens "(" "[" start both an abstract declarator in
        -- parentheses and a function suffix whose first parameter has
        -- attributes, so the abstract declarator is tried first
        ['=direct_abstract_declarator'] = [[
            (("(" abstract_declarator ")" / function_suffix) | _array_suffix)
            _array_suffix* function_suffix?
        ]],
        ['=type_name'] = [[
            (_qualifier_or_keyword_type | type_specifier)+
            attribute_specifier_sequence? abstract_declarator?
        ]],
        ['=enumerator'] = [[
            identifier attribute_specifier_sequence? ("=" constant_expression)?
        ]],
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
                | attribute_specifier_sequence identifier?
                  enum_type_specifier? _enum_body
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
            | attribute_specifier_sequence declarator compound_statement
            | (
                (declarator compound_statement)
                / (type_specifier _function_rest)
            )
        ]],
        -- two tokens do not tell a label with attributes from a statement
        -- with them, so a label is tried first
        ['=statement'] = [[ labeled_statement / unlabeled_statement ]],
        ['=labeled_statement'] = [[ label statement ]],
        ['=expression_statement'] = [[
            expression? ";" | attribute_specifier_sequence expression ";"
        ]],
        ['=block_item'] = [[ declaration / label / unlabeled_statement ]],
        ['=_primary_expression'] = [[
            identifier | number | character_constant | _strings
            | "true" | "false" | "nullptr"
            | generic_selection | (compound_literal / "(" expression ")")
        ]],
    },
}))
