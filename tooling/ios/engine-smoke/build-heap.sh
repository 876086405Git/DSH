#!/usr/bin/env bash
# Builds only the C observer; the prepared framework is supplied to heap-drive.mjs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?output executable}"
SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANG="$(xcrun --sdk iphonesimulator --find clang)"
mkdir -p "$(dirname "$OUT")"
"$CLANG" -std=c11 -target arm64-apple-ios15.0-simulator -isysroot "$SYSROOT" \
  -O2 -pthread "$HERE/heap-smoke.c" -o "$OUT"
