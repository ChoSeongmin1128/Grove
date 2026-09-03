# Microphone recording, folders, and saved speakers

Updated: 2026-09-03. AI-assisted working document; verify against source and tests.

## Scope and design

Grove records the local microphone and imports existing audio/video files. It is not
a remote-meeting audio recorder. System-output taps, aggregate-device creation,
system-audio capture service, input-mode picker, and audio-output permission text
have been removed. Historical dual-channel paths/manifests remain read-compatible;
removal of the capture feature does not delete users' recordings.

The UI keeps Pretendard and the existing neutral palette: canvas #F5F6F7, white
surface, ink #24282C, restrained green #39765D, and amber review status. The primary
layout is a left folder sidebar and a left-aligned document/list. No new decorative
dashboard or global meeting-size control is added. The frontend-design guidance is
reference material, subordinate to the user's plain, native macOS preference.

## Recording and options

- `AudioRecorder.isRecording` describes an active session, including pause.
- Pause uses `AVAudioRecorder.pause()`. Resume calls `record()` on the same object;
  failure leaves it paused. Stop is valid while paused.
- Elapsed/final duration uses recorded `currentTime`, not wall time, so pauses are
  excluded. The HUD shows pause state and separate continue/finish controls.
- New-recording and import sheets copy saved defaults into independent local drafts.
  Cancelling/changing one draft never changes global defaults or prior recordings.
- Only Settings manages persistent defaults. Per-recording configuration is stored
  in the meeting index and restored for explicit reprocessing.
- This feature's recording/folder behavior is independent of engine selection. The
  user-approved beta routing is documented in `ultra8-option-and-speaker-count.md`.

## Folders and identity

- `MeetingRecord.folderID` is optional; old records decode without migration loss.
- `library.json` separately stores folders, defaults, and saved speaker identities.
- Folder creation/rename, moving a recording, all-recordings and unfiled views are
  available. Deleting a folder moves recordings to unfiled; audio/transcripts stay.
- Metadata writes validate, back up, and replace atomically. Malformed metadata is
  not silently overwritten. Folder-delete metadata failure attempts index rollback
  and explicitly reports partial completion if rollback also fails.
- Saved speakers are UUID identities scoped to a folder, not strings or cluster IDs.
  A user saves a confirmed name, then explicitly connects that profile to a speaker
  in another recording. Same display names never imply the same person.
- This beta stores **names only**, not voiceprints, and runs **no automatic voice
  matching**. Automatic identity recognition is outside the approved shipped feature
  contract. Experimental extractor/matcher code is not evidence of a supported capability.
- Existing linked profiles cannot be duplicated by re-saving. Renaming a local speaker
  clears that link; deleting the saved profile does not rewrite historical transcripts.
- Transcript schema 4 adds optional profile provenance and reversible profile changes;
  schema 3 remains readable. Any unconfirmed identity in a document is marked as
  inferred in the UI and TXT/Markdown export, not silently asserted as fact.

## Validation and remaining gates

Tests cover pause/resume failure, stopping while paused, old data decoding, folder
persistence/moving/deletion, malformed metadata, independent drafts, folder-scoped
manual profile reuse, no voiceprint collection, identity undo/redo, and export labels.

Real microphone interruption/resumption across hardware disconnects and a long sleep
remain hardware QA, not established by fake-recorder unit tests. Automatic cross-meeting
identity matching needs separate-session/device/unknown-speaker validation and is not
complete. Accuracy must be qualified separately for each target recording condition.

Private recordings, speaker references, identity scores and qualitative diagnostics
remain in ignored local storage. They are excluded from public documentation and fixtures.

See handoff and release readiness for the actually installed build and test results.
