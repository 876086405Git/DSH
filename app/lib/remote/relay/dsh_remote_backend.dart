import 'dart:async';
import 'dart:io' show Platform;

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import '../../secrets/secure_storage.dart';
import '../link_status.dart';
import '../secret_store.dart';
import 'relay_backend.dart';
import 'network_route.dart';

/// [RelayBackend] over `packages/dsh_remote` (ds-harness-remote by 李国宝:
/// account login, Host directory with key pinning, Noise IK over the Relay).
///
/// Host trust works like SSH: a Host seen for the first time is only pinned
/// after the person confirmed its fingerprint in the UI ([approveHost]); a
/// changed key fails closed until [forgetHost].
///
/// [direct] (直连优先) lets connections try LAN / P2P / TURN over
/// [peerConnector] (flutter_webrtc) before the Server's relay.
class DshRemoteRelayBackend implements RelayBackend, RelayNetworkBackend, RelayPairingBackend {
  DshRemoteRelayBackend({
    required SecretStore secrets,
    Object? serverUrl,
    String clientVersion = '0.1.0',
    remote.RemoteAccount? account,
    this.peerConnector,
    bool direct = true,
    Future<RemoteNetworkRoute> Function()? resolveNetworkRoute,
    this._loadCompactHistory,
  }) : _resolveNetworkRoute = resolveNetworkRoute ?? resolveRemoteNetworkRoute,
       account =
           account ??
           remote.RemoteAccount(
             secrets: _Secrets(secrets),
             serverUrl: serverUrl,
             deviceName: switch (Platform.operatingSystem) {
               'ohos' => 'DSH App (HarmonyOS)',
               'ios' => 'DSH App (iOS)',
               _ => 'DSH App (Android)',
             },
             platform: 'dsh-app-android',
             clientVersion: clientVersion,
             onDirectFallback: (_) => debugPrint('[dsh-remote] automatic transport fallback'),
           ) {
    this.direct = direct;
    if (account == null) {
      this.account.preferredTransports = () async {
        final route = await _resolveNetworkRoute();
        _networkRoute = route;
        return transportsForRemoteRoute(route);
      };
    }
  }

  final remote.RemoteAccount account;
  final Future<bool> Function()? _loadCompactHistory;
  final Future<RemoteNetworkRoute> Function() _resolveNetworkRoute;
  RemoteNetworkRoute _networkRoute = RemoteNetworkRoute.unknown;
  final _sessionRoutes = Expando<RemoteNetworkRoute>('remote route');
  final _networkProbes = Expando<Future<bool>>('remote network probe');
  final _loggedSessions = Expando<bool>('logged remote network');

  /// The WebRTC stack [direct] connections use.
  final remote.RemotePeerConnector? peerConnector;

  /// Applies from the next (re)connect.
  set direct(bool enabled) => account.peerConnector = enabled ? peerConnector : null;

  /// Applies to the next client, without disturbing live streams or its reconnects.
  set compactHistory(bool enabled) => account.compactHistory = enabled;

  /// Reconnects back off to a minute: a sleeping computer isn't polled every
  /// few seconds (network changes and 重试 still connect at once).
  static const _muxOptions = MuxOptions(
    retryCaps: [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
  );

  /// Last listing, so [connectHost] gets the full `RemoteHost` back.
  final Map<String, remote.RemoteHost> _hosts = {};

  /// Fingerprints the person confirmed in the UI, by Host id. A first connect
  /// pins only a key whose fingerprint is exactly the one they saw.
  final Map<String, String> _approved = {};

  /// The server's origin (`https://dsh.r2049.cn`), or a [HostLinkError] for
  /// something that isn't one (self-hosted servers: HTTPS, or HTTP on a
  /// private address).
  static String normalizeServer(String input) {
    try {
      return remote.normalizeServerUrl(input).origin;
    } on ArgumentError {
      throw HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrInvalidServer);
    }
  }

  @override
  bool get available => true;

  @override
  String get serverLabel => account.serverUrl.host;

  @override
  Future<RelayUser?> currentUser() => _map(() async {
    final user = await account.currentUser();
    return user == null ? null : _user(user);
  });

  @override
  Future<List<RelayAuthProvider>> loginProviders() => _map(() async {
    final providers = await account.loginProviders();
    return [for (final p in providers) RelayAuthProvider(id: p.id, displayName: p.displayName)];
  });

