# Lua 5.1 grammar

The built-in grammars of Lua 5.1. The rules follow the complete syntax of Lua in section 8 of the Lua 5.1 reference manual; rule names come from the manual and from the Lua 5.1 parser (`lparser.c`). Together with the token names they are a public contract with consumers: a change that breaks it is listed in [the changes](#changes).

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:lua51'))))
local result = assert(lexogram.parse(compiled, 'local n = #t'))
```

The sections below follow the top-level fields of the grammar files `grammars/lua51.lua` and `grammars/lua51_shebang.lua`; [the grammar format](../grammar.md) describes what each field means.

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a file is: the revision of the lexogram specification it follows, its name (also its built-in name), and its own version. `lua51_shebang` names the grammar it extends in `extends`, and the [mixin](../grammar.md#mixins) it embeds in `embeds`.

| Field | `lua51` | `lua51_shebang` |
|---|---|---|
| `lexogram` | `'2026.11.15.1'` | `'2026.11.15.1'` |
| `name` | `'lua51'` | `'lua51_shebang'` |
| `version` | `'5.1.5-1'` | `'5.1.5-1'` |
| `extends` | — | `'lexogram:lua51'` |
| `embeds` | — | `{ 'lexogram:shebang' }` |
| Built-in name | `lexogram:lua51` | `lexogram:lua51_shebang` |
| Module | `lexogram.grammars.lua51` | `lexogram.grammars.lua51_shebang` |

The version is `5.1.5-1`: the release of Lua 5.1 that the grammar was checked against, and the revision of the grammar, as for every built-in grammar (see [the grammar format](../grammar.md#metadata)). A change that breaks the rule names or the token names is listed in [the changes](#changes).

`lua51` accepts the syntax as the parser of Lua 5.1 does (`loadstring`). `lua51_shebang` is `lua51` with a first line that starts with `#` skipped, as the file loader of Lua 5.1 (`luaL_loadfile`, `lua`, `luac`) reads files; it differs from `lua51` only in the `tokens`, `skip` and `leading` fields, which the built-in mixin `lexogram:shebang` (module `lexogram.grammars.shebang`) adds.

## start

The rule that must cover the whole input: `chunk`, which is a `block`.

## tokens

The tokens of Lua 5.1: names, numbers, short strings, comments and white space are patterns; long strings and long comments are delimited tokens, because their close repeats the level of their open. The parts with `_` are fragments of the number and string patterns, not tokens.

Pattern tokens:

| Token | Matches |
|---|---|
| `name` | `[A-Za-z_][A-Za-z0-9_]*` |
| `number` | `3`, `3.0`, `3.`, `.5`, `314.16e-2`, `0x56`, `0x1p4`, written as an [array of two patterns](../grammar.md#arrays-of-patterns). The first is the run that the lexer of Lua 5.1 reads: digits and dots, an exponent mark with its sign, then letters, digits and `_`. The second is the forms that `strtod` must read from all of it: `_decimal _exponent?`, or `0x` and hexadecimal digits with an optional `p` and decimal digits. A run of another form is an `invalid_token` error (Lua 5.1 reports a malformed number): `3e`, `1..2`, `3print` and `0x1p+4`. `1e5..x` is `1e5 .. x`, as an exponent ends the dots |
| `string` | `"..."` and `'...'` with `_escape`; a line break without a backslash cannot be inside it |
| `comment` | `--` and the rest of the line |
| `space` | Space, tab, carriage return, line feed, vertical tab and form feed |
| `shebang` | `lua51_shebang` only: `#` and the rest of the line (a leading token, see `leading`) |

Fragments (parts of the patterns above, not tokens):

| Fragment | Matches |
|---|---|
| `_decimal` | `_digits ("." DIGIT*)? \| "." _digits` |
| `_digits` | `DIGIT+` |
| `_exponent` | `[eE] ("+" \| "-")? _digits` |
| `_escape` | A backslash and a line break (`\r\n`, `\n\r`, `\n` or `\r`), any other byte that is no digit (`\n`, `\\`, `\q`), or `_decimal_escape` |
| `_decimal_escape` | One to three digits, as many as there are, up to 255 (`\0`, `\65`, `\255`; `\256` is an error, as in Lua 5.1) |

Delimited token tables:

| Token | Table | Matches |
|---|---|---|
| `long_string` | `open = "[["`, `close = "]]"`, `nest = 'error'` | A long bracket of level 0; a `[[` inside it is an error (`nested_delimiter`), as in the lexer of Lua 5.1 |
| `long_string_level` | `open = "[" level "["`, `close = "]" level "]"`, `level = "="+` | A long bracket with `=` (`[=[ ... ]=]`, `[==[ ... ]==]`, ...); an open inside it is ordinary text |
| `long_comment` | `prefix = "--"`, `match = { 'long_string', 'long_string_level' }` | `--` followed by either of them, so that its body is read the same way: a `[[` inside `--[[ ... ]]` is an error |

## symbols

The punctuation of Lua 5.1, 26 literals. Rules refer to them as literals (`"+"`, `"=="`, ...). In the notation below, `|` separates the items; the names on the left only group them for reading, and the grammar lists all of them in one array:

```ebnf
arithmetic  = "+" | "-" | "*" | "/" | "%" | "^"
length      = "#"
comparison  = "==" | "~=" | "<=" | ">=" | "<" | ">"
assignment  = "="
brackets    = "(" | ")" | "{" | "}" | "[" | "]"
separators  = ";" | ":" | "," | "."
dots        = ".." | "..."
```

## keywords

The reserved words of Lua 5.1, 21 literals. A name that is one of them is the keyword, not a `name` token (a literal wins over a pattern token of the same length).

```ebnf
keywords = "and" | "break" | "do" | "else" | "elseif" | "end" | "false"
         | "for" | "function" | "if" | "in" | "local" | "nil" | "not"
         | "or" | "repeat" | "return" | "then" | "true" | "until" | "while"
```

## skip

The tokens that may appear anywhere between the elements of the rules: white space and comments, and in `lua51_shebang` also the shebang line.

| `lua51` | `lua51_shebang` |
|---|---|
| `space`, `comment`, `long_comment` | the same and `shebang` |

The tokens in `skip` are skipped between the elements of the rules, so that no rule has to mention them, but they are still TOKEN events of the event array (their kind has `skip = true` in the kind table), placed outside the ranges of the rules: the events cover the whole source.

## leading

The tokens that are tried at the start of the input only. `lua51` has none; `lua51_shebang` reads a first line that starts with `#` as `shebang`.

| `lua51` | `lua51_shebang` |
|---|---|
| — | `shebang` |

A leading token is tried at the start of the input only, before every other token. In `lua51_shebang`, a first line that starts with `#` is the token `shebang` (in `skip`); a `#` anywhere else is the length operator.

## rules

The syntax of Lua 5.1. The rules without `_` are the structures that a consumer sees: each statement kind, the parts of a function and a table constructor, the expression with its operators, a suffixed expression and call arguments. The rules with `_` group alternatives and produce no events.

Rules with events (an ENTER and an EXIT around their range):

| Rule | Syntax |
|---|---|
| `chunk` | `block` |
| `block` | `(_stat ";"?)* (_laststat ";"?)?` |
| `exprstat` | `suffixedexp (("," suffixedexp)* "=" explist)?`: an assignment or a function call |
| `dostat` | `"do" block "end"` |
| `whilestat` | `"while" exp "do" block "end"` |
| `repeatstat` | `"repeat" block "until" exp` |
| `ifstat` | `"if" exp "then" block ("elseif" exp "then" block)* ("else" block)? "end"` |
| `forstat` | `"for" (fornum \| forlist)` |
| `fornum` | `name "=" exp "," exp ("," exp)? "do" block "end"` |
| `forlist` | `namelist "in" explist "do" block "end"` |
| `funcstat` | `"function" funcname body` |
| `localfunc` | `"local" "function" name body` |
| `localstat` | `"local" namelist ("=" explist)?` |
| `retstat` | `"return" explist?` |
| `breakstat` | `"break"` |
| `funcname` | `name ("." name)* (":" name)?` |
| `namelist` | `name ("," name)*` |
| `explist` | `exp ("," exp)*` |
| `exp` | `unop* _simpleexp (binop unop* _simpleexp)*`: terms and operators in order, without precedence |
| `unop` | `"-" \| "not" \| "#"` |
| `binop` | `"+" \| "-" \| "*" \| "/" \| "^" \| "%" \| ".." \| "<" \| "<=" \| ">" \| ">=" \| "==" \| "~=" \| "and" \| "or"` |
| `suffixedexp` | `_primaryexp _suffix*+`: a variable, a call or a parenthesized expression with its suffixes |
| `args` | `"(" explist? ")" \| tableconstructor \| string \| long_string \| long_string_level` |
| `functiondef` | `"function" body` |
| `body` | `"(" parlist? ")" block "end"` |
| `parlist` | `name ("," name)* ("," "...")? \| "..."` |
| `tableconstructor` | `"{" (_field (_fieldsep _field)* _fieldsep?)? "}"` |
| `recfield` | `("[" exp "]" \| name) "=" exp` |
| `listfield` | `exp` |

Rules without events (their names start with `_`; their contents belong to the enclosing rule):

| Rule | Syntax |
|---|---|
| `_stat` | `exprstat \| dostat \| whilestat \| repeatstat \| ifstat \| forstat \| funcstat \| localfunc \| localstat` |
| `_laststat` | `retstat \| breakstat` |
| `_simpleexp` | `"nil" \| "false" \| "true" \| number \| string \| long_string \| long_string_level \| "..." \| functiondef \| tableconstructor \| suffixedexp` |
| `_primaryexp` | `name \| "(" exp ")"` |
| `_suffix` | `"." name \| "[" exp "]" \| ":" name args \| args` |
| `_field` | `recfield \| listfield` |
| `_fieldsep` | `"," \| ";"` |

**Possessive repetition**: the `_suffix*+` of `suffixedexp` goes on as long as the next token can continue it, where the grammar would otherwise be ambiguous (see [How rules are applied](../grammar.md#how-rules-are-applied)). A `(` after an expression is always read as call arguments, even at the start of a line, as the parser of Lua 5.1 does (it also reports such a call that starts a new line as ambiguous syntax; see the differences below).

## recover

The rules from which the analysis recovers after a syntax error: none, so the first syntax error stops the analysis.

## Telling constructs apart

How a consumer tells the constructs of Lua apart from the event array alone:

- **Statements**: each kind has its own rule, which includes its keywords. `for` is read by `forstat`, around `fornum` or `forlist`, which need three tokens to tell apart.
- **Assignment or call**: an `exprstat` is an assignment when it has a `=` token directly inside it.
- **Table fields**: `recfield` for `[exp] = exp` and `name = exp` (told apart by the first token), `listfield` for a bare expression.
- **Call arguments**: the first token inside `args` is `(`, a `tableconstructor`, or a string token. A method call has `:` and the method name directly before its `args` inside `suffixedexp`.
- **Parenthesized expression**: a `suffixedexp` whose direct children are `(`, an `exp` and `)`.

## Expressions

`exp` lists its terms and operators flat; a consumer applies the precedence of Lua. The priorities of the Lua 5.1 parser are, from low to high (a right priority below the left one makes an operator right associative):

| Operators | Left | Right |
|---|---|---|
| `or` | 1 | 1 |
| `and` | 2 | 2 |
| `<` `>` `<=` `>=` `~=` `==` | 3 | 3 |
| `..` | 5 | 4 |
| `+` `-` | 6 | 6 |
| `*` `/` `%` | 7 | 7 |
| unary `not` `#` `-` | 8 (operand) | |
| `^` | 10 | 9 |

So `-x ^ 2` is `-(x ^ 2)` and `2 ^ -3` is `2 ^ (-3)`. `test/grammars/lua51_expression_test.lua` builds such trees from the event array, the kind table and this table alone.

## Differences from Lua 5.1

The grammars accept every source that Lua 5.1 accepts, and some that it rejects. The grammar describes the syntax only. The parser of Lua 5.1 also makes checks that are not syntax, so the grammar accepts these sources although `luac -p` of Lua 5.1 rejects them (each is a case in `test/grammars/lua51/`, compared with `luac` by `test/grammars/lua51_conformance_test.lua`):

| Source | Lua 5.1 | lexogram |
|---|---|---|
| `f() = 1` | syntax error: a call cannot be assigned | an `exprstat` with `=` |
| `x` | syntax error: a statement must be an assignment or a call | an `exprstat` without `=` and without `args` at its end |
| `this file is categorized as file` | syntax error | six `exprstat`s of one name each: plain text can parse as Lua |
| `goto continue` | syntax error (`goto` is a name in Lua 5.1) | two `exprstat`s |
| `break` outside a loop | `no loop to break` | a `breakstat` |
| `function f() return ... end` | `cannot use '...' outside a vararg function` | `...` as an expression |
| `a = b` + new line + `(f)()` | `ambiguous syntax (function call x new statement)` | a call `b(f)()` (`_suffix*+`) |

A consumer that needs the official behavior checks the event array: an `exprstat` must have `=` or end with `args`, and so on.

Other differences:

- **Shebang**: `lua51` rejects a first line that starts with `#`, as the parser of Lua 5.1 does; use `lua51_shebang` for files.
- **Letters of names**: the lexer of Lua 5.1 takes the letters of the C locale (`isalpha`); the grammar takes the ASCII letters. They are the same in the default C locale.
- **Unterminated tokens**: an unclosed string or long bracket is an error in both. In lexogram the quote of an unclosed short string is an `INVALID` token (a `syntax_error`), and an unclosed long bracket is an `unterminated_token` error.
- **Bytes above 127**: Lua 5.1 accepts them in strings, comments and long brackets, as lexogram does; outside them both reject them (in the C locale).

## Conformance

How the grammars were compared with the official compiler. On 2026-11-18 the grammars agreed with `luac -p` of Lua 5.1.5 on all 24 files of the official Lua 5.1 test suite, and on 7,904 of 7,908 Lua files of this and nearby repositories; the official compiler accepted no file that `lua51` rejects (with a first `#` line blanked) or that `lua51_shebang` rejects, and the other four files were the plain text above. `tools/conformance.lua` repeats the comparison on any list of files:

```sh
find . -name '*.lua' | lua tools/conformance.lua --strip-shebang lexogram:lua51 /path/to/luac5.1
find . -name '*.lua' | lua tools/conformance.lua lexogram:lua51_shebang /path/to/luac5.1
```

The numbers and the escapes were also compared with `load` of Lua 5.1.5 on 2026-11-18, in parentheses so that the pieces of a split token cannot form valid syntax (`x = (...)`): all 444,604 numeral-like sources (up to five characters of digits, `a`, `e`, `f`, `x`, `p`, `.`, `+`, `-`, `_` and `g`) and all 137,570 escape-like strings (a backslash and up to four characters) agreed.

## Performance

The speed of `lua51` on each runtime. `lua bench/tokenize.lua lexogram:lua51` and `lua bench/parse.lua lexogram:lua51` measure the grammar on the library sources, each wrapped in `do ... end` and repeated to 2.17 MB (best of 5 in one process, CPU time, 2026-11-19, local machine). Load and compile is the time of the first `lexogram.load` of the grammar, which checks it and the grammars it extends (see `lexogram.grammar`), and of `lexogram.compile`, which then copies the compiled object made from that check. On LuaJIT the speed differs between processes, as the traces that the compiler chooses differ; the range of five processes is shown.

| Runtime | Load and compile | Tokenize | Parse to the event array |
|---|---|---|---|
| Lua 5.1 | 0.07 s | 5.0 MB/s (1.1 M tokens/s) | 2.3 MB/s (1.0 M events/s) |
| Lua 5.4 | 0.06 s | 7.1 MB/s | 3.2 MB/s |
| Lua 5.5 | 0.06 s | 7.0 MB/s | 3.2 MB/s |
| LuaJIT 2.1 | 0.05 s | 101 to 106 MB/s | 21 to 31 MB/s |

## Changes

| Version | Change |
|---|---|
| `5.1.5-1` | The first version (2026-11-18). |
