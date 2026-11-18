# RemoteXPC object and HTTP/2 resource budgets (ADD08 / ADD09)

This increment extends the control-message limits in
`README-REMOTEXPC-BOUNDS.md`. It keeps the idevice commit, archive checksum,
dependency versions and lock unchanged. All upstream edits remain in
`idevice-rsd-xctest.patch`; run `prepare_upstream.py` to reconstruct the source.

## Object parsing and plist conversion

Each `XPCObject::decode` and `to_plist` operation has its own cumulative budget:

| Resource | Limit |
| --- | --- |
| Object depth, root counted as 1 | 64 |
| Objects, including containers and Null values | 65,536 |
| String, dictionary key and Data bytes | 16 MiB |

The same counter follows sibling branches. Container declarations are checked
before iteration, and do not cause a capacity reservation for untrusted counts.
String terminators, padding and remaining input are checked before copying.
The earlier 16 MiB wire-body limit and String/Data remaining-length checks stay
in effect.

`XPCObject::to_plist` now returns `Result<plist::Value, IdeviceError>`. Both pinned
RemoteXPC call sites propagate that result. Conversion also limits objects
constructed by program code, including dictionary keys; UUID text and the keys
and scalar generated for a FileTransfer dictionary consume the output budget.
Every error from `recv`, `recv_root` or `recv_any` clears the partial control
buffers and closes the owned HTTP/2 transport.

## HTTP/2 buffering and flow control

| Resource | Limit |
| --- | --- |
| Inbound frame payload | 16 KiB |
| Raw frame reassembly buffer | 32,777 bytes |
| Queued DATA per stream | 1 MiB |
| Queued DATA across all streams | 4 MiB |
| Tracked streams | 128 |
| Queued DATA frames per stream / total | 1,024 / 4,096 |
| Pending serialized output | One frame, at most 16 KiB + 9 bytes |

DATA accounting includes its pad-length byte and padding, and excludes the
nine-byte frame header. The frame length is rejected from the header before
waiting for its body. The 16 KiB frame limit matches the HTTP/2 default: this
client does not advertise a larger SETTINGS_MAX_FRAME_SIZE. Empty DATA still
consumes a queued-frame slot.

Connection and stream receive windows start separately at 65,535 bytes. The
existing RemoteXPC handshake still raises the stream initial window to 1 MiB
with SETTINGS and raises the connection window to 1 MiB with a separate
WINDOW_UPDATE. Arrival debits both windows. An unconsumed stream receives no
replacement credit merely because DATA was enqueued.

Removing DATA from the queue accumulates credit for the next operation. There
is no await between popping the payload and returning it to the caller. Credit
is moved into a single persistent output frame, whose write offset survives a
cancelled future. Local granted credit increases only after that whole frame
has been written. Retrying a partial write or a pending flush neither duplicates
WINDOW_UPDATE nor adds its credit twice. ACK, HEADERS and DATA use the same
pending-frame writer so subsequent output cannot split an unfinished frame.

The peer's send-window changes are also checked for 31-bit overflow. A legal
SETTINGS shrink can make a send window negative; empty DATA/END_STREAM still
costs no flow-control credit. Protocol/resource errors close the owned transport
immediately, clear local queues and leave the client in a sticky failed state.
They do not retry or act on another native owner.

## Stream lifecycle and practical limits

END_STREAM marks the remote half closed. Queued final DATA remains readable;
new DATA and further stream credit are disallowed. Once both halves have ended
and queued DATA is consumed, the stream entry is removed. The existing expected
RST for a completed outbound file stream removes its entry and returns only
connection credit for discarded queued bytes. Other active resets remain fatal.

Two parity-specific watermarks retain closed-ID information without an expanding
tombstone set. Existing lower-numbered streams remain live; retired IDs cannot
be recreated. Late WINDOW_UPDATE/RST for retired streams is ignored. Half-closed
or unread streams remain subject to the same caps. There is no timer-based
assumption that the peer has acknowledged closure, and no invented idle expiry.

These are local operational limits, not measured Apple protocol maxima or an
exact RSS ceiling. Vector/map spare capacity, object overhead, input and output
coexisting, caller-held data and lower-layer transport buffers have additional
cost. ADD09 control receives drain both channels 1 and 3 as described below;
other unconsumed streams, including file-transfer streams, can still stall at
their window until their caller consumes them or an existing outer deadline
ends the operation. Legitimate traffic exceeding a cap fails instead of growing
memory. Device compatibility at the chosen limits, Apple builds and real-device
behavior remain **UNRUN**.

This change does not add general HTTP/2 support beyond the pinned RemoteXPC
frame/setting subset. It does not change the file-transfer wrapper arithmetic,
trusted outbound XPC encoder or `From<plist::Value>` recursion, and makes no
claim about caller-created arbitrarily deep values being safe to drop. The new
recursive fixtures stop at depth 65. No old crash, deep-stack, ASan or high-fd
probe is used.

## ADD09: consume both control channels while waiting for one route

