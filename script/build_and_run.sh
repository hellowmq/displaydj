#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-run}"
case "$mode" in run|--verify|--tools|--logs|--debug) ;; *) echo 'Usage: script/build_and_run.sh [--verify|--tools|--logs|--debug]' >&2; exit 2;; esac
# Stop only this checkout's bundled app; preserve any installed copy.
app_binary="$PWD/.build/DisplayDJ.app/Contents/MacOS/DisplayDJBar"
while IFS= read -r app_pid; do
  if [ "$(ps -p "$app_pid" -o comm=)" = "$app_binary" ]; then kill -TERM "$app_pid"; fi
done < <(pgrep -x DisplayDJBar || true)
bash scripts/build-app.sh
case "$mode" in
  --debug) lldb -- "$app_binary" ;;
  --tools) /usr/bin/open -n "$PWD/.build/DisplayDJ.app" --args --display-tools ;;
  --logs) /usr/bin/open -n "$PWD/.build/DisplayDJ.app"; /usr/bin/log stream --info --style compact --predicate 'process == "DisplayDJBar"' ;;
  --verify) /usr/bin/open -n "$PWD/.build/DisplayDJ.app"; sleep 1; pgrep -x DisplayDJBar >/dev/null ;;
  run) /usr/bin/open -n "$PWD/.build/DisplayDJ.app" ;;
esac
