# f9d0bd3 fd identity smoke

This is a separate Simulator process, not an app feature or a change to drive.mjs.
It dlopens the prepared DshNodeHost and calls its real dsh_node_start/stop API.
The Simulator shares this Mac's filesystem, so the script, empty preload and
ready files use absolute paths. No model or loopback server is needed.

Use the frameworks built from f9d0bd3 or a later equivalent runner: parent raw-fd
tracking is removed and the data-URL Worker wrapper disables its tracking.
Do not interpret an older tracking-enabled runner failing this gate as a regression.
The ordinary DSH/Worker round remains the responsibility of drive.mjs; this probe
isolates normal same-Environment fs ownership and does not load the DSH profile.

```sh
bash tooling/ios/engine-smoke/build-fd.sh "$RUNNER_TEMP/fd-smoke"
node tooling/ios/engine-smoke/fd-drive.mjs \
  --simulator "$udid" --smoke "$RUNNER_TEMP/fd-smoke" \
  --frameworks "$RUNNER_TEMP/sim" --work "$RUNNER_TEMP/fd-smoke-work"
```

Use a new work directory. --runs defaults to 5 (range 1..20). The framework directory
must also contain the matching NodeMobile.framework, as in the existing smoke job.
The driver sets DSH_GO_OHOS_NATIVE_LIBRARY_DIR to --frameworks, including the
SIMCTL_CHILD_ form for simctl. This is the same native-directory contract as the
real host and supports the follow-up synchronous Worker preload fix: that build
must contain DshNodeHost.framework/worker-preload.cjs. Linux verification can pass
--native-dir explicitly (otherwise it uses the host library's parent directory).
No missing preload is fabricated or silently skipped by this probe.
The native observer has an in-process watchdog of 120*rounds+30 seconds; a stuck
Stop exits that actual Simulator process with 124, not just its xcrun parent.

Each round leaves 8 sync and 8 callback raw fds open, plus 2 retained FileHandles.
It explicitly closes 8 additional raw fds. The host reserves exactly those freed
numbers for its own sentinel using F_DUPFD_CLOEXEC, then requests Stop and waits
for the runner to return. No dup2 is used: if another thread occupies a target,
reservation fails without replacing that fd and prepared=false marks the fixture
inconclusive. A deterministic preflight first occupies a target and confirms this
same reservation routine refuses it while preserving its owner's dev/ino.

Expected after each Stop:

- 8 host sentinel fds and the independent host source retain their dev/ino.
- 16 raw Node fds retain their original identity: this is the accepted f9 limitation.
- The 2 managed FileHandles are recorded separately; the Linux reference closes both.
- Same-PID raw-fd accumulation is 16, 32, 48, 64, 80 over the default five rounds.

The report gates all listed reference observations. It includes rawStillOpen,
fileHandleClosed/fileHandleStillOpen, ownedNumberReused and sentinelsLost so a
failure can distinguish unmanaged retention, managed-handle cleanup and misclosure.
Do not reduce this to fd counts: every owned descriptor is checked by dev/ino.
Raw fixture fds are deliberately retained between rounds and closed by the observer
only after the last measurement. That final diagnostic cleanup is not a product fix.

report.json, stdout.log and stderr.log are written under --work. No token, model
credential or account is involved. A prepared=false row is a setup failure, not
proof that the engine closes the wrong fd. Preserve the exact framework SHA and
commit alongside results. This script does not claim to measure fd accumulation
of a full DSH session, cross-Worker ownership, or real devices.

Linux reference-only runner for the identical observer and JS driver:

```sh
g++ -std=c++20 -shared -fPIC -O2 -pthread -DDSH_FD_SMOKE_LINUX_PRELOAD \
  tooling/ios/engine-smoke/fd-smoke.cc -ldl -o /tmp/fd-observer.so
node tooling/ios/engine-smoke/fd-drive.mjs \
  --smoke /absolute/node-24.22.1 --linux-preload /tmp/fd-observer.so \
  --library /absolute/actual-f9-host.so --work /new/linux-fd-work
```

The Linux adapter uses official Node's exported embedder symbols. It does not
build or emulate NodeMobile; actual Simulator compilation/run must be reported
separately. The source changes only the iOS test directory and adds no dependencies.
