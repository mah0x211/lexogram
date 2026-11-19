# C macro forms

`lexogram:c_macro` is a [mixin](../grammar.md#mixins) for the C grammars: it adds the forms that macros make in C sources before preprocessing, which have no C syntax while the macros are not expanded. `lexogram:c99_macro` is [`lexogram:c99`](c99.md) with it, `lexogram:c11_macro` is [`lexogram:c11`](c11.md) with it, and `lexogram:c23_macro` is [`lexogram:c23`](c23.md) with it.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:c99_macro'))))
local result = assert(lexogram.parse(compiled, 'x = cast(char *, "a" LUA_QS "b");'))
```

Each of these forms has no other reading in C, so a source of C is read as by the grammar without the mixin, with the same events; the rules with events are those of that grammar.

## Forms

| Form | Example | How it is read |
|---|---|---|
| A member declared by a macro | `struct S { CommonHeader; int a; };` | The declarators of a member may be left out: `struct_declaration` holds the name as a `type_specifier` and `;` |
| A type name as a macro argument | `cast(char *, s)`, `newvector(L, n, Proto *)` | An argument that cannot be read as an expression is tried as a `type_name`, in `argument_expression_list` |
| A macro next to a string literal | `"a" LUA_QS "b"`, `LUA_QL("x") " b"`, `FMT "x" Y` | Names of macros may be between and after the string literals of a run that has one, and string literals may follow an operand (a call of a macro too), all in the `postfix_expression` of the operand |

The other forms of macros remain syntax errors: names of macros next to each other without a string literal (`A B`), an operator or a statement as an argument (`intop(+, a, b)`, `TRY(L, f(); )`), a macro used as a statement keyword (`vmdispatch (x) { ... }`), and a member declared by a macro without its `;`.

## The mixin

| Field | Value |
|---|---|
| `lexogram` | `2026.11.15.1` |
| `name` | `c_macro` (module `lexogram.grammars.c_macro`) |
| `version` | `1.0.0` |

It replaces rules that the C grammars define for it, and adds one:

| Rule | In the C grammars | With the mixin |
|---|---|---|
| `_struct_declarators` | `_struct_declarator_list` (`_struct_declarator_list?` in `c11` and `c23`), where `_struct_declarator_list` is the list of declarators of a member (`struct_declarator_list`, or `member_declarator_list` in `c23`) | `_struct_declarator_list?` |
| `argument_expression_list` | `assignment_expression ("," assignment_expression)*` | `_argument ("," _argument)*` |
| `_argument` | (none) | `assignment_expression / type_name` |
| `_strings` | `string_literal+` | `string_literal++ (identifier _strings?+)?` |
| `_postfix_suffix` | the suffixes of an operand | the same, and `_strings` |

## c99_macro

| Field | Value |
|---|---|
| `extends` | `lexogram:c99` |
| `embeds` | `lexogram:c_macro` |
| `name` | `c99_macro` (module `lexogram.grammars.c99_macro`) |
| `version` | `1999-1`, as `c99` |

## c11_macro

| Field | Value |
|---|---|
| `extends` | `lexogram:c11` |
| `embeds` | `lexogram:c_macro` |
| `name` | `c11_macro` (module `lexogram.grammars.c11_macro`) |
| `version` | `2011-1`, as `c11` |

## c23_macro

| Field | Value |
|---|---|
| `extends` | `lexogram:c23` |
| `embeds` | `lexogram:c_macro` |
| `name` | `c23_macro` (module `lexogram.grammars.c23_macro`) |
| `version` | `2024-1`, as `c23` |

## Results on real sources

On the C sources of Lua 5.1.5 to 5.5.1 that [`c99`](c99.md#results-on-real-sources) was run on (295 files, 3.36 MB, 2026-11-19), `c99_macro` parses 262 files (88.8%, against 173 with `c99`), and their event arrays cover their sources exactly; `c11_macro` and `c23_macro` parse the same files. The other 33 fail at the first of these forms:

| First error | Files | Example |
|---|---:|---|
| A statement or a declaration as a macro argument | 12 | `LUAI_DDEC(const lu_byte luai_ctype_[UCHAR_MAX + 2];)` |
| An operator as a macro argument | 10 | `intop(+, v1, v2)` |
| Names of macros next to each other | 6 | `LUA_PATH_SEP LUA_PATH_SEP` |
| A macro used as a statement keyword | 1 | `vmdispatch (GET_OPCODE(i)) {` |
| A member declared by a macro without its `;` | 1 | `numfield` |
| Conditional compilation and GNU extensions | 3 | C++ code in an `#if` branch, `&&L_OP_MOVE` |

## Performance

Measured as for [`c99`](c99.md#performance), on the 51 files of Lua 5.4.8 that `c99_macro` parses, concatenated and repeated to 2.63 MB (2026-11-19). Loading a grammar for the first time checks the grammars it extends too (`c99` for `c99_macro`; `c99` and `c11` for `c11_macro`); the speed of tokenizing and parsing is that of the grammar without the mixin on the same input.

| Runtime | Grammar | Load and compile | Tokenize | Parse to the event array |
|---|---|---|---|---|
| Lua 5.1 | `c99_macro` | 1.20 s | 4.8 MB/s | 1.3 MB/s |
| Lua 5.1 | `c11_macro` | 1.95 s | 4.8 MB/s | 1.3 MB/s |
| Lua 5.4 | `c99_macro` | 0.91 s | 6.7 MB/s | 1.8 MB/s |
| Lua 5.4 | `c11_macro` | 1.57 s | 6.8 MB/s | 1.8 MB/s |
| Lua 5.5 | `c99_macro` | 0.89 s | 6.7 MB/s | 1.8 MB/s |
| Lua 5.5 | `c11_macro` | 1.53 s | 6.7 MB/s | 1.8 MB/s |
| LuaJIT 2.1 | `c99_macro` | 0.53 to 0.70 s | 93 to 109 MB/s | 13 to 14 MB/s, and about 2.5 MB/s in two of five processes |
| LuaJIT 2.1 | `c11_macro` | 0.84 to 1.13 s | 90 to 96 MB/s | 11 to 13 MB/s |

## Changes

| Version | Change |
|---|---|
| `1.0.0` | The first version of `c_macro`, with `c99_macro` `1999-1`, `c11_macro` `2011-1` and `c23_macro` `2024-1` (2026-11-19). |
