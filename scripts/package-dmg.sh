#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build-app.sh --release
version="$(.build/DisplayDJ.app/Contents/MacOS/display-cli version --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["version"])')"
arch="$(uname -m)"
output_dir="${DISPLAYDJ_OUTPUT_DIR:-$PWD/outputs}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
image="$output_dir/displaydj-$version-macos-$arch.dmg"
if [[ -e "$image" || -e "$image.sha256" ]]; then
  echo "Package already exists: $image (choose a new DISPLAYDJ_OUTPUT_DIR)" >&2
  exit 1
fi

codesign --verify --deep --strict .build/DisplayDJ.app
hdiutil create -quiet -volname "DisplayDJ $version" \
  -srcfolder .build/DisplayDJ.app -format UDZO "$image"
hdiutil verify -quiet "$image"
(cd "$output_dir" && shasum -a 256 "$(basename "$image")" > "$(basename "$image").sha256")
printf 'Packaged: %s\n' "$image"
