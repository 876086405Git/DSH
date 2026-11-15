#!/usr/bin/env bash
# Prepares what the app needs to run the engine on the phone, in app/ios/Engine/
# (not in git): the pinned NodeMobile, the runtime archive composed by runtime/ohos,
# and the sources of the two native addons. Then the Xcode build (or
# tooling/ios/build-engine-native.sh) can compile the rest.
#
#   tooling/ios/prepare-engine.sh            # needs python3 >= 3.11, curl, and network
#
# Without this the app still builds and only connects to remote hosts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/app/ios/Engine"
WORK="${DSH_IOS_ENGINE_WORK:-$HOME/Library/Caches/dsh-ios-engine}"

NODE_VERSION=24.22.1
NODE_MOBILE_URL=https://github.com/fogtape/nodejs-mobile/releases/download/v24.22.1-0/nodejs-mobile-ios-24.22.1-0.zip
NODE_MOBILE_SHA256=3fa1b8fb0720768b01c2e0dae3a17e788476e8c1613a1d9a54e206793b45326e
ADDON_COMMIT=a58d3599a2e551d7d706d1ff796c9fd4bbaff63c
ADDON_URL="https://codeload.github.com/deepseek-ai/dsh-node-addon-require-builtin/tar.gz/$ADDON_COMMIT"
ADDON_SHA256=286616f15e4f12013988e45ad27a69b4968a9f059c8bd351e412505230577948

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) NODE_DIST=node-v$NODE_VERSION-darwin-arm64; NODE_SHA256=${DSH_IOS_NODE_SHA256:-} ;;
  Darwin-x86_64) NODE_DIST=node-v$NODE_VERSION-darwin-x64; NODE_SHA256=${DSH_IOS_NODE_SHA256:-} ;;
  Linux-x86_64) NODE_DIST=node-v$NODE_VERSION-linux-x64; NODE_SHA256=${DSH_IOS_NODE_SHA256:-} ;;
  *) printf 'Unsupported build host: %s\n' "$(uname -sm)" >&2; exit 1 ;;
esac

PYTHON="${PYTHON:-python3}"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || {
  printf 'prepare-engine needs python3 >= 3.11; set PYTHON to one\n' >&2
  exit 1
}
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() { # url sha256 file
  if [[ ! -f "$3" || "$(sha256 "$3")" != "$2" ]]; then
    curl -fsSL --retry 3 -o "$3.partial" "$1"
    [[ "$(sha256 "$3.partial")" == "$2" ]] || {
      printf 'Checksum mismatch for %s\n' "$1" >&2
      exit 1
    }
    mv "$3.partial" "$3"
  fi
}

mkdir -p "$WORK"
# prepare-inputs.py compares paths lexically, so a ".." here would look inside the repository.
WORK="$(cd "$WORK" && pwd -P)"
STEP="$(mktemp -d "$WORK/run.XXXXXX")"
trap 'rm -rf "$STEP"' EXIT

# The host Node only composes the archive; nothing of it reaches the phone.
if [[ ! -x "$WORK/$NODE_DIST/bin/node" ]]; then
  curl -fsSL --retry 3 -o "$STEP/SHASUMS256.txt" "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"
  expected="$(awk -v name="$NODE_DIST.tar.gz" '$2 == name { print $1 }' "$STEP/SHASUMS256.txt")"
  [[ -n "$expected" && ( -z "$NODE_SHA256" || "$expected" == "$NODE_SHA256" ) ]] || {
    printf 'No checksum for %s\n' "$NODE_DIST" >&2
    exit 1
  }
  fetch "https://nodejs.org/dist/v$NODE_VERSION/$NODE_DIST.tar.gz" "$expected" "$WORK/$NODE_DIST.tar.gz"
  tar xzf "$WORK/$NODE_DIST.tar.gz" -C "$WORK"
fi
NODE="$WORK/$NODE_DIST/bin/node"
NPM="$WORK/$NODE_DIST/bin/npm"
export PATH="$WORK/$NODE_DIST/bin:$PATH"
# The composition pins its own npm, which isn't the one this Node ships with.
NPM_VERSION="$("$PYTHON" -c 'import json, sys; print(json.load(open(sys.argv[1]))["installation"]["npmVersion"])' \
  "$ROOT/runtime/ohos/package/composition.json")"
if [[ "$("$NPM" --version)" != "$NPM_VERSION" ]]; then
  "$NPM" install --prefix "$WORK/npm-$NPM_VERSION" --no-audit --no-fund "npm@$NPM_VERSION" >/dev/null
  NPM="$WORK/npm-$NPM_VERSION/node_modules/.bin/npm"
fi

