#!/usr/bin/env bash
# Smoke-tests a built x86_64 rootfs on an x86_64 Linux host with bubblewrap (no proot: the
# Termux proot is a bionic binary). Runs the guest half of manifest.launch.argv (from
# `/usr/bin/env -i` on) exactly as the app would, then checks: pnpm and its registry plus a
# real `dsh plugin` add/remove, token line, auth exchange, static health URL, graceful SIGTERM
# via the pid file, an offline start, and the route guard patch plus dsh-go-bridge
# (runtime/tests/route-guard.mjs against every registered route), and the native plugin protocol
# end to end (runtime/tests/native-bridge.mjs --shipped) and its v1.2 capabilities
# (runtime/tests/native-capabilities-live.mjs). bwrap has real hard links, so
# pnpm under proot's --link2symlink is not covered here.
#
#   runtime/test-host.sh [port]                  # RUNTIME_OUT=/path tests a staged build
#   NETWORK=0 runtime/test-host.sh               # skip the sections that need the internet
#   DIRECT_PROOT=/path/to/pinned-source-proot KOTLINC=kotlinc runtime/test-host.sh
#   DIRECT_ONLY=1 DIRECT_ROOTFS=/disposable/rootfs DIRECT_MANIFEST=/fixture/manifest.json \
#     DIRECT_PROOT=/path/to/pinned-source-proot KOTLINC=kotlinc runtime/test-host.sh
set -euo pipefail
HERE="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABI=x86_64
PORT="${1:-38080}"
NETWORK="${NETWORK:-1}"
ROOT="$HERE/.work/$ABI/verify-rootfs"
MANIFEST="${RUNTIME_OUT:-$HERE/out}/$ABI/assets/runtime/manifest.json"
if [[ "${DIRECT_ONLY:-0}" == 1 ]]; then
  exec bash "$HERE/tests/direct/run-tests.sh" "${DIRECT_ROOTFS:?DIRECT_ROOTFS required}" \
    "${DIRECT_MANIFEST:-$MANIFEST}" "${DIRECT_PROOT:?DIRECT_PROOT required}" \
    "${DIRECT_OUT:-$HERE/.work/$ABI/direct-evidence}" "$PORT"
fi
command -v bwrap >/dev/null || { echo "bwrap required" >&2; exit 1; }
[[ "$(uname -m)" == x86_64 ]] || { echo "x86_64 host required" >&2; exit 1; }

archive_names="$(python3 -I - "$MANIFEST" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
schema = manifest.get("schema", 1)
if schema == 1:
    print(manifest["rootfs"])
elif schema == 2:
    for layer in ("base", "engine"):
        print(manifest["layers"][layer]["asset"])
else:
    sys.exit("unsupported runtime manifest schema: %s" % schema)
PY
)"
mapfile -t archives <<< "$archive_names"
rm -rf "$ROOT"; mkdir -p "$ROOT"
for archive in "${archives[@]}"; do
  tar -xf "$(dirname "$MANIFEST")/$archive" -C "$ROOT"
done

mapfile -t GUEST < <(python3 -I - "$MANIFEST" "$PORT" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); argv = m["launch"]["argv"]
tail = argv[argv.index("/usr/bin/env"):]
for a in tail:
    if a == "{GUEST_ENV}":
        print("DEEPSEEK_API_KEY=sk-dsh-app-smoke-test-not-a-real-key"); print("TZ=Asia/Shanghai")
        continue
    print(a.replace("{PORT}", sys.argv[2]))
PY
)

run() {  # run [extra bwrap args...] -- argv...
  local -a extra=()
  while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done; shift
  bwrap --bind "$ROOT" / --dev /dev --proc /proc --bind "$ROOT/var/lib/dsh-app/shm" /dev/shm \
    --unshare-user --uid 0 --gid 0 --unshare-ipc --unshare-uts --die-with-parent --chdir /root \
    "${extra[@]}" "$@"
}

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0
trap 'kill $(jobs -pr) 2>/dev/null || true; wait' EXIT

echo "== versions"
run -- "${GUEST[@]:0:${#GUEST[@]}-3}" /bin/bash -c 'set -eo pipefail; node --version; npm --version; dsh --version 2>&1 | sed -n "1,3p"; head -2 /etc/os-release' || fail versions

