# Speaker diarization research

Status: research and local private-sample diagnosis

Verified: 2026-09-03

> This document is AI-assisted. Public model claims are not Grove quality results. The
> unpublished audio, transcripts, speaker names, RTTM files, and raw measurements are not
> part of this repository.

## Current diagnosis

The private Korean sample is 180 seconds, mono, and has four known human speakers. Two
male voices are reported to sound similar.

SpeakerKit 1.1.0 produced three substantial clusters plus one 1.256-second cluster made
only of short overlapping fragments. No transcribed word was assigned to the short
cluster. Exclusive reconciliation removed it and left three clusters.

The following additional tests did not recover the fourth person:

- exact speaker count set to four
- exact four plus exclusive reconciliation
- automatic clustering thresholds 0.45, 0.50, 0.55, 0.60, 0.65, and 0.70
- repeated automatic execution

All non-exclusive conditions produced the same partition up to label permutation. The
repeat was byte-identical. Therefore the earlier conclusion that the meeting probably
had three people was wrong. The stronger explanation is:

1. two real speakers were merged into one substantial cluster;
2. an overlap or unstable fragment consumed the fourth cluster slot;
3. fixed-count clustering could not recover the missing boundary from the available
   segmentation and embeddings.

This is consistent with the general failure mode of segmentation + speaker-embedding +
clustering systems on short turns, overlap, and similar voices. It is not enough to tune
one global distance threshold.

## How these models are normally run on a Mac

### Qwen3-ASR

The official Qwen3-ASR Python examples are CUDA/vLLM-oriented. They load 0.6B or 1.7B
models with `device_map="cuda:0"`, recommend FlashAttention, and use a separate
Qwen3-ForcedAligner when timestamps are required. Korean is an explicitly supported
language, but the official repository does not document a first-class Apple MPS or Core
ML deployment path.

Source: <https://github.com/QwenLM/Qwen3-ASR>

Mac applications therefore normally choose one of these non-upstream runtime strategies:

1. **MLX/Metal** — third-party Swift or Python conversion of quantized 0.6B/1.7B weights.
   This uses the Apple GPU and is the most flexible native long-form path.
2. **Core ML/ANE** — converted audio encoder/decoder models. This can keep the GPU free
   and reduce power, but export details such as attention masks and input buckets can
   materially change accuracy.
3. **Local sidecar** — a separate MLX/Python/CLI process exposes a localhost API while the
   Swift app owns recording, storage, and UI. This isolates model crashes and lets the app
   unload a large model after post-processing.

Current native projects include:

- <https://github.com/soniqo/speech-swift> — MLX and Core ML Qwen3-ASR plus forced aligner
- <https://github.com/FluidInference/FluidAudio> — experimental `Qwen3AsrManager` Core ML path

Qwen3-ASR is transcription, language detection, and optional alignment; it does **not**
solve speaker diarization. A Grove Qwen path would still need a full-meeting diarizer and
timestamp reconciliation. Third-party English speed/WER results do not establish Korean
meeting quality, so Qwen should enter the same private A/B gate as Whisper rather than be
selected from model-card rankings.

### pyannote

The upstream pyannote Community-1 model card documents CPU execution by default and CUDA
placement for acceleration. It does not document production MPS support. Open PyTorch
reports show pyannote MPS failures on recent Apple Silicon combinations, so Grove should
not base its packaged app on Python MPS behavior.

Source: <https://huggingface.co/pyannote/speaker-diarization-community-1>

Recent MPS failure report: <https://github.com/pytorch/pytorch/issues/181650>

The common Mac production route is to convert the neural segmenter and speaker embedder to
Core ML, then keep binarization, PLDA/AHC/VBx clustering, and timeline reconstruction in
Swift/C++. SpeakerKit and FluidAudio follow this pattern. A separate MLX conversion is
useful for research, but voice embeddings from different backends must not be mixed in one
identity database unless cross-backend equivalence is measured.

For Grove, upstream Python pyannote should be a slow reference implementation, while a
native Core ML or end-to-end diarizer is the deployable candidate.

## Candidate families

### SpeakerKit / pyannote Community-1 Core ML

