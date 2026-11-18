# Lua 5.4 grammar

The built-in grammars of Lua 5.4. `lua54` extends [`lua53`](lua53.md) with the changes of the Lua 5.4 reference manual (section 9, the complete syntax, and section 3.1, the lexical conventions) and of its lexer and parser (`llex.c`, `lparser.c`). The sections below follow the top-level fields of the grammar files `grammars/lua54.lua` and `grammars/lua54_shebang.lua`; each tells what changes from `lua53`, and what does not change is described in [the Lua 5.3 grammar](lua53.md), [the Lua 5.2 grammar](lua52.md) and [the Lua 5.1 grammar](lua51.md). [The grammar format](../grammar.md) describes what each field means.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:lua54'))))
local result = assert(lexogram.parse(compiled, 'local f <close> = io.open(name)'))
```

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a file is, `extends` names the grammar it is a difference of, and `embeds` the [mixin](../grammar.md#mixins) it embeds.

| Field | `lua54` | `lua54_shebang` |
|---|---|---|
| `extends` | `'lexogram:lua53'` | `'lexogram:lua54'` |
| `embeds` | — | `{ 'lexogram:bom_shebang' }` |
| `lexogram` | `'2026.11.15.1'` | `'2026.11.15.1'` |
| `name` | `'lua54'` | `'lua54_shebang'` |
| `version` | `'1.0.0'` | `'1.0.0'` |
| Built-in name | `lexogram:lua54` | `lexogram:lua54_shebang` |
| Module | `lexogram.grammars.lua54` | `lexogram.grammars.lua54_shebang` |

`lua54` accepts the syntax as the parser of Lua 5.4 does (`load`). `lua54_shebang` is `lua54` with a UTF-8 byte order mark and a first line that starts with `#` skipped, as the file loader of Lua 5.4 (`luaL_loadfilex`, `lua`, `luac`) reads files, the same as in Lua 5.2 and 5.3; it differs from `lua54` only in the `tokens`, `skip` and `leading` fields, which the built-in mixin `lexogram:bom_shebang` adds, as for [`lua52_shebang`](lua52.md#tokens).

## start

`chunk`, as in `lua51`.

## tokens

The tokens of [`lua53`](lua53.md#tokens). A `\u{XXX}` escape may now write any value below 2³¹ (`\u{7FFFFFFF}`), which Lua 5.4 checks; the token takes any number of hexadecimal digits, as in `lua53`. A hexadecimal integer that overflows wraps around, which is a matter of its value, not of the token.

## symbols

The symbols of `lua53`. The attributes of local variables are written with `<` and `>`, which are symbols already.

## keywords

The keywords of `lua53`. The names of the attributes (`const`, `close`) are names, not keywords.

## skip

As in `lua53`.

| `lua54` | `lua54_shebang` |
|---|---|
| `space`, `comment`, `long_comment` | the same and `shebang` |

## leading

As in `lua53`.

| `lua54` | `lua54_shebang` |
|---|---|
| — | `shebang` |

## rules

A local variable may have an attribute, `<const>` or `<close>`, as in the parser of Lua 5.4. One rule is replaced and two are added; the other rules are those of [`lua53`](lua53.md#rules).

| Rule | Syntax | Change |
|---|---|---|
| `localstat` | `"local" attnamelist ("=" explist)?` | replaced |
| `attnamelist` | `name attrib? ("," name attrib?)*` | added |
| `attrib` | `"<" name ">"` | added |

`namelist` stays for the generic `for`, whose names cannot have attributes; neither can the name of a `local function`.

## recover

None, as in `lua53`: the first syntax error stops the analysis.

## Telling constructs apart

As in [`lua53`](lua53.md#telling-constructs-apart), and:

- **Attributes**: an `attrib` after a name inside `attnamelist`; the attribute is the `name` token between `<` and `>`.

## Expressions

The operators and their priorities are those of [`lua53`](lua53.md#expressions): the parser of Lua 5.4 has the same table. `test/grammars/lua54_test.lua` checks that every rule other than those of local statements is that of `lua53`.

## Differences from Lua 5.4

The grammars accept every source that Lua 5.4 accepts, and some that it rejects: those of [`lua53`](lua53.md#differences-from-lua-53), with a `\u` escape at 80000000 or above in place of one above 10FFFF, and the ones below. Each is a case in `test/grammars/lua54/`, compared with `luac` by `test/grammars/lua54_conformance_test.lua`:

| Source | Lua 5.4 | lexogram |
|---|---|---|
| `x = "\u{80000000}"` | `UTF-8 value too large` | a `string` token; the value of an escape is the consumer's to check |
| `local x <other> = 1` | `unknown attribute 'other'` | an `attrib` with the name `other` |
| `local a <close>, b <close> = nil, nil` | `multiple to-be-closed variables in local list` | two `attrib`s |
| `local x <const> = 1; x = 2` | `attempt to assign to const variable 'x'` | a `localstat` and an `exprstat` |
| `x = 3print(1)` | `malformed number near '3p'` | a number, then a call of `print`: two `exprstat`s |

A numeral that touches a letter is new in Lua 5.4 (Lua 5.2 and 5.3 accept `3print(1)`); like the other malformed numbers, it is left as a difference for now.

## Conformance

On 2026-11-18 the grammars agreed with `luac -p` of Lua 5.4.8 on all 33 files of the official Lua 5.4 test suite (5.4.8), and on 7,903 of 7,908 Lua files of this and nearby repositories; the official compiler accepted no file that `lua54` rejects (with a byte order mark and a first `#` line blanked) or that `lua54_shebang` rejects. Of the other five files, four were plain text, as for [`lua51`](lua51.md#conformance), and one assigned to a `<const>` variable. `tools/conformance.lua` repeats the comparison:

```sh
find . -name '*.lua' | lua tools/conformance.lua --strip-bom --strip-shebang lexogram:lua54 /path/to/luac5.4
find . -name '*.lua' | lua tools/conformance.lua lexogram:lua54_shebang /path/to/luac5.4
```

## Performance

`lua bench/tokenize.lua lexogram:lua54` and `lua bench/parse.lua lexogram:lua54` measure the grammar as for [`lua51`](lua51.md#performance) (best of 5 in one process, CPU time, 2026-11-18, local machine). On LuaJIT the speed differs between processes, as the traces that the compiler chooses differ; the range of five processes is shown.

| Runtime | Compile | Tokenize | Parse to the event array |
|---|---|---|---|
| Lua 5.1 | 0.24 s | 5.8 MB/s | 2.5 MB/s |
| Lua 5.4 | 0.19 s | 7.8 MB/s | 3.5 MB/s |
| Lua 5.5 | 0.19 s | 7.6 MB/s | 3.5 MB/s |
| LuaJIT 2.1 | 0.11 s | 97 to 104 MB/s | 22 to 32 MB/s |
