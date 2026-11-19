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
-- C11 grammar for lexogram. doc/grammars/c11.md describes it in Markdown.
--
-- The grammar extends "lexogram:c99" with the changes of the syntax of C11
-- (ISO/IEC 9899:2011, Annex A); the rest, and the choices made where C
-- cannot be parsed without knowing which identifiers name types, are those
-- of c99.
--
--   extends   'lexogram:c99'
--   name      'c11', the built-in grammar "lexogram:c11" (module
--             lexogram.grammars.c11)
--   version   '2011-1', the year of the standard and the revision of the
--             grammar
--
-- keywords
--
-- _Alignas, _Alignof, _Atomic, _Generic, _Noreturn, _Static_assert and
-- _Thread_local are added.
--
-- tokens
--
--   character_constant  the prefixes u and U are added
--   string_literal      the prefixes u8, u and U are added
--
-- rules
--
--   storage_class_specifier  _Thread_local is added
--   function_specifier       _Noreturn is added
--   type_qualifier           _Atomic is added
--   atomic_type_specifier    _Atomic ( type_name ), a type specifier: an
--                            _Atomic followed by "(" is this, and any
--                            other _Atomic is a type qualifier
--   alignment_specifier      _Alignas ( type_name ) or _Alignas (
--                            constant_expression ), a specifier of
--                            declarations and members (the type name is
--                            tried first)
--   static_assert_declaration
--                            _Static_assert ( constant_expression ,
--                            string literals ) ;, a declaration and a
--                            member
--   alignof_expression       _Alignof ( type_name ), a term
--   generic_selection        _Generic ( assignment_expression ,
--                            generic_association, ... ), an operand
--   generic_association      type_name : assignment_expression or default
--                            : assignment_expression
--
-- A member may have no declarators (an anonymous structure or union; the
-- syntax does not tell it from other types). The specifiers of a member may
-- include alignment_specifier (as C17 corrected).
return assert(require('lexogram.grammar')({
    extends = 'lexogram:c99',
    lexogram = '2026.11.15.1',
    name = 'c11',
    version = '2011-1',
    ['+keywords'] = {
        '_Alignas',
        '_Alignof',
        '_Atomic',
        '_Generic',
        '_Noreturn',
        '_Static_assert',
        '_Thread_local',
    },
    tokens = {
        ['=character_constant'] = [[
            [LuU]? "'" ([^'\\\n\r] | _escape)+ "'"
        ]],
        ['=string_literal'] = [[
            ("u8" | [LuU])? "\"" ([^"\\\n\r] | _escape)* "\""
        ]],
    },
    ['++rules'] = {
        -- _Atomic followed by "(" is a type specifier, any other a
        -- qualifier
        atomic_type_specifier = [[ "_Atomic" "(" type_name ")" ]],
        _atomic = [[
            (atomic_type_specifier)->type_specifier
            / ("_Atomic")->type_qualifier
        ]],
        _plain_qualifier = [[
            ("const" | "restrict" | "volatile")->type_qualifier
        ]],
        alignment_specifier = [[
            "_Alignas" "(" (type_name / constant_expression) ")"
        ]],
        static_assert_declaration = [[
            "_Static_assert" "(" constant_expression "," _strings ")" ";"
        ]],
        alignof_expression = [[ "_Alignof" "(" type_name ")" ]],
        generic_selection = [[
            "_Generic" "(" assignment_expression ","
            generic_association ("," generic_association)* ")"
        ]],
        generic_association = [[
            (type_name | "default") ":" assignment_expression
        ]],
    },
    rules = {
        ['=storage_class_specifier'] = [[
            "typedef" | "extern" | "static" | "_Thread_local" | "auto"
            | "register"
        ]],
        ['=function_specifier'] = [[ "inline" | "_Noreturn" ]],
        ['=type_qualifier'] = [[
            "const" | "restrict" | "volatile" | "_Atomic"
        ]],
        ['=_keyword_specifier'] = [[
            storage_class_specifier | _keyword_type_specifier
            | _plain_qualifier | function_specifier | alignment_specifier
            | _atomic
        ]],
        ['=_qualifier_or_keyword_type'] = [[
            _keyword_type_specifier | _plain_qualifier | alignment_specifier
            | _atomic
        ]],
        ['=_type_part'] = [[
            _keyword_type_specifier | type_specifier
            | (atomic_type_specifier)->type_specifier
        ]],
        ['=declaration'] = [[
            _keyword_specifier _declaration_rest
            | type_specifier _declaration_rest
            | static_assert_declaration
        ]],
        ['=struct_declaration'] = [[
            _qualifier_or_keyword_type _struct_rest
            | type_specifier _struct_rest
            | static_assert_declaration
        ]],
        ['=_struct_declarators'] = [[ struct_declarator_list? ]],
        ['=_term'] = [[
            unary_operator _term | ("++" | "--") _term | sizeof_expression
            | alignof_expression | (cast_expression / postfix_expression)
        ]],
        ['=_primary_expression'] = [[
            identifier | number | character_constant | _strings
            | generic_selection | (compound_literal / "(" expression ")")
        ]],
    },
}))
