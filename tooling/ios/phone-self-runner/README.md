# Shared on-device CoreDevice and XCTest owner

This native component provides two routes through the **same singleton owner,
remote pairing input, and RSD tunnel implementation**. CoreDevice supplies PNG
screenshots, app names/IDs, app launch, and bounded HID operations. The existing
optional XCTest route still launches the installed, signed PhoneRunner helper and
returns its encrypted endpoint. The app chooses the route and handles user
consent; this library does not make that choice or automatically retry an action
through another route.

The new CoreDevice/DDI implementation has portable compilation, parser,
ownership, wire-format and C ABI checks. **Apple cross-builds, actual device DDI
mounting/TSS, screen sharing, HID effects, orientation mapping and remote cleanup
remain device-validation gates.** Static inspection of Apple's fixed DDI supports
the media protocol fields below; it is not a successful device execution.

## Build and verification

`prepare_upstream.py` already refuses an existing `.upstream` whose recorded
pin/patch identity or file inventory differs. It now reports the unchanged
directory, expected commit/archive/patch hashes and a quoted rerun command,
including the original `--archive` argument when supplied. Missing or invalid
prepared metadata receives the same recovery guidance. Preserve and inspect
the old entry, check it against `source-pins.json` and the current patch, then
explicitly move it to a chosen backup outside `.upstream` before rerunning.
The script never removes or rebuilds that entry automatically. A matching
existing tree is still reused; archive, patch and source checks are unchanged.

The local [toolchain file](rust-toolchain.toml) pins Rust 1.99.1. The repository
iOS build integration supplies the native archive and generated config. Merely
linking the component grants no pairing, network, media or input authority; all
such work requires the app to explicitly start the owner after its user gates.

```sh
bash tooling/ios/build-phone-self-runner.sh --check
```

This verifies the upstream archive and prepared tree, runs the Rust tests, builds
the actual host static library, links/runs a C ABI smoke executable, and runs the
preparation/attribution tests. The C executable starts real native workers using
a nonexistent legacy pairing file: it tests bounded rejection, busy/stale
handles, startup cancellation, callbacks and owner release before any TCP
connection. It does not emulate a successful phone.

A separate ignored test can read the eight real pinned DDI files using the
production native cache loader. It never mounts an image or contacts a device:

```sh
cd tooling/ios/phone-self-runner
DSH_TEST_DDI_CACHE=/absolute/fixed-layout/catalog \
  cargo test --locked real_pinned_catalog_files_pass_independent_native_validation -- --ignored
```

On a Mac with Xcode selected:

```sh
bash tooling/ios/build-phone-self-runner.sh
```

The script builds device arm64 and simulator arm64/x86_64 libraries in the ignored
`app/ios/PhoneSelfRunnerNative/` directory. It publishes
`PhoneSelfRunner.xcconfig` last; that file enables the optional Swift compilation
condition and selects the platform/architecture library. The app must still obtain explicit opt-in to its sensitive capabilities. A
failed native build must not be represented as an enabled but missing archive.

`LICENSE.idevice.txt`, `SOURCE.json`, `THIRD_PARTY_CRATES.json` and `NOTICES.txt`
are emitted for the app resource phase. The inventory covers the actual locked
Cargo metadata graph; NOTICES reproduces its available license and attribution
texts, including separately identified pinned supplements. The build and archive
gates verify whole-document and per-source byte identities and package coverage.
See [README-NOTICES.md](README-NOTICES.md) for source gaps and verification limits;
the collection is not a legal compatibility or complete distribution audit.

## Pairing and checked status

Both routes accept `pairingBase64`: canonical base64 of a remote pairing plist,
maximum 87,384 encoded bytes / 65,536 decoded bytes. The native layer independently
requires exactly the flat fields `public_key`, `private_key`, `identifier`, and
optional `alt_irk`. Public/private keys must each have 32 bytes; deriving the
public key from the private key must agree. The identifier is nonempty, at most
128 UTF-8 bytes, with no NUL; alt_irk must have 16 bytes. Duplicate fields,
unknown fields, nested containers and malformed types are rejected. This is not
a traditional lockdown HostID/HostCertificate record.

