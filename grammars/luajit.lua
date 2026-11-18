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
-- LuaJIT grammar for lexogram. doc/grammars/luajit.md has the same text in
-- Markdown.
--
-- The grammar extends "lexogram:lua51" with the syntax of the v2.1 branch
-- of LuaJIT (lj_lex.c, lj_parse.c and lj_strscan.c at 2.1.1792527310, the
-- last change of the syntax), which keeps the syntax of Lua 5.1 and adds
-- extensions of its own and some of Lua 5.2 and LuaJIT 3.0
-- (doc/extensions.html of LuaJIT). doc/grammars/lua51.md describes what
-- it inherits; the sections below follow the top-level fields of the table
-- returned at the end of this file and tell what changes.
--
-- Metadata
--
-- The fields lexogram, name and version tell which grammar this is.
--
--   extends   'lexogram:lua51'
--   lexogram  '2026.11.15.1'
--   name      'luajit', the built-in grammar "lexogram:luajit" (module
--             lexogram.grammars.luajit)
--   version   '2.1.1792527310-1', the version of LuaJIT whose syntax it
--             follows and the revision of the grammar
--
-- It accepts the syntax as the parser of LuaJIT does (loadstring, load and
-- loadfile alike: its lexer itself skips a byte order mark and a first
-- line that starts with "#!").
--
-- tokens
--
--   name                  a letter, "_" or a byte from 80 to FF, then also
--                         digits: the lexer takes every byte from 80 on as
--                         a character of a name
--   number                in two patterns: the run that the lexer reads
--                         (digits, letters, "_", the bytes from 80 on and
--                         dots, with the sign after an exponent mark), and
--                         the forms that the rest must be after every "_"
--                         is dropped, or it is an invalid number: decimal,
--                         hexadecimal (0x, with a fraction and a binary
--                         exponent) or binary (0b, an integer of at most 64
--                         digits after the leading zeros); an exponent is
--                         below 2^20; an integer may have the suffix LL,
--                         ULL or LLU (any case: a 64 bit integer, decimal
--                         up to 2^64 - 1, hexadecimal of at most 16 digits
--                         after the leading zeros), and any number the
--                         suffix i (an imaginary number)
--   string, _escape       the escapes of Lua 5.2 and \u{...} up to 10FFFF
--   long_string           a nested [[ is no error
--   space                 not a line break that a line number directive
--                         follows
--   line_directive        skipped: a line break, then a line "# 123" or
--                         "# 123 \"name\"" (spaces and tabs around; the
--                         line number up to 2147483379), which sets the line
--                         number for error messages; a larger line number
--                         makes it invalid, a "#" that starts a line and is
--                         followed by a number in any other form is an
--                         error, and one followed by no number is the
--                         length operator
--   shebang               leading and skipped: a byte order mark, and a
--                         first line that starts with "#!" with its line
--                         break, which the lexer skips
--   first_line_directive  leading and skipped: a line number directive
--                         at the start (after a byte order mark)
--
-- A line number directive after the shebang line is the length operator
-- instead, as the lexer reads the line after it without a line break.
--
-- symbols
--
-- "::" for labels; the compound assignments +=, -=, *=, /=, %=, ..=, &=,
-- |=, <<=, >>= and ~>>=, written without white space as the parser
-- requires; and the operators of the expressions below: -> ? ?. ?? ! !=
-- && || & | ~ << >> ~>>.
--
-- keywords
--
-- goto, const and continue are contextual keywords (keywords.contextual):
-- names that are keywords only where a statement starts with them, as the
-- parser of LuaJIT tells: goto before a name, const before a name or
-- function, continue at the end of a block.
--
-- rules
--
-- Statements of their own; four rules are replaced and five added:
--
--   block         (_stat | ";")* (_laststat ";"*)?     replaced: empty
--                                                      statements anywhere
--   _stat         the statements of lua51, conststat, labelstat and
--                 gotostat                             replaced
--   _laststat     retstat | breakstat | continuestat   replaced
--   exprstat      _primaryexp (_suffix++ _assignment? | _assignment)
--                                                      replaced
--   _assignment   ("," suffixedexp)* "=" explist
--                 | (compound assignment) exp          added
--   labelstat     "::" name "::"                       added
--   gotostat      "goto" name                          added
--   conststat     "const" ("function" name body
--                 | namelist ("=" explist)?)           added
--   continuestat  "continue"                           added
--
-- Expressions, with their own rules; five rules are replaced and five
-- added:
--
--   exp           unop* _simpleexp (binop unop* _simpleexp)*+ ternary?+
--                                                      replaced
--   unop          "-" | "not" | "#" | "~" | "!"        replaced
--   binop         the operators of lua51, the bit operators & | ~ << >>
--                 ~>>, != && || (as ~= and or) and ??  replaced
--   _simpleexp    the terms of lua51 and shortfunc     replaced
--   _suffix       "?."? ("[" exp "]" | ":" name "?."? args | args)
--                 | "?." name | "." name               replaced
--   ternary       "?" _middle ":" exp                  added
--   _middle       the operators and terms of exp, where ":" is no method
--                 call                                 added
--   _simpleexp_nocolon, _suffix_nocolon                added (the terms
--                                                      and suffixes of
--                                                      _middle)
--   shortfunc     (name | "|" parlist? "|" | "||") "->"
--                 ("do" block "end" | exp)             added
--
-- The ternary operator has the lowest priority and is right associative
-- (its else is an exp). In its middle, ":" is no method call, as in the
-- parser of LuaJIT (c ? a : m() is a ternary operator; c ? a:m() : b is an
-- error, and (a:m()) is written instead); the terms there are reported as
-- suffixedexp and shortfunc by aliases (see doc/grammar.md). The body of a
-- short function is one expression, as long as it goes on, or a block; a
-- short function name -> ... cannot start a statement. ?. before a suffix
-- skips the rest of the chain when the value is nil. The priorities of the
-- operators, from the lowest: or || ??, and &&, the comparisons and ~= !=,
-- |, ~, &, << >> ~>>, .. (right), + -, * / %, the unary operators, ^
-- (right).
--
-- A name or a parenthesized expression alone is no statement in exprstat,
-- as in the parser of LuaJIT, which lets two tokens tell the contextual
-- keywords from a name; so the first target of an assignment, or the call
-- of a call statement, is not in a suffixedexp, unlike in lua51 (the
-- other targets are). In a statement, ~= is the exclusive or assignment.
--
-- Differences from LuaJIT
--
-- The grammar accepts every source that LuaJIT accepts, and some that it
-- rejects: a statement that ends with a suffix other than a call (x.y), a
-- call as the target of an assignment, break and continue outside a loop,
-- a safe navigation in an assignment of several targets, and a number with
-- more than about 2^20 digits after its point.
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua51',
    lexogram = '2026.11.15.1',
    name = 'luajit',
    version = '2.1.1792527310-1',
    ['--tokens'] = {
        '_decimal',
        '_digits',
        '_exponent',
    },
    ['++tokens'] = {
        -- the underscores after a character of a number, which the lexer
        -- drops
        _u = [[ "_"* ]],
        _d = [[ DIGIT _u ]],
        _h = [[ HEXDIGIT _u ]],
        _b = [[ [01] _u ]],
        -- an exponent, below 2^20 after the leading zeros
        _exponent_value = [[ ("0" _u)+ _exponent_digits? | _exponent_digits ]],
        _exponent_digits = [[
              [1-9] _u _d{0,5}
            | "1" _u "0" _u [0-3] _u _d{4}
            | "1" _u "0" _u "4" _u [0-7] _u _d{3}
            | "1" _u "0" _u "4" _u "8" _u [0-4] _u _d{2}
            | "1" _u "0" _u "4" _u "8" _u "5" _u [0-6] _u _d
            | "1" _u "0" _u "4" _u "8" _u "5" _u "7" _u [0-5] _u
        ]],
        -- the suffix of a 64 bit integer
        _ll = [[
            ([uU] _u)? [lL] _u [lL] _u | [lL] _u [lL] _u [uU] _u
        ]],
        -- a decimal integer up to 2^64 - 1, after the leading zeros
        _ll_decimal = [[ ("0" _u)+ _ll_decimal_digits? | _ll_decimal_digits ]],
        _ll_decimal_digits = [[
              [1-9] _u _d{0,18}
            | "1" _u [0-7] _u _d{18}
            | "1" _u "8" _u [0-3] _u _d{17}
            | "1" _u "8" _u "4" _u [0-3] _u _d{16}
            | "1" _u "8" _u "4" _u "4" _u [0-5] _u _d{15}
            | "1" _u "8" _u "4" _u "4" _u "6" _u [0-6] _u _d{14}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u [0-3] _u _d{13}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u [0-3] _u
              _d{12}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u [0-6] _u _d{10}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u [0-2] _u _d{9}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u [0-6] _u _d{8}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u [0-8] _u _d{6}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u "9" _u [0-4] _u _d{5}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u "9" _u "5" _u [0-4] _u
              _d{4}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u "9" _u "5" _u "5" _u
              "0" _u _d{3}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u "9" _u "5" _u "5" _u
              "1" _u [0-5] _u _d{2}
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u "9" _u "5" _u "5" _u
              "1" _u "6" _u "0" _u _d
            | "1" _u "8" _u "4" _u "4" _u "6" _u "7" _u "4" _u "4" _u
              "0" _u "7" _u "3" _u "7" _u "0" _u "9" _u "5" _u "5" _u
              "1" _u "6" _u "1" _u [0-5] _u
        ]],
        -- a hexadecimal integer of at most 16 digits after the leading
        -- zeros
        _ll_hex = [[ ("0" _u)+ _ll_hex_digits? | _ll_hex_digits ]],
        _ll_hex_digits = [[
            [1-9A-Fa-f] _u _h{0,15}
        ]],
        -- a binary integer of at most 64 digits after the leading zeros
        _binary = [[ ("0" _u)+ _binary_digits? | _binary_digits ]],
        _binary_digits = [[
            "1" _u _b{0,63}
        ]],
        -- a line break, as the lexer reads it
        _line_break = [[ "\r\n" | "\n\r" | "\n" | "\r" ]],
        -- the line number of a directive, up to 2147483379 after the
        -- leading zeros (the lexer stops at a number that a digit more
        -- could make larger than the largest line number): the digits
        -- choose the directive, and a larger number makes it invalid
        _line_number = {
            [[ DIGIT+ ]],
            [[ "0"+ _line_number_digits? | _line_number_digits ]],
        },
        _line_number_digits = [[
              [1-9] DIGIT{0,8}
            | "1" DIGIT{9}
            | "2" "0" DIGIT{8}
            | "2" "1" [0-3] DIGIT{7}
            | "2" "1" "4" [0-6] DIGIT{6}
            | "2" "1" "4" "7" [0-3] DIGIT{5}
            | "2" "1" "4" "7" "4" [0-7] DIGIT{4}
            | "2" "1" "4" "7" "4" "8" [0-2] DIGIT{3}
            | "2" "1" "4" "7" "4" "8" "3" [0-2] DIGIT{2}
            | "2" "1" "4" "7" "4" "8" "3" "3" [0-6] DIGIT
            | "2" "1" "4" "7" "4" "8" "3" "3" "7" [0-9]
        ]],
        -- a line number directive after its "#": the line number and a
        -- name in a string that stays on the line, with spaces and tabs
        -- around, up to the end of the line
        _directive = [[
            [ \t]* _line_number [ \t]* (_directive_name [ \t]*)?
            (?![^\r\n])
        ]],
        _directive_name = [[
            "\"" (
                [^"\\\n\r]
                | "\\" (
                    [abfnrtvz\\\"']
                    | "x" HEXDIGIT{2}
                    | _decimal_escape
                    | "u{" "0"* _code_point "}"
                )
            )* "\""
        ]],
        line_directive = [[ _line_break "#" _directive ]],
        first_line_directive = [[ "\xEF\xBB\xBF"? "#" _directive ]],
        shebang = [[
            "\xEF\xBB\xBF" ("#!" [^\r\n]* _line_break?)?
            | "#!" [^\r\n]* _line_break?
        ]],
        -- the hexadecimal digits of a code point up to 10FFFF, after the
        -- leading zeros
        _code_point = [[ HEXDIGIT{1,5} | "10" HEXDIGIT{4} ]],
    },
    tokens = {
        ['--long_string'] = {
            'nest',
        },
        ['=name'] = [[ [A-Za-z_\x80-\xFF] [0-9A-Za-z_\x80-\xFF]* ]],
        -- 3  3.  .5  1e3  0x1p4  0b101  1_000  1LL  0x10ULL  2i; the run
        -- that the lexer reads: digits, letters, "_", the bytes from 80 on
        -- and dots, and a sign after an exponent mark (e, or p after a first
        -- 0x, also after a dot; the "_" between them are dropped), written
        -- without a lookahead for the 0x, which a decimal run cannot start
        -- with; then the forms of a number with the limits of the values
        ['=number'] = {
            [[
                "."? (
                    "0" "_"* [xX]
                      ([0-9A-Za-z_\x80-\xFF.] | [pP] "_"* ("+" | "-"))*
                    | ([1-9] | "0" "_"* ([0-9A-WYZa-wyz\x80-\xFF.]
                                         | [eE] "_"* ("+" | "-")))
                      ([0-9A-Za-z_\x80-\xFF.] | [eE] "_"* ("+" | "-"))*
                    | "0" "_"*
                )
            ]],
            [[
                (_d+ ("." _u _d*)? | "." DIGIT _u _d*)
                  ([eE] _u (("+" | "-") _u)? _exponent_value)? ([iI] _u)?
                | _ll_decimal _ll
                | "0" _u [xX] _u
                  (_h+ ("." _u _h*)? | "." _u _h+)
                  ([pP] _u (("+" | "-") _u)? _exponent_value)? ([iI] _u)?
                | "0" _u [xX] _u _ll_hex _ll
                | "0" _u [bB] _u _binary ([iI] _u | _ll)?
            ]],
        },
        ['=_escape'] = [[
            "\\" (
                [abfnrtv\\\"']
                | "\r\n" | "\n\r" | "\n" | "\r"
                | "x" HEXDIGIT{2}
                | _decimal_escape
                | "z" [ \t\r\n\x0B\x0C]*
                | "u{" "0"* _code_point "}"
            )
        ]],
        -- a line break that a line number directive follows is part of the
        -- directive
        ['=space'] = [[
            ([ \t\x0B\x0C] | _line_break (?!"#" [ \t]* DIGIT))+
        ]],
    },
    -- goto, const and continue are names, and keywords only where a
    -- statement starts with them (see the rules)
    ['++keywords'] = {
        contextual = {
            'goto',
            'const',
            'continue',
        },
    },
    ['+symbols'] = {
        '::',
        '+=',
        '-=',
        '*=',
        '/=',
        '%=',
        '..=',
        '&=',
        '|=',
        '<<=',
        '>>=',
        '~>>=',
        '->',
        '<<',
        '>>',
        '~>>',
        '&',
        '|',
        '~',
        '!',
        '!=',
        '&&',
        '||',
        '?',
        '?.',
        '??',
    },
    ['++rules'] = {
        labelstat = [[ "::" name "::" ]],
        gotostat = [[ "goto" name ]],
        conststat = [[ "const" ("function" name body | namelist ("=" explist)?) ]],
        continuestat = [[ "continue" ]],
        -- the rest of an assignment after its first target: more targets
        -- and the values, or a compound assignment of one target, where
        -- ~= is the exclusive or (the unequal operator is no statement)
        -- c ? a : b, right associative (the else is an exp); in the middle,
        -- ":" is no method call, and its operands are reported as those
        -- elsewhere
        ternary = [[ "?" _middle ":" exp ]],
        _middle = [[
            unop* _simpleexp_nocolon (binop unop* _simpleexp_nocolon)*+
            ternary?+
        ]],
        _simpleexp_nocolon = [[
            "nil" | "false" | "true" | number | string | long_string
            | long_string_level | "..." | functiondef | tableconstructor
            | ((name | "|" parlist? "|" | "||") "->"
               ("do" block "end" | _middle))->shortfunc
            | (_primaryexp _suffix_nocolon*)->suffixedexp
        ]],
        _suffix_nocolon = [[ "?."? ("[" exp "]" | args) | "?." name | "." name ]],
        -- x -> e, |a, b| -> e, || -> do ... end: the body is one expression
        -- (as long as it goes on) or a block
        shortfunc = [[
            (name | "|" parlist? "|" | "||") "->" ("do" block "end" | exp)
        ]],
        _assignment = [[
            ("," suffixedexp)* "=" explist
            | ("+=" | "-=" | "*=" | "/=" | "%=" | "..=" | "&=" | "|=" | "<<="
               | ">>=" | "~>>=" | "~=") exp
        ]],
    },
    rules = {
        -- empty statements anywhere
        ['=block'] = [[ (_stat | ";")* (_laststat ";"*)? ]],
        ['=_stat'] = [[
            exprstat | dostat | whilestat | repeatstat | ifstat | forstat
            | funcstat | localfunc | localstat | conststat | labelstat
            | gotostat
        ]],
        ['=_laststat'] = [[ retstat | breakstat | continuestat ]],
        -- a call or an assignment: a name or a parenthesized expression
        -- alone is no statement (which lets two tokens tell goto, const
        -- and continue from a name)
        ['=exprstat'] = [[ _primaryexp (_suffix++ _assignment? | _assignment) ]],
        -- the operators and terms in order, and a ternary operator; the body
        -- of a short function takes as much as it can
        ['=exp'] = [[ unop* _simpleexp (binop unop* _simpleexp)*+ ternary?+ ]],
        ['=unop'] = [[ "-" | "not" | "#" | "~" | "!" ]],
        ['=binop'] = [[
            "+" | "-" | "*" | "/" | "%" | "^" | "&" | "|" | "~" | "<<" | ">>"
            | "~>>" | ".." | "==" | "~=" | "!=" | "<" | "<=" | ">" | ">="
            | "and" | "&&" | "or" | "||" | "??"
        ]],
        ['=_simpleexp'] = [[
            "nil" | "false" | "true" | number | string | long_string
            | long_string_level | "..." | functiondef | tableconstructor
            | shortfunc | suffixedexp
        ]],
        -- "?." before a suffix skips the rest of the chain on nil
        ['=_suffix'] = [[
            "?."? ("[" exp "]" | ":" name "?."? args | args) | "?." name
            | "." name
        ]],
    },
    ['+skip'] = {
        'line_directive',
        'shebang',
        'first_line_directive',
    },
    ['+leading'] = {
        'shebang',
        'first_line_directive',
    },
}))
