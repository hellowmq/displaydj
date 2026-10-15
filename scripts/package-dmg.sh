#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/package-product.py --format dmg "$@"