New Swift callers use in-memory pairing; the native layer writes no pairing
file. A mutually exclusive absolute `pairingFile` remains for old callers and
portable compatibility tests. Self-owned base64/decoded buffers and the typed
validation copy are zeroized when released. This does not claim that every
allocation inside serde or the upstream library is zeroized.

For the optional XCTest route, if iOS asks to **Enable UI Automation**, confirm
on the iPhone by entering its lock-screen passcode there. This system
confirmation can block readiness even after PhoneRunner launches. If startup
times out, complete the confirmation before retrying; never send the passcode
to the app, agent or logs.

Only loopback IPs or the established self route `10.7.0.1` are accepted, with a
nonzero port. Startup verifies existing pairing; it never begins PIN pairing,
silently repairs the record, or persists credentials. The fixed upstream CLI's
creation command is:

```sh
idevice-tools --udid DEVICE_UDID rppairing pair HOSTNAME OUTPUT.plist
```

That USB/CoreDeviceProxy command may require an on-device trust action and has
not been run on a device in this environment. Treat its output as sensitive.

Core event fields distinguish actual checks:

| Optional boolean | When it is emitted as true |
| --- | --- |
| `vpnReachable` | The configured self-route TCP connection succeeded; this alone does not identify the VPN implementation |
| `pairingVerified` | RPPairing validation succeeded using the provided record |
| `lockdownReady` | A real Lockdown ProductVersion query over the same RSD adapter succeeded |
| `ddiMounted` | This owner completed a requested mount, refreshed RSD and found the required services |

An omitted field means it was not established. Existing developer service
availability is reported as `capabilities.servicesReady`; it is not relabeled as
proof that this owner mounted an image.

## CoreDevice C ABI

The declarations are in [dsh_phone_self_runner.h](include/dsh_phone_self_runner.h).
`dsh_phone_core_build_identity()` returns the permanent read-only NUL string
`dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065`
without touching an owner, pairing material or I/O. Swift checks the actually
linked component, and an archive can inspect this marker even after symbols are
stripped; it does not replace source provenance or runtime validation.
The new `dsh_phone_core_start` / `dsh_phone_core_request` inputs have explicit
lengths. Config is at most 96 KiB and a request at most 16 KiB. Config keys are
`runId`, `host`, `port`, `pairingBase64` (or legacy `pairingFile`), optional
`ddiCache`, and `allowDDIMount` (default false). `runId` must be a UUID.

Synchronous code 0 means accepted, not performed. Codes 1–8 mean invalid input,
busy, stale handle/ID, not ready, stopping, faulted, size limit, and internal
failure. A rejected request has no callback and sends no action. One owner has
one in-flight request; IDs must be nonzero and strictly increasing. Owner handles
increase without wrapping into a reused generation. A stale stop/cancel cannot
affect a newer owner/request.

Callbacks run outside the global owner mutex, on the native worker thread.
Strings and binary data are borrowed until callback return. Copy them before
MainActor dispatch. Callback JSON is at most 8192 bytes, PNG at most 16 MiB, and
app-list JSON bytes at most 1 MiB. Error callbacks have null/zero binary data.
Callbacks may precede start's return, after `handle_out` has been populated. An
accepted request gets one result before its owner's terminal callback, except
when the process terminates.

| Event kind | Meaning |
| --- | --- |
| 0 | Starting/progress stage; no actions ready |
| 1 | Ready, with a boolean capabilities map |
| 2 | Stopped, all owned local resources released and remote cleanup confirmed |
| 3 | Failed, with cleanup confirmed and owner released |
| 4 | Cleanup unconfirmed; local resources released, small owner remains poisoned until app restart |
| 5 | Actual DDI stage/byte progress |

