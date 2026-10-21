import { escape, duration, icon } from './ui.js';

const newSpeakerValue = '__new__';
const sameVersion = (a, b) => a?.id === b?.id && a?.revision === b?.revision;
const copySpeakers = speakers => (speakers || []).map(speaker => ({ id: speaker.id, name: speaker.name }));
const assignmentsOf = doc => doc.segments.map(segment => segment.speakerId ?? null);
const sameState = (a, b) => JSON.stringify([a.speakers, a.assignments]) === JSON.stringify([b.speakers, b.assignments]);

function speakerLabel(doc, segment) {
  return doc?.speakers?.find(speaker => speaker.id === segment?.speakerId)?.name || '화자 미지정';
}

function copyWorking(doc) {
  return { version: { ...doc.version }, speakers: copySpeakers(doc.speakers), assignments: assignmentsOf(doc), segments: doc.segments.map(segment => ({ id: segment.id, start: segment.start, text: segment.text })) };
}

function validateNames(speakers) {
  if (speakers.some(speaker => !speaker.name.trim() || new TextEncoder().encode(speaker.name).length > 256 || /[\u0000-\u001f\u007f-\u009f]/.test(speaker.name))) throw new Error('화자 이름이 비어 있거나 너무 깁니다. 짧은 이름으로 입력해 주세요.');
}

function nextSpeakerName(speakers) {
  let number = 1;
  const names = new Set(speakers.map(speaker => speaker.name));
  while (names.has(`화자 ${number}`)) number += 1;
  return `화자 ${number}`;
}

function assignSelected(working, selected, target, name, makeId) {
  if (!selected.size) throw new Error('발언을 선택해 주세요.');
  const validIds = new Set(working.segments.map(segment => segment.id));
  if ([...selected].some(id => !validIds.has(id))) throw new Error('음성 기록이 변경되었습니다. 화자 편집을 다시 열어 주세요.');
  const speakers = copySpeakers(working.speakers);
  let id = target || null;
  if (target === newSpeakerValue) {
    const speaker = { id: `manual-${makeId()}`, name: name.trim() };
    validateNames([speaker]);
    speakers.push(speaker);
    id = speaker.id;
  } else if (id && !speakers.some(speaker => speaker.id === id)) throw new Error('화자를 다시 선택해 주세요.');
  return { ...working, speakers, assignments: working.assignments.map((assignment, index) => selected.has(working.segments[index].id) ? id : assignment) };
}

function mergeSpeakers(working, from, into) {
  if (from === into || !working.speakers.some(speaker => speaker.id === from) || !working.speakers.some(speaker => speaker.id === into)) throw new Error('합칠 화자를 다시 선택해 주세요.');
  return { ...working, speakers: working.speakers.filter(speaker => speaker.id !== from).map(speaker => ({ ...speaker })), assignments: working.assignments.map(id => id === from ? into : id) };
}

