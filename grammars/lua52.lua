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
-- Lua 5.2 grammar for lexogram. doc/grammars/lua52.md has the same text
-- in Markdown.
--
-- The grammar extends "lexogram:lua51" with the changes of the Lua 5.2
-- reference manual (section 9, the complete syntax, and section 3.1, the
-- lexical conventions) and of its lexer and parser (llex.c, lparser.c).
-- doc/grammars/lua51.md describes what it inherits; the sections below
-- follow the top-level fields of the table returned at the end of this
-- file and tell what changes.
--
-- Metadata
--
-- The fields lexogram, name and version tell which grammar this is.
--
--   extends   'lexogram:lua51'
--   lexogram  '2026.11.15.1'
--   name      'lua52', the built-in grammar "lexogram:lua52" (module
--             lexogram.grammars.lua52)
--   version   '1.0.0'
--
-- It accepts the syntax as the parser of Lua 5.2 does (load).
--
-- tokens
--
-- Three tokens change, one fragment is added and one removed; the others
-- are those of lua51.
--
--   number             a hexadecimal number may have a fractional part and
--                      a binary exponent: 0x1.8p3, 0xA.Fp-2, 0x.8; the lexer
--                      reads hexadecimal digits and dots with exponent marks
--                      (e or E, p or P after 0x) and their signs, and
--                      rejects the whole run unless it is one number, so a
--                      decimal number is not followed by (?![0-9A-Fa-f.])
--                      and a hexadecimal one by (?![0-9A-Fa-fPp.]) (3e,
--                      1..2, 1e5..x, 0x and 0x1p are no numbers; 3print is
--                      the number 3 and the name print)
--   string             a backslash may be followed only by an escape of
--                      Lua 5.2: \a \b \f \n \r \t \v \\ \" \', a line break,
--                      \xXX (two hexadecimal digits), _decimal_escape or \z
--                      (which skips the white space and line breaks after
--                      it); any other escape is an error, as in the lexer of
--                      Lua 5.2
--   _escape            fragment: the escapes above
--   _integer           fragment: the digits of a decimal number; a first 0
--                      followed by x or X starts a hexadecimal number
--                      instead (also after a dot: .0x is no number); it
--                      replaces _decimal, which is removed
--   long_string        nest is removed: a [[ inside a long bracket of level
--                      0 is ordinary text, as in Lua 5.2 (long_comment,
--                      which reads its body as a long_string, follows)
--
-- symbols
--
-- One literal is added:
--
--   label = "::"
--
-- keywords
--
-- One literal is added, so goto is no longer a name:
--
--   keywords = "goto"
--
-- rules
--
-- A block is any number of statements and a final return; break becomes an
-- ordinary statement, and ";" alone is an empty statement, as in the
-- parser of Lua 5.2:
--
--   block      _stat* retstat?                       (replaced)
--   _stat      ";" | exprstat | dostat | whilestat | repeatstat | ifstat
--              | forstat | funcstat | localfunc | localstat | labelstat
--              | gotostat | breakstat                (replaced)
--   retstat    "return" explist? ";"?                (replaced)
--   labelstat  "::" name "::"                        (added)
--   gotostat   "goto" name                           (added)
--   _laststat                                        (removed)
--
-- An empty statement is a ";" token directly inside block, as a ";" after
-- a statement is in lua51.
--
-- Differences from Lua 5.2
--
-- The grammar accepts every source that Lua 5.2 accepts, and some that it
-- rejects. As in lua51, the checks that are not syntax are not made: an
-- assignment to a call (f() = 1), a statement that is not a call (x),
-- plain text as a sequence of such statements, a break outside a loop, and
-- "..." outside a vararg function. Lua 5.2 adds
-- checks of goto that are not syntax either: a goto without a visible
-- label, a goto into the scope of a local, and a label defined twice in
-- one block are accepted here.
--
-- Unlike Lua 5.1, the parser of Lua 5.2 reads a "(" at the start of a line
-- after an expression as call arguments, as this grammar does (_suffix*+), so
-- that difference of lua51 does not remain.
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua51',
    lexogram = '2026.11.15.1',
    name = 'lua52',
    version = '1.0.0',
    ['+keywords'] = {
        'goto',
    },
    ['+symbols'] = {
        '::',
    },
    -- the decimal part of a number is _integer instead
    ['--tokens'] = {
        '_decimal',
    },
    ['++tokens'] = {
        -- the digits of a decimal number; a first 0 followed by x or X
        -- starts a hexadecimal number instead
        _integer = [[ "0" (?![xX]) DIGIT* | [1-9] DIGIT* ]],
    },
    tokens = {
        ['--long_string'] = {
            'nest',
        },
        -- the lexer reads hexadecimal digits and dots, with exponent marks
        -- (e or E, p or P after 0x) and their signs, and rejects the whole
        -- run unless it is one number: a number is not followed by what
        -- the lexer would read on
        ['=number'] = [[
            (_integer ("." DIGIT*)? | "." _integer) _exponent?
              (?![0-9A-Fa-f.])
            | "0" ("x" | "X") (HEXDIGIT+ ("." HEXDIGIT*)? | "." HEXDIGIT+)
              (("p" | "P") ("+" | "-")? _digits)? (?![0-9A-Fa-fPp.])
        ]],
        -- a line break is \r\n, \n\r, \n or \r, as the lexer reads it
        ['=_escape'] = [[
            "\\" (
                [abfnrtv\\\"']
                | "\r\n" | "\n\r" | "\n" | "\r"
                | "x" HEXDIGIT HEXDIGIT
                | _decimal_escape
                | "z" [ \t\r\n\x0B\x0C]*
            )
        ]],
        ['=string'] = [[
            "\"" ([^"\\\n\r] | _escape)* "\""
            | "'" ([^'\\\n\r] | _escape)* "'"
        ]],
    },
    ['--rules'] = {
        '_laststat',
    },
    ['++rules'] = {
        labelstat = [[ "::" name "::" ]],
        gotostat = [[ "goto" name ]],
    },
    rules = {
        ['=block'] = [[ _stat* retstat? ]],
        ['=_stat'] = [[
            ";" | exprstat | dostat | whilestat | repeatstat | ifstat
            | forstat | funcstat | localfunc | localstat | labelstat
            | gotostat | breakstat
        ]],
        ['=retstat'] = [[ "return" explist? ";"? ]],
    },
}))
