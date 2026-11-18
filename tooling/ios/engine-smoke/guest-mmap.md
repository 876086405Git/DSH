# Confined file mappings and Python

`guest-kernel-probe.c` runs the production DshGuest backend directly on an
iOS Simulator. Use an isolated, disposable copy of the fakefs root published
by `guest-install.swift`. Each copy must have its own parent directory because
the interrupted-task marker belongs to that parent. Never use an app's live
installation. The fixture grants root writes only to this disposable kernel;
the app's per-call approval path is unchanged.

Build the host harness with Xcode clang for `arm64-apple-ios15.0-simulator`,
the SDK sysroot, `-I runtime/ios/guest/native`, `-F` pointing at the freshly
built simulator guest output, `-framework DshGuest`, and an rpath to that output.
Run through `xcrun simctl spawn SIMULATOR HARNESS ROOT WORKSPACE TEMP SCRIPT`.
WORKSPACE and TEMP must be separate, absolute directories outside ROOT.
The harness cancels a job after 120 seconds; download packages separately for
slow networks rather than treating that timeout as an emulator failure.

Compile the Linux fixture into WORKSPACE with LLVM clang/lld:

```sh
clang --target=aarch64-linux-musl -nostdlib -static -fuse-ld=lld \
  -O2 -fno-builtin tooling/ios/engine-smoke/guest-mmap-probe.c \
  -o "$WORKSPACE/mmap-probe"
```

Run this SCRIPT in the harness:

```sh
set -eu
/workspace/mmap-probe c
/workspace/mmap-probe x
/workspace/mmap-probe f
for mode in r w p e z; do
  set +e
  /workspace/mmap-probe "$mode"
  status=$?
  set -e
  test "$status" = 135
done
echo MMAP_OK
```

This checks ordinary file creation with Linux st_mode bits, partial EOF zeroing, no file writeback from private writes,
MAP_FIXED replacement, fork inheritance, mprotect, and SIGBUS on whole EOF
pages (including an empty file and a map wholly beyond EOF). It exercises the
actual guest translator and signal delivery, not a mocked page table. Before
the fix, mode x exits 3 because the initial oversized mmap returns EINVAL.
Also run ordinary `cp` and recursive `cp -R` from fakefs into WORKSPACE and
check stderr: directory mode preservation must succeed, not merely leave a
copy behind with a warning. Confined chmod accepts ordinary permissions and
continues to reject special permission bits and writes on readonly mounts.

For a Python integration check, install `python3` and `py3-pip` into the
disposable Alpine root, copy `python-probe.py` into WORKSPACE, and run it with
Python. Also copy libpython and `lib-dynload` into WORKSPACE and select those
copies with `LD_LIBRARY_PATH` and `PYTHONPATH`; this exercises confined host
file mappings rather than only the fakefs mapping path. The probe imports and
uses math, zlib, array, select, socket, ssl, ctypes, sqlite3, datetime, decimal,
csv, and unicodedata without contacting external services.
Run `python-filesystem-probe.py` as well: it verifies recursive copying,
permissions/timestamps, cross-mount moves and Python's fd-safe temporary
directory cleanup. An offline `pip install --no-index --no-deps --target`
of a verified PyPI wheel exercises the same paths as a real package install.

The confined mapper uses anonymous host backing and copies a file snapshot.
It does not implement coherent observation of later host file truncation or
growth. It never requests host PROT_EXEC. This regression is manual and does
not add a new CI gate.
