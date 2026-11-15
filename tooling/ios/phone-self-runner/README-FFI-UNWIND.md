# Synchronous FFI admission and Rust unwind containment

This change covers `dsh_phone_xctest_start`, `dsh_phone_xctest_start_bytes`,
`dsh_phone_core_start`, `dsh_phone_core_start_bytes` and
`dsh_phone_core_request`. Their signatures and acceptance contract stay the
same. It builds on the independent pairing-byte APIs; it is not a standalone
patch for a tree that does not yet contain those APIs.

For XCTest, a zero handle means no admission and no callback. For CoreDevice,
a nonzero synchronous status means no admission and no callback/action for that
call. Once admission is committed, a caught panic cannot change that return to
a rejection while a worker owns the accepted operation. Callbacks can still
precede the start/request return, run on the native worker, and allow reentrant
stop/cancel as before.

## Starts: worker creation precedes publication

Parsing, validation and the admission helper are enclosed by a Rust unwind
catch. The start helper acquires OWNER outside a second, narrower catch. It
creates the channels and worker before publishing the owner. The new worker
first locks OWNER and checks its exact handle; it cannot emit an event or open
a transport until publication has resolved.

The commit contains only moves into the known-empty slot, scalar writes to the
validated output pointer/admission marker, and an infallible return. A failure
before that commit leaves no owner, and a created worker exits without a
callback. A panic after the commit preserves the accepted handle/status and
lets the existing worker lifecycle deliver the terminal event.

OWNER's guard remains live outside the critical catch, including disposal of
the panic payload. It is released normally after the decision, so a newly
scheduled worker cannot race a temporarily poisoned mutex. This does not rely
on clearing poison after another thread might already have observed it.

## Requests: enqueue a callback-free placeholder, then commit

The queued value initially holds only a private gate. The parsed input and an
unarmed responder stay on the caller until admission succeeds. This separates
the fallible enqueue/wake path from ownership of a callback.

| Gate state | Meaning |
| --- | --- |
| Pending | Placeholder exists; no responder is owned by the channel yet |
| Ready | Admission committed; the worker owns the unique armed responder |
| Rejected | No admission; the placeholder produces no action or callback |
| Closed | Receiver took or dropped the placeholder |

Enqueue runs inside its own catch while OWNER stays locked. The commit helper
then keeps the private gate guard outside another catch. It requires successful
enqueue, a still-Pending gate, and a sender whose receiver is not closed. The
commit arms the responder, stores the accepted request ID and active ID, moves
the request into Ready, and sets the admission marker. These are scalar stores
and moves. The gate and OWNER are released before waking a waiting receiver.

The receiver waits for Ready/Rejected without holding OWNER. Its take/drop path
owns the unique responder after Ready, and drops that responder outside both
locks. Rejection therefore stays callback-free. After acceptance, ordinary
request completion or receiver teardown emits one result on the worker before
the owner terminal event, subject to the existing process-termination boundary.

## Receiver close between permit acquisition and push

The locked Tokio 1.54.1 source implements `try_send` as permit acquisition
followed by channel push/wake. A previously acquired permit can publish after
receiver close/drain. A Pending gate by itself is consequently insufficient:
the placeholder might have arrived after the final drain and have no live
receiver. Publishing Ready there could also create a
`Request -> Control -> Sender -> channel -> Request` reference cycle.

The commit checks `Sender::is_closed()` after enqueue, while its gate is held.
Such an orphaned placeholder is rejected without arming the responder or
advancing accepted IDs. If close instead races after that check, the already
pushed placeholder belongs to the receiver/drain, which waits on the same gate;
it takes or drops the eventual Ready request on the worker. The two orders have
separate deterministic tests, including a real reserved permit, receiver drop
and subsequent `Permit::send`, followed by weak-reference release assertions.

## What the catch does and does not cover

The shared helper catches Rust panics that unwind. It also catches a second
panic caused by dropping the first panic payload; that second payload is
forgotten rather than risking another unwind at the C boundary. Builds with a
panic strategy other than `unwind` are rejected at compile time.

The pointer validity and callback ABI contracts remain required. This does not
catch undefined behavior, process/OOM abort, an aborting panic hook, foreign
exceptions, or a callback unwinding across an `extern "C"` boundary. It does
not promise to recover an arbitrary failed process or erase every secret copy.
The stop/cancel/build-identity exports, Swift callers, protocol operations and
pairing ownership policy are unchanged.

## Pure synthetic verification

```sh
cargo test --locked --offline --lib w31_ffi -- --test-threads=1 --nocapture
```

Eleven targeted tests cover both legacy and byte start APIs, pre/post commit
panics, panic-payload destruction, waiting receivers, receiver teardown around
publication, full/closed queues, and the reserved-permit close window. Start
fixtures stop in their first callback and use the existing biased cancelled
branch before tunnel connection. Request fixtures use synthetic owners and
memory channels; they never create a Session or transport. Two affected existing
queue/result-drop tests are run separately from the same frozen test binary.

Expected injected-panic messages remain in the uncaptured logs; they are not
test failures. No old crash, abort, deep-stack, ASan, high-fd, device, server or
model probe is used. Apple builds and real-device behavior remain **UNRUN**.
The HTTP/2/XPC increment is separately reviewed; composition here is checked by
exact application, not by claiming an additional combined build.

Primary references: [`std::panic::catch_unwind`](https://doc.rust-lang.org/std/panic/fn.catch_unwind.html)
and the Cargo.lock-checksummed [Tokio 1.54.1 source archive](https://static.crates.io/crates/tokio/tokio-1.54.1.crate),
particularly `src/sync/mpsc/bounded.rs`, `chan.rs` and `batch_semaphore.rs`.
