#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
output="$root/apps/desktop/.generated/native"
mkdir -p "$output"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'MOSS native preparation currently requires macOS.' >&2
  exit 1
fi
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos26.0" \
  "$root/Sources/GroveInference/InferenceConfiguration.swift" \
  "$root/Sources/GroveInference/AnalysisAudioPreparer.swift" \
  "$root/scripts/audio-prepare/AudioPrepare.swift" -o "$output/AudioPrepare"
codesign --force --sign - "$output/AudioPrepare"
if [[ $# != 2 ]]; then
  echo 'AudioPrepare ready. Supply matching Xcode Release products and package checkouts to stage MOSS.'
  exit 0
fi
"$root/scripts/native-moss-harness/package_worker.sh" "$1" "$2" "$output/moss"
chmod -R u+rwX "$output/moss"
