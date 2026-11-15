#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dsh-pet-contract.XXXXXX")
trap 'rm -rf "$work"' EXIT
if command -v swiftc >/dev/null 2>&1; then
  compiler=(swiftc)
elif command -v xcrun >/dev/null 2>&1; then
  compiler=(xcrun swiftc)
else
  echo 'SKIP: Swift compiler unavailable; production Swift contract was not executed.' >&2
  exit 77
fi
"${compiler[@]}" -swift-version 5 -parse-as-library \
  "$root/app/ios/Runner/PetOverlay/PetOverlayState.swift" \
  "$root/app/ios/Runner/PetOverlay/PetOverlayPack.swift" \
  "$root/tooling/ios/pet-overlay-tests/contract.swift" -o "$work/contract"
"$work/contract" "$root/app/assets/pets"