export function mountSpeakers({ bridge, getState, finishEditing, onUpdated, showError, byId }) {
  const dialog = byId('speaker-dialog');
  const body = byId('speaker-dialog-body');
  const trigger = byId('speakers-button');
  const undoByMeeting = new Map();
  let editing = null;
  let opening = false;
  let saving = false;
  let preparing = false;
  let composing = false;
  let operation = 0;
  let returnFocus = null;

  function current() {
    const state = getState();
    const draft = state.transcriptDraft;
    const meeting = state.snapshot?.meetings?.find(item => item.id === state.selectedId);
    if (draft?.id !== state.selectedId || !draft?.doc?.segments?.length || meeting?.deletedAt != null) return null;
    return { state, id: state.selectedId, doc: draft.doc };
  }

  const blocked = view => !view || !view.state.connected || view.state.busy || (view.state.processing?.status === 'running' && view.state.processing.meetingId === view.id);
  const unchanged = () => editing && sameState(editing.base, editing.working);

  function undoFor(view) {
    const record = view && undoByMeeting.get(view.id);
    return record && sameVersion(record.expected, view.doc.version) ? record : null;
  }

  function message(text, error = false) {
    const node = byId('speaker-editor-message');
    if (!node) return;
    node.textContent = text;
    node.hidden = !text;
    node.dataset.state = error ? 'error' : 'success';
  }

  function focusReturn() {
    if (returnFocus?.isConnected) returnFocus.focus({ preventScroll: true });
    else if (returnFocus?.dataset?.speakerEdit != null) byId('transcript-rows')?.querySelector(`[data-speaker-edit="${Number(returnFocus.dataset.speakerEdit)}"]`)?.focus({ preventScroll: true });
    else if (!trigger.hidden) trigger.focus({ preventScroll: true });
  }

  function focusField(id) {
    const input = byId(id);
    (input?.closest?.('.grove-select')?.querySelector('button') || input)?.focus({ preventScroll: true });
  }

  function close() {
    globalThis.GroveControls?.close();
    editing = null;
    if (dialog.open) dialog.close();
    focusReturn();
  }

  function controls() {
    if (!editing || !dialog.open) return;
    const view = current();
    const stale = !view || view.id !== editing.id || !sameVersion(view.doc.version, editing.base.version);
    body.querySelectorAll('button, input, select').forEach(node => { node.disabled = saving || ((stale || blocked(view)) && !node.hasAttribute('data-speaker-close')); });
    const save = byId('speaker-save');
    save.disabled = saving || stale || blocked(view) || unchanged();
    save.innerHTML = saving ? '<span class="activity-spinner" aria-hidden="true"></span>저장 중' : '저장';
    const apply = byId('speaker-assign');
    apply.disabled = saving || stale || !editing.selected.size;
    const undo = byId('speaker-undo');
    undo.hidden = !undoFor(view);
    undo.disabled = saving || stale || blocked(view) || !unchanged();
    const merge = byId('speaker-merge-apply');
    if (merge) merge.disabled = saving || stale || !byId('speaker-merge-target')?.value;
    if (stale) message('음성 기록이 변경되었습니다. 수정을 취소하고 화자 편집을 다시 열어 주세요.', true);
    globalThis.GroveControls?.enhanceAll(body);
    body.querySelectorAll('select').forEach(input => globalThis.GroveControls?.refresh(input));
  }

  function draw() {
    const { working, selected, mergingId } = editing;
    const countFor = id => working.assignments.filter(assignment => assignment === id).length;
    const selectedAssignments = [...new Set(working.assignments.filter((_, index) => selected.has(working.segments[index].id)))];
    const selectedSpeaker = selectedAssignments.length === 1 ? selectedAssignments[0] : null;
    const options = working.speakers.map(speaker => `<option value="${escape(speaker.id)}"${speaker.id === selectedSpeaker ? ' selected' : ''}>${escape(speaker.name)}</option>`).join('');
    const source = working.speakers.find(speaker => speaker.id === mergingId);
    body.innerHTML = `<header class="speaker-dialog-header"><h2 id="speaker-dialog-title">화자 편집</h2><button type="button" class="icon-button quiet" data-speaker-close aria-label="닫기">${icon('x')}</button></header>
      <section class="speaker-names" aria-labelledby="speaker-names-title"><h3 id="speaker-names-title">화자 이름</h3>${working.speakers.some(speaker => speaker.id.startsWith('moss:chunk:')) ? '<p class="muted type-caption">처리 구간마다 화자가 나뉩니다. 같은 사람의 발언은 합칠 수 있습니다.</p>' : ''}<div class="speaker-name-list">${working.speakers.map((speaker, index) => `<div class="speaker-name-row"><label for="speaker-name-${index}" class="sr-only">화자 ${index + 1} 이름</label><input class="text-input" id="speaker-name-${index}" data-speaker-name="${escape(speaker.id)}" value="${escape(speaker.name)}" maxlength="256" autocomplete="off"><button type="button" class="quiet small" data-speaker-pick="${escape(speaker.id)}">발언 ${countFor(speaker.id)}개 선택</button>${working.speakers.length > 1 ? `<button type="button" class="quiet small" data-speaker-merge="${escape(speaker.id)}" aria-label="${escape(speaker.name)} 다른 화자와 합치기">합치기</button>` : ''}</div>`).join('') || '<p class="muted type-caption">발언을 선택해 화자를 지정하세요.</p>'}</div>
      ${source ? `<div class="speaker-merge-panel"><label for="speaker-merge-target">${escape(source.name)}의 발언을 합칠 화자</label><div class="speaker-assignment-controls"><select id="speaker-merge-target" data-field="speaker-merge-target"><option value="">화자 선택</option>${working.speakers.filter(speaker => speaker.id !== source.id).map(speaker => `<option value="${escape(speaker.id)}">${escape(speaker.name)}</option>`).join('')}</select><button type="button" id="speaker-merge-apply">합치기</button><button type="button" class="quiet" data-speaker-merge-cancel>취소</button></div></div>` : ''}</section>
      <section class="speaker-assignment" aria-labelledby="speaker-assignment-title"><div class="speaker-selection-header"><h3 id="speaker-assignment-title">발언 선택 <span id="speaker-selected-count">${selected.size}개</span></h3><button type="button" class="quiet small" data-speaker-select-all>전체 선택</button><button type="button" class="quiet small" data-speaker-clear>선택 해제</button></div>
      <div class="speaker-segment-list">${working.segments.map((segment, index) => `<label class="speaker-segment"><input type="checkbox" data-speaker-segment="${escape(segment.id)}"${selected.has(segment.id) ? ' checked' : ''}><span class="speaker-segment-time">${escape(duration(segment.start * 1000))}</span><span class="speaker-segment-content"><span class="speaker-segment-name" data-speaker-current="${escape(working.assignments[index] || '')}">${escape(working.speakers.find(speaker => speaker.id === working.assignments[index])?.name || '화자 미지정')}</span><span class="speaker-segment-text">${escape(segment.text || '(내용 없음)')}</span></span></label>`).join('')}</div>
      <div class="speaker-assignment-controls"><label for="speaker-assignment-target" class="sr-only">선택한 발언의 화자</label><select id="speaker-assignment-target" data-field="speaker-assignment-target"><option value="">화자 미지정</option>${options}<option value="${newSpeakerValue}">새 화자</option></select><label for="speaker-new-name" class="sr-only">새 화자 이름</label><input class="text-input" id="speaker-new-name" placeholder="새 화자 이름" value="${escape(nextSpeakerName(working.speakers))}" maxlength="256" autocomplete="off" hidden><button type="button" id="speaker-assign">선택 발언에 적용</button></div></section>
      <p id="speaker-editor-message" class="speaker-editor-message type-caption" role="status" hidden></p><footer class="speaker-dialog-actions"><button type="button" id="speaker-undo" class="quiet">이전 화자 수정 되돌리기</button><button type="button" data-speaker-close>취소</button><button type="button" id="speaker-save" class="primary">저장</button></footer>`;
    globalThis.GroveControls?.enhanceAll(body);
    controls();
  }

  function selectionChanged() {
    byId('speaker-selected-count').textContent = `${editing.selected.size}개`;
    body.querySelectorAll('[data-speaker-segment]').forEach(input => { input.checked = editing.selected.has(input.dataset.speakerSegment); });
    controls();
  }

  async function open(index = null) {
    if (opening || saving || preparing) return;
    const view = current();
    if (blocked(view) || view.state.editLocks) return;
    const meetingId = view.id;
    const segmentId = index == null ? null : view.doc.segments[index]?.id;
    if (index != null && !segmentId) return;
    opening = true;
    const request = ++operation;
    returnFocus = document.activeElement;
    try {
      await finishEditing(() => {
        const latest = current();
        if (request !== operation || blocked(latest) || latest.id !== meetingId) return;
        if (segmentId && !latest.doc.segments.some(segment => segment.id === segmentId)) throw new Error('음성 기록이 변경되었습니다. 발언을 다시 선택해 주세요.');
        const base = copyWorking(latest.doc);
        editing = { id: meetingId, base, working: copyWorking(latest.doc), selected: new Set(segmentId ? [segmentId] : []), mergingId: null };
        draw();
        if (!dialog.open) dialog.showModal();
        controls();
        focusField(segmentId || !latest.doc.speakers?.length ? 'speaker-assignment-target' : 'speaker-name-0');
      });
    } catch (error) { showError(error); }
    finally { opening = false; render(); }
  }

  async function save(undo = false) {
    if (saving || preparing || !editing) return;
    const owner = editing;
    preparing = true;
    await flushComposition();
    preparing = false;
    if (editing !== owner || (!undo && unchanged())) return;
    saving = true;
    controls();
    try {
      await finishEditing(async () => {
        const view = current();
        if (editing !== owner || blocked(view) || view.id !== owner.id || !sameVersion(view.doc.version, owner.base.version)) throw new Error('음성 기록이 변경되었습니다. 수정을 보존하고 화자 편집을 다시 열어 주세요.');
        const record = undo ? undoFor(view) : null;
        if (undo && (!record || !unchanged())) throw new Error('되돌릴 수 있는 화자 수정이 없습니다.');
        const next = undo ? record.previous : owner.working;
        validateNames(next.speakers);
        const saved = await bridge.saveSpeakers(view.id, { ...view.doc.version }, copySpeakers(next.speakers), [...next.assignments]);
        if (undo) undoByMeeting.delete(view.id);
        else undoByMeeting.set(view.id, { expected: { ...saved.version }, previous: { speakers: copySpeakers(owner.base.speakers), assignments: [...owner.base.assignments] } });
        await onUpdated(saved, view.id);
        if (editing === owner) close();
      });
    } catch (error) { message(error instanceof Error ? error.message : String(error), true); showError(error); }
    finally { saving = false; render(); controls(); }
  }

  function render() {
    const view = current();
    trigger.hidden = !view;
    trigger.disabled = blocked(view) || opening || saving || Boolean(view?.state.editLocks);
    const record = view && undoByMeeting.get(view.id);
    if (record && !sameVersion(record.expected, view.doc.version)) undoByMeeting.delete(view.id);
    if (editing && (!view || view.id !== editing.id)) close();
    controls();
  }

  function reset() {
    operation += 1;
    close();
  }

  async function flushComposition() {
    if (!composing) return;
    document.activeElement?.blur();
    await new Promise(requestAnimationFrame);
    composing = false;
  }

  trigger.addEventListener('click', () => { void open(); });
  dialog.addEventListener('cancel', event => { event.preventDefault(); if (!saving) close(); });
  dialog.addEventListener('close', () => { if (!saving) editing = null; });
  dialog.addEventListener('keydown', event => {
    const shortcut = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's';
    const enterName = event.key === 'Enter' && event.target.dataset?.speakerName && !event.isComposing && event.keyCode !== 229;
    if (!shortcut && !enterName) return;
    event.preventDefault();
    event.stopPropagation();
    void save();
  });
  body.addEventListener('compositionstart', () => { composing = true; });
  body.addEventListener('compositionend', () => { composing = false; });
  body.addEventListener('input', event => {
    const id = event.target.dataset.speakerName;
    if (!editing || saving || !id) return;
    const speaker = editing.working.speakers.find(item => item.id === id);
    if (speaker) {
      speaker.name = event.target.value;
      body.querySelectorAll('option').forEach(option => { if (option.value === id) option.textContent = speaker.name; });
      body.querySelectorAll('[data-speaker-current]').forEach(node => { if (node.dataset.speakerCurrent === id) node.textContent = speaker.name || '화자 미지정'; });
      body.querySelectorAll('select').forEach(input => globalThis.GroveControls?.refresh(input));
    }
    controls();
  });
  body.addEventListener('change', event => {
    if (!editing || saving) return;
    const segmentId = event.target.dataset.speakerSegment;
    if (segmentId) {
      if (event.target.checked) editing.selected.add(segmentId); else editing.selected.delete(segmentId);
      selectionChanged();
    } else if (event.target.id === 'speaker-assignment-target') {
      byId('speaker-new-name').hidden = event.target.value !== newSpeakerValue;
      if (event.target.value === newSpeakerValue) byId('speaker-new-name').focus({ preventScroll: true });
    } else if (event.target.id === 'speaker-merge-target') controls();
  });
  body.addEventListener('click', async event => {
    const target = event.target.closest('button');
    if (!target || !editing || saving) return;
    if (target.hasAttribute('data-speaker-close')) { close(); return; }
    if (target.id === 'speaker-save') { void save(); return; }
    if (target.id === 'speaker-undo') { void save(true); return; }
    if (target.hasAttribute('data-speaker-select-all')) { editing.selected = new Set(editing.working.segments.map(segment => segment.id)); selectionChanged(); return; }
    if (target.hasAttribute('data-speaker-clear')) { editing.selected.clear(); selectionChanged(); return; }
    if (target.dataset.speakerPick) { editing.selected = new Set(editing.working.segments.filter((_, index) => editing.working.assignments[index] === target.dataset.speakerPick).map(segment => segment.id)); selectionChanged(); return; }
    if (target.dataset.speakerMerge) { editing.mergingId = target.dataset.speakerMerge; draw(); focusField('speaker-merge-target'); return; }
    if (target.hasAttribute('data-speaker-merge-cancel')) { editing.mergingId = null; draw(); return; }
    try {
      const owner = editing;
      await flushComposition();
      if (editing !== owner) return;
      if (target.id === 'speaker-merge-apply') {
        editing.working = mergeSpeakers(editing.working, editing.mergingId, byId('speaker-merge-target').value);
        editing.mergingId = null;
        draw();
        message('화자를 합쳤습니다. 저장하면 반영됩니다.');
      } else if (target.id === 'speaker-assign') {
        editing.working = assignSelected(editing.working, editing.selected, byId('speaker-assignment-target').value, byId('speaker-new-name').value, () => crypto.randomUUID());
        draw();
        message(`${editing.selected.size}개 발언의 화자를 변경했습니다. 저장하면 반영됩니다.`);
      }
    } catch (error) { message(error instanceof Error ? error.message : String(error), true); }
  });

  return { render, open, reset, label: segment => speakerLabel(current()?.doc, segment) };
}
