// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Account sign-in, device identity, Host directory/pinning and connect.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:dsh_client/dsh_client.dart';

import '../carrier/tunnel_carrier.dart';
import '../channel/rpc_client.dart';
import '../channel/secure_channel.dart';
import '../crypto/noise_ik.dart';
import '../protocol/control.dart' show maxRemoteCapabilityEntries;
import '../pairing/device_pairing.dart';
import '../server/server_api.dart';
import '../state.dart';
import '../transport/peer_connection.dart';
import '../transport/relay_transport.dart';
import '../transport/transport.dart';
import '../transport/webrtc_transport.dart';
import '../util/bytes.dart';
import 'secret_store.dart';

// Accounts using the same storage object and server keys share commit order.
// An Expando does not keep an otherwise unreachable SecretStore alive.
class _AccountStorageState {
  Future<void> credentialWrites = Future<void>.value();
  int signInEpoch = 0;
}

final _accountStorageStates = Expando<Map<String, _AccountStorageState>>();

/// The signed-in account on one Server.
class RemoteUser {
  const RemoteUser({required this.account, required this.deviceId, required this.serverUrl, this.provider});

  /// Account name (email or OAuth account id) as the Server reports it.
  final String account;

  /// This app's client device id on the Server.
  final String deviceId;
  final Uri serverUrl;

  /// The provider this device signed in with (github, zhihu, google, password);
  /// null for credentials stored before providers were recorded.
  final String? provider;

  @override
  String toString() => 'RemoteUser($account on $serverUrl)';
}

enum RemoteHostTrust {
  /// Pinned identity key matches the Server descriptor.
  pinned,

  /// Never connected: the key will be pinned on first connect.
  unpinned,

  /// The Server now reports a different key than the pinned one: connecting
  /// fails closed until the user re-trusts it ([RemoteAccount.forgetHost]).
  keyChanged,

  /// The descriptor could not be fetched.
  unknown,
}

/// A Host this account may connect to.
class RemoteHost {
  const RemoteHost({
    required this.id,
    required this.name,
    required this.platform,
    required this.online,
    required this.trust,
    this.harnessVersion,
    this.pluginVersion,
    this.lastSeenAt,
    this.identityKey,
    this.pinnedIdentityKey,
    this.membershipId,
  });

  /// Host device id.
  final String id;

  /// Untrusted display name (escape / truncate in UI).
  final String name;

  /// `linux`, `darwin`, `win32`, ...
  final String platform;
  final bool online;

  /// DSH (Harness) version running on the Host, when reported.
  final String? harnessVersion;

  /// ds-harness-remote plugin version on the Host.
  final String? pluginVersion;
  final DateTime? lastSeenAt;

  /// Noise static key from the Server descriptor.
  final String? identityKey;

  /// Key pinned on this device, if any.
  final String? pinnedIdentityKey;
  final RemoteHostTrust trust;
  final String? membershipId;

  /// `ABCD EF01 2345` of [identityKey] (compare with the Host's display).
  String? get fingerprint => identityKey == null ? null : formatFingerprint(identityFingerprint(identityKey!));

  @override
  String toString() => 'RemoteHost($name, $id, ${online ? 'online' : 'offline'}, ${trust.name})';
}

/// Decides whether to trust a Host seen for the first time (show
/// [RemoteHost.fingerprint] and ask the user). Return `false` to refuse.
typedef HostTrustPrompt = Future<bool> Function(RemoteHost host);

/// An in-progress QR / browser sign-in.
///
/// Open [loginUrl] in a Custom Tab or the browser (or render it as a QR
/// code for another phone); [result] completes once the account authorized
/// this device, polling the Server every 2 s until [expiresAt].
class RemoteLogin {
  RemoteLogin._(this.loginUrl, this.providerId, this.expiresAt, this._result, this._cancel);

  final Uri loginUrl;
  final String providerId;
  final DateTime expiresAt;
  final Future<RemoteUser> _result;
  final void Function() _cancel;

  /// Completes with the signed-in user, or fails with
  /// [RemoteConnectException] (`LOGIN_EXPIRED`, `LOGIN_CANCELLED`, ...).
  Future<RemoteUser> get result => _result;

  /// Cancels before the local credential write starts; [result] then fails
  /// with `LOGIN_CANCELLED`. Once that atomic write has started, cancellation
  /// cannot undo it and [result] reports the actual commit outcome.
  /// Registration already processed by the Server is not revoked.
  void cancel() => _cancel();
}

/// The computer a finished pairing bound this phone to, and the account the
/// phone is now signed in to.
class RemotePairedHost {
  const RemotePairedHost({required this.user, required this.host});

  final RemoteUser user;

  /// The Host from the scanned code (its key is pinned already).
  final PairingDevice host;
}

/// A claimed pairing session: show [verificationCode] until the person typed
/// it into the computer's Remote plugin; [result] completes once this phone's
/// credentials are stored and the Host key is pinned.
///
/// The phone never confirms for the computer. The code has one attempt: a
/// wrong one on the computer ends the session ([result] fails with
/// `PAIRING_CODE_REJECTED`) and the whole scan starts over.
class RemotePairing {
  RemotePairing._(this.offer, this.mobile, this._claim, this._sendCancel);

  final PairingOffer offer;

  /// This phone's device as the session knows it.
  final PairingDevice mobile;
  final PairingClaim _claim;
  final Future<void> Function() _sendCancel;
  final Completer<RemotePairedHost> _result = Completer();
  final StreamController<PairingState> _states = StreamController.broadcast();
  PairingState _state = PairingState.claimed;
  bool _committing = false;
  bool _paused = false;
  Completer<void>? _resumed;

  /// Exactly 8 digits, leading zeros kept. Show it on the pairing screen only:
  /// never log, notify, copy or share it.
  String get verificationCode => _claim.verificationCode;

  /// When the computer can no longer submit the code.
  DateTime get codeExpiresAt => _claim.expiresAt;

  PairingState get state => _state;
  Stream<PairingState> get states => _states.stream;

  /// Fails with [PairingException]: `PAIRING_CODE_REJECTED`,
  /// `PAIRING_CANCELLED`, `PAIRING_EXPIRED`, `PAIRING_ACCOUNT_CONFLICT`,
  /// `PAIRING_IDENTITY_MISMATCH`, another Server code, ...
  Future<RemotePairedHost> get result => _result.future;

  bool get isClosed => _result.isCompleted;

  /// Stops polling while the app is in the background (a poll in flight
  /// still lands). Resuming polls again at once.
  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    if (!value) {
      final resumed = _resumed;
      _resumed = null;
      resumed?.complete();
    }
  }

  bool get paused => _paused;

  /// Gives up before the credentials are being stored, and tells the Server
  /// (best effort). A completed binding is undone by revoking it, not here.
  Future<void> cancel() async {
    if (_committing || isClosed) return;
    _fail(const PairingException('PAIRING_CANCELLED', 'Pairing was cancelled on this phone.'));
    await _sendCancel().catchError((Object _) {});
  }

  Future<void> _wait(Duration delay) async {
    await Future<void>.delayed(delay);
    while (_paused && !isClosed) {
      await (_resumed ??= Completer<void>()).future;
    }
  }

  void _emit(PairingState state) {
    if (isClosed || state == _state) return;
    _state = state;
    _states.add(state);
  }

  void _complete(RemotePairedHost host) {
    if (isClosed) return;
    _state = PairingState.completed;
    _states.add(PairingState.completed);
    _result.complete(host);
    unawaited(_states.close());
  }

  void _fail(PairingException error) {
    if (isClosed) return;
    _result.completeError(error);
    unawaited(_states.close());
    paused = false;
  }
}

class _Identity {
  _Identity({
    required this.deviceId,
    required this.privateKey,
    required this.publicKey,
    required this.name,
    required this.platform,
  });

  factory _Identity.fromJson(JsonMap json) => _Identity(
    deviceId: json['deviceId']! as String,
    privateKey: json['privateKey']! as String,
    publicKey: json['publicKey']! as String,
    name: json['name']! as String,
    platform: json['platform']! as String,
  );

