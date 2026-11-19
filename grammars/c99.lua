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
-- C99 grammar for lexogram. doc/grammars/c99.md describes it in Markdown,
-- with the choices made where C cannot be parsed without knowing which
-- identifiers name types, and the results on real sources.
--
-- The grammar reads a C source as written, before preprocessing: a
-- directive is a token that the rules skip, and macros are not expanded,
-- so the code outside the directives must have the syntax of C99 as it is
-- (ISO/IEC 9899:1999, Annex A). The rules follow the names of Annex A.
--
-- Metadata
--
--   lexogram  '2026.11.15.1'
--   name      'c99', the built-in grammar "lexogram:c99" (module
--             lexogram.grammars.c99)
--   version   '1999-1', the year of the standard and the revision of the
--             grammar
--
-- start
--
-- translation_unit, any number of external declarations (a source of
-- directives and comments only is one with none).
--
-- tokens
--
--   identifier          letters, digits, "_" and universal character names
--                       (\uXXXX, \UXXXXXXXX), not starting with a digit
--   number              a preprocessing number (digits, letters, "_", dots,
--                       and a sign after e, E, p or P), which must be an
--                       integer constant (decimal, octal or hexadecimal,
--                       with the suffixes u, l and ll) or a floating constant
--                       (decimal or hexadecimal, with the suffixes f and l);
--                       a run of another form is an invalid number (08,
--                       1.2.3, 0x1e+1)
--   character_constant  'c' and L'c', with the escapes of C99
--   string_literal      "..." and L"...", with the escapes of C99; a
--                       backslash and a line break (a line splice) may be
--                       inside
--   space               white space, and a line splice between tokens; not a
--                       line break that a directive follows
--   line_comment        "//" to the end of the line (a line splice goes on)
--   block_comment       "/*" to "*/"
--   directive           a line break, then a line whose first token is "#"
--                       or "%:", up to the end of the line, with its line
--                       splices, comments (a block comment can go on to other
--                       lines) and quoted text (a quote not closed on the
--                       line, as in an #error message, runs to its end,
--                       and a comment does not start inside it)
--   first_directive     the same at the start of the source (leading)
--
-- symbols and keywords
--
-- The punctuators of C99 that the rules use, with the digraphs <: :> <% %>
-- for [ ] { }, and the 37 keywords of C99. "#", "##", "%:" and "%:%:" are
-- read inside directives only.
--
-- skip
--
--   space, line_comment, block_comment, directive, first_directive
--
-- rules
--
-- Rules with events:
--
--   translation_unit, external_declaration, function_definition,
--   declaration, storage_class_specifier, type_specifier, typedef_name,
--   type_qualifier, function_specifier, init_declarator_list,
--   init_declarator, struct_or_union_specifier, struct_declaration,
--   struct_declarator_list, struct_declarator, enum_specifier, enumerator,
--   declarator, direct_declarator, pointer, function_suffix,
--   parameter_type_list, parameter_declaration, type_name,
--   abstract_declarator, direct_abstract_declarator, initializer,
--   initializer_list, designation, designator, statement,
--   labeled_statement, compound_statement, block_item,
--   expression_statement, selection_statement, iteration_statement,
--   jump_statement, expression, assignment_expression, conditional,
--   constant_expression, assignment_operator, binary_operator,
--   unary_operator, sizeof_expression, cast_expression,
--   postfix_expression, compound_literal, argument_expression_list
--
-- Which identifiers name types
--
-- Whether an identifier names a type decides how C is parsed, and it
-- depends on declarations that this grammar does not track. An identifier
-- may be a type specifier (typedef_name), and the forms that both readings
-- fit are told apart by trials (ordered choices):
--
--   - In the specifiers of a declaration, an identifier is tried first as
--     the start of the declarators with the rest of the declaration (up to
--     its ";", or its body for a function definition), then as a type name:
--     T x; declares x of type T, and MACRO T *x; reads MACRO and T as types.
--   - In a parameter declaration, an identifier before the first type
--     specifier is a type name; after it, the identifier is tried as the
--     declarator first (int f(const T x)).
--   - A function declarator is followed by no other suffix (a function
--     returns no function or array), and a declarator that is an identifier
--     in parentheses is followed by a suffix: int (f)(void) declares f, and
--     f(x); in a block is a call, not a declaration of x.
--   - A block item is tried as a declaration first: T *p; declares p, and
--     so does a * b; which multiplies only when a is not a type.
--   - A cast is tried before a parenthesized expression: (T)x is a cast,
--     and so is (a) - b, which subtracts only when a is not a type.
--   - sizeof is tried with a type name first: sizeof(x) reads x as a type
--     name either way, and sizeof (a)[0] is an error (sizeof(T) * n would
--     otherwise be sizeof((T) * n)).
--
-- Expressions
--
-- An expression lists its terms and operators in order, without precedence;
-- a consumer applies the precedence of C. A term is a postfix_expression
-- (an operand with its suffixes), after its unary operators, "++" or "--",
-- sizeof or a cast; assignment_expression and constant_expression end with
-- an assignment or a conditional, and expression is a list of
-- assignment_expression.
return assert(require('lexogram.grammar')({
    lexogram = '2026.11.15.1',
    name = 'c99',
    version = '1999-1',
    start = 'translation_unit',
    tokens = {
        identifier = [[ _nondigit (_nondigit | DIGIT)* ]],
        _nondigit = [[ [A-Za-z_] | _ucn ]],
        _ucn = [[ "\\u" HEXDIGIT{4} | "\\U" HEXDIGIT{8} ]],
        -- the preprocessing number, then the forms of the constants that it
        -- must have
        number = {
            [[ "."? DIGIT ([0-9A-Za-z_.] | [eEpP] ("+" | "-") | _ucn)* ]],
            [[ _integer_constant | _floating_constant ]],
        },
        _integer_constant = [[
            ([1-9] DIGIT* | "0" [0-7]* | "0" [xX] HEXDIGIT+)
            ([uU] _long? | _long [uU]?)?
        ]],
        _long = [[ "l" | "L" | "ll" | "LL" ]],
        _floating_constant = [[
            (
                (DIGIT* "." DIGIT+ | DIGIT+ ".") _exponent?
                | DIGIT+ _exponent
                | "0" [xX] (HEXDIGIT* "." HEXDIGIT+ | HEXDIGIT+ "."?)
                  [pP] ("+" | "-")? DIGIT+
            ) [fFlL]?
        ]],
        _exponent = [[ [eE] ("+" | "-")? DIGIT+ ]],
        character_constant = [[ "L"? "'" ([^'\\\n\r] | _escape)+ "'" ]],
        string_literal = [[ "L"? "\"" ([^"\\\n\r] | _escape)* "\"" ]],
        -- the escapes, and a backslash and a line break (a line splice)
        _escape = [[
            "\\" (
                ['"?\\abfnrtv]
                | [0-7] [0-7]? [0-7]?
                | "x" HEXDIGIT+
                | "u" HEXDIGIT{4}
                | "U" HEXDIGIT{8}
                | _line_break
            )
        ]],
        _line_break = [[ "\r\n" | "\n" | "\r" ]],
        _blank = [[ [ \t\x0B\x0C] ]],
        -- a line break that a directive follows is part of the directive
        space = [[
            (
                _blank
                | _line_break (?!_blank* ("#" | "%:"))
                | "\\" _line_break
            )+
        ]],
        line_comment = [[
            "//" ([^\\\n\r] | "\\" (_line_break | [^\n\r]))* "\\"?
        ]],
        block_comment = {
            open = [[ "/*" ]],
            close = [[ "*/" ]],
        },
        directive = [[ _line_break _blank* _directive ]],
        first_directive = [[ _blank* _directive ]],
        _directive = [[ ("#" | "%:") _directive_body ]],
        _directive_body = [[
            (
                [^\n\r\\/"']
                | "\\" (_line_break | [^\n\r])
                | "/*" ([^*] | "*"+ [^*/])* "*"+ "/"
                | "//" ([^\\\n\r] | "\\" (_line_break | [^\n\r]))*
                | "/" (?![*/])
                | "\"" ([^"\\\n\r] | "\\" (_line_break | [^\n\r]))*
                  ("\"" | (?![^\n\r]))
                | "'" ([^'\\\n\r] | "\\" (_line_break | [^\n\r]))*
                  ("'" | (?![^\n\r]))
            )*
        ]],
    },
    symbols = {
        '[',
        ']',
        '(',
        ')',
        '{',
        '}',
        '.',
        '->',
        '++',
        '--',
        '&',
        '*',
        '+',
        '-',
        '~',
        '!',
        '/',
        '%',
        '<<',
        '>>',
        '<',
        '>',
        '<=',
        '>=',
        '==',
        '!=',
        '^',
        '|',
        '&&',
        '||',
        '?',
        ':',
        ';',
        '...',
        '=',
        '*=',
        '/=',
        '%=',
        '+=',
        '-=',
        '<<=',
        '>>=',
        '&=',
        '^=',
        '|=',
        ',',
        '<:',
        ':>',
        '<%',
        '%>',
    },
    keywords = {
        'auto',
        'break',
        'case',
        'char',
        'const',
        'continue',
        'default',
        'do',
        'double',
        'else',
        'enum',
        'extern',
        'float',
        'for',
        'goto',
        'if',
        'inline',
        'int',
        'long',
        'register',
        'restrict',
        'return',
        'short',
        'signed',
        'sizeof',
        'static',
        'struct',
        'switch',
        'typedef',
        'union',
        'unsigned',
        'void',
        'volatile',
        'while',
        '_Bool',
        '_Complex',
        '_Imaginary',
    },
    skip = {
        'space',
        'line_comment',
        'block_comment',
        'directive',
        'first_directive',
    },
    leading = {
        'first_directive',
    },
    rules = {
        -- external definitions
        translation_unit = [[ external_declaration* ]],
        external_declaration = [[ function_definition / declaration ]],
        function_definition = [[
            _keyword_specifier _function_rest | type_specifier _function_rest
        ]],
        _function_rest = [[
            _keyword_specifier _function_rest
            | (
                (declarator declaration* compound_statement)
                / (type_specifier _function_rest)
            )
        ]],

        -- declarations: an identifier after a specifier is tried as the
        -- start of the declarators with the rest of the declaration, then
        -- as a type name
        declaration = [[
            _keyword_specifier _declaration_rest
            | type_specifier _declaration_rest
        ]],
        _declaration_rest = [[
            _keyword_specifier _declaration_rest
            | (
                (init_declarator_list? ";")
                / (type_specifier _declaration_rest)
            )
        ]],
        _keyword_specifier = [[
            storage_class_specifier | _keyword_type_specifier | type_qualifier
            | function_specifier
        ]],
        storage_class_specifier = [[
            "typedef" | "extern" | "static" | "auto" | "register"
        ]],
        _keyword_type_specifier = [[ (_type_keyword)->type_specifier ]],
        _type_keyword = [[
            "void" | "char" | "short" | "int" | "long" | "float" | "double"
            | "signed" | "unsigned" | "_Bool" | "_Complex" | "_Imaginary"
            | struct_or_union_specifier | enum_specifier
        ]],
        type_specifier = [[ typedef_name ]],
        typedef_name = [[ identifier ]],
        type_qualifier = [[ "const" | "restrict" | "volatile" ]],
        function_specifier = [[ "inline" ]],
        init_declarator_list = [[ init_declarator ("," init_declarator)* ]],
        init_declarator = [[ declarator ("=" initializer)? ]],

        struct_or_union_specifier = [[
            ("struct" | "union")
            (identifier _struct_body? | _struct_body)
        ]],
        _struct_body = [[ _lbrace struct_declaration+ _rbrace ]],
        struct_declaration = [[
            _qualifier_or_keyword_type _struct_rest
            | type_specifier _struct_rest
        ]],
        _struct_rest = [[
            _qualifier_or_keyword_type _struct_rest
            | (
                (struct_declarator_list ";")
                / (type_specifier _struct_rest)
            )
        ]],
        _qualifier_or_keyword_type = [[
            _keyword_type_specifier | type_qualifier
        ]],
        struct_declarator_list = [[
            struct_declarator ("," struct_declarator)*
        ]],
        struct_declarator = [[
            declarator (":" constant_expression)? | ":" constant_expression
        ]],
        enum_specifier = [[
            "enum" (identifier _enum_body? | _enum_body)
        ]],
        _enum_body = [[
            _lbrace enumerator ("," enumerator)* ","? _rbrace
        ]],
        enumerator = [[ identifier ("=" constant_expression)? ]],

        -- declarators: a function declarator is followed by no other
        -- suffix, and an identifier in parentheses is followed by one
        declarator = [[ pointer? direct_declarator ]],
        direct_declarator = [[ identifier _suffixes | "(" _parenthesized ]],
        _parenthesized = [[
            ((identifier)->direct_declarator)->declarator ")"
              _required_suffixes
            | ((identifier _required_suffixes)->direct_declarator)->declarator
              ")" _suffixes
            | (pointer direct_declarator)->declarator ")" _suffixes
            | (("(" _parenthesized)->direct_declarator)->declarator ")"
              _suffixes
        ]],
        _suffixes = [[ _array_suffix* function_suffix? ]],
        _required_suffixes = [[
            _array_suffix+ function_suffix? | function_suffix
        ]],
        pointer = [[ ("*" type_qualifier*)+ ]],
        _array_suffix = [[ _lbracket _array_size? _rbracket ]],
        _array_size = [[
            "static" type_qualifier* assignment_expression
            | type_qualifier+ ("static"? assignment_expression | "*")?
            | "*"
            | assignment_expression
        ]],
        function_suffix = [[ "(" parameter_type_list? ")" ]],
        parameter_type_list = [[
            parameter_declaration ("," parameter_declaration)* ("," "...")?
        ]],
        -- an identifier before the first type specifier is a type name;
        -- after it, an identifier is tried as the declarator first
        parameter_declaration = [[
            _nontype_specifier* _type_part _parameter_rest?
        ]],
        _nontype_specifier = [[
            storage_class_specifier | type_qualifier | function_specifier
        ]],
        _type_part = [[ _keyword_type_specifier | type_specifier ]],
        _parameter_rest = [[
            _keyword_specifier _parameter_rest?
            | (
                declarator / abstract_declarator
                / (type_specifier _parameter_rest?)
            )
        ]],
        type_name = [[
            (_qualifier_or_keyword_type | type_specifier)+ abstract_declarator?
        ]],
        abstract_declarator = [[
            pointer direct_abstract_declarator? | direct_abstract_declarator
        ]],
        direct_abstract_declarator = [[
            ("(" abstract_declarator ")" | _array_suffix | function_suffix)
            _array_suffix* function_suffix?
        ]],
        initializer = [[
            assignment_expression | _lbrace initializer_list ","? _rbrace
        ]],
        initializer_list = [[
            designation? initializer ("," designation? initializer)*
        ]],
        designation = [[ designator+ "=" ]],
        designator = [[
            _lbracket constant_expression _rbracket | "." identifier
        ]],

        -- brackets and braces, also written as digraphs
        _lbracket = [[ "[" | "<:" ]],
        _rbracket = [[ "]" | ":>" ]],
        _lbrace = [[ "{" | "<%" ]],
        _rbrace = [[ "}" | "%>" ]],

        -- statements; a block item is tried as a declaration first
        statement = [[
            labeled_statement | compound_statement | expression_statement
            | selection_statement | iteration_statement | jump_statement
        ]],
        labeled_statement = [[
            identifier ":" statement | "case" constant_expression ":" statement
            | "default" ":" statement
        ]],
        compound_statement = [[ _lbrace block_item* _rbrace ]],
        block_item = [[ declaration / statement ]],
        expression_statement = [[ expression? ";" ]],
        -- an else belongs to the nearest if
        selection_statement = [[
            "if" "(" expression ")" statement ("else" statement)?+
            | "switch" "(" expression ")" statement
        ]],
        iteration_statement = [[
            "while" "(" expression ")" statement
            | "do" statement "while" "(" expression ")" ";"
            | "for" "(" (declaration / expression? ";") expression? ";"
              expression? ")" statement
        ]],
        jump_statement = [[
            "goto" identifier ";" | "continue" ";" | "break" ";"
            | "return" expression? ";"
        ]],

        -- expressions: terms and operators in order, without precedence; a
        -- cast is tried before a parenthesized expression, and sizeof with
        -- a type name first
        expression = [[ assignment_expression ("," assignment_expression)* ]],
        assignment_expression = [[
            _binary_expression
            (assignment_operator assignment_expression | conditional)?
        ]],
        conditional = [[ "?" expression ":" assignment_expression ]],
        constant_expression = [[ _binary_expression conditional? ]],
        assignment_operator = [[
            "=" | "*=" | "/=" | "%=" | "+=" | "-=" | "<<=" | ">>=" | "&="
            | "^=" | "|="
        ]],
        _binary_expression = [[ _term (binary_operator _term)* ]],
        binary_operator = [[
            "*" | "/" | "%" | "+" | "-" | "<<" | ">>" | "<" | ">" | "<=" | ">="
            | "==" | "!=" | "&" | "^" | "|" | "&&" | "||"
        ]],
        _term = [[
            unary_operator _term | ("++" | "--") _term | sizeof_expression
            | (cast_expression / postfix_expression)
        ]],
        unary_operator = [[ "&" | "*" | "+" | "-" | "~" | "!" ]],
        sizeof_expression = [[ "sizeof" ("(" type_name ")" / _term) ]],
        cast_expression = [[ "(" type_name ")" _term ]],
        postfix_expression = [[ _primary_expression _postfix_suffix* ]],
        _primary_expression = [[
            identifier | number | character_constant | string_literal+
            | (compound_literal / "(" expression ")")
        ]],
        compound_literal = [[
            "(" type_name ")" _lbrace initializer_list ","? _rbrace
        ]],
        _postfix_suffix = [[
            _lbracket expression _rbracket | "(" argument_expression_list? ")"
            | ("." | "->") identifier | "++" | "--"
        ]],
        argument_expression_list = [[
            assignment_expression ("," assignment_expression)*
        ]],
    },
}))
