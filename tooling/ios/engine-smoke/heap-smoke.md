# Main-heap recovery smoke (0130a5c + near-limit fix / b59fb06)

This standalone Simulator process dlopens the prepared DshNodeHost framework and
calls the real dsh_node_start twice in one PID. It needs the main-Environment
near-heap-limit fix (delivery 55/66). An older runner's fatal OOM is an expected
negative control, not evidence that this test enabled recovery.

```sh
bash tooling/ios/engine-smoke/build-heap.sh "$RUNNER_TEMP/heap-smoke"
node tooling/ios/engine-smoke/heap-drive.mjs \
  --simulator "$udid" --smoke "$RUNNER_TEMP/heap-smoke" \
  --frameworks "$RUNNER_TEMP/sim" --work "$RUNNER_TEMP/heap-smoke-work"
```

Use a new work directory and the frameworks already prepared for the ordinary
engine smoke: DshNodeHost.framework, matching NodeMobile.framework and the actual
DshNodeHost.framework/worker-preload.cjs. The driver sets both
DSH_GO_OHOS_NATIVE_LIBRARY_DIR and its SIMCTL_CHILD_ form to --frameworks, exactly
as fd-drive.mjs does. It does not fabricate a missing resource or rebuild NodeMobile.
The simulator shares the Mac filesystem, so absolute JS and empty-preload paths
are deliberate. No model, network server, credential, guest profile or App is needed.

Expected sequence, with one positive PID in all five JSON rows:

1. JS round 1 reports its actual heap_size_limit (268 MiB for the fixed 256/4 runner).
2. It allocates retained ordinary arrays filled with fractional numbers, forcing
   double elements rather than pointer-size-dependent small-integer slots. The
   request is bounded at 384 MiB of element payload. It must hit the actual main
   isolate limit; it does not use Buffer/ArrayBuffer external storage or exit(70).
3. The real first dsh_node_start returns 70 and emits ERR_IOS_HOST_HEAP_LIMIT.
4. JS round 2 starts in that same process, runs an ordinary eval Worker with an
   explicit empty execArgv, and receives 42 with Worker exit 0.
5. The real second dsh_node_start returns 0.

PASS requires the exact ordered rows, both real return codes, the recovery Worker,
fixed limit and native limit diagnostic, and observer exit 0. A round that simply
exits 70 without exercising this path is not an intentional probe option. A first
round returning 0, a failed recovery Worker, a missing bootstrap or fatal process
signal is BLOCKED. An unexpected heap limit fails before the pressure allocation;
do not remove that guard to stress an unknown memory budget.

The C watchdog exits the actual observer after 120 seconds; the driver has a
150-second outer deadline and a 1 MiB cap on each output stream. The observer ends
with _exit after reporting both Environment return codes, matching fd-smoke's
lifetime convention. This is not evidence of natural process-global Node teardown,
complete resource cleanup, business rollback, or continuing the interrupted turn.
It does not cover external/native/system OOM, initialization before registration,
cleanup after removal, or another heap shape needing more than the one 16 MiB
near-limit allowance. Real devices can still be terminated by jetsam.

stdout.log, stderr.log and report.json are written under --work. Preserve the exact
commit/framework SHA with a CI run. A Linux result is explicitly NOT an Apple run;
only invoking the Simulator command above supplies NodeMobile evidence. This test
uses an empty unified preload and is complementary to the full DSH thick smoke.

## Linux reference and negative gates

```sh
cc -std=c11 -D_GNU_SOURCE -shared -fPIC -O2 -pthread \
  -DDSH_HEAP_SMOKE_LINUX_PRELOAD tooling/ios/engine-smoke/heap-smoke.c \
  -ldl -o /tmp/heap-observer.so
node tooling/ios/engine-smoke/heap-drive.mjs \
  --smoke /absolute/node-24.22.1 --linux-preload /tmp/heap-observer.so \
  --library /absolute/actual-host-with-fix.so \
  --native-dir /absolute/prepared-frameworks --work /new/linux-heap-work
```

The Linux build uses the same C observer and JS checker with official Node's
exported embedding API. Author verification also tested these isolated negative
controls, each of which must be BLOCKED:

- Actual older runner without the callback: SIGABRT.
- A private script copy allocating only one array: first return 0.
- A private script copy whose recovery Worker returns 41: recovery fails.
- An empty --native-dir: the real runner rejects missing worker-preload.cjs.

No fault switch is added to the product runner or shipped probe. Control scripts
are private copies for verification, not candidate files. Running fatal controls
should disable core dumps in the test parent; they are not part of the default CI
command. No NOFILE adjustment is added by the probe.