  final String deviceId;
  final String privateKey;
  final String publicKey;
  final String name;
  final String platform;

  JsonMap toJson() => {
    'v': 1,
    'deviceId': deviceId,
    'privateKey': privateKey,
    'publicKey': publicKey,
    'name': name,
    'platform': platform,
  };
}

class _Credentials {
  _Credentials({
    required this.deviceId,
    required this.account,
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    this.provider,
  });

  factory _Credentials.fromTokens(String deviceId, String account, DeviceTokenPair tokens, {String? provider}) =>
      _Credentials(
        deviceId: deviceId,
        account: account,
        accessToken: tokens.accessToken,
        accessTokenExpiresAt: tokens.accessTokenExpiresAt,
        refreshToken: tokens.refreshToken,
        refreshTokenExpiresAt: tokens.refreshTokenExpiresAt,
        provider: provider,
      );

  factory _Credentials.fromJson(JsonMap json) => _Credentials(
    deviceId: json['deviceId']! as String,
    account: json['account']! as String,
    accessToken: json['accessToken']! as String,
    accessTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(json['accessTokenExpiresAt']! as int),
    refreshToken: json['refreshToken']! as String,
    refreshTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(json['refreshTokenExpiresAt']! as int),
    provider: asString(json['provider']),
  );

  final String deviceId;
  final String account;
  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;

  /// Provider the device signed in with, when recorded.
  final String? provider;

  JsonMap toJson() => {
    'v': 1,
    'deviceId': deviceId,
    'account': account,
    'accessToken': accessToken,
    'accessTokenExpiresAt': accessTokenExpiresAt.millisecondsSinceEpoch,
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshTokenExpiresAt.millisecondsSinceEpoch,
    'provider': ?provider,
  };
}

class _Pin {
  _Pin(this.identityKey, this.name, this.pinnedAt);
  final String identityKey;
  final String name;
  final DateTime pinnedAt;
}

/// One account on one ds-harness-remote Server.
///
/// ```dart
/// final account = RemoteAccount(secrets: MySecureStore());
/// if (await account.currentUser() == null) {
///   final login = await account.startLogin();          // or loginWithPassword
///   await launchUrl(login.loginUrl, mode: LaunchMode.externalApplication);
///   await login.result;
/// }
/// final hosts = await account.listHosts();
/// final client = await account.connectHost(hosts.first, onState: print);
/// final sessions = await client.listSessions();        // same DshClient API
/// ```
///
/// Everything secret (identity private key, access/refresh tokens, Host
/// pins) goes through [secrets], partitioned by Server origin. The account
/// web token from sign-in is used once to register this device and never
/// stored.
///
/// One Server connection per device: connecting to another Host closes the
/// previous remote client (the Server allows one Host connection per
/// client device).
class RemoteAccount {
  RemoteAccount({
    required SecretStore secrets,
    Object? serverUrl,
    this.deviceName = 'DSH App',
    this.platform = 'dsh-app-android',
    this.clientVersion = '0.1.0',
    HttpClient? httpClient,
    ControlSocketConnector? socketConnector,
    this.loginPollInterval = const Duration(seconds: 2),
    this.pairingPollInterval = const Duration(milliseconds: 2500),
    this.controlTracer,
    this.peerConnector,
    this.preferredTransports,
    this.onDirectFallback,
    this.compactHistory = false,
    this.directTimeout = const Duration(seconds: 8),
    this.iceServersTimeout = const Duration(seconds: 10),
  }) : serverUrl = normalizeServerUrl(serverUrl ?? defaultRemoteServer),
       _secrets = secrets,
       _socketConnector = socketConnector {
    api = RemoteServerApi(this.serverUrl, httpClient: httpClient);
    _scope = hashes.sha256.convert(utf8.encode(this.serverUrl.origin)).toString().substring(0, 24);
    final scopes = _accountStorageStates[secrets] ??= {};
    _storageState = scopes.putIfAbsent(_scope, _AccountStorageState.new);
  }

  final Uri serverUrl;
  final String deviceName;

  /// Device platform reported to the Server (`[a-z0-9][a-z0-9._-]*`).
  final String platform;
  final String clientVersion;
  final Duration loginPollInterval;

  /// How often a claimed pairing asks for the computer's answer (2–3 s).
  final Duration pairingPollInterval;

  /// Optional Control-frame tracer (tokens and ciphertext redacted).
  final ControlTracer? controlTracer;

  /// WebRTC stack for the direct path (LAN / P2P / TURN); `null` keeps every
  /// connection on the Relay. Read at each (re)connect, so a change applies
  /// from the next connection on.
  RemotePeerConnector? peerConnector;

  /// Optional native network hint. Actual selection still requires a working
  /// ICE pair. Exceptions or a stalled hint retain automatic defaults.
  Future<List<RemoteTransportMode>> Function()? preferredTransports;

  /// Payload-free fallback code ([RemoteNetworkFallbackReason.name]), never
  /// raw native exception text, SDP or candidate addresses.
  void Function(String reason)? onDirectFallback;

  /// Requests bounded history summaries from supporting Hosts. Captured by
  /// [connectHost] for that client's lifetime, including automatic reconnects.
  /// Changing it only affects the next [connectHost], not live streams or
  /// cached history. The first successful session fixes the effective mode:
  /// an unsupported Host stays full even if it gains support on reconnect.
  bool compactHistory;

  /// Local DataChannel negotiation deadline when the Server does not provide
  /// `webrtcFallbackTimeoutMs`; a supplied Server deadline takes precedence.
  final Duration directTimeout;

  /// Budget for each connection's fresh STUN/TURN credential request,
  /// separate from the DataChannel negotiation deadline.
  final Duration iceServersTimeout;
  late final RemoteServerApi api;
  final SecretStore _secrets;
  final ControlSocketConnector? _socketConnector;
  late final String _scope;

  _Identity? _identity;
  Future<_Identity>? _creatingIdentity;
  _Credentials? _credentials;
  // Shared only within this storage object and normalized server scope.
  late final _AccountStorageState _storageState;
  bool _restored = false;
  Future<void>? _restoring;
  Map<String, _Pin>? _pins;
  ({_Credentials owner, Future<String> result})? _refreshing;
  _ActiveConnection? _active;
  final Map<String, DateTime> _directCooldown = {};
  final Map<String, DateTime> _turnCooldown = {};
  final Map<String, String> _networkHints = {};
  final StreamController<RemoteConnectionState> _connectionStates = StreamController.broadcast();

  String get _identityKey => 'dsh_remote.v1.$_scope.identity';
  String get _credentialsKey => 'dsh_remote.v1.$_scope.credentials';
  String get _pinsKey => 'dsh_remote.v1.$_scope.pins';

  // ---------------------------------------------------------------------------
  // Account state

  /// The signed-in user, restoring stored credentials on first call; `null`
  /// when signed out or the refresh token expired.
  Future<RemoteUser?> currentUser() async {
    await _restore();
    final credentials = _credentials;
    if (credentials == null) return null;
    if (!credentials.refreshTokenExpiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return null;
    }
    return RemoteUser(
      account: credentials.account,
      deviceId: credentials.deviceId,
      serverUrl: serverUrl,
      provider: credentials.provider,
    );
  }

  Future<void> _restore() {
    if (_restored) return Future<void>.value();
    return _restoring ??= _readStoredAccount().whenComplete(() => _restoring = null);
  }

  Future<void> _readStoredAccount() async {
    final identity = asMap(tryDecodeJson(await _secrets.read(_identityKey) ?? ''));
    try {
      if (identity != null) _identity = _Identity.fromJson(identity);
    } on Object {
      _identity = null; // corrupt record: a new identity is created at sign-in
    }
    final credentials = asMap(tryDecodeJson(await _secrets.read(_credentialsKey) ?? ''));
    try {
      if (credentials != null) {
        final parsed = _Credentials.fromJson(credentials);
        if (parsed.deviceId == _identity?.deviceId) _credentials = parsed;
      }
    } on Object {
      _credentials = null;
    }
    _restored = true;
  }

