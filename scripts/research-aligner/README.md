# Frozen-MOSS alignment research harness

Standalone research code; it does not change Grove's application or installed models.
Private audio, transcription, alignment units and measurements belong under ignored
`results/`, never in this directory or public Git.

`prepare_model.py` downloads a pinned MLX 8-bit conversion of Qwen3-ForcedAligner-0.6B
and hashes every model file. The official Qwen model supports Korean and describes
speech inputs up to five minutes. That is a model contract, not proof of accuracy on
overlapping meeting speech. The MLX conversion has not been checked for numerical
parity with the official weights/runtime.

Preparation requires a new directory and refuses existing directories or locations
inside installed apps, the user's Library, or the standard active Hugging Face cache.
For a failed download, use another explicitly chosen new research directory; no existing
snapshot is silently replaced.

The tested runtime is Python3.11, mlx-audio0.5.1, MLX0.32.2 and soynlp0.0.493.
Use `requirements.txt` in an isolated environment. The complete resolved dependency
inventory is also stored with each private alignment result.

- Official model: https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B
- Runtime/API: https://github.com/Blaizzy/mlx-audio
- Pinned conversion: https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit/tree/0e1a68e91d815300c7c9754b2a7639378b23db15

`align_moss.py` reads a complete native MOSS JSON and an existing mono16kHz recording.
For each MOSS utterance it aligns the unchanged spoken body to the corresponding
audio crop with a fixed half-second context on both sides. It removes only the exact
generated leading speaker label, matching Grove's decoder. No reference labels are
read, and no character-proportional timing is invented. The full source text and
crop offsets remain available for lossless downstream projection.

The upstream Korean tokenizer may split words and remove punctuation. The original
text is retained separately. The runtime's standard timestamp postprocessor repairs
nonmonotonic predictions, sometimes by interpolation; raw timestamp predictions and
repair flags are therefore saved. Invalid, zero-duration or repaired units must not
be treated as independently verified word timings. Alignment does not recover ASR
omissions or correct a mistaken diarization activity map.

Example, using caller-owned private paths:

```sh
python scripts/research-aligner/prepare_model.py --directory PRIVATE_MODEL_DIR --manifest PRIVATE_MANIFEST_JSON
python -m unittest discover -s scripts/research-aligner -v
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 python scripts/research-aligner/align_moss.py \
  --audio PRIVATE_AUDIO --moss PRIVATE_MOSS_JSON \
  --model-directory PRIVATE_MODEL_DIR --model-manifest PRIVATE_MANIFEST_JSON \
  --output PRIVATE_ALIGNMENT_JSON
```

The output includes pinned model hashes, dependency versions, source hashes, unit
text/start/end, source utterance index/crop offsets, integrity checks and resource
observations. Process RSS and MLX allocation peaks are different measures; neither
alone is total device memory. Repeated development samples are not unseen holdouts.

`validate_alignment.py --alignment PRIVATE_ALIGNMENT_JSON --moss PRIVATE_MOSS_JSON`
checks unchanged source bodies/indices/bounds and timestamp geometry. It also counts
raw nonmonotonic predictions separately from the upstream-repaired output. Passing
this check is structural integrity only, not an accuracy score or human review.

`--mode whole-clip` instead joins the unchanged bodies with exactly one space and calls
the aligner once on the entire audio (at most five minutes). Sequential Unicode kept-character
mapping assigns returned units back to source parents. Boundary-crossing text portions
retain the same predicted time with `crossesSourceUtteranceBoundary` and
`timeIsParentContext: true`; they must remain unknown, not receive proportional sub-times.
A lexical mapping failure is recorded as `sourceMappingFailed` with `unmappedWords`,
without guessing a parent. Fixed original parent text remains available for conservation.

Whole-clip execution uses a configurable memory guideline and own-process allocation/RSS
watchdog, limited to12GiB. MLX's limit is a guideline, not an absolute OS allocation cap.
The watchdog terminates only its own process on excess. Do not run concurrent heavy jobs.

For provenance validation, supply `--harness-snapshot` and, when available,
`--expected-alignment-sha256`. Results must explicitly declare schema1 and
`referenceUsed: false`; missing values and boolean utterance indices are rejected.
