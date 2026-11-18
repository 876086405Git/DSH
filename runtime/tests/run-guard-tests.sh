#!/usr/bin/env bash
# Runs the route-guard regression test against a DSH npm prefix on the build host, without
# assembling a rootfs: boots `dsh web` from <dsh-prefix> with a throwaway HOME/DSH_HOME, the
# route-probe test plugin and (unless --no-bridge) runtime/bridge/dsh-go-bridge, then runs
# runtime/tests/route-guard.mjs. Never touches ~/.dsh.
#
#   runtime/tests/run-guard-tests.sh <dsh-prefix> [--port N] [--no-bridge] [--guard patched|bridge|none]
#                                    [--expect-unguarded]
#
# <dsh-prefix> is an `npm --prefix` tree such as runtime/.work/x86_64/dsh-prefix after
# `rtbuild.py patch-dsh` (build-runtime.sh patches it in place).
set -euo pipefail
HERE="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$(dirname "$HERE")"
PREFIX="$(CDPATH= cd "${1:?usage: run-guard-tests.sh <dsh-prefix> [--port N] [--no-bridge] [--expect-unguarded]}" && pwd)"; shift
PORT=38181 BRIDGE=1 TITLE_TESTS=1 EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --no-bridge) BRIDGE=0; shift ;;
    --expect-unguarded) TITLE_TESTS=0; EXTRA+=(--expect-unguarded); shift ;;
    --guard) [[ "$2" == patched ]] || TITLE_TESTS=0; EXTRA+=(--guard "$2"); shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
NODE="$RUNTIME/.cache/host-node/node-v24.22.1-linux-x64/bin/node"
[[ -x "$NODE" ]] || NODE="$(command -v node)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-guard-test.XXXXXX")"
DSH_PID=""
cleanup() {
  [[ -n "$DSH_PID" ]] && kill -TERM "$DSH_PID" 2>/dev/null && wait "$DSH_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/home/.dsh"
printf -- '- insert:\n    - id: dsh-app-route-probe\n      name: %s\n' "$HERE/route-probe/index.js" > "$TMP/probe.patch.yml"
PATCHES=(--patch "$TMP/probe.patch.yml")
if [[ "$BRIDGE" == 1 ]]; then
  printf -- '- insert:\n    - id: dsh-go-bridge\n      name: %s\n' "$RUNTIME/bridge/dsh-go-bridge/lib/index.js" > "$TMP/bridge.patch.yml"
  if [[ " ${EXTRA[*]} " == *" --guard none "* ]]; then   # bridge without its fallback guard
    printf '      config:\n        guardRoutes: false\n' >> "$TMP/bridge.patch.yml"
  fi
  PATCHES+=(--patch "$TMP/bridge.patch.yml")
fi

LOG="$TMP/dsh-web.log"
: > "$LOG"
env -i PATH="$(dirname "$NODE"):/usr/bin:/bin" HOME="$TMP/home" DSH_HOME="$TMP/home/.dsh" LANG=C.UTF-8 TZ="${TZ:-Asia/Shanghai}" \
  DEEPSEEK_API_KEY=sk-dsh-app-guard-test-not-a-real-key UV_USE_IO_URING=0 \
  "$NODE" "$PREFIX/node_modules/@deepseek-ai/dsh/lib/bin.js" web "${PATCHES[@]}" \
  --host 127.0.0.1 --port "$PORT" --no-open > "$LOG" 2>&1 &
DSH_PID=$!
token=""
for _ in $(seq 1 240); do
  token="$(sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9]*/?token=\([A-Za-z0-9_-]*\).*#\1#p' "$LOG" | head -1)"
  [[ -n "$token" ]] && break
  kill -0 "$DSH_PID" 2>/dev/null || break
  sleep 0.5
done
if [[ -z "$token" ]]; then echo "dsh web did not start:" >&2; tail -40 "$LOG" >&2; exit 1; fi
rc=0
"$NODE" "$HERE/route-guard.mjs" "http://127.0.0.1:$PORT" "$token" "${EXTRA[@]}" || rc=$?
if grep -qiE 'dsh-go-bridge.*(error|fail)|route-probe.*(error|fail)' "$LOG"; then
  echo "plugin errors in dsh web log:" >&2; grep -iE 'dsh-go-bridge|route-probe' "$LOG" | tail -20 >&2; rc=1
fi
if [[ "$rc" == 0 && "$TITLE_TESTS" == 1 ]]; then
  "$NODE" "$HERE/title-cache-regression.mjs" "$PREFIX"
  "$NODE" "$HERE/title-cache-stat-regression.mjs" "$PREFIX"
  "$NODE" "$HERE/title-cache-scale.mjs" "$PREFIX"
  PATH="$(dirname "$NODE"):$PATH" TITLE_CACHE_PORT="$((PORT + 1))" \
    python3 "$HERE/title-cache-live.py" patched "$PREFIX" "$TMP/title-live"
fi
exit $rc