  @override
  Future<RelayLoginSession> login({String? providerId}) => _map(() async {
    final login = await account.startLogin(providerId: providerId);
    return RelayLoginSession(
      loginUrl: login.loginUrl,
      completed: _map(() async => _user(await login.result)),
      onCancel: login.cancel,
    );
  });

  @override
  Future<RelayUser> loginWithPassword(String email, String password) async {
    try {
      return _user(await account.loginWithPassword(email, password));
    } on remote.RemoteConnectException catch (e) {
      final code = e.failure.code;
      if (code.contains('AUTH') || code.contains('CREDENTIAL') || code == 'UNAUTHORIZED') {
        throw HostLinkError(
          HostLinkErrorKind.authFailed,
          appL10n.remoteErrEmailPassword,
          detail: '$code: ${e.failure.message}',
        );
      }
      throw describe(e.failure);
    }
  }

  @override
  Future<void> logout() => _map(() => account.logout());

  @override
  Future<List<RelayHost>> listHosts({bool refresh = false}) => _map(() async {
    final hosts = await account.listHosts();
    _hosts
      ..clear()
      ..addEntries(hosts.map((h) => MapEntry(h.id, h)));
    return [for (final h in hosts) _host(h)];
  });

  @override
  void approveHost(RelayHost host) {
    final fp = host.fingerprint;
    if (fp != null) _approved[host.id] = fp;
  }

  @override
  Future<void> forgetHost(RelayHost host) async {
    await account.forgetHost(host.id);
    approveHost(host);
  }

  /// Whether a first connect may pin [fingerprint] for [hostId]: only the
  /// exact key the person confirmed.
  bool approves(String hostId, String? fingerprint) => fingerprint != null && _approved[hostId] == fingerprint;

  @override
  bool reconnect(DshClient client) {
    final carrier = client.remoteCarrier;
    if (carrier == null || carrier.isClosed) return false;
    carrier.reconnect();
    return true;
  }

  @override
  Future<bool> probe(DshClient client) =>
      _networkProbes[client] ??= _probeNetwork(client).whenComplete(() => _networkProbes[client] = null);

  Future<bool> _probeNetwork(DshClient client) async {
    final carrier = client.remoteCarrier;
    final session = carrier?.session;
    if (carrier == null || session == null || session.isClosed) return true;
    final previous = _sessionRoutes[session] ?? _networkRoute;
    final next = await _resolveNetworkRoute();
    if (carrier.session != session || session.isClosed) return true;
    if (next != RemoteNetworkRoute.unknown) _sessionRoutes[session] = next;
    if (shouldRenegotiateRemoteRoute(previous, next)) {
      carrier.reconnect();
      return false;
    }
    return carrier.probe();
  }

  @override
  RelayPath? pathOf(DshClient client) {
    final session = client.remoteCarrier?.session;
    if (session == null || session.isClosed) return null;
    if (session.networkDiagnostics case final snapshot?) return _network(snapshot).path;
    return switch (session.transport) {
      'lan' => RelayPath.lan,
      'p2p' => RelayPath.p2p,
      'turn' => RelayPath.turn,
      'relay' => RelayPath.relay,
      _ => null,
    };
  }

  @override
  RemoteNetworkStatus? networkOf(DshClient client) {
    final session = client.remoteCarrier?.session;
    if (session != null) _sessionRoutes[session] ??= _networkRoute;
    final snapshot = session?.networkDiagnostics;
    if (session == null || session.isClosed || snapshot == null) return null;
    final value = _network(snapshot);
    if (_loggedSessions[session] != true) {
      _loggedSessions[session] = true;
      _logNetwork(value);
    }
    return value;
  }

  @override
  Future<RemoteNetworkStatus?> inspectNetwork(DshClient client) async {
    final carrier = client.remoteCarrier;
    final session = carrier?.session;
    if (session == null || session.isClosed) return null;
    final inspect = session.inspectNetwork;
    final snapshot = inspect == null ? session.networkDiagnostics : await inspect();
    if (carrier?.session != session || session.isClosed || snapshot == null) return null;
    final value = _network(snapshot);
    _logNetwork(value);
    return value;
  }

