#!/usr/bin/env bash
# Compiles the engine's native pieces against the prepared NodeMobile.
#
#   tooling/ios/build-engine-native.sh iphoneos|iphonesimulator OUTPUT_DIR [extra compiler flags]
#
# Writes DshNodeHost.framework, DshFlock.framework and DshRequireBuiltin.framework
# to OUTPUT_DIR, unsigned. The iOS-specialized loader opens each framework executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/app/ios/Engine"
SDK="${1:?iphoneos or iphonesimulator}"
OUT="${2:?output directory}"
shift 2
[[ -f "$ENGINE/.ready" ]] || { printf 'Run tooling/ios/prepare-engine.sh first\n' >&2; exit 1; }

MIN_IOS=15.0
case "$SDK" in
  iphoneos) TARGET="arm64-apple-ios$MIN_IOS"; SLICE=ios-arm64 ;;
  iphonesimulator) TARGET="arm64-apple-ios$MIN_IOS-simulator"; SLICE=ios-arm64-simulator ;;
  *) printf 'Unknown SDK: %s\n' "$SDK" >&2; exit 1 ;;
esac
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" --find clang)"
CLANGXX="$(xcrun --sdk "$SDK" --find clang++)"
FRAMEWORKS="$ENGINE/NodeMobile.xcframework/$SLICE"
[[ -d "$FRAMEWORKS/NodeMobile.framework" ]] || { printf 'NodeMobile has no %s slice\n' "$SLICE" >&2; exit 1; }

COMMON=(-target "$TARGET" -isysroot "$SYSROOT" -O2 -g0 -fPIC -fvisibility=hidden "-I$ENGINE/include/node")
LINK=(-dynamiclib "-F$FRAMEWORKS" -framework NodeMobile -Wl,-rpath,@loader_path -Wl,-rpath,@loader_path/..
  -Wl,-rpath,@executable_path/Frameworks)

mkdir -p "$OUT"
rm -f "$OUT/libdsh_flock.so" "$OUT/libdsh_require_builtin.so"
for name in DshFlock DshRequireBuiltin; do
  rm -rf "$OUT/$name.framework"
  mkdir -p "$OUT/$name.framework"
done
HOST_CORE="$ROOT/app/ohos/entry/src/main/cpp"
HOST_RUNTIME="$ROOT/runtime/ohos/host"
FRAMEWORK="$OUT/DshNodeHost.framework"
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK"
cp "$ROOT/runtime/ios/host/worker-preload.cjs" "$FRAMEWORK/worker-preload.cjs"
"$CLANGXX" "${COMMON[@]}" -std=c++20 -stdlib=libc++ -fexceptions -frtti -DNAPI_VERSION=8 -DDSH_IOS_HOST \
  "-I$ENGINE/include" "-I$HOST_CORE" "-I$HOST_RUNTIME" "$@" \
  "$ROOT/runtime/ios/host/node_runner.cc" "$ROOT/runtime/ios/host/ios_host.cc" \
  "$ROOT/runtime/ios/host/phone_binding.cc" "$ROOT/runtime/ios/host/image_binding.cc" \
  "$HOST_RUNTIME/publication_binding.cc" "$HOST_CORE/host_core.cpp" \
  "${LINK[@]}" -framework ImageIO -framework CoreGraphics -framework CoreFoundation \
  -install_name @rpath/DshNodeHost.framework/DshNodeHost \
  -o "$FRAMEWORK/DshNodeHost"
cat >"$FRAMEWORK/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DshNodeHost</string>
  <key>CFBundleIdentifier</key><string>io.github.ccch1mneyyy.dshgo.nodehost</string>
  <key>CFBundleName</key><string>DshNodeHost</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict></plist>
PLIST

"$CLANG" "${COMMON[@]}" -std=c11 -DNAPI_VERSION=8 "$ENGINE/addons/flock/flock.c" \
  "${LINK[@]}" -install_name @rpath/DshFlock.framework/DshFlock -o "$OUT/DshFlock.framework/DshFlock"

# The same units and defines as upstream's binding.gyp for its napi backend
# (runtime/ohos/native/loader/build-loader.py), against the same pinned commit.
LOADER="$ENGINE/addons/require-builtin"
SOURCES=()
while IFS= read -r line; do SOURCES+=("$LOADER/$line"); done < <(
  /usr/bin/python3 -c '
import json, sys
target = json.load(open(sys.argv[1]))["targets"][0]
for name in target["sources"] + target["conditions"][0][2]["sources"]:
    print(name)
' "$LOADER/binding.gyp")
"$CLANGXX" "${COMMON[@]}" -std=c++17 -stdlib=libc++ -fno-exceptions -pthread \
  -DNAPI_VERSION=9 -DNARB_BACKEND=1 -DNARB_PRODUCT=1 -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS \
  -DNODE_GYP_MODULE_NAME=require_builtin "-I$ENGINE/addons/node-addon-api" \
  "${SOURCES[@]}" "${LINK[@]}" -install_name @rpath/DshRequireBuiltin.framework/DshRequireBuiltin -o "$OUT/DshRequireBuiltin.framework/DshRequireBuiltin"

for name in DshFlock DshRequireBuiltin; do
  case "$name" in
    DshFlock) bundle_id=io.github.ccch1mneyyy.dshgo.flock ;;
    DshRequireBuiltin) bundle_id=io.github.ccch1mneyyy.dshgo.requirebuiltin ;;
  esac
  cat >"$OUT/$name.framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict></plist>
PLIST
done
