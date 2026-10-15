#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  --preview) args=(--preview --show) ;;
  '') args=() ;;
  *) echo 'Usage: bash scripts/run-lite-app.sh [--preview]' >&2; exit 2 ;;
esac
bash scripts/build-lite-app.sh
# Stop only this workspace's Lite instance; never touch DisplayDJBar or the daemon.
python3 - "$PWD/.build/DisplayDJLite.app/Contents/MacOS/DisplayDJLite" <<'PY'
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
if (( ${#args[@]} )); then
  open -n "$PWD/.build/DisplayDJLite.app" --args "${args[@]}"
else
  open -n "$PWD/.build/DisplayDJLite.app"
fi
