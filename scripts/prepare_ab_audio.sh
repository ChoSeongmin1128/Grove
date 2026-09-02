#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 INPUT_FILE_OR_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 2
fi

input_path="$1"
output_dir="$2"

if [[ ! -e "$input_path" ]]; then
  echo "Input does not exist: $input_path" >&2
  exit 1
fi

mkdir -p "$output_dir"

convert_one() {
  local source="$1"
  local filename stem target
  filename="$(basename "$source")"
  stem="${filename%.*}"
  target="$output_dir/${stem}.wav"
  /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$source" "$target"
  echo "$target"
}

if [[ -f "$input_path" ]]; then
  convert_one "$input_path"
else
  found=0
  while IFS= read -r -d '' source; do
    convert_one "$source"
    found=1
  done < <(
    find "$input_path" -maxdepth 1 -type f \
      \( -iname '*.wav' -o -iname '*.m4a' -o -iname '*.caf' \
         -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.mp3' \
         -o -iname '*.mp4' -o -iname '*.mov' \) -print0
  )
  if [[ "$found" -eq 0 ]]; then
    echo "No supported audio or video files found in: $input_path" >&2
    exit 1
  fi
fi
