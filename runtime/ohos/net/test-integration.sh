#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${OHOS_TEST_DSH_PREFIX:?point to an npm-ci verification tree with the OHOS patches applied}"
: "${OHOS_TEST_BASE_PREFIX:?point to the unchanged npm-ci verification tree}"
fixtures=$(mktemp -d)
trap 'rm -rf -- "$fixtures"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$fixtures/key.pem" -out "$fixtures/cert.pem" \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,DNS:origin.invalid,IP:127.0.0.1' \
  >"$fixtures/openssl.log" 2>&1
export OHOS_NET_TEST_CERT="$fixtures/cert.pem"
export OHOS_NET_TEST_KEY="$fixtures/key.pem"
DSH_GO_OHOS_SIM=1 "${NODE:-node}" --test "$repo/runtime/tests/ohos/net-android-path.test.mjs"
env -u DSH_GO_OHOS_SIM "${NODE:-node}" --import "$repo/runtime/ohos/sim/marker.mjs" --test "$repo/runtime/tests/ohos/net-integration.test.mjs"
simulation=(--jitless --import "$repo/runtime/ohos/sim/marker.mjs")
if [[ -n ${OHOS_SIM_PRELOAD:-} ]]; then
  simulation+=(--import "$OHOS_SIM_PRELOAD" --test-isolation=none)
fi
env -u DSH_GO_OHOS_SIM "${NODE:-node}" "${simulation[@]}" \
  --test "$repo/runtime/tests/ohos/net-integration.test.mjs"
