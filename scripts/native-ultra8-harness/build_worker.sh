#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 NEW_BUILD_DIRECTORY NEW_STAGING_DIRECTORY" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This local-beta worker build is validated only for Apple Silicon macOS." >&2
  exit 2
fi
source_root="$(cd "$(dirname "$0")" && pwd -P)"
build_root="$1"
destination="$2"
if [[ -e "$build_root" || -e "$destination" ]]; then
  echo "Build and staging paths must be new; refusing to overwrite existing work." >&2
  exit 2
fi
mkdir -p "$build_root"
build_root="$(cd "$build_root" && pwd -P)"
checkout="$build_root/parakeet-rs"
revision=1d6ffeae1b8641f497e4ef9a5e9fff37aa7a4181
git clone --filter=blob:none --no-checkout https://github.com/altunenes/parakeet-rs.git "$checkout"
git -C "$checkout" checkout --detach "$revision"
git -C "$checkout" apply --check "$source_root/upstream.patch"
git -C "$checkout" apply "$source_root/upstream.patch"
cp "$source_root/grove_ultra8.rs" "$checkout/examples/grove_ultra8.rs"
cp "$source_root/Cargo.lock" "$checkout/Cargo.lock"
export CARGO_HOME="$build_root/cargo-home"
export CARGO_TARGET_DIR="$build_root/target"
cargo test --manifest-path "$checkout/Cargo.toml" --locked --release --example grove_ultra8 --features sortformer -j 2
cargo build --manifest-path "$checkout/Cargo.toml" --locked --release --example grove_ultra8 --features sortformer -j 2
mkdir -p "$destination/Licenses/parakeet-rs" "$destination/Licenses/onnxruntime" "$destination/Licenses/nemo"
cp "$CARGO_TARGET_DIR/release/examples/grove_ultra8" "$destination/grove-ultra8"
cp "$checkout/LICENSE" "$destination/Licenses/parakeet-rs/LICENSE"
cp "$source_root/Cargo.lock" "$destination/Cargo.lock"
cp "$source_root/README.md" "$destination/README.md"
cp "$source_root/UPSTREAM-NOTICE.txt" "$destination/Licenses/UPSTREAM-NOTICE.txt"
for crate in "$CARGO_HOME"/registry/src/*/*; do
  [[ -d "$crate" ]] || continue
  name="$(basename "$crate")"
  while IFS= read -r notice; do
    [[ -f "$notice" ]] || continue
    relative="${notice#"$crate/"}"
    mkdir -p "$destination/Licenses/$name/$(dirname "$relative")"
    cp "$notice" "$destination/Licenses/$name/$relative"
  done < <(find "$crate" -type f \( -name 'LICENSE*' -o -name 'NOTICE*' -o -name 'COPYING*' \))
done
curl -fL https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.0/LICENSE \
  -o "$destination/Licenses/onnxruntime/LICENSE"
curl -fL https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.0/ThirdPartyNotices.txt \
  -o "$destination/Licenses/onnxruntime/ThirdPartyNotices.txt"
curl -fL https://raw.githubusercontent.com/NVIDIA-NeMo/Speech/ea1ebf55b25fceff372f885b4e7b5803f3d33dea/LICENSE \
  -o "$destination/Licenses/nemo/LICENSE"
otool -L "$destination/grove-ultra8"
echo "Worker staged without model weights. The app packager must sign the executable."
