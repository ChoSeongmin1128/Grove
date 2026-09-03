# Recording names and original files

2026-09-03. AI-assisted implementation notes. Check handoff for installed version and
actual QA; these features are separate from the planned annotation/review mode.

## Interaction

- A pencil button beside the detail title opens **녹음 이름 변경**. Library and sidebar
  recording context menus also expose **이름 변경…**.
- **원본 파일…** opens file details independent of transcription success, with the stored
  absolute path, selectable text, **경로 복사**, **Finder에서 보기**, and **원본 파일 저장…**.
- Rename changes only the meeting-index display title. Audio paths, UUIDs, transcription,
  corrections and timestamps are unchanged. Empty/multiline/control-character names fail.
- Rename is allowed during recording and inference; completed inference must not restore
  an old captured title. Index write failure leaves the old UI title and index intact.
- Export is a byte-for-byte copy, not transcoding. Imported video remains its original
  file format. Suggested names use the display title and preserve the source extension.
- Recording/paused capture blocks export until stopped. Completed, failed and currently
  transcribing recordings may export. Missing files show their known path and a useful
  error; the app does not search elsewhere and silently substitute another file.
- A primary audioPath wins. Old dual-channel records expose each source separately;
  this does not reintroduce computer-output capture.

## Safety

- UI obtains a destination through NSSavePanel. Overwrite requires the save panel's user
  confirmation; the copy layer additionally supports explicit no-overwrite operation.
- Export runs off the main actor with a 1MiB buffer. It writes a private destination-side
  temporary file, checks source/destination identity and modification state, then publishes
  atomically. Failed/cancelled work removes only its own temporary copy.
- The source itself, hardlinks, destination symlinks/aliases and Grove-managed directories
  (including symlinked ancestors) cannot be overwritten by export.
- Source size/inode/mtime/ctime changes abort the copy. The initial size bounds copying so
  a growing recording cannot create an unbounded copy operation.
- One export is active at a time. UI exposes cancellation and blocks dismissal during copy.
  Quit checks active export and prevents new recording/import/export while awaiting
  inference cancellation; state is rechecked before allowing termination.
- File bytes are preserved; xattrs/ACL/Finder tags are not promised. Final noncooperative
  external-writer races are not a filesystem CAS guarantee. Unsupported atomic publication
  fails instead of falling back to a destructive partial write.

## Validation coverage

`RecordingManagementTests` covers title persistence and failed saves, original/document
preservation, rename during inference, export without a transcript, capture blocking,
quit/export interleaving, and an opt-in local-file copy. Public fixtures are synthetic;
private file contents and file-derived measurements are not publication artifacts.
`OriginalRecordingFileTests` covers source selection, names, byte equality, explicit
replacement, links/protected directories, cancellation, source changes and cleanup.
Actual GUI actions and unperformed checks are recorded in handoff, not assumed from tests.
