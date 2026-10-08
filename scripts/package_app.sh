#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
case "$configuration" in
  debug|release) ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 2
    ;;
esac

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${GROVE_APP_OUTPUT:-$project_root/.work/dist/Grove.app}"
contents_path="$app_path/Contents"
build_path="$project_root/.work/swift-build"
binary_path="$build_path/$configuration/Grove"
workers_path="${GROVE_NATIVE_WORKERS_DIR:-$project_root/.work/native-workers}"

# Local beta uses already-qualified native workers, never a Python/Homebrew runtime.
for worker in Moss/MossHarness fluidaudiocli speech Ultra8/grove-ultra8 Nemotron/bin/nemo-speech; do
  if [[ ! -x "$workers_path/$worker" ]]; then
    echo "Missing native worker: $worker. Prepare GROVE_NATIVE_WORKERS_DIR before packaging." >&2
    exit 2
  fi
done
test -f "$workers_path/Moss/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.work/module-cache"
swift build --scratch-path "$build_path" --jobs 2 -c "$configuration" --product Grove

if [[ -e "$app_path" ]]; then
  /usr/bin/trash "$app_path"
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
mkdir -p "$contents_path/Helpers" "$contents_path/Resources/Licenses"
cp "$binary_path" "$contents_path/MacOS/Grove"
cp "$project_root/App/Info.plist" "$contents_path/Info.plist"
cp "$project_root/App/Icon/Grove.icns" "$contents_path/Resources/Grove.icns"
cp -R "$build_path/$configuration/Grove_GroveApp.bundle" "$contents_path/Resources/"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$contents_path/Resources/"
cp "$project_root/ThirdParty/FluidAudio-LICENSE.txt" "$contents_path/Resources/Licenses/"
cp "$project_root/ThirdParty/SpeechSwift-LICENSE.txt" "$contents_path/Resources/Licenses/"
moss_contents="$contents_path/Helpers/Moss.bundle/Contents"
mkdir -p "$moss_contents/MacOS" "$moss_contents/Resources"
cp "$workers_path/Moss/MossHarness" "$moss_contents/MacOS/MossHarness"
cp "$project_root/App/MossWorker-Info.plist" "$moss_contents/Info.plist"
for bundle in mlx-swift_Cmlx swift-crypto_Crypto swift-transformers_Hub; do
  ditto "$workers_path/Moss/$bundle.bundle" "$moss_contents/Resources/$bundle.bundle"
done
ditto "$workers_path/Moss/Licenses" "$contents_path/Resources/Licenses/Moss"
cp "$workers_path/Moss/Package.resolved" "$contents_path/Resources/Licenses/Moss/Package.resolved"
cp "$workers_path/fluidaudiocli" "$contents_path/Helpers/fluidaudiocli"
cp "$workers_path/speech" "$contents_path/Helpers/speech"
cp "$workers_path/Ultra8/grove-ultra8" "$contents_path/Helpers/grove-ultra8"
ditto "$workers_path/Ultra8/Licenses" "$contents_path/Resources/Licenses/Ultra8"
mkdir -p "$contents_path/Helpers/Nemotron"
ditto "$workers_path/Nemotron/bin" "$contents_path/Helpers/Nemotron/bin"
mkdir -p "$contents_path/Helpers/Nemotron/lib"
cp -P "$workers_path/Nemotron/lib/"*.dylib "$contents_path/Helpers/Nemotron/lib/"
ditto "$workers_path/Nemotron/share/nemo-speech" "$contents_path/Resources/Nemotron"
ditto "$workers_path/Nemotron/share/licenses/nemo-speech" "$contents_path/Resources/Licenses/Nemotron"
while IFS= read -r library; do
  /usr/bin/codesign --force --sign - "$library"
done < <(find "$contents_path/Helpers/Nemotron/lib" -type f -name '*.dylib')
/usr/bin/codesign --force --sign - "$contents_path/Helpers/Nemotron/bin/nemo-speech"
for worker in fluidaudiocli speech grove-ultra8; do
  /usr/bin/codesign --force --sign - "$contents_path/Helpers/$worker"
done
/usr/bin/codesign --force --sign - "$contents_path/Helpers/Moss.bundle"
printf 'APPL????' > "$contents_path/PkgInfo"

/usr/bin/plutil -lint "$contents_path/Info.plist" >/dev/null
/usr/bin/codesign \
  --force \
  --sign - \
  --entitlements "$project_root/App/Grove.entitlements" \
  "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo "$app_path"
