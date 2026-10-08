# Grove handoff

AI-assisted working document. Current user instructions, live state, source and tests
take precedence. This public handoff describes code, not a user's installed app,
machine, recordings or evaluation results. Machine-local installation receipts and
detailed validation logs remain in ignored `.work/`. The root `HANDOFF.md` points to
the private installation and evaluation receipts.

## Current source

- One workspace window owns navigation, its toolbar and recording / import / file-management
  dialogs. Recording and import begin after setup dismissal. Empty transcript states accept
  the available height; they must not enlarge the split view beyond the window.
- Pending microphone permission and file-copy work have explicit ownership. Cancelling
  an earlier setup cannot start or clear a newer attempt. Failed index writes restore the
  previous selection and keep source audio.
- Enrollment inspection uses at most the first120 seconds, allowing timer-stop latency
  without rejecting an otherwise valid recording. Rich-text export preserves inferred
  speaker labels, and an asynchronous Notion task is not a confirmed created page.

- Team voice enrollment records prompt reading and free speech, checks amplitude / clipping,
  supports preview and stores encrypted per-span features. The optional 15.3 MB voice
  model has pinned hashes and its own CoreML readiness check. Automatic naming remains
  gated; independent other-day five-person evaluation data is still required.
- Optional attendance is remembered per folder and stored separately from speaker-count
  options. Calendar recording opens the same meeting setup. Anonymous split clusters
  can share an identity if no retained overlap evidence conflicts.
- Calendar reminders use a single 440 x 40 row with title, countdown and recording action.

The source targets version0.4.0 / local-beta.20. This is a personal local beta, a
source build whose signing / notarization status must be checked from local receipts. Consult `App/Info.plist` for the
build identifier and local receipts for actual installation state.

- Basic transcript and accessibility time labels show whole seconds. Stored playback
  and split boundaries retain fractional precision. The metadata column is112pt
  (148pt for hour-long timestamps), with a12pt gap before transcript text.
- Thin horizontal separators are lighter between continuous same-speaker turns.
  The first visible row remains unruled; lines add no height or interaction targets.
- Detail titles, metadata and actions have separate rows with a shared content margin.
  Ordinary action buttons use native bordered controls, adaptive text and hover outlines.
  Empty-result failure / cancellation appears once with an explicit retry action; retained
  transcripts still show the processing warning above the prior result.
- General-purpose microphone recording, pause/resume and file import are supported.
  System-output capture is removed; older dual-channel files remain read-compatible.
- First-run precision mode uses bundled MOSS + Nemotron 3 and verified model downloads.
  Mac basic transcription uses Apple SpeechAnalyzer with no speaker separation.
  Existing saved routing is preserved. Legacy automatic mode remains Ultra8 for unknown
  count / 1–8 and Community-1 for 9+. Exact counts are still a Community-1 capability.
- Calendar reminders read selected Mac calendars and start microphone recording.
  Home actions use the same neutral bordered controls as detail actions. The root no
  longer forces a fixed dark-green tint onto ordinary native buttons.
- Notion rich-text copy / parent-end divider and child-page export are explicit actions.
  First-run downloads support byte progress, pause / resume, capacity and runtime checks.
- Per-recording options are local drafts; persistent defaults live in Settings.
- Recording names are editable. **원본 파일…** provides path access, Finder reveal and
  byte-preserving export with source/destination protection and cancellation.
  Internal names and full paths are collapsed under **파일 위치**; **사본 저장…** opens
  the existing save-copy flow without moving or changing the app's original file.
- Rows place speaker/start–end time left and text right. Pretendard and body scaling
  remain. Each utterance is independently editable; continuation never merges text.
- Folders and 미분류 share one section. 모든 녹음 is an aggregate; recent recordings are
  shortcuts. Drag/drop uses typed IDs and publishes changes only after successful save.