The bounded HTTP/2 client returns receive credit when queued DATA is consumed,
rather than on arrival. Before this correction, `recv()` waited only on reply
channel 3. DATA arriving on root channel 1 stayed in the HTTP/2 queue, retaining
both stream and shared connection credit (or the finite frame slots for empty
DATA). This can stall a long-lived DisplayServiceClient even while its caller
correctly waits for a reply.

A channel-specific RemoteXPC receive now drains both control channels and stores
each chunk under its actual channel in the existing persistent `partial` map.
The requested channel has priority when both have queued DATA. Only a decoded
body from that requested channel is returned; meaningful root messages are not
misclassified as replies or discarded. A later `recv_root()` or `recv_any()`
can consume them. There is no await between HTTP/2 consumption and appending to
the persistent buffer, so cancellation cannot strand a popped chunk in an
abandoned local future.

The transport still schedules connection and stream WINDOW_UPDATE through the
existing cancellation-safe writer on the next operation. Each channel retains
the unchanged 16 MiB + 24-byte pending-XPC cap, including coalesced messages and
incomplete headers; its declared body is still limited to 16 MiB. An oversized
declaration on the other control channel now fails promptly when its prefix is
received, using the existing protocol error and close/clear behavior. No budget
was increased and no control data was moved into an unbounded parsed-message
queue. Two independently bounded channel buffers, their capacity and decoded
objects are not a 16 MiB whole-process memory promise.

Two accompanying corrections preserve receive semantics after this routing
change:

- The internal multi-stream read carries a required-stream EOF condition. Final
  queued DATA on the requested channel is still returned, then its EOF remains
  an error even if the other control channel is open. Merely calling the old
  unrestricted `read_any([1, 3])` would have hidden that EOF behind another stream.
- `recv_any()` skips all already-buffered bodyless/empty-dictionary messages up
  to the first body or incomplete message before awaiting new network input.
  The other route can now have several keepalives and a body already buffered;
  taking just one empty message and awaiting new DATA would leave that body stuck.

Nonempty messages for an indefinitely unrequested route still consume its
bounded partial-buffer budget. This patch does not promise unlimited retention
or discard application messages whose meaning is unknown. The file-transfer
END_STREAM/reuse issue, pending-credit admission checks and transport flush
behavior listed separately in ADD09 LOW are unchanged. The EOF guard above is
for the selected control receive, not a fix for outbound file-stream closure.

There are no new Dart methods, map keys, phases, ABI status values or public error
strings. The existing invalid-control-message error can surface earlier for the
other control channel. The idevice commit, archive checksum, source preparation,
dependency versions and lock remain unchanged. Only the two reconstructed
production files `xpc/mod.rs` and `xpc/http2/mod.rs` differ from the prior prepared
source; every other nested patch section is byte-preserved.

### Bounded ADD09 regression target

```sh
cargo test --locked --offline --test remote_xpc_unread_channels -- --test-threads=1
```

This standalone integration target contains **7 authored / 0 executed** tests
in the current author environment. It calls the real prepared RemoteXpcClient;
it does not substitute a Python/C model for Rust execution. Normal
`build-phone-self-runner.sh --check` uses Cargo's test discovery and will also
include the new file. The command above limits a local verification run to these
new cases and does not run the older resource/deep-stack fixtures.

The cases cover both receive directions crossing more than two default
65,535-byte windows with actual credit observed by the peer, exact preservation
of the other channel's 128 KiB synthetic body, cancelled partial input, 1,100
zero-length DATA frames (9,900 wire bytes), a split oversize declaration rejected
at byte 16 without supplying its body, coalesced keepalives/body routing, required
DATA/HEADERS EOF and final DATA before EOF. They use 32 KiB Tokio duplex buffers
and one-second virtual deadlines; there are no sockets, devices, high-fd probes,
ASan runs, unbounded loops or recursive synthetic objects.

Pinned-source download/checksum verification, original and candidate
`prepare_upstream.py` executions, nested apply and outer patch apply are separate
recorded checks. Rust/Cargo are absent in this author environment, so Rust
compilation and all seven executions remain **UNRUN**. Apple compilation and
real-device compatibility also remain **UNRUN**.

## Pure synthetic verification

```sh
cargo test --locked --offline --lib xpc_resource_tests -- --test-threads=1
```

The test-only library module includes the exact reconstructed HTTP/2 and budget
files, while decoder/receive tests call the actual idevice dependency. Fixtures
cover depth 64/65, shared object/byte budgets, generated plist values, frame and
metadata caps, padding, independent windows, consumption-based credit, partial
write/flush cancellation, stream retirement and sticky transport failure. A
multi-frame control message also crosses the initial receive window and checks
returned credit before a plist-conversion budget error. All bytes use memory
transports; no socket, server, model, user record or device is used.

Protocol reference: [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html),
sections 4.1–4.2, 5.1–5.2, 6.1 and 6.9. The resource cap values and failure policy
above are project choices.
