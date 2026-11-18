# Lua 5.2 grammar

The built-in grammars of Lua 5.2. `lua52` extends [`lua51`](lua51.md) with the changes of the Lua 5.2 reference manual (section 9, the complete syntax, and section 3.1, the lexical conventions) and of its lexer and parser (`llex.c`, `lparser.c`). The sections below follow the top-level fields of the grammar files `grammars/lua52.lua` and `grammars/lua52_shebang.lua`; each tells what changes from `lua51`, and what does not change is described in [the Lua 5.1 grammar](lua51.md). [The grammar format](../grammar.md) describes what each field means.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:lua52'))))
local result = assert(lexogram.parse(compiled, 'goto done ::done::'))
```

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a file is, `extends` names the grammar it is a difference of, and `embeds` the [mixin](../grammar.md#mixins) it embeds.

| Field | `lua52` | `lua52_shebang` |
|---|---|---|
| `extends` | `'lexogram:lua51'` | `'lexogram:lua52'` |
| `embeds` | — | `{ 'lexogram:bom_shebang' }` |
| `lexogram` | `'2026.11.15.1'` | `'2026.11.15.1'` |
| `name` | `'lua52'` | `'lua52_shebang'` |
| `version` | `'1.0.0'` | `'1.0.0'` |
| Built-in name | `lexogram:lua52` | `lexogram:lua52_shebang` |
| Module | `lexogram.grammars.lua52` | `lexogram.grammars.lua52_shebang` |

`lua52` accepts the syntax as the parser of Lua 5.2 does (`load`). `lua52_shebang` is `lua52` with a UTF-8 byte order mark and a first line that starts with `#` skipped, as the file loader of Lua 5.2 (`luaL_loadfilex`, `lua`, `luac`) reads files; it differs from `lua52` only in the `tokens`, `skip` and `leading` fields, which the built-in mixin `lexogram:bom_shebang` (module `lexogram.grammars.bom_shebang`) adds: it extends `lexogram:shebang`, the mixin of `lua51_shebang`, and replaces its token.

## start

`chunk`, as in `lua51`.

## tokens

