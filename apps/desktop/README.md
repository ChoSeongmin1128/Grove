# Grove desktop

First native development slice for macOS and Windows. The application is named
Grove. It has a separate identity and never opens the legacy Swift library.

## Build

Install a supported Node.js version (see `package.json`), Rust and the native Tauri
prerequisites for the target OS. Windows builds need MSVC Build Tools, the Windows
SDK and WebView2; use a native Windows environment rather than WSL for acceptance.

From this directory:

```sh
npm ci
npm test
npm run build
npm run tauri -- build --debug --bundles app --ci -- --locked
```

On Windows use `--bundles nsis` instead of `--bundles app`. Build outputs are under
the workspace's `.work/rust-target`. Run Rust tests from the repository root with
`cargo test -p grove-core --locked`. Build/test one native target at a time.

For a macOS local test bundle, apply ad hoc signing after bundling and then run
`codesign --verify --deep --strict` on that bundle. This does not provide Developer ID
signing or notarization; use a separate distribution configuration for a release.

`npm run tauri -- dev` starts a development app. `npm run dev` alone serves its
frontend, whose actions require the native bridge; it does not supply fake meetings.
`prepare:shared` copies canonical design-system files into generated build inputs.

## Current behavior

- Create meetings, edit title/notes and reopen them after restarting.
- Select an input device and explicitly start microphone recording.
- When no input device is available, recording stays disabled; connect a microphone
  and refresh the device list to enable it. Existing recording controls stay available.
- Pause/resume/stop and use a separate compact control window.
- Preserve raw PCM and prepare a separate WAV for playback.
- Recover complete stored frames after interruption; retain originals on failure.
- On Apple silicon with macOS 26 or later and packaged workers, import local audio
  through the native file picker, retaining the original bytes and separate playback WAV.
- Explicitly prepare the pinned MOSS model, then transcribe finalized audio locally.
  Downloads are checked against the shared manifest; inference uploads no audio.
- Edit transcript text, seek to a segment, and reopen corrections after restarting.
  Raw worker output and correction revisions are retained separately. Cancelling or
  failing a rerun preserves the previous transcript.
- Hide the main window without ending recording. Explicit quit flushes notes and
  finalizes the active recording after confirmation.

The application identifier is `io.github.choseongmin1128.grove.desktop`.
Tauri resolves its own OS application data directory. No automatic legacy migration,
Keychain access, automatic model installation or account connection occurs.

## Optional macOS transcription workers

Build the pinned Release/macOS `MossHarness` scheme as described in
`scripts/native-moss-harness/README.md`, using task-local build and checkout directories.
Then, from the repository root, stage its matching resources before the Tauri build:

```sh
apps/desktop/scripts/prepare-native.sh XCODE_RELEASE_DIRECTORY CHECKOUTS_DIRECTORY
```

This compiles the shared audio preparer and packages the worker, its matching Metal
resources, dependency notices and resolution lock under `.generated/native`.
The worker destination must be new; existing packages are never silently replaced.
No development tools are needed by the resulting app. The recording app itself retains
its macOS 13 minimum; this optional transcription route requires Apple silicon/macOS 26.
Absent or unsupported workers leave transcription unavailable. Windows transcription
is not implemented. Models remain outside the application bundle in its own data directory.

The model snapshot and file hashes are shared with the retained Swift implementation
through `Sources/GroveApp/Resources/Models/moss.json`. Preparation starts only from the
app's explicit model button. The current downloader retains interrupted files but does
not resume partial bytes; retry checks complete files and downloads missing files again.

The packaging icon is temporary; the final Grove logo has not been selected.

## Remaining acceptance work

Native compilation does not prove recording reliability. On both operating systems,
test actual microphone permission, device removal, pause/resume, reopen/playback,
sleep/resume, low disk space, force termination and long recordings alongside a
meeting app. Windows NSIS installation and WebView2 provisioning need native checks.
Code signing, notarization and release-license review are separate release gates.

The current recorder has a RIFF WAV size limit and no automatic device reconnect.
It interrupts rather than silently claiming success on device/queue/write errors.
See the core README for queue capacity and file recovery details.

Diarization, summaries, domain dictionaries and reference-based summary context remain
future integrations. MOSS worker execution does not establish transcript accuracy or
speaker identities; model qualification and release acceptance remain separate work.
