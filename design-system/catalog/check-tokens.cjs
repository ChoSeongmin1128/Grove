const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { build } = require('./build-tokens.cjs');

const current = build();
const saved = JSON.parse(fs.readFileSync(path.join(__dirname, 'tokens.json'), 'utf8'));
assert.deepEqual(saved, current, 'Source drift: review source and regenerate tokens.json.');
const ids = [...saved.tokens, ...saved.metrics].map((item) => item.id);
assert.equal(new Set(ids).size, ids.length, 'Declaration identities must be unique.');
assert.equal(saved.audit.unresolvedReferences.length, 0, 'An input CSS variable has no definition or fallback.');
assert.equal(saved.themes.resolved.length, saved.themes.colors.length * saved.themes.resolvedModes.length);
const tokenIds = new Set(saved.tokens.map((item) => item.id));
const expectedNames = Object.keys(saved.themes.resolved[0].values).sort();
for (const theme of saved.themes.resolved) {
  assert.deepEqual(Object.keys(theme.values).sort(), expectedNames, `${theme.id}: incomplete role set.`);
  for (const [name, value] of Object.entries(theme.resolvedValues)) {
    assert.ok(!value.includes('var('), `${theme.id} ${name}: unresolved reference.`);
    assert.ok(tokenIds.has(theme.provenance[name]), `${theme.id} ${name}: missing source declaration.`);
  }
}
const desktopTokens = saved.tokens.filter((item) => item.name.startsWith('--desktop-') || item.name.startsWith('--overlay-') || item.name.startsWith('--win-'));
assert.ok(desktopTokens.length > 0);
assert.ok(desktopTokens.every((item) => !item.selector.includes('data-color')), 'Desktop neutral colors gained a color-theme dependency.');
console.log(`PASS: source snapshot, declaration identities, references, ${saved.themes.resolved.length} theme role sets and desktop color independence.`);
console.log('This checks source integrity. It does not establish browser layout, color contrast or native platform behavior.');
