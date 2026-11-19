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
-- Lua 5.4 grammar for lexogram. doc/grammars/lua54.md has the same text
-- in Markdown.
--
-- The grammar extends "lexogram:lua53" with the changes of the Lua 5.4
-- reference manual (section 9, the complete syntax, and section 3.1, the
-- lexical conventions) and of its lexer and parser (llex.c, lparser.c).
-- doc/grammars/lua53.md, doc/grammars/lua52.md and doc/grammars/lua51.md
-- describe what it inherits; the sections below follow the top-level
-- fields of the table returned at the end of this file and tell what
-- changes.
--
-- Metadata
--
-- The fields lexogram, name and version tell which grammar this is.
--
--   extends   'lexogram:lua53'
--   lexogram  '2026.11.15.1'
--   name      'lua54', the built-in grammar "lexogram:lua54" (module
--             lexogram.grammars.lua54)
--   version   '5.4.8-1', the release of Lua it was checked against and the
--             revision of the grammar
--
-- It accepts the syntax as the parser of Lua 5.4 does (load).
--
-- tokens
--
-- One token and one fragment change; the others are those of lua53.
--
--   number        the lexer reads one letter or "_" more after the run of
--                 lua53, which makes it an invalid number: 3print is no
--                 number either
--   _code_point   the digits of a value below 2^31 (\u{7FFFFFFF}; Lua 5.4
--                 checks the value: \u{80000000} is an error)
--
-- rules
--
-- A local variable may have an attribute (<const> or <close>). One rule is
-- replaced and two are added; the others are those of lua53:
--
--   localstat     "local" attnamelist ("=" explist)?      replaced
--   attnamelist   name attrib? ("," name attrib?)*         added
--   attrib        "<" name ">"                             added
--
-- namelist stays for the generic for. "<" and ">" are symbols already.
--
-- Expressions
--
-- The operators and their priorities are those of lua53.
--
-- Differences from Lua 5.4
--
-- The grammar accepts every source that Lua 5.4 accepts, and some that it
-- rejects: those of lua53 (the checks that are not syntax, including those
-- of goto), and the checks of the attributes (a name other than const or
-- close, two <close> variables in one statement, an assignment to a
-- <const> variable).
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua53',
    lexogram = '2026.11.15.1',
    name = 'lua54',
    version = '5.4.8-1',
    tokens = {
        -- the run that the lexer reads: that of lua53 and one letter or "_"
        -- more; then the forms of a number
        ['=number'] = {
            [[
                (
                    "."? "0" [xX] ([pP] ("+" | "-")? | [0-9A-Fa-f.])*
                    | (DIGIT | "." DIGIT) ([eE] ("+" | "-")? | [0-9A-Fa-f.])*
                ) [A-Za-z_]?
            ]],
            [[
                _decimal _exponent?
                | "0" [xX] (HEXDIGIT+ ("." HEXDIGIT*)? | "." HEXDIGIT+)
                  ([pP] ("+" | "-")? _digits)?
            ]],
        },
        -- the hexadecimal digits of a value below 2^31, after the leading
        -- zeros
        ['=_code_point'] = [[ HEXDIGIT{1,7} | [0-7] HEXDIGIT{7} ]],
    },
    ['++rules'] = {
        attnamelist = [[ name attrib? ("," name attrib?)* ]],
        attrib = [[ "<" name ">" ]],
    },
    rules = {
        ['=localstat'] = [[ "local" attnamelist ("=" explist)? ]],
    },
}))