fetch "$NODE_MOBILE_URL" "$NODE_MOBILE_SHA256" "$WORK/nodemobile.zip"
fetch "$ADDON_URL" "$ADDON_SHA256" "$WORK/require-builtin.tar.gz"

# Input preparation refuses an existing directory and a path inside the repository.
"$PYTHON" -I -B "$ROOT/runtime/ohos/package/prepare-inputs.py" --target ohos \
  --node "$NODE" --npm "$NPM" --cache "$WORK/npm" --out "$STEP/inputs" >"$STEP/inputs.json" || {
  cat "$STEP"/inputs/*.stderr >&2 2>/dev/null || true
  exit 1
}

TOOLS="$STEP/build-tools"
mkdir -p "$TOOLS"
cp "$ROOT/runtime/ohos/node/build-tools/package.json" "$ROOT/runtime/ohos/node/build-tools/package-lock.json" "$TOOLS/"
(cd "$TOOLS" && "$NPM" ci --no-audit --no-fund --cache "$WORK/npm" >/dev/null)

# build-rg-regex resolves re2js next to itself and writes under its own build/, both gitignored.
PROCESS="$ROOT/runtime/ohos/process"
LINKED=""
if [[ ! -e "$PROCESS/node_modules" ]]; then
  ln -s "$STEP/inputs/process/node_modules" "$PROCESS/node_modules"
  LINKED="$PROCESS/node_modules"
fi
cleanup() {
  [[ -n "$LINKED" ]] && rm -f "$LINKED"
  rm -rf "$STEP"
}
trap cleanup EXIT
"$NODE" "$PROCESS/build-rg-regex.mjs" "$TOOLS" >/dev/null
REGEX="$(find "$PROCESS/build" -name 're2js-unicode.mjs' | head -1)"

"$PYTHON" -I -B "$ROOT/runtime/ohos/package/compose-runtime.py" --target ohos \
  --dsh-prefix "$STEP/inputs/dsh" --process-prefix "$STEP/inputs/process" \
  --target-report "$STEP/inputs/target-report.json" --prepared-inputs "$STEP/inputs/prepared-inputs.json" \
  --regex-artifact "$REGEX" --esbuild-prefix "$TOOLS" --imports-report "$STEP/imports.json" \
  --node "$NODE" --runtime-core "$ROOT/app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets" \
  --out "$STEP/composed" --keep-expanded
"$PYTHON" -I -B "$ROOT/tooling/ios/specialize-runtime.py" \
  --expanded "$STEP/composed/expanded/dsh-runtime" --out "$STEP/ios-composed"
ARCHIVE="$STEP/ios-composed/runtime.zip"
[[ -f "$ARCHIVE" ]] || { printf 'Composition did not produce runtime.zip\n' >&2; exit 1; }

STAGE="$STEP/Engine"
mkdir -p "$STAGE/addons/flock" "$STAGE/addons/require-builtin"
cp "$ARCHIVE" "$STAGE/runtime.zip"
(cd "$STAGE" && unzip -q "$WORK/nodemobile.zip" 'NodeMobile.xcframework/*' 'include/*')
FLOCK="$STEP/inputs/dsh/node_modules/@deepseek-ai/node-addon-system"
cp "$FLOCK/src/flock.c" "$STAGE/addons/flock/"
tar xzf "$WORK/require-builtin.tar.gz" --strip-components=3 -C "$STAGE/addons/require-builtin" \
  "dsh-node-addon-require-builtin-$ADDON_COMMIT/packages/native"
# Build headers only, and an optional peer in the locks, so the install above leaves them out.
API="$STEP/node-addon-api"
mkdir -p "$API"
(cd "$API" && "$NPM" pack --silent --cache "$WORK/npm" node-addon-api@8.9.2 >/dev/null && tar xzf node-addon-api-8.9.2.tgz --strip-components=1)
"$PYTHON" -I -B -c '
import hashlib, json, sys
pins = json.load(open(sys.argv[1]))["nodeAddonApi"]["files"]
for name, expected in pins.items():
    if hashlib.sha256(open(sys.argv[2] + "/" + name, "rb").read()).hexdigest() != expected:
        sys.exit("node-addon-api differs from its pin: " + name)
' "$ROOT/runtime/ohos/native/loader/source-pins.json" "$API"
mkdir -p "$STAGE/addons/node-addon-api"
cp "$API"/*.h "$STAGE/addons/node-addon-api/"
"$PYTHON" -I -B "$ROOT/runtime/ohos/host/generate-node-version.py" --output "$STAGE/include/dsh_node_version.h"
touch "$STAGE/.ready"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$STAGE" "$OUT"
printf 'Engine prepared in %s\n' "$OUT"
