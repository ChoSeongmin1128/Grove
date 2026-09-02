# Third-party notices

## AudioCap

The Core Audio process-tap implementation in Grove was informed by AudioCap:

- Copyright (c) 2024 Guilherme Rambo
- Source: https://github.com/insidegui/AudioCap
- License: BSD 2-Clause (full text: `AudioCap-LICENSE.txt`)

Grove's implementation was rewritten for a global audio tap, local meeting
storage, crash-recovery manifests, and Swift concurrency isolation. Apple’s
“Capturing system audio with Core Audio taps” sample and the current macOS SDK
headers remain the primary API references.
