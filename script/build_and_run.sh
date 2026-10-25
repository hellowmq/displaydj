#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-run}"
case "$mode" in run|--verify|--tools|--logs|--debug|--preview) ;; *) echo 'Usage: script/build_and_run.sh [--verify|--tools|--logs|--debug|--preview]' >&2; exit 2;; esac
if (( $# )); then shift; fi
preview_args=()
while (( $# )); do
  if [[ "$mode" != --preview ]]; then echo 'Preview options require --preview' >&2; exit 2; fi
  case "$1" in
    --refresh-delay-ms)
      if ! [[ "${2:-}" =~ ^[0-9]{1,4}$ ]] || (( 10#$2 > 5000 )); then
        echo '--refresh-delay-ms requires an integer from 0 to 5000' >&2; exit 2
      fi
      preview_args+=("$1" "$2"); shift 2 ;;
    *) echo "Unknown preview option: $1" >&2; exit 2 ;;
  esac
done
# Stop only this checkout's bundled app; preserve any installed copy.
app_binary="$PWD/.build/DisplayDJ.app/Contents/MacOS/DisplayDJBar"
if [[ "$mode" == --preview ]]; then
  app_binary="$PWD/.build/DisplayDJ-Preview.app/Contents/MacOS/DisplayDJBar"
fi
while IFS= read -r app_pid; do
  if [ "$(ps -p "$app_pid" -o comm=)" = "$app_binary" ]; then kill -TERM "$app_pid"; fi
done < <(pgrep -x DisplayDJBar || true)
bash scripts/build-app.sh
if [[ "$mode" == --preview ]]; then
  # A separate identity keeps this review scene away from the installed app.
  # Its launcher always supplies the simulation flag, including a Finder launch.
  python3 - <<'PY'
from pathlib import Path
import plistlib
import shutil

source = Path('.build/DisplayDJ.app')
preview = Path('.build/DisplayDJ-Preview.app')
shutil.copytree(source, preview, dirs_exist_ok=True)
info_path = preview / 'Contents/Info.plist'
with info_path.open('rb') as handle:
    info = plistlib.load(handle)
info.update(CFBundleIdentifier='io.github.hellowmq.displaydj.preview',
            CFBundleName='DisplayDJ Preview', CFBundleDisplayName='DisplayDJ Preview',
            CFBundleExecutable='launch-preview')
with info_path.open('wb') as handle:
    plistlib.dump(info, handle)
launcher = preview / 'Contents/MacOS/launch-preview'
launcher.write_text('#!/bin/bash\nexec "$(dirname "$0")/DisplayDJBar" --interaction-preview --two-displays --show "$@"\n')
launcher.chmod(0o755)
PY
  codesign --force --sign - "$app_binary"
  codesign --force --sign - "$PWD/.build/DisplayDJ-Preview.app"
  codesign --verify --deep --strict "$PWD/.build/DisplayDJ-Preview.app"
  if (( ${#preview_args[@]} )); then
    /usr/bin/open -n "$PWD/.build/DisplayDJ-Preview.app" --args "${preview_args[@]}"
  else
    /usr/bin/open -n "$PWD/.build/DisplayDJ-Preview.app"
  fi
  exit 0
fi
case "$mode" in
  --debug) lldb -- "$app_binary" ;;
  --tools) /usr/bin/open -n "$PWD/.build/DisplayDJ.app" --args --display-tools ;;
  --logs) /usr/bin/open -n "$PWD/.build/DisplayDJ.app"; /usr/bin/log stream --info --style compact --predicate 'process == "DisplayDJBar"' ;;
  --verify) /usr/bin/open -n "$PWD/.build/DisplayDJ.app"; sleep 1; pgrep -x DisplayDJBar >/dev/null ;;
  run) /usr/bin/open -n "$PWD/.build/DisplayDJ.app" ;;
esac
