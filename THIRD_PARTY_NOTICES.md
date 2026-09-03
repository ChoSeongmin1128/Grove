# Third-party notices

## Pretendard

Grove bundles the unmodified Regular, Medium, and SemiBold fonts from Pretendard 1.3.9.
Copyright (c) 2021, Kil Hyung-jin. Distributed under the SIL Open Font License 1.1.
The complete license is included with the fonts in the app resource bundle.
Source: https://github.com/orioncactus/pretendard/tree/v1.3.9

## Native local beta workers

- MOSS worker: MLXAudio Swift 0.1.3 and MLX Swift 0.31.6. Dependency resolution and
  collected upstream license notices are included under `Contents/Resources/Licenses/Moss/`.
  Sources: https://github.com/Blaizzy/mlx-audio-swift and https://github.com/ml-explore/mlx-swift.
- FluidAudio: native Sortformer streaming CLI, Apache 2.0. The upstream license is
  included under `Contents/Resources/Licenses/FluidAudio-LICENSE.txt`.
  Source: https://github.com/FluidInference/FluidAudio.
- speech-swift 0.0.26: native Community-1 CLI, Apache 2.0, Copyright 2025 Ivan Digital.
  License: `Contents/Resources/Licenses/SpeechSwift-LICENSE.txt`.
  Source: https://github.com/soniqo/speech-swift/tree/v0.0.26.
- Ultra8 helper: Grove's pinned parakeet-rs/ONNX Runtime CPU integration. Source,
  dependency lock and build instructions are under `scripts/native-ultra8-harness/`;
  collected notices are bundled under `Contents/Resources/Licenses/Ultra8/`.
  Sources: https://github.com/altunenes/parakeet-rs and https://github.com/microsoft/onnxruntime.
  Ultra weights are from mago-ai's eight-speaker fine-tune, converted by investguy.
  Model and upstream NVIDIA base-model terms are separate from runtime source licenses:
  https://huggingface.co/mago-ai/ultra_diar_streaming_sortformer_8spk_v1 and
  https://huggingface.co/investguy/ultra_diar_streaming_sortformer_8spk_v1_onnx.

Model weights remain in machine-local caches, not the app or public repository.
This artifact is a local beta, not a notarized or audited public binary distribution.

Research-only voice matching tests use locally cached FluidAudio community-1
FBANK/WeSpeaker Core ML models (metadata: CC BY 4.0). The local beta does not run
automatic voice matching or store voiceprints; folder speaker reuse is manual.
