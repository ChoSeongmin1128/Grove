# Grove handoff

Updated: 2026-09-03

> This is an AI-assisted working document. Verify every important statement against the
> current source, tests, and runtime before acting on it.

## Product direction

Grove is a general-purpose local-first macOS meeting recorder and transcription app.
The product should prioritize recording safety, readable speaker-attributed transcripts,
manual correction, and simple export. Internal engine and capture terminology should stay
out of the primary UI.

## Verified implementation

- SwiftUI macOS app shell and local meeting list
- microphone M4A recording
- optional Core Audio system-output CAF plus separate microphone recording
- audio/video file import
- Apple `SpeechTranscriber` Korean post-meeting transcription
- `AnalysisContext` contextual strings from an optional local glossary
- original audio and meeting JSON in Application Support
- recording elapsed time and channel level HUD
- app icon assets and release packaging script

The public source ships with no organization glossary, personal names, or private demo
meeting. A local glossary can be placed at
`~/Library/Application Support/Grove/glossary.json`.

## Known product gaps

### Speaker workflow

- `TranscriptSegment.speaker` is still a plain `String`.
- source channels are currently displayed like human speakers.
- anonymous cluster, human profile, range reassignment, merge, and undo are missing.
- Apple transcription currently returns one transcript without person diarization.

### Export

- full transcript copy is missing.
- TXT and Markdown save flows are missing.
- export options for speaker names, timestamps, and summaries are undefined.

### UI

- current typography and layout are prototypes and require redesign.
- implementation details appear too prominently in some screens.
- review and glossary tools compete with the core meeting library and transcript flow.

## Diarization finding

An unpublished 3-minute Korean meeting sample has four known speakers. SpeakerKit's
automatic and forced-four runs produced the same partition: three substantial clusters
plus a short overlap-only cluster. Exclusive reconciliation removed the short cluster,
leaving three speakers. Threshold changes from 0.45 through 0.70 did not change the
partition except for label permutation.

This is evidence that the current pipeline merges two acoustically similar speakers; it
is not evidence that the meeting has three speakers. See
`docs/speaker-diarization-research-2026-09-03.md` for the evaluation plan. Private audio,
transcripts, RTTM files, names, and raw metrics are excluded from Git.

## Proposed next implementation

1. Add versioned `sourceChannel`, `speakerClusterID`, and optional `speakerProfileID`.
2. Persist raw overlapping diarization and derive an exclusive display track.
3. Add segment/range/cluster speaker reassignment, merge, and undo.
4. Add transcript copy and TXT/Markdown export.
5. A/B FluidAudio offline, FluidAudio Sortformer, pyannote Community-1, and MOSS on
   manually labeled Korean meetings before selecting a default.
6. Keep large experimental models behind an internal engine protocol until quality,
   memory, packaging, and license gates pass.

## Migration constraints

- Existing meeting JSON stores `speaker: String` and `glossaryProfile: String`.
- A new schema must continue decoding v0.2 records.
- Legacy speaker strings must not be assumed to be either source channels or confirmed
  human identities.
- Avoid in-place mutation of original transcript or audio records.

## Minimum completion criteria

- a clean install contains no private organization terms or personal names
- existing v0.2 meeting fixtures migrate and open
- speaker edits support one segment and a whole cluster with undo
- TXT and Markdown preserve Korean Unicode and selected export options
- Swift and Python tests, release build, signing verification, and app smoke test pass
- only the canonical `/Applications/Grove.app` remains after installation

## Unverified risks

- 60-minute Core Audio capture stability and channel clock drift
- crash recovery of real CAF/manifest sessions
- Korean four-speaker DER/JER and speaker-attributed CER
- similar-voice speaker confusion and overlap handling
- 8 GB and 16 GB Apple Silicon memory and thermal behavior
- usability of the redesigned speaker correction flow

This research-only update did not replace `/Applications/Grove.app`.
