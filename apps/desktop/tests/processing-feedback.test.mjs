import assert from 'node:assert/strict';
import test from 'node:test';
import { processingFeedback } from '../src/processing-feedback.js';

const running = (kind, extra = {}) => ({ id: 'job', kind, status: 'running', ...extra });

test('recognition and summary stay visibly active without inventing an inference percentage', () => {
  const recognition = processingFeedback(running('transcribe', { message: '텍스트로 변환 중' }));
  assert.equal(recognition.visible, true);
  assert.equal(recognition.active, true);
  assert.equal(recognition.title, '음성 기록 변환 중');
  assert.equal(recognition.detail, '');
  assert.equal(recognition.progress, null);
  assert.equal(recognition.cancelVisible, true);
  const summary = processingFeedback(running('summary', { message: '요약 중 (12/80)', totalBytes: 80, bytes: 12 }));
  assert.equal(summary.title, '회의록 요약 중');
  assert.equal(summary.detail, '요약 중 (12/80)');
  assert.equal(summary.progress, null);
});

test('only finite model preparation byte counts provide determinate progress', () => {
  for (const kind of ['setup', 'model', 'summary-model']) {
    const feedback = processingFeedback(running(kind, { totalBytes: 1000, bytes: 250 }));
    assert.deepEqual(feedback.progress, { value: 250, max: 1000, percent: 25 });
    assert.equal(processingFeedback(running(kind)).progress, null);
    assert.equal(processingFeedback(running(kind, { totalBytes: 0 })).progress, null);
    assert.equal(processingFeedback(running(kind, { totalBytes: Infinity })).progress, null);
  }
  assert.equal(processingFeedback(running('import', { totalBytes: 100, bytes: 50 })).progress, null);
});

test('progress clamps malformed byte counters without changing task completion state', () => {
  assert.deepEqual(processingFeedback(running('model', { totalBytes: 100, bytes: -5 })).progress,
    { value: 0, max: 100, percent: 0 });
  const verified = processingFeedback(running('model', { totalBytes: 100, bytes: 120 }));
  assert.deepEqual(verified.progress, { value: 100, max: 100, percent: 100 });
  assert.equal(verified.active, true);
  assert.equal(verified.visible, true);
});

test('cancel requests remain active and disable repeated cancellation until acknowledged', () => {
  for (const [job, options] of [
    [running('summary', { message: '취소 중' }), {}],
    [running('summary', { message: '요약 중' }), { cancelling: true }],
  ]) {
    const feedback = processingFeedback(job, options);
    assert.equal(feedback.state, 'cancelling');
    assert.equal(feedback.active, true);
    assert.equal(feedback.title, '회의록 요약 취소 중');
    assert.equal(feedback.cancelDisabled, true);
    assert.equal(feedback.cancelLabel, '취소 중');
    assert.equal(feedback.progress, null);
  }
});

test('terminal states stop activity and keep failure or cancellation messages available', () => {
  const failed = processingFeedback({ id: 'job', kind: 'transcribe', status: 'failed', message: '모델 파일을 다시 준비해 주세요.' });
  assert.equal(failed.visible, true);
  assert.equal(failed.active, false);
  assert.equal(failed.title, '음성 기록 변환 실패');
  assert.equal(failed.detail, '모델 파일을 다시 준비해 주세요.');
  assert.equal(failed.cancelVisible, false);
  const cancelled = processingFeedback({ id: 'job', kind: 'summary', status: 'cancelled', message: '처리를 취소했습니다.' });
  assert.equal(cancelled.visible, true);
  assert.equal(cancelled.state, 'cancelled');
  assert.equal(cancelled.active, false);
  assert.equal(processingFeedback({ id: 'job', kind: 'summary', status: 'completed' }).visible, false);
  assert.equal(processingFeedback().visible, false);
  assert.equal(processingFeedback({ status: 'running' }).active, false);
});
