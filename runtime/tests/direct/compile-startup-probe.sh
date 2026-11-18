#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
KOTLINC="${KOTLINC:-kotlinc}"
OUT="${1:?output jar path required}"
RUNTIME="$REPO/app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime"
mkdir -p "$(dirname "$OUT")"
"$KOTLINC" "$RUNTIME/DshProcess.kt" "$RUNTIME/LogRedactor.kt" "$RUNTIME/CrashClassifier.kt" "$RUNTIME/ProotTempFiles.kt" "$RUNTIME/LaunchDiagnostics.kt" "$RUNTIME/DirectLaunch.kt" "$RUNTIME/L2sMigration.kt" "$RUNTIME/RuntimeProcessOwnership.kt" "$RUNTIME/SpeechGuest.kt" "$RUNTIME/TawcrootLaunch.kt" "$RUNTIME/TawcrootLinks.kt" \
  "$HERE/cleanup-probe/AndroidContext.kt" "$HERE/cleanup-probe/AndroidOs.kt" \
  "$HERE/cleanup-probe/AndroidProcess.kt" "$HERE/cleanup-probe/UnusedPhoneContract.kt" \
  "$HERE/startup-probe/"*.kt -include-runtime -d "$OUT"