  static void _logNetwork(RemoteNetworkStatus value) {
    debugPrint(
      '[dsh-remote] transport=${value.path?.name ?? 'unknown'} '
      'setupMs=${value.connectDuration?.inMilliseconds ?? 'unknown'} '
      'rttMs=${value.roundTripTime?.inMilliseconds ?? 'unmeasured'} '
      'fallback=${value.safeFallbackReason ?? 'none'}',
    );
  }

  static RemoteNetworkStatus _network(remote.RemoteNetworkDiagnostics snapshot) => RemoteNetworkStatus(
    path: switch (snapshot.transportMode) {
      remote.RemoteTransportMode.lan => RelayPath.lan,
      remote.RemoteTransportMode.p2p => RelayPath.p2p,
      remote.RemoteTransportMode.turn => RelayPath.turn,
      remote.RemoteTransportMode.relay => RelayPath.relay,
      null => null,
    },
    connectDuration: snapshot.connectionDuration,
    roundTripTime: snapshot.roundTripTime,
    fallbackReason: snapshot.fallbackReason?.name,
    observedAt: snapshot.observedAt,
    localIpVersion: switch (snapshot.peerNetwork?.localIpVersion) {
      remote.RemoteIpVersion.ipv4 => NetworkIpVersion.ipv4,
      remote.RemoteIpVersion.ipv6 => NetworkIpVersion.ipv6,
      null => null,
    },
    remoteIpVersion: switch (snapshot.peerNetwork?.remoteIpVersion) {
      remote.RemoteIpVersion.ipv4 => NetworkIpVersion.ipv4,
      remote.RemoteIpVersion.ipv6 => NetworkIpVersion.ipv6,
      null => null,
    },
    iceProtocol: switch (snapshot.peerNetwork?.protocol) {
      remote.RemoteIceProtocol.udp => NetworkIceProtocol.udp,
      remote.RemoteIceProtocol.tcp => NetworkIceProtocol.tcp,
      null => null,
    },
  );

  @override
  Future<DshClient> connectHost(RelayHost host, {RelayStateCallback? onState}) => _map(() async {
    var target = _hosts[host.id];
    if (target == null) {
      await listHosts();
      target = _hosts[host.id];
    }
    if (target == null) {
      throw HostLinkError(HostLinkErrorKind.notLoggedIn, appL10n.remoteErrHostNotInAccount);
    }
    final loadCompactHistory = _loadCompactHistory;
    if (loadCompactHistory != null) account.compactHistory = await loadCompactHistory();
    return account.connectHost(
      target,
      muxOptions: _muxOptions,
      timeout: const Duration(seconds: 45),
      confirmNewHost: (h) async => approves(h.id, h.fingerprint),
      onState: onState == null
          ? null
          : (s) => onState(_state(s.phase), s.failure == null ? null : describe(s.failure!, host.name)),
    );
  }, hostName: host.name);

  Future<void> close() => account.close();

  // ---------------------------------------------------------------------------
  // Scan-to-pair

  @override
  Future<bool> supportsPairing() async {
    try {
      return await account.supportsPairing();
    } on Object {
      return false;
    }
  }

  @override
  Future<RelayPairingOffer> resolvePairing(String scanned) => _pairing(() async {
    final offer = await account.resolvePairing(remote.parsePairingScan(scanned));
    return RelayPairingOffer(
      server: offer.origin.toString(),
      hostName: offer.host.name,
      hostPlatform: offer.host.platform,
      fingerprint: offer.host.fingerprint,
      token: offer,
    );
  });

  @override
  Future<RelayPairingSession> claimPairing(RelayPairingOffer offer, {String? deepseekUserId}) => _pairing(() async {
    final token = offer.token;
    if (token is! remote.PairingOffer) throw ArgumentError.value(offer, 'offer');
    final pairing = await account.claimPairing(token, deepseekUserId: deepseekUserId);
    return RelayPairingSession(
      code: pairing.verificationCode,
      codeExpiresAt: pairing.codeExpiresAt,
      phases: pairing.states.where((s) => s == remote.PairingState.approved).map((_) => RelayPairingPhase.approved),
      completed: _pairing(() async {
        final paired = await pairing.result;
        // The paired Host is already pinned; list it with presence. The new
        // membership can take a moment to show in the directory: look again
        // briefly. Connecting lists once more and still checks the
        // authorized descriptor and the pin.
        for (var attempt = 0; attempt < 4; attempt++) {
          if (attempt > 0) await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
          final hosts = await listHosts(refresh: true).catchError((Object _) => const <RelayHost>[]);
          final listed = hosts.where((h) => h.id == paired.host.deviceId).firstOrNull;
          if (listed != null) return listed;
        }
        return RelayHost(
          id: paired.host.deviceId,
          name: paired.host.name,
          online: true,
          platform: paired.host.platform,
          fingerprint: remote.formatFingerprint(remote.identityFingerprint(paired.host.identityKey)),
        );
      }),
      onPause: (paused) => pairing.paused = paused,
      onCancel: pairing.cancel,
    );
  });

