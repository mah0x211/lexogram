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
-- Lua 5.2 grammar with a byte order mark and a first line that starts with
-- "#" skipped, the built-in grammar "lexogram:lua52_shebang" (module
-- lexogram.grammars.lua52_shebang).
--
-- The file loader of Lua 5.2 (luaL_loadfilex) skips a UTF-8 byte order
-- mark at the start of a file, and then a line that starts with "#", so
-- that a script can start with a shebang line ("#!/usr/bin/env lua"); the
-- parser itself rejects both, which "lexogram:lua52" follows. This grammar
-- adds them as the leading token shebang, which is skipped: a byte order
-- mark, a line that starts with "#", or a byte order mark and such a line
-- (two leading tokens cannot follow each other, so it is one token). It is
-- otherwise the same as lua52.
--
-- The token keeps the name shebang of lua51_shebang, although in Lua 5.2
-- it may be or begin with a byte order mark: the file loader removes a
-- byte order mark before it looks for the "#" line. For the operating
-- system, a byte order mark before "#!" makes the shebang line unusable;
-- Lua reads such a file all the same.
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua52',
    lexogram = '2026.11.15.1',
    name = 'lua52_shebang',
    version = '1.0.0',
    ['++tokens'] = {
        -- the rest of the line, up to the newline as the loader reads it
        shebang = [[ "\xEF\xBB\xBF" ("#" [^\n]*)? | "#" [^\n]* ]],
    },
    ['+leading'] = {
        'shebang',
    },
    ['+skip'] = {
        'shebang',
    },
}))
