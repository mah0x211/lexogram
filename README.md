# lexogram

> **Status: under development.** lexogram has not been released. The grammar format, the API, the result and the built-in grammars change without notice, and nothing is promised yet. Do not use it in your projects until the first release. Pull requests and issues are not accepted for now.

A grammar-driven lexical and syntactic analyzer in pure Lua. lexogram reads a grammar written as a Lua table, splits a source into tokens and parses it into a lossless event array.

```lua
local lexogram = require('lexogram')

local compiled = assert(lexogram.compile({
    lexogram = '2026.11.15.1',
    name = 'calc',
    version = '1.0.0',
    start = 'expr',
    tokens = {
        number = [[ DIGIT+ ("." DIGIT+)? ]],
        space = [[ [ \t\r\n]+ ]],
    },
    symbols = { '+', '-', '*', '/', '(', ')' },
    skip = { 'space' },
    rules = {
        expr = [[ term (binop term)* ]],
        term = [[ number | "(" expr ")" ]],
        binop = [[ "+" | "-" | "*" | "/" ]],
    },
}))
local result = assert(lexogram.parse(compiled, '1 + (2 * 3)'))

-- result.count  --> 27 (events)
-- result.events --> four integers for each event:
--   TOKEN (1): kind, start, position after it
--   ENTER (2): kind, start, number of its EXIT event
--   EXIT  (3): kind, position after it, number of its ENTER event
-- {
--     2, 12, 1, 27,  -- 1  ENTER expr    (EXIT is event 27)
--     2, 13, 1, 4,   -- 2  ENTER term    (EXIT is event 4)
--     1, 3, 1, 2,    -- 3  TOKEN number  "1"
--     3, 13, 2, 2,   -- 4  EXIT  term
--     1, 4, 2, 3,    -- 5  TOKEN space   " "
--     2, 11, 3, 8,   -- 6  ENTER binop
--     1, 5, 3, 4,    -- 7  TOKEN "+"
--     3, 11, 4, 6,   -- 8  EXIT  binop
--     ...
--     3, 12, 12, 1,  -- 27 EXIT  expr
-- }
-- The kinds are compiled.kinds[id]: 3 number, 4 space, 5 "+", 11 binop,
-- 12 expr, 13 term, ...
--
-- As a tree (`lexogram parse --format tree`):
-- expr
--   term
--     number "1"
--   space " "
--   binop
--     "+"
--   space " "
--   term
--     "("
--     expr
--       term
--         number "2"
--       space " "
--       binop
--         "*"
--       space " "
--       term
--         number "3"
--     ")"
```

## Goals

- **A simple notation close to EBNF.** Tokens and rules are written in one small notation: literals, references, sequences, choices, repetitions, counts (`{n,m}`), aliases (`(P)->name`) and prefix matches (`#X`). lexogram does not bring in the notation of a regular expression engine.
- **Complex analysis through structured settings, not notation.** What a small notation cannot say is said by the fields of the grammar table: delimited token tables for strings and comments, prefixed tables, leading tokens, contextual keywords, grammars that extend others, and mixins. A new feature is added as a setting first; a new operator is the last resort, and only the minimum one.
- **A lossless result.** The result is a flat array of integers, four for each event (a token, the start of a rule, its end). The tokens cover the source in order, without gaps or overlaps, including white space and comments, so a tool can rebuild the source byte for byte.
- **Predictable cost.** A grammar is checked and compiled into tables before parsing: a deterministic lexer that chooses the longest match, and an LL(2) parser that chooses between alternatives by the next two tokens. Ordered choice (`/`) tries alternatives only where a grammar asks for it.
- **Pure Lua.** Lua 5.1 to 5.5 and LuaJIT 2.1, with no other module.

If a task needs a full regular expression engine or semantic analysis inside the parser, another tool will serve it better: keeping the notation small is what lexogram is for.

## Notation

`tokens` and `rules` share one notation. This is all of it:

