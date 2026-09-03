# Offline speaker-logic experiments

AI-assisted working notes. Verify source, tests and raw evidence. Research harnesses
are not connected to Grove's inference, saved documents or installed application.
Private measurements and inspection notes stay in ignored `results/`.

## Scope and provenance

Keep a frozen native MOSS output and a frozen Ultra8 output. Do not rerun or change
ASR words to improve a speaker-only comparison. Original generated labels are removed
only by the same exact prefix rule as `ExternalOutputDecoder.mossBody`; all remaining
characters, punctuation and whitespace are preserved in the derived text.

- A: production-v1 whole-utterance overlap assignment.
- B-generated: align unchanged text to audio, then use valid unit timestamps for
  overlap assignment. Standard upstream timestamp repair remains visible in flags.
- B-guarded: additionally leave flagged alignment units unassigned. Invalid times
  never acquire invented nearest/proportional timing; their source text survives and
  any playback interval is explicitly the parent context, not a word boundary.
- C: independently apply hysteresis or a short same-cluster gap fill to the same
  frozen posterior. Never remove short speech, merge identities, or bridge over a
  different active speaker. Exact baseline turn reproduction is a precondition.
- D: optional exploratory combination, only after the independent comparisons.

Forced alignment uses an additional model. It is not a pure-logic upgrade, cannot
recover words missing from ASR and cannot identify a person absent from the raw
diarization. Crop context and whole-recording context are distinct experimental
conditions, not interchangeable runtime benchmarks.

The Qwen3 ForcedAligner model supports Korean according to its
[official repository](https://github.com/QwenLM/Qwen3-ASR). The research harness uses
the [MLX Audio implementation](https://github.com/Blaizzy/mlx-audio); model/runtime
revisions, license, checksums, timestamp repairs and resources must accompany a run.
This is not evidence of Grove app integration or validated native Swift performance.

## Evaluation contracts

- Text CER: NFKC, lowercase, letters/digits only; no spelling correction. Always
  report it separately from speaker-attributed text and speaker activity.
- Speaker-attributed CER: concatenated speaker streams with minimum-permutation edit
  cost. Unassigned text is forced to an unmapped insertion stream, never optimally
  relabelled as a real person. Missing reference text still counts as deletion, so
  this conservative unknown extension of cpCER can exceed 100%.
- DER: original activity tracks, collar zero, overlap included, silence included in
  the supplied UEM. Same-cluster duplicate activity is unioned; different-speaker
  overlap survives. Independently cross-check the interval sweep with pyannote.
- Short-turn coverage: diagnostic only, not a replacement for DER or text quality.
- Inspect every emitted utterance against the working reference as well as the
  numbers. Keep missing reference turns and uncertain overlap timing visible.

Word assignment does not alter raw activity DER. A tiny score change on a previously
inspected development fixture is not generalization evidence. Do not tune a grid on
that fixture or call it a held-out test. Word-boundary accuracy itself needs manual
word labels; utterance labels cannot prove it.

Sources are read into byte snapshots and hashed with the content used. Alignment
must bind both the exact audio and MOSS source, explicitly exclude reference input,
and preserve source utterance IDs/text/times. Failure never overwrites a prior run.
These sidecars are not app documents and must not be imported as correction history.

## Entry points

- `scripts/research_speaker_postprocess.py`: frozen-posterior C conditions.
- `scripts/research-aligner/`: pinned local model preparation and alignment-only runs.
- `scripts/research_speaker_logic.py`: projection, metrics and full-turn inspection.

Each script accepts explicit private paths. Keep all input/output paths under ignored
local storage. The evaluator requires a native MOSS envelope, a corrected TSV, and a
UEM file. `scripts/research-metrics-requirements.txt` records the tested Python3.12
scientific dependencies; use a separate environment from the aligner. Production
has no new dependency. Default tests skip scientific checks when they are unavailable.

```sh
python3 -m unittest discover -s tests -v
python3 -m unittest discover -s scripts/research-aligner -p 'test_*.py' -v
python3 scripts/research_speaker_logic.py --help
python3 scripts/research_speaker_postprocess.py --help
```

For future app implementation, preserve `InferenceResult.validate()`'s historical
projection-v1 behavior. Add a separately versioned derived result instead of changing
the verifier for old raw runs. Human corrections and confirmations are never replaced
by a new automatic experiment.