if [[ "$NETWORK" == 1 ]]; then
echo "== python / pip / venv / git / certificates / dpkg consistency (network)"
run --share-net -- "${GUEST[@]:0:${#GUEST[@]}-3}" /bin/bash -c '
  set -eo pipefail
  python3 --version; pip --version | cut -d" " -f1-2; git --version
  printf "print(sum(range(10)))\n" > /tmp/hello.py
  python3 /tmp/hello.py
  python3 -c "import ssl, urllib.request; print(\"https via python:\", urllib.request.urlopen(\"https://pypi.org/simple/pip/\", timeout=20).status)"
  python3 -m venv /tmp/venv
  /tmp/venv/bin/pip install -q six
  /tmp/venv/bin/python -c "import six; print(\"venv+pip install ok\", six.__version__)"
  git ls-remote https://github.com/termux/proot HEAD | cut -c1-12 | sed "s/^/git https ok: /"
  cd /tmp
  git init -q demo
  cd demo
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git log --oneline | head -1
  apt-get check -q 2>&1 | tail -1
' && pass "python3, pip, venv, git, https and apt-get check" || fail "python/git checks"
else echo "  (skipped: NETWORK=0)"; fi

if [[ "$NETWORK" == 1 ]]; then
echo "== pnpm, registries and a real plugin add/remove through dsh plugin (network)"
# A tiny published bundle (one dependency, no install scripts, older than pnpm's 24 h release cooldown).
PLUGIN="${PLUGIN:-dsh-git-badge@0.20.1}"
run --share-net -- "${GUEST[@]:0:${#GUEST[@]}-3}" /bin/bash -c '
  set -e
  echo "pnpm $(pnpm --version); pnpm registry: $(pnpm config get registry); npm registry: $(npm config get registry)"
  test "$(pnpm config get registry)" = https://registry.npmmirror.com/
  export DSH_HOME=/tmp/dsh-plugin-test; rm -rf "$DSH_HOME"
  SECONDS=0; dsh plugin --profile web add "$1" > /tmp/plugin-add.log 2>&1 || { tail -30 /tmp/plugin-add.log; exit 1; }
  echo "added $1 in ${SECONDS}s; profile $(du -sh "$DSH_HOME/profiles/web" | cut -f1), store $(du -sh "$(pnpm store path)" | cut -f1)"
  grep -q "\"${1%@*}\"" "$DSH_HOME/profiles/web/package.json"
  dsh plugin --profile web remove "${1%@*}" > /tmp/plugin-remove.log 2>&1 || { tail -30 /tmp/plugin-remove.log; exit 1; }
  if grep -q "\"${1%@*}\"" "$DSH_HOME/profiles/web/package.json"; then echo "still a dependency after remove"; exit 1; fi
  rm -rf "$DSH_HOME"
' _ "$PLUGIN" && pass "pnpm on PATH, npmmirror registry, dsh plugin add/remove $PLUGIN" || fail "pnpm / plugin install"
else echo "  (skipped: NETWORK=0)"; fi

echo "== dsh web (online, port $PORT)"; SECONDS=0
LOG="$HERE/.work/$ABI/dsh-web.log"
run --share-net -- "${GUEST[@]}" > "$LOG" 2>&1 &
BG=$!
token=""; for _ in $(seq 1 240); do
  token="$(sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9]*/?token=\([A-Za-z0-9_-]*\).*#\1#p' "$LOG" | head -1)"
  [[ -n "$token" ]] && break; sleep 0.5
