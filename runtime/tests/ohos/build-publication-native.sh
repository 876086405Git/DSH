#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  printf 'Usage: %s NODE_ROOT OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi
node_root=$(cd "$1" && pwd)
output=$(mkdir -p "$2" && cd "$2" && pwd)
root=$(cd "$(dirname "$0")/../../.." && pwd)
ohos_node_version=$(python3 "$root/runtime/ohos/host/generate-node-version.py" --print-version)
[[ $("$node_root/bin/node" --version) == "v$ohos_node_version" ]] || {
  printf 'This Linux fixture requires the Node version in runtime/ohos/node-version.json\n' >&2
  exit 2
}
python3 "$root/runtime/ohos/host/generate-node-version.py" --output "$output/dsh_node_version.h"
[[ $(uname -s) == Linux ]] || { printf 'Linux fixture only\n' >&2; exit 2; }
common=(-std=c++20 -shared -fPIC -fvisibility=hidden -DNAPI_VERSION=8
  -I "$output" -I "$node_root/include/node"
  -I "$root/runtime/tests/ohos/publication-deviceinfo-fixture"
  "$root/runtime/tests/ohos/publication-deviceinfo-fixture/deviceinfo.cc"
  "$root/runtime/ohos/host/publication_binding.cc")
"${CXX:-c++}" "${common[@]}" -DDSH_PUBLICATION_TEST_ADDON -o "$output/publication.node"
"${CXX:-c++}" "${common[@]}" -DDSH_PUBLICATION_TEST_PRELOAD -o "$output/libpublication-test-linked.so"
sha256sum "$node_root/bin/node" "$root/runtime/ohos/node-version.json" "$output/dsh_node_version.h" "$root/runtime/ohos/host/publication_binding.cc" \
  "$root/runtime/tests/ohos/publication-deviceinfo-fixture/deviceinfo.h" \
  "$root/runtime/tests/ohos/publication-deviceinfo-fixture/deviceinfo.cc" \
  "$output/publication.node" "$output/libpublication-test-linked.so" > "$output/SHA256.txt"
printf 'Built Linux test fixtures only; these binaries must not be shipped in an OHOS HAP.\n'
printf 'System version values are explicit test fixtures, not Linux or HarmonyOS measurements.\n'
