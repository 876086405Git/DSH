#!/usr/bin/env bash
# Builds or verifies the pinned iSH kernel and confined C backend.
# build-ish.sh iphoneos|iphonesimulator|linux OUTPUT_DIR
# build-ish.sh --cache-key SDK     (local inputs only; no download)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/ish/build.py" "$@"
