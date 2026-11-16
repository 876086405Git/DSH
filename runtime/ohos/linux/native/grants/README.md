# Trusted grant FID adapter: research integration, not a production mount capability

The C adapter consumes a one-use task ticket issued by the trusted parent. Guest
`aname` must be empty; no guest host path is opened. Only the research owner maps
fixed config selector `dsh-ticket` and mount tag `dsh-workspace` to this object.
The ordinary Node Linux binding does not expose that owner and must continue
advertising no workspace confinement. Do not enable shared workspaces merely
because this source compiles.

Compile TinyEMU with CONFIG_FS_GRANT plus this adapter, linking the same
libdsh_host grant service (host test compiles the service into one test DSO).
Use patch 0014 after the frozen 0013 recipe. The native ABI header is
app/ohos/entry/src/main/cpp/workspace_fids_abi.h. The default production build
without CONFIG_FS_GRANT remains unchanged in how it chooses a filesystem.

The object layer pins regular files/directories using portable POSIX read FDs;
walk requires read permission. No O_PATH or /proc/self/fd reopening is required.
Symlinks and special files are denied, hard links retain POSIX object semantics.
A write open verifies the pinned inode before truncating, and rejects a replaced
name. Already-opened files retain their object after rename. Relative parent
walk uses logical pinned ancestry and clamps at the selected grant root.
Guest uid/gid are virtual 60081, matching the fixed guest agent. They grant no
host permission: grant RW intersects the parent-issued task ticket on every IO.

This first consumer supports full-grant scope only. No subroot is accepted.
Synchronous calls serialize against ticket retirement. Tflush acknowledges only
previous completed synchronous operations; it is not cancellation of a blocking
host syscall. Tversion clears old FIDs without issuing a new grant. Retire stops
new accesses, but the owner must also stop the job tree, stop/join the VM before
calling the research quiesced hook, clunk every FID, and check ticket drain.
A close error quarantines both task and grant even after lease count reaches 0.
The VM heap stays quarantined, as in 912; no reuse or new-generation reconnect is
claimed by this research owner.

Still required for production: authenticated per-task mount admission in the
real guest agent, transport epochs and reconnect barriers, trusted parent mount
table integration, target SDK compilation, HAP inclusion and actual device
verification. Setattr/chmod/fsync/locks/link/symlink/append-open are not supported.
No cache=loose/writeback is allowed. Guest tests use cache=none/access=any.
