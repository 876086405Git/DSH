#!/usr/bin/env bash
set -euo pipefail
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DSH_OHOS_NODE:-node}" --jitless --import "$SIM_DIR/preload.mjs" "$@"
