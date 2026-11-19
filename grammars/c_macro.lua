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
-- The forms of C sources before preprocessing that macros make, for the C
-- grammars of lexogram: a mixin that lexogram:c99_macro embeds into
-- lexogram:c99. doc/grammars/c_macro.md describes it.
--
-- Without the macros expanded, these forms have no C syntax; each of them
-- has no other reading in C, so a source of C is read as without the
-- mixin:
--
--   - a member declared by a macro: the declarators of a member may be
--     left out (CommonHeader;)
--   - a type name as a macro argument: an argument that is no expression
--     is tried as a type name (cast(char, c), luaM_newvector(L, n, T *))
--   - a macro next to a string literal: names and calls of macros may be
--     between and after the string literals of a run that has one, and
--     string literals may follow an operand ("a" LUA_QS "b",
--     LUA_QL("x") " b", FMT "x")
--
-- It replaces _struct_declarators, argument_expression_list, _strings and
-- _postfix_suffix, and adds _argument.
return assert(require('lexogram.grammar')({
    mixin = true,
    lexogram = '2026.11.15.1',
    name = 'c_macro',
    version = '1.0.0',
    ['++rules'] = {
        -- an expression, or a type name where no expression can be read
        _argument = [[ assignment_expression / type_name ]],
    },
    rules = {
        ['=_struct_declarators'] = [[ struct_declarator_list? ]],
        ['=argument_expression_list'] = [[ _argument ("," _argument)* ]],
        ['=_strings'] = [[ string_literal++ (identifier _strings?+)? ]],
        ['=_postfix_suffix'] = [[
            _lbracket expression _rbracket | "(" argument_expression_list? ")"
            | ("." | "->") identifier | "++" | "--" | _strings
        ]],
    },
}))
