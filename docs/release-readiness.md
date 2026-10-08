# Release readiness

Current source: 0.4.0 / local-beta.14. Actual installed bundle, signing, notarization,
model qualification and test receipts belong in the private `HANDOFF.md` entry point.
Do not reuse an older installed-beta statement as proof of current runtime state.

| Capability | Current boundary |
| --- | --- |
| Precision transcription | Bundled MOSS / Nemotron 3; first-run pinned model preparation |
| Mac basic transcription | Apple-managed Korean assets; no diarization |
| Microphone recording | Local capture, pause / resume and original preservation |
| Calendar | Selected calendars from Mac accounts; app-running reminders |
| Notion | Rich copy, divider / child page at parent end; explicit transmission |
| Existing data | Legacy configurations and transcripts remain readable; no destructive migration |
| Distribution | Developer ID / hardened runtime / notarization script; credentials outside Git |

Required commands and runtime checks are in [distribution](distribution.md).
Additional gates: independent Korean meetings with 5+ speakers, real microphone device /
sleep recovery, comprehensive IME / VoiceOver / drag and drop, large Notion documents /
concurrent editing, and first download / actual transcription on a separate Mac without
developer tools. Mock service success does not establish live Calendar or Notion success.

Do not downgrade new Apple-mode records to a reader that does not understand the new
transcription / no-diarization values. Original recordings and prior revisions remain intact.
