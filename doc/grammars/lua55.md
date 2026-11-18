# Lua 5.5 grammar

The built-in grammars of Lua 5.5. `lua55` extends [`lua54`](lua54.md) with the changes of the Lua 5.5 reference manual (section 9, the complete syntax, and section 3.1, the lexical conventions) and of its lexer and parser (`llex.c`, `lparser.c`). The sections below follow the top-level fields of the grammar files `grammars/lua55.lua` and `grammars/lua55_shebang.lua`; each tells what changes from `lua54`, and what does not change is described in [the Lua 5.4 grammar](lua54.md) and the documents it refers to. [The grammar format](../grammar.md) describes what each field means.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:lua55'))))
local result = assert(lexogram.parse(compiled, 'global <const> print, x'))
```

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a file is, `extends` names the grammar it is a difference of, and `embeds` the [mixin](../grammar.md#mixins) it embeds.

| Field | `lua55` | `lua55_shebang` |
|---|---|---|
| `extends` | `'lexogram:lua54'` | `'lexogram:lua55'` |
| `embeds` | — | `{ 'lexogram:bom_shebang' }` |
| `lexogram` | `'2026.11.15.1'` | `'2026.11.15.1'` |
| `name` | `'lua55'` | `'lua55_shebang'` |
| `version` | `'5.5.1-1'` | `'5.5.1-1'` |
| Built-in name | `lexogram:lua55` | `lexogram:lua55_shebang` |
| Module | `lexogram.grammars.lua55` | `lexogram.grammars.lua55_shebang` |

The version is `5.5.1-1`: the release of Lua 5.5 that the grammar was checked against, and the revision of the grammar, as for every built-in grammar (see [the grammar format](../grammar.md#metadata)). A change that breaks the rule names or the token names is listed in [the changes](#changes).

`lua55` accepts the syntax as the parser of Lua 5.5 built by default does (`load`), where `LUA_COMPAT_GLOBAL` makes `global` no reserved word (see [keywords](#keywords)). `lua55_shebang` is `lua55` with a UTF-8 byte order mark and a first line that starts with `#` skipped, as the file loader of Lua 5.5 (`luaL_loadfilex`, `lua`, `luac`) reads files, the same as in Lua 5.2 to 5.4; it differs from `lua55` only in the `tokens`, `skip` and `leading` fields, which the built-in mixin `lexogram:bom_shebang` adds, as for [`lua52_shebang`](lua52.md#tokens).

## start

`chunk`, as in `lua51`.

## tokens

