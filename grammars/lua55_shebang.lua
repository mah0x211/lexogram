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
-- Lua 5.5 grammar with a byte order mark and a first line that starts with
-- "#" skipped, the built-in grammar "lexogram:lua55_shebang" (module
-- lexogram.grammars.lua55_shebang).
--
-- The file loader of Lua 5.5 (luaL_loadfilex) skips a UTF-8 byte order
-- mark at the start of a file, and then a line that starts with "#", so
-- that a script can start with a shebang line ("#!/usr/bin/env lua"); the
-- parser itself rejects both, which "lexogram:lua55" follows. This grammar
-- embeds the mixin "lexogram:bom_shebang", which adds them as the leading
-- token shebang, which is skipped: a byte order mark, a line that starts
-- with "#", or a byte order mark and such a line. It is otherwise the same
-- as lua55.
return assert(require('lexogram.grammar')({
    extends = 'lexogram:lua55',
    embeds = {
        'lexogram:bom_shebang',
    },
    lexogram = '2026.11.15.1',
    name = 'lua55_shebang',
    version = '5.5.1-1',
}))
