import assert from 'node:assert/strict';
import test from 'node:test';
import { filterLibraryMeetings, mountLibrary } from '../src/library-ui.js';

const meetings = () => [
  { id: 'one', title: '주간 회의', notes: '', folderId: 'project', deletedAt: null },
  { id: 'two', title: '기획 검토', notes: '일정', folderId: null, deletedAt: null },
  { id: 'three', title: '보관할 회의', notes: '', folderId: 'project', deletedAt: 100 },
];
const settle = () => new Promise(resolve => setImmediate(resolve));

function harness(overrides = {}, options = {}) {
  const nodes = new Map(), calls = [], errors = [];
  const state = { snapshot: { meetings: meetings(), folders: [{ id: 'project', name: '프로젝트' }], session: null }, selectedId: 'one', connected: true, libraryFilter: 'all', libraryOpen: true, librarySelection: new Set(), librarySelecting: false, libraryBusy: false, processing: { status: 'idle' } };
  let locked = false;
  class Node {
    constructor(id) { this.id = id; this.listeners = {}; this.dataset = {}; this.value = ''; this.open = false; this.hidden = false; this.disabled = false; this.isConnected = true; this.ownerDocument = { activeElement: null }; }
    addEventListener(name, listener) { this.listeners[name] = listener; }
    setAttribute(name, value) { this[name] = value; }
    removeAttribute(name) { delete this[name]; }
    focus() { this.focused = true; }
    select() { this.selected = true; }
    showModal() { this.open = true; }
    close() { this.open = false; }
    set innerHTML(value) {
      this.html = value;
      if (this.id === 'library-dialog-body') {
        for (const match of value.matchAll(/<input[^>]*id="([^"]+)"[^>]*>/g)) {
          const node = byId(match[1]);
          node.value = /value="([^"]*)"/.exec(match[0])?.[1]?.replace(/&quot;/g, '"') || '';
          this.autofocus = node;
        }
        this.checkedRadio = /<input[^>]*name="library-destination"[^>]*value="([^"]*)"[^>]* checked/.exec(value)?.[1];
      }
    }
    get innerHTML() { return this.html || ''; }
    querySelector(selector) {
      if (selector === '[autofocus]') return this.autofocus || null;
      if (selector === '[data-library-confirm]') return byId('confirm');
      if (selector.includes('library-destination')) return this.checkedRadio == null ? null : { value: this.checkedRadio };
      return null;
    }
    querySelectorAll() { return []; }
  }
  const byId = id => { if (!nodes.has(id)) nodes.set(id, new Node(id)); return nodes.get(id); };
  const snapshot = () => structuredClone(state.snapshot);
  const record = (name, action = () => snapshot()) => async (...args) => { calls.push({ name, args, locked }); return action(...args); };
  const bridge = {
    readSnapshot: record('read'),
    createFolder: record('create'), renameFolder: record('renameFolder'), deleteFolder: record('deleteFolder'), updateMeeting: record('renameMeeting'), moveMeetings: record('move'), trashMeetings: record('trash'), restoreMeetings: record('restore'), purgeMeetings: record('purge'),
    ...overrides,
  };
  let controller;
  const render = () => controller?.render();
  controller = mountLibrary({ bridge, getState: () => state, byId,
    finishEditing: async action => { locked = true; calls.push({ name: 'flush' }); try { return await action(); } finally { locked = false; } },
    acceptSnapshot: value => { state.snapshot = value; }, selectMeeting() {}, render,
    showError: error => errors.push(String(error)), escape: value => String(value ?? '').replace(/[&<>"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[character]), icon: name => `<svg data-icon="${name}"></svg>`,
    ...options,
  });
  controller.render();
  const click = (id, target = { closest: () => null }) => byId(id).listeners.click({ target, preventDefault() {}, stopPropagation() {} });
  const target = (dataset, selectors) => ({ dataset, closest: selector => selectors.some(part => selector.includes(part)) ? targetNode : null });
  let targetNode;
  const delegated = (id, dataset, selectors) => { targetNode = target(dataset, selectors); click(id, targetNode); };
  const submit = async () => { byId('library-dialog').listeners.submit({ preventDefault() {} }); await settle(); };
  return { state, nodes, byId, calls, errors, controller, bridge, click, delegated, submit, snapshot };
}

test('library scopes exclude trash and do not confuse unfiled with a folder', () => {
  const input = meetings();
  assert.deepEqual(filterLibraryMeetings(input).map(meeting => meeting.id), ['one', 'two']);
  assert.deepEqual(filterLibraryMeetings(input, 'project').map(meeting => meeting.id), ['one']);
  assert.deepEqual(filterLibraryMeetings(input, 'unfiled').map(meeting => meeting.id), ['two']);
  assert.deepEqual(filterLibraryMeetings(input, 'trash').map(meeting => meeting.id), ['three']);
  assert.deepEqual(filterLibraryMeetings(input, 'all', '일정').map(meeting => meeting.id), ['two']);
});

test('folder navigation flushes edits and clears the previous selection', async () => {
  const app = harness();
  app.state.librarySelection.add('one');
  app.state.librarySelecting = true;
  await app.controller.show('unfiled');
  assert.equal(app.calls[0].name, 'flush');
  assert.equal(app.state.libraryFilter, 'unfiled');
  assert.equal(app.state.librarySelection.size, 0);
  assert.equal(app.state.librarySelecting, false);
  assert.equal(app.byId('library-title').textContent, '미분류');
});

test('opening a meeting preserves the selected navigation scope and shows its actual folder separately', () => {
  const app = harness();
  app.state.libraryFilter = 'all';
  app.controller.render();
  const navigation = app.byId('folder-list').innerHTML;
  app.state.libraryOpen = false;
  app.controller.render();
  assert.equal(app.byId('folder-list').innerHTML, navigation);
  assert.match(navigation, /data-library-filter="all" aria-current="page"/);
  assert.equal(app.state.libraryFilter, 'all');
  assert.equal(app.byId('meeting-folder-context').textContent, '프로젝트');
  assert.equal(app.byId('meeting-folder-context').title, '프로젝트');
  app.state.snapshot.meetings[0].folderId = null;
  app.controller.render();
  assert.equal(app.byId('meeting-folder-context').textContent, '미분류');
  assert.equal(app.state.libraryFilter, 'all');
  app.state.libraryFilter = 'project';
  app.controller.render();
  assert.match(app.byId('folder-list').innerHTML, /data-library-filter="project" aria-current="page"/);
  assert.equal(app.byId('meeting-folder-context').textContent, '미분류');
});

test('renamed folders update detail context and long names keep an escaped full title', () => {
  const app = harness();
  const name = '이름이 긴 프로젝트와 반복 회의를 함께 정리하는 폴더 "검토"';
  app.state.snapshot.folders[0].name = name;
  app.controller.render();
  const html = app.byId('folder-list').innerHTML;
  assert.match(html, /class="library-folder-name" title="이름이 긴 프로젝트/);
  assert.match(html, /폴더 &quot;검토&quot;/);
  assert.equal(app.byId('meeting-folder-context').textContent, name);
  assert.equal(app.byId('meeting-folder-context').title, name);
  app.state.snapshot.folders[0].name = '변경한 폴더';
  app.controller.render();
  assert.equal(app.byId('meeting-folder-context').textContent, '변경한 폴더');
  app.state.selectedId = null;
  app.controller.render();
  assert.equal(app.byId('meeting-folder-context').hidden, true);
});

test('select all respects full-text search IDs and the current folder scope', () => {
  const app = harness();
  app.byId('search').value = '본문에서만 찾을 표현';
  app.state.librarySearchIds = new Set(['two', 'three']);
  app.click('library-select-all');
  assert.deepEqual(app.controller.selectedIds(), ['two']);
  app.state.libraryFilter = 'project';
  app.controller.render();
  assert.deepEqual(app.controller.selectedIds(), []);
});

test('folder creation waits for edit persistence and releases edit locks before native work', async () => {
  const app = harness();
  app.click('new-folder');
  assert.equal(app.byId('library-dialog').open, true);
  app.byId('library-folder-name').value = '  제품  ';
  await app.submit();
  const call = app.calls.find(call => call.name === 'create');
  assert.deepEqual(call.args, ['제품']);
  assert.equal(call.locked, false);
  assert.equal(app.byId('library-dialog').open, false);
  assert.equal(app.state.libraryBusy, false);
});

test('meeting rename uses the saved current notes and rejects an empty title', async () => {
  const app = harness();
  app.delegated('meeting-list', { libraryAction: 'rename', libraryTarget: 'one' }, ['[data-library-action]']);
  app.byId('library-meeting-name').value = '  ';
  await app.submit();
  assert.equal(app.calls.some(call => call.name === 'renameMeeting'), false);
  assert.match(app.byId('library-dialog-error').textContent, /회의 이름/);
  app.byId('library-meeting-name').value = '새 제목';
  app.state.snapshot.meetings[0].notes = '저장된 최신 메모';
  await app.submit();
  assert.deepEqual(app.calls.find(call => call.name === 'renameMeeting').args, ['one', '새 제목', '저장된 최신 메모']);
});

test('trash confirmation explains cancelling the affected processing job', () => {
  const app = harness();
  app.state.processing = { status: 'running', meetingId: 'one' };
  app.click('meeting-trash');
  assert.match(app.byId('library-dialog-body').innerHTML, /진행 중인 처리를 취소/);
  assert.match(app.byId('library-dialog-body').innerHTML, /처리 취소 후 휴지통/);
  assert.equal(app.calls.some(call => call.name === 'trash'), false);
});

test('active recording cannot open a trash confirmation', () => {
  const app = harness();
  app.state.snapshot.session = { state: 'recording', meetingId: 'one' };
  app.click('meeting-trash');
  assert.equal(app.byId('library-dialog').open, false);
  assert.match(app.errors[0], /녹음을 종료/);
});

test('purge failure refreshes its committed deletion and keeps the recovery error visible', async () => {
  const app = harness();
  app.state.libraryFilter = 'trash';
  app.state.selectedId = 'three';
  app.state.librarySelection.add('three');
  app.controller.render();
  app.bridge.purgeMeetings = async ids => { app.state.snapshot.meetings = app.state.snapshot.meetings.filter(meeting => !ids.includes(meeting.id)); throw new Error('파일 정리를 재시도합니다.'); };
  app.click('library-purge');
  assert.match(app.byId('library-dialog-body').innerHTML, /복원할 수 없습니다/);
  await app.submit();
  assert.equal(app.state.snapshot.meetings.some(meeting => meeting.id === 'three'), false);
  assert.equal(app.calls.at(-1).name, 'read');
  assert.equal(app.state.librarySelection.size, 0);
  assert.equal(app.state.libraryBusy, false);
  assert.equal(app.byId('library-dialog').open, false);
  assert.match(app.errors.at(-1), /재시도/);
});

test('slow restore keeps only library operations busy and does not hold edit locks', async () => {
  let resolve;
  const app = harness();
  app.state.libraryFilter = 'trash';
  app.state.librarySelection.add('three');
  app.bridge.restoreMeetings = () => new Promise(done => { resolve = done; });
  app.click('library-restore');
  await settle();
  assert.equal(app.state.libraryBusy, true);
  assert.equal(app.state.busy, undefined);
  assert.equal(app.byId('library-restore').disabled, true);
  resolve(app.snapshot());
  await settle();
  assert.equal(app.state.libraryBusy, false);
  assert.equal(app.state.librarySelection.size, 0);
});

test('failed folder save keeps the dialog input and returns focus for retry', async () => {
  const app = harness({ createFolder: async () => { throw new Error('다시 시도해 주세요.'); } });
  app.click('new-folder');
  app.byId('library-folder-name').value = '보존할 입력';
  await app.submit();
  assert.equal(app.byId('library-dialog').open, true);
  assert.equal(app.byId('library-folder-name').value, '보존할 입력');
  assert.equal(app.byId('library-folder-name').focused, true);
  assert.match(app.byId('library-dialog-error').textContent, /다시 시도/);
});

test('slow trash closes confirmation and preserves focus in another editor', async () => {
  let resolve;
  const app = harness({ trashMeetings: () => new Promise(done => { resolve = done; }) });
  app.click('meeting-trash');
  app.byId('library-dialog').listeners.submit({ preventDefault() {} });
  await settle();
  assert.equal(app.byId('library-dialog').open, false);
  assert.equal(app.state.libraryBusy, true);
  app.state.selectedId = 'two';
  app.state.libraryOpen = false;
  const editor = app.byId('other-meeting-notes');
  app.byId('library-dialog').ownerDocument.activeElement = editor;
  resolve(app.snapshot());
  await settle();
  assert.equal(app.state.libraryOpen, false);
  assert.equal(app.byId('new-folder').focused, undefined);
  assert.equal(app.byId('library-title').focused, undefined);
});

test('view callback only runs for an actual filter change, never during rendering', async () => {
  const changes = [];
  const app = harness({}, { onViewChanged: filter => changes.push(filter) });
  app.controller.render();
  await app.controller.show('all');
  await app.controller.show('trash');
  app.controller.render();
  assert.deepEqual(changes, ['trash']);
  app.byId('search').value = '수정한 회의 내용';
  await app.controller.show('trash');
  assert.deepEqual(changes, ['trash', 'trash']);
});

test('renaming a meeting invalidates content search without changing its scope', async () => {
  const changes = [];
  const app = harness({}, { onViewChanged: filter => changes.push(filter) });
  app.state.libraryFilter = 'project';
  app.byId('search').value = '주간';
  app.delegated('meeting-list', { libraryAction: 'rename', libraryTarget: 'one' }, ['[data-library-action]']);
  app.byId('library-meeting-name').value = '제품 검토';
  await app.submit();
  assert.deepEqual(changes, ['project']);
  assert.equal(app.calls.find(call => call.name === 'renameMeeting').args[1], '제품 검토');
});