  /// QR-capable sign-in providers of this Server (empty on a self-hosted
  /// Server: use [loginWithPassword]).
  Future<List<OAuthProvider>> loginProviders() => _guard(() async {
    final providers = await api.oauthProviders();
    return providers.where((p) => p.supportsQrLogin).toList();
  });

  /// Starts a QR / browser sign-in with [providerId] (default: the first
  /// QR-capable provider). Works without any app URL scheme: the account
  /// authorizes in the browser, this device polls for the result.
  Future<RemoteLogin> startLogin({String? providerId}) => _guard(() async {
    final providers = await loginProviders();
    final provider = providerId == null
        ? (providers.isEmpty ? null : providers.first)
        : providers.where((p) => p.id == providerId).firstOrNull;
    if (provider == null) {
      throw const RemoteConnectException(
        RemoteFailure(
          'OAUTH_PROVIDER_UNAVAILABLE',
          'No QR sign-in provider is available on this Server.',
          retryable: false,
        ),
      );
    }
    final session = await api.startQrLogin(provider);
    final expiresAt = DateTime.now().add(session.expiresIn);
    final completer = Completer<RemoteUser>();
    var cancelled = false;
    var committing = false;
    const cancelledError = RemoteConnectException(
      RemoteFailure('LOGIN_CANCELLED', 'Sign-in was cancelled.', retryable: true),
    );
    void checkCancelled() {
      if (cancelled) throw cancelledError;
    }

    Future<void> poll() async {
      while (!cancelled && DateTime.now().isBefore(expiresAt)) {
        QrPollResult result;
        try {
          result = await api.pollQrLogin(session.qrId);
        } on RemoteApiException catch (error) {
          if (!error.retryable) rethrow;
          await Future<void>.delayed(loginPollInterval);
          continue;
        }
        if (cancelled) return;
        switch (result) {
          case QrComplete(:final accountToken):
            final account = await api.accountMe(accountToken);
            if (cancelled) return;
            final user = await _registerWithAccountToken(
              accountToken,
              account,
              provider: provider.id,
              checkCancelled: checkCancelled,
              beforeCommit: () {
                checkCancelled();
                committing = true;
              },
            );
            completer.complete(user);
            return;
          case QrExpired():
            throw const RemoteConnectException(
              RemoteFailure('LOGIN_EXPIRED', 'The sign-in session expired.', retryable: true),
            );
          case QrPending():
            await Future<void>.delayed(loginPollInterval);
        }
      }
      if (!cancelled) {
        throw const RemoteConnectException(
          RemoteFailure('LOGIN_EXPIRED', 'The sign-in session expired.', retryable: true),
        );
      }
    }

    unawaited(
      poll().catchError((Object error) {
        if (!completer.isCompleted) completer.completeError(_asConnectException(error));
      }),
    );
    return RemoteLogin._(session.scanUrl, provider.id, expiresAt, completer.future, () {
      if (committing || completer.isCompleted) return;
      cancelled = true;
      completer.completeError(cancelledError);
    });
  });

  /// Email/password sign-in (the self-hosted Server's only method; the
  /// hosted one supports it for invited accounts).
  Future<RemoteUser> loginWithPassword(String email, String password) => _guard(() async {
    final login = await api.loginWithPassword(email, password);
    return _registerWithAccountToken(login.token, login.account, provider: 'password');
  });

  Future<RemoteUser> _registerWithAccountToken(
    String accountToken,
    String account, {
    String? provider,
    void Function()? checkCancelled,
    void Function()? beforeCommit,
  }) async {
    await _restore();
    checkCancelled?.call();
    var identity = await _ensureIdentity();
    checkCancelled?.call();
    DeviceTokenPair tokens;
    try {
      tokens = await api.registerDevice(_descriptor(identity), accountToken);
    } on RemoteApiException catch (error) {
      checkCancelled?.call();
      // A revoked or conflicting identity is replaced; sign-in is the
      // explicit re-authorization boundary.
      if (error.code != 'DEVICE_REVOKED' && error.code != 'PEER_IDENTITY_MISMATCH') rethrow;
      identity = await _ensureIdentity(rotate: true);
      checkCancelled?.call();
      tokens = await api.registerDevice(_descriptor(identity), accountToken);
    }
    checkCancelled?.call();
    await _saveCredentials(
      _Credentials.fromTokens(identity.deviceId, account, tokens, provider: provider),
      beforeWrite: beforeCommit,
      signIn: true,
    );
    return RemoteUser(account: account, deviceId: identity.deviceId, serverUrl: serverUrl, provider: provider);
  }

  DeviceDescriptor _descriptor(_Identity identity) => DeviceDescriptor(
    deviceId: identity.deviceId,
    name: identity.name,
    role: 'client',
    platform: identity.platform,
    identityKey: identity.publicKey,
    clientVersion: clientVersion,
  );

  Future<_Identity> _ensureIdentity({bool rotate = false}) async {
    // A cancelled sign-in may still be writing the identity. Its retry must
    // wait for that local mutation, or a late credential delete can erase it.
    final pending = _creatingIdentity;
    if (pending != null) return pending;
    final existing = _identity;
    if (existing != null && !rotate) return existing;
    final creating = _creatingIdentity = _createIdentity();
    try {
      return await creating;
    } finally {
      _creatingIdentity = null;
    }
  }

  Future<_Identity> _createIdentity() async {
    final keys = X25519KeyPair.generate();
    final identity = _Identity(
      deviceId: uuidV7(),
      privateKey: keys.privateKeyBase64Url,
      publicKey: keys.publicKeyBase64Url,
      name: deviceName,
      platform: platform,
    );
    await _secrets.write(_identityKey, jsonEncode(identity.toJson()));
    _identity = identity;
    await _dropCredentials();
    return identity;
  }

  Future<void> _saveCredentials(_Credentials credentials, {void Function()? beforeWrite, bool signIn = false}) {
    // SecretStore writes are atomic, but not cancellable. Serialize commits
    // so a slow older write cannot finish after a newer login's write.
    final write = _storageState.credentialWrites.then((_) async {
      beforeWrite?.call();
      await _secrets.write(_credentialsKey, jsonEncode(credentials.toJson()));
      _credentials = credentials;
      if (signIn) _storageState.signInEpoch++;
    });
    _storageState.credentialWrites = write.catchError((Object _) {});
    return write;
  }

  /// Signs out: closes the active connection, revokes this device on the
  /// Server (best effort, when [revokeDevice]) and deletes its tokens. A
  /// revoked device identity is discarded too; Host pins are kept.
  /// A newer committed sign-in retires further cleanup from this logout;
  /// a revoke or storage delete already issued cannot be undone here.
  Future<void> logout({bool revokeDevice = true}) async {
    final epoch = _storageState.signInEpoch;
    bool isCurrent() => epoch == _storageState.signInEpoch;
    await _restore();
    if (!isCurrent()) return;
    await _active?.close();
    if (!isCurrent()) return;
    final credentials = _credentials;
    if (revokeDevice && credentials != null) {
      try {
        final token = await accessToken();
        if (!isCurrent()) return;
        await api.revokeSelf(token);
      } on Object {
        // Offline or already revoked: still sign out locally.
      }
    }
    await _dropCredentials(isCurrent: isCurrent);
    if (revokeDevice && isCurrent()) {
      _identity = null;
      await _secrets.delete(_identityKey);
    }
  }

  /// Forces a token rotation (normally automatic, 60 s before expiry).
  Future<void> refresh() => _guard(() => accessToken(forceRefresh: true));

