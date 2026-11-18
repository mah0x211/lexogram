# Lua 5.3 grammar

The built-in grammars of Lua 5.3. `lua53` extends [`lua52`](lua52.md) with the changes of the Lua 5.3 reference manual (section 9, the complete syntax, and section 3.1, the lexical conventions) and of its lexer and parser (`llex.c`, `lparser.c`). The sections below follow the top-level fields of the grammar files `grammars/lua53.lua` and `grammars/lua53_shebang.lua`; each tells what changes from `lua52`, and what does not change is described in [the Lua 5.2 grammar](lua52.md) and [the Lua 5.1 grammar](lua51.md). [The grammar format](../grammar.md) describes what each field means.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:lua53'))))
local result = assert(lexogram.parse(compiled, 'return a // b & ~c'))
```

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a file is, `extends` names the grammar it is a difference of, and `embeds` the [mixin](../grammar.md#mixins) it embeds.

| Field | `lua53` | `lua53_shebang` |
|---|---|---|
| `extends` | `'lexogram:lua52'` | `'lexogram:lua53'` |
| `embeds` | — | `{ 'lexogram:bom_shebang' }` |
| `lexogram` | `'2026.11.15.1'` | `'2026.11.15.1'` |
| `name` | `'lua53'` | `'lua53_shebang'` |
| `version` | `'1.0.0'` | `'1.0.0'` |
| Built-in name | `lexogram:lua53` | `lexogram:lua53_shebang` |
| Module | `lexogram.grammars.lua53` | `lexogram.grammars.lua53_shebang` |

`lua53` accepts the syntax as the parser of Lua 5.3 does (`load`). `lua53_shebang` is `lua53` with a UTF-8 byte order mark and a first line that starts with `#` skipped, as the file loader of Lua 5.3 (`luaL_loadfilex`, `lua`, `luac`) reads files, the same as in Lua 5.2; it differs from `lua53` only in the `tokens`, `skip` and `leading` fields, which the built-in mixin `lexogram:bom_shebang` adds, as for [`lua52_shebang`](lua52.md#tokens).

## start

`chunk`, as in `lua51`.

## tokens

One fragment changes; the other tokens are those of [`lua52`](lua52.md#tokens).

| Token | Lua 5.3 |
|---|---|
| `_escape` | Fragment: the escapes of `lua52`, and `\u{XXX}`: one or more hexadecimal digits in braces, the UTF-8 encoding of a code point (`\u{48}`, `\u{10FFFF}`) |
| `shebang` | `lua53_shebang` only: as in `lua52_shebang` (from the mixin `lexogram:bom_shebang`) |

A numeral is written as in Lua 5.2. Whether it denotes an integer or a float (`3` or `3.0`, and an integer that does not fit becomes a float) depends on its text and value, not on the token, which is `number` either way.

## symbols

The symbols of `lua52`, and the operators of integer division and of bitwise operations:

```ebnf
integer_division = "//"
bitwise = "&" | "~" | "|" | "<<" | ">>"
```

`~` is the binary exclusive or and the unary not of bits. `~=` is still one token: the longest match wins, so `a ~= b` compares and `a ~ = b` is an error, as in Lua 5.3.

## keywords

The keywords of `lua52`.

## skip

As in `lua52`.

| `lua53` | `lua53_shebang` |
|---|---|
| `space`, `comment`, `long_comment` | the same and `shebang` |

## leading

As in `lua52`.

| `lua53` | `lua53_shebang` |
|---|---|
| — | `shebang` |

## rules

Two rules are replaced, for the new operators; the other rules are those of [`lua52`](lua52.md#rules).

| Rule | Syntax | Change |
|---|---|---|
| `unop` | `"-" \| "not" \| "#" \| "~"` | replaced |
| `binop` | `"+" \| "-" \| "*" \| "/" \| "//" \| "^" \| "%" \| "&" \| "~" \| "\|" \| ">>" \| "<<" \| ".." \| "<" \| "<=" \| ">" \| ">=" \| "==" \| "~=" \| "and" \| "or"` | replaced |

## recover

None, as in `lua52`: the first syntax error stops the analysis.

## Telling constructs apart

As in [`lua52`](lua52.md#telling-constructs-apart), and:

- **Integer division and bitwise operators**: a `binop` whose token is `//`, `&`, `~`, `|`, `<<` or `>>`.
- **Unary not of bits**: a `unop` whose token is `~`.

## Expressions

The terms and operators of an expression are listed flat, as in [`lua51`](lua51.md#expressions); the priorities `{ left, right }` of the Lua 5.3 parser build the tree, from low to high (a right priority below the left one makes the operator right associative):

| Operators | Priority |
|---|---|
| `or` | `{ 1, 1 }` |
| `and` | `{ 2, 2 }` |
| `<` `>` `<=` `>=` `~=` `==` | `{ 3, 3 }` |
| `\|` | `{ 4, 4 }` |
| `~` | `{ 5, 5 }` |
| `&` | `{ 6, 6 }` |
| `<<` `>>` | `{ 7, 7 }` |
| `..` | `{ 9, 8 }` |
| `+` `-` | `{ 10, 10 }` |
| `*` `/` `//` `%` | `{ 11, 11 }` |
| unary `not` `#` `-` `~` | `12` (the priority of the operand) |
| `^` | `{ 14, 13 }` |

`test/grammars/lua53_expression_test.lua` builds the trees from the event array and this table alone, and compares the value of random integer expressions with the running Lua where it has these operators.

## Differences from Lua 5.3

The grammars accept every source that Lua 5.3 accepts, and some that it rejects: those of [`lua52`](lua52.md#differences-from-lua-52), and one more check of a value. Each is a case in `test/grammars/lua53/`, compared with `luac` by `test/grammars/lua53_conformance_test.lua`:

| Source | Lua 5.3 | lexogram |
|---|---|---|
| `x = "\u{110000}"` | `UTF-8 value too large` | a `string` token; the value of an escape is the consumer's to check |

## Conformance

On 2026-11-18 the grammars agreed with `luac -p` of Lua 5.3.6 on all 28 files of the official Lua 5.3 test suite (5.3.4), and on 7,904 of 7,908 Lua files of this and nearby repositories; the official compiler accepted no file that `lua53` rejects (with a byte order mark and a first `#` line blanked) or that `lua53_shebang` rejects, and the other four files were plain text, as for [`lua51`](lua51.md#conformance). `tools/conformance.lua` repeats the comparison:

```sh
find . -name '*.lua' | lua tools/conformance.lua --strip-bom --strip-shebang lexogram:lua53 /path/to/luac5.3
find . -name '*.lua' | lua tools/conformance.lua lexogram:lua53_shebang /path/to/luac5.3
```

## Performance

`lua bench/tokenize.lua lexogram:lua53` and `lua bench/parse.lua lexogram:lua53` measure the grammar as for [`lua51`](lua51.md#performance) (best of 5 in one process, CPU time, 2026-11-18, local machine). On LuaJIT the speed differs between processes, as the traces that the compiler chooses differ; the range of five processes is shown.

| Runtime | Compile | Tokenize | Parse to the event array |
|---|---|---|---|
| Lua 5.1 | 0.24 s | 5.8 MB/s | 2.6 MB/s |
| Lua 5.4 | 0.19 s | 7.9 MB/s | 3.6 MB/s |
| Lua 5.5 | 0.20 s | 7.8 MB/s | 3.5 MB/s |
| LuaJIT 2.1 | 0.13 s | 101 to 104 MB/s | 21 to 32 MB/s |