Event JSON uses `code`, `stage`, `variant`, `completedBytes`, `totalBytes`,
`capabilities`, `cleanupConfirmed`, and the checked-status booleans above. Codes
are stable bounded identifiers; arbitrary device error text, pairing material,
clipboard text, TSS payloads and screenshots are never diagnostic fields.

Request status 0 is a successful read or transport dispatch, 1 is failure before
dispatch, 2 cancellation before dispatch, and 3 uncertainty after dispatch.
Result JSON uses `outcome` (`read`, `dispatched`, `notSent`, `uncertain`), `code`,
`mayHaveActed`, `cleanupConfirmed`, `contentType`, `kind`, `width`, `height`,
`interfaceOrientation`, `nativeFrameId`, `pid`, and `foregroundVerified` as
applicable. Result `cleanupConfirmed` is about that request. Complete owner
release is established only by terminal event 2/3.

### Explicit preparation, frame binding and operations

After a real native confirmation that includes establishing screen/control
sharing, Swift privately requests `prepareInput`. This operation is not exposed
as a model/MCP tool. Settings checks and DDI mount probes never request it.
Preparation invalidates any earlier native frame. Swift then obtains a screenshot,
checks the current engine/session task grant, and recaptures/compares the screen under
the same prepared owner before dispatching the approved input.

```json
{"op":"prepareInput"}
{"op":"screenshot"}
{"op":"apps"}
{"op":"launch","bundleId":"com.example.app"}
{"op":"tap","x":0.5,"y":0.5,"durationMs":50,"nativeFrameId":"UUID"}
{"op":"swipe","fromX":0.5,"fromY":0.8,"toX":0.5,"toY":0.2,"durationMs":300,"nativeFrameId":"UUID"}
{"op":"key","key":"home","nativeFrameId":"UUID"}
{"op":"ascii","text":"Hello","replace":false,"nativeFrameId":"UUID"}
{"op":"paste","replace":false,"nativeFrameId":"UUID"}
```

