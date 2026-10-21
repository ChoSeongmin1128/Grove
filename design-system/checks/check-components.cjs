const assert = require('node:assert/strict');
const UI = require('../components.js');
const { test } = require('node:test');

test('component text and attribute values cannot inject markup', () => {
  const value = '\"><img src=x onerror=alert(1)>';
  const button = UI.button({ text: value, action: value, attrs: { 'aria-label': value } });
  assert.ok(!button.includes('<img'));
  assert.ok(button.includes('&lt;img'));
  assert.throws(() => UI.button({ text: '등록', attrs: { onclick: 'bad()' } }), /Unsupported/);
  const row = UI.meetingRow({ title: value, date: value, phase: 'recording', count: 36, label: '녹음 중' });
  assert.ok(!row.includes('<img'));
  assert.match(row, /title="&quot;&gt;/);
  assert.ok(row.includes('36명'));
});

test('shared rows preserve event ownership and semantic state', () => {
  const row = UI.meetingRow({ title: '회의', date: '날짜 미정', phase: 'paused', label: '일시정지', action: 'open-meeting:42' });
  assert.ok(row.includes('data-action="open-meeting:42"'));
  assert.ok(row.includes('status-chip paused'));
  assert.ok(!row.includes('with-icon'), 'A structured row must keep its grid layout instead of the icon-button layout');
  const option = UI.personOption({ name: '홍길동', checked: true, attrs: { 'data-field': 'attendee:42', value: 42 } });
  assert.ok(option.includes('data-field="attendee:42"'));
  assert.ok(option.includes(' checked'));
  assert.ok(!UI.personOption({ name: '홍길동' }).includes(' checked'));
});

test('transcript distinguishes unknown speaker, current turn and edits', () => {
  const current = UI.utterance({ speaker: '발언자 1', time: '00:42', timeAction: 'time:42', unknown: true, current: true, text: '<발언>' });
  assert.ok(current.includes('이름 미확인'));
  assert.ok(current.includes('data-action="time:42"'));
  assert.ok(current.includes('aria-label="00:42 발언"'));
  assert.ok(current.includes('class="pending"'));
  assert.ok(current.includes('&lt;발언&gt;'));
  const edit = UI.utterance({ speaker: '홍길동', time: '00:42', editing: true, contentHTML: '<textarea id="edit-text"></textarea>' });
  assert.ok(edit.includes('id="edit-text"'));
  assert.ok(!edit.includes('class="pending"'));
});

test('transcript reading rows preserve time and edits without inventing speaker identity', () => {
  const row = UI.transcriptRow({ index: 0, time: '00:42', start: 42, text: '회의 내용입니다.', originalText: '회의 내용입니다.' });
  assert.match(row, /<article class="transcript-row" data-transcript-row="0" tabindex="-1">/);
  assert.match(row, /data-seek="42" aria-label="00:42 발언 재생"/);
  assert.match(row, /<p class="transcript-text">회의 내용입니다\.<\/p>/);
  assert.match(row, /data-transcript-edit="0" aria-label="1번 발언 수정"/);
  assert.doesNotMatch(row, /textarea|<details|speaker|avatar/);
  const corrected = UI.transcriptRow({ index: 1, time: '01:05', start: 65, text: '<수정된 내용>', originalText: '<이전 내용>' });
  assert.match(corrected, /<summary>원문 보기<\/summary><p>&lt;이전 내용&gt;<\/p>/);
  assert.ok(!corrected.includes('<수정된 내용>'));
  assert.ok(!corrected.includes('<이전 내용>'));
});

test('transcript editor exposes a single compact field with explicit completion and cancellation', () => {
  const row = UI.transcriptRow({ index: 2, time: '01:18', start: 78, text: '</textarea><script>bad()</script>', originalText: '원문', editing: true, disabled: true });
  assert.match(row, /class="transcript-row is-editing"/);
  assert.match(row, /<textarea class="text-input" data-segment="2" aria-label="3번 발언 수정" rows="1" spellcheck="false" readonly>/);
  assert.match(row, /&lt;\/textarea&gt;&lt;script&gt;bad\(\)&lt;\/script&gt;/);
  assert.equal((row.match(/<textarea\b/g) || []).length, 1);
  assert.match(row, /data-transcript-done="2"[^>]* disabled>완료<\/button>/);
  assert.match(row, /data-transcript-cancel="2"[^>]* disabled>취소<\/button>/);
  assert.doesNotMatch(row, /data-transcript-edit=|<details|<script>/);
});

test('document and dialog render safe content without owning app state', () => {
  const minutes = UI.minutes([{ title: '회의 내용', text: '' }, { title: '할 일', text: '<script>\n두 번째 줄' }]);
  assert.ok(minutes.includes('작성된 내용이 없습니다.'));
  assert.ok(minutes.includes('&lt;script&gt;\n두 번째 줄'));
  assert.ok(!minutes.includes('<script>'));
  const modal = UI.dialogContent({ title: '<긴 제목>', titleId: 'meeting-dialog', actionsHTML: UI.button({ text: '취소', action: 'close' }) });
  assert.ok(modal.includes('id="meeting-dialog"'));
  assert.ok(modal.includes('&lt;긴 제목&gt;'));
  assert.ok(modal.includes('data-action="close"'));
});
