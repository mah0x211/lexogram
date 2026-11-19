# LuaJIT grammar

The built-in grammar of LuaJIT. `luajit` extends [`lua51`](lua51.md) with the syntax of the v2.1 branch of LuaJIT, which is developed as rolling releases: its lexer, parser and number scanner (`lj_lex.c`, `lj_parse.c`, `lj_strscan.c`) at 2.1.1792527310, the last change of the syntax. LuaJIT keeps the syntax of Lua 5.1 and adds extensions of its own, some of Lua 5.2 and 5.3, and the syntax extensions backported from LuaJIT 3.0 (`doc/extensions.html` of LuaJIT). The sections below follow the top-level fields of the grammar file `grammars/luajit.lua`; each tells what changes from `lua51`, and what does not change is described in [the Lua 5.1 grammar](lua51.md). [The grammar format](../grammar.md) describes what each field means.

```lua
local lexogram = require('lexogram')
local compiled = assert(lexogram.compile(assert(lexogram.load('lexogram:luajit'))))
local result = assert(lexogram.parse(compiled, 'local n = t?.items ?? {}'))
```

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a file is, and `extends` names the grammar it is a difference of.

| Field | `luajit` |
|---|---|
| `extends` | `'lexogram:lua51'` |
| `lexogram` | `'2026.11.15.1'` |
| `name` | `'luajit'` |
| `version` | `'2.1.1792527310-1'` |
| Built-in name | `lexogram:luajit` |
| Module | `lexogram.grammars.luajit` |

