#!/bin/sh
# Xcode build phase: puts the engine into the app when tooling/ios/prepare-engine.sh
# has run. The engine isn't linked at launch: the app dlopens it on first start, so
# someone who only uses remote hosts doesn't pay for 90 MB of Node.
set -eu

ROOT="$(cd "$SRCROOT/../.." && pwd)"
ENGINE="$ROOT/app/ios/Engine"
if [ ! -f "$ENGINE/.ready" ]; then
  echo "note: app/ios/Engine isn't prepared; this build connects to remote hosts only."
  exit 0
fi
# A stale prepared runtime would still load loose .so names after native rebuild.
# Reject it before compiling or copying anything; prepare remains an explicit step.
python3 - "$ENGINE/runtime.zip" <<'PYZIP'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        name = 'files/node_modules/@dsh-go/ohos-native/index.cjs'
        if archive.namelist().count(name) != 1:
            raise ValueError('loader member must be unique')
        text = archive.read(name).decode('utf-8')
        expected = ("  flock: 'DshFlock.framework/DshFlock',",
                    "  'require-builtin': 'DshRequireBuiltin.framework/DshRequireBuiltin',")
        if any(text.count(mapping) != 1 for mapping in expected) or any(
            old in text for old in ('libdsh_flock.so', 'libdsh_require_builtin.so')
        ):
            raise ValueError('addon layout differs')
except (OSError, ValueError, KeyError, zipfile.BadZipFile):
    sys.exit('error: Prepared iOS runtime has an incompatible addon layout; rerun tooling/ios/prepare-engine.sh before building.')
PYZIP

case "$PLATFORM_NAME" in
  iphoneos) SLICE=ios-arm64 ;;
  iphonesimulator) SLICE=ios-arm64-simulator ;;
  *) echo "error: no engine for $PLATFORM_NAME"; exit 1 ;;
esac

BUILT="$ENGINE/build/$PLATFORM_NAME"
STAMP="$BUILT/.inputs"
INPUTS="$(cat "$ROOT/runtime/ios/host/"* "$ROOT/runtime/ohos/host/publication_binding.cc" \
  "$ROOT/app/ohos/entry/src/main/cpp/host_core.cpp" "$ROOT/app/ohos/entry/src/main/cpp/host_core.h" \
  "$ROOT/tooling/ios/build-engine-native.sh" "$ROOT/tooling/ios/embed-engine.sh" | shasum -a 256)"
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$INPUTS" ] ||
   [ ! -f "$BUILT/DshFlock.framework/DshFlock" ] ||
   [ ! -f "$BUILT/DshRequireBuiltin.framework/DshRequireBuiltin" ]; then
  # Xcode's environment selects its own SDK and target, which would override these.
  env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    /bin/bash "$ROOT/tooling/ios/build-engine-native.sh" "$PLATFORM_NAME" "$BUILT"
  printf '%s' "$INPUTS" >"$STAMP"
fi

GUEST_BUILT="$BUILT/guest"
# The guest has separate source/toolchain inputs and checks its own cache. It is
# bundled, but no kernel starts until the user installs Linux and runs a guest job.
env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
  /bin/bash "$ROOT/tooling/ios/build-guest-addon.sh" "$PLATFORM_NAME" "$GUEST_BUILT"

FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$FRAMEWORKS" "$RESOURCES/dsh-runtime"
rm -rf "$FRAMEWORKS/NodeMobile.framework" "$FRAMEWORKS/DshNodeHost.framework" \
  "$FRAMEWORKS/DshFlock.framework" "$FRAMEWORKS/DshRequireBuiltin.framework" \
  "$FRAMEWORKS/DshGuest.framework" "$FRAMEWORKS/DshGuestBridge.framework"
rm -f "$FRAMEWORKS/libdsh_flock.so" "$FRAMEWORKS/libdsh_require_builtin.so"
cp -R "$ENGINE/NodeMobile.xcframework/$SLICE/NodeMobile.framework" "$FRAMEWORKS/"
rm -rf "$FRAMEWORKS/NodeMobile.framework/Headers" "$FRAMEWORKS/NodeMobile.framework/Modules" \
  "$FRAMEWORKS/NodeMobile.framework/_CodeSignature"
cp -R "$BUILT/DshNodeHost.framework" "$FRAMEWORKS/"
cp -R "$BUILT/DshFlock.framework" "$BUILT/DshRequireBuiltin.framework" "$FRAMEWORKS/"
cp -R "$GUEST_BUILT/DshGuest.framework" "$GUEST_BUILT/DshGuestBridge.framework" "$FRAMEWORKS/"
cp "$ENGINE/runtime.zip" "$RESOURCES/dsh-runtime/runtime.zip"
# The phone tools' backend is iOS's own, so it isn't in the archive runtime/ohos composes.
mkdir -p "$RESOURCES/dsh-runtime/phone"
for file in actions.mjs bridge.mjs plugin.mjs descriptions.mjs catalog.json; do
  cp "$ROOT/runtime/ios/phone/$file" "$RESOURCES/dsh-runtime/phone/"
done
if [ -d "$ROOT/runtime/ios/browser" ]; then
  mkdir -p "$RESOURCES/dsh-runtime/browser"
  for file in actions.mjs catalog.json agent.js; do
    cp "$ROOT/runtime/ios/browser/$file" "$RESOURCES/dsh-runtime/browser/"
  done
fi
if [ -d "$ROOT/runtime/ios/system" ]; then
  mkdir -p "$RESOURCES/dsh-runtime/system"
  for file in actions.mjs results.mjs catalog.json; do
    cp "$ROOT/runtime/ios/system/$file" "$RESOURCES/dsh-runtime/system/"
  done
fi

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  exit 0
fi
for item in NodeMobile.framework DshNodeHost.framework DshFlock.framework DshRequireBuiltin.framework DshGuest.framework DshGuestBridge.framework; do
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} \
    --preserve-metadata=identifier,entitlements "$FRAMEWORKS/$item"
done
