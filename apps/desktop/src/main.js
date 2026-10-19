import * as bridge from './bridge.js';
import { icon, escape, button, duration, recordingStatus, statusMarkup, sessionControls, applySystemAppearance } from './ui.js';

applySystemAppearance();
const byId = (id) => document.getElementById(id);
const state = { snapshot: { meetings: [], session: null }, selectedId: null, devices: [], deviceId: null, connected: false, busy: false, composing: false, editLocks: 0, draft: null, saveTimer: null, saveQueue: Promise.resolve(), listKey: '', controlsKey: '', audioKey: '' };
const fullDate = new Intl.DateTimeFormat('ko-KR', { year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit' });
const shortDate = new Intl.DateTimeFormat('ko-KR', { month: 'numeric', day: 'numeric' });
let pendingQuitSessionId = null;
const currentMeeting = () => state.snapshot.meetings.find((meeting) => meeting.id === state.selectedId);
const activeSession = () => ['recording', 'paused', 'finalizing'].includes(state.snapshot.session?.state) ? state.snapshot.session : null;
const stateFor = (meeting) => activeSession()?.meetingId === meeting.id ? activeSession().state : meeting.status;

byId('create-meeting').innerHTML = `${icon('plus')}<span>새 회의</span>`;
byId('welcome-create').innerHTML = `${icon('plus')}<span>새 회의</span>`;
document.querySelector('.welcome-icon').innerHTML = icon('notebook-pen');
byId('recording-icon').innerHTML = icon('mic');

function showError(error, save = false) {
  byId('error-message').textContent = error instanceof Error ? error.message : String(error);
  byId('error').hidden = false;
  byId('retry-save').hidden = !save;
}

function clearError() { byId('error').hidden = true; }

function renderList() {
  const query = byId('search').value.trim().toLocaleLowerCase();
  const meetings = [...state.snapshot.meetings].sort((a, b) => b.createdAt - a.createdAt).filter((meeting) => `${meeting.title}\n${meeting.notes}`.toLocaleLowerCase().includes(query));
  byId('meeting-count').textContent = String(state.snapshot.meetings.length);
  const key = JSON.stringify([query, state.selectedId, meetings.map((meeting) => [meeting.id, meeting.title, meeting.createdAt, stateFor(meeting)])]);
  if (key === state.listKey) return;
  state.listKey = key;
  const focused = document.activeElement?.dataset.meetingId;
  const scroll = byId('meeting-list').scrollTop;
  byId('meeting-list').innerHTML = meetings.map((meeting) => {
    const phase = stateFor(meeting);
    return globalThis.GroveUI.button({ className: 'meeting-item', attrs: { 'data-meeting-id': meeting.id, 'aria-current': String(meeting.id === state.selectedId), title: meeting.title }, html: `${icon(['recording', 'paused'].includes(phase) ? 'mic' : meeting.audio ? 'audio-lines' : 'file-text')}<span class="meeting-item-content"><strong>${escape(meeting.title || '제목 없는 회의')}</strong><span class="meeting-item-meta"><span>${escape(shortDate.format(meeting.createdAt))}</span><span class="${['recording', 'paused'].includes(phase) ? 'recording' : ''}">${escape(recordingStatus(phase))}</span></span></span>` });
  }).join('') || `<p class="list-empty">${query ? '검색 결과가 없습니다.' : '저장한 회의가 없습니다.'}</p>`;
  byId('meeting-list').scrollTop = scroll;
  if (focused) [...byId('meeting-list').querySelectorAll('button')].find((element) => element.dataset.meetingId === focused)?.focus({ preventScroll: true });
}

function renderSaveState() {
  const dirty = state.draft?.dirty;
  byId('save').disabled = !dirty || state.busy;
  byId('save-status').textContent = state.draft?.saving ? '저장 중' : dirty ? '저장되지 않은 변경' : '저장됨';
}

function renderRecording(meeting) {
  const session = activeSession();
  const ownSession = session?.meetingId === meeting.id ? session : null;
  const phase = stateFor(meeting);
  byId('meeting-status').innerHTML = statusMarkup(phase);
  byId('recording-time').hidden = !ownSession;
  byId('recording-time').textContent = duration(ownSession?.elapsedMs);
  byId('show-recorder').hidden = !session;
  const key = JSON.stringify([meeting.id, Boolean(meeting.audio), session?.id, session?.state, session?.meetingId, state.devices, state.busy, state.deviceId]);
  if (key !== state.controlsKey) {
    state.controlsKey = key;
    const controls = byId('recording-controls');
    const microphoneFocused = document.activeElement?.dataset.field === 'microphone';
    if (ownSession) controls.innerHTML = sessionControls(ownSession, state.busy);
    else if (session) controls.innerHTML = button('녹음 중인 회의 열기', 'open-active', 'mic', '', state.busy);
    else if (meeting.audio) controls.innerHTML = '';
    else controls.innerHTML = `<label class="microphone-field"><span class="sr-only">녹음할 마이크</span><select id="microphone" data-field="microphone" aria-label="녹음할 마이크" ${state.busy ? 'disabled' : ''}><option value="">시스템 기본 마이크</option>${state.devices.map((device) => `<option value="${escape(device.id)}" ${device.id === state.deviceId ? 'selected' : ''}>${escape(device.name)}${device.isDefault ? ' (기본)' : ''}</option>`).join('')}</select></label>${globalThis.GroveUI.button({ html: icon('refresh-cw'), action: 'refresh-devices', className: 'icon', disabled: state.busy, attrs: { 'aria-label': '마이크 목록 새로고침', title: '마이크 목록 새로고침' } })}${button('녹음 시작', 'start', 'mic', 'primary', state.busy)}`;
    controls.hidden = !controls.innerHTML;
    globalThis.GroveControls.enhanceAll(controls);
    if (microphoneFocused && !state.busy) controls.querySelector('.grove-select-trigger')?.focus({ preventScroll: true });
  }
  const message = ownSession?.error || meeting.error || (phase === 'interrupted' ? '녹음이 중단되었습니다. 저장된 음성을 확인하세요.' : session && !ownSession ? '다른 회의에서 녹음하고 있습니다.' : !meeting.audio && !ownSession ? '선택한 마이크의 소리를 녹음합니다.' : '');
  byId('recording-message').textContent = message;
  byId('recording-message').hidden = !message;
  prepareAudio(meeting, Boolean(ownSession));
}

async function prepareAudio(meeting, recording) {
  const key = recording || !meeting.audio ? '' : `${meeting.id}:${meeting.audio.relativePath}:${meeting.audio.frames}`;
  if (state.audioKey === key) return;
  state.audioKey = key;
  const player = byId('audio-player');
  player.pause();
  player.removeAttribute('src');
  player.load();
  byId('audio-region').hidden = !key;
  if (!key) return;
  byId('audio-message').textContent = '녹음 파일을 여는 중입니다.';
  try {
    const url = await bridge.audioUrl(meeting.id);
    if (state.audioKey !== key) return;
    player.src = url;
    const milliseconds = meeting.audio.sampleRate ? meeting.audio.frames / meeting.audio.sampleRate * 1000 : 0;
    byId('audio-message').textContent = `녹음 길이 ${duration(milliseconds)}`;
  } catch (error) {
    if (state.audioKey === key) {
      byId('audio-message').textContent = '녹음 파일을 열 수 없습니다. 새로고침해서 다시 시도하세요.';
      showError(error);
    }
  }
}

function render() {
  byId('create-meeting').disabled = !state.connected || state.busy;
  byId('welcome-create').disabled = !state.connected || state.busy;
  renderList();
  const meeting = currentMeeting();
  byId('welcome').hidden = Boolean(meeting);
  byId('meeting-detail').hidden = !meeting;
  if (!meeting) return;
  byId('meeting-date').textContent = fullDate.format(meeting.createdAt);
  if (!state.draft?.dirty && !state.draft?.saving && document.activeElement !== byId('meeting-title') && document.activeElement !== byId('meeting-notes')) {
    byId('meeting-title').value = meeting.title;
    byId('meeting-notes').value = meeting.notes || '';
  }
  renderSaveState();
  renderRecording(meeting);
}

function acceptSnapshot(snapshot) {
  if (snapshot.revision != null && state.snapshot.revision != null && snapshot.revision < state.snapshot.revision) return;
  state.snapshot = snapshot;
  state.connected = true;
  if (!state.selectedId && snapshot.meetings.length) selectMeeting(snapshot.meetings[0].id);
  render();
}

function saveDraft() {
  clearTimeout(state.saveTimer);
  const draft = state.draft;
  if (!draft?.dirty || state.composing) return state.saveQueue;
  const version = draft.version;
  const title = draft.title.trim() || '제목 없는 회의';
  const notes = draft.notes;
  draft.saving = true;
  renderSaveState();
  const task = state.saveQueue.catch(() => {}).then(async () => {
    await bridge.updateMeeting(draft.id, title, notes);
    acceptSnapshot(await bridge.readSnapshot());
    if (draft.version === version) draft.dirty = false;
  });
  state.saveQueue = task.catch(() => {});
  return task.then(() => { clearError(); }).catch((error) => { showError(error, true); throw error; }).finally(() => {
    if (draft.version === version) draft.saving = false;
    renderSaveState();
  });
}

async function selectMeeting(id) {
  if (state.selectedId === id) return;
  try {
    await finishEditing(() => {
      const meeting = state.snapshot.meetings.find((item) => item.id === id);
      if (!meeting) return;
      state.selectedId = id;
      state.draft = { id, title: meeting.title, notes: meeting.notes || '', dirty: false, saving: false, version: 0 };
      byId('meeting-title').value = meeting.title;
      byId('meeting-notes').value = meeting.notes || '';
      byId('meeting-detail').scrollTop = 0;
      byId('meeting-notes').scrollTop = 0;
      render();
    });
  } catch { return; }
}

async function refreshDevices() {
  state.devices = await bridge.listDevices();
  if (state.deviceId && !state.devices.some((device) => device.id === state.deviceId)) state.deviceId = null;
  render();
}

async function run(action) {
  if (state.busy) return;
  const focusedId = document.activeElement?.id;
  const focusedAction = document.activeElement?.dataset.action;
  const focusedField = document.activeElement?.dataset.field;
  state.busy = true;
  render();
  try { await action(); } catch (error) { showError(error); } finally {
    state.busy = false;
    render();
    if (document.activeElement === document.body) {
      const nextAction = focusedAction === 'pause' ? 'resume' : focusedAction === 'resume' ? 'pause' : focusedAction;
      const target = focusedField ? document.querySelector(`button[data-field="${focusedField}"]`) : focusedId ? byId(focusedId) : [...document.querySelectorAll('[data-action]')].find((element) => element.dataset.action === nextAction);
      if (target && !target.disabled) target.focus({ preventScroll: true });
    }
  }
}

async function createMeeting() {
  await saveDraft();
  const meeting = await bridge.createMeeting('새 회의', '');
  acceptSnapshot(await bridge.readSnapshot());
  await selectMeeting(meeting.id);
  byId('meeting-title').focus();
  byId('meeting-title').select();
}

function onEdit() {
  if (!state.draft) return;
  state.draft.title = byId('meeting-title').value;
  state.draft.notes = byId('meeting-notes').value;
  state.draft.dirty = true;
  state.draft.version += 1;
  renderSaveState();
  clearTimeout(state.saveTimer);
  if (!state.composing) state.saveTimer = setTimeout(() => saveDraft().catch(() => {}), 600);
}

for (const id of ['meeting-title', 'meeting-notes']) {
  byId(id).addEventListener('input', onEdit);
  byId(id).addEventListener('compositionstart', () => { state.composing = true; clearTimeout(state.saveTimer); });
  byId(id).addEventListener('compositionend', () => { state.composing = false; onEdit(); });
}
byId('search').addEventListener('input', () => { byId('meeting-list').scrollTop = 0; renderList(); });
byId('meeting-list').addEventListener('click', (event) => { const id = event.target.closest('[data-meeting-id]')?.dataset.meetingId; if (id) void selectMeeting(id); });
byId('create-meeting').addEventListener('click', () => run(createMeeting));
byId('welcome-create').addEventListener('click', () => run(createMeeting));
byId('save').addEventListener('click', () => saveDraft().catch(() => {}));
byId('retry-save').addEventListener('click', () => saveDraft().catch(() => {}));
byId('dismiss-error').addEventListener('click', clearError);
byId('refresh').addEventListener('click', () => run(async () => { await saveDraft(); state.audioKey = ''; acceptSnapshot(await bridge.readSnapshot()); await refreshDevices(); }));
byId('show-recorder').addEventListener('click', () => run(() => bridge.showRecorder()));
byId('recording-controls').addEventListener('change', (event) => { if (event.target.id === 'microphone') state.deviceId = event.target.value || null; });
byId('recording-controls').addEventListener('click', (event) => {
  const action = event.target.closest('[data-action]')?.dataset.action;
  const session = activeSession();
  if (!action) return;
  run(async () => {
    if (action === 'refresh-devices') return refreshDevices();
    if (action === 'open-active' && session) return selectMeeting(session.meetingId);
    if (action === 'start') {
      await saveDraft();
      acceptSnapshot(await bridge.startRecording(state.selectedId, state.deviceId));
    }
    if (action === 'pause' && session) acceptSnapshot(await bridge.pauseRecording(session.id));
    if (action === 'resume' && session) acceptSnapshot(await bridge.resumeRecording(session.id));
    if (action === 'stop' && session) acceptSnapshot(await bridge.stopRecording(session.id));
  });
});
byId('audio-player').addEventListener('error', () => { if (byId('audio-player').getAttribute('src')) byId('audio-message').textContent = '음성을 재생할 수 없습니다. 녹음 파일을 다시 열어 주세요.'; });
document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') { event.preventDefault(); void saveDraft().catch(() => {}); }
});