  static Future<T> _pairing<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on remote.PairingException catch (e) {
      throw describePairing(e.code, e.message, server: e.origin?.toString());
    } on remote.RemoteConnectException catch (e) {
      throw describePairing(e.failure.code, e.failure.message);
    }
  }

  /// UI text for a pairing failure code (Server or local).
  static RelayPairingError describePairing(String code, String message, {String? server}) {
    RelayPairingError e(RelayPairingErrorKind kind, String text) =>
        RelayPairingError(kind, text, server: server, detail: '$code: $message');
    return switch (code) {
      'PAIRING_SCAN_INVALID' => e(RelayPairingErrorKind.invalidCode, appL10n.remotePairErrInvalidCode),
      'PAIRING_SERVER_MISMATCH' => e(RelayPairingErrorKind.otherServer, appL10n.remotePairErrOtherServer),
      'PAIRING_UNSUPPORTED' ||
      'PAIRING_REQUIRED' => e(RelayPairingErrorKind.unsupported, appL10n.remotePairErrUnsupported),
      'PAIRING_NOT_FOUND' ||
      'PAIRING_EXPIRED' ||
      'PAIRING_CLOSED' => e(RelayPairingErrorKind.expired, appL10n.remotePairErrExpired),
      'PAIRING_CODE_REJECTED' ||
      'PAIRING_ATTEMPT_USED' => e(RelayPairingErrorKind.codeRejected, appL10n.remotePairErrCodeRejected),
      'PAIRING_CANCELLED' => e(RelayPairingErrorKind.cancelled, appL10n.remotePairErrCancelled),
      'PAIRING_ACCOUNT_CONFLICT' => e(RelayPairingErrorKind.accountConflict, appL10n.remotePairErrAccountConflict),
      'PAIRING_IDENTITY_MISMATCH' ||
      'PAIRING_PROOF_INVALID' ||
      'PAIRING_SCAN_INVALID_PROOF' ||
      'PAIRING_DEVICE_CONFLICT' => e(RelayPairingErrorKind.identityMismatch, appL10n.remotePairErrIdentity),
      'HOST_DEVICE_LIMIT_REACHED' => e(RelayPairingErrorKind.other, appL10n.remotePairErrHostLimit),
      'PAIRING_PIN_SAVE_FAILED' => e(RelayPairingErrorKind.other, appL10n.remotePairErrPinSave),
      'RATE_LIMITED' || 'PAIRING_BUSY' => e(RelayPairingErrorKind.network, appL10n.remoteErrTooManyRequests),
      'CONNECTION_FAILED' ||
      'AUTHORIZATION_SYNC_PENDING' => e(RelayPairingErrorKind.network, appL10n.remotePairErrNetwork),
      _ => e(RelayPairingErrorKind.other, appL10n.remotePairErrFailed),
    };
  }

  // ---------------------------------------------------------------------------

  static RelayUser _user(remote.RemoteUser user) =>
      RelayUser(id: user.deviceId, displayName: user.account, provider: user.provider);

  static RelayHost _host(remote.RemoteHost h) => RelayHost(
    id: h.id,
    name: h.name,
    online: h.online,
    platform: h.platform,
    harnessVersion: h.harnessVersion,
    fingerprint: h.fingerprint,
    trust: switch (h.trust) {
      remote.RemoteHostTrust.pinned => RelayTrust.pinned,
      remote.RemoteHostTrust.unpinned => RelayTrust.unpinned,
      remote.RemoteHostTrust.keyChanged => RelayTrust.keyChanged,
      remote.RemoteHostTrust.unknown => RelayTrust.unknown,
    },
  );

  static RelayConnectionState _state(remote.RemoteConnectionPhase phase) => switch (phase) {
    remote.RemoteConnectionPhase.connecting => RelayConnectionState.connecting,
    remote.RemoteConnectionPhase.connected => RelayConnectionState.connected,
    remote.RemoteConnectionPhase.reconnecting => RelayConnectionState.reconnecting,
    remote.RemoteConnectionPhase.failed => RelayConnectionState.failed,
    remote.RemoteConnectionPhase.closed => RelayConnectionState.disconnected,
  };

  /// Runs [action], turning `dsh_remote` failures into person-readable
  /// [HostLinkError]s.
  static Future<T> _map<T>(Future<T> Function() action, {String? hostName}) async {
    try {
      return await action();
    } on remote.RemoteConnectException catch (e) {
      throw describe(e.failure, hostName);
    }
  }

  // The server supplies arbitrary text; only known protocol codes cross into diagnostics.
  static HostLinkDiagnosticCode _diagnosticCode(String code) => switch (code) {
    'HOST_OFFLINE' => HostLinkDiagnosticCode.remoteHostOffline,
    'ACCOUNT_AUTH_REQUIRED' => HostLinkDiagnosticCode.remoteAccountAuthRequired,
    'DEVICE_REVOKED' => HostLinkDiagnosticCode.remoteDeviceRevoked,
    'TOKEN_EXPIRED' => HostLinkDiagnosticCode.remoteTokenExpired,
    'PEER_IDENTITY_MISMATCH' => HostLinkDiagnosticCode.remotePeerIdentityMismatch,
    'HOST_NOT_TRUSTED' => HostLinkDiagnosticCode.remoteHostNotTrusted,
    'CONNECTION_REPLACED' => HostLinkDiagnosticCode.remoteConnectionReplaced,
    'CONNECTION_REJECTED' => HostLinkDiagnosticCode.remoteConnectionRejected,
    'MEMBERSHIP_REQUIRED' => HostLinkDiagnosticCode.remoteMembershipRequired,
    'DEVICE_NOT_FOUND' => HostLinkDiagnosticCode.remoteDeviceNotFound,
    'HARNESS_VERSION_INCOMPATIBLE' => HostLinkDiagnosticCode.remoteHarnessVersionIncompatible,
    'PROTOCOL_MISMATCH' => HostLinkDiagnosticCode.remoteProtocolMismatch,
    'UNSUPPORTED_VERSION' => HostLinkDiagnosticCode.remoteUnsupportedVersion,
    'CAPABILITY_NOT_SUPPORTED' => HostLinkDiagnosticCode.remoteCapabilityNotSupported,
    'FRAME_TOO_LARGE' => HostLinkDiagnosticCode.remoteFrameTooLarge,
    'INVALID_MESSAGE' => HostLinkDiagnosticCode.remoteInvalidMessage,
    'SECURE_CHANNEL_FAILED' => HostLinkDiagnosticCode.remoteSecureChannelFailed,
    'RPC_TIMEOUT' => HostLinkDiagnosticCode.remoteRpcTimeout,
    'CONNECTION_FAILED' => HostLinkDiagnosticCode.remoteConnectionFailed,
    'RATE_LIMITED' => HostLinkDiagnosticCode.remoteRateLimited,
    'HISTORY_MODE_CHANGED' => HostLinkDiagnosticCode.remoteHistoryModeChanged,
    _ => HostLinkDiagnosticCode.unknown,
  };

  /// Chinese UI text for a `RemoteFailure.code` (see dsh_remote `state.dart`).
  static HostLinkError describe(remote.RemoteFailure failure, [String? hostName]) {
    final name = hostName == null ? appL10n.remoteHostFallback : appL10n.remoteQuotedHostName(hostName);
    final detail = '${failure.code}: ${failure.message}';
    HostLinkError e(HostLinkErrorKind kind, String message, {bool? retryable}) => HostLinkError(
      kind,
      message,
      detail: detail,
      retryable: retryable ?? failure.retryable,
      diagnosticCode: _diagnosticCode(failure.code),
    );
    return switch (failure.code) {
      'HOST_OFFLINE' => e(HostLinkErrorKind.hostOffline, appL10n.remoteErrHostOffline, retryable: true),
      'DEVICE_NOT_FOUND' => e(HostLinkErrorKind.other, appL10n.remoteErrHostRemoved(name)),
      'ACCOUNT_AUTH_REQUIRED' ||
      'DEVICE_REVOKED' ||
      'TOKEN_EXPIRED' when !failure.retryable => e(HostLinkErrorKind.notLoggedIn, appL10n.remoteErrRelaySignInExpired),
      'PEER_IDENTITY_MISMATCH' => e(HostLinkErrorKind.hostKeyMismatch, appL10n.remoteErrIdentityKeyChanged),
      'HOST_NOT_TRUSTED' => e(HostLinkErrorKind.hostKeyUnverified, appL10n.remoteErrIdentityUnconfirmed),
      'CONNECTION_REPLACED' => e(HostLinkErrorKind.other, appL10n.remoteErrConnectionReplaced),
      'HISTORY_MODE_CHANGED' => e(HostLinkErrorKind.other, appL10n.remoteErrHistoryModeChanged, retryable: false),
      'CONNECTION_REJECTED' => e(HostLinkErrorKind.other, appL10n.remoteErrHostRejected),
      'MEMBERSHIP_REQUIRED' => e(HostLinkErrorKind.other, appL10n.remoteErrHostNotOwned),
      // Version and protocol mismatches fail the same way on every attempt:
      // no reconnect loop (network changes don't fix them), 重试 still works.
      'HARNESS_VERSION_INCOMPATIBLE' => e(
        HostLinkErrorKind.other,
        appL10n.remoteErrVersionIncompatible,
        retryable: false,
      ),
      // PROTOCOL_MISMATCH: a relay Control frame this app cannot parse.
      // (INVALID_MESSAGE also covers REST replies that were not JSON, e.g. a
      // captive portal, so it keeps the generic text below.)
      'PROTOCOL_MISMATCH' ||
      'UNSUPPORTED_VERSION' ||
      'CAPABILITY_NOT_SUPPORTED' => e(HostLinkErrorKind.other, appL10n.remoteErrUpdateNeeded, retryable: false),
      'FRAME_TOO_LARGE' when !failure.retryable => e(HostLinkErrorKind.other, appL10n.remoteErrUpdateNeeded),
      'LOGIN_EXPIRED' => e(HostLinkErrorKind.other, appL10n.remoteErrSignInTimeout),
      'LOGIN_CANCELLED' => e(HostLinkErrorKind.other, appL10n.remoteSignInCancelled),
      'OAUTH_PROVIDER_UNAVAILABLE' => e(HostLinkErrorKind.unavailable, appL10n.remoteErrBrowserSignInUnsupported),
      'RATE_LIMITED' => e(HostLinkErrorKind.unreachable, appL10n.remoteErrTooManyRequests, retryable: true),
      _credentialsUnreadableCode => e(HostLinkErrorKind.other, appL10n.harmonyCredentialsUnreadableHint),
      _ when failure.retryable => e(HostLinkErrorKind.unreachable, appL10n.remoteErrHostUnreachable),
      _ => e(HostLinkErrorKind.other, appL10n.remoteErrRemoteConnection),
    };
  }
}

const _credentialsUnreadableCode = 'SECRETS_UNREADABLE';

/// dsh_remote's secret-store interface over the app's (Keystore-backed) one.
///
/// Credentials that can't be read leave as dsh_remote's own failure: anything
/// else it reports as a network problem, retried for ever.
class _Secrets implements remote.SecretStore {
  factory _Secrets(SecretStore inner) => _adapters[inner] ??= _Secrets._(inner);

  _Secrets._(this._inner);

  // Backend replacements still use the same package storage ownership scope.
  static final _adapters = Expando<_Secrets>();

  final SecretStore _inner;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      if (!credentialsUnreadable(e)) rethrow;
      throw remote.RemoteConnectException(
        remote.RemoteFailure(_credentialsUnreadableCode, 'Saved credentials unreadable', retryable: false),
      );
    }
  }

  @override
  Future<String?> read(String key) => _guard(() => _inner.read(key));

  @override
  Future<void> write(String key, String value) => _guard(() => _inner.write(key, value));

  @override
  Future<void> delete(String key) => _guard(() => _inner.delete(key));
}
