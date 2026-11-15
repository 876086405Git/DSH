#!/usr/bin/env bash
# Builds the HarmonyOS HAP from app/ohos with oh-flutter.
#
#   FLUTTER_OHOS=/path/to/flutter-ohos/bin/flutter \
#   DSH_OHOS_NATIVE_LIBS=/path/to/hap-libs/arm64-v8a DSH_NODE_HEADERS=/path/to/node-v24.22.1/src \
#   DSH_OHOS_RUNTIME=/path/to/dsh-runtime-rawfile.zip \
#     tooling/ohos/build-hap.sh [--debug]
#
# The OHOS plugin overrides apply only for this run: pubspec_overrides.yaml and
# the lock file it changes are put back on exit, so the Android graph stays as it
# was. The host needs oh-flutter's AOT tools, published for macOS arm64 only so far
# (see app/ohos/README.md), plus hvigor and ohpm from HarmonyOS Command Line Tools.
#
# The Node-side native libraries come from runtime/ohos/native/build-hap-libs.py and are placed only for this run.
# The runtime is one Stored dsh-runtime/runtime.zip, which the app streams from rawfile; it is never expanded here.
# tooling/ohos/patch_framework.py changes a few framework branches in the SDK itself, and leaves them: only ohos takes them.
# A release build uses the embedding from tooling/ohos/prepare-pasteboard.py: it stands in for the SDK's HAR for
# this run, since flutter_tools and flutter-hvigor-plugin both read that one path, and goes back on exit.
# hvigor builds libdsh_host.so itself, against the placed libnode, through entry/src/main/cpp/CMakeLists.txt.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../app" && pwd)"
FLUTTER="${FLUTTER_OHOS:-flutter}"
MODE="${1:---release}"
NATIVE_LIBS="${DSH_OHOS_NATIVE_LIBS:?Set DSH_OHOS_NATIVE_LIBS to the arm64-v8a directory from build-hap-libs.py}"
: "${DSH_NODE_HEADERS:?Set DSH_NODE_HEADERS to the pinned Node source src directory}"
RUNTIME="${DSH_OHOS_RUNTIME:?Set DSH_OHOS_RUNTIME to the zip from runtime/ohos/package/compose-runtime.py}"
RUNTIME="$(cd "$(dirname "$RUNTIME")" && pwd)/$(basename "$RUNTIME")"
[[ -f "$RUNTIME" ]] || { printf 'Missing runtime zip: %s\n' "$RUNTIME" >&2; exit 1; }
PREPARED_HAR_SHA256=759a836691934a209ee39591fd8b0e25da38a77a330cb52d910d98f8b5f3899a
PASTEBOARD_HELPER_SHA256=4f16b6fa39cfc6d668895ce6e01a6faeec250c845feeeac700ba5d3263a84803
PLATFORM_PLUGIN_SHA256=938829683d527ce8e0c4f2f76895122c36b0992633596dc0e7b196890e2882a9
PREBUILT=(libnode.so libdsh_flock.so libdsh_require_builtin.so)
for lib in "${PREBUILT[@]}"; do
  [[ -f "$NATIVE_LIBS/$lib" ]] || { printf 'Missing native library: %s\n' "$NATIVE_LIBS/$lib" >&2; exit 1; }
done

cd "$APP"
LIBS=ohos/entry/libs/arm64-v8a
RAWFILE=ohos/entry/src/main/resources/rawfile
LOCK="$(mktemp)"
cp pubspec.lock "$LOCK"
ENGINE_HAR=""
ENGINE_KEPT=""
PREPARED=""
restore() {
  if [[ -n "$ENGINE_KEPT" ]]; then mv -f "$ENGINE_KEPT" "$ENGINE_HAR"; fi
  if [[ -n "$PREPARED" ]]; then rm -rf "$PREPARED"; fi
  rm -rf pubspec_overrides.yaml ohos/.vendor
  for lib in "${PREBUILT[@]}"; do rm -f "$LIBS/$lib"; done
  rmdir "$LIBS" ohos/entry/libs 2>/dev/null || true
  rm -rf "$RAWFILE/dsh-runtime"
  rmdir "$RAWFILE" 2>/dev/null || true
  cp "$LOCK" pubspec.lock
  rm -f "$LOCK"
}
trap restore EXIT

