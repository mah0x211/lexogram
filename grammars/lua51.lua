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
-- Lua 5.1 grammar for lexogram. doc/grammars/lua51.md has the same text
-- in Markdown, together with lua51_shebang, which extends this grammar.
--
-- The rules follow the complete syntax of Lua in section 8 of the Lua 5.1
-- reference manual; rule names come from the manual and from the Lua 5.1
-- parser (lparser.c). Together with the token names they are a public
-- contract with consumers, and the version of the grammar follows it: a
-- renamed or removed name is a new major version. The sections below
-- follow the top-level fields of the table returned at the end of this
-- file.
--
-- Metadata
--
-- The fields lexogram, name and version tell which grammar this is: the
-- revision of the lexogram specification it follows, its name (also its
-- built-in name), and its own version.
--
--   lexogram  '2026.11.15.1'
--   name      'lua51', the built-in grammar "lexogram:lua51" (module
--             lexogram.grammars.lua51)
--   version   '1.0.0'
--
-- It accepts the syntax as the parser of Lua 5.1 does (loadstring);
-- "lexogram:lua51_shebang" also skips a first line that starts with "#",
-- as the file loader of Lua 5.1 does.
--
-- start
--
-- The rule that must cover the whole input: chunk, which is a block.
--
-- tokens
--
-- The tokens of Lua 5.1: names, numbers, short strings, comments and white
-- space are patterns; long strings and long comments are delimited tokens,
-- because their close repeats the level of their open. The two parts with
-- "_" are fragments of the number pattern, not tokens.
--
--   name               [A-Za-z_][A-Za-z0-9_]*
--   number             3, 3.0, 3., .5, 314.16e-2, 0x56
--   string             "..." and '...'; a backslash may be followed by any
--                      byte (\n, \\, \ddd, a backslash and a line break); a
--                      line break without a backslash cannot be inside it
--   comment            "--" and the rest of the line
--   space              space, tab, carriage return, line feed, vertical tab
--                      and form feed
--   _digits            fragment: DIGIT+
--   _exponent          fragment: ("e" | "E") ("+" | "-")? _digits
--   long_string        open "[[", close "]]", nest = 'error': a long
--                      bracket of level 0; a [[ inside it is an error
--                      (nested_delimiter), as in the lexer of Lua 5.1
--   long_string_level  open "[" level "[", close "]" level "]", level "="+:
--                      a long bracket with "=" ([=[ ... ]=], ...); an open
--                      inside it is ordinary text
--   long_comment       prefix "--", match { long_string, long_string_level }:
--                      "--" followed by either of them, so that its body is
--                      read the same way (a [[ inside --[[ ... ]] is an
--                      error)
--
-- symbols
--
-- The punctuation of Lua 5.1, 26 literals ("|" separates the items; the
-- names on the left only group them for reading, and the grammar lists
-- all of them in one array):
--
--   arithmetic  = "+" | "-" | "*" | "/" | "%" | "^"
--   length      = "#"
--   comparison  = "==" | "~=" | "<=" | ">=" | "<" | ">"
--   assignment  = "="
--   brackets    = "(" | ")" | "{" | "}" | "[" | "]"
--   separators  = ";" | ":" | "," | "."
--   dots        = ".." | "..."
--
-- keywords
--
-- The reserved words of Lua 5.1, 21 literals. A name that is one of them
-- is the keyword, not a name token (a literal wins over a pattern token of
-- the same length).
--
--   keywords = "and" | "break" | "do" | "else" | "elseif" | "end" | "false"
--            | "for" | "function" | "if" | "in" | "local" | "nil" | "not"
--            | "or" | "repeat" | "return" | "then" | "true" | "until"
--            | "while"
--
-- skip
--
-- The tokens that may appear anywhere between the elements of the rules:
--
--   space, comment, long_comment
--
-- The tokens in skip are skipped between the elements of the rules, so
-- that no rule has to mention them, but they are still TOKEN events of the
-- event array (their kind has skip = true in the kind table), placed
-- outside the ranges of the rules: the events cover the whole source.
--
-- leading
--
-- The tokens that are tried at the start of the input only: none
-- (lua51_shebang reads a first line that starts with "#" as shebang).
--
-- rules
--
-- The syntax of Lua 5.1. The rules without "_" are the structures that a
-- consumer sees: each statement kind, the parts of a function and a table
-- constructor, the expression with its operators, a suffixed expression
-- and call arguments. The rules with "_" group alternatives and produce no
-- events.
--
-- Rules with events (an ENTER and an EXIT around their range):
--
--   chunk             block
--   block             (_stat ";"?)* (_laststat ";"?)?
--   exprstat          suffixedexp (("," suffixedexp)* "=" explist)?: an
--                     assignment or a function call
--   dostat            "do" block "end"
--   whilestat         "while" exp "do" block "end"
--   repeatstat        "repeat" block "until" exp
--   ifstat            "if" exp "then" block ("elseif" exp "then" block)*
--                     ("else" block)? "end"
--   forstat           "for" (fornum | forlist)
--   fornum            name "=" exp "," exp ("," exp)? "do" block "end"
--   forlist           namelist "in" explist "do" block "end"
--   funcstat          "function" funcname body
--   localfunc         "local" "function" name body
--   localstat         "local" namelist ("=" explist)?
--   retstat           "return" explist?
--   breakstat         "break"
--   funcname          name ("." name)* (":" name)?
--   namelist          name ("," name)*
--   explist           exp ("," exp)*
--   exp               unop* _simpleexp (binop unop* _simpleexp)*: terms
--                     and operators in order, without precedence
--   unop              "-" | "not" | "#"
--   binop             "+" | "-" | "*" | "/" | "^" | "%" | ".." | "<" | "<="
--                     | ">" | ">=" | "==" | "~=" | "and" | "or"
--   suffixedexp       _primaryexp _suffix*+: a variable, a call or a
--                     parenthesized expression with its suffixes
--   args              "(" explist? ")" | tableconstructor | string
--                     | long_string | long_string_level
--   functiondef       "function" body
--   body              "(" parlist? ")" block "end"
--   parlist           name ("," name)* ("," "...")? | "..."
--   tableconstructor  "{" (_field (_fieldsep _field)* _fieldsep?)? "}"
--   recfield          ("[" exp "]" | name) "=" exp
--   listfield         exp
--
-- Rules without events (their names start with "_"; their contents belong
-- to the enclosing rule):
--
--   _stat             exprstat | dostat | whilestat | repeatstat | ifstat
--                     | forstat | funcstat | localfunc | localstat
--   _laststat         retstat | breakstat
--   _simpleexp        "nil" | "false" | "true" | number | string
--                     | long_string | long_string_level | "..."
--                     | functiondef | tableconstructor | suffixedexp
--   _primaryexp       name | "(" exp ")"
--   _suffix           "." name | "[" exp "]" | ":" name args | args
--   _field            recfield | listfield
--   _fieldsep         "," | ";"
--
-- Possessive repetitions
--
-- The repetitions that go on as long as the next token can continue them,
-- where the grammar would otherwise be ambiguous, are possessive (*+): the
-- _suffix*+ of suffixedexp. A "(" after an expression is always read as
-- call arguments, even at the start of a line, as the parser of Lua 5.1
-- does (it also reports such a call that starts a new line as ambiguous
-- syntax; see the differences below).
--
-- recover
--
-- The rules from which the analysis recovers after a syntax error: none,
-- so the first syntax error stops the analysis.
--
-- Telling constructs apart
--
-- How a consumer tells the constructs of Lua apart from the event array
-- alone:
--
--   - Statements: each kind has its own rule, which includes its keywords.
--     "for" is read by forstat, around fornum or forlist, which need three
--     tokens to tell apart.
--   - Assignment or call: an exprstat is an assignment when it has a "="
--     token directly inside it.
--   - Table fields: recfield for [exp] = exp and name = exp (told apart by
--     the first token), listfield for a bare expression.
--   - Call arguments: the first token inside args is "(", a
--     tableconstructor or a string token. A method call has ":" and the
--     method name directly before its args inside suffixedexp.
--   - Parenthesized expression: a suffixedexp whose direct children are
--     "(", an exp and ")".
--
-- Expressions
--
-- exp lists its terms and operators flat; a consumer applies the
-- precedence of Lua. The priorities { left, right } of the Lua 5.1 parser
-- are, from low to high (a right priority below the left one makes the
-- operator right associative):
--
--   or                   { 1, 1 }
--   and                  { 2, 2 }
--   < > <= >= ~= ==      { 3, 3 }
--   ..                   { 5, 4 }
--   + -                  { 6, 6 }
--   * / %                { 7, 7 }
--   unary not # -        8 (the priority of the operand)
--   ^                    { 10, 9 }
--
-- So -x ^ 2 is -(x ^ 2) and 2 ^ -3 is 2 ^ (-3).
--
-- Differences from Lua 5.1
--
-- The grammar accepts every source that Lua 5.1 accepts, and some that it
-- rejects. The grammar describes the syntax only. The parser of Lua 5.1
-- also makes checks that are not syntax, and its lexer rejects some tokens
-- as a whole, so the grammar accepts these sources although luac -p of Lua
-- 5.1 rejects them (each is a case in test/grammars/lua51/):
--
--   f() = 1                  a call cannot be assigned; here an exprstat
--                            with "="
--   x                        a statement must be an assignment or a call;
--                            here an exprstat without "=" and without args
--                            at its end
--   this file is categorized as file
--                            plain text parses as six exprstats
--   goto continue            goto is a name in Lua 5.1; two exprstats
--   break outside a loop     "no loop to break"; a breakstat
--   function f() return ... end
--                            "cannot use '...' outside a vararg
--                            function"; "..." as an expression
--   x = "\300"               "escape sequence too large"; a string token,
--                            whose escapes are the consumer's to check
--   x = 3e                   "malformed number"; the number 3 and the name
--                            e, two exprstats
--   a = b, a new line, (f)() "ambiguous syntax"; a call b(f)() (_suffix*+)
--
-- A consumer that needs the official behavior checks the event array: an
-- exprstat must have "=" or end with args, and so on. Other differences:
--
--   - Shebang: this grammar rejects a first line that starts with "#", as
--     the parser of Lua 5.1 does; "lexogram:lua51_shebang" reads files as
--     the file loader does.
--   - Letters of names: the lexer of Lua 5.1 takes the letters of the C
--     locale (isalpha); the grammar takes the ASCII letters. They are the
--     same in the default C locale.
--   - Unterminated tokens: an unclosed string or long bracket is an error
--     in both. Here the quote of an unclosed short string is an INVALID
--     token (a syntax_error), and an unclosed long bracket is an
--     unterminated_token error.
--   - Bytes above 127: Lua 5.1 accepts them in strings, comments and long
--     brackets, as this grammar does; outside them both reject them (in
--     the C locale).
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
        -- backslash-newline continuation); a line break without a
        -- backslash cannot be inside it, so the quote of an unclosed
        -- string is INVALID
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
        -- suffixes; a "(" after it is always taken as call arguments, even
        -- at the start of a line, as in the official parser (which reports
        -- such a call that starts a new line as ambiguous syntax)
        suffixedexp = [[ _primaryexp _suffix*+ ]],
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
}))
