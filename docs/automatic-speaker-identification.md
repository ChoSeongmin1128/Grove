# Voice enrollment and automatic names

2026-10-08. Source behavior and evaluation requirements. Automatic naming remains
unqualified; successful storage, rendering or model execution does not establish
recognition accuracy.

## Available flow

A folder's Team section supports adding and renaming people, recording their voice,
replacing a registration and deleting its encrypted voice features independently of
the saved name. Name changes affect future uses; existing transcript edits remain
unchanged.

Microphone enrollment:

1. Prepare the optional voice model when the user requests it.
2. Read the displayed casual Korean prompts in a normal meeting voice.
3. Switch to free speech about recent work or an ordinary experience.
4. Inspect recording duration, sufficiently loud intervals and clipping; listen back.
5. Confirm the recording was authorized and contains only that person's voice.
6. Extract several independent spans and save their encrypted features. Delete the
   temporary recording on success or cancellation.

The prompts and roughly 60–90 seconds total / 20–30 seconds free speech are starting
points for evaluation, not validated optimums or mandatory recording times. The
amplitude check is not VAD, speaker separation, a noise classifier or proof that one
person is present. Failed consistency checks require another recording; they never
average conflicting speakers into a profile. Capture is limited to two minutes.
Interrupted enrollment captures from terminated processes are removed at next launch;
files belonging to a live process and unrelated files are left alone.

The natural-speech design is motivated by mismatch between read and spontaneous
speech, not proof that mixing both during enrollment improves accuracy:
[Interspeech 2025](https://www.isca-archive.org/interspeech_2025/martinek25_interspeech.html).

## Models and storage

The optional voice feature assets are approximately 15.3 MB from the pinned
[FluidInference model repository](https://huggingface.co/FluidInference/speaker-diarization-coreml).
`ModelCatalog` contains individual file sizes and SHA256 hashes. Download, resume,
capacity checks and verification reuse the existing model manager. A separate
readiness receipt follows a synthetic CoreML execution check. Default MOSS / Nemotron
readiness does not depend on this optional model.

`LocalSpeakerVoiceService` reads Grove-managed `Models/VoiceIdentity`, using the
versioned active-frame-centered feature recipe. Models and preprocessing participate
in the fingerprint; older recipes cannot silently compare against new registrations.
This recipe can collect registrations but is not yet qualified for automatic names.
FluidAudio's `SpeakerManager` is a streaming-diarizer API, not an attachment to
Nemotron's anonymous outputs. Grove uses a separate feature/matching step:
[official API](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/SpeakerManager.md).

Each selected span retains its own 256-dimensional vector, range and source hash in
`SpeakerVoiceVault`. Features use AES-GCM; separate generation keys remain in Keychain.
The public names index contains no voice vectors. New registrations from microphone
capture have no fictitious meeting, transcript revision or speaker identifier. Those
optional identifiers remain compatible with older meeting-derived records.

The existing transaction contract remains: publish addressable metadata before a
Keychain write, atomically publish encrypted data, persist cleanup obligations, then
remove old keys. Interrupted or failed writes stay addressable for cleanup. Never
remove a name before its voice storage is cleaned up. Missing keys or corrupt ciphertext
fail without overwriting a registration. Names-only backups strip legacy plaintext
voice fields. Automatically inferred matches never augment enrollment data.

## Attendance

New-meeting setup supports optional registered people, named guests and unnamed guests.
It displays the total and remembers the latest selection per folder. Calendar recording
opens this same setup with the event title. Changing folders restores that folder's
selection; unavailable profiles are removed from the draft.

Attendance is stored separately from inference options. Five attendees with three
actual speakers is valid. Attendance never sets a diarizer's required speaker count.
Unregistered names and guest counts are not voice identity evidence. The explicit
selected registered profiles form the matching candidates; an empty selection does
not search the whole team. Legacy/imported records without attendance preserve the
previous folder-based candidate scope. Mac basic transcription has no diarization,
so it does not gain automatic speaker names through attendance.

## Automatic naming remains gated

`VoiceIdentityReleaseGate.isEnabled` remains false. Voice search, post-transcription
naming and legacy meeting-derived enrollment remain disabled. Dedicated microphone
registration and manual name linking are available. There is no product CLI or
environment override for automatic naming.

After qualification, the intended flow is MOSS transcription and existing diarization,
followed by independent feature extraction and direct application of sufficiently
consistent names. Ambiguous or unknown voices stay anonymous. No repeated confirmation
prompt is required. `isConfirmed` remains distinct from an inferred name; source
clusters and manual assignments remain intact. User name/assignment edits and identity
undo/redo history prevent automatic overwrites. Recognition failure never fails ASR.

Current thresholds (similarity 0.85, runner-up margin 0.15, inter-span consistency 0.80)
are uncalibrated guardrails, not probabilities or production accuracy guarantees.
Registration currently requires 3–5 spans and at least 10 seconds in total; query
matching requires 2–5 consistent spans. New microphone recordings select spans from
both prompt reading and free speech. These limits also require evaluation.

Several non-overlapping clusters may receive the same registered identity after each
passes matching. If their transcript intervals or retained activity evidence overlap,
those identity assignments are deferred. Naming cannot repair two people merged into
one cluster. Same-recording IDs or identical source bytes exclude self-comparisons;
file hashes cannot detect every re-encoded copy.

## Independent evaluation

`VoiceIdentityQualificationTests.evaluateIndependentRecordings` consumes explicit
private enrollment/query manifests. Different session IDs and audio hashes are required
between enrollment and evaluation. Use different days in the supplied data, not two
segments from the same meeting. Conditions are researcher-supplied labels, not measured
proof of microphone variation or similar voices.

The output includes model fingerprint, extraction time, audio hashes and separate
counts for correct known names, wrong known names, missed known names and unknown
false accepts. It compares a small threshold grid without re-running inference and
never enables the release gate. Rejecting every known person is not success.

Manifest entries:

```json
{
  "enrollments": [{
    "id": "registration-a", "personID": "person-a", "sessionID": "registration-day",
    "audioPath": "audio/registration-a.wav",
    "ranges": [{"start": 1, "end": 6}, {"start": 8, "end": 13}, {"start": 15, "end": 20}]
  }],
  "queries": [{
    "id": "meeting-a", "personID": "person-a", "sessionID": "another-day",
    "audioPath": "audio/another-meeting.wav",
    "ranges": [{"start": 10, "end": 15}, {"start": 30, "end": 35}],
    "candidates": ["person-a"], "conditions": ["different-microphone"]
  }]
}
```

`personID: null` denotes an unknown person. Add all five registered people, other-day
queries, absent-person/candidate exclusion, unknown guests, similar voices and
microphone/distance changes before assessing release readiness. A single-person example
is a format example, not adequate qualification. Use ground-truth single-speaker spans
to isolate identity errors, then separately evaluate diarizer-produced spans.

Developer-only execution, with an output directory that does not already exist:

```bash
GROVE_VOICE_IDENTITY_MANIFEST=.work/voice-evaluation/manifest.json \
GROVE_VOICE_IDENTITY_OUTPUT=.work/voice-evaluation/run-1 \
GROVE_VOICE_IDENTITY_MODELS=.work/voice-models/Models/VoiceIdentity \
taskpolicy -b swift test --jobs 2 --scratch-path .work/swift \
  --filter VoiceIdentityQualificationTests
```

The developer evaluation needs Swift; distributed app users do not. Keep all recordings,
labels, voice vectors, paths and evaluation outputs outside public Git. Select thresholds
on development data and confirm them on separate holdout sessions. Measure additional
processing time and memory before describing the feature as lightweight.