async function finishEditing(action) {
  if (state.composing) {
    document.activeElement?.blur();
    await new Promise(requestAnimationFrame);
    state.composing = false;
    onEdit();
  }
  state.editLocks += 1;
  byId('meeting-title').readOnly = true;
  byId('meeting-notes').readOnly = true;
  try {
    const draft = state.draft;
    do { await saveDraft(); } while (state.draft === draft && draft?.dirty);
    return await action();
  } finally {
    state.editLocks -= 1;
    byId('meeting-title').readOnly = state.editLocks > 0;
    byId('meeting-notes').readOnly = state.editLocks > 0;
  }
}

async function onQuitRequest({ sessionId } = {}) {
  if (!activeSession()) {
    await run(() => finishEditing(() => bridge.requestQuit(null)));
    return;
  }
  if (sessionId !== activeSession().id) return;
  pendingQuitSessionId = sessionId;
  const dialog = byId('quit-dialog');
  dialog.innerHTML = globalThis.GroveUI.dialogContent({ title: '녹음을 종료하고 나갈까요?', titleId: 'quit-title', bodyHTML: '<p>지금까지 녹음한 음성과 메모를 저장한 뒤 앱을 종료합니다.</p>', actionsHTML: button('계속 녹음', 'cancel-quit', null, '') + button('저장하고 종료', 'confirm-quit', null, 'primary') });
  if (!dialog.open) dialog.showModal();
  dialog.querySelector('[data-action="cancel-quit"]').focus();
}
byId('quit-dialog').addEventListener('click', (event) => {
  const action = event.target.closest('[data-action]')?.dataset.action;
  if (action === 'cancel-quit') byId('quit-dialog').close();
  if (action === 'confirm-quit') {
    const sessionId = pendingQuitSessionId;
    byId('quit-dialog').close();
    run(() => finishEditing(() => bridge.requestQuit(sessionId)));
  }
});
byId('quit-dialog').addEventListener('close', () => { pendingQuitSessionId = null; });

try {
  await bridge.subscribeSnapshots(acceptSnapshot);
  await bridge.subscribeOpenMeeting(async (meetingId, error) => { await selectMeeting(meetingId); if (error) showError(error); });
  await bridge.subscribeQuitRequest(onQuitRequest);
  await bridge.subscribeCloseRequest(() => run(() => finishEditing(() => bridge.hideMain())));
  acceptSnapshot(await bridge.readSnapshot());
  await refreshDevices();
} catch (error) {
  if (!state.connected) byId('welcome-message').textContent = '데스크톱 앱에서 열어 주세요.';
  showError(error);
}
render();