mkdir -p "$LIBS"
for lib in "${PREBUILT[@]}"; do cp "$NATIVE_LIBS/$lib" "$LIBS/$lib"; done
mkdir -p "$RAWFILE"
python3 -I - "$RUNTIME" "$RAWFILE" <<'PY_RUNTIME_ARCHIVE'
import pathlib, sys, zipfile
transport, rawfile = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(transport) as bundle:
    entries = bundle.infolist()
    if (len(entries) != 1 or entries[0].filename != "dsh-runtime/runtime.zip"
            or entries[0].compress_type != zipfile.ZIP_STORED
            or entries[0].flag_bits & 9):
        sys.exit(f"{transport} must contain one unencrypted Stored dsh-runtime/runtime.zip")
    bundle.extract(entries[0], rawfile)
PY_RUNTIME_ARCHIVE
FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v "$FLUTTER")")")")"
python3 -I -B "$APP/../tooling/ohos/patch_framework.py" "$FLUTTER_ROOT"
if [[ "$MODE" == --release ]]; then
  ENGINE_HAR="$FLUTTER_ROOT/bin/cache/artifacts/engine/ohos-arm64-release/flutter_embedding_release.har"
  [[ -f "$ENGINE_HAR" ]] || "$FLUTTER" precache --ohos
  PREPARED="$(mktemp -d)"
  python3 -I -B "$APP/../tooling/ohos/prepare-pasteboard.py" --input-har "$ENGINE_HAR" --output "$PREPARED/out" >/dev/null || {
    printf '%s is not the pinned release embedding; run "flutter precache --ohos --force" if an interrupted build left it replaced\n' "$ENGINE_HAR" >&2
    exit 1
  }
  echo "$PREPARED_HAR_SHA256  $PREPARED/out/flutter_embedding_release.har" | sha256sum -c --status || {
    printf 'The prepared embedding HAR is not %s\n' "$PREPARED_HAR_SHA256" >&2
    exit 1
  }
  ENGINE_KEPT="$ENGINE_HAR.dsh-upstream"
  mv "$ENGINE_HAR" "$ENGINE_KEPT"
  cp "$PREPARED/out/flutter_embedding_release.har" "$ENGINE_HAR"
  # ohpm keeps a file dependency by path and version, so an older install would hide the swap.
  rm -rf ohos/oh_modules ohos/entry/oh_modules ohos/oh-package-lock.json5
else
  printf 'build-hap: %s has no pinned fixes, paste and haptics stay upstream\n' "$MODE" >&2
fi
export DSH_NODE_HEADERS
cp ohos/pubspec_overrides.ohos.yaml pubspec_overrides.yaml
"$FLUTTER" pub get
python3 "$APP/../tooling/ohos/vendor_platform_switches.py"
python3 -I -B "$APP/../tooling/ohos/prepare-forks.py" \
  --package-config "$APP/.dart_tool/package_config.json" \
  --output "$APP/ohos/.vendor/forks" --overrides "$APP/pubspec_overrides.yaml"
"$FLUTTER" pub get
python3 -I -B "$APP/../tooling/ohos/prepare-forks.py" \
  --verify-package-config "$APP/.dart_tool/package_config.json" --output "$APP/ohos/.vendor/forks"
# No icon tree shaking: oh-flutter's const_finder fails on its own Dart ("Invalid SDK hash").
# ENABLE_FLEX_OVERFLOW: oh-flutter's release-only strategy shrinks the whole app's
# device pixel ratio when a Column overflows. Android clips the overflow and carries on.
"$FLUTTER" build hap "$MODE" --target-platform ohos-arm64 --no-tree-shake-icons --dart-define=ENABLE_FLEX_OVERFLOW=false
python3 -I -B "$APP/../tooling/ohos/prepare-forks.py" \
  --verify-package-config "$APP/.dart_tool/package_config.json" --output "$APP/ohos/.vendor/forks" --after-build
python3 -I -B "$APP/../tooling/ohos/prepare-forks.py" --verify-installed "$APP/ohos"
if [[ "$MODE" == --release ]]; then
  # What ohpm installed is what hvigor compiled.
  for pinned in "util/PasteboardUtils.ets $PASTEBOARD_HELPER_SHA256" "plugin/PlatformPlugin.ets $PLATFORM_PLUGIN_SHA256"; do
    read -r file sum <<< "$pinned"
    installed="$(find ohos/oh_modules -path "*/@ohos/flutter_ohos/src/main/ets/$file")"
    [[ -n "$installed" ]] || { printf 'No installed %s under ohos/oh_modules\n' "$file" >&2; exit 1; }
    while IFS= read -r copy; do
      echo "$sum  $copy" | sha256sum -c --status || {
        printf 'The installed file is not the prepared one: %s\n' "$copy" >&2
        exit 1
      }
    done <<< "$installed"
  done
fi