  /// A valid device access token, refreshing it when it expires within a
  /// minute. Concurrent callers share one refresh (refresh tokens rotate and
  /// a reused one revokes the whole family). Throws
  /// [RemoteConnectException] `ACCOUNT_AUTH_REQUIRED` when signed out.
  Future<String> accessToken({bool forceRefresh = false}) async {
    await _restore();
    final credentials = _credentials;
    if (credentials == null) {
      throw const RemoteConnectException(
        RemoteFailure('ACCOUNT_AUTH_REQUIRED', 'Sign in to the remote Server first.', retryable: false),
      );
    }
    if (!forceRefresh && credentials.accessTokenExpiresAt.isAfter(DateTime.now().add(const Duration(seconds: 60)))) {
      return credentials.accessToken;
    }
    final refreshing = _refreshing;
    if (refreshing != null && identical(refreshing.owner, credentials)) return refreshing.result;
    late final Future<String> result;
    result = _rotate(credentials).whenComplete(() {
      if (identical(_refreshing?.result, result)) _refreshing = null;
    });
    _refreshing = (owner: credentials, result: result);
    return result;
  }

  Future<String> _rotate(_Credentials credentials) async {
    if (!credentials.refreshTokenExpiresAt.isAfter(DateTime.now())) {
      await _dropCredentials(owner: credentials);
      throw const RemoteConnectException(
        RemoteFailure('ACCOUNT_AUTH_REQUIRED', 'The device sign-in expired; sign in again.', retryable: false),
      );
    }
    try {
      final tokens = await api.refresh(credentials.deviceId, credentials.refreshToken);
      await _saveCredentials(
        _Credentials.fromTokens(credentials.deviceId, credentials.account, tokens, provider: credentials.provider),
        beforeWrite: () {
          if (!identical(_credentials, credentials)) {
            throw const RemoteConnectException(
              RemoteFailure('ACCOUNT_AUTH_REQUIRED', 'The device sign-in changed during refresh.', retryable: false),
            );
          }
        },
      );
      return tokens.accessToken;
    } on RemoteApiException catch (error) {
      if (error.retryable || error.code == 'CONNECTION_FAILED' || error.code == 'RATE_LIMITED') {
        throw RemoteConnectException(RemoteFailure(error.code, error.message, retryable: true));
      }
      await _dropCredentials(owner: credentials);
      throw RemoteConnectException(
        RemoteFailure(
          'ACCOUNT_AUTH_REQUIRED',
          'The Server refused the device token (${error.code}); sign in again.',
          retryable: false,
        ),
      );
    }
  }

  Future<void> _dropCredentials({_Credentials? owner, bool Function()? isCurrent}) {
    // Deletes share the commit queue; retired refreshes and logouts recheck
    // their owner at the point where the mutation would actually begin.
    final write = _storageState.credentialWrites.then((_) async {
      if (isCurrent != null && !isCurrent()) return;
      if (owner != null && !identical(_credentials, owner)) return;
      _credentials = null;
      await _secrets.delete(_credentialsKey);
    });
    _storageState.credentialWrites = write.catchError((Object _) {});
    return write;
  }

  // ---------------------------------------------------------------------------
  // Device pairing: scan the computer's code (upstream docs/device-pairing-v1.md)

  /// Whether this Server pairs devices by scanning. A failed discovery
  /// throws ([PairingException]); it never reads as "unsupported".
  Future<bool> supportsPairing() async {
    try {
      return (await api.serverCapabilities()).devicePairing == devicePairingProtocol;
    } on RemoteApiException catch (error) {
      throw _pairingException(error);
    }
  }

  /// What a scanned code points at (read-only on the Server: it does not
  /// use up the claim). The code must belong to this account's Server;
  /// another fails with `PAIRING_SERVER_MISMATCH` (its [PairingException.origin]
  /// says which), so the caller can switch Servers with the person's OK.
  Future<PairingOffer> resolvePairing(PairingScan scan) async {
    if (scan.origin != serverUrl) {
      throw PairingException(
        'PAIRING_SERVER_MISMATCH',
        'The code belongs to ${scan.origin}, not $serverUrl.',
        origin: scan.origin,
      );
    }
    final RemoteServerCapabilities capabilities;
    try {
      capabilities = await api.serverCapabilities();
    } on RemoteApiException catch (error) {
      throw _pairingException(error);
    }
    if (capabilities.devicePairing != devicePairingProtocol) {
      throw const PairingException('PAIRING_UNSUPPORTED', 'This Server does not pair devices by scanning.');
    }
    switch (scan) {
      case PairingLegacyScan(:final offer):
        return offer;
      case PairingTicketScan(:final ticket):
        if (capabilities.devicePairingQr != devicePairingQrFormat) {
          throw const PairingException('PAIRING_UNSUPPORTED', 'This Server does not resolve short pairing codes.');
        }
        final body = await _pairingRequest(
          () => api.resolvePairing(ticket),
          until: DateTime.now().add(const Duration(seconds: 30)),
        );
        return PairingOffer.parse(body, origin: serverUrl, ticket: ticket);
    }
  }

  /// Claims [offer] with this phone's own device identity, once the person
  /// confirmed the computer on the phone. Returns the code to show; the
  /// phone then polls until the computer submitted it. No access exists
  /// before [RemotePairing.result] completes.
  ///
  /// [deepseekUserId] is optional unverified metadata (a DeepSeek account
  /// id from a non-sensitive profile read); never credentials.
  Future<RemotePairing> claimPairing(PairingOffer offer, {String? deepseekUserId}) async {
    if (offer.origin != serverUrl) {
      throw PairingException('PAIRING_SERVER_MISMATCH', 'The session belongs to another Server.', origin: offer.origin);
    }
    await _restore();
    final identity = await _ensureIdentity();
    final mobile = PairingDevice(
      deviceId: identity.deviceId,
      name: identity.name,
      role: 'client',
      platform: identity.platform,
      identityKey: identity.publicKey,
    );
    if (mobile.deviceId == offer.host.deviceId || mobile.identityKey == offer.host.identityKey) {
      throw const PairingException('PAIRING_IDENTITY_MISMATCH', 'The computer and this phone share an identity.');
    }
    final privateKey = fromBase64Url(identity.privateKey);
    String proof(String path, String raw) => pairingProof(
      devicePrivateKey: privateKey,
      serverPublicKey: offer.serverPublicKey,
      sessionId: offer.sessionId,
      side: 'mobile',
      path: path,
      rawJson: raw,
    );
    // One serialization; a lost response is recovered by resending exactly
    // these bytes, never by claiming again with other content.
    final raw = pairingClaimBody(scanSecret: offer.scanSecret, device: mobile, deepseekUserId: deepseekUserId);
    final path = offer.path('claim');
    final claimProof = proof(path, raw);
    final claim = PairingClaim.parse(
      await _pairingRequest(() => api.pairingPost(path, raw, claimProof), until: offer.expiresAt),
    );
    final cancelPath = offer.path('mobile/cancel');
    final cancelProof = proof(cancelPath, '{}');
    final pairing = RemotePairing._(offer, mobile, claim, () => api.pairingPost(cancelPath, '{}', cancelProof));
    unawaited(_followPairing(pairing, identity, proof(offer.path('mobile/status'), '{}')));
    return pairing;
  }

