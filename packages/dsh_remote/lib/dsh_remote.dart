/// Pure-Dart client for ds-harness-remote (https://github.com/liguobao/ds-harness-remote,
/// MIT): reach a remote Host's DSH Harness API through the Server Relay, or
/// directly over WebRTC, with end-to-end Noise IK encryption, using the same
/// `DshClient` API as the local engine.
///
/// Entry point: [RemoteAccount] (sign-in, Host list, [RemoteAccount.connectHost]).
///
/// Layers, lowest first:
/// * [RemoteServerApi] — REST (`/api/v1/*`): providers, QR / password
///   login, device registration, token refresh, Host directory.
/// * [RelayTransport] — Control WebSocket: hello, connect, relay frames,
///   ping/pong, WebRTC signaling.
/// * [WebRtcTransport] — LAN / P2P / TURN: Noise ciphertext over a
///   DataChannel of a platform [RemotePeerConnection] (flutter_webrtc in the
///   app), falling back to the Relay.
/// * [NoiseIkSession] + [SecureChannel] — `Noise_IK_25519_ChaChaPoly_SHA256`,
///   DSHF fragmentation, replay protection.
/// * [RemoteRpcClient] — Remote message RPC correlation and events.
/// * [RemoteTunnelCarrier] — `DshCarrier` mapping `DshRpc` / `DshMux` onto
///   `harness.remote.call` / `harness.remote.stream.*`.
library;

export 'package:dsh_client/dsh_client.dart';

export 'src/account/remote_account.dart'
    show
        HostTrustPrompt,
        RemoteAccount,
        RemoteHost,
        RemoteHostTrust,
        RemoteLogin,
        RemotePairedHost,
        RemotePairing,
        RemoteUser;
export 'src/account/secret_store.dart';
export 'src/carrier/tunnel_carrier.dart';
export 'src/channel/rpc_client.dart';
export 'src/dsh_web.dart';
export 'src/session_transfer.dart';
export 'src/channel/secure_channel.dart';
export 'src/crypto/noise_ik.dart'
    show
        NoiseIkSession,
        NoiseRole,
        NoiseSessionError,
        X25519KeyPair,
        createNoisePrologue,
        formatFingerprint,
        identityFingerprint,
        noiseIkProtocol;
export 'src/pairing/device_pairing.dart';
export 'src/protocol/control.dart' show ControlFrame, ControlFrameLimits, ProtocolError, protocolVersion;
export 'src/protocol/messages.dart' show RemoteMessage, SecureMessageCodec, maxSecureMessageBytes;
export 'src/server/server_api.dart';
export 'src/state.dart';
export 'src/transport/peer_connection.dart';
export 'src/transport/relay_transport.dart';
export 'src/transport/transport.dart';
export 'src/transport/webrtc_transport.dart';
