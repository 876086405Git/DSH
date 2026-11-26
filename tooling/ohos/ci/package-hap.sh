#!/usr/bin/env bash
# Build a checked, unsigned OpenHarmony sideload HAP on the Linux runner.
set -euo pipefail

AOT="$(realpath "${1:?Pass the extracted ohos-aot directory}")"
HAP="$(realpath -m "${2:?Pass the output HAP path}")"
: "${OHOS_SDK:?Set OHOS_SDK to the OpenHarmony API 26 SDK directory}"
: "${DSH_OHOS_NATIVE_LIBS:?Set DSH_OHOS_NATIVE_LIBS to the prepared arm64-v8a libraries}"
: "${DSH_NODE_HEADERS:?Set DSH_NODE_HEADERS to the pinned Node headers}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

# Local HAP builds keep this library optional; the official runner must ship it.
IMAGE_CODEC="$DSH_OHOS_NATIVE_LIBS/libdsh_image_codec.so"
if [[ ! -f "$IMAGE_CODEC" || ! -s "$IMAGE_CODEC" || ! -r "$IMAGE_CODEC" ]]; then
  printf '%s\n' "package-hap: required OH arm64 image codec is missing, empty, or unreadable: $IMAGE_CODEC" \
    'Build it using runtime/ohos/image/BUILD.zh.md and put the verified libdsh_image_codec.so in DSH_OHOS_NATIVE_LIBS.' >&2
  exit 1
fi

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dsh-go-ohos.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

COMPOSITION=runtime/ohos/package/composition.json
NPM_VERSION="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["installation"]["npmVersion"])' "$COMPOSITION")"
npm install --prefix "$WORK/npm" --ignore-scripts --no-audit --no-fund "npm@$NPM_VERSION"
NPM="$WORK/npm/node_modules/.bin/npm"
NODE="$(command -v node)"
PREPARED="$WORK/prepared"
python3 -I -B runtime/ohos/package/prepare-inputs.py --target ohos --node "$NODE" \
  --npm "$NPM" --cache "$WORK/npm-cache" --out "$PREPARED"

ESBUILD="$WORK/esbuild"
mkdir "$ESBUILD"
cp runtime/ohos/node/build-tools/package{,-lock}.json "$ESBUILD/"
"$NPM" ci --prefix "$ESBUILD" --ignore-scripts --no-audit --no-fund
PROCESS=runtime/ohos/process
NODE_PATH="$PREPARED/process/node_modules" "$NODE" "$PROCESS/build-rg-regex.mjs" "$ESBUILD"

python3 -I -B runtime/ohos/package/compose-runtime.py --target ohos --node "$NODE" \
  --dsh-prefix "$PREPARED/dsh" --process-prefix "$PREPARED/process" \
  --target-report "$PREPARED/target-report.json" --prepared-inputs "$PREPARED/prepared-inputs.json" \
  --regex-artifact "$PROCESS/build/re2js-unicode.mjs" --esbuild-prefix "$ESBUILD" \
  --runtime-core app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets \
  --imports-report "$WORK/imports.json" --out "$WORK/composed"

bash tooling/ohos/check-arkts.sh --sdk "$OHOS_SDK" --work "$WORK/arkts" --full --hms-stubs \
  --aot "$AOT" --native "$DSH_OHOS_NATIVE_LIBS" --node-headers "$DSH_NODE_HEADERS" \
  --runtime "$WORK/composed/dsh-runtime-rawfile.zip"

cp -- "$WORK"/arkts/check-*/app/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap "$HAP"
