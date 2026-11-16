-- Lua 5.1 lexical grammar (reference manual section 2.1), used as a
-- benchmark and test fixture for the tokenizer. It is NOT the real Lua
-- grammar of lexogram: rules is a trivial chunk that accepts any sequence
-- of tokens and literals (an unordered choice, decided by one token), only
-- so that the grammar compiles without errors and warnings and the parse
-- benchmark measures the analyzer on every token.
return {
    lexogram = '2026.11.15.1',
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
        long_string = {
            open = [[ "[" level "[" ]],
            close = [[ "]" level "]" ]],
            level = [[ "="* ]],
        },
        long_comment = {
            open = [[ "--[" level "[" ]],
            close = [[ "]" level "]" ]],
            level = [[ "="* ]],
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
        chunk = [[ item* ]],
        item = [[
            name | number | string | long_string
            | "+" | "-" | "*" | "/" | "%" | "^" | "#"
            | "==" | "~=" | "<=" | ">=" | "<" | ">" | "="
            | "(" | ")" | "{" | "}" | "[" | "]" | ";" | ":" | ","
            | "." | ".." | "..."
            | "and" | "break" | "do" | "else" | "elseif" | "end"
            | "false" | "for" | "function" | "if" | "in" | "local"
            | "nil" | "not" | "or" | "repeat" | "return" | "then"
            | "true" | "until" | "while"
        ]],
    },
}
