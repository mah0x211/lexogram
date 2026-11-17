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
-- Lua 5.1 grammar for lexogram, the built-in grammar "lexogram:lua51"
-- (module lexogram.grammars.lua51).
--
-- The rules follow the complete syntax of Lua in the Lua 5.1 reference
-- manual (section 8). Rule names come from the manual and from the Lua
-- 5.1 parser (lparser.c); they are a public contract with consumers.
--
-- Statements are kept apart by named rules that include their keywords:
-- exprstat (assignments and function calls), dostat, whilestat,
-- repeatstat, ifstat, forstat (with fornum or forlist inside it, after
-- "for"), funcstat, localfunc, localstat, retstat and breakstat. Fields of
-- a table constructor are recfield ("[" exp "]" "=" exp and name "=" exp)
-- or listfield, and the kind of call arguments is told by the first token
-- inside args ("(", "{" or a string).
--
-- Long strings are two tokens: long_string for level 0 ([[ ]]), where an
-- inner [[ is an error as in the Lua 5.1 lexer (nest = 'error'), and
-- long_string_level for the levels with "=" ([=[ ]=] ...), where an inner
-- open is ordinary text. A long comment is "--" followed by either of
-- them, so it reads its body the same way, as the Lua 5.1 lexer does.
--
-- Expressions list their terms and operators flat (unop, binop); a
-- consumer applies the operator precedence of Lua itself. Whether the
-- target of an assignment is assignable, or whether an expression
-- statement is a call, is not checked by the grammar (it describes the
-- syntax only), so such code is accepted although the official parser
-- rejects it.
return assert(require('lexogram.grammar')({
    lexogram = '2026.11.15.1',
    name = 'lua51',
    version = '1.0.0',
    start = 'chunk',
    tokens = {
        name = [[ (ALPHA | "_") (ALPHA | DIGIT | "_")* ]],
        -- 3  3.0  3.  .5  314.16e-2  0x56
        number = [[
            _digits ("." DIGIT*)? _exponent?
            | "." _digits _exponent?
            | "0" ("x" | "X") HEXDIGIT+
        ]],
        _digits = [[ DIGIT+ ]],
        _exponent = [[ ("e" | "E") ("+" | "-")? _digits ]],
        -- a backslash may be followed by any byte (\n, \\, \ddd and a
        -- backslash-newline continuation); an unescaped line break ends
        -- the token without a closing quote
        string = [[
            "\"" ([^"\\\n\r] | "\\" ANY)* "\""
            | "'" ([^'\\\n\r] | "\\" ANY)* "'"
        ]],
        space = [[ [ \t\r\n\x0B\x0C]+ ]],
        comment = [[ "--" [^\n\r]* ]],
        -- the patterns contain [[ and ]], so they are written in Lua long
        -- brackets of level 1
        long_string = {
            open = [=[ "[[" ]=],
            close = [=[ "]]" ]=],
            nest = 'error',
        },
        long_string_level = {
            open = [[ "[" level "[" ]],
            close = [[ "]" level "]" ]],
            level = [[ "="+ ]],
        },
        long_comment = {
            prefix = [[ "--" ]],
            match = {
                'long_string',
                'long_string_level',
            },
        },
    },
    symbols = {
        '+',
        '-',
        '*',
        '/',
        '%',
        '^',
        '#',
        '==',
        '~=',
        '<=',
        '>=',
        '<',
        '>',
        '=',
        '(',
        ')',
        '{',
        '}',
        '[',
        ']',
        ';',
        ':',
        ',',
        '.',
        '..',
        '...',
    },
    keywords = {
        'and',
        'break',
        'do',
        'else',
        'elseif',
        'end',
        'false',
        'for',
        'function',
        'if',
        'in',
        'local',
        'nil',
        'not',
        'or',
        'repeat',
        'return',
        'then',
        'true',
        'until',
        'while',
    },
    skip = {
        'space',
        'comment',
        'long_comment',
    },
    rules = {
        -- chunks and blocks
        chunk = [[ block ]],
        block = [[ (_stat ";"?)* (_laststat ";"?)? ]],

        -- statements
        _stat = [[
            exprstat | dostat | whilestat | repeatstat | ifstat | forstat
            | funcstat | localfunc | localstat
        ]],
        _laststat = [[ retstat | breakstat ]],
        exprstat = [[ suffixedexp (("," suffixedexp)* "=" explist)? ]],
        dostat = [[ "do" block "end" ]],
        whilestat = [[ "while" exp "do" block "end" ]],
        repeatstat = [[ "repeat" block "until" exp ]],
        ifstat = [[
            "if" exp "then" block ("elseif" exp "then" block)*
            ("else" block)? "end"
        ]],
        -- fornum and forlist need three tokens to tell apart, so "for" is
        -- read by forstat around them
        forstat = [[ "for" (fornum | forlist) ]],
        fornum = [[ name "=" exp "," exp ("," exp)? "do" block "end" ]],
        forlist = [[ namelist "in" explist "do" block "end" ]],
        funcstat = [[ "function" funcname body ]],
        localfunc = [[ "local" "function" name body ]],
        localstat = [[ "local" namelist ("=" explist)? ]],
        retstat = [[ "return" explist? ]],
        breakstat = [[ "break" ]],

        funcname = [[ name ("." name)* (":" name)? ]],
        namelist = [[ name ("," name)* ]],
        explist = [[ exp ("," exp)* ]],

        -- expressions: terms and operators in order, without precedence
        exp = [[ unop* _simpleexp (binop unop* _simpleexp)* ]],
        unop = [[ "-" | "not" | "#" ]],
        binop = [[
            "+" | "-" | "*" | "/" | "^" | "%" | ".." | "<" | "<=" | ">"
            | ">=" | "==" | "~=" | "and" | "or"
        ]],
        _simpleexp = [[
            "nil" | "false" | "true" | number | string | long_string
            | long_string_level | "..." | functiondef | tableconstructor
            | suffixedexp
        ]],
        -- a variable, a call or a parenthesized expression with its
        -- suffixes; a "(" after it is always taken as call arguments
        suffixedexp = [[ _primaryexp _suffix* ]],
        _primaryexp = [[ name | "(" exp ")" ]],
        _suffix = [[ "." name | "[" exp "]" | ":" name args | args ]],
        args = [[
            "(" explist? ")" | tableconstructor | string | long_string
            | long_string_level
        ]],

        -- functions
        functiondef = [[ "function" body ]],
        body = [[ "(" parlist? ")" block "end" ]],
        parlist = [[ name ("," name)* ("," "...")? | "..." ]],

        -- table constructors
        tableconstructor = [[
            "{" (_field (_fieldsep _field)* _fieldsep?)? "}"
        ]],
        _field = [[ recfield | listfield ]],
        recfield = [[ ("[" exp "]" | name) "=" exp ]],
        listfield = [[ exp ]],
        _fieldsep = [[ "," | ";" ]],
    },
    -- a "(" after an expression starts call arguments even at the start of
    -- a line, as in the official parser (which reports such a call that
    -- starts a new line as ambiguous syntax)
    greedy = {
        'suffixedexp',
    },
}))