- Speaker/text editing, split, undo/redo, history and TXT/Markdown copy/export exist.
  Names can be manually reused within a folder. Dedicated microphone enrollment is
  available from team profiles. Automatic naming and legacy enrollment from meeting
  utterances remain behind the disabled release gate.
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
- Voice registration is separate from names-only reuse. Microphone enrollment uses
  encrypted storage and explicit consent / single-speaker confirmation. Gated matching
  uses selected attendance candidates, ambiguous-result deferral, user-name protection
  and confirm/reject/undo without auto-learning.
  Persist cleanup references before Keychain access; deletion/failed registration must
  not orphan keys. Ordinary library saves/backups strip legacy plaintext embeddings.
- Signed-app replacements need a qualified Keychain access / reauthorization flow;
  never silently reset missing keys.
- Full audio-hash/correction-head/snapshot identities, activity/coverage verification,
  UEM/RTTM datasets and training approval remain planned, not implemented.

## Validation and release work

Run the commands in `AGENTS.md` before publishing code or replacing an application.
Use the opt-in titled-window layout check for transcript changes, and inspect actual
file-picker / setup-dismissal / processing / completion transitions when authorized.
Component snapshots do not establish workspace layout correctness. Keep code-test results separate from model quality.

Debug QA can use `--qa-profile <isolated-directory>`; release builds ignore that
argument. The QA library must contain no production Keychain references or Notion
connection. `window-layout.jsonl` records geometry only when this argument is present.
After exercising library / processing / completed or failed states, validate it with:

```bash
python3 scripts/check_workspace_layout.py <qa-directory>/window-layout.jsonl --require-transitions
```

A passing offscreen `NSHostingController` render cannot exclude a sizing fault in the
actual SwiftUI scene. Validate that captured workspace bounds stay inside the window;
keep the live before/after evidence private. In-window editing menus, real microphone
capture, pointer hover, IME and external Notion writes require their own runtime checks.

Tests cover formatting, exact split boundaries, typed folder moves, publication/storage
failure, explicit confirmation, schema compatibility and undo. Voice tests use synthetic
features/fake keys for encrypted storage, cancellation, stale-source deferral, unknown
and conflicting proposals, cleanup/restart and the disabled product gate. These are not
real-voice accuracy tests or a substitute for signed-app Keychain qualification. Hardware interruption,
pointer drag/drop, VoiceOver and full IME/export checks remain independent QA gates;
unit tests are not evidence that those workflows were manually tested.

Before replacing an app, confirm permission and check for active recording, inference,
export or editing. Preserve data, keep a recoverable prior bundle, verify signing and
confirm the new process. Never restore an old library over newer data. Do not leave
duplicate generated apps in Downloads or Applications.

Qualified native helpers are bundled. The app prepares pinned default weights after
user selection, or uses Apple-managed Korean assets for basic transcription. Do not
claim a developer-tool-free separate Mac test unless it was performed.
Research environments and build caches are regenerable; preserve source, locks,
licenses and private evidence before scoped cleanup.

## Research boundaries and next work

- Notion OAuth uses public-client PKCE / dynamic registration with the official hosted
  MCP endpoint. No Grove auth server, app secret or user-installed CLI is needed. Grant
  metadata and user-selected destinations replace team / workspace / email allowlists.
  Native browser consent and a live parent-page export require user-run qualification;
  synthetic protocol / storage checks do not establish live workspace write success.
  Manual tokens remain available under advanced connection settings.
  The AuthenticationServices bridge uses an explicitly Sendable completion and hops
  to MainActor for session state. Background-queue callback / cancellation / retry
  checks exercise the actual bridge rather than replacing the browser implementation.
  See `setup-and-integrations.md` for lifecycle and compatibility.
- [Automatic speaker identification](automatic-speaker-identification.md) has implemented
  microphone enrollment and attendance selection. **Automatic naming remains gated**.
  A new embedding recipe needs independent-session known/unknown calibration and
  evaluation. Rejecting every speaker is not success. Enrollment alone does not qualify
  automatic naming. Names-only manual reuse remains usable.
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

See [setup and integrations](setup-and-integrations.md) and [distribution](distribution.md).
