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
- speech-swift 0.0.26: native Community-1 CLI, Apache 2.0, Copyright 2025 Ivan Digital.
  License: `Contents/Resources/Licenses/SpeechSwift-LICENSE.txt`.
  Source: https://github.com/soniqo/speech-swift/tree/v0.0.26. Its Community-1 Core ML weights
  are used only at the verified revision of https://huggingface.co/aufklarer/Pyannote-Community-1-CoreML.
- Nemotron 3: official NeMo-Speech.cpp 0.2.0 Metal helper. Runtime notices are included
  under `Contents/Resources/Licenses/Nemotron/`. Source: https://github.com/NVIDIA/NeMo-Speech.cpp.
  The separately downloaded Q8 model is distributed under OpenMDW 1.1:
  https://huggingface.co/nvidia/Nemotron-3-Diarization.

Model weights remain in machine-local caches, not the app or public repository.
Signing and notarization status must be established for each packaged build; these
notices do not certify a public binary distribution.

Optional team voice enrollment downloads the pinned FBANK / WeSpeaker Core ML models from
https://huggingface.co/FluidInference/speaker-diarization-coreml (metadata: CC BY 4.0) on
request. Voice features are stored encrypted; automatic naming remains disabled.
