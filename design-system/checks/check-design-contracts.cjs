const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
for (const entry of ['catalog/index.html', 'prototype/index.html', 'prototype/plan.html', 'windows-preview/index.html']) {
  const html = read(entry);
  for (const file of ['typography.css', 'components.css', ...(entry.endsWith('plan.html') ? [] : ['controls.css'])]) {
    assert.ok(html.includes('../' + file), `${entry} does not load ${file}`);
  }
}
for (const [script, entry] of [['prototype/app.js', 'prototype/index.html'], ['catalog/catalog.js', 'catalog/index.html']]) {
  const source = read(script);
  assert.ok(read(entry).includes('../components.js'), `${entry} does not load shared views`);
  for (const component of ['meetingRow', 'personRow', 'utterance', 'minutes', 'dialogContent']) {
    assert.ok(source.includes('UI.' + component), `${script} does not use ${component}`);
  }
  for (const duplicated of ['<article class="utterance', '<article class="minutes-document', '<span class="person-voice-status"']) {
    assert.ok(!source.includes(duplicated), `${script} duplicated shared markup: ${duplicated}`);
  }
}
const typography = read('typography.css');
for (const role of ['body', 'label', 'caption', 'aux', 'subtitle', 'reading', 'heading', 'title', 'display', 'code', 'timer']) {
  assert.ok(typography.includes('.type-' + role), `Missing typography role: ${role}`);
}
assert.match(typography, /--font-ui:[^;]*Malgun Gothic[^;]*Apple SD Gothic Neo|--font-ui:[^;]*Apple SD Gothic Neo[^;]*Malgun Gothic/);
assert.match(typography, /font-variant-numeric:\s*tabular-nums/);
for (const file of ['style.css', 'components.css', 'controls.css', 'desktop-preview.css', 'windows-preview/windows.css', 'windows-preview/bridge.css']) {
  const css = read(file);
  assert.ok(!/font-size:\s*\d/.test(css), `${file} gained a raw product text size`);
  assert.ok(!/Avenir|Segoe UI|Malgun Gothic|SFMono-Regular|Consolas/.test(css), `${file} gained a separate font-family contract`);
}
console.log('PASS: shared foundations, view consumers, typography roles and platform font ownership.');
