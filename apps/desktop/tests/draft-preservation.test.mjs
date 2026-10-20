import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../src/main.js', import.meta.url), 'utf8');
const uiSource = await readFile(new URL('../src/ui.js', import.meta.url), 'utf8');
const componentsSource = await readFile(new URL('../../../design-system/components.js', import.meta.url), 'utf8');
const tick = () => new Promise(setImmediate);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function openApp(initialTranscript = null) {
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
  let transcript = initialTranscript ? structuredClone(initialTranscript) : null;
  const transcriptUpdates = [];
  let devices = [];
  let closeRequest;
  const bridge = {
    subscribeProcessing: async () => () => {}, processingStatus: async () => ({ status: 'idle', supported: true, modelReady: false }), readTranscript: async (id) => id === 'a' ? structuredClone(transcript) : null,
    saveTranscript(id, expected, texts) {
      const pending = deferred();
      transcriptUpdates.push({ id, expected, texts, pending });
      return pending.promise.then(() => {
        transcript = { ...transcript, version: { ...transcript.version, revision: transcript.version.revision + 1 }, segments: transcript.segments.map((segment,index) => ({ ...segment, text: texts[index] })) };
        return structuredClone(transcript);
      });
    },
    subscribeSnapshots: async () => () => {}, subscribeOpenMeeting: async () => () => {},
    subscribeQuitRequest: async () => () => {},
    subscribeCloseRequest: async (callback) => { closeRequest = callback; return () => {}; },
    readSnapshot: async () => structuredClone(snapshot), listDevices: async () => structuredClone(devices),
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
    GroveControls: { enhanceAll() {} },
    setTimeout: () => 1, clearTimeout() {}, requestAnimationFrame: (callback) => callback(),
  });
  vm.runInContext(componentsSource, context);
  context.testUI = vm.runInContext(`(() => {
    ${uiSource.replace(/^export /gm, '')}
    return { icon, escape, button, duration, recordingStatus, statusMarkup, sessionControls, applySystemAppearance() {} };
  })()`, context);
  const executable = source.replace(/^import .*;\n/gm, '');
  const app = await vm.runInContext(`(async () => {
    const bridge = testBridge;
    const { icon, escape, button, duration, recordingStatus, statusMarkup, sessionControls, applySystemAppearance } = testUI;
    ${executable}
    return { state, selectMeeting, saveDraft, onEdit, onQuitRequest, refreshDevices, acceptSnapshot, saveTranscript, loadTranscript, acceptProcessing };
  })()`, context);
  await tick();
  return {
    app, element, updates, exits, bridge, transcriptUpdates, savedTranscript: () => transcript,
    editTranscript(text) { element('transcript-rows').listeners.get('input')({ target: { dataset: { segment: '0' }, value: text } }); },
    close: () => closeRequest(),
    setDevices(value) { devices = value; return app.refreshDevices(); },
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

test('no microphone disables recording while keeping device refresh available', async () => {
  const page = await openApp();
  const controls = page.element('recording-controls').innerHTML;
  assert.match(controls, /<button[^>]*data-action="start"[^>]* disabled/);
  assert.match(controls, /<select[^>]* disabled/);
  assert.doesNotMatch(controls.match(/<button[^>]*data-action="refresh-devices"[^>]*>/)[0], / disabled/);
  assert.match(page.element('recording-message').textContent, /마이크가 없습니다/);
});

test('refresh recovers microphone selection and recording after connection changes', async () => {
  const page = await openApp();
  await page.setDevices([{ id: 'usb-input', name: 'USB 마이크', isDefault: true }]);
  let controls = page.element('recording-controls').innerHTML;
  assert.doesNotMatch(controls.match(/<button[^>]*data-action="start"[^>]*>/)[0], / disabled/);
  assert.match(controls, /USB 마이크/);
  assert.doesNotMatch(page.element('recording-message').textContent, /마이크가 없습니다/);
  page.app.state.deviceId = 'usb-input';
  await page.setDevices([]);
  assert.equal(page.app.state.deviceId, null);
  controls = page.element('recording-controls').innerHTML;
  assert.match(controls, /<button[^>]*data-action="start"[^>]* disabled/);
});

test('empty device inventory does not disable controls for an active recording', async () => {
  const page = await openApp();
  page.app.acceptSnapshot({
    revision: 2,
    meetings: [{ id: 'a', title: '회의 A', notes: '', createdAt: 1, status: 'recording' }],
    session: { id: 'session-a', meetingId: 'a', state: 'recording', elapsedMs: 1000 },
  });
  await page.setDevices([]);
  const controls = page.element('recording-controls').innerHTML;
  for (const action of ['pause', 'stop']) {
    assert.doesNotMatch(controls.match(new RegExp(`<button[^>]*data-action="${action}"[^>]*>`))[0], / disabled/);
  }
  assert.doesNotMatch(page.element('recording-message').textContent, /마이크가 없습니다/);
});

const transcriptDocument = () => ({
  version: { id: 'transcript-a', revision: 0 }, sourceSessionId: 'audio-a', model: 'MOSS',
  segments: [{ id: 'segment-a', start: 0, end: 1, originalText: '모델 원문', text: '모델 원문' }],
});

test('meeting transition saves transcript edits arriving during an earlier save', async () => {
  const page = await openApp(transcriptDocument());
  page.editTranscript('첫 수정');
  const saving = page.app.saveTranscript();
  await tick();
  page.editTranscript('추가 수정');
  const leaving = page.app.selectMeeting('b');
  page.transcriptUpdates[0].pending.resolve();
  await tick();
  assert.equal(page.app.state.selectedId, 'a');
  assert.deepEqual(page.transcriptUpdates[1].texts, ['추가 수정']);
  assert.equal(page.transcriptUpdates[1].expected.revision, 1);
  page.transcriptUpdates[1].pending.resolve();
  await Promise.all([saving, leaving]);
  assert.equal(page.app.state.selectedId, 'b');
  assert.equal(page.savedTranscript().segments[0].text, '추가 수정');
  assert.equal(page.savedTranscript().segments[0].originalText, '모델 원문');
});

test('failed transcript save preserves input and prevents leaving the meeting', async () => {
  const page = await openApp(transcriptDocument());
  page.editTranscript('미저장 수정');
  const leaving = page.app.selectMeeting('b');
  await tick();
  page.transcriptUpdates[0].pending.reject(new Error('전사 저장 실패'));
  await leaving;
  assert.equal(page.app.state.selectedId, 'a');
  assert.equal(page.app.state.transcriptDraft.dirty, true);
  assert.equal(page.app.state.transcriptDraft.doc.segments[0].text, '미저장 수정');
  assert.equal(page.element('error').hidden, false);
});

test('late transcript loading cannot replace the newly selected meeting', async () => {
  const page = await openApp();
  const pending = deferred();
  page.bridge.readTranscript = async (id) => id === 'a' ? pending.promise : null;
  const loading = page.app.loadTranscript('a');
  await page.app.selectMeeting('b');
  pending.resolve(transcriptDocument());
  await loading;
  assert.equal(page.app.state.selectedId, 'b');
  assert.equal(page.app.state.transcriptDraft.id, 'b');
  assert.equal(page.app.state.transcriptDraft.doc, null);
});

test('quit commits an active transcript composition before requesting native exit', async () => {
  const page = await openApp(transcriptDocument());
  const input = page.element('segment-input');
  input.dataset.segment = '0';
  input.value = '조합 중 마지막 입력';
  input.focus();
  page.element('transcript-rows').listeners.get('compositionstart')();
  const leaving = page.app.onQuitRequest({});
  await tick();
  assert.equal(page.exits.length, 0);
  assert.deepEqual(page.transcriptUpdates[0].texts, ['조합 중 마지막 입력']);
  page.transcriptUpdates[0].pending.resolve();
  await tick();
  assert.equal(page.savedTranscript().segments[0].text, '조합 중 마지막 입력');
  assert.equal(page.exits[0].type, 'quit');
  page.exits[0].pending.resolve();
  await leaving;
});

test('late processing replies cannot replace the current running job', async () => {
  const page = await openApp();
  await page.app.acceptProcessing({ revision: 5, id: 'new-job', kind: 'model', status: 'running', supported: true });
  await page.app.acceptProcessing({ revision: 4, id: 'old-job', kind: 'model', status: 'completed', supported: true });
  assert.equal(page.app.state.processing.id, 'new-job');
  assert.equal(page.element('cancel-processing').hidden, false);
  assert.equal(page.element('import-audio').disabled, true);
});
