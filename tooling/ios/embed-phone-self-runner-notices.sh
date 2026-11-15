#!/usr/bin/env bash
# The standard build prepares this shared CoreDevice/XCTest library. Direct
# Xcode/config-only callers without generated native inputs retain a clean skip.
set -euo pipefail
[[ "${DSH_PHONE_SELF_RUNNER_ENABLED:-NO}" == YES ]] || exit 0
: "${SRCROOT:?Xcode SRCROOT required}"
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode resource path required}"
SOURCE="$SRCROOT/PhoneSelfRunnerNative"
DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PhoneSelfRunnerNotices"
for name in LICENSE.idevice.txt THIRD_PARTY_CRATES.json NOTICES.txt SOURCE.json; do
  [[ -s "$SOURCE/$name" ]] || { printf 'Missing phone native notice: %s; rerun build-phone-self-runner.sh.\n' "$name" >&2; exit 1; }
done
mkdir -p "$DESTINATION"
for name in LICENSE.idevice.txt THIRD_PARTY_CRATES.json NOTICES.txt SOURCE.json; do
  cp "$SOURCE/$name" "$DESTINATION/$name"
done