The tokens of [`lua54`](lua54.md#tokens): the lexer of Lua 5.5 reads numbers, strings and escapes as that of Lua 5.4 does (its only change is the reserved word `global`).

## symbols

The symbols of `lua54`. The declaration of every global is written with `*`, which is a symbol already.

## keywords

The keywords of `lua54`, and `global` as a [contextual keyword](../grammar.md#contextual-keywords) (`keywords.contextual`).

The reference manual lists `global` as a reserved word, as it is when Lua is built without `LUA_COMPAT_GLOBAL`. The default build defines it, and its parser takes `global` as a declaration only at the start of a statement where the next token is `<`, a name, `*` or `function`, and as a name everywhere else: `local global = 1`, `global.x = 1` and `global(1)` are valid. The grammar reads `global` as the token `name`, which is the keyword `global` where the rules below match it; in the events, such a token has the kind of the keyword, and the kind `name` elsewhere. `lexogram.tokenize` always returns `name`.

## skip

As in `lua54`.

| `lua55` | `lua55_shebang` |
|---|---|
| `space`, `comment`, `long_comment` | the same and `shebang` |

## leading

As in `lua54`.

| `lua55` | `lua55_shebang` |
|---|---|
| — | `shebang` |

## rules

A declaration of globals, an attribute before the names of a declaration, and a name for the vararg parameter, as in the parser of Lua 5.5. Two rules are added, two are replaced, and `_stat` is split in two; the other rules are those of [`lua54`](lua54.md#rules).

| Rule | Syntax | Change |
|---|---|---|
| `_stat` | `(globalfunc \| globalstat) / _stat_rest` | replaced |
| `_stat_rest` | `";" \| exprstat \| dostat \| whilestat \| repeatstat \| ifstat \| forstat \| funcstat \| localfunc \| localstat \| labelstat \| gotostat \| breakstat` | added (the `_stat` of `lua54`) |
| `globalfunc` | `"global" "function" name body` | added |
| `globalstat` | `"global" attrib? ("*" \| name attrib? ("," name attrib?)* ("=" explist)?)` | added |
| `attnamelist` | `attrib? name attrib? ("," name attrib?)*` | replaced |
| `parlist` | `name ("," name)* ("," "..." name?)? \| "..." name?` | replaced |

A statement that starts with `global` is tried as a declaration first, and as any other statement when that fails (an [ordered choice](../grammar.md#how-rules-are-applied)). The parser of Lua 5.5 takes it as a declaration when the next token is `<`, a name, `*` or `function`, where no other statement can go on, and as another statement otherwise, where no declaration can, so both accept the same sources. The trial is made only when the statement starts with `global`. A syntax error inside a declaration is therefore reported where the other statements fail, after `global`, rather than where the declaration does.

An attribute before the names applies to every name without one of its own (`local <const> x, y <close>`), and `global <const> *` declares every other global read-only. The names of the attributes are not syntax.

## recover

None, as in `lua54`: the first syntax error stops the analysis.

## Telling constructs apart

As in [`lua54`](lua54.md#telling-constructs-apart), and:

- **Declarations of globals**: `globalfunc` for `global function`, and `globalstat` for the others; a `globalstat` that declares every global has the `*` token.
- **Attributes**: an `attrib` before the first name applies to the names without one, and one after a name to that name.
- **Vararg parameter**: the `name` token after `...` in a `parlist`.

## Expressions

The operators and their priorities are those of [`lua54`](lua54.md#expressions): the parser of Lua 5.5 has the same table. `test/grammars/lua55_test.lua` checks that every rule other than those of statements, declarations and parameters is that of `lua54`.

## Differences from Lua 5.5

The grammars accept every source that Lua 5.5 accepts, and some that it rejects: those of [`lua54`](lua54.md#differences-from-lua-54), and the checks of Lua 5.5 below. Each is a case in `test/grammars/lua55/`, compared with `luac` by `test/grammars/lua55_conformance_test.lua`:

| Source | Lua 5.5 | lexogram |
|---|---|---|
| `for i = 1, 2 do i = 3 end` | `attempt to assign to const variable 'i'` | an `exprstat` in the loop |
| `function f(... t) t = {} end` | `attempt to assign to const variable 't'` | an `exprstat` in the body |
| `global <const> x; x = 1` | `attempt to assign to const variable 'x'` | a `globalstat` and an `exprstat` |
| `global <close> x` | `global variables cannot be to-be-closed` | a `globalstat` with an `attrib` |
| `global x; y = 1` | `variable 'y' not declared` | a `globalstat` and an `exprstat` |
| `global function a.b() end` | `'(' expected near '.'` | the expression statement `global` and a `funcstat` |

Lua 5.5 reads the last one as a declaration, whose name cannot have a field; the grammar, after the declaration fails, reads it as the expression statement `global` followed by a function statement, as it accepts `global` alone (see [`lua51`](lua51.md#differences-from-lua-51)).

## Conformance

On 2026-11-18 the grammars agreed with `luac -p` of Lua 5.5.1 on all 34 files of the official Lua 5.5 test suite (5.5.1), and on 7,848 of 7,908 Lua files of this and nearby repositories; the official compiler accepted no file that `lua55` rejects (with a byte order mark and a first `#` line blanked) or that `lua55_shebang` rejects. Of the other 60 files, 55 assigned to a variable of a `for` loop, which Lua 5.5 makes read-only, four were plain text, as for [`lua51`](lua51.md#conformance), and one was a directory. `tools/conformance.lua` repeats the comparison:

```sh
find . -name '*.lua' | lua tools/conformance.lua --strip-bom --strip-shebang lexogram:lua55 /path/to/luac5.5
find . -name '*.lua' | lua tools/conformance.lua lexogram:lua55_shebang /path/to/luac5.5
```

The numbers and the escapes were also compared with `load` of Lua 5.5.1 on 2026-11-18, as for [`lua54`](lua54.md#conformance): all 444,604 numeral-like sources and all 137,570 escape-like strings agreed, and Lua 5.5.1 judged each of them as Lua 5.4.8 does.

## Performance

`lua bench/tokenize.lua lexogram:lua55` and `lua bench/parse.lua lexogram:lua55` measure the grammar as for [`lua51`](lua51.md#performance) (best of 5 in one process, CPU time, 2026-11-18, local machine). On LuaJIT the speed differs between processes, as the traces that the compiler chooses differ; the range of five processes is shown.

| Runtime | Compile | Tokenize | Parse to the event array |
|---|---|---|---|
| Lua 5.1 | 0.41 s | 5.2 MB/s | 2.3 MB/s |
| Lua 5.4 | 0.32 s | 7.4 MB/s | 3.2 MB/s |
| Lua 5.5 | 0.32 s | 7.3 MB/s | 3.2 MB/s |
| LuaJIT 2.1 | 0.17 to 0.21 s | 105 to 110 MB/s | 21 to 33 MB/s |

## Changes

| Version | Change |
|---|---|
| `5.5.1-1` | The first version (2026-11-18). |
