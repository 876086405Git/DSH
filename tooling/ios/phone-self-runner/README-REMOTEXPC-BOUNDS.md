# RemoteXPC control-message budgets

The pinned upstream patch now limits a RemoteXPC control-message body to 16 MiB
and each channel's pending XPC buffer to 16 MiB + the 24-byte wrapper. The pending
cap includes any coalesced complete messages and incomplete following headers.
This is a local operational budget, not an Apple-documented protocol maximum.

The shared checked helper reads the little-endian u64 declaration as soon as the
first 16 wrapper bytes are available. It rejects an excessive declaration before
extending the pending Vec, and uses checked conversion/addition. The public
`XPCMessage::decode` also uses that helper before body slicing. All three receive
routes (`recv`, `recv_root`, `recv_any`) use the same append/decode budgets.

Only complete, declared frames reach the object decoder. A malformed complete
body returns its error immediately instead of being mistaken for an incomplete
frame and accumulating later bytes indefinitely. Successful frames still drain
exactly their own bytes, preserving coalesced following messages; incomplete
valid input still survives a cancelled read.

String/Data declared lengths plus padding must fit the remaining body before
allocation. This closes the adjacent path where a small body could otherwise
request a much larger Vec. Limits and malformed inputs surface through existing
protocol errors; no new ABI or diagnostic payload is introduced.

## Exact scope

This budget concerns control-message bytes. HTTP/2 raw frames and queued payloads
for other streams are owned by the separate HTTP/2 client and are not given a
new aggregate budget here. File-transfer streams, recursive object depth, total
node overhead, Vec spare capacity and converted plist copies are also not a
claim about a 16 MiB whole-connection or process-memory ceiling. The file-transfer
path is unchanged. Actual large legitimate device responses have not been
measured; Apple/device validation remains **UNRUN**.

The helper and decoder changes are carried only in the repository's existing
upstream patch mechanism; the idevice commit, dependency versions and lock remain
unchanged. This patch is independent of the TSS and pairing-lifetime changes.

## Pure synthetic verification

```sh
cargo test --locked --test remote_xpc_bounds
```

Tests compile the exact prepared bounds helper and use the actual public
RemoteXpcClient / XPCMessage implementations. They cover exact/over limits,
`u64::MAX`, a split length prefix, reject-before-append behavior, all three receive
routes, coalesced messages, cancelled/resumed partial input, and String/Data
lengths that exceed their complete body. All transport bytes use Tokio memory
duplex streams and virtual time. No socket, server, RSD peer, real device, model,
engine or user record is used.