done
if [[ -n "$token" ]]; then pass "token line after ${SECONDS}s: $(grep -m1 '^dsh web:' "$LOG" | sed 's/token=.*/token=<redacted>/')"; else fail "no token line"; cat "$LOG"; fi
B="http://127.0.0.1:$PORT"
code="$(curl -s -o /dev/null -w '%{http_code}' "$B/")"; [[ "$code" == 401 ]] && pass "GET / without cookie -> 401" || fail "GET / -> $code"
hdr="$(curl -s -D - -o /dev/null "$B/?token=$token")"
cookie="$(sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' <<<"$hdr" | head -1)"
grep -q '^HTTP/1.1 303' <<<"$hdr" && [[ "$cookie" == dsh-auth-* ]] && pass "token exchange -> 303 + ${cookie%%=*}=…" || fail "token exchange: $hdr"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$B/")"; [[ "$code" == 200 ]] && pass "GET / with cookie -> 200" || fail "GET / with cookie -> $code"
asset="$(curl -s -H "Cookie: $cookie" "$B/" | grep -oE '(src|href)="\./[^"]+\.(js|css|svg|ico|png)"' | head -1 | sed -E 's/^(src|href)="\.//; s/"$//')"
if [[ -n "$asset" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "$B$asset")"; [[ "$code" == 200 ]] && pass "static $asset without cookie -> 200" || fail "static $asset -> $code"
fi
pid="$(cat "$ROOT/tmp/dsh-web.pid" 2>/dev/null || true)"
if [[ -n "$pid" ]] && grep -q 'lib/bin.js' "/proc/$pid/cmdline" 2>/dev/null; then
  pass "pid file names the dsh node process ($pid)"
  kill -TERM "$pid"     # what the app does: SIGTERM the pid from {ROOTFS}/tmp/dsh-web.pid
else
  fail "pid file missing or not the dsh process"; kill -TERM "$BG" 2>/dev/null || true
fi
for _ in $(seq 1 40); do kill -0 "$BG" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$BG" 2>/dev/null; then fail "still running 10s after SIGTERM"; kill -KILL "$BG"
else
  rc=0; wait "$BG" || rc=$?
  [[ $rc == 0 ]] && pass "dsh exited after SIGTERM (rc=$rc)" || fail "dsh exited after SIGTERM (rc=$rc)"
fi

echo "== dsh web offline (no network namespace access)"
LOG2="$HERE/.work/$ABI/dsh-web-offline.log"
run --unshare-net -- "${GUEST[@]}" > "$LOG2" 2>&1 &
BG=$!
ok=0; for _ in $(seq 1 240); do grep -q '^dsh web: http' "$LOG2" && { ok=1; break; }; kill -0 "$BG" 2>/dev/null || break; sleep 0.5; done
[[ $ok == 1 ]] && pass "starts and prints the token line without network" || { fail "offline start"; tail -20 "$LOG2"; }
kill -TERM "$BG" 2>/dev/null || true; wait "$BG" 2>/dev/null || true

echo "== route guard patch and dsh-go-bridge (port $((PORT + 1)))"
python3 -I - "$ROOT" "$HERE/patches/pins.json" "$MANIFEST" "$HERE" <<'PY' && pass "patched webserver matches pins.json; bridge at /opt/dsh-go; overlay loads it" || fail "patch / bridge layout"
import hashlib, importlib.util, json, os, sys
root, pins, manifest, runtime = sys.argv[1:5]
spec = importlib.util.spec_from_file_location('rtbuild', os.path.join(runtime, 'lib/rtbuild.py'))
rtbuild = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtbuild)
catalog = json.load(open(pins))
names, _ = rtbuild.select_dsh_patches(catalog, os.path.dirname(pins), 'android')
m = json.load(open(manifest))
terminal = {}
assert set(names) <= set(m["dshPatches"]), m["dshPatches"]
# The build records the series application order in the manifest.
for name in m["dshPatches"]:
    for rel, pin in catalog["patches"][name][m["dshVersion"]].items():
        if rel in terminal:
            assert terminal[rel] == pin["before"], (name, rel, 'broken ordered hash chain')
        terminal[rel] = pin["after"]
for rel, expected in terminal.items():
    got = hashlib.sha256(open(os.path.join(root, "opt/dsh", rel), "rb").read()).hexdigest()
    assert got == expected, (rel, got)
assert os.path.isfile(os.path.join(root, "opt/dsh-go/dsh-go-bridge/lib/client.js"))
assert "/opt/dsh-go/dsh-go-bridge/lib/index.js" in open(os.path.join(root, "etc/dsh-app/dsh-web.patch.yml")).read()
PY
rm -rf "$ROOT/tmp/route-probe"; mkdir -p "$ROOT/tmp/route-probe"
cp "$HERE/tests/route-probe/"* "$HERE/tests/route-guard.mjs" "$ROOT/tmp/route-probe/"
printf -- '- insert:\n    - id: dsh-app-route-probe\n      name: /tmp/route-probe/index.js\n' > "$ROOT/tmp/route-probe/probe.patch.yml"
GPORT=$((PORT + 1))
GUARD_GUEST=("${GUEST[@]}")   # same launch, another port, plus the test-only probe plugin
GUARD_GUEST[-1]="${GUARD_GUEST[-1]/--port $PORT/--port $GPORT}"
# extra overlays go right after the shipped one: options after the app's own flags reach the app
GUARD_GUEST[-1]="${GUARD_GUEST[-1]/dsh-web.patch.yml/dsh-web.patch.yml --patch /tmp/route-probe/probe.patch.yml}"
LOG3="$HERE/.work/$ABI/dsh-web-guard.log"
run --share-net -- "${GUARD_GUEST[@]}" > "$LOG3" 2>&1 &
BG=$!
token=""; for _ in $(seq 1 240); do
  token="$(sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9]*/?token=\([A-Za-z0-9_-]*\).*#\1#p' "$LOG3" | head -1)"
  [[ -n "$token" ]] && break; kill -0 "$BG" 2>/dev/null || break; sleep 0.5
done
if [[ -n "$token" ]]; then
  run --share-net -- /opt/node/bin/node /tmp/route-probe/route-guard.mjs "http://127.0.0.1:$GPORT" "$token" \
    && pass "every route guarded; official client, WebView and Dart client flows unchanged; bridge API" \
    || fail "route guard / bridge checks (see above)"
else
  fail "dsh web with the route probe did not start"; tail -20 "$LOG3"
fi
pid="$(cat "$ROOT/tmp/dsh-web.pid" 2>/dev/null || true)"
[[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || kill -TERM "$BG" 2>/dev/null || true
wait "$BG" 2>/dev/null || true

echo "== native plugins end to end (port $((PORT + 2)))"
# The shipped bridge (overlay, default timers) plus the test-only plugins of runtime/tests/fixtures,
# driven by runtime/tests/native-bridge.mjs --shipped with the rootfs's own node. Offline-safe.
rm -rf "$ROOT/tmp/native-test"; mkdir -p "$ROOT/tmp/native-test"
cp -r "$HERE/tests/fixtures" "$HERE/tests/native-bridge.mjs" "$ROOT/tmp/native-test/"
printf -- '- insert:\n    - id: fx-usage\n      name: /tmp/native-test/fixtures/native-usage/index.js\n    - id: fx-quick\n      name: /tmp/native-test/fixtures/native-quick/index.js\n    - id: fx-static\n      name: /tmp/native-test/fixtures/native-static/index.js\n' > "$ROOT/tmp/native-test/fixtures.patch.yml"
NPORT=$((PORT + 2))
NATIVE_GUEST=("${GUEST[@]}")
NATIVE_GUEST[-1]="${NATIVE_GUEST[-1]/--port $PORT/--port $NPORT}"
NATIVE_GUEST[-1]="${NATIVE_GUEST[-1]/dsh-web.patch.yml/dsh-web.patch.yml --patch /tmp/native-test/fixtures.patch.yml}"
LOG4="$HERE/.work/$ABI/dsh-web-native.log"
run --share-net -- "${NATIVE_GUEST[@]}" > "$LOG4" 2>&1 &
BG=$!
token=""; for _ in $(seq 1 240); do
  token="$(sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9]*/?token=\([A-Za-z0-9_-]*\).*#\1#p' "$LOG4" | head -1)"
  [[ -n "$token" ]] && break; kill -0 "$BG" 2>/dev/null || break; sleep 0.5
done
if [[ -n "$token" ]]; then
  run --share-net --setenv DSH_GO_BRIDGE_LIB /opt/dsh-go/dsh-go-bridge/lib/native -- \
    /opt/node/bin/node /tmp/native-test/native-bridge.mjs "http://127.0.0.1:$NPORT" "$token" --shipped \
    && pass "native plugin protocol: contributions, views, stream, invoke, deferred results, guard, degrade, reload" \
    || fail "native plugin protocol checks (see above)"
else
  fail "dsh web with the native fixtures did not start"; tail -20 "$LOG4"
fi
pid="$(cat "$ROOT/tmp/dsh-web.pid" 2>/dev/null || true)"
[[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || kill -TERM "$BG" 2>/dev/null || true
wait "$BG" 2>/dev/null || true
rm -rf "$ROOT/tmp/native-test"

echo "== native plugins v1.2 end to end (port $((PORT + 3)))"
# The shipped bridge plus the v1.2 test plugin (runtime/tests/fixtures/native-voice): media, micro,
# capability events, leases (runtime/tests/native-capabilities-live.mjs). Offline-safe.
rm -rf "$ROOT/tmp/native-test"; mkdir -p "$ROOT/tmp/native-test"
cp -r "$HERE/tests/fixtures" "$HERE/tests/native-capabilities-live.mjs" "$ROOT/tmp/native-test/"
printf -- '- insert:\n    - id: fx-voice\n      name: /tmp/native-test/fixtures/native-voice/index.js\n' > "$ROOT/tmp/native-test/voice.patch.yml"
VPORT=$((PORT + 3))
VOICE_GUEST=("${GUEST[@]}")
VOICE_GUEST[-1]="${VOICE_GUEST[-1]/--port $PORT/--port $VPORT}"
VOICE_GUEST[-1]="${VOICE_GUEST[-1]/dsh-web.patch.yml/dsh-web.patch.yml --patch /tmp/native-test/voice.patch.yml}"
LOG5="$HERE/.work/$ABI/dsh-web-native-v12.log"
run --share-net -- "${VOICE_GUEST[@]}" > "$LOG5" 2>&1 &
BG=$!
token=""; for _ in $(seq 1 240); do
  token="$(sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9]*/?token=\([A-Za-z0-9_-]*\).*#\1#p' "$LOG5" | head -1)"
  [[ -n "$token" ]] && break; kill -0 "$BG" 2>/dev/null || break; sleep 0.5
done
if [[ -n "$token" ]]; then
  run --share-net --setenv DSH_GO_BRIDGE_LIB /opt/dsh-go/dsh-go-bridge/lib/native -- \
    /opt/node/bin/node /tmp/native-test/native-capabilities-live.mjs "http://127.0.0.1:$VPORT" "$token" \
    && pass "native plugins v1.2: declarations, negotiation, media, micro, capability events, leases" \
    || fail "native plugins v1.2 checks (see above)"
else
  fail "dsh web with the v1.2 fixture did not start"; tail -20 "$LOG5"
fi
pid="$(cat "$ROOT/tmp/dsh-web.pid" 2>/dev/null || true)"
[[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || kill -TERM "$BG" 2>/dev/null || true
wait "$BG" 2>/dev/null || true
rm -rf "$ROOT/tmp/native-test"

echo "== dsh home after runs"; ls -A "$ROOT/root/.dsh" | head -20
echo "== direct glibc launch (Linux source build; Android permission/lifecycle still needs a device)"
if [[ -n "${DIRECT_PROOT:-}" ]]; then
  # Earlier plugin/route tests exercise mutable profile state. Use another
  # extraction of the same pinned archives for the direct/proot comparison.
  # The true non-root session gate must be able to traverse every ancestor.
  # Only this new disposable directory has its mode/ownership changed.
  DIRECT_ROOT="$(mktemp -d /tmp/dsh-direct-host.XXXXXX)"
  chmod 0755 "$DIRECT_ROOT"
  for archive in "${archives[@]}"; do
    tar -xf "$(dirname "$MANIFEST")/$archive" -C "$DIRECT_ROOT"
  done
  if bash "$HERE/tests/direct/run-tests.sh" "$DIRECT_ROOT" "$MANIFEST" "$DIRECT_PROOT" \
    "${DIRECT_OUT:-$HERE/.work/$ABI/direct-evidence}" "$((PORT + 4))"; then
    pass "direct host gate"
    rm -rf "$DIRECT_ROOT"
  else
    fail "direct host gate (see evidence directory; disposable root retained at $DIRECT_ROOT)"
  fi
else
  echo '  SKIP: set DIRECT_PROOT to a Linux build of the pinned Termux PRoot source and KOTLINC to a Kotlin compiler.'
fi
exit $FAILED
