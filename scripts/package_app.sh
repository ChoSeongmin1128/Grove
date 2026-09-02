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
app_path="$project_root/dist/Grove.app"
contents_path="$app_path/Contents"
binary_path="$project_root/.build/$configuration/Grove"

cd "$project_root"
swift build -c "$configuration" --product Grove

if [[ -e "$app_path" ]]; then
  /bin/rm -rf "$app_path"
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/Grove"
cp "$project_root/App/Info.plist" "$contents_path/Info.plist"
cp "$project_root/App/Icon/Grove.icns" "$contents_path/Resources/Grove.icns"
cp "$project_root/config/domain-glossary.v1.json" "$contents_path/Resources/"
cp "$project_root/config/speaker-hints.v1.json" "$contents_path/Resources/"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$contents_path/Resources/"
cp "$project_root/ThirdParty/AudioCap-LICENSE.txt" "$contents_path/Resources/"
printf 'APPL????' > "$contents_path/PkgInfo"

/usr/bin/plutil -lint "$contents_path/Info.plist" >/dev/null
/usr/bin/codesign \
  --force \
  --sign - \
  --entitlements "$project_root/App/Grove.entitlements" \
  "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo "$app_path"
