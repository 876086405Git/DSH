# Guest DNS preparation

The fixed Alpine minirootfs has CA certificates but no resolv.conf. On Apple,
the C backend now snapshots the default system resolver immediately before each
serial task, before mounting the approved workspace or temporary directory.
It renders numeric IPv4/IPv6 nameservers using public libresolv APIs and writes
through guest fakefs operations, preserving database metadata. Apple DshGuest
links `-lresolv`.

This is a default-resolver snapshot, not Apple's complete split-DNS/VPN routing
policy. Scoped IPv6 addresses and nonstandard DNS ports are not represented.
There is no hardcoded public resolver and no promise of network availability.
If no usable server is returned, an explanatory comment replaces any old
nameservers and the task still starts, allowing offline programs to run. Guest
DNS/network operations then succeed or fail according to the actual environment.
The API does not return a networkReady flag.

Before changing files, `/etc` must be a real guest directory, the destination
must be absent or a regular file, and each maintenance path must normalize to
itself on the supervisor's root fakefs mount. No guest task runs during this
check. A fresh exclusive/no-follow staging file with a monotonic numeric suffix is written, closed and renamed
through guest APIs. Preexisting staging objects are skipped, never overwritten or removed. A new
process restarts its counter but skips names left by previous processes. Up to
64 collisions are tried per task; exhausting the bound returns EEXIST and the
next task continues from the advanced counter.
Only a staging file created by this invocation is cleaned up after failure.
Unsafe paths return EPERM; publication failures return EIO. Such failures start
no task, borrow no callback context, and leave the kernel READY for a retry.
A process crash may leave a staging file; subsequent tasks skip it. Legacy
unsuffixed files are also left untouched. Residual files occupy ordinary rootfs
space and are included in installation usage. This change does not implement
garbage collection: safe cleanup can be added later, or uninstall/reinstall
removes the installation after the existing kernel lifecycle gate allows it.

Apple API declarations were checked against the official header:
https://raw.githubusercontent.com/apple-oss-distributions/libresolv/main/resolv.h
SHA256 `23b0c0ee5ec83c530b66539f86b94913047d1084750d5afc1dbd331ee5a7ae2e`.
The header declares res_ninit(res_state), res_getservers(res_state,
union res_sockaddr_union *, int), and res_ndestroy(res_state); Apple names are
mapped to res_9_* symbols. Implementation is original code using those APIs,
not copied from an app's DNS routine. Official source context:
https://github.com/apple-oss-distributions/libresolv/blob/main/res_state.c

Apple SDK compilation, libresolv linkage on the target SDK, and device networking
remain unverified. Linux tests substitute the resolver provider only, while
executing the actual kernel/fakefs writer; see tests/README-dns.md. The Linux
production build does not synchronize Apple resolver state.
