#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh --release
bin_dir="$(swift build -c release --show-bin-path)"
version="$("$bin_dir/display-cli" version --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["version"])')"
arch="$(uname -m)"
mkdir -p outputs
archive="$PWD/outputs/displaydj-$version-macos-$arch.zip"
ditto -c -k --sequesterRsrc --keepParent '.build/DisplayDJ.app' "$archive"
(cd outputs && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Packaged: %s\n' "$archive"
