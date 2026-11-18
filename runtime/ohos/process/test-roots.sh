#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${OHOS_TEST_PROCESS_PREFIX:?指定含 M4-4a 搜索后置补丁的独立 DSH 前缀}"
: "${OHOS_SIM_PRELOAD:?指定已复核的 O0 sim/preload.mjs}"
node_bin=${NODE:-node}
"$node_bin" -e 'if (process.version !== "v24.22.1") throw new Error("本轮测量固定 Node 24.22.1")'
"$node_bin" "$repo/runtime/ohos/process/build-rg-regex.mjs" "${OHOS_ESBUILD_PREFIX:-$repo/runtime/ohos/node/build-tools}"
tests=(
  "$repo/runtime/tests/ohos/process-roots-lifecycle.test.mjs"
  "$repo/runtime/tests/ohos/process-search-roots.test.mjs"
  "$repo/runtime/tests/ohos/process-concurrency.test.mjs"
)
gate="$repo/runtime/tests/ohos/process-paths-io-gate.mjs"
env -u DSH_GO_OHOS_SIM M4_4_RUNTIME_DIR="$repo/runtime/ohos/process" \
  "$node_bin" --import "$repo/runtime/ohos/sim/marker.mjs" --import "$gate" \
  --test --test-isolation=none "${tests[@]}"
env -u DSH_GO_OHOS_SIM M4_4_RUNTIME_DIR="$repo/runtime/ohos/process" \
  python3 "$repo/runtime/tests/ohos/process-link-fixture.py" \
  --evidence "${OHOS_TEST_ROOTS_LINK_EVIDENCE:-$repo/runtime/ohos/process/build/strict-roots-link-fixture.json}" -- \
  "$node_bin" --jitless --import "$OHOS_SIM_PRELOAD" --import "$gate" \
  --test --test-isolation=none "${tests[@]}"