  Future<void> _followPairing(RemotePairing pairing, _Identity identity, String statusProof) async {
    final path = pairing.offer.path('mobile/status');
    // Results stay retrievable until `recoverUntil` (creation + 480 s).
    var deadline = pairing.offer.expiresAt.add(const Duration(seconds: 300));
    var delay = pairingPollInterval;
    try {
      while (!pairing.isClosed) {
        await pairing._wait(delay);
        if (pairing.isClosed) return;
        if (DateTime.now().isAfter(deadline.add(PairingOffer.clockSkew))) {
          throw const PairingException('PAIRING_EXPIRED', 'The pairing session expired.');
        }
        final Object? body;
        try {
          body = await api.pairingPost(path, '{}', statusProof);
          delay = pairingPollInterval;
        } on RemoteApiException catch (error) {
          if (error.code == 'PAIRING_NOT_FOUND') {
            throw const PairingException('PAIRING_EXPIRED', 'The pairing session expired.');
          }
          if (!_pairingRetryable(error)) throw _pairingException(error);
          // Back off on 429 and outages; never start a new session.
          delay = delay * 2 > const Duration(seconds: 15) ? const Duration(seconds: 15) : delay * 2;
          continue;
        }
        if (pairing.isClosed) return;
        final status = PairingStatus.parse(body, offer: pairing.offer, mobile: pairing.mobile);
        if (status.recoverUntil case final recover?) deadline = recover;
        // Completed is announced once the credentials are stored.
        if (status.state != PairingState.completed) pairing._emit(status.state);
        switch (status.state) {
          case PairingState.created || PairingState.claimed || PairingState.approved:
            continue;
          case PairingState.completed:
            final RemoteUser user;
            try {
              user = await _commitPairing(pairing, identity, status.credentials!);
            } on PairingException {
              rethrow;
            } on Object {
              // Storage failed before the credentials were stored: the same
              // ones can be fetched again until `recoverUntil`.
              pairing._committing = false;
              continue;
            }
            // Stored: from here on nothing is committed twice.
            await _pinPairedHost(pairing.offer.host);
            pairing._complete(RemotePairedHost(user: user, host: pairing.offer.host));
            return;
          case PairingState.failed:
            final reason = status.failureReason;
            throw reason == null || reason == 'verification_failed'
                ? const PairingException('PAIRING_CODE_REJECTED', 'The computer submitted a wrong code.')
                : PairingException(reason, 'The Server refused the binding ($reason).');
          case PairingState.cancelled:
            throw const PairingException('PAIRING_CANCELLED', 'The pairing was cancelled.');
          case PairingState.expired:
            throw const PairingException('PAIRING_EXPIRED', 'The pairing session expired.');
        }
      }
    } on PairingException catch (error) {
      pairing._fail(error);
    } on Object catch (error) {
      pairing._fail(PairingException('PAIRING_FAILED', '$error'));
    }
  }

