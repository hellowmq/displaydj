#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preview_args=()
case "${1:-}" in
  --preview) args=(--preview --show); shift ;;
  '') args=() ;;
  *) echo 'Usage: bash scripts/run-lite-app.sh [--preview]' >&2; exit 2 ;;
esac
while (( $# )); do
  case "$1" in
    --appearance)
      case "${2:-}" in light|dark|system) ;; *) echo '--appearance requires light, dark or system' >&2; exit 2 ;; esac
      preview_args+=("$1" "$2"); shift 2 ;;
    --failure)
      case "${2:-}" in none|read|write) ;; *) echo '--failure requires none, read or write' >&2; exit 2 ;; esac
      preview_args+=("$1" "$2"); shift 2 ;;
    --refresh-delay-ms)
      if ! [[ "${2:-}" =~ ^[0-9]{1,4}$ ]] || (( 10#$2 > 5000 )); then
        echo '--refresh-delay-ms requires an integer from 0 to 5000' >&2; exit 2
      fi
      preview_args+=("$1" "$2"); shift 2 ;;
    --all-scenarios) preview_args+=("$1"); shift ;;
    *) echo "Unknown preview option: $1" >&2; exit 2 ;;
  esac
done
app_path="$PWD/.build/DisplayDJLite.app"
if (( ${#args[@]} )); then app_path="$PWD/.build/DisplayDJLite-Preview.app"; fi
# Stop only this workspace's Lite instance; never touch DisplayDJBar or the daemon.
python3 - "$app_path/Contents/MacOS/DisplayDJLite" <<'PY'
import os, signal, subprocess, sys, time
path = sys.argv[1]
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) != 2 or fields[1] != path:
        continue
    pid = int(fields[0])
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if subprocess.run(['kill', '-0', str(pid)], stderr=subprocess.DEVNULL).returncode:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('Old Lite instance did not exit')
PY
source_app="$app_path"
if (( ${#args[@]} )); then source_app="$PWD/.build/lite-preview-source/DisplayDJLite.app"; fi
DISPLAYDJ_LITE_APP_PATH="$source_app" bash scripts/build-lite-app.sh
if (( ${#args[@]} )); then
  python3 - "$source_app" "$app_path" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
app = Path(sys.argv[2])
shutil.copytree(Path(sys.argv[1]), app, dirs_exist_ok=True)
path = app / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info.update(CFBundleIdentifier='io.github.hellowmq.displaydj.lite.preview',
            CFBundleName='DisplayDJ Lite Preview', CFBundleDisplayName='DisplayDJ Lite Preview',
            CFBundleExecutable='launch-preview')
path.write_bytes(plistlib.dumps(info))
launcher = app / 'Contents/MacOS/launch-preview'
launcher.write_text('#!/bin/bash\nexec "$(dirname "$0")/DisplayDJLite" --preview --show "$@"\n')
launcher.chmod(0o755)
PY
  codesign --force --sign - "$app_path/Contents/MacOS/DisplayDJLite"
  codesign --force --sign - "$app_path"
  codesign --verify --deep --strict "$app_path"
  if (( ${#preview_args[@]} )); then open -n "$app_path" --args "${preview_args[@]}"
  else open -n "$app_path"; fi
else
  open -n "$app_path"
fi
