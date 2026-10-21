import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../src/speakers-ui.js', import.meta.url), 'utf8');
const tick = () => new Promise(setImmediate);
const plain = value => JSON.parse(JSON.stringify(value));
const escape = value => String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
const decode = value => value.replace(/&(?:amp|lt|gt|quot|#39);/g, entity => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" })[entity]);
const documentForTest = () => ({
  version: { id: 'document', revision: 0 },
  speakers: [{ id: 'S1', name: '화자 1' }, { id: 'S2', name: '화자 2' }],
  segments: [
    { id: 'a', start: 1, end: 2, speakerId: 'S1', originalText: '첫 발언', text: '첫 발언' },
    { id: 'b', start: 3, end: 4, speakerId: 'S2', originalText: '다음 발언', text: '다음 발언' },
    { id: 'c', start: 5, end: 6, speakerId: 'S1', originalText: '마지막 발언', text: '마지막 발언' },
  ],
});

function openController(doc = documentForTest()) {
  const elements = new Map();
  const document = { activeElement: null };
  function element(tagName, attributes = {}) {
    const node = { tagName: tagName.toUpperCase(), attributes, id: attributes.id || '', dataset: {}, listeners: new Map(), children: [], textContent: '', value: attributes.value || '', hidden: Object.hasOwn(attributes, 'hidden'), disabled: false, checked: Object.hasOwn(attributes, 'checked'), isConnected: true, open: false,
      addEventListener(name, callback) { this.listeners.set(name, callback); },
      hasAttribute(name) { return Object.hasOwn(this.attributes, name); },
      closest(selector) { return selector === 'button' && this.tagName === 'BUTTON' ? this : null; },
      focus() { document.activeElement = this; },
      blur() { document.activeElement = null; this.onBlur?.(); },
      showModal() { this.open = true; }, close() { this.open = false; this.listeners.get('close')?.(); },
      querySelectorAll(selector) { return this.children.filter(child => selector.split(',').some(part => { const name = part.trim(); return name.startsWith('[') ? child.hasAttribute(name.slice(1, -1)) : child.tagName.toLowerCase() === name; })); },
      querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
    };
    for (const [key, value] of Object.entries(attributes)) if (key.startsWith('data-')) node.dataset[key.slice(5).replace(/-([a-z])/g, (_, character) => character.toUpperCase())] = value;
    if (node.id) elements.set(node.id, node);
    return node;
  }
  const trigger = element('button', { id: 'speakers-button' });
  const dialog = element('dialog', { id: 'speaker-dialog' });
  const body = element('div', { id: 'speaker-dialog-body' });
  element('div', { id: 'transcript-rows' });
  let html = '', writes = 0;
  Object.defineProperty(body, 'innerHTML', { get: () => html, set(value) {
    for (const node of body.children) { node.isConnected = false; if (node.id) elements.delete(node.id); }
    html = value; writes += 1;
    body.children = [...value.matchAll(/<(button|input|select|option|span|p|h2)\b([^>]*)>/g)].map(match => {
      const attributes = Object.fromEntries([...match[2].matchAll(/([\w-]+)(?:="([^"]*)")?/g)].map(attribute => [attribute[1], decode(attribute[2] || '')]));
      return element(match[1], attributes);
    });
    for (const match of value.matchAll(/<select\b([^>]*)>([\s\S]*?)<\/select>/g)) {
      const id = /id="([^"]+)"/.exec(match[1])?.[1];
      const options = [...match[2].matchAll(/<option\b([^>]*)>/g)];
      const chosen = options.find(option => /\bselected\b/.test(option[1])) || options[0];
      if (id && chosen) elements.get(id).value = decode(/value="([^"]*)"/.exec(chosen[1])?.[1] || '');
    }
  } });
  document.activeElement = trigger;
  const state = { selectedId: 'meeting', connected: true, busy: false, editLocks: 0, snapshot: { meetings: [{ id: 'meeting' }] }, processing: { status: 'idle' }, transcriptDraft: { id: 'meeting', doc: structuredClone(doc) } };
  const calls = [], errors = [], updates = [], flushes = [];
  let beforeFlush = null;
  const bridge = { saveSpeakers(id, expected, speakers, assignments) {
    return new Promise((resolve, reject) => calls.push({ id, expected: plain(expected), speakers: plain(speakers), assignments: plain(assignments), reject, resolve() {
      const current = state.transcriptDraft.doc;
      resolve({ ...structuredClone(current), version: { ...current.version, revision: current.version.revision + 1 }, speakers: plain(speakers), segments: current.segments.map((segment, index) => ({ ...segment, speakerId: assignments[index] })) });
    } }));
  } };
  const context = vm.createContext({ escape, duration: value => `00:${String(Math.floor(value / 1000)).padStart(2, '0')}`, icon: () => '', TextEncoder, document, requestAnimationFrame: callback => callback(), crypto: { randomUUID: () => 'generated-id' }, GroveControls: { enhanceAll() {}, refresh() {}, close() {} } });
  const functions = vm.runInContext(`${source.replace(/^import .*;\n/gm, '').replace(/^export /gm, '')}\n({ mountSpeakers, speakerLabel, copyWorking, assignSelected, mergeSpeakers, nextSpeakerName, validateNames })`, context);
  const controller = functions.mountSpeakers({ bridge, getState: () => state, finishEditing: async action => { flushes.push(true); await beforeFlush?.(); return action(); }, onUpdated: (saved, meetingId) => { updates.push(meetingId); if (state.selectedId === meetingId) state.transcriptDraft.doc = saved; }, showError: error => errors.push(String(error.message || error)), byId: id => elements.get(id) || null });
  const click = async node => { await body.listeners.get('click')({ target: typeof node === 'string' ? elements.get(node) : node }); await tick(); };
  const change = node => body.listeners.get('change')({ target: node });
  const nameInput = id => body.children.find(node => node.dataset.speakerName === id);
  const name = (id, value) => { const input = nameInput(id); input.value = value; body.listeners.get('input')({ target: input }); return input; };
  return { functions, controller, elements, body, dialog, trigger, state, calls, errors, updates, flushes, click, change, name, nameInput, writes: () => writes, beforeFlush: callback => { beforeFlush = callback; }, find: (attribute, value) => body.children.find(node => node.attributes[attribute] === value), compositionStart: () => body.listeners.get('compositionstart')(), compositionEnd: () => body.listeners.get('compositionend')(), document };
}

test('speaker operations preserve text and work without model speaker labels', () => {
  const app = openController();
  const { functions } = app;
  const doc = documentForTest();
  const working = functions.copyWorking(doc);
  const assigned = functions.assignSelected(working, new Set(['a', 'c']), '__new__', '진행자', () => 'one');
  assert.deepEqual(plain(assigned.assignments), ['manual-one', 'S2', 'manual-one']);
  assert.equal(assigned.speakers.at(-1).name, '진행자');
  assert.deepEqual(plain(assigned.segments), plain(working.segments));
  assert.deepEqual(plain(working.assignments), ['S1', 'S2', 'S1']);
  const merged = functions.mergeSpeakers(assigned, 'manual-one', 'S2');
  assert.deepEqual(plain(merged.assignments), ['S2', 'S2', 'S2']);
  assert.equal(merged.speakers.some(speaker => speaker.id === 'manual-one'), false);
  const unknown = functions.assignSelected(merged, new Set(['b']), '', '', () => 'unused');
  assert.equal(unknown.assignments[1], null);
  assert.equal(functions.speakerLabel({ speakers: [] }, { speakerId: null }), '화자 미지정');
  assert.throws(() => functions.assignSelected(working, new Set(['missing']), 'S1'));
  assert.throws(() => functions.assignSelected(working, new Set(), 'S1'));
  assert.throws(() => functions.mergeSpeakers(working, 'S1', 'S1'));
  assert.throws(() => functions.validateNames([{ name: ' ' }]));
  assert.throws(() => functions.validateNames([{ name: '가'.repeat(86) }]));
  assert.equal(functions.nextSpeakerName([{ name: '화자 1' }, { name: '화자 3' }]), '화자 2');
});

test('opening flushes pending text, names update without replacing focused inputs, and cancel writes nothing', async () => {
  const app = openController();
  app.beforeFlush(() => { app.state.transcriptDraft.doc.version.revision = 1; app.state.transcriptDraft.doc.segments[0].text = '저장된 수정'; });
  await app.controller.open(0);
  assert.equal(app.dialog.open, true);
  assert.equal(app.elements.get('speaker-assignment-target').value, 'S1');
  assert.equal(app.find('data-speaker-segment', 'a').checked, true);
  assert.match(app.body.innerHTML, /저장된 수정/);
  const writes = app.writes();
  const input = app.name('S1', '새 이름');
  assert.equal(app.writes(), writes);
  assert.equal(app.nameInput('S1'), input);
  await app.click(app.find('data-speaker-close', ''));
  assert.equal(app.dialog.open, false);
  assert.equal(app.calls.length, 0);
  assert.equal(app.state.transcriptDraft.doc.speakers[0].name, '화자 1');
});

test('selected utterances can be split into a new speaker and the last saved action can be undone once', async () => {
  const app = openController();
  await app.controller.open(0);
  app.elements.get('speaker-assignment-target').value = '__new__';
  app.change(app.elements.get('speaker-assignment-target'));
  app.elements.get('speaker-new-name').value = '새 화자';
  await app.click('speaker-assign');
  assert.equal(app.calls.length, 0);
  await app.click('speaker-save');
  assert.equal(app.calls.length, 1);
  assert.deepEqual(app.calls[0].assignments, ['manual-generated-id', 'S2', 'S1']);
  assert.deepEqual(app.calls[0].expected, { id: 'document', revision: 0 });
  assert.equal(app.elements.get('speaker-save').disabled, true);
  const cancel = { preventDefault() {} };
  app.dialog.listeners.get('cancel')(cancel);
  assert.equal(app.dialog.open, true);
  app.calls[0].resolve(); await tick();
  assert.equal(app.dialog.open, false);
  assert.deepEqual(app.updates, ['meeting']);
  assert.equal(app.state.transcriptDraft.doc.segments[0].text, '첫 발언');
  await app.controller.open();
  assert.equal(app.elements.get('speaker-undo').hidden, false);
  await app.click('speaker-save');
  assert.equal(app.calls.length, 1);
  assert.equal(app.elements.get('speaker-undo').hidden, false);
  await app.click('speaker-undo');
  assert.equal(app.calls.length, 2);
  assert.deepEqual(app.calls[1].assignments, ['S1', 'S2', 'S1']);
  assert.deepEqual(app.calls[1].expected, { id: 'document', revision: 1 });
  app.calls[1].resolve(); await tick();
  await app.controller.open();
  assert.equal(app.elements.get('speaker-undo').hidden, true);
});

test('merge applies to every source utterance and native failure keeps the staged correction', async () => {
  const app = openController();
  await app.controller.open();
  await app.click(app.find('data-speaker-merge', 'S1'));
  app.elements.get('speaker-merge-target').value = 'S2';
  app.change(app.elements.get('speaker-merge-target'));
  await app.click('speaker-merge-apply');
  await app.click('speaker-save');
  assert.deepEqual(app.calls[0].speakers, [{ id: 'S2', name: '화자 2' }]);
  assert.deepEqual(app.calls[0].assignments, ['S2', 'S2', 'S2']);
  app.calls[0].reject(new Error('저장 실패')); await tick();
  assert.equal(app.dialog.open, true);
  assert.equal(app.elements.get('speaker-save').disabled, false);
  assert.match(app.elements.get('speaker-editor-message').textContent, /저장 실패/);
  await app.click('speaker-save');
  assert.deepEqual(app.calls[1].assignments, ['S2', 'S2', 'S2']);
  app.calls[1].resolve(); await tick();
});

test('IME names finish before save and stale versions cannot overwrite a newer transcript', async () => {
  const app = openController();
  await app.controller.open();
  const input = app.name('S1', 'ㅎ');
  app.document.activeElement = input;
  app.compositionStart();
  input.onBlur = () => { app.name('S1', '한글 이름'); app.compositionEnd(); };
  await app.click('speaker-save');
  assert.equal(app.calls[0].speakers[0].name, '한글 이름');
  app.calls[0].resolve(); await tick();
  await app.controller.open();
  app.name('S1', '추가 수정');
  app.state.transcriptDraft.doc.version.revision += 1;
  app.controller.render();
  assert.equal(app.elements.get('speaker-save').disabled, true);
  assert.equal(app.elements.get('speaker-undo').hidden, true);
  await app.click('speaker-save');
  assert.equal(app.calls.length, 1);
  assert.equal(app.nameInput('S1').value, '추가 수정');
  assert.ok(app.errors.some(error => error.includes('변경')));
});

test('dialog escapes arbitrary transcript/name content and resets safely on navigation', async () => {
  const doc = documentForTest();
  doc.speakers[0].name = '"><script>alert(1)</script>';
  doc.segments[0].text = '<img src=x onerror=alert(1)> & 문장';
  const app = openController(doc);
  await app.controller.open(0);
  assert.ok(app.body.innerHTML.includes('&lt;script&gt;'));
  assert.ok(app.body.innerHTML.includes('&lt;img'));
  assert.equal(app.body.innerHTML.includes('<script>'), false);
  app.state.selectedId = 'another';
  app.controller.reset();
  assert.equal(app.dialog.open, false);
  app.controller.render();
  assert.equal(app.trigger.hidden, true);
  assert.equal(app.calls.length, 0);
  app.state.selectedId = 'meeting';
  app.state.snapshot.meetings[0].deletedAt = 1;
  app.controller.render();
  assert.equal(app.trigger.hidden, true);
});