```text
Tokens and rules
  "abc"                      literal (in rules, one declared in symbols or keywords)
  name                       reference (in tokens, built-in classes and fragments;
                             in rules, tokens and rules)
  A B                        sequence
  A | B                      choice, independent of order
  (A)                        grouping
  A?   A*   A+               optional, zero or more, one or more
  A{n}   A{n,}   A{n,m}      exactly n, at least n, from n to m times

Tokens only
  [a-z_]   [^"\\]            character class, negated class
  ALPHA DIGIT HEXDIGIT ANY   built-in classes (ANY is any one byte)
  (?=A)   (?!A)              lookahead, positive and negative: consumes nothing
  _name                      fragment: a pattern for other patterns, not a token

Rules only
  A / B                      ordered choice: tried in order
  A?+  A*+  A++  A{n,}+  A{n,m}+
                             possessive: take the element where it is ambiguous
  (A)->name                  alias: report the range of A as the rule name
  #"abc"   #name             prefix match: the next token, or a part at its
                             start (a ">" out of ">>" in Vec<Vec<u8>>)
  _name                      helper rule: produces no events
```

## A grammar at a glance

What the notation does not say, the fields of the grammar say. A small grammar that uses each of them:

```lua
return {
    lexogram = '2026.11.15.1',  -- the revision of the grammar format
    name = 'toy',
    version = '1.0.0',
    start = 'chunk',            -- the rule that must cover the whole input
    -- extends = 'lexogram:lua54',  -- write only the differences from another grammar
    -- embeds = { 'my_mixin' },     -- apply mixins: parts shared between grammars
    tokens = {
        -- a pattern token
        name = [[ (ALPHA | "_") (ALPHA | DIGIT | "_")* ]],
        -- a fragment
        _digits = [[ DIGIT+ ]],
        -- an array of patterns, checked in stages: the first pattern chooses
        -- the token, and the others check its exact form. The first takes the
        -- whole run that looks like a number, so "12abc" or "1.2.3" is one
        -- invalid number, reported where it starts, instead of "12" followed
        -- by the name "abc"; the check states the form apart, and each pattern
        -- stays simple
        number = {
            [[ DIGIT (ALPHA | DIGIT | "_" | ".")* ]],
            [[ _digits ("." _digits)? ]],
        },
        string = [[ "\"" ([^"\\\n] | "\\" ANY)* "\"" ]],
        -- a delimited token table: the close repeats the level of the open
        long_string = {
            open = [[ "[" level "[" ]],
            close = [[ "]" level "]" ]],
            level = [[ "="* ]],
        },
        -- a prefixed table: "--" followed by a long string
        long_comment = { prefix = [[ "--" ]], match = { 'long_string' } },
        comment = [[ "--" ([^[\n] [^\n]*)? ]],
        shebang = [[ "#!" [^\n]* ]],
        space = [[ [ \t\r\n]+ ]],
    },
    symbols = { '=', ',', '(', ')', ';' },
    -- "global" is a keyword only where a rule expects it, and a name elsewhere
    keywords = { 'local', contextual = { 'global' } },
    skip = { 'space', 'comment', 'long_comment', 'shebang' },
    leading = { 'shebang' },    -- tried at the start of the input only
    rules = {
        chunk = [[ (stat ";"?)* ]],
        stat = [[ global_stat / local_stat / call ]],
        global_stat = [[ "global" name ]],
        local_stat = [[ "local" name ("," name)* ("=" _explist)? ]],
        call = [[ name "(" _explist? ")" ]],
        _explist = [[ exp ("," exp)* ]],
        exp = [[ number | string | long_string | call | (name)->var ]],
        var = [[ name ]],
    },
}
```

## Scope

lexogram applies the rules of a grammar and nothing else. It does not track symbols or types, evaluate expressions, or build an abstract syntax tree: a consumer of the event array does that. The grammars of Lua 5.1 to 5.5, LuaJIT, C99, C11 and C23 that ship with lexogram are samples to test it on real languages and to copy as starting points; they make no promise of compatibility.

Error recovery is not implemented yet: the first syntax error stops the analysis.

## Installation

From a clone of this repository:

```sh
luarocks make rockspecs/lexogram-scm-1.rockspec
```

This installs the library and the `lexogram` command.

## Documentation

- [Grammar files](doc/grammar.md): the grammar format, the notation, how tokens are chosen and how rules are applied.
- [The lexogram command](doc/command.md): checking grammars, copying built-in ones, saving compiled grammars and parsing from the shell.
- [Built-in grammars](doc/grammars/): one document for each, with measurements.

## License

MIT License. See [LICENSE](LICENSE).