  /// Stores this phone's credentials, unless they would replace another
  /// account's. A storage failure throws (the caller fetches them again);
  /// only an undecodable stored record counts as none.
  Future<RemoteUser> _commitPairing(RemotePairing pairing, _Identity identity, PairingCredentials credentials) async {
    await _restore();
    const identityChanged = PairingException('PAIRING_IDENTITY_MISMATCH', 'This phone signed out or changed identity.');
    late String? provider;
    // Decide at the serialized commit point, from what is stored now: another
    // sign-in (here, or in another RemoteAccount on the same store) may have
    // committed since this pairing started.
    final write = _storageState.credentialWrites.then((_) async {
      // Still cancellable while queued behind other writes.
      if (pairing.isClosed) throw const PairingException('PAIRING_CANCELLED', 'Pairing was cancelled on this phone.');
      final storedIdentity = asMap(tryDecodeJson(await _secrets.read(_identityKey) ?? ''));
      if (!identical(_identity, identity) || storedIdentity?['deviceId'] != identity.deviceId) throw identityChanged;
      // A failed read is not "no credentials": it must not let this write
      // replace another account's sign-in.
      final raw = await _secrets.read(_credentialsKey);
      _Credentials? stored;
      try {
        final map = asMap(tryDecodeJson(raw ?? ''));
        stored = map == null ? null : _Credentials.fromJson(map);
      } on Object {
        stored = null;
      }
      final current =
          stored != null &&
          stored.deviceId == identity.deviceId &&
          stored.refreshTokenExpiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)));
      if (current && stored.account != credentials.account) {
        throw const PairingException(
          'PAIRING_ACCOUNT_CONFLICT',
          'This phone is signed in to another account; its credentials are kept.',
        );
      }
      provider = current ? stored.provider : 'pairing';
      final saved = _Credentials.fromTokens(
        identity.deviceId,
        credentials.account,
        credentials.tokens,
        provider: provider,
      );
      pairing._committing = true;
      await _secrets.write(_credentialsKey, jsonEncode(saved.toJson()));
      _credentials = saved;
      _storageState.signInEpoch++;
    });
    _storageState.credentialWrites = write.catchError((Object _) {});
    await write;
    return RemoteUser(
      account: credentials.account,
      deviceId: identity.deviceId,
      serverUrl: serverUrl,
      provider: provider,
    );
  }

  /// Pins the Host key from the code the person confirmed, retrying the
  /// read and the save. Never re-commits credentials: when the pin cannot be
  /// stored the pairing fails with `PAIRING_PIN_SAVE_FAILED` and the stored
  /// sign-in stays (pairing again pins it).
  Future<void> _pinPairedHost(PairingDevice host) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final pins = await _loadPins();
        pins[host.deviceId] = _Pin(host.identityKey, host.name, DateTime.now());
        await _savePins(pins);
        return;
      } on Object {
        if (attempt == 3) {
          throw const PairingException(
            'PAIRING_PIN_SAVE_FAILED',
            'The computer key could not be stored on this phone; pair again.',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
    }
  }

  /// Retries outages and rate limits with the same request until [until];
  /// any other refusal is final.
  Future<Object?> _pairingRequest(Future<Object?> Function() send, {required DateTime until}) async {
    var delay = const Duration(seconds: 1);
    while (true) {
      try {
        return await send();
      } on RemoteApiException catch (error) {
        if (!_pairingRetryable(error) || DateTime.now().add(delay).isAfter(until)) throw _pairingException(error);
      }
      await Future<void>.delayed(delay);
      if (delay < const Duration(seconds: 8)) delay *= 2;
    }
  }

  static bool _pairingRetryable(RemoteApiException error) =>
      error.retryable || error.code == 'CONNECTION_FAILED' || error.status == 429 || error.status == 503;

  static PairingException _pairingException(RemoteApiException error) => PairingException(error.code, error.message);

  // ---------------------------------------------------------------------------
  // Hosts and pins

  /// Hosts on this account with presence, versions and pin status. Fetches
  /// every Host's descriptor (identity key) in parallel.
  Future<List<RemoteHost>> listHosts() => _guard(() async {
    final listings = await _withToken(api.listHosts);
    final pins = await _loadPins();
    return Future.wait(
      listings.map((listing) async {
        final peer = await _withToken((token) => api.device(token, listing.deviceId));
        final pin = pins[listing.deviceId];
        final key = peer.role == 'host' && identityKeyPattern.hasMatch(peer.identityKey) ? peer.identityKey : null;
        final trust = key == null
            ? RemoteHostTrust.unknown
            : pin == null
            ? RemoteHostTrust.unpinned
            : pin.identityKey == key
            ? RemoteHostTrust.pinned
            : RemoteHostTrust.keyChanged;
        return RemoteHost(
          id: listing.deviceId,
          name: listing.name,
          platform: listing.platform,
          online: peer.online ?? listing.online,
          trust: trust,
          harnessVersion: listing.harnessVersion ?? peer.harnessVersion,
          pluginVersion: listing.clientVersion ?? peer.clientVersion,
          lastSeenAt: peer.lastSeenAt ?? listing.lastSeenAt,
          identityKey: key,
          pinnedIdentityKey: pin?.identityKey,
          membershipId: listing.membershipId,
        );
      }),
    );
  });

  /// Forgets a Host's pinned key, so the next connect trusts (or prompts
  /// for) the key the Server reports. Use after a legitimate Host reinstall.
  Future<void> forgetHost(String hostId) async {
    final pins = await _loadPins();
    if (pins.remove(hostId) != null) await _savePins(pins);
  }

  Future<Map<String, _Pin>> _loadPins() async {
    final cached = _pins;
    if (cached != null) return cached;
    final json = asMap(asMap(tryDecodeJson(await _secrets.read(_pinsKey) ?? ''))?['hosts']) ?? const {};
    final pins = <String, _Pin>{};
    json.forEach((id, raw) {
      final map = asMap(raw);
      final key = asString(map?['identityKey']);
      if (key == null) return;
      pins[id] = _Pin(
        key,
        asString(map!['name']) ?? '',
        DateTime.fromMillisecondsSinceEpoch(asInt(map['pinnedAt']) ?? 0),
      );
    });
    return _pins = pins;
  }

  Future<void> _savePins(Map<String, _Pin> pins) => _secrets.write(
    _pinsKey,
    jsonEncode({
      'v': 1,
      'hosts': {
        for (final MapEntry(:key, :value) in pins.entries)
          key: {
            'identityKey': value.identityKey,
            'name': value.name,
            'pinnedAt': value.pinnedAt.millisecondsSinceEpoch,
          },
      },
    }),
  );

  Future<T> _withToken<T>(Future<T> Function(String token) action) async {
    final token = await accessToken();
    try {
      return await action(token);
    } on RemoteApiException catch (error) {
      if (!error.isAuthFailure) rethrow;
      return action(await accessToken(forceRefresh: true));
    }
  }

  // ---------------------------------------------------------------------------
  // Connect

  /// Current state of the active remote connection.
  RemoteConnectionState? get connectionState => _active?.carrier.state;

  /// States of whichever Host connection is active (connecting / connected
  /// / reconnecting / failed / closed).
  Stream<RemoteConnectionState> get connectionStates => _connectionStates.stream;

  /// The client of the active connection, if any.
  DshClient? get activeClient => _active?.client;

  /// Connects to [host] with end-to-end Noise encryption, directly
  /// ([peerConnector]) or through the Server Relay, and returns a ready
  /// [DshClient] (first `$events` generation received). The client
  /// reconnects by itself after drops; [onState] and [connectionStates]
  /// report progress and failures.
  ///
  /// Trust: the Host's identity key is pinned on first connect (after
  /// [confirmNewHost] approves, when given) and must never change afterwards
  /// (`PEER_IDENTITY_MISMATCH`, fail closed).
  ///
  /// Throws [RemoteConnectException] when not ready within [timeout], or at
  /// once for terminal failures and `HOST_OFFLINE`.
  Future<DshClient> connectHost(
    RemoteHost host, {
    void Function(RemoteConnectionState state)? onState,
    HostTrustPrompt? confirmNewHost,
    MuxOptions muxOptions = const MuxOptions(),
    Duration timeout = const Duration(seconds: 30),
    Duration healthInterval = const Duration(seconds: 25),
    Duration healthTimeout = const Duration(seconds: 10),
    DshTracer? tracer,
  }) async {
    final historyMode = _HistoryMode(compactHistory);
    await _restore();
    final previous = _active;
    _active = null;
    await previous?.close();
    late final RemoteTunnelCarrier carrier;
    carrier = RemoteTunnelCarrier(
      hostId: host.id,
      open: (last) => _openHostSession(host, last, confirmNewHost, historyMode, () => carrier.isClosed, carrier.states),
      healthInterval: healthInterval,
      healthTimeout: healthTimeout,
      tracer: tracer,
    );
    final client = DshClient.withCarrier(carrier, muxOptions: muxOptions);
    final active = _ActiveConnection(client, carrier);
    _active = active;
    active.stateSub = carrier.states.listen((state) {
      onState?.call(state);
      if (_active == active && !_connectionStates.isClosed) _connectionStates.add(state);
      if (state.phase == RemoteConnectionPhase.closed && _active == active) _active = null;
    });
    carrier.attachMux(client.mux);

    final ready = client.mux.ready(timeout: timeout);
    final failFast = Completer<RemoteFailure>();
    final failSub = carrier.failures.listen((failure) {
      if (!failFast.isCompleted && (!failure.retryable || failure.code == 'HOST_OFFLINE')) {
        failFast.complete(failure);
      }
    });
    try {
      final outcome = await Future.any<Object?>([ready, failFast.future]);
      if (outcome is RemoteFailure) throw RemoteConnectException(outcome);
      return client;
    } on Object catch (error) {
      ready.ignore();
      if (_active == active) _active = null;
      await active.close();
      if (error is RemoteConnectException) rethrow;
      throw RemoteConnectException(
        carrier.lastFailure ??
            switch (error) {
              DshCarrierRefusedException(:final code, :final message) => RemoteFailure(code, message, retryable: false),
              _ => RemoteFailure('CONNECTION_FAILED', '$error', retryable: true),
            },
      );
    } finally {
      await failSub.cancel();
    }
  }

  Future<RemoteHostSession> _openHostSession(
    RemoteHost host,
    RemoteFailure? previous,
    HostTrustPrompt? confirm,
    _HistoryMode historyMode,
    bool Function() isCancelled,
    Stream<RemoteConnectionState> ownerStates,
  ) async {
    try {
      return await _openHostSessionOnce(host, previous, confirm, historyMode, isCancelled, ownerStates);
    } on RemoteConnectException {
      rethrow;
    } on Object catch (error) {
      throw _asConnectException(error);
    }
  }

  Future<RemoteHostSession> _openHostSessionOnce(
    RemoteHost host,
    RemoteFailure? previous,
    HostTrustPrompt? confirm,
    _HistoryMode historyMode,
    bool Function() isCancelled,
    Stream<RemoteConnectionState> ownerStates,
  ) async {
    final identity = _identity;
    if (identity == null || _credentials == null) {
      throw const RemoteConnectException(
        RemoteFailure('ACCOUNT_AUTH_REQUIRED', 'Sign in to the remote Server first.', retryable: false),
      );
    }
    final staleToken = previous?.code == 'TOKEN_EXPIRED' || previous?.code == 'AUTH_INVALID';
    var token = await accessToken(forceRefresh: staleToken);

    // 1. Authorized descriptor + pin check (fails closed before any socket).
    AuthorizedPeer peer;
    try {
      peer = await api.device(token, host.id);
    } on RemoteApiException catch (error) {
      if (!error.isAuthFailure) rethrow;
      token = await accessToken(forceRefresh: true);
      peer = await api.device(token, host.id);
    }
    if (peer.role != 'host' || peer.deviceId != host.id || !identityKeyPattern.hasMatch(peer.identityKey)) {
      throw const RemoteConnectException(
        RemoteFailure('INVALID_MESSAGE', 'The Server returned an invalid Host descriptor.', retryable: false),
      );
    }
    if (peer.online == false) {
      throw const RemoteConnectException(RemoteFailure('HOST_OFFLINE', 'The Host is offline.', retryable: true));
    }
    final hostKey = await _checkPin(host, peer, confirm);
    // Exclude a first-use trust prompt's human response time.
    final setup = Stopwatch()..start();

    // 2. Data plane: direct when enabled and negotiated, else the Relay
    // (refresh once when the token is refused).
    _TransportSelection selection;
    try {
      selection = await _connectTransport(token, host.id, isCancelled);
    } on RemoteTransportException catch (error) {
      if (error.code != 'AUTH_INVALID' && error.code != 'TOKEN_EXPIRED') rethrow;
      token = await accessToken(forceRefresh: true);
      selection = await _connectTransport(token, host.id, isCancelled);
    }
    final transport = selection.transport;
    if (isCancelled()) {
      await transport.close();
      throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
    }

    // 3. Noise IK (client = initiator) against the pinned key.
    final channel = await SecureChannel.establish(
      transport: transport,
      clientDeviceId: identity.deviceId,
      clientPrivateKey: identity.privateKey,
      clientPublicKey: identity.publicKey,
      hostDeviceId: host.id,
      hostIdentityKey: hostKey,
    );
    if (isCancelled()) {
      await channel.close();
      throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
    }
    final rpc = RemoteRpcClient(channel);
    // A failed live carrier needs a fresh Noise session on a different path.
    // Cooldowns are short, account-local hints; no candidate or token is kept.
    unawaited(
      rpc.done.then((reason) {
        if (!reason.retryable || reason.code == 'CLIENT_CLOSED') return;
        final until = DateTime.now().add(const Duration(seconds: 45));
        switch (transport is WebRtcTransport ? transport.actualMode ?? transport.mode : transport.mode) {
          case RemoteTransportMode.lan || RemoteTransportMode.p2p:
            _directCooldown[host.id] = until;
          case RemoteTransportMode.turn:
            _directCooldown[host.id] = until;
            _turnCooldown[host.id] = until;
          case RemoteTransportMode.relay:
            break;
        }
      }),
    );

    // Until the carrier installs this session, its close must retire Noise/lease
    // even while a capability RPC is pending. The finally releases this handoff.
    final ownerSub = ownerStates.listen((state) {
      if (state.phase == RemoteConnectionPhase.closed) unawaited(rpc.close());
    }, onDone: () => unawaited(rpc.close()));
    // 4. Capability probe: the first RPC must be harness.transport.describe.
    var probingCapabilities = true;
    try {
      // Recovery may keep this Noise session only after the RPC receiver exists.
      if (transport is LeaseAwareTransport) transport.markSecureReady();
      final description = asMap(
        await rpc.call('harness.transport.describe', const <String, Object?>{}, timeout: const Duration(seconds: 10)),
      );
      if (isCancelled()) {
        throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
      }
      probingCapabilities = false;
      final raw = description?['capabilities'];
      if (raw is! List ||
          raw.length > maxRemoteCapabilityEntries ||
          raw.any((c) => c is! String || c.isEmpty) ||
          raw.toSet().length != raw.length) {
        throw const RemoteConnectException(
          RemoteFailure('INVALID_MESSAGE', 'The Host returned invalid transport capabilities.', retryable: false),
        );
      }
      final capabilities = raw.cast<String>();
      final v3 = capabilities.contains('harness.remote.v3');
      final v1 = capabilities.contains('harness.remote.v1');
      if (v3 && v1) {
        throw const RemoteConnectException(
          RemoteFailure(
            'INVALID_MESSAGE',
            'The Host advertised conflicting Harness Session formats.',
            retryable: false,
          ),
        );
      }
      if (!v3) {
        throw RemoteConnectException(
          RemoteFailure(
            'HARNESS_VERSION_INCOMPATIBLE',
            v1
                ? 'The Host runs a pre-0.1.5 DSH (Session format v1); this client needs DSH 0.2.x (Session V3).'
                : 'The Host exposes no Typert Remote carrier (harness.remote.v3); update its ds-harness-remote plugin.',
            retryable: false,
          ),
        );
      }
      final supportsCompact = capabilities.contains('remote.history.compact.v1');
      final compact = historyMode.negotiated ?? (supportsCompact && historyMode.requested);
      if (compact && !supportsCompact) {
        throw const RemoteConnectException(
          RemoteFailure(
            'HISTORY_MODE_CHANGED',
            'The Host no longer supports compact history; create a new client to load full history.',
            retryable: false,
          ),
        );
      }
      if (supportsCompact) {
        final result = asMap(
          await rpc.call('remote.history.configure', {'compact': compact}, timeout: const Duration(seconds: 10)),
        );
        if (isCancelled()) {
          throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
        }
        if (result == null || result.length != 1 || result['compact'] is! bool || result['compact'] != compact) {
          throw const RemoteConnectException(
            RemoteFailure('INVALID_MESSAGE', 'The Host returned an invalid history configuration.', retryable: false),
          );
        }
      }
      historyMode.negotiated = compact;
      setup.stop();
      RemoteNetworkDiagnostics snapshot() => RemoteNetworkDiagnostics(
        transportMode: transport is WebRtcTransport ? transport.actualMode : transport.mode,
        connectionDuration: setup.elapsed,
        roundTripTime: transport is WebRtcTransport ? transport.roundTripTime : null,
        peerNetwork: transport is WebRtcTransport ? transport.peerNetwork : null,
        fallbackReason:
            selection.fallbackReason ??
            (transport is WebRtcTransport && transport.actualMode == null
                ? RemoteNetworkFallbackReason.pathUnverified
                : null),
        observedAt: DateTime.now(),
      );
      return RemoteHostSession(
        rpc: rpc,
        // api.device was fetched and pin-checked for this exact opening.
        // Do not fall back to host.harnessVersion (a stale listing).
        harnessVersion: peer.harnessVersion,
        capabilities: List.unmodifiable(capabilities),
        workspaceTypes: description!['workspaceTypes'],
        transport: transport.mode.name,
        networkDiagnostics: snapshot(),
        inspectNetwork: () async {
          if (transport is WebRtcTransport) await transport.inspectNetwork();
          return snapshot();
        },
      );
    } on RemoteRpcException catch (error) {
      final closed = channel.closedReason;
      await rpc.close();
      if (error.isLocal && closed != null) {
        throw _asConnectException(SecureChannelException(closed.code, closed.message, retryable: closed.retryable));
      }
      if (probingCapabilities && error.code == 'METHOD_NOT_FOUND') {
        throw const RemoteConnectException(
          RemoteFailure(
            'HARNESS_VERSION_INCOMPATIBLE',
            'The Host plugin predates capability discovery (rc.2 ApiProxy only); update ds-harness-remote on the Host.',
            retryable: false,
          ),
        );
      }
      throw RemoteConnectException(
        RemoteFailure(error.code, error.message, retryable: error.retryable || error.isLocal),
      );
    } on Object {
      await rpc.close();
      rethrow;
    } finally {
      await ownerSub.cancel();
    }
  }

  /// Tries LAN/P2P, then TURN on a fresh tunnel (the Host accepts one offer per
  /// tunnel). An unopened RTC failure can select Relay on that same tunnel.
  /// Noise starts only after selection. Recent failures skip the bad path
  /// for 45 seconds; a changed native network hint clears that cooldown.
  Future<_TransportSelection> _connectTransport(String token, String hostId, bool Function() isCancelled) async {
    final connector = peerConnector;
    if (connector == null) {
      return _TransportSelection(
        await _connectRelay(token, hostId, isCancelled: isCancelled),
        RemoteNetworkFallbackReason.webrtcUnavailable,
      );
    }
    var preferred = RemoteTransportMode.values;
    try {
      final hint = preferredTransports;
      if (hint != null) preferred = (await hint().timeout(const Duration(milliseconds: 500))).toSet().toList();
    } on Object {
      // Native connectivity can be unavailable during startup.
    }
    preferred = [...preferred.where((p) => p != RemoteTransportMode.relay), RemoteTransportMode.relay];
    final hintKey = preferred.map((p) => p.name).join(',');
    final oldHint = _networkHints[hostId];
    _networkHints[hostId] = hintKey;
    if (oldHint != null && oldHint != hintKey) {
      _directCooldown.remove(hostId);
      _turnCooldown.remove(hostId);
    }
    final now = DateTime.now();
    final skipDirect = _directCooldown[hostId]?.isAfter(now) ?? false;
    final skipTurn = _turnCooldown[hostId]?.isAfter(now) ?? false;
    RemoteNetworkFallbackReason? reason = skipDirect ? RemoteNetworkFallbackReason.directRecentlyFailed : null;
    var wantDirect = !skipDirect && preferred.any((p) => p == RemoteTransportMode.lan || p == RemoteTransportMode.p2p);
    var wantTurn = !skipTurn && preferred.contains(RemoteTransportMode.turn);
    // TURN refetches credentials for its new connectionId; a failed direct
    // lookup must not suppress that separately authorized attempt.
    Future<List<RemoteIceServer>> fetchIce(String id) => api.turnCredentials(token, id);

    if (!wantDirect && !wantTurn) {
      return _TransportSelection(await _connectRelay(token, hostId, isCancelled: isCancelled), reason);
    }
    var control = await _connectRelay(token, hostId, direct: true, preferred: preferred, isCancelled: isCancelled);
    if (control.directTransports.isEmpty) {
      return _TransportSelection(control, RemoteNetworkFallbackReason.webrtcUnavailable);
    }
    try {
      wantDirect = wantDirect && control.directTransports.any((p) => p == 'lan' || p == 'p2p');
      wantTurn = wantTurn && control.directTransports.contains('turn');
      var directFailed = false;
      var dataChannelOpened = false;
      if (wantDirect) {
        try {
          final rtc = await WebRtcTransport.negotiate(
            control: control,
            connector: connector,
            iceServers: fetchIce,
            timeout: directTimeout,
            iceServersTimeout: iceServersTimeout,
          );
          return _TransportSelection(rtc, reason);
        } on WebRtcUnavailable catch (error) {
          directFailed = true;
          dataChannelOpened = error.dataChannelOpened;
          reason = error.timedOut
              ? RemoteNetworkFallbackReason.directTimeout
              : RemoteNetworkFallbackReason.directFailed;
          _directCooldown[hostId] = DateTime.now().add(const Duration(seconds: 45));
          _notifyFallback(reason);
        }
      }
      if (isCancelled()) {
        throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
      }
      if (wantTurn) {
        if (directFailed) {
          await control.close();
          control = await _connectRelay(
            token,
            hostId,
            direct: true,
            preferred: const [RemoteTransportMode.turn, RemoteTransportMode.relay],
            isCancelled: isCancelled,
          );
          if (control.directTransports.isEmpty) return _TransportSelection(control, reason);
        }
        try {
          final rtc = await WebRtcTransport.negotiate(
            control: control,
            connector: connector,
            iceServers: fetchIce,
            timeout: directTimeout,
            iceServersTimeout: iceServersTimeout,
            relayOnly: true,
          );
          return _TransportSelection(rtc, reason);
        } on WebRtcUnavailable catch (error) {
          dataChannelOpened = error.dataChannelOpened;
          if (error.turnUnavailable) {
            reason ??= RemoteNetworkFallbackReason.turnUnavailable;
          } else {
            reason = error.timedOut ? RemoteNetworkFallbackReason.turnTimeout : RemoteNetworkFallbackReason.turnFailed;
          }
          _turnCooldown[hostId] = DateTime.now().add(const Duration(seconds: 45));
          // Missing credentials should not duplicate the direct-stage reason.
          if (!error.turnUnavailable || !directFailed) {
            _notifyFallback(reason);
          }
        }
      }
      if (isCancelled()) {
        throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
      }
      if (dataChannelOpened && control.canUseRelay) {
        // The Host already selected RTC and drops this tunnel when its peer closes.
        await control.close();
        control = await _connectRelay(token, hostId, isCancelled: isCancelled);
      } else {
        await control.selectRelay();
      }
      return _TransportSelection(control, reason);
    } on Object {
      await control.close();
      rethrow;
    }
  }

  void _notifyFallback(RemoteNetworkFallbackReason reason) {
    try {
      onDirectFallback?.call(reason.name);
    } on Object {
      // Diagnostic consumers cannot prevent transport fallback.
    }
  }

  Future<RelayTransport> _connectRelay(
    String token,
    String hostId, {
    required bool Function() isCancelled,
    bool direct = false,
    List<RemoteTransportMode>? preferred,
  }) => RelayTransport.connect(
    url: controlSocketUrl(serverUrl),
    deviceId: _identity!.deviceId,
    accessToken: token,
    refreshAccessToken: (forceRefresh) async {
      try {
        return await accessToken(forceRefresh: forceRefresh);
      } on RemoteConnectException catch (error) {
        final failure = error.failure;
        throw RemoteTransportException(failure.code, failure.message, retryable: failure.retryable);
      }
    },
    hostDeviceId: hostId,
    clientVersion: clientVersion,
    connector: _socketConnector,
    isCancelled: isCancelled,
    tracer: controlTracer,
    offerDirect: direct,
    preferredTransports: preferred,
  );

  Future<String> _checkPin(RemoteHost host, AuthorizedPeer peer, HostTrustPrompt? confirm) async {
    final pins = await _loadPins();
    final pinned = pins[host.id];
    if (pinned != null) {
      if (!constantTimeEquals(utf8.encode(pinned.identityKey), utf8.encode(peer.identityKey))) {
        throw RemoteConnectException(
          RemoteFailure(
            'PEER_IDENTITY_MISMATCH',
            'The identity key of Host "${host.name}" changed (pinned ${identityFingerprint(pinned.identityKey)}, '
                'Server reports ${identityFingerprint(peer.identityKey)}). Refusing to connect.',
            retryable: false,
          ),
        );
      }
      return pinned.identityKey;
    }
    if (confirm != null) {
      final candidate = RemoteHost(
        id: host.id,
        name: peer.name,
        platform: peer.platform,
        online: peer.online ?? host.online,
        trust: RemoteHostTrust.unpinned,
        harnessVersion: peer.harnessVersion ?? host.harnessVersion,
        pluginVersion: peer.clientVersion ?? host.pluginVersion,
        lastSeenAt: peer.lastSeenAt,
        identityKey: peer.identityKey,
        membershipId: peer.membershipId,
      );
      if (!await confirm(candidate)) {
        throw const RemoteConnectException(
          RemoteFailure('HOST_NOT_TRUSTED', 'The new Host identity was not confirmed.', retryable: false),
        );
      }
    }
    pins[host.id] = _Pin(peer.identityKey, peer.name, DateTime.now());
    await _savePins(pins);
    return peer.identityKey;
  }

  /// Closes the active connection and the HTTP client.
  Future<void> close() async {
    await _active?.close();
    _active = null;
    await _connectionStates.close();
    api.close();
  }

  // ---------------------------------------------------------------------------

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteConnectException {
      rethrow;
    } on Object catch (error) {
      throw _asConnectException(error);
    }
  }
}

