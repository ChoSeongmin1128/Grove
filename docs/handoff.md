# Grove handoff

AI-assisted working document. Current user instructions, live state, source and tests
take precedence. This public handoff describes code, not a user's installed app,
machine, recordings or evaluation results. Machine-local installation receipts and
detailed validation logs remain in ignored `results/`.

## Current source

The source targets version0.3.0 / local-beta.10. This is a personal local beta, not a
notarized release or a standalone model installer. Consult `App/Info.plist` for the
build identifier and local receipts for actual installation state.

- Basic transcript and accessibility time labels show whole seconds. Stored playback
  and split boundaries retain fractional precision. Metadata column widths are
  unchanged; a narrower gutter was discussed but is not implemented.
- Thin horizontal separators are lighter between continuous same-speaker turns.
  The first visible row remains unruled; lines add no height or interaction targets.
- General-purpose microphone recording, pause/resume and file import are supported.
  System-output capture is removed; older dual-channel files remain read-compatible.
- MOSS transcription runs after recording/import. Approved routing is Ultra8 for
  unknown count or1–8 people and Community-1 for9+. Sortformer4 remains selectable.
  Ultra8/Sortformer counts are advisory; Community-1 offers exact-count processing.
- Per-recording options are local drafts; persistent defaults live in Settings.
- Recording names are editable. **원본 파일…** provides path access, Finder reveal and
  byte-preserving export with source/destination protection and cancellation.
- Rows place speaker/start–end time left and text right. Pretendard and body scaling
  remain. Each utterance is independently editable; continuation never merges text.
- Folders and 미분류 share one section. 모든 녹음 is an aggregate; recent recordings are
  shortcuts. Drag/drop uses typed IDs and publishes changes only after successful save.
- Speaker/text editing, split, undo/redo, history and TXT/Markdown copy/export exist.
  Names can be manually reused within a folder; automatic voice matching is not shipped.
- Completion, speaker issues, count mismatch and failure/cancellation are separate.
  Failed retranscription retains and labels the prior transcript.

## Data and compatibility

- Preserve original audio, raw outputs, source-channel/cluster identity and corrections.
- Schema5 adds assignment measurements and explicit speaker-confirmation history.
  Schema3/4 and old split/undo history remain readable, with no startup rewrite. After
  saving schema5 corrections, older betas cannot safely read the new history.
- Acknowledgement binds text, speaker ID, times/source, generation and rule version.
  Relevant edits invalidate only related evidence; title/display-name edits do not.
  Bulk reassignment never acknowledges hidden issues. This is not dataset approval.
- Raw flags remain unchanged. UI triage is heuristic, not a calibrated confidence score.
- Full audio-hash/correction-head/snapshot identities, activity/coverage verification,
  UEM/RTTM datasets and training approval remain planned, not implemented.

## Validation and release work

Run the commands in `AGENTS.md` before publishing code or replacing an application.
Use the opt-in synthetic layout check for transcript changes, and inspect the actual
installed window when authorized. Keep code-test results separate from model quality.

Tests cover formatting, exact split boundaries, typed folder moves, publication/storage
failure, explicit confirmation, schema compatibility and undo. Hardware interruption,
pointer drag/drop, VoiceOver and full IME/export checks remain independent QA gates;
unit tests are not evidence that those workflows were manually tested.

Before replacing an app, confirm permission and check for active recording, inference,
export or editing. Preserve data, keep a recoverable prior bundle, verify signing and
confirm the new process. Never restore an old library over newer data. Do not leave
duplicate generated apps in Downloads or Applications.

Qualified native helpers and local model weights remain prerequisites for a fresh
installation. Do not claim first-run model download or untested hardware support.
Research environments and build caches are regenerable; preserve source, locks,
licenses and private evidence before scoped cleanup.

## Research boundaries and next work

- [Automatic speaker identification](automatic-speaker-identification.md) is a researched
  proposal only: explicit voice enrollment, folder-scoped matching, unknown-person
  rejection and protected voice storage. Names-only manual reuse remains shipped.
- [Offline speaker-logic experiments](speaker-logic-experiments.md) separate unchanged-text
  alignment, word assignment and frozen-posterior postprocessing. They create research
  sidecars, not app documents; production projection-v1 and human edits remain unchanged.
- [Annotation plans](review-mode-spec.md) are separate from speaker-issue triage. Read
  their data contracts before implementing training/evaluation dataset production.
- Public Git contains code, synthetic tests and generic documentation only. Private
  audio, references, labels, voice features, measurements, qualitative diagnoses,
  screenshots, local paths and installation receipts remain ignored.
- Commit/push with the personal account and restore the active GitHub CLI account
  to `nathan-glorang`, as required by `AGENTS.md`.

See [transcript/library UX](transcript-library-ux.md), [file management](recording-file-management.md),
[release readiness](release-readiness.md), [saved speakers](microphone-folders-and-speaker-reuse.md)
and [artifact retention](artifact-retention.md). Historical private notes and local
installation details remain under ignored `results/`.
