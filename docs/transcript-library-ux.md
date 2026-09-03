# Transcript and library UX

Updated 2026-09-03. AI-assisted implementation notes; current code and runtime checks
take precedence. Installation/test evidence is recorded in `handoff.md`.

## Transcript reading

- Metadata occupies a fixed left gutter: speaker name and start–end time. Text is
  aligned in a separate right column, with a quiet per-utterance menu at the edge.
- Pretendard and the existing 100–200% body-size control are retained. Compact rows
  replace the repeated heading/body block and its large bottom padding.
- Every utterance retains its own visible speaker button, identity, text, timing,
  selection and editing actions. There is no automatic text/segment merge.
- Thin horizontal separators connect each row's metadata and text visually. The first
  visible row has no top separator; continuous same-speaker rows use a lighter line.
  Lines are noninteractive overlays, so they add no row height and do not intercept
  selection/clicks or add accessibility elements. System increased contrast is respected.
- Only adjacent, same-ID/same-source, non-overlapping turns with a gap of at most
  two seconds get reduced spacing/emphasis. Unknown speakers, long silences,
  overlaps and intervening filtered-out turns break this visual continuation.
- Time ranges use hundredths and support hour boundaries. This is display precision,
  not a claim that model boundaries are accurate to 10 ms. Stored times and existing
  TXT/Markdown timestamp conventions remain unchanged.
- Clicking the range plays that utterance with the existing surrounding context.
  Text stays selectable; reading/selecting text does not start playback.
- Search/speaker/review filtering preserves individual IDs. Copying the whole document,
  selected IDs and currently visible IDs remain distinct commands.

## Library organization

- **모든 녹음** is an aggregate view, not a storage folder or drop destination.
- **미분류** and user folders share one **폴더** section, indentation and row treatment.
  Each shows its recording count; unknown legacy folder references appear in 미분류.
- **최근 녹음** is a shortcut list across all locations. Moving a recording does not
  remove that shortcut; its location subtitle updates instead.
- Drag from the recent/library rows onto a sidebar location or an open folder view.
  The payload contains a recording UUID and per-store scope, not audio, title, text
  or a filesystem path. External text/files and other-store payloads are rejected.
- Drop highlight, a temporary success message and errors provide feedback. The
  existing **폴더로 이동** menu remains the non-drag alternative.
- Moves persist only index `folderID`, before publishing UI state. Audio paths,
  transcript/correction history, selected recording, list order and speaker IDs do
  not change. Busy source items, missing IDs/folders and invalid batches fail safely.
- Title search is scoped to the current list. Empty location and empty search results
  have different messages. Selecting another folder clears the prior search.
- New duplicate/reserved/multiline folder names are rejected; existing folder names
  are not silently rewritten. Folder deletion still keeps recordings in 미분류 and
  requires explicit confirmation before deleting that folder's saved speaker names.

## Speaker issue triage is not dataset annotation

- Successful processing is **전사 완료**. A separate **화자 확인 N곳** action opens
  pending utterances with reasons, contextual listening and explicit confirmation.
- Input/detected count mismatches are separate, result-revision-bound metadata linked
  to the speaker list. Count input is not relabelled as an exact Ultra8 constraint.
- Failure, cancellation and interrupted work have independent outcomes, cause/retry
  controls and an explicit retained-result label when a previous transcript survives.
- Legacy `needsReview` with a document and no error is shown as completed without
  rewriting it. Ambiguous old error strings are preserved as prior-process guidance,
  not guessed into a new failure/count category.
- Raw model flags and assignment output are preserved. A versioned UI heuristic uses
  no coverage/unresolved/tied candidates, winner coverage below 50%, or a runner-up
  at least 80% of the winner. These are triage heuristics, not calibrated confidence
  or a new measured accuracy result. A tiny secondary speaker interval alone is no
  longer an alert. Legacy multiple-speaker-only flags lack the finer measurements;
  suppressing that coarse alert is not human confirmation.
- A confirmation binds the document run, utterance ID, current text, speaker ID,
  time/source and review-rule version. Relevant edits invalidate only that evidence;
  meeting titles and speaker display-name changes do not change speaker identity.
- General/bulk reassignment never acknowledges hidden warnings. Single-utterance
  correction offers an explicit **이 발화의 화자 배정을 확인함** checkbox. When selected,
  the correction and confirmation are one saved/undoable change.
- New confirmation mutations use document schema 5. Schema 3/4 current documents and
  historical split/undo items remain readable; there is no startup rewrite. After a
  schema-5 edit, an older beta cannot safely read the new history. Do not blindly
  downgrade the app over newer corrections.
- No warning, no remaining warning, or speaker confirmation does **not** certify
  complete text accuracy, absence of missed speech, timing/overlap quality, or approval
  for model training/evaluation. The full annotation/snapshot/UEM plan is still separate.

## Verification boundaries

Unit/integration fixtures cover folder payload validation and atomic persistence,
presentation ordering/time precision, processing outcome preservation, speaker policy,
confirmation invalidation and undo/redo/migration. Existing private library compatibility
can be tested read-only with `GROVE_COMPATIBILITY_LIBRARY`; synthetic offscreen images
are opt-in via `GROVE_LAYOUT_OUTPUT`. Neither uses a second installed app.

Headless image dimensions alone are not visual QA. Inspect rendered text/controls or
the actual installed window before claiming layout success. Real pointer drag/drop,
hardware microphone behavior and long-file/model accuracy require separate evidence.