Inputs require the latest owner-local frame UUID, at most 30 seconds old. They
consume the frame, require already active owned media, and recheck SpringBoard
orientation immediately before sending. They never start media implicitly.
Frame age uses Apple `mach_continuous_time` (available since iOS 10) with checked
integer timebase conversion, or Linux `CLOCK_BOOTTIME` for portable checks. Both
include system sleep. Missing/invalid samples, overflow and backwards samples
reject the frame; there is no wall-clock or awake-only fallback. Rust 1.99.1's
Apple `Instant` uses `CLOCK_UPTIME_RAW`, so it is deliberately not used for this
age check. Other request/transport scheduling retains its existing clocks.
The source contracts are the fixed
[Apple Mach time header](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/mach/mach_time.h)
and [Rust 1.99.1 clock implementation](https://github.com/rust-lang/rust/blob/58cf8f9c35b355199727627d07ae34a4e2846d67/library/std/src/sys/time/unix.rs).
The injected sleep-spanning boundary test is not an actual iPhone suspend test.
Cancellation invalidates the current frame. A new capture is required after each
input, launch or preparation. The native gate supplements the app's approval and
screen matching; the native C ABI by itself is not an end-user permission UI.

Screenshot orientation is queried before and after capture using the read-only
SpringBoard service. A change or unknown value fails the capture. Raw orientation
values are 1 portrait, 2 upside down, 3 landscape right and 4 landscape left.
Dimensions come from the actual PNG IHDR, whose signature, length and CRC are
checked, and are bounded to 8192 per axis / 33,554,432 pixels. Swift must decode
the complete PNG and compare its dimensions before use; the native IHDR check is
not a full PNG decoder. Service reply allocations occur in the upstream client
before these application output limits; no stronger network-allocation bound is
claimed here.

Tap/swipe coordinates are finite normalized values in [0,1], translated to the
fixed upstream mainTouchscreen range 0..65535. Tap duration defaults to 50 ms and
is bounded to 50..1500 ms for long press; swipe duration is 50..2000 ms.
Tap/swipe require orientation 1 (portrait); other orientations fail before any
touch report with `ERR_PHONE_TOUCH_ORIENTATION_UNVERIFIED` and capabilities
include `touchPortraitOnly: true`. The pinned screenshot source returns PNG
bytes without a PNG-to-HID rotation contract. This conservative gate does not
prove even portrait mapping: corner/center grid tests on a device remain a
release gate. Screenshot, ASCII and keyboard requests are not disabled by this
touch-specific check. Keys are
limited to home, enter, backspace, tab, escape, arrowUp/Down/Left/Right. ASCII is
printable US-layout ASCII (0x20..0x7e), 1..1024 bytes, validated in full before the
first report. Other scripts go through the app's explicit clipboard/paste flow.
Both the Rust ASCII parser and the Swift text plan reject LF and TAB in literal
text, so embedded LF/TAB are not translated to Enter/Tab reports. The named-key operation
is a separate native primitive and does not bypass the app's approval rules.
The Swift plan also conservatively refuses strings containing only 3..8 decimal
digits after ignoring whitespace and separators U+002D, U+2010, U+2011, U+2013,
and U+2212. This OTP/PIN heuristic is not a complete sensitive-data classifier
and does not normalize or rewrite accepted text.
Native paste only emits Command+V and never receives the clipboard content.
ASCII/paste accept an optional `replace` boolean (default false); true prepends
Command+A inside that same approved/frame-bound request. The first Command+A
already sets mayHaveActed, so a failure after selection is uncertain, never an
automatic retry. Native does not append an implicit Enter/submit; any later
submit needs a fresh screenshot and the app's separate verification/approval.

The app list binary body is `{"apps":[{"name":"Display name","id":"com.example.app"}]}`
with `kind=apps`, `contentType=application/json`. No executable paths or audit
payloads are returned. Launch sends only the bundle ID, no arbitrary argv/env,
kill-existing, suspension or stdio options. It returns the real nonzero PID and
`foregroundVerified=false`. AppService list/launch is not proof of the current
foreground app. Screenshots likewise say `foregroundVerified=false`; the app
must not infer an OS-verified bundle identity from them.

HID sends are one-way. `dispatched` means that the requested report sequence was
written and its release/keyboard-removal handling completed; it does **not** prove
that an app consumed a click, text or paste. No fixed delay is an application ACK.
After an action may have been sent, error/cancellation returns uncertainty and
retires the owner. It cannot authorize automatic retry or fallback through
XCTest. If remote cleanup cannot be confirmed, the singleton remains poisoned.

## Media ownership and cleanup

Fixed idevice source requires an active display-service media session for HID
input. Explicit preparation negotiates audio then video using one fresh session
UUID and two UDP sockets on the existing RSD adapter. RTP payloads are drained
and discarded. Bounded header counters and RTCP receiver reports maintain the
session; media payloads are not decoded, logged, stored or delivered to the model.
Registering a virtual keyboard also sets mayHaveActed before its create RPC.
The mainKeyboard uses the pinned create/identity-confirm/reset/remove/confirm-
absence API; arbitrary service IDs and arbitrary HID reports are not exported.

An initial status query rejects an existing session. After start and before
cleanup, native checks the UUID, media kind, expected receiver endpoint, peer
endpoint, and returned numeric identifier. Stop sends **`stopAll=false` with
only the verified current owner's UInt32 identifiers**, with unsigned XPC wire
encoding. It validates `stoppedStreams`, the stop result's server state, and a
fresh independent status query. Unknown schemas, missing identities, duplicate
identifiers or foreign reuse are not treated as idle/safe cleanup.

The fixed Apple DDI's `SessionWrapper.identifier` is the returned
`connection.streamConfig.RemoteSSRC`; its internal AVC `streamToken` is separate.
This mapping was independently established from actual ARM64 getter/store/stop-
matching instructions, supported by Swift field/CodingKeys reflection. Both
fixed DDI variants contain the same relevant binaries:

| Binary | SHA256 |
| --- | --- |
| dtremotedisplayd | `5ac94652b4f7cfc076dd5867c6d957e988e526aa78576f6deb7f2ab7deae85ca` |
| CoreDeviceUtilities | `78d978f2d69fa0239550d87947c26b3bccaf4b11b52093910b8da981f14fc5af` |
| CoreDeviceMediaStreamSupport | `9025f543066da266df512beee72792c85d6d20e2e4fbeb7005d17c1b64487c7f` |

DeviceServerInfo has running/runDurationSeconds/sessions; each SessionInfo has
optional connection and a status object. Portable fixtures are constructed from
this static schema, not captured device traffic. A dropped media-start future
may still commit remotely; an empty status snapshot alone does not clear that
uncertainty. Local socket closure and ConnectionInfo.timeout are not assumed to
prove remote cleanup.

The daemon's start path can remove a duplicate existing stream by type,
direction and source. Therefore `mayHaveActed` is set **before the first media
start**, even before any HID report. A preflight status query is not an atomic
cross-controller lock; this implementation does not prove global SSRC uniqueness
or eliminate a different controller's concurrent status/start/stop race. It does
not invoke a global stop to hide those limitations. Screen sharing may also
conflict with camera/microphone use in foreground apps; this code does not bypass
platform restrictions.

## DDI cache and foreground mount authorization

`allowDDIMount` defaults to false. Having cached bytes is never mounting authority.
Only the app's foreground mount confirmation supplies true. Existing required
developer services cause no mount. An already present image with missing services
is not automatically unmounted, replaced, or nonce-rolled.

The only catalog is
`ddi-e2aaeac89ca8fa56c2fa1f144d182994e07a525b-v1`, from the pinned
[DeveloperDiskImage distribution](https://github.com/doronz88/DeveloperDiskImage/tree/e2aaeac89ca8fa56c2fa1f144d182994e07a525b).
This is a third-party mirror of Apple's DDI assets, not an Apple download host.
The app downloader verifies the fixed hashes and publishes its cache atomically;
native independently checks the same eight built-in SHA256 pins. No arbitrary
URL, caller-selected hash or manifest-directed path is accepted.

```text
catalog/
  personalized/BuildManifest.plist
  personalized/Image.dmg
  personalized/Image.dmg.trustcache
  cryptex/BuildManifest.plist
  cryptex/Image.dmg
  cryptex/Image.dmg.trustcache
  cryptex/Image.dmg.cryptex_info
  cryptex/Image.dmg.root_hash
```

`ddiCache` has `catalogId`, absolute `directory`, and optional `personalized`
(manifest/image/trustCache hashes) and `cryptex`
(manifest/image/trustCache/info/rootHash hashes) objects. The missing required
variant is returned as `ERR_PHONE_DDI_CACHE_REQUIRED` plus `variant`, so the app
can request the bounded download. Files are opened relative to anchored directory
FDs; bundle/file symlinks, nonregular files, changed hashes and wrong lengths are
rejected. Nonblocking open prevents a FIFO fixture from hanging before its file
kind can be rejected. Each of the eight pins includes an exact byte length,
checked on the opened FD before allocation and again after the bounded read.
Personalized manifest/image/trustcache are 801,505 / 15,733,248 / 1,895 bytes;
Cryptex manifest/image/trustcache/info/rootHash are
804,946 / 15,895,040 / 1,895 / 430 / 229 bytes. A larger invalid cache file is
rejected from metadata before reading its payload.

Selection follows the conservative policy in fixed
[pymobiledevice3 776d601](https://github.com/doronz88/pymobiledevice3/blob/776d601cec83b894c3ad0eeee8ab4db375a46e4a/pymobiledevice3/services/mobile_image_mounter.py):
iOS major >=27 plus explicit CryptexInstall capability selects Cryptex1;
otherwise Personalized requires a matching chip/board identity. Capability alone
is not used to claim support on older versions. Personalized uses the pinned
ImageMounter/TSS operations and performs the documented Lockdown query after
opening/reopening its service. Cryptex uses the pinned Cryptex1 asset/request
APIs. Both stay on the same adapter and refresh RSD before reporting success.

Progress stages are verifyingAssets, personalizing, uploading, mounting and
refreshingServices. Personalized upload uses actual byte progress; Cryptex's
upstream install helper has no byte callback, so its progress is indeterminate.
Cancellation or failure after upload/install submission preserves unconfirmed
cleanup poison. Portable validation of the real catalog only establishes local
file hashes/parsing; Apple TSS and a device mount still require real execution.

## Preserved XCTest path

The legacy `dsh_phone_xctest_start/stop` symbols, callback kinds and exact-PID
cleanup semantics remain. Its config additionally needs runnerBundleId,
targetBundleId and a 2048-bit RSA PKCS#1 DER publicKeyBase64. The matching signed
helper must already be installed. No custom runner environment, RPC token or
private RSA key is accepted.

The only injected runner environment fields are nonsecret DSH_PHONE_RUN_ID and
DSH_PHONE_PUBLIC_KEY. The helper creates its credential in memory, seals its
endpoint with RSA-OAEP-SHA256 and returns an encrypted XCTest activity. The
listener accepts readiness only from the selected serving test; the app must
still decrypt and verify the fresh run ID. Existing iOS 26 none/none activity
handling, UID resolution and the absence of a legacy Marco/Polo requirement are
retained.

Submitted XCTest launch waits for a valid nonzero 32-bit PID or faults. Cleanup
only kills/queries that exact PID, never a newly discovered process by bundle ID.
Missing/malformed process-status replies do not prove absence. Faulted/unconfirmed
sessions retain the shared singleton so another route cannot overlap them.

## Dependency provenance and known transport findings

The sole protocol-library source is
[jkcoxson/idevice](https://github.com/jkcoxson/idevice), MIT, fixed at
`3854a5df4a5a6dee71ffce4d8befc2ea356a8065` (0.1.68), archive SHA256
`bb3c171161476dac94c190a4867bf4a670663643d5dfa5b8b38086948fbc3042`.
[source-pins.json](source-pins.json) and [Cargo.lock](Cargo.lock) are checked in.
Generated upstream source and build outputs are ignored. No external dsh-Go PR
was merged or copied.

The existing [upstream source patch](idevice-rsd-xctest.patch) retains its RSD
XCTest entry point, strict PID-exit confirmation, encrypted readiness support,
UID fixes and removal of a pairing-record debug statement. The crate additionally
disables all upstream tracing in development and release: other upstream debug
paths can contain pairing or TSS data. Explicit bounded ABI events remain.

Two pre-existing issues in the fixed shared transport were observed and recorded
separately; this native change does not silently claim to fix them:

- `remote_pairing/tls_psk.rs` accepts a decrypted server Finished whose verify_data
  mismatches the computed value: it logs and continues. Record MAC validation
  exists, but is not a substitute for transcript-bound Finished verification.
- `remote_pairing/tunnel.rs` checks the CDTunnel header but slices the declared
  body length without checking that the complete body is present. A truncated
  authenticated body can panic. Native catch_unwind/poison contains some fallout;
  it does not make this a correct parser rejection.

Both routes use those functions. A separately reviewed hardening change needs
negative crypto/frame tests and the existing Apple/device regression gate.
Neither static analysis nor portable tests establish the complete production
safety/compatibility of this new phone path.