Three tokens and the fragment `_escape` change, `_integer` replaces `_decimal`, and the other tokens are those of [`lua51`](lua51.md#tokens).

| Token | Lua 5.2 |
|---|---|
| `number` | A hexadecimal number may also have a fractional part and a binary exponent: `0x1.8p3`, `0xA.Fp-2`, `0x.8`, `0X1P+4`. The lexer of Lua 5.2 reads hexadecimal digits and dots with exponent marks (`e` or `E`, `p` or `P` after `0x`) and their signs, and rejects the whole run unless it is one number; so a decimal number is not followed by `(?![0-9A-Fa-f.])` and a hexadecimal one by `(?![0-9A-Fa-fPp.])`. `3e`, `1..2`, `1e5..x`, `0x` and `0x1p` are no numbers; `3print` is the number `3` and the name `print`, as in Lua 5.2 |
| `string` | A backslash may be followed only by an escape of Lua 5.2 (`_escape`); any other escape, such as `\q`, is an error, as in the lexer of Lua 5.2 |
| `_escape` | Fragment: `\a \b \f \n \r \t \v \\ \" \'`, a backslash and a line break (`\r\n`, `\n\r`, `\n` or `\r`), `\xXX` (exactly two hexadecimal digits), `_decimal_escape` of [`lua51`](lua51.md#tokens) (up to three digits, up to 255), and `\z`, which skips the white space and line breaks after it |
| `_integer` | Fragment: the digits of a decimal number, `"0" (?![xX]) DIGIT* \| [1-9] DIGIT*`: a first `0` followed by `x` or `X` starts a hexadecimal number instead, also after a dot (`.0x` is no number) |
| `long_string` | `nest` is removed: a `[[` inside a long bracket of level 0 is ordinary text. `long_comment` reads its body as a `long_string`, so a `[[` inside `--[[ ... ]]` is ordinary text too |
| `shebang` | `lua52_shebang` only: a byte order mark, a line that starts with `#`, or a byte order mark and such a line (a leading token, see `leading`). The token keeps the name of `lua51_shebang`, although it may be or begin with a byte order mark: the file loader of Lua 5.2 removes a byte order mark before it looks for the `#` line. For the operating system, a byte order mark before `#!` makes the shebang line unusable; Lua reads such a file all the same |

## symbols

The symbols of `lua51` and one more, for labels:

```ebnf
label = "::"
```

## keywords

The keywords of `lua51` and one more, so that `goto` is no longer a name:

```ebnf
keywords = "goto"
```

## skip

The tokens that may appear anywhere between the elements of the rules: as in `lua51`, and `shebang` in `lua52_shebang`.

| `lua52` | `lua52_shebang` |
|---|---|
| `space`, `comment`, `long_comment` | the same and `shebang` |

## leading

The tokens that are tried at the start of the input only. `lua52` has none; `lua52_shebang` reads what the file loader skips as `shebang`. Two leading tokens cannot follow each other, so a byte order mark and a `#` line are one token.

| `lua52` | `lua52_shebang` |
|---|---|
| — | `shebang` |

## rules

A block is any number of statements and a final `return`: `break` becomes an ordinary statement that may be followed by others, `;` alone is an empty statement, and `goto` and labels are added, as in the parser of Lua 5.2. The other rules are those of [`lua51`](lua51.md#rules).

| Rule | Syntax | Change |
|---|---|---|
| `block` | `_stat* retstat?` | replaced |
| `retstat` | `"return" explist? ";"?` | replaced |
| `labelstat` | `"::" name "::"` | added |
| `gotostat` | `"goto" name` | added |
| `_stat` | `";" \| exprstat \| dostat \| whilestat \| repeatstat \| ifstat \| forstat \| funcstat \| localfunc \| localstat \| labelstat \| gotostat \| breakstat` | replaced |
| `_laststat` | | removed |

An empty statement is a `;` token directly inside `block`, as a `;` after a statement is in `lua51`; the parser of Lua 5.2 does not make a node for it either.

A `(` after an expression is always read as call arguments, even at the start of a line (the possessive `_suffix*+` of `suffixedexp`, as in `lua51`); unlike Lua 5.1, the parser of Lua 5.2 does the same without an error.

## recover

None, as in `lua51`: the first syntax error stops the analysis.

## Telling constructs apart

As in [`lua51`](lua51.md#telling-constructs-apart), and:

- **goto and labels**: `gotostat` and `labelstat`; the label name is the `name` token inside.
- **break**: a `breakstat`, anywhere in a block.
- **Empty statements**: `;` tokens directly inside `block` that do not follow a statement.

## Expressions

The operators and their priorities are those of [`lua51`](lua51.md#expressions); Lua 5.2 adds no operator.

## Differences from Lua 5.2

The grammars accept every source that Lua 5.2 accepts, and some that it rejects. As in `lua51`, the checks that are not syntax are not made; Lua 5.2 adds checks of `goto` that are not syntax either. Each is a case in `test/grammars/lua52/`, compared with `luac` by `test/grammars/lua52_conformance_test.lua`:

| Source | Lua 5.2 | lexogram |
|---|---|---|
| `f() = 1` | syntax error: a call cannot be assigned | an `exprstat` with `=` |
| `x` | syntax error: a statement must be an assignment or a call | an `exprstat` without `=` and without `args` at its end |
| `break` outside a loop | `<break> ... not inside a loop` | a `breakstat` |
| `function f() return ... end` | `cannot use '...' outside a vararg function` | `...` as an expression |
| `goto continue` without the label | `no visible label 'continue' for <goto>` | a `gotostat` |
| `do goto l; local a = 1 ::l:: print(a) end` | `<goto l> ... jumps into the scope of local 'a'` | a `gotostat` and a `labelstat` |
| `::a:: ::a::` | `label 'a' already defined` | two `labelstat`s |

The other differences of `lua51` (letters of names, unterminated tokens, bytes above 127) apply as well, with the byte order mark of the file loader added to the shebang: `lua52` rejects both, as the parser of Lua 5.2 does; use `lua52_shebang` for files.

## Conformance

On 2026-11-18 the grammars agreed with `luac -p` of Lua 5.2.4 on all 27 files of the official Lua 5.2 test suite, and on 7,904 of 7,908 Lua files of this and nearby repositories; the official compiler accepted no file that `lua52` rejects (with a byte order mark and a first `#` line blanked) or that `lua52_shebang` rejects, and the other four files were plain text. `tools/conformance.lua` repeats the comparison:

```sh
find . -name '*.lua' | lua tools/conformance.lua --strip-bom --strip-shebang lexogram:lua52 /path/to/luac5.2
find . -name '*.lua' | lua tools/conformance.lua lexogram:lua52_shebang /path/to/luac5.2
```

The numbers and the escapes were also compared with `load` of Lua 5.2.4 on 2026-11-18, in parentheses so that the pieces of a split token cannot form valid syntax (`x = (...)`): all 444,604 numeral-like sources (up to five characters of digits, `a`, `e`, `f`, `x`, `p`, `.`, `+`, `-`, `_` and `g`) and all 137,570 escape-like strings (a backslash and up to four characters) agreed.

## Performance

`lua bench/tokenize.lua lexogram:lua52` and `lua bench/parse.lua lexogram:lua52` measure the grammar as for [`lua51`](lua51.md#performance) (best of 5 in one process, CPU time, 2026-11-18, local machine). On LuaJIT the speed differs between processes, as the traces that the compiler chooses differ; the range of five processes is shown.

| Runtime | Compile | Tokenize | Parse to the event array |
|---|---|---|---|
| Lua 5.1 | 0.27 s | 5.2 MB/s | 2.4 MB/s |
| Lua 5.4 | 0.22 s | 7.3 MB/s | 3.4 MB/s |
| Lua 5.5 | 0.21 s | 7.2 MB/s | 3.4 MB/s |
| LuaJIT 2.1 | 0.13 s | 104 to 110 MB/s | 23 to 32 MB/s |
