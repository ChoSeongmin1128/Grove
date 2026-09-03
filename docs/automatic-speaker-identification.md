# Automatic speaker identification: proposal, not shipped

2026-09-03. AI-assisted notes. This is a researched proposal, not authorization to
collect voiceprints or evidence that automatic recognition works in Grove.

## Meaning of the requested feature

[NAVER WORKS' official introduction](https://naver.worksmobile.com/blog/clovanote-speaker-identification/)
describes linking a clear voice to an address-book person once, then recognizing
that person in later meetings. The article permits correcting an association and
notes sensitivity to noise, overlap and short/unclear speech. It does not disclose
the recognition model, retraining procedure or a local-only implementation.

Distinguish three independent tasks:

- Diarization: determine which anonymous speaker is active at each time.
- Text projection: assign recognized words/utterances to activity.
- Identification: associate voice characteristics with a previously registered person.

A failed word-alignment experiment is not proof that cross-meeting identification
is impossible. Naming a mixed cluster does not separate people the diarizer already
merged. Never infer identity from attendance count or transcript mentions alone.

## Current Grove behavior

`GroveStore.saveSpeakerProfile` saves folder-scoped names and source IDs, with no voice
feature extraction. Applying a saved profile is explicit and manual. Research-only
`VoiceEmbeddingExtractor` and `SpeakerProfileMatcher` do not run in normal app flow.

The current sample selector does not require explicit human-reviewed enrollment
evidence. Library/backup storage was designed for names, not an encrypted voice
registry. Do not simply connect these helpers and call the feature complete.

## Proposed local flow

Keep MOSS and the selected diarizer. Add a separate identification stage:

1. The user explicitly chooses **remember this voice** for a named person in a folder.
   Select several clean, sufficiently long, non-overlapping, human-confirmed spans.
   Reject inconsistent samples instead of averaging two people into one identity.
2. Extract versioned local voice characteristics. Compare new meeting clusters only
   with that folder's registered people, unless the user explicitly broadens scope.
3. Evaluate match strength, runner-up separation and agreement across multiple spans.
   Unknown people and ambiguous matches remain unnamed. Similarity is not a calibrated
   probability, and there is no universal production threshold.
4. Initially suggest a name while preserving the anonymous source cluster. Permit
   confirm, correct, disconnect and undo. Automatic display can later be an explicit
   option after separate-session validation; inferred names stay distinguishable.
5. Never absorb automatic matches into enrollment samples. Only explicit confirmation
   may add or replace a sample, with evidence and an undoable history boundary.

Store voice data locally in a dedicated encrypted registry with a protected key.
Registration, replacement and deletion must cover stale backup/cache copies, not just
the live profile array. Deleting enrollment must not erase historical transcript
text. Decide retention/export behavior before collecting voice data; do not upload it.

## Implementation evidence and verification gates

- [FluidAudio known-speaker documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)
  demonstrates embedding extraction and initialization with named speaker profiles.
- [sherpa-onnx speaker-identification example](https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/speaker-identification.py)
  demonstrates explicit embedding registration, thresholded search and unknown output.

These are implementation candidates, not measured Grove accuracy. Inspect the pinned
API/model/export before adoption; replacing the existing diarizer is not necessary
just to add a separate identity layer.

Enroll from one session and evaluate different sessions, microphones and distances.
Include similar voices, missing registered participants and genuinely new people.
Measure wrong-name assignments separately from unrecognized speakers and DER. Do not
evaluate enrollment against the same spans used to create it. Keep raw audio, voice
features, labels and all private evaluation evidence out of public Git.
