# C macro forms

`lexogram:c_macro` is a [mixin](../grammar.md#mixins) for the C grammars: it adds the forms that macros make in C sources before preprocessing, which have no C syntax while the macros are not expanded. These forms come from reading a source before preprocessing, whichever standard it is written in, so [`lexogram:c99`](c99.md) embeds the mixin, and [`lexogram:c11`](c11.md) and [`lexogram:c23`](c23.md) inherit it.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:c99'))))
local result = assert(lexogram.parse(compiled, 'x = cast(char *, "a" LUA_QS "b");'))
```

Each of these forms has no other reading in C, so a source with the syntax of C is read as without the mixin, with the same events; the mixin adds no rule with events. On the C sources of Lua that [`c99`](c99.md#results-on-real-sources) was run on, the event arrays of the 173 files that parse without the mixin are the same with it.

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
| `_struct_declarators` | `_struct_declarator_list` (`_struct_declarator_list?` in `c11`, for anonymous members), where `_struct_declarator_list` is the list of declarators of a member (`struct_declarator_list`, or `member_declarator_list` in `c23`) | `_struct_declarator_list?` |
| `argument_expression_list` | `assignment_expression ("," assignment_expression)*` | `_argument ("," _argument)*` |
| `_argument` | (none) | `assignment_expression / type_name` |
| `_strings` | `string_literal+` | `string_literal++ (identifier _strings?+)?` |
| `_postfix_suffix` | the suffixes of an operand | the same, and `_strings` |

## Changes

| Version | Change |
|---|---|
| `1.0.0` | The first version, embedded in `c99` (2026-11-19). |
