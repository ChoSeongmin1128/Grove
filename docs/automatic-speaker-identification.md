# Automatic speaker identification: implemented foundation, release blocked

2026-09-03. AI-assisted notes. Verify these contracts in code and tests. Source
integration is not evidence that automatic recognition works accurately. Private
measurements and recordings stay in ignored results, never this document.

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

`VoiceIdentityReleaseGate.isEnabled` is **false**. The installed-source default rejects
new voice enrollment, manual voice search and post-transcription automatic matching
before extraction. UI says validation is pending; it must not look like an available
feature or collect voices while matching is blocked. No command-line or environment
override enables the product feature. Tests can explicitly inject availability with
synthetic extractors, isolated storage and fake keys.

`saveSpeakerProfile` remains names-only. Applying saved names is manual. Existing
voice cleanup is available even while enrollment/matching is blocked. The old
`SpeakerProfileMatcher`/`VoiceProfileSelection` are legacy research helpers, not the
new production integration. Do not enable the release gate merely because tests pass.

## Implemented, gated flow

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
5. Never absorb automatic matches into enrollment samples. Confirmation only confirms
   the displayed name; adding/replacing voice samples requires a separate explicit
   registration. Neither action approves transcript text or training data.

Enrollment requires three to five distinct clean utterances, at least ten seconds
after boundary trimming, and explicit same-person/permission confirmation. Raw activity
must cover the utterance sufficiently without a competing cluster. Do not hide mixed
enrollment by averaging vectors: compare individual samples and reject inconsistency.
Query requires multiple clean spans and agreement, an absolute similarity guard and
separation from the runner-up. Thresholds are versioned beta guardrails, not calibrated
probabilities. A single registered person is a particularly important unknown-person
test, not permission to always choose that person.

Same recording ID or identical audio bytes exclude self-enrollment comparisons.
Re-encoded copies with different IDs are not reliably detected; byte hashes do not
prove independent sessions. Folder opt-in defaults off. Existing human names,
assignments and identity undo/redo history prevent automatic overwrites. Duplicate
claims by separate clusters for one profile are all deferred. A suggestion stores its
model/policy, registration timestamp and query IDs without embedding vectors.

Async work binds the document, folder/library and source audio; changes before apply
discard the proposal. Save before publishing UI state. Cancellation before the commit
point publishes nothing; during encrypted commit the cancel button is disabled.
An identification failure does not turn successful transcription into failure.

## Storage, failure and deletion contracts

- `SpeakerVoiceVault` stores only AES-GCM ciphertext. Folder/profile/key generation are
  authenticated. Keys are stored separately in OS Keychain, never a local plaintext key.
- Each replacement gets a fresh key. Publish ciphertext atomically before removing
  old keys. Surface post-publication cleanup failure separately from failed publication.
- Persist the profile's cleanup reference before touching Keychain. A failed first
  enrollment remains addressable after restart even if no live ciphertext was published.
  Delete voice storage successfully before deleting its name or folder metadata.
- New `library.json` saves and backups strip legacy embedding fields. Do not silently
  migrate legacy embeddings into the vault. A names-only save cannot replace a profile
  ID that might still own keys. Voice deletion retains historical names/text/undo.
- Missing keys, tampering, unsafe paths and oversized files fail closed. No automatic
  reset, plaintext fallback, cloud upload or inclusion in ordinary JSON backup/export.
- Local ad-hoc beta uses the login Keychain explicitly; Data Protection Keychain needs
  signing/entitlements not provided by an ad-hoc beta. A new ad-hoc app signature can
  lose access to older keys. This is a release gate, not an automatic recovery path.
- Key deletion cannot guarantee erasure of Keychain backups, memory copies or original
  audio. Do not claim forensic deletion. Interrupted private audio preparation can
  leave temporary audio; it contains no plaintext voice vectors and needs scoped cleanup.
- Optional fields remain decodable with older documents. Do not roll back to an older
  app to modify voice-linked names: it cannot preserve the new cleanup contract.

## Implementation evidence and verification gates

- [FluidAudio known-speaker documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)
  demonstrates embedding extraction and initialization with named speaker profiles.
- [sherpa-onnx speaker-identification example](https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/speaker-identification.py)
  demonstrates explicit embedding registration, thresholded search and unknown output.

These are implementation candidates, not measured Grove accuracy. Inspect the pinned
API/model/export before adoption; replacing the existing diarizer is not necessary
just to add a separate identity layer.

## Conditions before enabling the release gate

Enroll from one session and evaluate different sessions, microphones and distances.
Include similar voices, missing registered participants and genuinely new people.
Measure wrong-name assignments separately from unrecognized speakers and DER. Do not
evaluate enrollment against the same spans used to create it. Keep raw audio, voice
features, labels and all private evaluation evidence out of public Git.

Test registration acceptance and useful known-person recall alongside wrong-name
assignments. Rejecting everyone is not a successful identification feature. Changes
to preprocessing require a distinct model fingerprint; never compare their vectors
with registrations from another recipe. The active-frame-centering recipe in source
is diagnostic, not a qualified default. Qualify Keychain add/read/forget, interrupted
commit and signed-app replacement with synthetic keys before enabling collection.