SpeakerKit is the current native baseline. Argmax describes it as an on-device Core ML
implementation of pyannote Community-1 with automatic/fixed speaker count, clustering
thresholds, regular/exclusive output, transcript reconciliation, and RTTM export.

- Strength: native Swift/Core ML, already measured as fast after model preparation.
- Strength: current API exposes per-cluster centroid embeddings for cross-meeting matching.
- Failure in Grove sample: fixed four and threshold sweeps did not split the similar pair.
- Integration issue: CLI 1.1.0 `transcribe --diarization` did not preserve labels in its
  JSON/SRT report, so Grove would need direct API use or explicit RTTM/word merging.

Sources:

- <https://github.com/argmaxinc/argmax-oss-swift#speakerkit>
- <https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0>
- <https://huggingface.co/pyannote/speaker-diarization-community-1>

The original pyannote Community-1 pipeline is still worth one reference run. If official
PyTorch pyannote separates four speakers while Core ML SpeakerKit does not, the problem is
conversion/implementation/tuning. If both merge the same pair, switching wrappers will
not solve it. Run with `num_speakers=4` and retain both regular and exclusive outputs.

### FluidAudio offline VBx

FluidAudio's offline pipeline also uses powerset segmentation, 256-dimensional WeSpeaker
embeddings, AHC warm start, PLDA/VBx clustering, and full-file reconstruction. It exposes
speaker embeddings, fixed speaker bounds, progress, RTTM scoring, and individual pipeline
timings.

This is a useful independently implemented baseline but not a guaranteed model change.
Because it belongs to the same broad segmentation/embedding/clustering family, it may
repeat the same similar-voice merge.

Source: <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md>

### FluidAudio Sortformer

Sortformer is the highest-priority alternative for the known four-speaker case.
FluidAudio documents these properties:

- end-to-end diarization rather than post-hoc AHC/VBx clustering
- up to four speakers
- strong speaker-order and identity stability
- better behavior on noise and overlap than the legacy online diarizer
- speaker enrollment support, including similar voices
- possible missed quiet speech and degradation when many loud voices overlap

The four-speaker ceiling matches this sample exactly but is not a good universal product
limit. Grove should test it as a post-meeting or live provisional track and retain a
fallback for meetings with more than four people.

Source: <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md>

### FluidAudio LS-EEND

LS-EEND supports up to ten speakers and high overlap. FluidAudio describes it as lighter
and eager to detect speech, but more prone to false alarms and less stable identities than
Sortformer. It is a secondary comparison for larger meetings, not the first replacement
for this four-speaker sample.

Source: <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md>

### MOSS-Transcribe-Diarize 0.9B

MOSS jointly generates transcript text, timestamps, and anonymous speaker tags in one
autoregressive pass. The upstream model card states support for 50+ languages, audio up to
90 minutes, hotwords, and Korean participation in the 2026 multilingual challenge.
However, the published objective table is dominated by Chinese meeting/media datasets and
does not provide a Korean per-language diarization metric.

The upstream model is a Whisper-Medium audio encoder plus Qwen3-style 0.6B decoder. The
main safetensors file is about 1.82 GB. The official Python implementation has important
Mac limitations:

- `resolve_device("auto")` selects CUDA or CPU only; it does not select MPS;
- non-CUDA inference uses float32;
- loading requires `trust_remote_code=True`;
- it needs the complete recording and cannot provide a normal streaming transcript;
- long audio increases both prompt/context memory and autoregressive decode cost.

Sources:

- <https://github.com/OpenMOSS/MOSS-Transcribe-Diarize>
- <https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize>
- <https://arxiv.org/abs/2601.01554>

There are newer third-party Apple paths:

- MLX Audio Swift: <https://github.com/Blaizzy/mlx-audio-swift>
- speech-swift MLX/Core ML path: <https://github.com/soniqo/speech-swift/blob/main/docs/inference/moss-transcribe-diarize.md>
- ggml/GGUF port: <https://github.com/localai-org/moss-transcribe.cpp>

These make MOSS technically feasible on an M4 Pro with 24 GB RAM. They do not yet make it
a suitable Grove default. The Swift/MLX integrations are recent, there is no published
Korean four-speaker result for Grove's conditions, and a joint generative model makes it
harder to independently revise ASR text, speaker boundaries, and overlap truth.

