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
set +x  # Signing environment values must never be traced.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../app" && pwd)"
FLUTTER="${FLUTTER_OHOS:-flutter}"
MODE=--release
DISTRIBUTION=store
SIGN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug|--release) MODE="$1"; shift ;;
    --distribution)
      DISTRIBUTION="${2:?--distribution requires debug, device or store}"; SIGN=1; shift 2 ;;
    *) printf 'Usage: build-hap.sh [--debug|--release] [--distribution debug|device|store]\n' >&2; exit 2 ;;
  esac
done
case "$DISTRIBUTION" in
  debug|device|store) ;;
  *) printf 'Unknown distribution\n' >&2; exit 2 ;;
esac
if [[ "$DISTRIBUTION" == device && "$MODE" != --release ]]; then
  printf 'Device distribution requires --release\n' >&2; exit 2
fi
DISTRIBUTION_HELPER="$APP/../tooling/ohos/hap-distribution.py"
SIGN_KEYS=(DSH_OHOS_SIGN_KEYSTORE DSH_OHOS_SIGN_CERTIFICATE DSH_OHOS_SIGN_PROFILE DSH_OHOS_SIGN_KEY_ALIAS
           DSH_OHOS_SIGN_KEY_PASSWORD DSH_OHOS_SIGN_STORE_PASSWORD DSH_OHOS_SIGN_TOOL)
# Keep credentials in this shell; only the signing helper inherits them.
export -n "${SIGN_KEYS[@]}"
signing_python() ( export "${SIGN_KEYS[@]}"; python3 -I -B "$DISTRIBUTION_HELPER" "$@"; )
if [[ "$SIGN" == 1 ]]; then
  signing_python check-signing
fi
NATIVE_LIBS="${DSH_OHOS_NATIVE_LIBS:?Set DSH_OHOS_NATIVE_LIBS to the arm64-v8a directory from build-hap-libs.py}"
: "${DSH_NODE_HEADERS:?Set DSH_NODE_HEADERS to the pinned Node source src directory}"
RUNTIME="${DSH_OHOS_RUNTIME:?Set DSH_OHOS_RUNTIME to the zip from runtime/ohos/package/compose-runtime.py}"
RUNTIME="$(cd "$(dirname "$RUNTIME")" && pwd)/$(basename "$RUNTIME")"
[[ -f "$RUNTIME" ]] || { printf 'Missing runtime zip: %s\n' "$RUNTIME" >&2; exit 1; }
PREBUILT=(libnode.so libdsh_flock.so libdsh_require_builtin.so)
# Optional Python is one complete signed pair; never copy arbitrary extra libraries.
if [[ -f "$NATIVE_LIBS/libdsh_python.so" || -f "$NATIVE_LIBS/libpython3.14.so" ]]; then
  PREBUILT+=(libdsh_python.so libpython3.14.so)
fi
if [[ -f "$NATIVE_LIBS/libdsh_linux.so" ]]; then PREBUILT+=(libdsh_linux.so); fi
if [[ -f "$NATIVE_LIBS/libdsh_workspace_grants.so" ]]; then PREBUILT+=(libdsh_workspace_grants.so); fi
# Image is an explicit optional product library; SDK dependencies remain system libraries.
if [[ -f "$NATIVE_LIBS/libdsh_image_codec.so" ]]; then PREBUILT+=(libdsh_image_codec.so); fi
for lib in "${PREBUILT[@]}"; do
  [[ -f "$NATIVE_LIBS/$lib" ]] || { printf 'Missing native library: %s\n' "$NATIVE_LIBS/$lib" >&2; exit 1; }
done

cd "$APP"
LIBS=ohos/entry/libs/arm64-v8a
RAWFILE=ohos/entry/src/main/resources/rawfile
LOCK="$(mktemp)"
cp pubspec.lock "$LOCK"
MODULE=ohos/entry/src/main/module.json5
MODULE_KEPT="$(mktemp)"
cp "$MODULE" "$MODULE_KEPT"
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
  cp "$MODULE_KEPT" "$MODULE"
  rm -f "$MODULE_KEPT"
  cp "$LOCK" pubspec.lock
  rm -f "$LOCK"
}
trap restore EXIT
python3 -I -B "$DISTRIBUTION_HELPER" permissions --distribution "$DISTRIBUTION" --input "$MODULE_KEPT" --output "$MODULE"
# Signing happens outside hvigor, so neither its project model nor cache gets credentials.
if ! python3 -I - ohos/build-profile.json5 <<'PY_UNSIGNED'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
sys.exit(0 if re.search(r'"signingConfigs"\s*:\s*\[\s*\]', text) else 1)
PY_UNSIGNED
then
  printf 'Use an empty signingConfigs array; supply signing materials through DSH_OHOS_SIGN_* environment variables\n' >&2
  exit 1
fi
UNSIGNED_CANDIDATES=("$APP/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap" "$APP/build/hap/outputs/default/entry-default-unsigned.hap")
if [[ "$SIGN" == 1 ]]; then
  for hap in "${UNSIGNED_CANDIDATES[@]}"; do rm -f "$hap"; done
fi

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
python3 -I -B "$APP/../runtime/ohos/package/linux-assets.py" \
  --runtime-zip "$RAWFILE/dsh-runtime/runtime.zip" --native-directory "$LIBS"
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
  python3 -I -B "$APP/../tooling/ohos/prepare-pasteboard.py" --input-har "$ENGINE_HAR" \
    --verify-har "$PREPARED/out/flutter_embedding_release.har" >/dev/null || {
    printf 'The prepared embedding HAR members do not match the pinned sources\n' >&2
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
  python3 -I - "$APP/../tooling/ohos/embedding-fixes/pasteboard-settlement.json" > "$PREPARED/fix-outputs.tsv" <<'PY_EMBEDDING_FIXES'
import json, sys
for fix in json.load(open(sys.argv[1]))['fixes']:
    target = fix['target']
    assert target.startswith('package/src/main/ets/')
    print(target.removeprefix('package/'), fix['afterSha256'])
PY_EMBEDDING_FIXES
  while read -r file sum; do
    installed="$(find ohos/oh_modules -path "*/@ohos/flutter_ohos/$file")"
    [[ -n "$installed" ]] || { printf 'No installed %s under ohos/oh_modules\n' "$file" >&2; exit 1; }
    while IFS= read -r copy; do
      echo "$sum  $copy" | sha256sum -c --status || {
        printf 'The installed file is not the prepared one: %s\n' "$copy" >&2
        exit 1
      }
    done <<< "$installed"
  done < "$PREPARED/fix-outputs.tsv"
fi

if [[ "$SIGN" == 1 ]]; then
  UNSIGNED=""
  for hap in "${UNSIGNED_CANDIDATES[@]}"; do
    [[ -f "$hap" ]] || continue
    if [[ -n "$UNSIGNED" ]] && ! cmp -s "$UNSIGNED" "$hap"; then
      printf 'Two different unsigned HAP outputs were produced; refusing ambiguous signing input\n' >&2
      exit 1
    fi
    UNSIGNED="$hap"
  done
  [[ -n "$UNSIGNED" ]] || { printf 'No fresh unsigned HAP was produced\n' >&2; exit 1; }
  SIGNED="$APP/build/hap/dsh-go-$DISTRIBUTION-signed.hap"
  signing_python sign --input "$UNSIGNED" --output "$SIGNED"
  printf 'Signed and verified HAP: %s\n' "$SIGNED"
fi
