/// Connection states and failures surfaced to the app.
library;

/// Why a remote connection attempt failed or a live one dropped.
///
/// [code] values:
/// * transient (the client keeps retrying): `HOST_OFFLINE`,
///   `CONNECTION_FAILED`, `SECURE_CHANNEL_FAILED`, `RPC_TIMEOUT`,
///   `RATE_LIMITED`, `TOKEN_EXPIRED`;
/// * terminal (user action needed): `ACCOUNT_AUTH_REQUIRED` (sign in
///   again), `PEER_IDENTITY_MISMATCH` (the Host's key changed; see
///   `RemoteAccount.forgetHost`), `HOST_NOT_TRUSTED` (first-use confirmation
///   declined), `CONNECTION_REPLACED` (another client of this device took
///   over), `CONNECTION_REJECTED` (the Host refused this client),
///   `HARNESS_VERSION_INCOMPATIBLE` (Host plugin / DSH too old or too new),
///   `MEMBERSHIP_REQUIRED`, `DEVICE_NOT_FOUND`, `DEVICE_REVOKED`.
class RemoteFailure {
  const RemoteFailure(this.code, this.message, {required this.retryable});

  final String code;

  /// English diagnostic; map [code] to UI text instead of showing this.
  final String message;
  final bool retryable;

  @override
  String toString() => 'RemoteFailure($code${retryable ? '' : ', terminal'}): $message';
}

/// Thrown by `RemoteAccount.connectHost` and account operations.
class RemoteConnectException implements Exception {
  const RemoteConnectException(this.failure);

  final RemoteFailure failure;

  String get code => failure.code;

  @override
  String toString() => 'RemoteConnectException(${failure.code}): ${failure.message}';
}

enum RemoteConnectionPhase {
  /// First attempt in progress.
  connecting,

  /// Secure channel up and the Host's `$events` stream is ready, including
  /// Control-only recovery while the same data plane remains usable.
  connected,

  /// The link dropped or an attempt failed; retrying with backoff
  /// ([RemoteConnectionState.failure] says why).
  reconnecting,

  /// Stopped: needs user action ([RemoteConnectionState.failure]).
  failed,

  /// Closed by the app.
  closed,
}

class RemoteConnectionState {
  const RemoteConnectionState(this.phase, {required this.hostId, this.failure, this.transport, this.at});

  final RemoteConnectionPhase phase;
  final String hostId;

  /// Last failure for `reconnecting` / `failed` (may also accompany
  /// `connecting` after a failed first attempt).
  final RemoteFailure? failure;

  /// Data plane of a connected state: `lan`, `p2p`, `turn` (WebRTC) or
  /// `relay`.
  final String? transport;
  final DateTime? at;

  bool get isConnected => phase == RemoteConnectionPhase.connected;

  @override
  String toString() =>
      'RemoteConnectionState(${phase.name}${transport == null ? '' : ' via $transport'}${failure == null ? '' : ', $failure'})';
}
