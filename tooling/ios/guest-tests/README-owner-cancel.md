# N-API output cancellation regression

The Owner treats explicit cancel/kill as permission to discard unacknowledged
output. This is separate from selecting the signal: cancel keeps TERM followed
by the existing KILL escalation; kill sends KILL immediately; explicit abandon
keeps its existing cancellation/error semantics.

A stopped native output callback returns ECANCELED so the C bridge records
abandonment and drains without incrementing delivered/ACK counters. No native ACK
is fabricated. No new output events are dispatched after the stop flag is set.
A late ACK for the same still-active cancelled job is a no-op: it does not call
native ACK or advance confirmed offsets. After exit the retired id is ESTALE,
even if another job is active. Normal jobs retain their original exact ACK and
per-stream backpressure rules.

JavaScript output Buffers were already made with napi_create_buffer_copy. They
remain owned by JavaScript if a consumer retains them after native cancellation;
waking the native callback does not free or mutate the consumer's Buffer.

## Cross-layer contract

For actually discarded output, the native result honestly reports
abandoned=true even when error=0 and resourcesSettled=true. The transport records
per-operation intent only after native cancel/kill succeeds. It accepts discarded
output only for that signalled operation, with resourcesSettled=true and a
non-quarantined native state, and after every JavaScript output consumer Promise
has actually fulfilled. Consumers that reject or remain pending still fault the
serial channel; no settlement or ACK is fabricated. Unsolicited abandonment and
failed signal requests do not gain this exception. A successfully cancelled
operation yields the usual AbortError and permits the next queued task.

Successful signalling also stops pending stdin EAGAIN retries. Continuing to
write after cancellation can encounter the deliberately closed input pipe and
incorrectly fault the otherwise settled queue. Failed signal requests do not
stop input, and unrelated EPIPE remains a real transport failure.

## Test

owner-cancel.cjs requires an already built real addon/kernel and a disposable
installed fakefs root. Supply absolute DSH_GUEST_TEST_ADDON, DSH_GUEST_TEST_ROOT,
DSH_GUEST_TEST_WORKSPACE, DSH_GUEST_TEST_TEMP and DSH_GUEST_TEST_PROTECTED paths.
The workspace/temp must be disjoint and outside the protected/root trees. It
writes small signal-marker files into that synthetic workspace.

Run with the matching Node architecture. The actual verification used official
Node24.22.1 Linux ARM64 under QEMU, --jitless --disable-sigusr1. It tests held ACK
cancel, standalone kill and abandon; no subsequent output event; retained Buffer
contents; late active ACK; stale old ACK during a replacement job; and successful
reuse. TERM markers distinguish cancel/abandon from standalone kill. Apple SDK,
NodeMobile, device lifecycle and signals remain separately unverified.

The companion channel-cancel.mjs uses the same absolute test environment paths.
Run it in separate processes with fulfilled, rejected and pending arguments. It
loads the real addon/kernel through the production NativeGuestChannel and
SerialGuestChannel. A500ms delayed consumer must complete before a clean cancel
settles; the next real guest job must succeed. A rejected or never-finished
consumer must still fault. channel-cancel.test.mjs adds focused synthetic
transport boundary cases (signal failure, unsolicited abandonment, unsettled or
quarantined exit); these unit fixtures do not claim native execution.
