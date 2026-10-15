#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=debug
case "${1:-}" in
  --release) configuration=release ;;
  '') ;;
  *) echo 'Usage: bash scripts/build-lite-app.sh [--release]' >&2; exit 2 ;;
esac
swift build -c "$configuration" --product DisplayDJLite
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/.build/DisplayDJLite.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DisplayDJLite" "$app/Contents/MacOS/DisplayDJLite"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp LICENSES/DisplayDJ.txt "$app/Contents/Resources/DisplayDJ-LICENSE.txt"
cp LICENSES/VibeDisplay.txt "$app/Contents/Resources/VibeDisplay-LICENSE.txt"
iconset="$PWD/.build/DisplayDJLiteIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PWD/Assets/DisplayDJLiteIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$PWD/Assets/DisplayDJLiteIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/DisplayDJLite.icns"
python3 - "$app" <<'PY'
import pathlib, plistlib, re, sys
app = pathlib.Path(sys.argv[1])
source = pathlib.Path('Sources/DisplayDJLite/LiteConnectionService.swift').read_text()
version = re.search(r'static let version = "([^"]+)"', source).group(1)
identity = re.search(r'static let bundleID = "([^"]+)"', source).group(1)
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(dict(CFBundleExecutable='DisplayDJLite', CFBundleIdentifier=identity,
                      CFBundleName='DisplayDJ Lite', CFBundleDisplayName='DisplayDJ Lite',
                      CFBundleIconFile='DisplayDJLite.icns',
                      CFBundleVersion=version, CFBundleShortVersionString=version,
                      CFBundlePackageType='APPL', LSMinimumSystemVersion='13.0',
                      LSUIElement=True, NSHighResolutionCapable=True), stream)
PY
sign_identity="${DISPLAYDJ_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != '-' ]]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$sign_identity" != '-' ]]; then
  signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  if [[ "$signature_details" != *'Authority=Developer ID Application:'* ]]; then
    echo 'DISPLAYDJ_SIGN_IDENTITY did not produce a Developer ID Application signature' >&2
    exit 1
  fi
fi
printf 'Built Lite: %s (not notarized)\n' "$app"
