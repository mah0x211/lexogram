local testcase = require('testcase')
local assert = require('assert')
local lexogram = require('lexogram')
local builtin_value = require('lexogram.grammar').builtin_value

function testcase.shebang_adds_a_leading_token()
    local chain, err, kind = builtin_value('shebang')

    assert.is_nil(err)
    assert.equal(kind, 'mixin')
    assert.equal(#chain, 1)
    assert.equal(chain[1].source, 'lexogram:shebang')
    assert.equal(chain[1].diff['++tokens'], {
        shebang = ' "#" [^\\n]* ',
    })
    assert.equal(chain[1].diff['+leading'], {
        'shebang',
    })
    assert.equal(chain[1].diff['+skip'], {
        'shebang',
    })
end

function testcase.bom_shebang_extends_shebang()
    local chain, err, kind = builtin_value('bom_shebang')

    assert.is_nil(err)
    assert.equal(kind, 'mixin')
    assert.equal({
        chain[1].source,
        chain[2].source,
    }, {
        'lexogram:shebang',
        'lexogram:bom_shebang',
    })
    assert.equal(chain[2].diff.tokens, {
        ['=shebang'] = ' "\\xEF\\xBB\\xBF" ("#" [^\\n]*)? | "#" [^\\n]* ',
    })
end

function testcase.mixins_are_no_grammars()
    for _, name in ipairs({
        'shebang',
        'bom_shebang',
    }) do
        local grammar, err = lexogram.load('lexogram:' .. name)
        assert.is_nil(grammar)
        assert.equal(err, 'lexogram:' .. name ..
                         ': a mixin is not a grammar (embed it with embeds)')
    end
end

function testcase.grammars_embed_the_mixins()
    -- the token of each grammar is that of its mixin
    local lua51 = assert(lexogram.load('lexogram:lua51_shebang'))
    local lua52 = assert(lexogram.load('lexogram:lua52_shebang'))

    assert.equal(lua51.tokens.shebang, ' "#" [^\\n]* ')
    assert.equal(lua52.tokens.shebang,
                 ' "\\xEF\\xBB\\xBF" ("#" [^\\n]*)? | "#" [^\\n]* ')
    for _, grammar in ipairs({
        lua51,
        lua52,
    }) do
        assert.equal(grammar.leading, {
            'shebang',
        })
        assert.equal(grammar.skip[#grammar.skip], 'shebang')
        assert.is_nil(grammar.embeds)
    end
end
