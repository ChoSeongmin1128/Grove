# Grove release readiness

Updated2026-09-03. AI-assisted source and implementation audit, not a model benchmark.
Private meeting-derived results are kept outside public documentation.

## Installed beta

Version0.3.0 / local-beta.9, build11 is installed at `/Applications/Grove.app`.
The prior app is recoverable in Trash, and `dist/Grove.app` is absent.
Release packaging, strict deep signature and the actual executable location were checked.
Existing library bytes were preserved through replacement and read-only UI inspection.

| Capability | Current boundary |
|---|---|
| Microphone recording and pause | Implemented; real device disconnect/sleep recovery needs more QA |
| System-output audio | Removed from new capture; legacy source files remain readable |
| File import and MOSS transcription | Native helper route connected; helpers/weights must be installed separately |
| Ultra8 / Community-1 / Sortformer4 | Approved beta routing and explicit engine choices; capacity is not quality evidence |
| Recording titles and original files | Rename, path access and protected original export implemented |
| Folder organization | CRUD, counts, title search, per-store typed drag/drop and menu alternative implemented |
| Compact transcript | Left metadata/right body, subtle horizontal row separators; spacing and individual editing preserved |
| Speaker/text correction | Scope selection, split, undo/redo and TXT/Markdown copy/export implemented |
| Saved speakers | Explicit folder-scoped name reuse; no automatic voice identity matching |
| Processing vs review | Completion, counts, failure/cancellation, retained result and issue queue separated |
| Speaker acknowledgement | Explicit single-utterance confirmation; content-bound evidence and schema5 history |
| Full annotation and training data | Planned only; speaker confirmation is not text/coverage/dataset approval |
| Distribution | Personal ad-hoc local beta, not a notarized or self-contained installer |

## Checks performed

- Swift default run:163 passed,5 opt-in skipped (runner168). Python7 passed.
- Beta.9 separator-only changes were inspected in synthetic light/dark, large-body and
  review-filter native renders. No model/data behavior changed. Increased-contrast and
  non-Retina environments were not manually exercised.
- Earlier beta.8 opt-in checks exercised existing-document/history/raw-result read
  compatibility and packaged native import/edit/reopen. Beta.9 reran synthetic native
  layouts but did not rerun unchanged model inference for a separator-only change.
- Fault injection covers first/repeated processing index publication failure, source/raw
  preservation, prior correction retention and folder/confirmation save failure.
- Beta.9 installed UI verified separators and row controls. Prior beta.8 verified
  transcript columns/ranges, folder hierarchy, pending-only reasons
  and explicit acknowledgement controls. Dialogs were cancelled rather than changing user data.
- Fine-grained model outputs, metrics, timings and real-data screenshots remain in ignored
  local evidence and are not public release attachments.

## Remaining gates

- Real pointer drag/drop, keyboard-only/VoiceOver, comprehensive IME and export interactions.
- Microphone pause/resume under device changes, sleep, permissions loss and storage pressure.
- Long-recording memory/thermal behavior and independent, permissioned, held-out Korean
  transcription/diarization evaluation. Successful execution does not establish accuracy.
- First-run model setup, redistribution/license review, signing/notarization and distribution.
- Full annotation versioning, audio hashes, coverage review and immutable dataset exports.

Schema3/4 remains readable; new edits use schema5. Do not downgrade over newer correction
history or restore stale library indexes. New replacement work requires a fresh idle-state
check and preservation of current user state. See [handoff](handoff.md) and
[UX/data contract](transcript-library-ux.md).
