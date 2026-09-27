#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh --release
bin_dir="$(swift build -c release --show-bin-path)"
version="$("$bin_dir/display-cli" version --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["version"])')"
arch="$(uname -m)"
output_dir="${DISPLAYDJ_OUTPUT_DIR:-$PWD/outputs}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
archive="$output_dir/displaydj-$version-macos-$arch.zip"
if [[ -e "$archive" || -e "$archive.sha256" ]]; then
  echo "Package already exists: $archive (choose a new DISPLAYDJ_OUTPUT_DIR)" >&2
  exit 1
fi
ditto -c -k --sequesterRsrc --keepParent '.build/DisplayDJ.app' "$archive"
(cd "$output_dir" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Packaged: %s\n' "$archive"
