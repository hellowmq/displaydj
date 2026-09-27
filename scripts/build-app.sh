#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=debug
case "${1:-}" in
  --release) configuration=release ;;
  '') ;;
  *) echo 'Usage: scripts/build-app.sh [--release]' >&2; exit 2 ;;
esac
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
version="$("$bin_dir/display-cli" version --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["version"])')"
app="$PWD/.build/DisplayDJ.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DisplayDJBar" "$app/Contents/MacOS/DisplayDJBar"
cp "$bin_dir/display-cli" "$app/Contents/MacOS/display-cli"
cp "$bin_dir/displaydj" "$app/Contents/MacOS/displaydj"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp LICENSES/DisplayDJ.txt "$app/Contents/Resources/DisplayDJ-LICENSE.txt"
cp LICENSES/VibeDisplay.txt "$app/Contents/Resources/VibeDisplay-LICENSE.txt"
iconset="$PWD/.build/DisplayDJIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PWD/Assets/DisplayDJIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$PWD/Assets/DisplayDJIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/DisplayDJ.icns"
python3 - "$app" "$version" <<'PY'
import plistlib,sys,pathlib
app=pathlib.Path(sys.argv[1])
with (app/'Contents/Info.plist').open('wb') as f:
 plistlib.dump(dict(CFBundleExecutable='DisplayDJBar',CFBundleIdentifier='io.github.hellowmq.displaydj',CFBundleName='DisplayDJ',CFBundleDisplayName='DisplayDJ',CFBundleIconFile='DisplayDJ.icns',CFBundleVersion=sys.argv[2],CFBundleShortVersionString=sys.argv[2],CFBundlePackageType='APPL',LSMinimumSystemVersion='13.0',LSUIElement=True,NSHighResolutionCapable=True,NSHumanReadableCopyright='MIT; DisplayDJ, VibeDisplay and MonitorControl contributors'),f)
PY
sign_identity="${DISPLAYDJ_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$sign_identity")
sign_label='ad-hoc signed; not notarized'
if [[ "$sign_identity" != '-' ]]; then
  sign_args+=(--options runtime --timestamp)
  sign_label='Developer ID signed; not notarized'
fi
codesign "${sign_args[@]}" "$app/Contents/MacOS/display-cli"
codesign "${sign_args[@]}" "$app/Contents/MacOS/displaydj"
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$sign_identity" != '-' ]]; then
  signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  if [[ "$signature_details" != *'Authority=Developer ID Application:'* ]]; then
    echo 'DISPLAYDJ_SIGN_IDENTITY did not produce a Developer ID Application signature' >&2
    exit 1
  fi
fi
printf 'Built: %s (v%s, %s)\n' "$app" "$version" "$sign_label"
