/// Data-plane abstraction under the Noise secure channel.
///
/// Every transport delivers opaque Noise messages between this client and
/// one Host connection authorized by the Server (`connect.accepted`), and
/// relays the two Noise handshake messages (always over the Server Control
/// channel). Implementations:
///
/// * [RelayTransport] — ciphertext inside `relay` frames, on the Control
///   socket or on the Relay node data socket the Server assigns;
/// * [WebRtcTransport] — LAN / P2P / TURN: a DataChannel named `dsh`
///   (`ordered: true`) carrying binary ciphertext, negotiated with
///   `signal.offer/answer/ice` and announced with `transport.selected`
///   before the handshake; a failed attempt falls back to the Relay.
///
/// Both implement this interface, so the secure channel, RPC layer and
/// carrier do not change.
library;

import 'dart:typed_data';

import 'relay_transport.dart' show RelayTransport;
import 'webrtc_transport.dart' show WebRtcTransport;

/// Data plane in use; mirrors the `transport.selected` vocabulary.
enum RemoteTransportMode { lan, p2p, turn, relay }

enum RemoteIpVersion { ipv4, ipv6 }

enum RemoteIceProtocol { udp, tcp }

/// Selected ICE pair metadata only; never retains candidate addresses or URLs.
class RemotePeerNetworkInfo {
  const RemotePeerNetworkInfo({this.localIpVersion, this.remoteIpVersion, this.protocol});

  final RemoteIpVersion? localIpVersion;
  final RemoteIpVersion? remoteIpVersion;
  final RemoteIceProtocol? protocol;
}

/// Payload-free reasons for trying a less preferred data plane.
enum RemoteNetworkFallbackReason {
  webrtcUnavailable,
  directFailed,
  directTimeout,
  directRecentlyFailed,
  turnUnavailable,
  turnFailed,
  turnTimeout,
  pathUnverified,
}

/// A snapshot of the actual data plane. No SDP, candidate addresses, relay
/// URLs, credentials or exception text is exposed. Unknown stats stay null.
class RemoteNetworkDiagnostics {
  const RemoteNetworkDiagnostics({
    required this.transportMode,
    required this.observedAt,
    this.connectionDuration,
    this.roundTripTime,
    this.fallbackReason,
    this.peerNetwork,
  });

  final RemoteTransportMode? transportMode;
  final Duration? connectionDuration;
  final Duration? roundTripTime;
  final RemoteNetworkFallbackReason? fallbackReason;
  final RemotePeerNetworkInfo? peerNetwork;
  final DateTime observedAt;
}

/// Identities bound into the Noise prologue.
class RemoteConnectionInfo {
  const RemoteConnectionInfo({required this.connectionId, required this.localDeviceId, required this.remoteDeviceId});

  final String connectionId;
  final String localDeviceId;
  final String remoteDeviceId;
}

/// Why a transport ended. [code] uses the protocol error vocabulary
/// (`CONNECTION_FAILED`, `CONNECTION_REPLACED`, `AUTH_INVALID`,
/// `TOKEN_EXPIRED`, `HOST_OFFLINE`, `SECURE_CHANNEL_FAILED`, ...).
class RemoteTransportClosed {
  const RemoteTransportClosed(this.code, this.message, {this.retryable = true, this.closeCode});

  final String code;
  final String message;
  final bool retryable;

  /// WebSocket close code when the Server closed the Control socket.
  final int? closeCode;

  @override
  String toString() => 'RemoteTransportClosed($code${closeCode == null ? '' : ' ws=$closeCode'}): $message';
}

typedef TransportDataHandler = void Function(Uint8List ciphertext, int? counter);
typedef TransportHandshakeHandler = void Function(int step, Uint8List data);
typedef TransportClosedHandler = void Function(RemoteTransportClosed reason);

/// One authorized Host connection's data plane plus handshake relay.
abstract class SecureHandshakeTransport {
  RemoteTransportMode get mode;

  RemoteConnectionInfo get info;

  /// Registers the handlers. Frames that arrived earlier are delivered now,
  /// in order. [onClosed] fires once, unless [close] was called first.
  void listen({
    required TransportDataHandler onData,
    required TransportHandshakeHandler onHandshake,
    required TransportClosedHandler onClosed,
  });

  /// Sends Noise handshake message [step] (1 from the client).
  Future<void> sendHandshake(int step, Uint8List data);

  /// Sends one Noise transport message. [counter] is the Noise nonce it was
  /// encrypted with; the Relay frame carries it and the Host requires it to
  /// match its receive nonce.
  Future<void> send(Uint8List ciphertext, {required int counter});

  Future<void> close();
}

/// Optional lifecycle hooks for transports with lease-backed Control recovery.
/// The secure-channel owner marks readiness only after registering its receiver.
abstract interface class LeaseAwareTransport implements SecureHandshakeTransport {
  void markSecureReady();

  /// Check Control liveness on foreground/network kicks, independent of RPC
  /// traffic on a still healthy data plane.
  void checkControlHealth();
}

/// Thrown while establishing a transport (Control handshake, connect
/// request). [code] as in [RemoteTransportClosed].
class RemoteTransportException implements Exception {
  const RemoteTransportException(this.code, this.message, {this.retryable = true, this.closeCode});

  final String code;
  final String message;
  final bool retryable;
  final int? closeCode;

  @override
  String toString() => 'RemoteTransportException($code): $message';
}
