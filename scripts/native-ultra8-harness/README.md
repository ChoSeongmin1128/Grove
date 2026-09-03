# Native Ultra8 worker

This headless Apple Silicon macOS helper accepts:

```text
grove-ultra8 INPUT_WAV MODEL_ONNX OUTPUT_JSON
```

Input must be nonempty 16 kHz mono PCM16 WAV. It loads only the supplied local ONNX
model; it does not download weights, upload audio or open an app window. Use a new
output path. Existing files, including symlinks, are never overwritten. Output is
published atomically only after successful inference and validation.

## Pinned model and runtime

- Model: [investguy/ultra_diar_streaming_sortformer_8spk_v1_onnx](https://huggingface.co/investguy/ultra_diar_streaming_sortformer_8spk_v1_onnx).
- Model revision: `2a45f114eaf920b4d50b04a5964cc1aab35ddf5f`.
- Model SHA256: `c64a1fb633ad52b77103ce0c0a0dd2b5f55a71f029083ed819901e36c7420c0a`.
- parakeet-rs 0.3.7 at `1d6ffeae1b8641f497e4ef9a5e9fff37aa7a4181`.
- ort 2.0.0-rc.13 / ONNX Runtime 1.28.0, CPU execution provider,
  four intra-op threads and one inter-op thread. No GPU/ANE provider is selected.
- Speaker activity shape: eight columns; model capacity is eight, not a request to
  produce eight speakers. No exact-N parameter is available.
- Streaming metadata is checked: chunk 340, right context 40, FIFO 40, cache 376.
- The model SHA256 is verified before loading. Wrong/modified model files fail closed.

These are model/runtime identities and source configuration values, not observations
about a private recording.

## Postprocessing contract

The worker uses raw probabilities and the NeMo-default threshold configuration:
onset=offset=0.5, with no median smoothing, padding, gap merging or minimum durations.
Exactly 0.5 retains the previous activity state. Intervals are half-open; overlapping
speakers are retained. Timestamps follow 80 ms model frames rounded to two decimal
places, then clipped to the input duration. This differs from parakeet-rs's
CallHome/median-filter configuration and must be treated as a separate processing route.

Output JSON contains `schemaVersion: 1`, `engine: "ultra8"`, `maxSpeakers: 8`,
`speakerCountConstraint: null`, `modelRevision`, `modelSHA256`,
`postprocessing: "nemo-default-0.5"`, `durationSeconds`, `processingSeconds`,
`inferenceSeconds`, `frameCount`, and `segments: [{start, end, speaker}]`.
Speaker values are anonymous decimal strings `"0"` through `"7"`. No identities or
reference labels are embedded in this helper. Silence may legitimately produce no
segments. Nonzero exit means no successful result; stderr contains the error.

## Build and stage

Prerequisites: Apple Silicon macOS, Rust/Cargo with edition 2024 support, Xcode command
line tools, Git and curl. Use new paths under an ignored local build/result folder:

```sh
bash scripts/native-ultra8-harness/build_worker.sh NEW_BUILD_DIRECTORY NEW_STAGING_DIRECTORY
```

The script clones the pinned upstream revision, applies `upstream.patch`, installs
the retained `Cargo.lock`, runs helper unit tests and creates a release worker.
It collects Rust crate licenses plus ONNX Runtime LICENSE/ThirdPartyNotices in staging.
Use a toolchain compatible with the lockfile and validate the intended deployment target.
No model weights are staged.

The outer app packager signs and installs the worker and notices in the bundle.
The current Grove preset selects this helper for unknown count or an entered 1–8,
while preserving explicit engine choices. See [Grove](../../README.md) and
[engine/count options](../../docs/ultra8-option-and-speaker-count.md).

The build directory is disposable after staging and validation. Do not delete supplied
models, originals, or private evaluation evidence as part of routine build cleanup.

## Validation and limits

Synthetic unit tests cover threshold equality, overlap, clipping, invalid probabilities,
silence, and non-overwriting output publication. Local parity checks should compare
segments with the declared postprocessing applied to the same raw model output.
Recording-derived expected outputs, scores, error analyses, timing, and memory observations
must remain outside public Git and public documentation.

Model capacity does not establish diarization accuracy. Original-checkpoint to converted-model
numerical parity, long-file memory behavior, and end-to-end application correctness are
separate validation requirements. Upstream feature extraction loads the recording into
memory; do not infer bounded long-recording memory from the word "streaming".
An application preset is not evidence of a quality ranking or an exact-N constraint.
