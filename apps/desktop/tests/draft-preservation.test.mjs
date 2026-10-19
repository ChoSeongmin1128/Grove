import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../src/main.js', import.meta.url), 'utf8');
const tick = () => new Promise(setImmediate);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function openApp() {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', dataset: {}, readOnly: false, disabled: false, hidden: false,
      innerHTML: '', textContent: '', scrollTop: 0, listeners: new Map(),
      addEventListener(name, callback) { this.listeners.set(name, callback); },
      querySelectorAll() { return []; }, querySelector() { return null; },
      focus() { document.activeElement = this; }, blur() { document.activeElement = document.body; },
      select() {}, pause() {}, load() {}, removeAttribute() {}, getAttribute() { return null; },
    });
    return elements.get(id);
  };
  const document = {
    body: element('body'), activeElement: null, getElementById: element,
    querySelector: element, querySelectorAll: () => [], addEventListener() {},
  };
  document.activeElement = document.body;
  let snapshot = { revision: 1, session: null, meetings: [
    { id: 'a', title: '회의 A', notes: '', createdAt: 1, status: 'draft' },
    { id: 'b', title: '회의 B', notes: '', createdAt: 2, status: 'draft' },
  ] };
  const updates = [];
  const exits = [];
  let closeRequest;
  const bridge = {
    subscribeSnapshots: async () => () => {}, subscribeOpenMeeting: async () => () => {},
    subscribeQuitRequest: async () => () => {},
    subscribeCloseRequest: async (callback) => { closeRequest = callback; return () => {}; },
    readSnapshot: async () => structuredClone(snapshot), listDevices: async () => [],
    updateMeeting(id, title, notes) {
      const pending = deferred();
      updates.push({ id, title, notes, pending });
      return pending.promise.then(() => {
        snapshot = { ...snapshot, revision: snapshot.revision + 1, meetings: snapshot.meetings.map((meeting) => meeting.id === id ? { ...meeting, title, notes } : meeting) };
      });
    },
    requestQuit() { const pending = deferred(); exits.push({ type: 'quit', pending }); return pending.promise; },
    hideMain() { const pending = deferred(); exits.push({ type: 'close', pending }); return pending.promise; },
  };
  const context = vm.createContext({
    document, testBridge: bridge,
    testUI: { icon: () => '', escape: String, button: () => '', duration: String, recordingStatus: String, statusMarkup: () => '', sessionControls: () => '', applySystemAppearance() {} },
    GroveUI: { button: () => '' }, GroveControls: { enhanceAll() {} },
    setTimeout: () => 1, clearTimeout() {}, requestAnimationFrame: (callback) => callback(),
  });
  const executable = source.replace(/^import .*;\n/gm, '');
  const app = await vm.runInContext(`(async () => {
    const bridge = testBridge;
    const { icon, escape, button, duration, recordingStatus, statusMarkup, sessionControls, applySystemAppearance } = testUI;
    ${executable}
    return { state, selectMeeting, saveDraft, onEdit, onQuitRequest };
  })()`, context);
  await tick();
  return {
    app, element, updates, exits, close: () => closeRequest(),
    saved: () => snapshot.meetings.find((meeting) => meeting.id === 'a'),
    edit(notes) { element('meeting-notes').value = notes; app.onEdit(); },
  };
}

test('meeting transition preserves edits arriving while earlier saves are pending', async () => {
  const page = await openApp();
  page.edit('처음 입력');
  const autosave = page.app.saveDraft();
  await tick();
  page.edit('저장 중 추가 입력');
  const transition = page.app.selectMeeting('b');
  assert.equal(page.element('meeting-notes').readOnly, true);
  page.updates[0].pending.resolve();
  await tick();
  page.edit('마지막 입력까지 보존');
  page.updates[1].pending.resolve();
  await tick();
  assert.equal(page.app.state.selectedId, 'a');
  assert.equal(page.updates[2].notes, '마지막 입력까지 보존');
  page.updates[2].pending.resolve();
  await Promise.all([autosave, transition]);
  assert.equal(page.saved().notes, '마지막 입력까지 보존');
  assert.equal(page.app.state.selectedId, 'b');
  assert.equal(page.element('meeting-notes').readOnly, false);
});

for (const kind of ['quit', 'close']) {
  test(`${kind} waits for the latest edit and keeps the editor locked until the native action finishes`, async () => {
    const page = await openApp();
    page.edit('처음 입력');
    const leaving = kind === 'quit' ? page.app.onQuitRequest({}) : page.close();
    await tick();
    assert.equal(page.element('meeting-title').readOnly, true);
    page.edit('종료 전 추가 입력');
    page.updates[0].pending.resolve();
    await tick();
    assert.equal(page.exits.length, 0);
    assert.equal(page.updates[1].notes, '종료 전 추가 입력');
    page.updates[1].pending.resolve();
    await tick();
    assert.equal(page.saved().notes, '종료 전 추가 입력');
    assert.equal(page.exits[0].type, kind);
    assert.equal(page.element('meeting-notes').readOnly, true);
    page.exits[0].pending.resolve();
    await leaving;
    assert.equal(page.element('meeting-notes').readOnly, false);
  });
}

test('failed save keeps the current draft and unlocks the editor without switching meetings', async () => {
  const page = await openApp();
  page.edit('저장되지 않은 입력');
  const transition = page.app.selectMeeting('b');
  await tick();
  page.updates[0].pending.reject(new Error('저장 실패'));
  await transition;
  assert.equal(page.app.state.selectedId, 'a');
  assert.equal(page.app.state.draft.notes, '저장되지 않은 입력');
  assert.equal(page.app.state.draft.dirty, true);
  assert.equal(page.element('meeting-notes').readOnly, false);
  assert.equal(page.element('error').hidden, false);
});