RemoteConnectException _asConnectException(Object error) => switch (error) {
  RemoteConnectException() => error,
  RemoteApiException(:final code, :final message, :final retryable) => RemoteConnectException(
    RemoteFailure(code, message, retryable: retryable || code == 'CONNECTION_FAILED' || code == 'HOST_OFFLINE'),
  ),
  RemoteTransportException(:final code, :final message, :final retryable) => RemoteConnectException(
    RemoteFailure(code, message, retryable: retryable && !_terminalCodes.contains(code)),
  ),
  SecureChannelException(:final code, :final message, :final retryable) => RemoteConnectException(
    RemoteFailure(code, message, retryable: retryable && !_terminalCodes.contains(code)),
  ),
  RemoteRpcException(:final code, :final message) => RemoteConnectException(
    RemoteFailure(code, message, retryable: true),
  ),
  NoiseSessionError(:final code, :final message) => RemoteConnectException(
    RemoteFailure(code, message, retryable: false),
  ),
  ArgumentError() => RemoteConnectException(RemoteFailure('INVALID_ARGUMENT', '$error', retryable: false)),
  _ => RemoteConnectException(RemoteFailure('CONNECTION_FAILED', '$error', retryable: true)),
};

const Set<String> _terminalCodes = {
  'CONNECTION_REPLACED',
  'CONNECTION_REJECTED',
  'PEER_IDENTITY_MISMATCH',
  'MEMBERSHIP_REQUIRED',
  'DEVICE_REVOKED',
  'DEVICE_NOT_FOUND',
  'CAPABILITY_NOT_SUPPORTED',
  'UNSUPPORTED_VERSION',
  'ACCOUNT_AUTH_REQUIRED',
};

// A client's transcript cache must not mix compact and full baselines.
class _HistoryMode {
  _HistoryMode(this.requested);

  final bool requested;
  bool? negotiated;
}

class _ActiveConnection {
  _ActiveConnection(this.client, this.carrier);

  final DshClient client;
  final RemoteTunnelCarrier carrier;
  StreamSubscription<RemoteConnectionState>? stateSub;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await client.close();
    await Future<void>.delayed(Duration.zero);
    await stateSub?.cancel();
  }
}

class _TransportSelection {
  const _TransportSelection(this.transport, this.fallbackReason);
  final SecureHandshakeTransport transport;
  final RemoteNetworkFallbackReason? fallbackReason;
}
