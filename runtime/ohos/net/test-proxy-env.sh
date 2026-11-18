#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
fixtures=$(mktemp -d)
trap 'rm -rf -- "$fixtures"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$fixtures/key.pem" -out "$fixtures/cert.pem" \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  >"$fixtures/openssl.log" 2>&1
export OHOS_NET_TEST_CERT="$fixtures/cert.pem"
export OHOS_NET_TEST_KEY="$fixtures/key.pem"
"${NODE:-node}" --import "$repo/runtime/ohos/sim/marker.mjs" \
  --test "$repo/runtime/tests/ohos/net-proxy-env.test.mjs"
"${NODE:-node}" --jitless --import "$repo/runtime/ohos/sim/preload.mjs" \
  --test --test-isolation=none "$repo/runtime/tests/ohos/net-proxy-env.test.mjs"