The version is `2.1.1792527310-1`: the version of LuaJIT whose syntax the grammar follows, and the revision of the grammar, as for every built-in grammar (see [the grammar format](../grammar.md#metadata)). A change that breaks the rule names or the token names is listed in [the changes](#changes).

`luajit` accepts the syntax as the parser of LuaJIT does, with `loadstring`, `load` and `loadfile` alike: the lexer of LuaJIT itself skips a byte order mark and a first line that starts with `#!`, so there is no separate grammar for files as for the versions of Lua.

## start

`chunk`, as in `lua51`.

## tokens

The tokens of `lua51`, with these changes; the parts with `_` are fragments.

| Token | LuaJIT |
|---|---|
| `name` | A letter, `_` or a byte from 80 to FF, then also digits: the lexer takes every byte from 80 on as a character of a name (`café`, and invalid UTF-8 too) |
| `number` | An [array of two patterns](../grammar.md#arrays-of-patterns), as in [`lua51`](lua51.md#tokens). The first is the run that the lexer reads: digits, letters, `_`, the bytes from 80 on and dots, with the sign after an exponent mark (`e`, or `p` after a first `0x`, also after a dot). The lexer drops every `_` after the first digit, and the rest must be one number, the second pattern; a run of another form is an `invalid_token` error (LuaJIT reports a malformed number). The first pattern tells a decimal run from one that starts with `0x` without a lookahead: a lookahead over the `_` would have no bound, and its values would be computed for the whole input once per parse. Decimal; hexadecimal with `0x` (with a fraction and a binary exponent); binary with `0b`, an integer of at most 64 digits after the leading zeros. An exponent is below 2²⁰. An integer may have the suffix `LL`, `ULL` or `LLU` (letters in any case): a 64 bit integer, decimal up to 2⁶⁴ − 1, hexadecimal of at most 16 digits after the leading zeros; any number may have the suffix `i`, an imaginary number. `1_000`, `0_x1F`, `1e_+5` and `1L_L` are numbers; `3print`, `1..2` and a number beyond a limit are invalid |
| `string`, `_escape` | The escapes of Lua 5.2 (`\x`, `\z`, decimal escapes up to 255, and an error for any other character after `\`) and `\u{...}` up to `10FFFF`, as in [`lua53`](lua53.md#tokens) |
| `long_string` | A nested `[[` is no error (as in Lua 5.2) |
| `space` | White space, but not a line break that a line number directive follows |
| `line_directive` | Skipped: a line break, then a line `# 123` or `# 123 "name"` (spaces and tabs around, the line number up to 2147483379), which sets the line number for error messages. The fragment `_line_number` is an [array of two patterns](../grammar.md#arrays-of-patterns): the digits choose the directive, and a larger line number is an `invalid_token` error (LuaJIT reports a malformed line number directive). A `#` that starts a line and is followed by a number in any other form is an error; one followed by no number is the length operator, and so is a `#` that does not start a line |
| `shebang` | Leading and skipped: a byte order mark, and a first line that starts with `#!` with its line break. A `#` at the start that is not followed by `!` is a line number directive or the length operator, and the line after the shebang line starts without a line break, so a `#` there is the length operator |
| `first_line_directive` | Leading and skipped: a line number directive at the start (after a byte order mark) |

The value of a number (its integer, or a cdata of FFI for `LL` and `i`) is not a matter of the token.

## symbols

The symbols of `lua51`, and:

| Symbols | Use |
|---|---|
| `::` | Labels |
| `+=` `-=` `*=` `/=` `%=` `..=` `&=` `\|=` `<<=` `>>=` `~>>=` | Compound assignments, written without white space as the parser requires (`a + = 1` is an error) |
| `->` | Short functions |
| `?` | The ternary operator, with `:` |
| `?.` | Safe navigation |
| `??` | The nil-coalescing operator |
| `!` `!=` `&&` `\|\|` | Customary operators: not, unequal, and, or |
| `&` `\|` `~` `<<` `>>` `~>>` | Bit operators; `~` is also the unary bit not, and `~>>` the arithmetic shift |

## keywords

The keywords of `lua51`, and `goto`, `const` and `continue` as [contextual keywords](../grammar.md#contextual-keywords) (`keywords.contextual`). LuaJIT reads them as names everywhere a name goes (`local goto = 1`, `const.x = 1`, `continue(1)` are valid), and as keywords only where a statement starts with them:

| Keyword | A statement when the next token is |
|---|---|
| `goto` | a name (`goto` before `goto`, `const` or `continue` too) |
| `const` | a name or `function` |
| `continue` | `;` or the end of a block (`end`, `else`, `elseif`, `until`, the end of input) |

A token matched as the keyword has the kind of the keyword in the events, and the kind `name` elsewhere. `lexogram.tokenize` always returns `name`.

## skip

`space`, `comment`, `long_comment`, `line_directive`, `shebang` and `first_line_directive`.

## leading

`shebang` and `first_line_directive`.

## rules

The rules of `lua51`, with the statements and the expressions of LuaJIT: ten rules are replaced and ten added.

| Rule | Syntax | Change |
|---|---|---|
| `block` | `(_stat \| ";")* (_laststat ";"*)?` | replaced: empty statements anywhere |
| `_stat` | the statements of `lua51`, `conststat`, `labelstat` and `gotostat` | replaced |
| `_laststat` | `retstat \| breakstat \| continuestat` | replaced |
| `exprstat` | `_primaryexp (_suffix++ _assignment? \| _assignment)` | replaced |
| `_assignment` | `("," suffixedexp)* "=" explist \| (compound assignment) exp` | added |
| `labelstat` | `"::" name "::"` | added |
| `gotostat` | `"goto" name` | added |
| `conststat` | `"const" ("function" name body \| namelist ("=" explist)?)` | added |
| `continuestat` | `"continue"` | added |
| `exp` | `unop* _simpleexp (binop unop* _simpleexp)*+ ternary?+` | replaced |
| `unop` | `"-" \| "not" \| "#" \| "~" \| "!"` | replaced |
| `binop` | the operators of `lua51`, `&` `\|` `~` `<<` `>>` `~>>`, `!=` `&&` `\|\|` and `??` | replaced |
| `_simpleexp` | the terms of `lua51` and `shortfunc` | replaced |
| `_suffix` | `"?."? ("[" exp "]" \| ":" name "?."? args \| args) \| "?." name \| "." name` | replaced |
| `ternary` | `"?" _middle ":" exp` | added |
| `_middle` | the operators and terms of `exp`, where `:` is no method call | added |
| `_simpleexp_nocolon` | the terms of `_middle`: those of `_simpleexp`, with the operands without a method call reported as `suffixedexp` and `shortfunc` by aliases | added |
| `_suffix_nocolon` | `_suffix` without the method call | added |
| `shortfunc` | `(name \| "\|" parlist? "\|" \| "\|\|") "->" ("do" block "end" \| exp)` | added |

- **Statements**: a name or a parenthesized expression alone is no statement (`x` and `(x)` are errors), as in the parser of LuaJIT; this lets two tokens tell the contextual keywords from a name. So the first target of an assignment, or the call of a call statement, is in `exprstat` itself, unlike in `lua51`, where it is in a `suffixedexp`; the other targets are in `suffixedexp`s. In a statement, `a ~= b` is the exclusive or assignment (the unequal operator is no statement), and `^=` is no compound assignment. `break` and `continue` end a block, and `return` does.
- **The ternary operator** `c ? a : b` has the lowest priority and is right associative: its else is an `exp`. In its middle, `:` is no method call, as in the parser of LuaJIT: `c ? a : m()` is a ternary operator, `c ? a:m() : b` is an error, and the middle writes `(a:m())`. The limit does not reach into parentheses, brackets, arguments and table constructors. The terms of the middle are written by their own rules, and reported as `suffixedexp` and `shortfunc` with [aliases](../grammar.md#patterns), so that they look as elsewhere.
- **Safe navigation**: `?.` before a suffix skips the rest of the chain when the value is nil: `a?.b`, `a?.[k]`, `a?.(x)`, `a?."s"`, `a?.:m()` and `a:m?.()`.
- **Short functions**: `x -> e`, `|a, b| -> e`, `|...| -> e` and `|| -> do ... end`. The body is one expression, as long as it goes on (`|x| -> x * 2` is one short function), or a block. A short function `name -> ...` cannot start a statement.

## recover

None, as in `lua51`: the first syntax error stops the analysis.

## Telling constructs apart

As in [`lua51`](lua51.md#telling-constructs-apart), and:

- **Statements**: `exprstat` starts with the name or the parenthesized expression of its first target or call; an assignment has `=` or a compound assignment token in it, and a call statement neither. `labelstat`, `gotostat`, `conststat` and `continuestat` for the statements of their names.
- **Ternary operators**: a `ternary` node at the end of an `exp`, after its condition; the middle is between `?` and `:`, and the else is the `exp` after `:`.
- **Short functions**: a `shortfunc` node; its parameters are a `name` before `->`, or a `parlist` between `|` and `|`, or none with `||`.
- **Safe navigation**: a `?.` token among the suffixes of a `suffixedexp`, or of an `exprstat`.

## Expressions

The priorities of the operators of the parser of LuaJIT (`lj_parse.c`), from the lowest; the binary operators are left associative but `..` and `^`, and the ternary operator is right associative below all of them:

| Priority | Operators |
|---|---|
| 1 | `or` `\|\|` `??` |
| 2 | `and` `&&` |
| 3 | `<` `>` `<=` `>=` `~=` `!=` `==` |
| 4 | `\|` |
| 5 | `~` |
| 6 | `&` |
| 7 | `<<` `>>` `~>>` |
| 8 | `..` (right) |
| 9 | `+` `-` |
| 10 | `*` `/` `%` |
| 11 | the unary operators `not` `!` `#` `-` `~` |
| 12 | `^` (right) |

There is no `//`.

## Differences from LuaJIT

The grammar accepts every source that LuaJIT accepts, and some that it rejects: those of [`lua51`](lua51.md#differences-from-lua-51) that remain, and those below. Each is a case in `test/grammars/luajit/`, compared with LuaJIT by `test/grammars/luajit_conformance_test.lua`:

| Source | LuaJIT | lexogram |
|---|---|---|
| `x.y` | `'=' expected near '<eof>'` | an `exprstat` that ends with a suffix other than a call |
| `f() = 1` | `unexpected symbol near '='` | an `exprstat` with a call as the target |
| `break` outside a loop | `no loop to break` | a `breakstat` |
| `continue` outside a loop | `no loop to continue` | a `continuestat` |
| `x?.y, z = 1, 2` | `syntax error near ','` | an assignment of two targets, the first with `?.` (and `x, y?.z = 1, 2`, which LuaJIT rejects with `'=' expected near '?.'`) |

A number with more than about 2²⁰ digits after its point is an error of LuaJIT, which no pattern of the grammar writes.

## Conformance

On 2026-11-18 the grammar agreed with `loadfile` of LuaJIT 2.1.1792527310 (built from the v2.1 branch at that version) on all 201 files of the tests of LuaJIT (`LuaJIT-test-cleanup`), all 24 files of the official Lua 5.1 test suite, and all 7,908 Lua files of this and nearby repositories. LuaJIT has no `luac -p`; `tools/conformance.lua` checks each file with `loadfile` when given a LuaJIT executable:

```sh
find . -name '*.lua' | lua tools/conformance.lua lexogram:luajit /path/to/luajit
```

The tokens were also compared with `loadstring` of that LuaJIT on 2026-11-18: all 216,989 numeral-like sources (up to five characters of digits, `.`, `_`, `e`, `x`, `b`, `p`, `i`, `L`, `u`, `+`, `-` and `f`, and the limits of the values), all 88,747 escape-like strings, and all 735,567 sources with line number directives, shebang lines and byte order marks agreed.

`test/grammars/luajit_conformance_test.lua` runs only with LuaJIT 2.1.1792527310 or later (from the environment variable `LEXOGRAM_LUAJIT`, or installed by lenv); an older LuaJIT lacks the syntax.

## Performance

`lua bench/tokenize.lua lexogram:luajit` and `lua bench/parse.lua lexogram:luajit` measure the grammar as for [`lua51`](lua51.md#performance) (best of 5 in one process, CPU time, 2026-11-19, local machine). On LuaJIT the speed differs between processes; the range of five processes is shown, and for parsing of twenty, without the few (one in twenty or so) that parse at 7 to 14 MB/s.

| Runtime | Compile | Tokenize | Parse to the event array |
|---|---|---|---|
| Lua 5.1 | 0.69 s | 4.9 MB/s | 2.1 MB/s |
| Lua 5.4 | 0.54 s | 6.8 MB/s | 2.9 MB/s |
| Lua 5.5 | 0.55 s | 6.8 MB/s | 3.0 MB/s |
| LuaJIT 2.1 | 0.28 to 0.35 s | 99 to 101 MB/s | 22 to 29 MB/s |

The compilation takes longer than for `lua51` (0.25 s on Lua 5.1): the automata of the tokens are larger (the limits of the numbers, the line number directives and the lookaheads), and the analysis of two tokens ahead has more terminals. Parsing is somewhat slower than for `lua51` (2.3 MB/s on Lua 5.1). The lookahead of `space` after a line break has no bound, but it reads a byte or a few after each line break, so its values are not computed for the whole input (see the cost of lookaheads in [the grammar reference](../grammar.md#lookaheads)).

## Changes

| Version | Change |
|---|---|
| `2.1.1792527310-1` | The first version (2026-11-18). |
