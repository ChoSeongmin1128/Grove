# Grove

Grove is an experimental local-first macOS meeting recorder and transcription app.
Audio and meeting metadata stay on the Mac unless the user explicitly exports them.

> Grove is a local beta, not a production-ready recorder or a self-contained model
> installer. Current builds require preinstalled native workers and model weights.

## Current capabilities

- native SwiftUI macOS app
- microphone-only recording to M4A, with pause/resume
- audio and video file import
- Korean post-meeting transcription with a native MOSS worker
- independent diarization: Ultra8 by default for unknown count or 1–8 people,
  Community-1 for an entered count of 9+, and manually selectable Sortformer4
- per-recording engine/count options; persistent defaults live in Settings
- local folders, recording-title editing, and explicit reuse of saved speaker names
- utterance text/speaker editing, splitting, undo/redo and TXT/Markdown export
- original audio preservation, path access and byte-preserving file export

Speaker names are not automatically matched across meetings. Ultra8/Sortformer4 count
entry is advisory, not an exact cluster-count constraint. A successful transcription
or an acknowledged speaker warning does not certify transcription accuracy or approve
training data. AI summaries and dataset-quality annotation/export are not shipped.

## Requirements

- macOS 26 or newer
- Apple Silicon
- Swift 6.2 / Xcode 26

## Build

```bash
swift test
python3 -m unittest discover -s tests -v
./scripts/package_app.sh release
codesign --verify --deep --strict dist/Grove.app
```

The packaged application is written to `dist/Grove.app`. Packaging expects qualified
workers in `results/native-workers` (or `GROVE_NATIVE_WORKERS_DIR`), including their
matching resources and license notices. This ignored directory is not part of a fresh
checkout. See the [MOSS worker](scripts/native-moss-harness/README.md) and
[Ultra8 worker](scripts/native-ultra8-harness/README.md) build notes; the app also uses
FluidAudio and speech-swift helpers described in [third-party notices](THIRD_PARTY_NOTICES.md).
Models are stored separately under Grove's Application Support directory and are not
bundled in the app or this repository. Source builds/tests do not establish that the
runtime models are installed or that a release is notarized.

## Optional glossary experiments

Grove starts with no built-in organization terms or personal names. To test local
context conditioning, copy [`config/glossary.example.json`](config/glossary.example.json)
to:

```text
~/Library/Application Support/Grove/glossary.json
```

This machine-local file is never required for a clean build and should not be committed.
Apple/Whisper benchmark scripts retain glossary experiments; the current MOSS app path
does not inject that glossary. Raw transcription and corrections remain separate records.

## Private evaluation data

Audio, video, transcripts, RTTM/SRT files, licensed datasets, benchmark outputs, and
machine-local glossary profiles are excluded by `.gitignore`. The public repository
contains only generic test fixtures.

If you add your own dataset, keep it under `test-data/` and generated outputs under
`results/`. Neither directory is tracked.

## Design principles

- preserve original audio and raw transcripts
- keep input source, anonymous speaker cluster, and confirmed human identity separate
- treat summaries and corrections as derived revisions with source references
- support local microphone recording and file import, without system-output capture
- keep processing completion, speaker-review issues and dataset approval separate
- do not ship organization-specific terms, names, examples, or demo meetings
- measure Korean multi-speaker quality on private reference data before selecting a
  default diarization engine

Research notes are indexed in [`AGENTS.md`](AGENTS.md). They are AI-assisted working
documents and must be checked against current code and primary sources.
