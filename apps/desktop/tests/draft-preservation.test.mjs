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

async function openApp(initialTranscript = null, readiness = { status: 'idle', supported: true, modelReady: true, summarySupported: true, summaryReady: true }, storage = new Map()) {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', dataset: {}, readOnly: false, disabled: false, hidden: false,
      innerHTML: '', textContent: '', scrollTop: 0, listeners: new Map(),
      addEventListener(name, callback) { this.listeners.set(name, callback); },
      querySelectorAll() { return []; }, querySelector() { return null; },
      focus() { document.activeElement = this; }, blur() { document.activeElement = document.body; },
      select() {}, pause() {}, load() {}, setAttribute(name, value) { this[name] = value; }, removeAttribute(name) { delete this[name]; }, getAttribute(name) { return this[name] ?? null; }, showModal() { this.open = true; }, close() { this.open = false; this.listeners.get('close')?.(); },
    });
    const node = elements.get(id);
    if (!Object.hasOwn(node, 'htmlWrites')) {
      let html = node.innerHTML; node.htmlWrites = 0;
      Object.defineProperty(node, 'innerHTML', { get: () => html, set(value) { html = value; node.htmlWrites++; } });
    }
    return node;
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
    setAutoRecorder: async () => {}, subscribeProcessingError: async () => () => {},
    readSummary: async () => null,
    subscribeProcessing: async () => () => {}, processingStatus: async () => structuredClone(readiness), readTranscript: async (id) => id === 'a' ? structuredClone(transcript) : null,
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
    async setMeetingDate(id, meetingDate) { snapshot = { ...snapshot, revision: snapshot.revision + 1, meetings: snapshot.meetings.map(meeting => meeting.id === id ? { ...meeting, meetingDate } : meeting) }; },
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
    document, testBridge: bridge, localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
    GroveControls: { enhanceAll() {} },
    setTimeout: () => 1, clearTimeout() {}, requestAnimationFrame: (callback) => callback(),
  });
  vm.runInContext(componentsSource, context);
  context.testUI = vm.runInContext(`(() => {
    ${uiSource.replace(/^export /gm, '')}
    return { icon, escape, button, duration, recordingStatus, statusMarkup, sessionControls, documentExport, applySystemAppearance() {} };
  })()`, context);
  const executable = source.replace(/^import .*;\n/gm, '');
  const app = await vm.runInContext(`(async () => {
    const bridge = testBridge;
    const { icon, escape, button, duration, recordingStatus, statusMarkup, sessionControls, applySystemAppearance, documentExport } = testUI;
    ${executable}
    return { state, selectMeeting, saveDraft, onEdit, onQuitRequest, refreshDevices, acceptSnapshot, saveTranscript, loadTranscript, acceptProcessing, loadSummary, renderSummary, createMeeting, openSetup, openSettings, changeMicrophone, changeMeetingDate, render, prepareAudio, exportDocument };
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

test('recording stays compact and microphone failures lead to settings', async () => {
  const page = await openApp();
  const controls = page.element('recording-controls').innerHTML;
  assert.match(controls, /<button[^>]*data-action="start"[^>]* disabled/);
  assert.doesNotMatch(controls, /<select|refresh-devices/);
  assert.match(controls, /data-action="recording-settings"/);
  assert.match(page.element('recording-message').textContent, /마이크가 없습니다/);
  await page.app.openSettings();
  assert.equal(page.element('settings-dialog').open, true);
  assert.equal(page.element('settings-refresh-devices').disabled, false);
});

test('missing preferred microphone never silently switches to another input', async () => {
  const page = await openApp();
  await page.setDevices([{ id: 'usb-input', name: 'USB 마이크', isDefault: true }]);
  let controls = page.element('recording-controls').innerHTML;
  assert.doesNotMatch(controls.match(/<button[^>]*data-action="start"[^>]*>/)[0], / disabled/);
  assert.doesNotMatch(controls, /<select|USB 마이크/);
  page.app.state.deviceId = 'usb-input'; page.app.state.deviceName = 'USB 마이크';
  await page.setDevices([{ id: 'built-in', name: '내장 마이크', isDefault: true }]);
  assert.equal(page.app.state.deviceId, 'usb-input');
  assert.match(page.element('recording-message').textContent, /선택한 마이크/);
  assert.match(page.element('recording-controls').innerHTML, /data-action="start"[^>]* disabled/);
  assert.match(page.element('settings-microphone').innerHTML, /USB 마이크.*연결 안 됨/);
  await page.setDevices([{ id: 'usb-input', name: 'USB 마이크', isDefault: true }]);
  assert.doesNotMatch(page.element('recording-controls').innerHTML.match(/<button[^>]*data-action="start"[^>]*>/)[0], / disabled/);
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


test('late summary response cannot leak into another meeting', async () => {
  const page = await openApp(transcriptDocument());
  const pending = deferred();
  page.bridge.readSummary = async (id) => id === 'a' ? pending.promise : null;
  const loading = page.app.loadSummary('a');
  await page.app.selectMeeting('b');
  pending.resolve({ document: { id: 'summary-a', text: '회의 A 내용', sourceVersion: transcriptDocument().version }, stale: false });
  await loading;
  assert.equal(page.app.state.summary, null);
  assert.equal(page.element('summary-content').innerHTML, '');
});

test('summary rendering escapes model output and removes stale source links', async () => {
  const page = await openApp(transcriptDocument());
  page.app.state.summary = { document: { id: 'summary-a', text: '<script>bad()</script> 결정 [1]', sourceVersion: structuredClone(page.app.state.transcriptDraft.doc.version) }, stale: false };
  page.app.renderSummary(page.app.state.snapshot.meetings[0]);
  assert.match(page.element('summary-content').innerHTML, /&lt;script&gt;/);
  assert.match(page.element('summary-content').innerHTML, /data-summary-seek/);
  page.editTranscript('수정 중');
  page.app.renderSummary(page.app.state.snapshot.meetings[0]);
  assert.doesNotMatch(page.element('summary-content').innerHTML, /data-summary-seek/);
  assert.match(page.element('summary-message').textContent, /음성 기록이 수정/);
});

test('summary starts only after pending transcript edits are saved', async () => {
  const page = await openApp(transcriptDocument());
  const calls = [];
  page.bridge.summarizeMeeting = async (id) => { calls.push(id); return { id:'summary-job', kind:'summary', status:'running', revision:10, meetingId:id }; };
  page.editTranscript('요약 전 수정');
  const click = page.element('summarize').listeners.get('click')();
  await tick();
  assert.equal(calls.length, 0);
  page.transcriptUpdates[0].pending.resolve();
  await click;
  assert.deepEqual(calls, ['a']);
  assert.equal(page.app.state.transcriptDraft.dirty, false);
});


test('missing model readiness opens setup, blocks creation and import, and preserves existing meetings', async () => {
  const page = await openApp(null, { status: 'idle', supported: true, modelReady: false, summarySupported: true, summaryReady: false, summaryBytes: 1000 });
  let creates = 0, imports = 0;
  page.bridge.createMeeting = async () => { creates++; };
  page.bridge.importAudio = async () => { imports++; };
  assert.equal(page.app.state.selectedId, null);
  assert.equal(page.element('setup-screen').hidden, false);
  await page.app.createMeeting();
  page.element('import-audio').listeners.get('click')(); await tick();
  assert.equal(creates, 0); assert.equal(imports, 0);
  await page.app.selectMeeting('a');
  assert.equal(page.element('setup-screen').hidden, true);
  assert.equal(page.element('meeting-detail').hidden, false);
  assert.equal(page.element('meeting-title').value, '회의 A');
});

test('setup starts only after the download action, cancellation does not unlock meetings', async () => {
  const page = await openApp(null, { revision: 1, status: 'idle', supported: true, modelReady: false, summarySupported: true, summaryReady: false });
  let starts = 0, cancellations = 0;
  page.bridge.prepareMeetingModels = async (includeSummary) => { assert.equal(includeSummary, false); starts++; return { revision: 2, id: 'setup-1', kind: 'setup', status: 'running', supported: true, summarySupported: true }; };
  page.bridge.cancelProcessing = async () => { cancellations++; };
  assert.equal(starts, 0);
  page.element('setup-download').listeners.get('click')(); await tick();
  assert.equal(starts, 1);
  page.element('setup-cancel').listeners.get('click')(); await tick();
  assert.equal(cancellations, 1);
  await page.app.acceptProcessing({ revision: 3, id: 'setup-1', kind: 'setup', status: 'cancelled', supported: true, modelReady: false, summarySupported: true, summaryReady: false });
  assert.equal(page.element('setup-screen').hidden, false);
  assert.equal(page.element('setup-start').hidden, true);
  await page.app.acceptProcessing({ revision: 4, id: 'setup-2', kind: 'setup', status: 'completed', supported: true, modelReady: true, summarySupported: true, summaryReady: false });
  assert.equal(page.element('setup-screen').hidden, false);
  assert.equal(page.element('setup-start').hidden, false);
});


test('speech readiness opens meetings without optional summary and optional download is explicit', async () => {
  const page = await openApp(null, { status: 'idle', supported: true, modelReady: true, summarySupported: false, summaryReady: false });
  assert.equal(page.app.state.selectedId, 'a');
  assert.equal(page.element('setup-screen').hidden, true);
  assert.equal(page.element('meeting-detail').hidden, false);
  const fresh = await openApp(null, { status: 'idle', supported: true, modelReady: false, summarySupported: true, summaryReady: false });
  let requested = null;
  fresh.bridge.prepareMeetingModels = async (includeSummary) => { requested = includeSummary; return { revision: 1, kind: 'setup', status: 'running', supported: true, summarySupported: true }; };
  fresh.element('setup-summary-option').checked = true;
  fresh.element('setup-download').listeners.get('click')(); await tick();
  assert.equal(requested, true);
  assert.equal(fresh.element('setup-download').textContent.includes('GB'), false);
});


test('opening an active setup keeps progress visible after speech becomes ready', async () => {
  const page = await openApp(null, { revision: 1, status: 'idle', supported: true, modelReady: false, summarySupported: true, summaryReady: false });
  page.app.state.snapshot.meetings = [];
  page.app.state.setupRequested = false;
  await page.app.acceptProcessing({ revision: 2, id: 'setup-active', kind: 'setup', status: 'running', modelStage: 'summary', supported: true, modelReady: true, summarySupported: true, summaryReady: false, totalBytes: 100, bytes: 50 });
  assert.equal(page.element('setup-screen').hidden, false);
  assert.equal(page.element('setup-progress-region').hidden, false);
  assert.equal(page.element('setup-start').hidden, true);
});

test('optional summary download leaves new meetings enabled and reports transfer percent', async () => {
  const page = await openApp();
  await page.app.acceptProcessing({ revision: 3, id: 'download', kind: 'summary-model', status: 'running', supported: true, modelReady: true, summarySupported: true, summaryReady: false, message: '요약 모델 다운로드 중', bytes: 25, totalBytes: 100 });
  assert.equal(page.element('create-meeting').disabled, false);
  assert.equal(page.element('setup-screen').hidden, true);
  assert.equal(page.element('processing-message').textContent, '요약 모델 다운로드 중 25%');
  let created = false;
  page.bridge.createMeeting = async () => { created = true; return { id: 'b' }; };
  await page.app.createMeeting();
  assert.equal(created, true);
  assert.equal(page.app.state.selectedId, 'b');
});

test('export saves the latest transcript correction before opening the native save dialog', async () => {
  const page = await openApp(transcriptDocument());
  const exports = [];
  page.bridge.exportText = async (name, text) => { exports.push({ name, text }); return true; };
  page.editTranscript('내보낼 수정 문장');
  const exporting = page.app.exportDocument('transcript', 'md');
  await tick();
  assert.equal(exports.length, 0);
  page.transcriptUpdates[0].pending.resolve();
  await exporting;
  assert.equal(exports.length, 1);
  assert.match(exports[0].name, /음성 기록\.md$/);
  assert.match(exports[0].text, /내보낼 수정 문장/);
  assert.doesNotMatch(exports[0].text, /모델 원문/);
});


test('microphone preference persists and settings reject changes during recording', async () => {
  const storage = new Map();
  const page = await openApp(null, undefined, storage);
  await page.app.openSettings('recording');
  await page.setDevices([{ id: 'usb-input', name: 'USB 마이크', isDefault: true }]);
  page.element('settings-microphone').value = 'usb-input';
  page.app.changeMicrophone();
  const reopened = await openApp(null, undefined, storage);
  assert.equal(reopened.app.state.deviceId, 'usb-input');
  assert.equal(reopened.app.state.deviceName, 'USB 마이크');
  page.app.acceptSnapshot({revision: 2, meetings: page.app.state.snapshot.meetings, session: {id:'recording-a',meetingId:'a',state:'recording',elapsedMs:0}});
  assert.equal(page.element('settings-microphone').disabled, true);
  page.element('settings-microphone').value = '';
  page.app.changeMicrophone();
  assert.equal(page.app.state.deviceId, 'usb-input');
  assert.match(page.element('settings-message').textContent, /녹음을 마친 뒤/);
});

test('settings storage failure preserves the microphone choice and reports recovery', async () => {
  const storage = { get() { return null; }, set() { throw Error('storage full'); } };
  const page = await openApp(null, undefined, storage);
  await page.app.openSettings('recording');
  await page.setDevices([{id:'usb',name:'USB',isDefault:true}]);
  page.element('settings-microphone').value = 'usb';
  page.app.changeMicrophone();
  assert.equal(page.app.state.deviceId, null);
  assert.match(page.element('settings-message').textContent, /저장하지 못했습니다/);
  assert.equal(page.element('settings-microphone').value, '');
});

test('starting a recording rechecks device availability and uses the saved preference', async () => {
  const page = await openApp();
  let started = null;
  page.bridge.startRecording = async (meetingId, deviceId) => { started = {meetingId,deviceId}; return page.bridge.readSnapshot(); };
  await page.setDevices([{id:'usb',name:'USB',isDefault:true}]);
  page.app.state.deviceId = 'usb';
  await page.element('recording-controls').listeners.get('click')({target:{closest:()=>({dataset:{action:'start'}})}});
  await tick();
  assert.deepEqual(started, {meetingId:'a',deviceId:'usb'});
  started = null;
  page.bridge.listDevices = async () => [{id:'other',name:'내장',isDefault:true}];
  await page.element('recording-controls').listeners.get('click')({target:{closest:()=>({dataset:{action:'start'}})}});
  await tick();
  assert.equal(started, null);
});


test('settings wait for pending meeting edits and return from model management to the right category', async () => {
  const page = await openApp();
  page.edit('설정을 열기 전 메모');
  const opening = page.app.openSettings();
  await tick();
  assert.equal(Boolean(page.element('settings-dialog').open), false);
  page.updates[0].pending.resolve();
  await opening;
  assert.equal(page.element('settings-dialog').open, true);
  assert.equal(page.saved().notes, '설정을 열기 전 메모');
  page.element('settings-models-tab').listeners.get('click')();
  assert.equal(page.element('settings-models-panel').hidden, false);
  page.element('models').listeners.get('click')(); await tick();
  assert.equal(page.element('settings-dialog').open, false);
  assert.equal(page.element('setup-title').textContent, '모델');
  page.element('setup-back').listeners.get('click')(); await tick();
  assert.equal(page.element('settings-dialog').open, true);
  assert.equal(page.element('settings-models-panel').hidden, false);
  page.element('settings-close').listeners.get('click')();
  assert.equal(page.element('settings-dialog').open, false);
  assert.equal(page.element('settings').id, 'settings');
});

test('settings category keyboard navigation includes appearance and leaves editing state intact', async () => {
  const page = await openApp();
  await page.app.openSettings();
  assert.equal(page.app.state.settingsPanel, 'appearance');
  assert.equal(page.element('settings-appearance-panel').hidden, false);
  const navigate = (id, key) => page.element('settings-dialog').listeners.get('keydown')({ target: { id }, key, preventDefault() {} });
  navigate('settings-appearance-tab', 'ArrowDown');
  assert.equal(page.app.state.settingsPanel, 'recording');
  navigate('settings-recording-tab', 'ArrowDown');
  assert.equal(page.app.state.settingsPanel, 'models');
  navigate('settings-models-tab', 'ArrowDown');
  assert.equal(page.app.state.settingsPanel, 'appearance');
  navigate('settings-appearance-tab', 'End');
  assert.equal(page.app.state.settingsPanel, 'models');
  navigate('settings-models-tab', 'Home');
  assert.equal(page.app.state.settingsPanel, 'appearance');
  assert.equal(page.updates.length, 0);
});

test('automatic saving shows pending feedback and clears it after persistence', async () => {
  const page = await openApp();
  assert.equal(page.element('save-status').hidden, true);
  page.element('meeting-notes').value = '자동 저장 메모';
  page.app.onEdit();
  const save = page.app.saveDraft();
  await tick();
  assert.equal(page.element('save-status').hidden, false);
  assert.equal(page.element('save-status').textContent, '저장 중');
  page.updates[0].pending.resolve();
  await save;
  assert.equal(page.element('save-status').hidden, true);
  assert.equal(page.app.state.draft.dirty, false);
});


test('unchanged snapshots and timer updates preserve recording control DOM', async () => {
  const page = await openApp();
  const initial = structuredClone(page.app.state.snapshot);
  const writes = page.element('meeting-status').htmlWrites;
  page.app.acceptSnapshot({ ...initial, revision: 2 });
  assert.equal(page.element('meeting-status').htmlWrites, writes);
  const active = { revision: 3, meetings: initial.meetings, session: { id: 's', meetingId: 'a', state: 'recording', elapsedMs: 1000 } };
  page.app.acceptSnapshot(active);
  const statusWrites = page.element('meeting-status').htmlWrites;
  const controlWrites = page.element('recording-controls').htmlWrites;
  page.app.acceptSnapshot({ ...active, revision: 4, session: { ...active.session, elapsedMs: 2000 } });
  assert.equal(page.element('recording-time').textContent, '00:02');
  assert.equal(page.element('meeting-status').htmlWrites, statusWrites);
  assert.equal(page.element('recording-controls').htmlWrites, controlWrites);
});

test('capture quality warning stays visible during recording and after completion without disabling controls', async () => {
  const page = await openApp();
  const warning = '일부 음성이 끊겼을 수 있습니다.';
  const meetings = structuredClone(page.app.state.snapshot.meetings);
  page.app.acceptSnapshot({ revision: 2, meetings, session: { id: 's', meetingId: 'a', state: 'recording', elapsedMs: 1000, warning } });
  assert.equal(page.element('recording-message').textContent, warning);
  assert.equal(page.element('recording-message').hidden, false);
  assert.match(page.element('recording-controls').innerHTML, /일시정지/);
  page.app.acceptSnapshot({ revision: 3, meetings: meetings.map(meeting => meeting.id === 'a' ? { ...meeting, status: 'completed', warning } : meeting), session: null });
  assert.equal(page.element('recording-message').textContent, warning);
  page.app.acceptSnapshot({ revision: 4, meetings: meetings.map(meeting => meeting.id === 'a' ? { ...meeting, status: 'interrupted', warning, error: '장치 연결이 끊어졌습니다.' } : meeting), session: { id: 's', meetingId: 'a', state: 'interrupted', elapsedMs: 1000, warning, error: '장치 연결이 끊어졌습니다.' } });
  assert.equal(page.element('recording-message').textContent, '장치 연결이 끊어졌습니다.');
});

test('saving notes cannot dismiss an unrelated processing error', async () => {
  const page = await openApp();
  page.edit('메모');
  const saving = page.app.saveDraft(); await tick();
  page.bridge.setAutoRecorder = async () => { throw Error('설정 오류'); };
  page.element('auto-recorder').checked = false;
  await page.element('auto-recorder').listeners.get('change')();
  page.element('error').hidden = false;
  page.app.state.errorIsSave = false;
  page.element('error-message').textContent = '처리 실패';
  page.updates[0].pending.resolve(); await saving;
  assert.equal(page.element('error').hidden, false);
  assert.equal(page.element('error-message').textContent, '처리 실패');
});

test('creating a meeting cannot create a blank record before current transcript edits persist', async () => {
  const page = await openApp(transcriptDocument());
  let creates = 0;
  page.bridge.createMeeting = async () => { creates++; };
  page.editTranscript('변경');
  const creating = page.app.createMeeting(); await tick();
  assert.equal(creates, 0);
  page.transcriptUpdates[0].pending.reject(Error('저장 실패'));
  await assert.rejects(creating);
  assert.equal(creates, 0);
  assert.equal(page.app.state.selectedId, 'a');
});

test('date classification persists without changing the recording or creation time', async () => {
  const page = await openApp();
  const createdAt = page.saved().createdAt;
  page.element('meeting-day').value = '2026-10-01';
  await page.app.changeMeetingDate();
  assert.equal(page.saved().meetingDate, '2026-10-01');
  assert.equal(page.saved().createdAt, createdAt);
  assert.equal(page.element('meeting-day').disabled, false);
  page.bridge.setMeetingDate = async () => { throw Error('storage'); };
  page.element('meeting-day').value = '2026-11-02';
  await page.app.changeMeetingDate();
  assert.equal(page.saved().meetingDate, '2026-10-01');
  assert.equal(page.element('meeting-day').value, '2026-10-01');
  assert.equal(page.element('meeting-date-message').hidden, false);
});

test('meeting list shows local recording time and refreshes it when recording starts', async () => {
  const page = await openApp();
  const createdAt = new Date(2026, 9, 20, 9, 5).getTime();
  const recordedAt = new Date(2026, 9, 20, 18, 41).getTime();
  const meeting = { ...page.saved(), createdAt, meetingDate: '2026-10-01' };
  page.app.acceptSnapshot({ revision: 2, session: null, meetings: [meeting] });
  assert.match(page.element('meeting-list').innerHTML, />10\. 20\. 09:05<\/span>/);
  assert.match(page.element('meeting-list').innerHTML, /title="생성 /);
  page.element('meeting-list').scrollTop = 80;
  page.app.acceptSnapshot({ revision: 3, session: null, meetings: [{ ...meeting, recordedAt }] });
  const html = page.element('meeting-list').innerHTML;
  assert.match(html, />10\. 20\. 18:41<\/span>/);
  assert.match(html, /title="녹음 시작 /);
  assert.match(html, /회의 날짜 2026-10-01/);
  assert.doesNotMatch(html, />10\. 1\. 18:41/);
  assert.equal(page.element('meeting-list').scrollTop, 80);
});

test('meeting list orders by the displayed timestamp without inventing imported recording time', async () => {
  const page = await openApp();
  const stamp = (hour, minute) => new Date(2026, 9, 20, hour, minute).getTime();
  const recorded = { ...page.saved(), id: 'recorded', createdAt: stamp(8, 0), recordedAt: stamp(18, 41), meetingDate: '2026-10-01', audio: {} };
  const imported = { ...page.saved(), id: 'imported', createdAt: stamp(14, 5), audio: {} };
  const midnight = { ...page.saved(), id: 'midnight', createdAt: stamp(0, 0) };
  page.app.acceptSnapshot({ revision: 2, session: null, meetings: [midnight, imported, recorded] });
  const html = page.element('meeting-list').innerHTML;
  assert.ok(html.indexOf('data-meeting-id="recorded"') < html.indexOf('data-meeting-id="imported"'));
  assert.ok(html.indexOf('data-meeting-id="imported"') < html.indexOf('data-meeting-id="midnight"'));
  assert.match(html, />10\. 20\. 00:00<\/span>/);
  const importedRow = html.slice(html.indexOf('data-meeting-id="imported"'), html.indexOf('data-meeting-id="midnight"'));
  assert.match(importedRow, /title="생성 /);
  assert.doesNotMatch(importedRow, /녹음 시작/);
});

test('automatic recorder preference persists and rolls back native preference when storage fails', async () => {
  const storage = new Map();
  const page = await openApp(null, undefined, storage);
  page.element('auto-recorder').checked = false;
  await page.element('auto-recorder').listeners.get('change')();
  assert.equal(page.app.state.autoRecorder, false);
  const reopened = await openApp(null, undefined, storage);
  assert.equal(reopened.app.state.autoRecorder, false);
  const failed = await openApp(null, undefined, { get: () => null, set: () => { throw Error('storage'); } });
  const calls = [];
  failed.bridge.setAutoRecorder = async value => { calls.push(value); };
  failed.element('auto-recorder').checked = false;
  await failed.element('auto-recorder').listeners.get('change')();
  assert.deepEqual(calls, [false,true]);
  assert.equal(failed.app.state.autoRecorder, true);
});

test('editing a transcript immediately invalidates old summary links without a background refresh', async () => {
  const page = await openApp(transcriptDocument());
  page.app.state.summary = { document: { id: 'summary', text: '회의록 [1]', sourceVersion: structuredClone(page.app.state.transcriptDraft.doc.version) }, stale: false };
  page.app.renderSummary(page.app.state.snapshot.meetings[0]);
  assert.match(page.element('summary-content').innerHTML, /data-summary-seek/);
  page.editTranscript('새 내용');
  assert.doesNotMatch(page.element('summary-content').innerHTML, /data-summary-seek/);
});


test('action failure does not downgrade a failed save recovery button', async () => {
  const page = await openApp();
  page.edit('저장할 메모');
  page.element('create-meeting').listeners.get('click')(); await tick();
  page.updates[0].pending.reject(Error('저장 실패')); await tick(); await tick();
  assert.equal(page.element('retry-save').hidden, false);
  assert.equal(page.app.state.errorIsSave, true);
});

test('readiness arriving after the first snapshot still selects an existing meeting', async () => {
  const page = await openApp(null, { revision: 1, status: 'idle', supported: true, modelReady: false });
  assert.equal(page.app.state.selectedId, null);
  const same = structuredClone(page.app.state.snapshot);
  await page.app.acceptProcessing({ revision: 2, status: 'idle', supported: true, modelReady: true });
  page.app.acceptSnapshot(same); await tick();
  assert.equal(page.app.state.selectedId, 'a');
});

test('delayed date failure belongs to its meeting after navigating elsewhere', async () => {
  const page = await openApp();
  const pending = deferred();
  page.bridge.setMeetingDate = () => pending.promise;
  page.element('meeting-day').value = '2026-11-01';
  const saving = page.app.changeMeetingDate(); await tick();
  await page.app.selectMeeting('b');
  pending.reject(Error('storage')); await saving;
  assert.equal(page.app.state.selectedId, 'b');
  assert.equal(page.element('meeting-date-message').hidden, true);
  await page.app.selectMeeting('a');
  assert.equal(page.element('meeting-date-message').hidden, false);
});
