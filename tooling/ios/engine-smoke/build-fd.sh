#!/usr/bin/env bash
# Builds only the standalone fd observer, using the same simulator target as smoke.c.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?output executable}"
SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANGXX="$(xcrun --sdk iphonesimulator --find clang++)"
mkdir -p "$(dirname "$OUT")"
"$CLANGXX" -std=c++20 -stdlib=libc++ -target arm64-apple-ios15.0-simulator \
  -isysroot "$SYSROOT" -O2 -pthread "$HERE/fd-smoke.cc" -o "$OUT"
