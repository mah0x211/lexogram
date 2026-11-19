# The lexogram command

`lexogram` checks grammars, merges them, saves compiled grammars and parses sources, without writing Lua. LuaRocks installs it with the library.

```sh
lexogram check GRAMMAR
lexogram merge GRAMMAR
lexogram compile GRAMMAR [-o FILE]
lexogram parse [--format json|tree] GRAMMAR [FILE]
```

`GRAMMAR` is a [grammar file](grammar.md), a built-in grammar (`lexogram:NAME`), or a compiled grammar that `compile` saved, which is read back without checking and compiling the grammar again.

## Commands

| Command | What it does |
|---|---|
| `check` | Loads, checks and compiles the grammar, and writes the diagnostics to the standard output, one per line: the severity, the code, the path and the message, separated by tabs |
| `merge` | Writes the grammar merged with the grammars it extends and the mixins it embeds, a grammar file that extends no other one ([`lexogram.merge`](grammar.md#built-in-grammars)); use it to copy a built-in grammar |
| `compile` | Writes the compiled grammar ([`lexogram.dump`](grammar.md#saving-a-compiled-grammar)) to `FILE`, or to the standard output |
| `parse` | Parses `FILE`, or the standard input, and writes the result |

The commands other than `check` write the warnings of the grammar to the standard error. A saved compiled grammar cannot be merged or compiled again.

## The result of parse

`--format json`, the default, writes the result for other programs to read:

```json
{"grammar":{"name":"words","version":"1.0.0"},
"kinds":[{"category":"error","name":"INVALID","skip":false},{"category":"error","name":"ERROR","skip":false},{"category":"token","name":"space","skip":true},{"category":"token","name":"word","skip":false},{"category":"symbol","name":",","skip":false},{"category":"rule","name":"chunk","skip":false}],
"events":[2,6,1,6,1,4,1,3,1,5,3,4,1,3,4,5,1,4,5,7,3,6,7,1],
"errors":[]}
```

- `kinds` is the table of kinds, and an ID of a kind is an index of it, from 1.
- `events` is the event array: four integers for each event, an opcode (1 a token, 2 the start of a rule, 3 its end), a kind, and two integers. For a token they are its start and the position after it, in bytes from 1; for the start of a rule, its start and the number of its end event; for the end of a rule, the position after it and the number of its start event. The text of a range is the bytes of the source from its start up to the position after it.
- `errors` holds the syntax errors that were recovered from.

The source itself is not written: the program that reads the result has it. The same grammar and source always give the same bytes.

`--format tree` writes the result for people to read: a rule with its children indented under it, a token with a name as its name and text, and a symbol or a keyword as its text. The text is in double quotes, with `"`, `\`, a line feed, a carriage return and a tab escaped, and other bytes that are not printable ASCII written as `\ddd`.

```text
$ printf 'ab, cd' | lexogram parse --format tree words.lua
chunk
  word "ab"
  ","
  space " "
  word "cd"
```

A syntax error is written to the standard error as `FILE:LINE:COLUMN: message`, with `-` for the standard input.

## Exit status

| Status | When |
|---|---|
| 0 | Success (warnings do not change it) |
| 1 | The grammar has errors or cannot be loaded, the source has a syntax error, or a saved compiled grammar is of another version of lexogram |
| 2 | A wrong use (the usage is written to the standard error), or a file that cannot be read or written |
