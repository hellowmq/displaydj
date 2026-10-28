#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_root="$(mktemp -d /tmp/displaydj-next-tests.XXXXXX)"
mkdir -p "$test_root/home" "$test_root/tmp" "$test_root/full" "$test_root/lite"
export CFFIXED_USER_HOME="$test_root/home"
export DISPLAYDJ_HOME="$test_root/full"
export DISPLAYDJ_LITE_HOME="$test_root/lite"
export TMPDIR="$test_root/tmp/"
printf 'Isolated test data: %s\n' "$test_root"
swift test "$@"
