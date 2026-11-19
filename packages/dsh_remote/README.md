# dsh_remote

Pure-Dart client for [ds-harness-remote](https://github.com/liguobao/ds-harness-remote) (李国宝, MIT). It reaches a remote Host's DSH Harness API through the Server Relay, or directly over a WebRTC DataChannel (LAN / P2P / TURN) when the app supplies a WebRTC stack, end-to-end encrypted with `Noise_IK_25519_ChaChaPoly_SHA256` either way. The result is an ordinary `DshClient` from `package:dsh_client`, so chat, watch, approvals, models and keys work exactly as they do with the local engine.

Status (2026-10-30, upstream `7e387df`, Host plugin 0.6.0):

| Layer | State |
|---|---|
| Noise IK | Matches upstream `fixtures/crypto/v1/noise-ik.json` byte for byte |
| Control frames / negotiation | Passes upstream `fixtures/protocol/v1` (84 client-relevant cases), including duplicate-key rejection, canonical Base64URL and the list limits |
| Relay transport (Control socket, or a Relay node data socket via `transport.relay.attach`), DSHF framing, RPC, tunnel carrier | Unit-tested against an in-process fake Server, Relay node and Host |
| Whole stack vs real upstream | **E2E passes** against self-hosted `apps/server` (upstream `7e387df`) + `dsh web` 0.2.1-rc.5 with the `ds-harness-remote` Host plugin 0.6.0 (packed from `7e387df`, not on npm yet), both on the Control socket and, with `RELAY_ATTACH=1`, through a Relay node data socket; also plugin 0.5.23 from npm (`tool/e2e/run_e2e.sh`; `PLUGIN_SPEC=<tarball>` for unreleased builds) |
| WebRTC / LAN / TURN (`WebRtcTransport`, opt-in through `peerConnector`) | Unit-tested: signaling order, selection before Noise, `RTCH`, fresh-connection Relay fallback and TURN configuration/selection. **Real P2P and Relay-only probes pass on Android 35 x86_64**, each with a 120 KiB request, 38,328-byte response and 20 round trips. No live TURN or WAN/device validation. See [verification and APK size](VERIFICATION.md) |

## Quick start (Flutter app)

```yaml
dependencies:
  dsh_remote: {path: ../packages/dsh_remote}   # re-exports package:dsh_client
```

```dart
import 'package:dsh_remote/dsh_remote.dart';

// 1. Secrets go through your SecretStore (flutter_secure_storage).
class SecureStore implements SecretStore {
  final s = const FlutterSecureStorage();
  @override Future<String?> read(String k) => s.read(key: k);
  @override Future<void> write(String k, String v) => s.write(key: k, value: v);
  @override Future<void> delete(String k) => s.delete(key: k);
}

final account = RemoteAccount(
  secrets: SecureStore(),
  serverUrl: 'https://dsh.r2049.cn',   // default; any self-hosted origin works
  deviceName: 'Pixel 9 · DSH App',      // shown in the account's device list
  platform: 'dsh-app-android',
  clientVersion: appVersion,
);

// 2. Sign in (once; tokens persist and refresh themselves).
if (await account.currentUser() == null) {
  final login = await account.startLogin();          // QR / browser sign-in
  await launchUrl(login.loginUrl);                   // Custom Tab or browser
  final user = await login.result;                   // polls every 2 s
  // Self-hosted Server: await account.loginWithPassword(email, password);
}

// 3. Hosts.
final hosts = await account.listHosts();             // online, versions, fingerprint, trust

// 4. Connect: a ready DshClient (same API as local).
final client = await account.connectHost(
  hosts.firstWhere((h) => h.online),
  onState: (s) => ui.showConnection(s),              // connecting/connected/reconnecting/failed/closed
  confirmNewHost: (h) => ui.confirmFingerprint(h.name, h.fingerprint!),  // optional first-use prompt
);
final sessions = await client.listSessions();
client.watch(sessions.first.sessionId).listen(transcript.apply);
await client.prompt(sessionId, 'hi');
await client.close();                                // or account.logout()
```

## API surface

### `RemoteAccount`: one account on one Server

| Member | Notes |
|---|---|
| `RemoteAccount({required SecretStore secrets, Object? serverUrl, deviceName, platform, clientVersion, ...})` | `serverUrl` defaults to `https://dsh.r2049.cn`. It is normalized to an origin, and plain HTTP is accepted only for loopback or private hosts. Storage is partitioned by origin |
| `RemotePeerConnector? peerConnector` (settable), `onDirectFallback`, `directTimeout = 8 s` | The WebRTC stack for the direct path; `null` (the default) keeps every connection on the Relay exactly as before. Read at each (re)connect. The package has no WebRTC of its own: the app implements `RemotePeerConnection` (flutter_webrtc). `onDirectFallback` reports why a direct attempt fell back |
| `bool compactHistory` (settable, default `false`) | Captured per new `connectHost` client, then reconfigured on each authenticated reconnect when the Host declares `remote.history.compact.v1`. Changing it never changes an existing client's history mode or live streams; losing compact support on an existing compact client fails with terminal `HISTORY_MODE_CHANGED` rather than mixing cached formats |
| `Future<RemoteUser?> currentUser()` | Restores stored credentials. Returns `null` when signed out or when the refresh token has expired. `RemoteUser.provider` is the provider the device signed in with (`github`, `zhihu`, `password`, ...), or `null` for credentials stored before it was recorded |
| `Future<List<OAuthProvider>> loginProviders()` | Server-defined QR-capable providers (`github`, `google`, `zhihu`, ...). Empty on a self-hosted Server |
| `Future<RemoteLogin> startLogin({String? providerId})` | QR / browser sign-in that needs **no app URL scheme**. Fields: `loginUrl` (open it), `expiresAt`, `providerId`, `result` (a `Future<RemoteUser>`) and `cancel()`. Keep `result` alive while the Custom Tab is open; polling resumes when the app returns to the foreground. The one-time web token is used once to register this device and is never stored |
| `Future<RemoteUser> loginWithPassword(email, password)` | Self-hosted Server, or invited accounts on the hosted one |
| `Future<void> logout({bool revokeDevice = true})` | Closes the connection and revokes the device on the Server (best effort). Deletes the tokens, and also the identity when revoked. Host pins are kept |
| `Future<void> refresh()` / `Future<String> accessToken({forceRefresh})` | Refresh is normally automatic (60 s before expiry) and single-flight, because refresh tokens rotate and reusing an old one revokes the whole family |
| `Future<List<RemoteHost>> listHosts()` | Fetches every Host's descriptor in parallel to report the identity key and trust |
| `Future<bool> supportsPairing()`, `resolvePairing(scan)`, `claimPairing(offer, {deepseekUserId})` | Device pairing v1 (scan the computer's QR, see below) |
| `Future<void> forgetHost(hostId)` | Drops a pin. Use it after the user confirms a legitimate Host reinstall |
| `Future<DshClient> connectHost(host, {onState, confirmNewHost, muxOptions, timeout = 30 s, tracer})` | See below |
| `Stream<RemoteConnectionState> connectionStates`, `connectionState`, `activeClient` | Follow whichever connection is currently active |
| `Future<void> close()` | Closes the active connection and the HTTP client |

`RemoteHost` fields: `id`, `name` (untrusted, escape it in the UI), `platform`, `online`, `harnessVersion` (DSH on the Host), `pluginVersion` (ds-harness-remote), `lastSeenAt`, `identityKey`, `fingerprint` (`ABCD EF01 2345`), `pinnedIdentityKey`, and `trust` (`pinned | unpinned | keyChanged | unknown`).

### `connectHost`

It returns once the first `$events` generation is ready. It throws `RemoteConnectException(failure)` in three cases: immediately for terminal failures, immediately for `HOST_OFFLINE`, and otherwise after `timeout`. Opening a connection does this:

1. Fetches the Host descriptor and checks the **pin**. The first connect pins the key, after `confirmNewHost` returns true when that callback is given; otherwise trust is on first use. A changed key always fails closed with `PEER_IDENTITY_MISMATCH`, before any socket is opened.
2. Control WebSocket: `hello` → `connect.request` → `connect.accepted`. A refused token is refreshed and retried once. When `connect.accepted` carries a Relay assignment (Server and Host both on `transport.relay.attach`), the client opens the node's data WebSocket, sends `relay.attach` with the one-time ticket, waits for `relay.ready` and announces `transport.selected`. Ciphertext and the node's heartbeats then use that socket; the handshake stays on the Control socket. Without an assignment (self-hosted `apps/server`, Hosts before 0.6.0) everything stays on the Control socket.

   **Direct path** (only with `peerConnector`): the client also offers `transport.lan/p2p/turn`. If the Server negotiates any of them and does not send `webrtcEnabled: false`, `connect.request` lists them before `relay`, and after `connect.accepted` the client fetches the connection's ICE servers (`GET /api/v1/turn/credentials`, configurable `iceServersTimeout`, default 10 s), opens an ordered DataChannel `dsh`, sends `signal.offer`, trickles `signal.ice` (never before the offer) and applies `signal.answer` and the Host's candidates. Once the DataChannel opens, the selected candidate pair names the path (`lan` for a local pair, `turn` for a relay candidate, else `p2p`; `lan` goes out as `p2p` when only that was negotiated) and `transport.selected` goes out **before** the Noise handshake, which stays on the Control socket. Ciphertext then travels as binary DataChannel messages, `RTCH`-chunked above 8 KiB. The first attempt is STUN/direct-only and filters relay candidates. No DataChannel within `max(directTimeout, webrtcFallbackTimeoutMs)` (capped at 15 s, including native peer creation and offer generation), ICE failure, or an unnegotiated path closes that connection. If TURN was negotiated, a **new** connection fetches fresh credentials and tries relay-only ICE, even when the first credential lookup failed or returned no TURN servers. Only after that stage fails does a new Relay-only connection open. Noise starts once on the final connection, without stale WebRTC state on the Host. Failed direct/TURN paths have independent 45 s host cooldowns; a changed native network hint clears them. Without negotiated direct transports the same connection simply continues on the Relay.
3. Noise IK as initiator. The Host's static key must equal the pin, and the prologue binds the connection and both device ids.
4. `harness.transport.describe`. The Host must declare `harness.remote.v3` (DSH 0.2.x Session V3). Older or ApiProxy-only Hosts fail with `HARNESS_VERSION_INCOMPATIBLE`.
5. When `remote.history.compact.v1` is present, await encrypted `remote.history.configure({compact: compactHistory})` and verify its exact echo before exposing the session or opening streams. Unsupported Hosts receive no configuration RPC. The Host summarizes historical tool details only; live events, approvals and original records are unchanged. The first successfully negotiated mode stays fixed for one `DshClient` (including automatic reconnects), avoiding mixed full/compact transcript caches: an initially unsupported Host stays full even if it later gains the capability, while losing compact support ends a compact client with terminal `HISTORY_MODE_CHANGED`. Changing the preference or recovering from that error requires a new client and transcript. Wire reference: [upstream protocol §17](https://github.com/liguobao/ds-harness-remote/blob/479b94341c0d0de63846f21d0fcca26997d158d1/docs/protocol.md#17-capability).

The returned client **reconnects by itself** (DshMux backoff 0.5 to 10 s): a new connection, a new `$events` generation, streams reopened, and `watch()` resynced with a snapshot where `isResync` is true. Liveness comes from a `harness.transport.describe` health probe every 25 s (5 s deadline) plus the Server's Control heartbeat; three silent heartbeats count as dead. `relay.detach` (the Host left the node), a dropped data socket or a closed DataChannel also ends the connection, and the reconnect builds a new one (trying the direct path again) with a new Noise session. The Server allows **one Host connection per client device**, so connecting another Host closes the previous client.

`session.networkDiagnostics` and `session.inspectNetwork()` expose selected-path timings and optional `peerNetwork` metadata (local/remote `RemoteIpVersion`, `RemoteIceProtocol`). Only the current selected candidate pair is used; missing/mDNS addresses remain unknown. No IP address, SDP, URL or credential is retained in these snapshots. ICE metadata does not describe the Control WebSocket or a Relay node's IP family. IPv6 private HTTP origins accept loopback, ULA (`fc00::/7`) and link-local (`fe80::/10`) literals; public IPv6 origins still require HTTPS. Address validation does not guarantee link-local routing or interface scope support.

### Connection state

```dart
enum RemoteConnectionPhase { connecting, connected, reconnecting, failed, closed }
class RemoteConnectionState { phase; hostId; RemoteFailure? failure; String? transport /* 'lan' | 'p2p' | 'turn' | 'relay' */; DateTime? at; }
class RemoteFailure { code; message; retryable; }
```

You can read it from `onState`, `account.connectionStates`, `client.remoteStates` or `client.remoteCarrier!.state`. The `DshClient` itself still reports `DshConnectionState`, and `watch()` still emits `ConnectionStateEvent`. Terminal remote failures map to `DshConnectionState.unauthorized`.

| `failure.code` | Kind | Suggested UI |
|---|---|---|
| `HOST_OFFLINE` | retrying | "Host offline" |
| `CONNECTION_FAILED`, `SECURE_CHANNEL_FAILED`, `RPC_TIMEOUT`, `TOKEN_EXPIRED`, `RATE_LIMITED` | retrying | "Reconnecting…" |
| `ACCOUNT_AUTH_REQUIRED` | terminal | Sign in again |
| `PEER_IDENTITY_MISMATCH` | terminal | Warn: the key changed; offer `forgetHost` only after explicit confirmation |
| `HOST_NOT_TRUSTED` | terminal | First-use confirmation declined |
| `CONNECTION_REPLACED` | terminal | "Used on another device"; offer to take over |
| `CONNECTION_REJECTED`, `MEMBERSHIP_REQUIRED`, `DEVICE_NOT_FOUND`, `DEVICE_REVOKED` | terminal | Host refused this phone / removed from the account |
| `HARNESS_VERSION_INCOMPATIBLE` | terminal | Update DSH (0.2.x) or the plugin on the Host |

A terminal failure **sticks**: the client stops reconnecting, so it never fights another device for the connection. After the user has fixed the cause, call `client.remoteCarrier!.reconnect()`.

### Differences from the local engine (same `DshClient` API)

| | Local `dsh web` | Remote tunnel |
|---|---|---|
| Endpoints | everything | Fixed upstream allow-list (`harnessRemoteAllowlist`). Others fail locally with `DshRemoteException('METHOD_NOT_ALLOWED')`. `uploadFile` (`fileUploads/upload`) remains unavailable; `client.supportsFileUpload` also checks the live `workspace.upload.v1` capability for `uploadWorkspaceFile`. Workspace uploads return a relative path, not an attachment receipt |
| Uplink stream items | yes | **no**: `MuxStream.supportsUplink == false` and `send()` throws `UnsupportedError` |
| Size | 300 MiB HTTP body | Calls up to 2 MiB go direct; larger ones (big inline images) use chunked `harness.remote.transfer.*` (512 KiB chunks, 288 MiB max). Responses over 4 MiB are retried through a transfer |
| Binary results | multipart (rejected) | `workspaceFiles/readBytes`, `officeToPdf/render` return `data` as a base64 string |
| Tunnel failures | HTTP 401/403/404 | Host refusals (`RPC_TIMEOUT`, `RATE_LIMITED`, `TERMINAL_DISABLED`, ...) become `DshRemoteException` with `details.remote = true`. A lost connection or a local deadline becomes `DshTransportException`, meaning the outcome is unknown, so don't blindly retry mutations |
| Streams | unlimited | 16 per connection (Host limit) |
| `client.connection` | `DshConnection` | throws `StateError`; use `client.remoteCarrier` |

### Workspace file uploads

`client.uploadWorkspaceFile(sessionId, bytes, name: 'notes.md')` uses the upstream top-level `workspace.upload.open/chunk/commit/abort` RPCs, with sequential chunks on one authenticated connection, using the Host's advertised `chunkBytes` (1–65536 bytes). Include the returned `path` in prompt text; do not invent a `fileReceiptId`. `client.supportsFileUpload` follows the current connection's capability, so reconnecting to an older Host can disable it again.

There is no extra client-side 20 MiB cap. The carrier enforces the protocol's absolute **1 GiB** ceiling; the app retains its normal **200 MiB** attachment budget. The Host remains authoritative for its version/path-specific limits (usually 20 MiB for Relay/TURN/unknown paths and older plugins, up to 1 GiB for newer verified LAN/P2P), writable session workspaces, safe basenames and collision-safe publication. Failed transfers are aborted best-effort; no mutation is automatically replayed after a timeout or reconnect. A timed-out commit may already have published the file.

Protocol reference: [ds-harness-remote 0.6.2, `479b943`](https://github.com/liguobao/ds-harness-remote/blob/479b94341c0d0de63846f21d0fcca26997d158d1/docs/protocol.md#L1529-L1618), MIT.

### Conversation snapshots

`RemoteSessionTransfer(client.remoteCarrier!.session!)` binds session backup and restore to one live Noise connection. Check `canExport` and `canImport` independently (`session.transfer.export.v1` / `session.transfer.import.v1`). `openExport` accepts a session or workspace scope, `readSession` returns verified opaque gzip bytes, and `closeExport` releases the handle. Only one session (up to 8 MiB compressed) is buffered at a time; no plaintext temporary file is needed.

`restore` validates the saved length and SHA-256, uploads sequential chunks and awaits `beforeCommit` so the caller can durably record the target device, batch and request IDs. Cancellation or failure before commit aborts the handle. An unknown commit outcome raises `SessionImportOutcomeUnknownException`: retain the pending record and query `status` with the original device identity after reconnecting. `null` means unknown or expired, not permission to retry. A false `workspaceAttached` still means history was restored; show the returned conversation ID instead of importing again. Mutations are never replayed automatically.

The app encrypts snapshots and its catalog in private storage, with the key in platform secret storage. Copies use backup-to-phone followed by switching hosts and restoring, because one client device can connect to only one Host. Attachments and workspace source files are not transferred. See the [upstream session-transfer protocol](https://github.com/liguobao/ds-harness-remote/blob/main/docs/protocol.md#跨机器会话传输).

### Remote DSH Web

`RemoteDshWeb(session)` uses the current live `dsh.web.v1` capability. `open()` returns a validated HTTPS tunnel root and operation-local grant; `takePostBody()` consumes the grant exactly once for the native WebView's form POST to `/__remote/session`. Never put that body into URLs, logs or persistent storage. Refresh uses a plain root GET, not the original POST.

`close()` stays on the original Noise session, serialized before a following open even across API instances. A failed or uncertain exchange is not replayed: obtain a new grant after closing. The default trusted parent is `hostc.4ba.io`; self-hosted parents must come from trusted app configuration, never from an RPC response. The App handles explicit `RATE_LIMITED` / HTTP 429 with a short busy message, without automatic retries. Android / iOS native POST, cookies, redirects and streaming still require real-device validation.

### Device pairing (scan the computer's code)

Upstream `docs/device-pairing-v1.md` and `docs/dsh-go-pairing-integration.md`, the phone side:

1. `parsePairingScan(text)` strictly parses the short code `https://<server>/pair#v1.<ticket>` (or the legacy JSON code) without opening it. Show `scan.origin` before sending anything there.
2. `resolvePairing(scan)` checks login discovery (`capabilities.devicePairing == dsh-pairing-v1`, plus `devicePairingQr == fragment-ticket-v1` for the short code) and resolves the ticket. Read-only on the Server. A code for another Server fails with `PAIRING_SERVER_MISMATCH` and its `origin`.
3. After the person confirmed the computer (name and the full `PairingDevice.fingerprint`), `claimPairing` claims with this device identity and returns `RemotePairing.verificationCode` (8 digits). The person types it into the computer; the phone never confirms for it.
4. `RemotePairing.result` completes once this phone's credentials are stored and the Host key is pinned; then `listHosts` / `connectHost` as usual. It fails with `PAIRING_CODE_REJECTED` (one attempt), `PAIRING_EXPIRED`, `PAIRING_CANCELLED`, `PAIRING_ACCOUNT_CONFLICT` (signed in to another account: those credentials are kept), `PAIRING_IDENTITY_MISMATCH`, or a Server code.

The claim, `mobile/status` and `mobile/cancel` POSTs carry `X-DSH-Pairing-Proof` over the exact JSON text sent; `resolve` sends only the ticket, without a proof (`pairingProof`, checked against the upstream fixed vectors in `test/fixtures/pairing/proof_v1.json`). A lost claim response is recovered by resending the same bytes. Polling (2.5 s) backs off on 429/503 and pauses with `RemotePairing.paused`. `deepseekUserId` is optional unverified metadata, never credentials.

## Security model

- The device identity (X25519) and tokens live only in `SecretStore`, under keys `dsh_remote.v1.<sha256(origin)[:24]>.{identity,credentials,pins}`. Passwords and web tokens are never stored or logged, and tracers redact tokens, Relay tickets and ciphertext. A Relay ticket is sent only on the node's data socket, never on the Control socket.
- Noise IK authenticates both sides against keys distributed by the Server. **E2EE does not protect against a malicious Server on first contact**: the first pin trusts the Server's descriptor, and the fingerprint is only 48 bits. Pins fail closed afterwards. Upstream Hosts auto-trust any client of the same account, so an account takeover equals Host access. There is no rekey yet (upstream roadmap).
- Replay protection: the Relay `counter` must equal the next Noise receive nonce. Duplicates, reorders, forgeries, bad fragments and unknown message types close the channel.

## Architecture

```
RemoteAccount ─ RemoteServerApi (REST /api/v1)
      │ connectHost
      ▼
RemoteTunnelCarrier (DshCarrier) ── DshClient / DshRpc / DshMux (package:dsh_client)
      │ RemoteHostSession per connection
      ▼
RemoteRpcClient (rpc.request/response/error, events, 128 pending, deadlines)
      ▼
SecureChannel (Noise IK initiator, DSHF fragments, ordered sends, fail closed)
      ▼
SecureHandshakeTransport ◀── RelayTransport (Control WS: hello, connect, handshake, ping/pong, signaling;
                         │    relay on the Control WS, or on the Relay node data WS when assigned)
                         ◀── WebRtcTransport (LAN / P2P / TURN: ciphertext on the DataChannel "dsh",
                                              signaling and handshake on RelayTransport's Control WS)
                                  ▼
                              RemotePeerConnection (implemented by the app over flutter_webrtc)
```

Nothing above `SecureHandshakeTransport` knows which path a connection took.

Performance: crypto is pure Dart (`cryptography` 2.9 ChaCha20-Poly1305 and X25519, `crypto` SHA-256/HMAC) and runs synchronously on the calling isolate. A desktop JIT runs it at about 55 MB/s, so a 4 MiB message costs about 75 ms each way. Chat traffic is negligible. Large image transfers on low-end phones may be worth moving to an isolate later.

## Tests

```bash
dart test                      # Noise vectors, protocol conformance, DSHF, RTCH, fake Server+Host(+WebRTC) carrier tests
tool/e2e/run_e2e.sh            # real stack, isolated temp HOME/DSH_HOME, loopback only, no prompts
```

`run_e2e.sh` bundles upstream `apps/server` from a checkout (`UPSTREAM`, default `../../.refs/ds-harness-remote-upstream`) with esbuild. It installs `ds-harness-remote@$PLUGIN_VERSION` (default 0.5.23) from npm, or `PLUGIN_SPEC`, into a fresh DSH profile and points that profile at the local Server with a profile `cordis.patch.yml`. Terminal, Codex and ACP are disabled there; the bundled patch hard-codes `https://dsh.r2049.cn`, so the override is required. It pre-provisions the Host credentials (`tool/e2e/provision-host.mjs`; the plugin CLI only does QR or code login), starts `dsh web` (`DSH_BIN` selects the version) and runs `test/live_remote_test.dart`. That test covers connect, list/create/rename/archive sessions, live follow events, model/permission/key, workspaces, host events, the transfer path, reconnect/resync and token rotation. The open-source Server has no Relay node, so `RELAY_ATTACH=1` mounts `tool/e2e/relay-node.ts` on it (`tool/e2e/patch-relay-attach.mjs`): the Server then negotiates `transport.relay.attach`, and the run fails unless both sides attached, answered the node's ping and sent frames through it. That mode needs a 0.6.0 Host plugin.

Both the published 0.5.23 Host and the 0.6.0 source expose the WebRTC answering path: they lazily load native `@roamhq/wrtc`, falling back to bundled werift. STUN/TURN configuration comes from the authorized connection's `/api/v1/turn/credentials` response; it is not hard-coded in the app.

The open-source Server is Relay-only too, so `WEBRTC=1` patches it to negotiate `transport.lan/p2p/turn`, send `webrtcEnabled: true` and forward `signal.*` / `transport.selected` like the hosted one (`tool/e2e/patch-webrtc.mjs`; no STUN or TURN servers). The Dart VM has no WebRTC stack, so the live test still connects through the Relay; `SERVE=1` keeps the stack up instead, and `tool/e2e/p2p_emulator.sh` runs the app's probe build (`lib/dev/remote_p2p_probe_main.dart`, real flutter_webrtc) on an emulator against it and fails unless the tunnel took a direct path and the Host bound its Noise channel to WebRTC. `PLUGIN_OPTIONAL=1` installs the plugin's optional `@roamhq/wrtc` (native libwebrtc on the Host); without it the Host uses its bundled werift.

The Android 35 x86_64 probe completed both P2P and direct-disabled Relay modes. The oversized 120 KiB search request returned the Host's expected 500-character validation error after reassembly; this verifies transport delivery, not acceptance of an oversized search. Each mode also received a 38,328-byte settings response and completed 20 round trips. The dependency-only release APK comparison adds **16.467 MiB per ABI** (arm64 and x64); these are comparison artifacts, not the final full-runtime APK sizes. Exact observations, artifact hashes and remaining validation boundaries are in [VERIFICATION.md](VERIFICATION.md).

`bin/remote_probe.dart` is an interactive CLI: `--server`, `--email` (password in `DSH_REMOTE_PASSWORD`) or QR sign-in, `--state` file, `--create-session --cwd`, `--watch-seconds`, `--reconnect-test`, `--trace`. It never sends prompts.

Not covered live: TURN, WAN/NAT traversal, direct-failure Relay fallback, approvals and questions over `$events` (they need a model prompt; the fake-Host test covers them), the hosted `dsh.r2049.cn` QR flow (needs a real account; it matches the upstream Android and plugin code and runs against the fake Server), and physical-device behavior.

## License and attribution

Protocol, framing, validation and connection logic are ported from ds-harness-remote, Copyright (c) 2026 DSH Remote contributors, MIT. The full text is in [LICENSE-ds-harness-remote](LICENSE-ds-harness-remote), and each ported file names its upstream source. The Noise state machine is our own implementation, with the author's agreement, and is verified against the upstream golden vectors. Fixtures under `test/fixtures` are copied from upstream.

The optional Flutter app adapter bundles native dependencies even when the direct-path preference is off. Their verified attribution sources and the **unfinished final native-library license audit** are recorded in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md#webrtc-150787104-核对记录2026-10-30); the top-level WebRTC BSD license does not cover every linked third-party component.
