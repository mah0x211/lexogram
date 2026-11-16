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
-- lexogram: public entry point of the lexogram library.
-- load(pathname) loads a grammar file (see lexogram.loader) and
-- check(grammar) returns the diagnostics of a grammar table (see
-- lexogram.check), compile(grammar) compiles it into plain data (see
-- lexogram.compile) and tokenize(compiled, source, pos, mode) finds the
-- token at a position (see lexogram.tokenizer).
local loader = require('lexogram.loader')
local check = require('lexogram.check')
local compile = require('lexogram.compile')
local tokenizer = require('lexogram.tokenizer')

return {
    load = loader.load,
    check = check.check,
    compile = compile.compile,
    tokenize = tokenizer.tokenize,
}
