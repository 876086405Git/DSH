#!/usr/bin/env bash
# Builds the N-API owner separately from the iSH C kernel.
# build-guest-addon.sh iphoneos|iphonesimulator OUTPUT_DIR
# Produces unsigned DshGuestBridge.framework beside DshGuest.framework.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="${1:?iphoneos or iphonesimulator}"
OUT="${2:?output directory}"
[[ $# == 2 ]] || { printf 'usage: build-guest-addon.sh SDK OUTPUT_DIR\n' >&2; exit 2; }
case "$SDK" in
  iphoneos) TARGET=arm64-apple-ios15.0; SLICE=ios-arm64; PLATFORM=iPhoneOS ;;
  iphonesimulator) TARGET=arm64-apple-ios15.0-simulator; SLICE=ios-arm64-simulator; PLATFORM=iPhoneSimulator ;;
  *) printf 'Unsupported SDK: %s\n' "$SDK" >&2; exit 2 ;;
esac
ENGINE="$ROOT/app/ios/Engine"
NATIVE="$ROOT/runtime/ios/guest/native"
NODE="$ENGINE/NodeMobile.xcframework/$SLICE"
[[ -f "$NODE/NodeMobile.framework/NodeMobile" && -f "$ENGINE/include/node/node_api.h" ]] || {
  printf 'Run tooling/ios/prepare-engine.sh first (matching NodeMobile SDK slice required)\n' >&2
  exit 1
}
# This verifies the kernel receipt, sources and SDK before linking the owner.
# build-ish does not call this script: callers explicitly build both products.
"$ROOT/tooling/ios/build-ish.sh" "$SDK" "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
FRAMEWORK="$OUT/DshGuestBridge.framework"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANGXX="$(xcrun --sdk "$SDK" --find clang++)"
WORK="$(mktemp -d "$OUT/.guest-addon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/DshGuestBridge.framework"
"$CLANGXX" -target "$TARGET" -isysroot "$SYSROOT" -std=c++20 -stdlib=libc++ \
  -O2 -g0 -fPIC -fvisibility=hidden -fexceptions -frtti -DNAPI_VERSION=8 -DNODE_GYP_MODULE_NAME=dsh_guest_bridge \
  -I"$ENGINE/include/node" -I"$NATIVE" "$NATIVE/guest_addon.cc" \
  -dynamiclib -F"$NODE" -framework NodeMobile -F"$OUT" -framework DshGuest \
  -Wl,-rpath,@loader_path/.. -Wl,-rpath,@executable_path/Frameworks \
  -install_name @rpath/DshGuestBridge.framework/DshGuestBridge \
  -o "$WORK/DshGuestBridge.framework/DshGuestBridge"
python3 - "$WORK/DshGuestBridge.framework/Info.plist" "$PLATFORM" <<'PY'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(dict(
    CFBundleExecutable='DshGuestBridge',
    CFBundleIdentifier='io.github.ccch1mneyyy.dshgo.guestbridge',
    CFBundleName='DshGuestBridge', CFBundlePackageType='FMWK',
    CFBundleShortVersionString='1.0', CFBundleVersion='1',
    MinimumOSVersion='15.0', CFBundleSupportedPlatforms=[sys.argv[2]])))
PY
rm -rf "$FRAMEWORK"
mv "$WORK/DshGuestBridge.framework" "$FRAMEWORK"
printf 'Built unsigned %s\n' "$FRAMEWORK"
