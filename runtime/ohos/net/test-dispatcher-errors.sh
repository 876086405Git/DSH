#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${OHOS_TEST_DSH_PREFIX:?point to the separately patched M3-5 DSH prefix}"
tests=("$repo/runtime/tests/ohos/net-headers.test.mjs" "$repo/runtime/tests/ohos/net-policy-closed.test.mjs")
"${NODE:-node}" --import "$repo/runtime/ohos/sim/marker.mjs" --test "${tests[@]}"
"${NODE:-node}" --jitless --import "$repo/runtime/ohos/sim/preload.mjs" \
  --test --test-isolation=none "${tests[@]}"
