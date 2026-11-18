# Pairing bytes at the Swift/native boundary

This follow-up depends on the native lifetime change in
`README-PAIRING-LIFETIME.md`. It removes the avoidable pairing base64 String and
secret-bearing JSON representations from both production Swift startup paths.
It also covers the related status-query item: XCTest `isConfigured` now uses a
separate availability closure instead of loading and normalizing private keys.
The remaining FFI unwind work is separate and is not implemented here.

## Additive C ABI

```c
uint64_t dsh_phone_xctest_start_bytes(
    const uint8_t *config_json, size_t config_len,
    const uint8_t *pairing_plist, size_t pairing_len,
    dsh_phone_xctest_callback callback);
int32_t dsh_phone_core_start_bytes(
    const uint8_t *config_json, size_t config_len,
    const uint8_t *pairing_plist, size_t pairing_len,
    dsh_phone_core_event_callback callback, uint64_t *handle_out);
```

The JSON and plist are independent borrowed read-only buffers. Config is UTF-8
JSON of 1..98,304 bytes. Pairing is the existing raw RP plist format of 1..65,536
bytes, including binary plist zero bytes. It is not a NUL-terminated string.
Both pointers must remain valid and unmodified for the synchronous call. Native
parses the plist directly into the existing single owned typed pairing record;
it does not retain a caller pointer or a second full raw plist/base64 buffer.

The byte APIs use strict metadata schemas with no `pairingBase64` or
`pairingFile` field. Either key is rejected, even when its value is null. Unknown
and duplicate keys are rejected. Other launch fields retain their existing
validation, including the public RSA key for XCTest. That public key remains
base64; it is not the imported pairing private key.

Validation happens before owner admission. Empty/null/malformed/schema-invalid
inputs have no callback or accepted handle. Core returns 1 for invalid inputs,
7 for an exceeded length limit after required-pointer/empty/callback checks,
and 2 when the original shared owner is busy. `handle_out` is zero on rejection;
an invalid non-null pointer remains caller UB. XCTest retains its zero/nonzero
handle convention. Both wrappers use the original internal start machinery;
callback ordering, singleton ownership, cancellation and terminal semantics are
unchanged. This patch adds no panic-containment guarantee; the separate FFI work
must cover these two new wrappers as well as the original entry points.

The original `dsh_phone_xctest_start` and `dsh_phone_core_start` symbols and JSON
contracts remain supported for existing callers. Their base64 fields continue
to use the clearing owners added by the preceding lifetime change. The internal
Swift XCTest file-only test/compatibility seam still uses the old ABI, with a
path and public metadata only. Production supplies the memory provider and
always chooses the byte API. Failure to load that record does not fall back to
the legacy file route.

## Swift ownership and remaining limits

Both owners serialize public metadata before loading the record. A small
synchronous scope loads the Data and calls native through nested
`withUnsafeBytes` closures. The record is not captured in callbacks or stored in
the owner/session model. No asynchronous wait follows the borrow inside that
scope. Apple's [ContiguousBytes contract](https://developer.apple.com/documentation/foundation/contiguousbytes/withunsafebytes(_:))
limits the buffer pointer to the closure's execution; native must finish parsing
before that closure returns. The API may provide contiguous storage when needed,
so this is not a claim that Foundation creates no temporary storage.

