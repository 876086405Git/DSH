#!/usr/bin/env bash
# Run the checked Linux OHOS matrix. Device/HMS validation is a separate scope.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 -I -B "$here/run-gates.py" "$@"
