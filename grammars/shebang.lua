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
-- The built-in mixin "lexogram:shebang" (module lexogram.grammars.shebang):
-- a first line that starts with "#" as the leading token shebang, which is
-- skipped.
--
-- The file loaders of Lua skip such a line, so that a script can start with
-- a shebang line ("#!/usr/bin/env lua"), while the parser itself rejects
-- it. A grammar that reads files as the loader does embeds this mixin
-- (embeds = { 'lexogram:shebang' }); a "#" anywhere else is left to the
-- grammar (the length operator in Lua).
return assert(require('lexogram.grammar')({
    mixin = true,
    lexogram = '2026.11.15.1',
    name = 'shebang',
    version = '1.0.0',
    ['++tokens'] = {
        -- the rest of the line, up to the newline as the loader reads it
        shebang = [[ "#" [^\n]* ]],
    },
    ['+leading'] = {
        'shebang',
    },
    ['+skip'] = {
        'shebang',
    },
}))
