--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
--
-- Lua 5.5 grammar for lexogram. doc/grammars/lua55.md has the same text
-- in Markdown.
--
-- The grammar extends "lexogram:lua54" with the changes of the Lua 5.5
-- reference manual (section 9, the complete syntax, and section 3.1, the
-- lexical conventions) and of its lexer and parser (llex.c, lparser.c).
-- doc/grammars/lua54.md and the documents it refers to describe what it
-- inherits; the sections below follow the top-level fields of the table
-- returned at the end of this file and tell what changes.
--
-- Metadata
--
-- The fields lexogram, name and version tell which grammar this is.
--
--   extends   'lexogram:lua54'
--   lexogram  '2026.11.15.1'
--   name      'lua55', the built-in grammar "lexogram:lua55" (module
--             lexogram.grammars.lua55)
--   version   '1.0.0'
--
-- It accepts the syntax as the parser of Lua 5.5 built by default does
-- (load), where LUA_COMPAT_GLOBAL makes global no reserved word.
--
-- keywords
--
-- global is a contextual keyword (keywords.contextual): a name, read as
-- the token name, that is the keyword where a statement starts with it
-- and the rules below match it. Elsewhere it is a name: local global = 1,
-- global.x = 1 and global(1) are valid. The reference manual lists global
-- as a reserved word, as it is when Lua is built without
-- LUA_COMPAT_GLOBAL; the default build parses it as here.
--
-- tokens
--
-- The tokens are those of lua54: the lexer of Lua 5.5 reads numbers,
-- strings and escapes as that of Lua 5.4 does.
--
-- rules
--
-- A global declaration, an attribute before the names of a declaration,
-- and a name for the vararg parameter. Two rules are added, two are
-- replaced and _stat is split in two; the others are those of lua54:
--
--   _stat         (globalfunc | globalstat) / _stat_rest  replaced
--   _stat_rest    ";" | exprstat | dostat | whilestat | repeatstat
--                 | ifstat | forstat | funcstat | localfunc | localstat
--                 | labelstat | gotostat | breakstat     added (the
--                                                         _stat of lua54)
--   globalfunc    "global" "function" name body          added
--   globalstat    "global" attrib? ("*" | name attrib?
--                 ("," name attrib?)* ("=" explist)?)    added
--   attnamelist   attrib? name attrib? ("," name attrib?)*
--                                                         replaced
--   parlist       name ("," name)* ("," "..." name?)?
--                 | "..." name?                          replaced
--
-- A statement that starts with global is tried as a declaration first,
-- and as any other statement when that fails (an ordered choice, see
-- doc/grammar.md): the parser of Lua 5.5 takes it as a declaration when
-- the next token is "<", a name, "*" or function, where no other
-- statement can go on, and as another statement otherwise, where no
-- declaration can. The trial is made only when the statement starts with
-- global. A syntax error inside a declaration is therefore reported where
-- the other statements fail (after global), not where the declaration
-- does.
--
-- An attribute before the names applies to every name without one of its
-- own (local <const> x, y <close>), and global <const> * declares every
-- other global read-only; the names of the attributes are not syntax.
--
-- Expressions
--
-- The operators and their priorities are those of lua54.
--
-- Differences from Lua 5.5
--
-- The grammar accepts every source that Lua 5.5 accepts, and some that it
-- rejects: those of lua54 (the checks that are not syntax, including those
-- of goto and of the attributes), and the checks of the declarations of
-- globals (an assignment to a global declared <const>, a global declared
-- <close>, a name that is not declared where global declarations are in
-- effect, an assignment to a for variable or to the vararg parameter).
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua54',
    lexogram = '2026.11.15.1',
    name = 'lua55',
    version = '1.0.0',
    ['++keywords'] = {
        contextual = {
            'global',
        },
    },
    ['++rules'] = {
        globalfunc = [[ "global" "function" name body ]],
        globalstat = [[
            "global" attrib? ("*" | name attrib? ("," name attrib?)*
                                     ("=" explist)?)
        ]],
        _stat_rest = [[
            ";" | exprstat | dostat | whilestat | repeatstat | ifstat
            | forstat | funcstat | localfunc | localstat | labelstat
            | gotostat | breakstat
        ]],
    },
    rules = {
        ['=_stat'] = [[ (globalfunc | globalstat) / _stat_rest ]],
        ['=attnamelist'] = [[ attrib? name attrib? ("," name attrib?)* ]],
        ['=parlist'] = [[ name ("," name)* ("," "..." name?)? | "..." name? ]],
    },
}))