`speech-swift` reports an M5 Pro INT5 experiment with 987 MiB of weights, 1,281 MiB peak
RSS and 15.5× realtime diarization throughput. Its five-file English VoxConverse slice had
28.05% pooled DER and only 40% speaker-count accuracy, although the one four-speaker file
scored 6.95% DER. This demonstrates feasibility and high variance, not Korean quality or an
M4 Pro guarantee.

Benchmark source: <https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/moss-mlx.md>

Recommendation: test MOSS MLX as an **offline second-pass challenger**, not as the live or
default production pipeline. Compare its speaker-attributed output to Whisper + a separate
diarizer on the same manually labeled meetings.

A local build attempt of `soniqo/speech-swift` commit
`7d8bd294e8657e87e5c76902992692d3999dfb9c` resolved a large Swift dependency graph but
stalled while downloading its binary `SpeechCore.xcframework` artifact. It was stopped
after more than five minutes without starting compilation. No MOSS weights were downloaded
and no M4 Pro inference result was produced. This is integration-friction evidence only,
not a MOSS performance result.

## Open-source application findings

Three related repositories were shallow-cloned and inspected at fixed commits. They were
not built or executed.

| Project | Commit | Relevant pattern |
|---|---|---|
| Meeting Transcriber | `d73f35ed5a1d5a47068a9bf05b8d670d974e7a05` | FluidAudio offline/Sortformer switch, exact speaker count, overlap-excluded embeddings, echo quarantine |
| Muesli | `a070956a4e2dd1c044cb4c045918b402aa6b8972` | separate mic/system sources, raw transcript contract, diarization reconciliation, Markdown/PDF export |
| diarize | `39f8948c49355870a45eb80ac5271f72c6656051` | segment embedding storage, top-K cross-meeting matching, rename/reassign/split/merge, GRDB migrations |

`diarize` most directly matches the requested correction workflow, but it has almost no
public adoption evidence. Meeting Transcriber has the strongest defensive production
logic. Grove should reimplement the required contracts in its own versioned model instead
of copying one app wholesale.

See `docs/open-source-local-meeting-apps-2026-09-02.md` for the broader comparison.

## Evaluation contract

The next test must start with a reference annotation, not another visual inspection of
anonymous clusters.

1. Label every speech interval as non-identifying `R1` through `R4` and mark overlaps.
2. Create a reference transcript with word/segment timestamps.
3. Run every candidate on the same mono input with no manual post-correction.
4. Preserve raw regular output and derive exclusive output only for ASR assignment.
5. Calculate:
   - speaker-count error
   - DER with no forgiveness collar and overlap included
   - JER
   - speaker confusion matrix and pairwise merge/split time
   - cpCER or speaker-attributed CER
   - overlap recall and short-turn recall
   - cold/warm wall time, RTF, peak RSS, system memory pressure, and energy
6. Repeat on at least three longer Korean meetings. One three-minute clip is a diagnostic,
   not a model-selection benchmark.

## Grove recommendation

Short term:

1. Keep Whisper large-v3 as the quality transcript baseline and Apple Speech as the fast
   preview path.
2. Replace the current three-speaker interpretation with four known anonymous people in
   the private reference annotation.
3. Test FluidAudio Sortformer first, official pyannote Community-1 second, and MOSS MLX as
   an offline joint-model challenger.
4. Do not rely on a fixed cluster count alone. The current test demonstrates that an
   artifact cluster can consume the requested fourth slot.
5. Ship manual correction before claiming reliable automatic speaker identity.

Product data model:

- `sourceChannelID`: microphone/system/import source
- `speakerClusterID`: one diarizer revision's anonymous cluster
- `speakerProfileID`: optional user-confirmed person
- raw overlapping intervals: immutable engine output
- exclusive word assignment: replaceable derived output
- speaker edits: versioned range/cluster operations with undo

Voice enrollment can help map already-separated clusters across meetings. It cannot
recover a second person after the diarizer has merged both voices into one cluster, so it
must not be presented as the fix for the current failure.
