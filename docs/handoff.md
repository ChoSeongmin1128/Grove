# Grove handoff

Updated: 2026-09-03

AI-assisted working document. Current user instructions, live state, source and tests
take precedence. Personal meeting data and its derived evaluation measurements are
excluded from public documentation; retain those only under ignored `results/`.

## Current build

Local-beta.9, version0.3.0, build11 is installed at `/Applications/Grove.app`.
It is a personal local beta, not a notarized release or a standalone model installer.
The previous bundle is recoverable in Trash. There is no intermediate app in `dist`.

Beta.9 adds only thin horizontal transcript separators: lighter between continuous
same-speaker turns, with no extra spacing or interaction target. First visible rows
remain unruled. Normal light/dark, large-body and review-filter synthetic renders were
inspected; system increased-contrast behavior is implemented but not manually toggled.
Model routing, transcription data, speaker review and schema are unchanged.

## Product behavior

- General-purpose local microphone recording, pause/resume and file import. System
  audio capture is removed; older dual-channel recordings retain read-only compatibility.
- MOSS transcription runs after recording/import. The approved beta routing is Ultra8
  for unknown count or1–8 people and Community-1 for9+. Sortformer4 remains selectable.
  Ultra8/Sortformer count input is advisory; Community-1 offers exact-count processing.
- Per-recording options are local drafts; persistent defaults live in Settings.
- Recording names are editable. **원본 파일…** provides path access, Finder reveal and
  bounded, byte-preserving export with source/destination protection and cancellation.
- Transcript rows put speaker/start–end time on the left, body on the right. Repeated
  turns get tighter spacing without merging utterances. Pretendard and text scaling remain.
- Folders and 미분류 share one sidebar section. 모든 녹음 is an aggregate; recent recordings
  are shortcuts independent of location. Drag/drop uses per-store typed IDs and updates
  only folder metadata after successful save. Menus, counts and title search remain available.
- Speaker/text editing, split, undo/redo, history and TXT/Markdown copy/export are implemented.
  Saved names can be manually reused within a folder; automatic voice matching is not shipped.
- Processing completion, pending speaker issues, count mismatch and failed/cancelled work
  are separate. Existing transcripts are retained on retry failure and labelled accordingly.
- Speaker acknowledgement is explicit, per-utterance and content-bound. Bulk reassignment
  never acknowledges hidden warnings. The single-edit checkbox can atomically save a
  corrected assignment and its acknowledgement. This is not dataset approval.

## Data and compatibility

- Preserve original audio, raw model outputs, source-channel/cluster identity and corrections.
- Schema5 adds optional assignment measurements and explicit speaker-confirmation history.
  Schema3/4 documents and old split/undo history remain readable, with no startup rewrite.
  After saving schema5 corrections, an old beta cannot safely read the new history.
- Confirmation binds utterance text, speaker ID, time/source, model generation and rule
  version. Relevant edits make only that evidence stale; display-name/title edits do not.
- Machine flags are not altered. The separate UI triage policy is heuristic, not a calibrated
  confidence score. A tiny secondary-speaker interval alone is not a review warning.
- Full audio-hash/correction-head/snapshot identities, complete text/activity/coverage
  verification, UEM/RTTM datasets and training approval are still planned, not implemented.

## Validation and installation

- Default Swift:163 passed and5 opt-in skipped (runner168). Python:7 passed.
- Tests cover typed folder payloads, atomic moves, state/count separation, first/repeated
  result publication failure, confirmation scope/invalidation, schema compatibility and undo.
- Beta.9 reran the default suites and synthetic offscreen native layout checks.
  Beta.8 previously exercised existing-file read compatibility and packaged native
  import/edit/reopen; those unchanged inference paths were not rerun for separators alone.
  Personal-input results/timing and snapshots remain in ignored local evidence only.
- Release packaging and strict deep code-signature verification passed. Installed main SHA256:
  `7a1bae50a9e255f526597fd3e9e848366c56a2bce9277b954fc1fb22e01a5f8f`.
- The idle prior app was normally quit before replacement. The new app's executable path was
  verified; existing library bytes were unchanged across installation and read-only UI QA.
- Beta.9 installed UI confirmed separators and preserved row controls. Prior beta.8
  installed UI checks covered transcript columns/ranges, folder structure, issue filtering,
  reasons and the explicit confirmation checkbox. Dialogs were cancelled; no user recording,
  speaker assignment or folder was changed. The full transcript was restored with playback off.
- Real pointer drag/drop, VoiceOver, full IME/export and microphone hardware edge cases
  remain separate QA gates. Unit tests do not prove those interactions or model accuracy.

## Publication and next work

- Offline-only speaker-logic research harnesses now separate unchanged-text alignment,
  word assignment and frozen-posterior postprocessing. They write independent sidecars;
  neither production projection-v1 nor stored documents are changed. See
  [experiment contracts](speaker-logic-experiments.md). Private runs and full-text
  inspection remain under ignored `results/`, not public documentation.
- Regenerable build/Python caches and an obsolete research executable were moved to
  a dedicated recoverable Trash location after checking active references. App assets,
  evaluation inputs, raw evidence, source and locks were preserved. Rebuilding now
  recreates the app build cache; no new app bundle was packaged or installed.
- Temporary alignment weights, interpreter environment and download caches were also
  removed from the working project after the experiments; pinned reproduction metadata
  and raw outputs remain private. Re-run inference only after recreating those inputs.
- Offline validation:43 Python suite checks plus13 alignment-contract checks passed.
  The scientific evaluator suite ran in its qualified environment, not as skipped
  checks. Swift/app packaging and UI smoke were not rerun for research-only tooling.
- Public commits/pushes use the personal account, then restore the active GitHub CLI
  account to `nathan-glorang`, as specified in `AGENTS.md`.
- Personal audio, references, labels, model outputs, raw or aggregate private evaluation
  results, screenshots, local paths and caches are not publication artifacts.
- The new review layer is speaker-issue triage only. Read the separate annotation plan
  before extending it into training/evaluation data production.
- Fresh installations still require qualified native helpers and local model weights.
  Do not claim first-run download/packaging or untested hardware support is complete.
- For a future app replacement, check for active recording, inference, export or user
  editing first; preserve current state and do not restore an old library over newer data.

See [transcript/library UX](transcript-library-ux.md), [file management](recording-file-management.md),
[release readiness](release-readiness.md), [annotation plan](review-mode-spec.md) and
[artifact retention](artifact-retention.md). Detailed prior handoffs remain local under
ignored `results/publication-private-notes/`.