The user-selected session record in `IOSPhonePairingStore`, or a remembered
Keychain item, remains a legitimate holder. A local Data value may share storage
with that record. Mutating non-unique Data can cause a copy; Apple's
[Data initializer documentation](https://developer.apple.com/documentation/foundation/data/init(bytesnocopy:count:deallocator:))
explicitly describes this copy-on-write behavior. Consequently startup does not
call `resetBytes` on the borrowed local value as a claimed erasure: that can
allocate and erase a new copy while the intentionally retained original remains.
It releases its local hold instead. This does not change the store's import,
session-retention, revocation or Keychain policies.

Swift Data, Keychain bridging, PropertyListSerialization, CryptoKit, parser
scratch, allocator, stack and register copies are not proven universally erased.
Native owned fields retain the preceding patch's clearing behavior; its single
persistent signing-key record is dropped immediately after successful pair-verify
and on error/cancellation. Session-derived RPC/TLS keys remain necessary for the
connection and are a separate lifetime.

The production `pairingAvailable` closure calls `IOSPhonePairingStore.hasRecord`,
which uses the existing attribute-only Keychain presence query. Status does not
call the record provider. An injected memory provider must also supply its
availability closure; absent availability is false. Startup still handles a
record being unavailable or invalid when actually loaded.

## Presence and backend selection (ADDENDUM-09 §3.1)

The selected policy keeps the attribute-only presence query. It does not restore
private-key reads to status polling and does not add an automatic Mac fallback
after an on-device preparation failure. Presence, loadability, pair-verify and
an accepted XCTest endpoint are separate observations.

In the production memory-provider path, `isConfigured` means that the native
client exists and `hasRecord` reports a stored/session record. It does not check
all launch configuration, load the bytes, normalize keys, contact the device or
prove that PhoneRunner is ready. A remembered item can be present while its
subsequent read or validation fails. That failure is `.setup`, before native
startup admission, and the caller returns the existing failure outcome. The
fixed native explanation now includes unreadable/invalid records as well as
incomplete configuration; it does not assert that every `.setup` is a Keychain
failure or that unlocking always repairs it.

The existing `dsh/phone` status key `bridgeListening` is
`bridge != nil && IOSPhoneSelfRunner.shared.isConfigured`. When the bridge is
bound and the record is present, it can therefore remain true despite a later
load failure. The existing `pairing.present` / `pairing.code=OK` status likewise
reports presence, not a fresh content validation. Neither is a ready indicator.
The separate CoreDevice `connection` / `checks` fields retain their own meaning.

`IOSPhoneRunner` selects the on-device XCTest owner when `link.enabled` and
`isConfigured` are true. A failure from that selected owner returns its message
and the existing instruction that this call will not automatically switch to a
Mac runner. It does not try the legacy file provider either. A separate Mac
endpoint can still be selected through the existing route when the on-device
route was not selected; this is not a retry of the failed call. The native
resource predicate `mayUseMacFallback` alone is not an automatic retry policy.

There are no new Dart methods, arguments, keys, phase values or error codes.
The existing runner result still uses `isError=true` and `text`; the explanatory
text changes, while route selection and failure semantics stay as implemented
in 17. UI wording should say that a record is saved and still needs a successful
check, rather than label `bridgeListening` as a verified connection. See the
[UI contract](../phone-control/UI-CONTRACT.md#2-状态字段). Dart UI is maintained
separately and is not changed by this patch.

## Verification

```sh
cargo test --locked --offline --lib w31_pairing -- --test-threads=1
cc -std=c11 -Wall -Wextra -Werror -fsyntax-only -I include tests/pairing-bytes-header.c
```

The Rust filter includes eight new byte-boundary tests and the preceding nine
lifetime tests. It covers raw input independence, exactly one native validation,
65,536-byte acceptance/65,537-byte rejection, partial parse cleanup, strict JSON
including forbidden null fields, pointer/length/callback rejection, busy-owner
rejection without callbacks, and both new start wrappers' pre-connection cancel
paths. Those startup callbacks cancel before the biased connection future is
polled; no socket, service, file or device operation is needed. All keys and
records are freshly generated synthetic fixtures. The C fixture checks new and
legacy declarations without linking or running an owner.

The existing Swift test classes add four methods using recording transports:
separate unchanged bytes and public-only metadata in both callers, session-store
retention, boolean status without record loads, invalid lengths before admission,
and unavailable records without private-key reads. These methods are already
within the existing RunnerTests class selections. They require Apple SDKs and
are not claimed executed on Linux. Native Apple linking, Swift type-checking,
real Keychain behavior and actual device startup remain Apple validation gates.

The ADDENDUM-09 follow-up adds one owner regression case for presence=true with
a throwing record provider: status does not load it, preparation reports setup,
native is never started and a later status query still does not read private
bytes. This is authored XCTest, not an executed Apple test; the no-Mac-retry
branch is additionally traced in the unchanged production Runner.
