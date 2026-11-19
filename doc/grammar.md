# Grammar files

A grammar describes the tokens and the syntax of a language. lexogram compiles it into tables that split a source into tokens and parse it into an event array. This document is the reference of the grammar format; `doc/grammars/` describes the built-in grammars.

```lua
local lexogram = require('lexogram')

local grammar, err = lexogram.load('my.lua')            -- a grammar file
local grammar, err = lexogram.load('lexogram:lua51')    -- a built-in grammar
local diagnostics = lexogram.check(grammar)              -- errors and warnings
local compiled, diagnostics = lexogram.compile(grammar)  -- nil on errors
local result, err = lexogram.parse(compiled, source)
```

## Contents

- [The form of a grammar](#the-form-of-a-grammar)
- [Built-in grammars](#built-in-grammars)
- [Top-level fields](#top-level-fields)
- [Metadata](#metadata): `lexogram`, `name`, `version`
- [start](#start)
- [tokens](#tokens)
- [symbols and keywords](#symbols-and-keywords)
- [skip](#skip)
- [leading](#leading)
- [rules](#rules)
- [recover](#recover)
- [extends](#extends)
- [Mixins](#mixins): `mixin`, `embeds`
- [Patterns](#patterns)
- [How tokens are chosen](#how-tokens-are-chosen)
- [How rules are applied](#how-rules-are-applied)
- [Diagnostics](#diagnostics)

## The form of a grammar

A grammar is a Lua table. It is written in one of two forms.

**A grammar file** is a Lua chunk that returns the table:

```lua
return {
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
}
```

`lexogram.load(pathname)` runs it in an isolated environment that holds only `import`, `pairs` and `ipairs`; reading or assigning any other global variable is an error. `import(name)` returns a copy of another grammar (see [extends](#extends) for the names), to share parts between grammars. The isolation keeps grammar files declarative; it is not a security sandbox.

**A grammar module** is a Lua module that returns the result of `lexogram.grammar`. The built-in grammars are such modules (`lexogram.grammars.<name>`, read as `"lexogram:<name>"`):

```lua
return assert(require('lexogram.grammar')({
    lexogram = '2026.11.15.1',
    name = 'calc',
    ...
}))
```

`require('lexogram.grammar')(def)` merges `def` into the grammar it extends, if any, and runs every check of `lexogram.check`. Without errors it returns a function that returns a new copy of the checked grammar on each call, so that no caller can change the definition, `nil`, and the diagnostics (warnings only, such as an unreachable rule); with errors it returns `nil`, a message with one line per error, and the diagnostics. A module has no directory, so its `extends` and `embeds` can name built-in grammars and mixins only, and it cannot use `import`. A [mixin](#mixins) module is written the same way.

## Built-in grammars

lexogram ships grammars of Lua 5.1 to 5.5, LuaJIT, C99, C11 and C23, and the mixins they embed, as the modules `lexogram.grammars.<name>`, read as `"lexogram:<name>"`; [grammars/](grammars/) has a document for each. They are there to test lexogram on real languages, and as starting points for grammars of your own. They make no promise of compatibility: from one version of lexogram to the next, their rules, tokens, helper rules and events may change, and a grammar that extends one of them may break.

To use one, copy it. `lexogram.merge` returns the Lua source of a grammar merged with the grammars it extends and the mixins it embeds: a grammar file that extends no other one. Keep it in your project under a name and a version of your own, and change it there:

```lua
local lexogram = require('lexogram')
local source = assert(lexogram.merge('lexogram:c23'))
local f = assert(io.open('c23.lua', 'w'))
f:write(source)
f:close()
```

The document of each built-in grammar lists its changes, which tells what to bring into a copy.

## Top-level fields

| Field | Required | Value | Meaning |
|---|---|---|---|
| `lexogram` | yes | string | The revision of this specification that the grammar follows |
| `name` | yes | string | The name of the grammar |
| `version` | yes | string | The version of the grammar itself |
| `start` | yes | rule name | The rule that must cover the whole input |
| `tokens` | yes | table | Name → pattern, array of patterns, delimited token table or prefixed table |
| `symbols` | | array of literals | Punctuation |
| `keywords` | | array of literals | Reserved words |
| `skip` | | array of token names | Tokens skipped between the elements of the rules |
| `leading` | | array of pattern token names | Tokens tried at the start of the input only |
| `rules` | yes | table | Name → pattern |
| `recover` | | array of rule names | Rules to recover in after a syntax error (not implemented yet) |
| `extends` | | grammar name | The grammar this one is a difference of; resolved by `lexogram.load` |
| `embeds` | | array of mixin names | The [mixins](#mixins) applied after the base, or to the grammar itself when it has no `extends` |

An unknown field is an error, so that a field added in a later revision cannot collide with an existing grammar.

Names of tokens and rules match `[A-Za-z_][A-Za-z0-9_]*`, and tokens and rules share one namespace (a name defined in both is an error). Names in all upper case are reserved for the built-in classes. A name that starts with `_` is a helper: in `tokens` a fragment that other patterns refer to, which is not a token by itself; in `rules` a rule that produces no events. The order of the items of an array does not matter.

## Metadata

The fields `lexogram`, `name` and `version` tell which grammar a table is.

- **`lexogram`**: the revision of this specification, `yyyy.mm.dd.n`. A later lexogram reads a grammar with the meaning of the revision it states; a revision newer than the running lexogram, or older than the first one, is an error. The only revision so far is `2026.11.15.1`.
- **`name`**: matches `^[A-Za-z0-9_-]+$`. A built-in grammar is named after its module (`lexogram:lua51` is named `lua51`). The compiled object carries it as `compiled.name`.
- **`version`**: the version of the grammar itself, a string of letters, digits, `.`, `_`, `+` and `-` (`^[0-9A-Za-z._+-]+$`). Its form and meaning are the author's: lexogram does not compare versions. The compiled object carries it as `compiled.version`, and the functions of `lexogram.grammar` have it in their chunk name (`=lexogram.grammar:<name>@<version>`), so that error messages and tracebacks tell the grammar and its version.
- **Versions of the built-in grammars**: the version of the language that a built-in grammar was checked against, a `-`, and the revision of the grammar, counted from 1: `5.4.8-1` is the first revision for Lua 5.4.8, as a LuaRocks rockspec writes `1.0.0-1`. The revision is not a pre-release as in Semantic Versioning. The version tells which revision a [copy](#built-in-grammars) was made from, and the document of each grammar lists its changes. The built-in mixins, which have no language, have their own version (`1.0.0`).

## start

The rule that the analysis starts with. It must name a rule, and the input must end after it.

## tokens

The tokens of the language, as a table from names to definitions. A definition is one of four forms: a pattern string, an array of patterns, a delimited token table, or a prefixed table. A name that starts with `_` is a fragment: a pattern that other token patterns refer to, which is not a token by itself; a fragment is a pattern string or an [array of patterns](#arrays-of-patterns).

### Pattern tokens

A pattern string (see [Patterns](#patterns)) that refers to built-in classes and fragments only:

```lua
tokens = {
    name = [[ (ALPHA | "_") (ALPHA | DIGIT | "_")* ]],
    number = [[ _digits ("." _digits)? ]],
    _digits = [[ DIGIT+ ]],
}
```

A pattern token that matches the empty string is an error, and so is a pair of pattern tokens that can match the same whole string (see [How tokens are chosen](#how-tokens-are-chosen)).

#### Arrays of patterns

A pattern token can be written as an array of patterns, checked in stages. The first pattern chooses the token, as a pattern string does: it gives its kind and its end. Each later pattern checks the token afterwards: it must match the whole text of the token, and a token that fails one is invalid. A form that is simple to tell apart can so be chosen by a small pattern, and its exact rules checked by others, without one large automaton for all of them:

```lua
tokens = {
    -- a run of digits and "_", not followed by a letter; at most three
    -- digits after the leading zeros
    number = {
        [[ DIGIT (DIGIT | "_")* (?![0-9A-Za-z_]) ]],
        [[ ("0" "_"*)* ([1-9] "_"* (DIGIT "_"*){0,2})? ]],
    },
}
```

- The array has at least one item, each a pattern string, and no other key. An array of one pattern is that pattern. A table with `open`, `close`, `nest`, `prefix` or `match` is a delimited token table or a prefixed table, not an array.
- The later patterns are tried in order, and all of them must match: a token fails at the first that does not. They may use fragments and lookaheads; a lookahead in a later pattern sees only the text of the token, whose end is the end of its input.
- An invalid token keeps its kind and its end. `lexogram.tokenize` returns `kind, stop, 'invalid', i`, where `i` is the index in the array of the pattern that failed; `lexogram.parse` stops with the error `invalid_token` at the start of the token (`invalid number`). This holds for skipped and leading tokens as well.
- Conflicts between tokens are checked with the first patterns. A later pattern that matches no non-empty string is an error (`unmatchable_pattern`); whether the first pattern and the later ones have a string in common is not checked.
- Each later pattern is an automaton of its own, run only on the tokens of its kind: a condition that needs the product of two automata when written in one pattern (as a lookahead that holds over the whole token) costs no more than the two.
- In a grammar that extends another, the marks work on the array as on any array: `['+number'] = { [[ ... ]] }` appends a check, `['-number'] = { [[ ... ]] }` removes one, and `['=number']` replaces the definition. A pattern string is not an array: to add a check to it, replace the token.

A fragment can be written as an array of patterns too. It matches the strings that all its patterns match, wherever it is referred to: in a choice, in a sequence, in a repetition or in another fragment. Each form of a token can so carry its own rules, as the rules of a grammar such as ABNF are written:

```lua
tokens = {
    -- at most three digits, with an exponent of one digit
    _decimal = { [[ DIGIT+ ]], [[ DIGIT{1,3} ]] },
    _exponent = { [[ "e" DIGIT+ ]], [[ "e" DIGIT ]] },
    -- at most two hexadecimal digits
    _hex = { [[ "0x" HEXDIGIT+ ]], [[ "0x" HEXDIGIT{1,2} ]] },
    number = [[ (_hex | _decimal _exponent?) (?![0-9A-Za-z]) ]],
}
```

- The token is chosen with the first pattern of each such fragment, so its kind and its end do not depend on the others: `1234` is one `number`, which is invalid, rather than a shorter token.
- Then the whole text of the token must match its pattern with each such fragment taken as all its patterns, and its lookaheads left out (they were evaluated when the token was chosen). Through a choice, one alternative is enough: `0xff` matches `_hex`, and `12e3` matches `_decimal _exponent?`. A token that does not is invalid: `lexogram.tokenize` returns `kind, stop, 'invalid', 1`, before the later patterns of the token, if it has any, are tried.
- The intersection of the patterns of a fragment is an automaton of its own, which only the checks of the tokens include: the token automaton has the first patterns only. A later pattern of a token, and the body of a lookahead, match such a fragment as all its patterns.
- A fragment written as an array cannot hold a lookahead, also through another fragment (`lookahead_not_allowed`): write it in the token. A delimited token table or a prefixed table cannot refer to one (`invalid_reference`). A fragment whose patterns have no non-empty string in common is `unmatchable_pattern`.

### Delimited token tables

A token whose end is given by its start, which a pattern cannot express: a long bracket whose close repeats the level of its open, a heredoc whose close repeats its tag, a nested comment.

```lua
tokens = {
    long_string = {
        open = [[ "[" level "[" ]],
        close = [[ "]" level "]" ]],
        level = [[ "="* ]],
    },
}
```

| Key | Value |
|---|---|
| `open` | The pattern of the start. It may refer to one capture, once, as an item of its top-level sequence |
| `close` | The end: a sequence of literals and the capture |
| `nest` | `'count'` or `'error'` (optional, below) |
| any other key | A capture definition: a pattern. The bytes it matched in `open` are matched again where `close` refers to it |

- The items of `open` before the capture must have a fixed length, and a byte that can continue the capture must not be able to start the rest of `open`; so the captured bytes are exact.
- The body runs to the first occurrence of the close after the open. Without one, the token runs to the end of the input and is an error (`unterminated`).
- **`nest`** declares what an occurrence of the same open (with the same captured bytes) inside the body means. `'count'`: it opens a nested level that needs its own close (block comments of Rust, Swift, OCaml or Haskell). `'error'`: it is an error, and the token still ends at its first close (a level 0 long string of Lua 5.1). Without `nest` it is ordinary text. At each position the close is tried before the open.
- Capture names cannot start with `_`, and a delimited token table cannot be a fragment.

### Prefixed tables

A token that is a fixed prefix followed by one of some delimited tokens, read exactly as those tokens are read:

```lua
tokens = {
    long_comment = {
        prefix = [[ "--" ]],
        match = { 'long_string', 'long_string_level' },
    },
}
```

| Key | Value |
|---|---|
| `prefix` | A pattern that does not match the empty string |
| `match` | A non-empty array of names of delimited token tables (with `open` and `close`) |

The token is the prefix and the whole token of the table that follows it. Its close, captures and nest are those of that table, and a nested open in its body is an open of that table, without the prefix: a `[[` inside `--[[ ... ]]` is an error as it is inside `[[ ... ]]`. The prefix must have a fixed length when a named table has a capture. A table that has `prefix` or `match` is a prefixed table, so its only keys are these two. String prefixes such as `u8R"x(...)x"` of C++ have the same shape.

## symbols and keywords

The literal tokens: arrays of the strings that rules write in quotes. Both are matched the same way; they differ only in the category of their kinds in the compiled object (`symbol` or `keyword`).

```lua
symbols = { '+', '-', '==', '(', ')' },
keywords = { 'if', 'then', 'end', ignore_case = true },
```

- An empty item, an item twice in one array, and an item in both arrays are errors.
- The settings of the hash part are `ignore_case` (when true, ASCII letters match in either case) and, in `keywords` only, `contextual` (see below).
- A table as an item is reserved for a later revision.

### Contextual keywords

`keywords.contextual` lists keywords that are not reserved: words that are keywords only where the rules expect them, and names elsewhere, such as `global` of Lua 5.5.

```lua
keywords = { 'local', 'function', contextual = { 'global' } },
rules = {
    -- the declaration is tried first; global = 1 is an assignment
    stat = [[ globalstat / exprstat ]],
    globalstat = [[ "global" name ]],
    ...
},
```

- A contextual keyword is not a token of its own: its text is read as the pattern token that matches it (here `name`), which must be exactly one pattern token, not listed in `skip` (`invalid_contextual`). `lexogram.tokenize` returns that token.
- In rules, `"global"` matches a token of that kind whose text is `global` (after ASCII folding with `ignore_case`), and `name` matches it too. The token has the kind of the keyword in the events where the rules matched the keyword, and the kind `name` elsewhere.
- No rule makes the keyword win: an alternative that starts with `"global"` and one that starts with `name` are ambiguous unless two tokens tell them apart (`ambiguous_choice`). Write an [ordered choice](#how-rules-are-applied) `/` to try the keyword first; it is tried only when the next token is the keyword.
- An item that is also an item of `keywords` or `symbols` is an error (`duplicate_item`). Its kind follows those of the keywords in the compiled object, with the category `keyword` and `base` (the kind of the token it is read as).

## skip

The tokens that may appear anywhere between the elements of the rules, such as white space and comments. A rule cannot refer to them. They are still TOKEN events of the event array (their kind has `skip = true`), placed outside the ranges of the rules, so that the events cover the whole source.

## leading

The pattern tokens that are tried at the start of the input only, before every other token, such as a shebang line or a byte order mark:

```lua
tokens = { shebang = [[ "#" [^\n]* ]], ... },
leading = { 'shebang' },
skip = { 'space', 'shebang' },
```

A leading token never matches elsewhere, and it is checked for conflicts with the other leading tokens only. Listing a token in `leading` does not use it: list it in `skip` or refer to it from a rule. Several structures at the start (a byte order mark and then a shebang line) are written as one token with alternatives. Delimited token tables are reserved for a later revision.

## rules

The syntax, as a table from names to patterns (see [Patterns](#patterns)). A rule pattern refers to literals, tokens (not fragments) and rules; it cannot use character classes or built-in classes. A literal must be declared in `symbols` or `keywords`.

- Each application of a rule whose name does not start with `_` produces an ENTER and an EXIT event around its range. These rule names are a contract with consumers.
- A rule whose name starts with `_` produces no events; its contents belong to the enclosing rule.
- Which alternative of a choice was taken leaves no trace in the events, so a structure that consumers must tell apart is a rule of its own.
- Rules may be recursive, but a rule that reaches itself without consuming a token (left recursion) is an error.
- Expressions are written flat, without precedence: `expr = [[ unop* operand (binop unop* operand)* ]]`; a consumer applies the precedence of its language.

## recover

The rules to recover in after a syntax error: the error would be replaced by an `ERROR` span covering the rule, and the analysis would go on. **Error recovery is not implemented yet**: the field is checked, but the first syntax error stops the analysis.

## extends

A grammar may be the difference from another grammar. `extends` names the base, and the other fields are operations on it, marked at the start of their keys:

```lua
return {
    extends = 'lexogram:lua51',
    name = 'lua51_shebang',
    version = '1.0.0',
    ['++tokens'] = { shebang = [[ "#" [^\n]* ]] },
    ['+leading'] = { 'shebang' },
    ['+skip'] = { 'shebang' },
}
```

`lexogram.load` merges the difference into a copy of the base, so checking and compiling see an ordinary grammar; `lexogram.check` and `lexogram.compile` report `extends` and marked keys as unknown fields.

**Names of grammars** (also the argument of `import`):

| Name | Grammar |
|---|---|
| `'base'`, `'dir/base'` | The file `base.lua` or `dir/base.lua` below the directory of the file that writes the name. Each part matches `^[A-Za-z0-9_-]+$`, separated by `/`: a name cannot go up, be absolute or hold a drive |
| `'lexogram:lua51'` | The built-in grammar of the module `lexogram.grammars.lua51` |

The base may extend another grammar in turn; a cycle is an error.

**Marks**, on a key of the table that the operation changes, telling what to do directly under it:

| Key | Value | Operation | Condition |
|---|---|---|---|
| `+X` | array of items | Append the items to the array `X` | an item must not be in it yet |
| `-X` | array of items | Remove the items from the array `X` | each item must be in it |
| `++X` | table of fields | Add the fields to the table `X` | a field must not exist yet |
| `--X` | array of names | Remove the fields from the table `X` | each field must exist |
| `=X` | value | Replace the value of `X` | |
| `X` | table | Enter the table `X` and apply the same marks inside it (the number of its fields does not change) | the value must be a table |

Separate examples of each mark:

```lua
['+keywords'] = { 'goto' },                    -- append a keyword
['-symbols'] = { '::' },                       -- remove a symbol
['++rules'] = { gotostat = [[ "goto" name ]] }, -- add a rule
['--tokens'] = { 'shebang' },                  -- remove a token
rules = { ['=_stat'] = [[ ... | gotostat ]] },  -- replace a rule
tokens = { ['--long_string'] = { 'nest' } },    -- remove a setting of a token
```

- The target `X` must exist in the base. The top-level table fields (`tokens`, `rules`, `symbols`, `keywords`, `skip`, `leading`, `recover`) exist as empty tables when the base has none.
- In one table, removals (`-`, `--`) are applied first, then replacements and entered tables (`=`, unmarked), then additions (`+`, `++`). `=X` and `X` together are an error.
- `extends`, `embeds`, `mixin`, `lexogram`, `name` and `version` are written without a mark. `lexogram` is inherited when it is not written; `name` and `version` are not inherited, so that a derived grammar never keeps the name of its base. `start` is replaced with `['=start']`.
- An error of the merge is returned by `lexogram.load` as `nil, "<file>: <path>: <reason>"`.

`lexogram.merge(name)` returns the Lua source of the merged grammar, which extends no grammar and loads back into an equal table, in the same form on every runtime.

## Mixins

A mixin is a difference without a base, written once and embedded in grammars that extend different bases. It has `mixin = true`, and its other fields are operations written with the same [marks](#extends):

```lua
-- shebang.lua
return {
    mixin = true,
    lexogram = '2026.11.15.1',
    name = 'shebang',
    version = '1.0.0',
    ['++tokens'] = { shebang = [[ "#" [^\n]* ]] },
    ['+leading'] = { 'shebang' },
    ['+skip'] = { 'shebang' },
}

-- lua51_shebang.lua
return {
    extends = 'lexogram:lua51',
    embeds = { 'shebang' },
    name = 'lua51_shebang',
    version = '1.0.0',
}
```

- **Embedding**: `embeds` is a non-empty array of names of mixins (the names of [extends](#extends)). In a grammar with `extends`, the base is merged first, then each mixin in the order of `embeds`, then the difference of the grammar itself, which can adjust what the mixins wrote. A grammar without `extends` is a complete table, not a difference, so each mixin is applied to it in the same order.
- **Extending a mixin**: a mixin may extend another mixin with `extends`, but not a grammar, and it cannot embed. Embedding it applies the mixin it extends first, then its own difference. A grammar cannot extend a mixin, and `lexogram.load`, `lexogram.merge` and `import` reject a mixin, which is no complete grammar.
- **Marks in a mixin**: a mixin is written without knowing its base, so an item (`+X`) or a field (`++X`) that already exists, in the base or from an earlier mixin, is not added, with an `already_defined` warning. A replacement (`=X`) replaces what an earlier mixin wrote: the later one wins. The other marks work as in a difference of `extends`, and the difference of the grammar itself stays as strict as ever.
- **Embedding twice**: a mixin that two items of `embeds` bring in is an error, such as `embeds = { 'shebang', 'bom_shebang' }` where `bom_shebang` extends `shebang`: `cannot embed "shebang": it is already embedded through "bom_shebang"`.
- **Checks**: `lexogram.load` checks the metadata of a mixin (`lexogram`, `name`, `version` are required, `mixin` must be `true`) and the shape of its operations; whether their targets exist is known only in the grammar that embeds it, which is checked as a whole. The `lexogram`, `name` and `version` of a mixin do not change the grammar.
- **Errors and warnings**: an error of a mixin names it: `"<file>: <mixin>: <path>: <reason>"`. The warnings are returned, not printed: `lexogram.load` and `lexogram.merge` return them after `nil` (`grammar, nil, warnings`), and `lexogram.grammar` before the warnings of the check.

```lua
{ severity = 'warning', code = 'already_defined', path = 'tokens.shebang',
  source = 'lexogram:shebang', message = 'tokens.shebang already exists; it is not added' }
```

## Patterns

`tokens` and `rules` share one notation:

```ebnf
pattern  = choice
choice   = sequence ("|" sequence)* | sequence ("/" sequence)*
sequence = repeat+
repeat   = primary (("?" | "*" | "+" | count) "+"?)?
         | "(" choice ")" "->" name
count    = "{" digits ("," digits?)? "}"
primary  = literal | class | name | "(" choice ")"
         | "(?=" choice ")" | "(?!" choice ")"
```

| Notation | Meaning | In `tokens` | In `rules` |
|---|---|---|---|
| `"abc"` | Literal | yes | yes (declared ones) |
| `[a-z_]`, `[^"\\]` | Character class, negated class | yes | no |
| name | Reference | built-in classes and fragments | tokens and rules |
| `A B` | Sequence | yes | yes |
| `A \| B` | Choice, independent of order | yes | yes |
| `A / B` | Ordered choice (tried in order) | no | yes |
| `A?`, `A*`, `A+` | Optional, zero or more, one or more | yes | yes |
| `A?+`, `A*+`, `A++` | The same, possessive: the greedy choice is intended where it is ambiguous (see [How rules are applied](#how-rules-are-applied)) | no | yes |
| `A{n}`, `A{n,}`, `A{n,m}` | Exactly `n`, at least `n`, from `n` to `m` times | yes | yes |
| `A{n,}+`, `A{n,m}+` | The same, possessive | no | yes |
| `(A)` | Grouping | yes | yes |
| `(A)->name` | Alias: the range of `A` is reported as the rule `name` | no | yes |
| `(?=A)`, `(?!A)` | Lookahead, positive and negative: consumes nothing (see [Lookaheads](#lookaheads)) | yes | no |

- An alias reports a part of a pattern with the kind of a rule: its range gets the ENTER and EXIT events of the rule `name`, which must be a rule with a kind (a name that does not start with `_`). It lets a grammar write the same construct in two ways and report both alike: `(name "{" "}")->call` is a `call` as `name "(" ")"` in the rule `call` is. An alias of a rule with a kind contains it (`(exp)->x` is an `x` around an `exp`), and the kinds of the compiled object stay those of the rules. The range of an alias is always written in parentheses, also for one reference (`(x)->name`); a repetition of an alias is written with a group around it (`((A)->name)*`), and so is an alias of a repetition (`(A*)->name`). The rule that an alias names counts as used. A diagnostic inside an alias names the rule it is written in. Errors: `alias_not_allowed` in tokens, `invalid_alias` without parentheses before `->` or a rule name after it, `undefined_reference` and `invalid_reference` for the name.
- A count is written without white space inside the braces; `n` and `m` are at most 1000, `m` is not below `n`, and a count of zero times only (`{0}`, `{0,0}`) is an error. `A{n}` is `n` copies of `A` in sequence, `A{n,}` is `n - 1` copies followed by `A+` (`A*` for `{0,}`), and `A{n,m}` is `n` copies followed by `m - n` nested optional copies (`A{1,3}` is `A (A A?)?`): a grammar that uses counts is analyzed as if written that way, and a diagnostic names the count (`{1,3}+`). The counts of one pattern may make at most 10000 nodes. `A{n}+` is an error, since a fixed count has nothing to make possessive (`invalid_repetition` for these errors).
- Postfix operators bind tighter than sequences (the `+` of a possessive operator follows the operator directly, without white space), and sequences tighter than choices. `|` and `/` cannot be mixed in one choice; group one of them with parentheses.
- White space outside quotes and brackets is ignored. Patterns are written in Lua long brackets (`[[ ... ]]`), where the escapes of Lua do not apply; a pattern that contains `]]` is written in `[=[ ... ]=]`.
- Escapes in literals and classes: `\\`, `\"`, `\n`, `\r`, `\t`, `\xHH` (one byte) and `\u{H...}` (a code point); in classes also `\]`, `\-` and `\^`. Other punctuation is reserved for later operators and is an error.
- Parentheses nest at most 100 deep.

**Bytes and code points**: patterns match bytes. A literal matches the UTF-8 bytes of its text. A class of ASCII characters and `\xHH` is a set of bytes, and its negation any other byte. A class with a non-ASCII character or `\u{...}` is a set of code points, matched as their UTF-8 bytes, and its negation any other valid code point. `\xHH` above `7F` cannot be mixed with code points in one class.

**Built-in classes**:

| Name | Matches |
|---|---|
| `ALPHA` | `[A-Za-z]` |
| `DIGIT` | `[0-9]` |
| `HEXDIGIT` | `[0-9A-Fa-f]` |
| `ANY` | Any one byte |

### Lookaheads

`(?= p )` holds where the input from that position starts with a string of `p`, and `(?! p )` where it starts with none; they consume nothing, as in regular expressions. The input they see goes on after the token. A number that must not touch a letter, a dot or another digit:

```lua
number = [[ DIGIT+ ("." DIGIT+)? (?![0-9A-Za-z_.]) ]],
```

- `p` can be any pattern: choices, repetitions, fragments and nested lookaheads, of any length. Fragments still cannot be recursive, so a lookahead keeps the patterns regular.
- Lookaheads are allowed in pattern tokens (in each pattern of an [array](#arrays-of-patterns)), fragments (not written as arrays) and leading tokens. In a delimited token table (`open`, `close`, `prefix`, a capture, also through a fragment) and in `rules` they are errors (`lookahead_not_allowed`); a repeated lookahead (`(?=A)*`) is `invalid_lookahead`.
- A token is chosen by longest match, as below: at each length its lookaheads are evaluated, and the longest length at which the whole pattern holds is the match. In `[0-9]+ (?![a-z])`, the input `12a` gives the token `1`, which is followed by `2`, not a letter; write `(?![0-9a-z])` for "the whole run of digits, not followed by a letter".
- Two pattern tokens conflict when they can match the same string at the same position with both lookaheads holding on the same input. A token cannot be preferred over another, so tokens that differ by a lookahead are written with complementary conditions (`(?=p)` and `(?!p)`).
- Cost: a lookahead whose result is known after a bounded number of bytes is evaluated where needed; one without a bound (such as `(?="a"* "b")`) is also evaluated where needed while the bytes it has read on the input stay within the length of the input, and beyond that is computed for every position of the input once, from its end, so that it costs at most about twice the length of the input. `lexogram.parse` keeps this for one call; for repeated calls of `lexogram.tokenize` on one input, make an input of it once with `lexogram.input(source)` and pass that instead of the string (`tokenize(compiled, input, pos)`): the input holds the source with what is computed for it, kept apart for each compiled grammar that it is used with. Given a string, a lookahead without a bound is evaluated where it is needed, which may read up to the end of the input.

## How tokens are chosen

At a position of the source, the token is chosen in this order:

1. At position 1 only, the longest match of the leading tokens, if any.
2. The delimited token whose open matches; of several, the longest open.
3. The longest match of the pattern tokens and the literals (a pattern with lookaheads matches at a length only where they hold there).
4. Of a pattern token and a literal of the same length, the literal.
5. A byte that starts no token is an `INVALID` token of one byte.

A pattern token written as an [array of patterns](#arrays-of-patterns) is chosen by its first pattern, and a fragment written as an array by its first pattern too; the others then check its text.

Two pattern tokens (or two leading tokens) that can match the same whole string are an error (with lookaheads, only when both can hold on the same input), and so are two opens of delimited tokens; the diagnostic shows the shortest such string. A pattern token that never wins, because a literal or a longer token always takes its strings, is warned about (`never_adopted`).

## How rules are applied

The analysis is deterministic and looks at most two tokens ahead (skipped tokens are not counted).

- **Choice `|`**: the alternatives must be told apart by the next two tokens; otherwise it is an error (`ambiguous_choice`). As long as they can be told apart, their order does not matter.
- **Repetition `?`, `*`, `+`**: greedy, without backtracking. When the next tokens can start the element, the element is taken. Where two tokens of lookahead cannot tell whether to take the element or to go on, the repetition is ambiguous: that is an error (`ambiguous_repetition`), as for a choice, unless the repetition is written possessive (`?+`, `*+`, `++`), which declares that the greedy choice is intended. A possessive repetition parses the same way; one that is not ambiguous is warned about (`unneeded_possessive`). For example, in `name* name?` the `name?` can never match, which is likely a mistake and is reported; a grammar that means it writes `name*+ name?`.
- **Ordered choice `/`** (rules only): the first alternative is tried; if a syntax error occurs inside it, the input and the events are rewound to its start and the next alternative is tried. Once an alternative succeeds it is kept, even if a later part fails. When the next token cannot start an alternative, it is not tried. The overlap of the alternatives is not checked: their order decides. Nested trials can cost much time; use them only where two tokens cannot decide.
- **Syntax errors**: the analysis stops with `nil` and `{ code, pos, line, column, expected, actual, message }`. The error is at the furthest token where the analysis failed, also inside the alternatives of ordered choices that were tried and rewound, and `expected` lists the kinds expected by every failure at that token: for `stat = [[ name "=" name ";" / name "(" ")" ]]`, `f = x y` fails at `y` (expected `";"`), not at `=`, where the last alternative failed. `code` is `syntax_error`, or for a token that cannot be read `unterminated_token`, `nested_delimiter` (see [Delimited token tables](#delimited-token-tables)) or `invalid_token` (see [Arrays of patterns](#arrays-of-patterns)).

The compilation also rejects a repetition of an element that can match nothing (`nullable_repetition`), a rule that cannot derive a finite sequence of tokens (`nonterminating_rule`), and a rule that refers to a token in `skip` (`skipped_token`).

## Diagnostics

`lexogram.check(grammar)` returns a list of diagnostics, and `lexogram.compile` returns the same list (with `nil` on errors). It never raises, whatever value it is given.

```lua
-- for rules = { block = [[ stat ]], ... } without a token or rule stat
{ severity = 'error', code = 'undefined_reference', path = 'rules.block',
  pos = 2, message = 'rules.block refers to undefined token or rule "stat"' }
```

- `severity` is `'error'` or `'warning'`. Warnings are reported only when there is no error.
- `path` is the place in the grammar: `rules.block`, `tokens.long_string.open`, `symbols[3]`, `tokens["a b"]`.
- `pos` is the byte position in a pattern string, for diagnostics about a pattern.
- The list is ordered by path (top-level fields in the order of the table above), then position, then code.

| Kind | Codes |
|---|---|
| Structure | `invalid_type`, `missing_field`, `unknown_field`, `invalid_key`, `invalid_value`, `invalid_version`, `version_too_new`, `version_too_old`, `empty_item`, `duplicate_item`, `reserved_item`, `invalid_name`, `reserved_name`, `duplicate_name`, `undefined_reference`, `invalid_reference`, `undeclared_literal` |
| Pattern | `unexpected_char`, `unterminated_literal`, `empty_literal`, `invalid_escape`, `unterminated_class`, `empty_class`, `invalid_range`, `mixed_class`, `invalid_utf8`, `invalid_codepoint`, `unbalanced_paren`, `missing_operand`, `repeated_postfix`, `mixed_choice`, `class_not_allowed`, `ordered_choice_not_allowed`, `possessive_not_allowed`, `lookahead_not_allowed`, `invalid_lookahead`, `invalid_repetition`, `alias_not_allowed`, `invalid_alias`, `unknown_builtin`, `invalid_reference`, `reserved_name`, `nesting_too_deep` |
| Tokens | `fragment_recursion`, `empty_match`, `token_conflict`, `literal_conflict`, `invalid_delimiter`, `capture_overlap`, `delimiter_conflict`, `invalid_contextual`, `unmatchable_pattern`, `automaton_too_large` |
| Rules | `left_recursion`, `nonterminating_rule`, `nullable_repetition`, `skipped_token`, `ambiguous_choice`, `ambiguous_repetition` |
| Warnings | `never_adopted`, `unneeded_possessive`, `unused_token`, `unused_fragment`, `unused_literal`, `unreachable_rule` |
| Warnings of the merge | `already_defined` (a [mixin](#mixins) adds what exists; returned by `lexogram.load`, `lexogram.merge` and `lexogram.grammar`, with the mixin as `source`) |
