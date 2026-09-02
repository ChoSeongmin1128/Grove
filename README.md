# Grove

Grove is an experimental local-first macOS meeting recorder and transcription app.
Audio and meeting metadata stay on the Mac unless the user explicitly exports them.

> Grove is an early prototype. It is not yet a production-ready meeting recorder,
> and the current UI is scheduled for redesign.

## Current capabilities

- native SwiftUI macOS app
- microphone recording to M4A
- optional Core Audio system-output and microphone capture to separate files
- audio and video file import
- Korean post-meeting transcription with Apple `SpeechTranscriber`
- local meeting library under Application Support
- original audio preservation
- experimental glossary conditioning through `AnalysisContext`

The app does not currently provide reliable automatic speaker diarization, speaker
editing, final WhisperKit integration, or TXT/Markdown export. Those are active design
and evaluation areas rather than finished features.

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

The packaged application is written to `dist/Grove.app`.

## Optional local glossary

Grove starts with no built-in organization terms or personal names. To test local
context conditioning, copy [`config/glossary.example.json`](config/glossary.example.json)
to:

```text
~/Library/Application Support/Grove/glossary.json
```

This machine-local file is never required for a clean build and should not be committed.
Raw transcription and normalized/corrected text must remain separate records.

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
- use Core Audio for audio-only system capture; do not request screen recording solely
  for audio
- do not ship organization-specific terms, names, examples, or demo meetings
- measure Korean multi-speaker quality on private reference data before selecting a
  default diarization engine

Research notes are indexed in [`AGENTS.md`](AGENTS.md). They are AI-assisted working
documents and must be checked against current code and primary sources.
