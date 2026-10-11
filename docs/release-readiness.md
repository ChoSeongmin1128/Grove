# Release readiness

Current source: 0.4.0 / local-beta.27. Actual installed bundle, signing, notarization,
model qualification and test receipts belong in the private `HANDOFF.md` entry point.
Do not reuse an older installed-beta statement as proof of current runtime state.

| Capability | Current boundary |
| --- | --- |
| Precision transcription | Bundled MOSS / Nemotron 3 (up to eight speakers, advisory count); first-run pinned model preparation |
| Mac basic transcription | Apple-managed Korean assets; no diarization |
| Microphone recording | ADTS capture that survives a crash, lossless M4A repackaging, pause / resume and original preservation |
| Calendar | Selected Mac calendars, compact app-running reminders and meeting setup |
| Team voices | Optional pinned voice model, prompt / free-speech capture and encrypted registration |
| Attendance | Optional per-recording candidates; independent from actual speaker count |
| Automatic names | Disabled pending independent-session known / unknown qualification |
| Notion | Hosted-MCP OAuth or advanced manual token; rich copy and parent-end divider / child page; grant-scoped session reuse and uncertain-write recovery |
| AI summaries | Not implemented; provider integration research does not authorize implementation |
| Existing data | Legacy configurations and transcripts remain readable; no destructive migration |
| Distribution | Developer ID / hardened runtime / notarization script; credentials outside Git |

Required commands and runtime checks are in [distribution](distribution.md).
Additional gates: independent Korean meetings with 5+ speakers, real microphone device /
sleep recovery, comprehensive IME / VoiceOver / drag and drop, large Notion documents /
concurrent editing, and first download / actual transcription on a separate Mac without
developer tools. Mock service success does not establish live Calendar or Notion success.

Do not downgrade new Apple-mode records to a reader that does not understand the new
transcription / no-diarization values. New standalone team profiles also require a reader supporting optional source identifiers.
Original recordings and prior revisions remain intact.
