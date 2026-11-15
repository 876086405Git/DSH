# Pairing record lifetime

The CoreDevice and XCTest JSON ABIs remain compatible. This change only reduces
native ownership and lifetime of the persistent remote-pairing record:

- `pairingBase64` is deserialized into a field that zeroizes its owned String on
  drop. A later invalid field, duplicate/unknown key or truncated JSON therefore
  also releases that already-parsed field through the clearing path.
- Base64 decodes into a guarded destination. Partially written bytes are cleared
  on decoding errors. The typed plist fields each have their own clearing owner,
  including when the enclosing plist record cannot be constructed.
- Typed plist values directly construct the upstream signing/verifying-key
  record. There is no second generic-dictionary parse and no retained original
  plist/base64 buffer. The memory input is validated once and consumed once.
- The connection future takes the record out of session configuration before
  polling. A cancelled, timed-out, failed or never-polled connection drops its
  record. Successful pair-verify explicitly drops the persistent record before
  creating the TCP/TLS tunnel, so it cannot remain for the rest of a session.
- A compile-time `ZeroizeOnDrop` constraint verifies the pinned SigningKey's
  clearing implementation is enabled. The local owner clears identifier and
  optional `alt_irk`; the SigningKey's destructor clears the private key.

The active upstream RPC/TLS connection still needs per-session derived keys and
cipher state. Those are distinct from the imported persistent signing key. This
patch does not claim to erase every cryptographic temporary inside upstream
libraries, deserialize-parser scratch buffer, allocator, stack or register.

## Swift / ABI boundary

Native functions borrow the caller's config bytes and do not mutate or retain
those input bytes. Native clearing therefore cannot erase the original Swift
Data/String, base64 representation, JSON serialization or bridging copies.
Swift's immutable/possibly shared String storage does not provide a reliable
"wipe every copy" guarantee. Native owned fields are now guarded independently
of Swift's release timing.

A separate pointer-plus-length pairing argument could remove base64/JSON
representations at this boundary, but requires a coordinated new CoreDevice and
XCTest ABI plus Swift callers. It is technically possible; this narrow native
patch retains compatibility rather than silently changing either ABI. Swift
callers should keep pairing/config values local to startup, avoid retaining
pairingBase64 in session models, promptly clear their mutable Data, and release
configuration values after the synchronous start call. Avoiding unnecessary JSON
slash escaping can reduce serialization work but is not a memory-erasure proof.
Any remaining Swift changes are separate from this native patch.

## Pure synthetic tests

```sh
cargo test --locked --lib w31_pairing
```

New tests cover one validation only, base64 partial failures, later plist-field
errors, key mismatch, conflicting inputs, JSON parse/validation failure in both
native configs, virtual-time cancellation, and both actual session functions'
pre-cancel branches. The latter use an already-ready biased cancellation before
the connection future is polled; no connection or file read occurs. Fixtures
are newly generated synthetic keys and literal test data, never imported user
records. Test-only events observe clearing while buffers are still owned; the
tests never inspect freed memory. No Apple/device execution is implied.

## ADD08 follow-up: legacy file destination

The compatibility file branch now reserves `MAX_PAIRING + 1` (65,537 bytes of
requested capacity) before reading any secret bytes. The extra byte is the
existing oversize sentinel; metadata checks, the `take(MAX_PAIRING + 1)` read
limit, final validation and `SecretData` clearing owner are unchanged. This
avoids growing the destination Vec from empty while it contains pairing data.
It does not erase parser scratch space, Tokio's own I/O buffers, allocator
copies or the original file, and is separate from the newer Swift byte ABI.

```sh
cargo test --locked --offline --lib w31_pairing_legacy_capacity -- --test-threads=1
```

The two new bounded fixtures invoke the actual legacy file load using only
newly generated synthetic keys and temporary regular files. They check short
and maximum-size valid records, empty and partial invalid plist input, and a
metadata-oversized file. Test-only observations compare destination capacity
and allocation identity while it is still owned, and retain the existing
clearing-path checks on success and validation error. No freed memory or user
pairing file is inspected; the oversized file is rejected before allocation
or parsing. These tests make no device, network, or Apple-execution claim.
