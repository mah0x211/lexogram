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
--
-- Lua 5.3 grammar for lexogram. doc/grammars/lua53.md has the same text
-- in Markdown.
--
-- The grammar extends "lexogram:lua52" with the changes of the Lua 5.3
-- reference manual (section 9, the complete syntax, and section 3.1, the
-- lexical conventions) and of its lexer and parser (llex.c, lparser.c).
-- doc/grammars/lua52.md and doc/grammars/lua51.md describe what it
-- inherits; the sections below follow the top-level fields of the table
-- returned at the end of this file and tell what changes.
--
-- Metadata
--
-- The fields lexogram, name and version tell which grammar this is.
--
--   extends   'lexogram:lua52'
--   lexogram  '2026.11.15.1'
--   name      'lua53', the built-in grammar "lexogram:lua53" (module
--             lexogram.grammars.lua53)
--   version   '5.3.6-1', the release of Lua it was checked against and the
--             revision of the grammar
--
-- It accepts the syntax as the parser of Lua 5.3 does (load).
--
-- tokens
--
-- One fragment changes and one is added; the tokens are those of lua52.
--
--   _escape       the escapes of lua52 and \u{XXX}: the UTF-8 encoding of
--                 a code point written as hexadecimal digits, "0"* and
--                 _code_point
--   _code_point   the digits of a value up to 10FFFF, after the leading
--                 zeros (Lua 5.3 checks the value: \u{110000} is an error)
--
-- A numeral is written as in Lua 5.2. Whether it denotes an integer or a
-- float depends on its text and value, not on the range of the token.
--
-- symbols
--
-- The operators of integer division and of bitwise operations are added:
--
--   integer_division = "//"
--   bitwise          = "&" | "~" | "|" | "<<" | ">>"
--
-- "~" is the binary exclusive or and the unary not of bits; "~=" is still
-- one token (the longest match).
--
-- rules
--
-- Two rules are replaced; the others are those of lua52:
--
--   unop    "-" | "not" | "#" | "~"
--   binop   "+" | "-" | "*" | "/" | "//" | "^" | "%" | "&" | "~" | "|"
--           | ">>" | "<<" | ".." | "<" | "<=" | ">" | ">=" | "==" | "~="
--           | "and" | "or"
--
-- Expressions
--
-- The priorities { left, right } of the Lua 5.3 parser, from low to high
-- (a right priority below the left one makes the operator right
-- associative):
--
--   or                   { 1, 1 }
--   and                  { 2, 2 }
--   < > <= >= ~= ==      { 3, 3 }
--   |                    { 4, 4 }
--   ~                    { 5, 5 }
--   &                    { 6, 6 }
--   << >>                { 7, 7 }
--   ..                   { 9, 8 }
--   + -                  { 10, 10 }
--   * / // %             { 11, 11 }
--   unary not # - ~      12 (the priority of the operand)
--   ^                    { 14, 13 }
--
-- Differences from Lua 5.3
--
-- The grammar accepts every source that Lua 5.3 accepts, and some that it
-- rejects: those of lua52 (the checks that are not syntax, including those
-- of goto).
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua52',
    lexogram = '2026.11.15.1',
    name = 'lua53',
    version = '5.3.6-1',
    ['+symbols'] = {
        '//',
        '&',
        '~',
        '|',
        '<<',
        '>>',
    },
    ['++tokens'] = {
        -- the hexadecimal digits of a code point up to 10FFFF, after the
        -- leading zeros
        _code_point = [[
            HEXDIGIT HEXDIGIT? HEXDIGIT? HEXDIGIT? HEXDIGIT?
            | "10" HEXDIGIT HEXDIGIT HEXDIGIT HEXDIGIT
        ]],
    },
    tokens = {
        -- a line break is \r\n, \n\r, \n or \r, as the lexer reads it
        ['=_escape'] = [[
            "\\" (
                [abfnrtv\\\"']
                | "\r\n" | "\n\r" | "\n" | "\r"
                | "x" HEXDIGIT HEXDIGIT
                | _decimal_escape
                | "z" [ \t\r\n\x0B\x0C]*
                | "u{" "0"* _code_point "}"
            )
        ]],
    },
    rules = {
        ['=unop'] = [[ "-" | "not" | "#" | "~" ]],
        ['=binop'] = [[
            "+" | "-" | "*" | "/" | "//" | "^" | "%" | "&" | "~" | "|" | ">>"
            | "<<" | ".." | "<" | "<=" | ">" | ">=" | "==" | "~=" | "and"
            | "or"
        ]],
    },
}))
