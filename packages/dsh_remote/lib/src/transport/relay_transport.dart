// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Client Control transport: the Server Control WebSocket, plus the
// assigned Relay node data WebSocket when the Server offers one. With
// `offerDirect` it also negotiates WebRTC and carries its signaling
// ([WebRtcTransport] then takes over the data plane).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol/close_semantics.dart';
import '../protocol/control.dart';
import '../util/bytes.dart';
import 'control_lease.dart';
import 'transport.dart';

/// Opens the Control WebSocket (`wss://<server>/ws/v1/connect`); injectable
/// for tests.
typedef ControlSocketConnector = Future<WebSocket> Function(Uri url, Duration timeout);

Future<WebSocket> _defaultConnector(Uri url, Duration timeout) {
  var expired = false;
  // timeout does not cancel the opening Future. Keep ownership of a socket
  // that arrives after the caller has already received the timeout.
  final opening = WebSocket.connect(url.toString()).then((socket) {
    if (expired) unawaited(socket.close(WebSocketStatus.normalClosure).catchError((Object _) {}));
    return socket;
  });
  return opening.timeout(
    timeout,
    onTimeout: () {
      expired = true;
      throw TimeoutException('Future not completed', timeout);
    },
  );
}

/// Diagnostic hook: every Control frame in or out, and Relay data frames as
/// `data-in` / `data-out` (tokens, tickets and ciphertext redacted).
typedef ControlTracer = void Function(String direction, JsonMap frame);

/// Relay transport: `hello` → `hello.ack` → `connect.request` →
/// `connect.accepted`, then Noise handshake and ciphertext in `relay`
/// frames. Answers Server `ping` with `pong`; treats a silent socket
/// (no frame for 3 heartbeats) as dead.
///
/// `transport.relay.attach`: when `connect.accepted` carries a Relay
/// assignment (`relayEndpoint`, `relayTicket`, `relayNodeId`, `relayEpoch`),
/// the client opens that data WebSocket, sends `relay.attach` with the
/// ticket (the ticket never goes on the Control socket), waits for
/// `relay.ready`, then announces `transport.selected` (`relay`). The Noise
/// handshake stays on the Control socket; `relay` frames and the node's
/// heartbeats move to the data socket. `relay.detach` or a dropped data
/// socket ends the connection: Noise state is never carried over, the
/// caller opens a new one. Without an independent assignment, ciphertext
/// stays on Control and the connection is not eligible for detached recovery.
///
/// Direct paths (`offerDirect`): the client also offers `transport.lan`,
/// `transport.p2p` and `transport.turn`. When the Server negotiates any of
/// them (and does not send `webrtcEnabled: false`), `connect.request` lists
/// them before `relay` and [connect] returns at `connect.accepted` with the
/// data plane still open: [directTransports] is non-empty, nothing is
/// attached and no `transport.selected` was sent. The caller then
/// negotiates WebRTC over [sendSignal] / [onSignal] ([WebRtcTransport]), or
/// calls [selectRelay] on this tunnel if negotiation fails. A confirmed lease
/// retains the channel only while its independent data plane remains alive.
///
/// One Control WebSocket per device: the Server closes an older socket of
/// the same device (`CONNECTION_REPLACED`, close code 4003), and a new
/// `connect.request` replaces the device's previous Host connection.
class RelayTransport implements LeaseAwareTransport {
  RelayTransport._(
    this._socket,
    this._deviceId,
    this._hostDeviceId,
    this._tracer,
    this._connector,
    this._timeout,
    this._offered,
    this._preferredTransports,
    this._url,
    this._accessToken,
    this._clientVersion,
    this._refreshAccessToken,
    this._isCancelled,
  );

  /// Connects and waits for `connect.accepted`.
  ///
  /// Throws [RemoteTransportException]: `CONNECTION_FAILED` (socket, timeout),
  /// `AUTH_INVALID` / `TOKEN_EXPIRED` (access token refused — refresh and
  /// retry once), `HOST_OFFLINE`, `MEMBERSHIP_REQUIRED`,
  /// `CAPABILITY_NOT_SUPPORTED`, `CONNECTION_REJECTED` (Host refused),
  /// `INVALID_MESSAGE` (protocol violation).
  ///
  /// [isCancelled] retires an owner's pending socket before it can send hello.
  /// A socket that arrives after cancellation is closed without authentication;
  /// this does not retract a hello that was already sent.
  static Future<RelayTransport> connect({
    required Uri url,
    required String deviceId,
    required String accessToken,
    required String hostDeviceId,
    String? clientVersion,
    Duration timeout = const Duration(seconds: 10),
    ControlSocketConnector? connector,
    bool Function()? isCancelled,
    ControlTracer? tracer,
    bool offerDirect = false,
    List<RemoteTransportMode>? preferredTransports,
    Future<String> Function(bool forceRefresh)? refreshAccessToken,
  }) async {
    if (isCancelled?.call() == true) {
      throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
    }
    final connect = connector ?? _defaultConnector;
    final WebSocket socket;
    try {
      socket = await connect(url, timeout);
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      throw RemoteTransportException(
        status == 401 || status == 403 ? 'AUTH_INVALID' : 'CONNECTION_FAILED',
        'Control WebSocket failed${status == null ? '' : ' (HTTP $status)'}.',
        retryable: status != 401 && status != 403,
      );
    } on TimeoutException {
      throw const RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect timed out.');
    } on SocketException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect failed: ${error.message}');
    } on HttpException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect failed: ${error.message}');
    } on HandshakeException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'TLS handshake failed: ${error.message}');
    }
    if (isCancelled?.call() == true) {
      unawaited(socket.close(WebSocketStatus.normalClosure).catchError((Object _) {}));
      throw const RemoteTransportException('CLIENT_CLOSED', 'The connection owner closed.', retryable: false);
    }
    final transport = RelayTransport._(
      socket,
      deviceId,
      hostDeviceId,
      tracer,
      connect,
      timeout,
      offerDirect ? _directOffered : _relayOffered,
      preferredTransports,
      url,
      accessToken,
      clientVersion,
      refreshAccessToken,
      isCancelled,
    );
    try {
      await transport._open(accessToken).timeout(timeout);
      transport._ready = null;
      if (transport.directTransports.isEmpty) await transport.selectRelay();
      return transport;
    } on TimeoutException {
      await transport.close();
      throw const RemoteTransportException('CONNECTION_FAILED', 'Relay control handshake timed out.');
    } on Object {
      await transport.close();
      rethrow;
    }
  }

  static const List<String> _relayOffered = [relayResumeCapability, 'transport.relay', 'transport.relay.attach'];
  static const List<String> _directOffered = [
    webRtcResumeCapability,
    relayResumeCapability,
    'transport.lan',
    'transport.p2p',
    'transport.turn',
    'transport.relay',
    'transport.relay.attach',
  ];

  WebSocket? _socket;
  final Uri _url;
  final String _accessToken;
  final String? _clientVersion;
  final Future<String> Function(bool forceRefresh)? _refreshAccessToken;
  final bool Function()? _isCancelled;
  final String _deviceId;
  final String _hostDeviceId;
  final ControlTracer? _tracer;
  final ControlSocketConnector _connector;
  final Duration _timeout;
  final List<String> _offered;
  final List<RemoteTransportMode>? _preferredTransports;
  ControlFrameLimits _limits = const ControlFrameLimits();
  String? _connectionId;
  List<String> _direct = const [];
  int? _webrtcFallbackMs;
  List<String> _negotiated = const [];

  // hello.ack sets readiness for one socket; loss clears it. Generation checks
  // retire late opens/frames on loss or close; only recovery hello + lease ack
  // reauthorize the original tunnel. A failed recovery closes this lifetime.
  bool _controlReady = false;
  int _controlGeneration = 0;
  bool _authRecoveryAttempted = false;
  // One timer: either jitter before dialing or the deadline until hello.ack.
  Timer? _recoveryTimer;

  // connect.accepted owns assignments/tickets until terminal cleanup. The lease
  // rotates its selected ticket on ack; no unconfirmed ticket is sent in hello.
  JsonMap? _relayAssignment;
  String? _recoveryTicket;
  String? _relayRecoveryTicket;
  ControlLease? _lease;
  bool Function()? _webRtcAlive;

  /// Relay node data socket, once assigned.
  WebSocket? _data;
  int? _relayEpoch;
  // Only matching relay.ready sets data readiness. Data loss invalidates the
  // whole tunnel; the carrier obtains a fresh assignment and Noise session.
  bool _dataReady = false;
  Completer<void>? _dataOpening;
  Completer<void>? _ready;
  int _heartbeatMs = 25000;
  DateTime _lastReceived = DateTime.now();
  Timer? _watchdog;
  bool _closed = false;
  bool _closedNotified = false;

  TransportDataHandler? _onData;
  TransportHandshakeHandler? _onHandshake;
  TransportClosedHandler? _onClosed;
  final List<void Function()> _backlog = [];
  RemoteTransportClosed? _pendingClose;

  /// Negotiated `hello.ack` heartbeat.
  Duration get heartbeatInterval => Duration(milliseconds: _heartbeatMs);

  /// Direct paths both sides negotiated, in the configured preference order;
  /// empty when this connection uses the Relay.
  List<String> get directTransports => _direct;

  /// `hello.ack.webrtcFallbackTimeoutMs`, when the Server sets one.
  Duration? get webrtcFallbackTimeout => _webrtcFallbackMs == null ? null : Duration(milliseconds: _webrtcFallbackMs!);

  /// Receives this connection's `signal.answer`, `signal.ice` and
  /// `transport.selected` frames (WebRTC negotiation).
  void Function(ControlFrame frame)? onSignal;

  @override
  RemoteTransportMode get mode => RemoteTransportMode.relay;

  @override
  RemoteConnectionInfo get info {
    final id = _connectionId;
    if (id == null) throw StateError('relay connection has not been authorized');
    return RemoteConnectionInfo(connectionId: id, localDeviceId: _deviceId, remoteDeviceId: _hostDeviceId);
  }

  Future<void> _open(String accessToken) {
    final ready = _ready = Completer<void>();
    _listenControl(_socket!);
    _sendHello(accessToken);
    return ready.future;
  }

  void _listenControl(WebSocket socket) {
    socket.listen(
      (raw) {
        if (identical(_socket, socket)) _onMessage(raw);
      },
      onError: (Object _) {
        if (identical(_socket, socket)) {
          _controlLost(const RemoteTransportClosed('CONNECTION_FAILED', 'Control socket failed.'));
        }
      },
      onDone: () {
        if (identical(_socket, socket)) _onControlClosed(socket);
      },
      cancelOnError: true,
    );
  }

  void _sendHello(String token) {
    final ticket = _lease?.recoveryTicket;
    _sendControl('hello', {
      'role': 'client',
      'deviceId': _deviceId,
      'accessToken': token,
      'protocols': [protocolVersion],
      'capabilities': _offered,
      'clientVersion': ?_clientVersion,
      if (ticket != null) 'recoveryTickets': [ticket],
    });
  }

  void _onControlClosed(WebSocket socket) {
    final code = socket.closeCode;
    final reason = socket.closeReason?.trim() ?? '';
    // Current recovery authorization failure: retire the old tunnel/ticket,
    // then let the existing carrier establish a new Noise session.
    if (_lease != null &&
        !_controlReady &&
        (code == 4012 || (code == 4002 && reason == 'recovery authorization rejected'))) {
      _fail(RemoteTransportClosed('RECOVERY_REJECTED', 'Recovery authorization rejected.', closeCode: code));
      return;
    }
    if (_lease != null &&
        !_controlReady &&
        (code == 4002 || (code == 4001 && (reason == 'AUTH_INVALID' || reason == 'TOKEN_EXPIRED')))) {
      _recoverAuthentication();
      return;
    }
    // dart:io reports an empty Close frame as a synthetic 1005.
    final semantics = classifyControlClose(code == WebSocketStatus.noStatusReceived ? null : code, reason);
    final semanticCode = semantics.replaced
        ? 'CONNECTION_REPLACED'
        : semantics.serverShutdown
        ? 'SERVER_SHUTDOWN'
        : semantics.heartbeatTimeout
        ? 'HEARTBEAT_TIMEOUT'
        : code == 4004
        ? 'DEVICE_REVOKED'
        : code == 4011
        ? 'UNSUPPORTED_VERSION'
        : (code == 4001 && const ['AUTH_INVALID', 'TOKEN_EXPIRED', 'DEVICE_REVOKED'].contains(reason))
        ? reason
        : code == 4002
        ? 'AUTH_INVALID'
        : 'CONNECTION_FAILED';
    // Never include arbitrary close text in diagnostics.
    final detail = semantics.serverShutdown
        ? 'server shutdown'
        : semantics.heartbeatTimeout
        ? 'heartbeat timeout'
        : semanticCode;
    _controlLost(
      RemoteTransportClosed(
        semanticCode,
        'Control channel closed (${code ?? 'no code'} $detail).',
        retryable: semantics.retryable,
        closeCode: code,
      ),
    );
  }

  static const Set<String> _retryableCodes = {
    'CONNECTION_FAILED',
    'HOST_OFFLINE',
    'RATE_LIMITED',
    'SLOW_CONSUMER',
    'RELAY_UNAVAILABLE',
  };

  void _onMessage(Object? raw) {
    final ControlFrame frame;
    try {
      if (raw is! String) throw const ProtocolError('Relay control frames must be text JSON.');
      frame = decodeControlFrame(raw, _limits);
    } on ProtocolError catch (error) {
      // A frame this client cannot parse (unknown type, bad field, newer
      // protocol version, oversize) fails the same way on every attempt:
      // stop rather than reconnect forever. Retrying is left to the person.
      // PROTOCOL_MISMATCH tells it apart from a REST reply that was not JSON
      // (a captive portal or proxy), which shares INVALID_MESSAGE.
      final code = error.code == 'INVALID_MESSAGE' ? 'PROTOCOL_MISMATCH' : error.code;
      _fail(RemoteTransportClosed(code, error.message, retryable: false));
      return;
    }
    _lastReceived = DateTime.now();
    _trace('in', frame.toJson());
    try {
      _handle(frame);
    } on ProtocolError catch (error) {
      // Assignment races may be retried; protocol/capability/auth failures may not.
      _fail(RemoteTransportClosed(error.code, error.message, retryable: !_incompatibleCodes.contains(error.code)));
    } on RemoteTransportException catch (error) {
      _controlLost(RemoteTransportClosed(error.code, error.message, retryable: error.retryable));
    }
  }

  /// [ProtocolError] codes that say the two sides do not speak the same protocol.
  static const Set<String> _incompatibleCodes = {
    'UNSUPPORTED_VERSION',
    'PROTOCOL_MISMATCH',
    'CAPABILITY_NOT_SUPPORTED',
    'FRAME_TOO_LARGE',
    'AUTH_INVALID',
    'TOKEN_EXPIRED',
    'DEVICE_REVOKED',
    'CONNECTION_REPLACED',
    'PEER_IDENTITY_MISMATCH',
  };

  void _handle(ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'hello.ack':
        if (_controlReady) throw const ProtocolError('Unexpected hello.ack.');
        try {
          _negotiated = acceptNegotiatedCapabilities(_offered, (p['capabilities'] as List<Object?>?)?.cast<String>());
        } on ProtocolError catch (error) {
          throw ProtocolError(error.message, 'CAPABILITY_NOT_SUPPORTED');
        }
        _limits = ControlFrameLimits(
          maxControlFrameBytes: p['maxControlFrameBytes']! as int,
          maxRelayFrameBytes: p['maxRelayFrameBytes']! as int,
        );
        _heartbeatMs = p['heartbeatIntervalMs']! as int;
        _direct = p['webrtcEnabled'] == false
            ? const []
            : [
                for (final t in (_preferredTransports?.map((t) => t.name) ?? const ['lan', 'p2p', 'turn']))
                  if (t != 'relay' && _negotiated.contains('transport.$t')) t,
              ];
        _webrtcFallbackMs = asInt(p['webrtcFallbackTimeoutMs']);
        if (_direct.isEmpty && !canUseRelay) {
          throw const ProtocolError('Server did not negotiate a supported transport.', 'CAPABILITY_NOT_SUPPORTED');
        }
        final lease = _lease;
        if (lease != null) {
          final required = _webRtcAlive != null ? webRtcResumeCapability : relayResumeCapability;
          if (!_negotiated.contains(required)) {
            _fail(
              const RemoteTransportClosed(
                'RECOVERY_REJECTED',
                'Server no longer negotiated the active transport recovery capability.',
              ),
            );
            return;
          }
        }
        _controlReady = true;
        _watchdog = Timer.periodic(heartbeatInterval, (_) => checkControlHealth());
        if (lease != null) {
          // The hello deadline is independent of the lease ack window.
          _recoveryTimer?.cancel();
          _recoveryTimer = null;
          lease.tick(force: true);
          return;
        }
        _sendControl('connect.request', {
          'hostDeviceId': _hostDeviceId,
          'preferredTransports': [..._direct, if (canUseRelay) 'relay'],
        });
      case 'connect.accepted':
        final ready = _ready;
        if (!_controlReady || ready == null || ready.isCompleted || _connectionId != null) {
          throw const ProtocolError('Unexpected connect.accepted.');
        }
        _connectionId = p['connectionId']! as String;
        _recoveryTicket = _negotiated.contains(webRtcResumeCapability) ? asString(p['recoveryTicket']) : null;
        _relayRecoveryTicket = _negotiated.contains(relayResumeCapability) ? asString(p['relayRecoveryTicket']) : null;
        _webrtcFallbackMs = asInt(p['webrtcFallbackTimeoutMs']) ?? _webrtcFallbackMs;
        if (p['relayEndpoint'] is String && p['relayTicket'] is String) _relayAssignment = p;
        ready.complete();
      case 'connection.lease.ack':
        final lease = _lease;
        if (lease == null) throw const ProtocolError('Unexpected connection lease.');
        if (lease.acknowledge(p)) _authRecoveryAttempted = false;
      case 'connect.rejected':
        if (_connectionId != null && p['connectionId'] != _connectionId) return;
        final code = asString(p['code']) ?? 'CONNECTION_REJECTED';
        _fail(
          RemoteTransportClosed(
            code,
            asString(p['message']) ?? 'The Host rejected the connection.',
            // The Server rejects with HOST_OFFLINE while a Host sleeps: keep
            // backing off so it reconnects once the Host is back.
            retryable: _retryableCodes.contains(code),
          ),
        );
      case 'error':
        final connectionId = asString(p['connectionId']);
        if (connectionId != null && _connectionId != null && connectionId != _connectionId) return;
        final code = p['code']! as String;
        if (_lease != null && !_controlReady && (code == 'AUTH_INVALID' || code == 'TOKEN_EXPIRED')) {
          _recoverAuthentication();
          return;
        }
        _fail(
          RemoteTransportClosed(
            code,
            p['message']! as String,
            retryable:
                !_incompatibleCodes.contains(code) && ((p['retryable'] as bool?) ?? _retryableCodes.contains(code)),
          ),
        );
      case 'relay':
        // Ciphertext belongs to the data socket once the node assigned one.
        if (_data != null) return;
        _receiveRelay(p);
      case 'secure.handshake':
        _receiveHandshake(p);
      case 'signal.answer' || 'signal.ice' || 'transport.selected':
        if (p['connectionId'] == _connectionId && p['targetDeviceId'] == _deviceId) onSignal?.call(frame);
      case 'ping':
        _sendControl('pong', {'nonce': p['nonce']});
      default:
        // pong, offers and Host-only frames are not for a client.
        break;
    }
  }

  void _receiveRelay(JsonMap p) {
    if (p['connectionId'] != _connectionId || p['targetDeviceId'] != _deviceId) {
      throw const ProtocolError('Received a relay frame for an unknown connection.');
    }
    if (_data != null && !_dataReady) throw const ProtocolError('Relay data arrived before relay.ready.');
    if (_lease?.isValid == false) return;
    final data = fromBase64Url(p['ciphertext']! as String);
    final counter = p['counter']! as int;
    _deliver(() => _onData!(data, counter));
  }

  void _receiveHandshake(JsonMap p) {
    if (p['connectionId'] != _connectionId || p['targetDeviceId'] != _deviceId) {
      throw const ProtocolError('Received a secure handshake frame for an unknown connection.');
    }
    final data = fromBase64Url(p['data']! as String);
    final step = p['step']! as int;
    _deliver(() => _onHandshake!(step, data));
  }

  // ---------------------------------------------------------------------------
  // Relay node data socket

  bool get canUseRelay => _negotiated.contains('transport.relay');

  /// Select Relay on this already-authorized tunnel after a provisional RTC
  /// attempt fails. No Noise state exists yet; no new Control tunnel is needed.
  Future<void> selectRelay() async {
    _requireConnection();
    if (!canUseRelay) {
      throw const RemoteTransportException(
        'CAPABILITY_NOT_SUPPORTED',
        'Server did not negotiate Relay fallback.',
        retryable: false,
      );
    }
    final assignment = _relayAssignment;
    if (assignment != null) {
      final ready = _dataOpening = Completer<void>();
      _relayEpoch = asInt(assignment['relayEpoch']);
      unawaited(_attach(Uri.parse(assignment['relayEndpoint']! as String), assignment['relayTicket']! as String));
      try {
        await ready.future.timeout(_timeout);
      } on TimeoutException {
        _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'Relay data attach timed out.'));
        throw const RemoteTransportException('CONNECTION_FAILED', 'Relay data attach timed out.');
      } finally {
        _dataOpening = null;
      }
    }
    _requireConnection();
    _sendControl('transport.selected', {
      'connectionId': _connectionId,
      'targetDeviceId': _hostDeviceId,
      'transport': 'relay',
    });
  }

  Future<void> _attach(Uri endpoint, String ticket) async {
    final WebSocket socket;
    try {
      socket = await _connector(endpoint, _timeout);
    } on Object {
      _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'Relay data socket failed.'));
      return;
    }
    if (_closed) {
      unawaited(socket.close(1000).catchError((Object _) {}));
      return;
    }
    _data = socket;
    socket.listen(
      (raw) {
        if (identical(_data, socket)) _onDataMessage(raw);
      },
      onError: (Object _) {
        if (identical(_data, socket)) {
          _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'Relay data socket failed.'));
        }
      },
      onDone: () {
        if (identical(_data, socket)) {
          _fail(RemoteTransportClosed('CONNECTION_FAILED', 'Relay data socket closed.', closeCode: socket.closeCode));
        }
      },
      cancelOnError: true,
    );
    try {
      _sendData('relay.attach', {
        'connectionId': _connectionId,
        'deviceId': _deviceId,
        'peerDeviceId': _hostDeviceId,
        'ticket': ticket,
      });
    } on ProtocolError catch (error) {
      _fail(RemoteTransportClosed(error.code, error.message, retryable: false));
    } on RemoteTransportException catch (error) {
      _fail(RemoteTransportClosed(error.code, error.message, retryable: error.retryable));
    }
  }

  void _onDataMessage(Object? raw) {
    if (_closed) return;
    final ControlFrame frame;
    try {
      if (raw is! String) throw const ProtocolError('Relay data frames must be text JSON.');
      frame = decodeRelayDataFrame(raw, _limits);
    } on ProtocolError catch (error) {
      final code = error.code == 'INVALID_MESSAGE' ? 'PROTOCOL_MISMATCH' : error.code;
      _fail(RemoteTransportClosed(code, error.message, retryable: false));
      return;
    }
    _trace('data-in', frame.toJson());
    try {
      _handleData(frame);
    } on ProtocolError catch (error) {
      _fail(RemoteTransportClosed(error.code, error.message, retryable: !_incompatibleCodes.contains(error.code)));
    } on RemoteTransportException catch (error) {
      _fail(RemoteTransportClosed(error.code, error.message, retryable: error.retryable));
    }
  }

  void _handleData(ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'relay.ready':
        if (p['connectionId'] != _connectionId ||
            (_relayEpoch != null && p['epoch'] != _relayEpoch) ||
            (p.containsKey('deviceId') && p['deviceId'] != _deviceId) ||
            (p.containsKey('peerDeviceId') && p['peerDeviceId'] != _hostDeviceId)) {
          throw const ProtocolError('Relay data attach does not match the assigned connection.');
        }
        _dataReady = true;
        final opening = _dataOpening;
        if (opening != null && !opening.isCompleted) opening.complete();
      case 'relay.detach':
        _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'The Host detached from the Relay node.'));
      case 'ping':
        _sendData('pong', p);
      case 'relay':
        _receiveRelay(p);
      case 'secure.handshake':
        _receiveHandshake(p);
      default:
        break;
    }
  }

  void _sendData(String type, JsonMap payload) {
    final frame = ControlFrame(type, payload);
    final encoded = encodeRelayDataFrame(frame, _limits);
    _trace('data-out', frame.toJson());
    final socket = _data;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'Relay data socket is not open.');
    }
    try {
      socket.add(encoded);
    } on Object {
      throw const RemoteTransportException('CONNECTION_FAILED', 'Relay data socket write failed.');
    }
  }

  void _deliver(void Function() action) {
    if (_onData == null) {
      _backlog.add(action);
    } else {
      action();
    }
  }

  @override
  void checkControlHealth() {
    // The deadline also applies while Control is detached or the app was suspended.
    if (_lease?.isValid == false || !_controlReady) return;
    final timeoutMs = math.max(15000, _heartbeatMs * 3);
    if (DateTime.now().difference(_lastReceived).inMilliseconds >= timeoutMs) {
      _controlLost(const RemoteTransportClosed('HEARTBEAT_TIMEOUT', 'Control heartbeat timed out.', closeCode: 4009));
    }
  }

  /// Called by WebRtcTransport only after DataChannel open + selected. Closing
  /// that transport makes the callback false; final cleanup removes it. A
  /// provisional failed attempt never registers a recoverable data plane.
  void confirmWebRtcDataPlane(bool Function() isAlive) => _webRtcAlive = isAlive;

  bool get _dataPlaneAlive => _webRtcAlive?.call() ?? (_dataReady && _data?.readyState == WebSocket.open);

  @override
  void markSecureReady() {
    if (!_controlReady || _lease != null || !_dataPlaneAlive) return;
    final ticket = _webRtcAlive != null ? _recoveryTicket : _relayRecoveryTicket;
    if (ticket == null) return;
    _recoveryTicket = null;
    _relayRecoveryTicket = null;
    _lease = ControlLease(_connectionId!, ticket, (payload) {
      checkControlHealth();
      if (!_controlReady) return false;
      try {
        _sendControl('connection.lease.request', payload);
        return true;
      } on ProtocolError catch (error) {
        _fail(RemoteTransportClosed(error.code, error.message, retryable: false));
        return false;
      } on RemoteTransportException {
        _controlLost(const RemoteTransportClosed('CONNECTION_FAILED', 'Control lease send failed.'));
        return false;
      }
    }, () => _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'Control authorization lease expired.')));
    _lease!.start();
  }

  void _recoverAuthentication() {
    if (_authRecoveryAttempted || _refreshAccessToken == null) {
      _fail(const RemoteTransportClosed('AUTH_INVALID', 'Server rejected refreshed credentials.', retryable: false));
      return;
    }
    _controlLost(
      const RemoteTransportClosed('CONNECTION_FAILED', 'Control authentication requires refresh.'),
      forceRefresh: true,
    );
  }

  void _controlLost(RemoteTransportClosed reason, {bool forceRefresh = false}) {
    if (_closed) return;
    if (_isCancelled?.call() == true) {
      _fail(const RemoteTransportClosed('CLIENT_CLOSED', 'The connection owner closed.', retryable: false));
      return;
    }
    if (!reason.retryable || _lease?.canDetach != true || !_dataPlaneAlive) {
      _fail(reason);
      return;
    }
    final socket = _socket;
    _socket = null;
    _controlGeneration++;
    _controlReady = false;
    _watchdog?.cancel();
    _lease!.controlLost();
    _recoveryTimer?.cancel();
    unawaited(socket?.close().catchError((Object _) {}));
    // Current AdaptiveTransport uses full jitter [0,15s] for every attempt,
    // including server shutdown; the confirmed lease is the total retry bound.
    _recoveryTimer = Timer(Duration(milliseconds: (math.Random().nextDouble() * 15000).floor()), () {
      _recoveryTimer = null;
      unawaited(_reopenControl(forceRefresh: forceRefresh));
    });
  }

  Future<void> _reopenControl({required bool forceRefresh}) async {
    if (_isCancelled?.call() == true) {
      _fail(const RemoteTransportClosed('CLIENT_CLOSED', 'The connection owner closed.', retryable: false));
      return;
    }
    final generation = _controlGeneration;
    if (_closed || _lease?.canDetach != true) return;
    bool current() => !_closed && generation == _controlGeneration && _isCancelled?.call() != true;
    var needsRefresh = forceRefresh;
    _recoveryTimer = Timer(const Duration(seconds: 15), () {
      if (current()) {
        _controlLost(
          const RemoteTransportClosed('CONNECTION_FAILED', 'Control recovery handshake timed out.'),
          forceRefresh: needsRefresh,
        );
      }
    });
    try {
      final token = _refreshAccessToken == null ? _accessToken : await _refreshAccessToken(forceRefresh);
      if (!current() || _lease?.canDetach != true) return;
      if (forceRefresh) _authRecoveryAttempted = true;
      needsRefresh = false;
      final socket = await _connector(_url, _timeout);
      if (!current() || _lease?.canDetach != true) {
        unawaited(socket.close(1000).catchError((Object _) {}));
        return;
      }
      _socket = socket;
      _limits = const ControlFrameLimits();
      _listenControl(socket);
      _sendHello(token);
    } on RemoteTransportException catch (error) {
      if (current()) {
        _controlLost(
          RemoteTransportClosed(error.code, error.message, retryable: error.retryable),
          forceRefresh: needsRefresh,
        );
      }
    } on ProtocolError catch (error) {
      if (current()) _fail(RemoteTransportClosed(error.code, error.message, retryable: false));
    } on Object {
      if (current()) {
        _controlLost(
          const RemoteTransportClosed('CONNECTION_FAILED', 'Control recovery unavailable.'),
          forceRefresh: needsRefresh,
        );
      }
    }
  }

  @override
  void listen({
    required TransportDataHandler onData,
    required TransportHandshakeHandler onHandshake,
    required TransportClosedHandler onClosed,
  }) {
    _onData = onData;
    _onHandshake = onHandshake;
    _onClosed = onClosed;
    final backlog = [..._backlog];
    _backlog.clear();
    for (final action in backlog) {
      action();
    }
    final pending = _pendingClose;
    if (pending != null && !_closedNotified) {
      _closedNotified = true;
      onClosed(pending);
    }
  }

  @override
  Future<void> sendHandshake(int step, Uint8List data) async {
    final id = _requireConnection();
    _sendControl('secure.handshake', {
      'connectionId': id,
      'targetDeviceId': _hostDeviceId,
      'step': step,
      'data': toBase64Url(data),
    });
  }

  /// Sends a WebRTC signaling frame ([type] `signal.offer`, `signal.ice` or
  /// `transport.selected`) for this connection to the Host.
  void sendSignal(String type, JsonMap payload) {
    _sendControl(type, {'connectionId': _requireConnection(), 'targetDeviceId': _hostDeviceId, ...payload});
  }

  @override
  Future<void> send(Uint8List ciphertext, {required int counter}) async {
    final payload = {
      'connectionId': _requireConnection(),
      'targetDeviceId': _hostDeviceId,
      'counter': counter,
      'ciphertext': toBase64Url(ciphertext),
    };
    if (_data != null) {
      _sendData('relay', payload);
    } else {
      _sendControl('relay', payload);
    }
  }

  String _requireConnection() {
    final id = _connectionId;
    if (_lease?.isValid == false || _closed) throw _asException(_pendingClose!);
    if (id == null) throw StateError('relay connection has not been authorized');
    return id;
  }

  void _sendControl(String type, JsonMap payload) {
    final socket = _socket;
    if (_closed || socket == null || socket.readyState != WebSocket.open) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'The relay control socket is closed.');
    }
    final frame = ControlFrame(type, payload);
    final encoded = encodeControlFrame(frame, _limits);
    _trace('out', frame.toJson());
    try {
      socket.add(encoded);
    } on Object {
      throw const RemoteTransportException('CONNECTION_FAILED', 'Control socket write failed.');
    }
  }

  void _trace(String direction, JsonMap frame) {
    final tracer = _tracer;
    if (tracer == null) return;
    final payload = asMapOrEmpty(frame['payload']);
    tracer(direction, {
      ...frame,
      'payload': {
        ...payload,
        if (payload.containsKey('accessToken')) 'accessToken': '<redacted>',
        if (payload.containsKey('relayEndpoint')) 'relayEndpoint': '<redacted>',
        if (payload.containsKey('relayTicket')) 'relayTicket': '<redacted>',
        if (payload.containsKey('recoveryTicket')) 'recoveryTicket': '<redacted>',
        if (payload.containsKey('relayRecoveryTicket')) 'relayRecoveryTicket': '<redacted>',
        if (payload.containsKey('recoveryTickets')) 'recoveryTickets': '<redacted>',
        if (payload.containsKey('data')) 'data': '<redacted>',
        if (payload.containsKey('ticket')) 'ticket': '<redacted>',
        if (payload.containsKey('ciphertext')) 'ciphertext': '<redacted>',
        // SDP and candidates carry the device's network addresses.
        if (payload.containsKey('sdp')) 'sdp': '<redacted>',
        if (payload.containsKey('candidate')) 'candidate': '<redacted>',
      },
    });
  }

  void _closeLease() {
    if (_lease != null && _controlReady && _socket?.readyState == WebSocket.open) {
      try {
        _sendControl('connection.lease.close', {'connectionId': _connectionId});
      } on Object {
        // A failed close write must not keep local authorization alive.
      }
    }
  }

  void _dispose() {
    _closed = true;
    _controlReady = false;
    _watchdog?.cancel();
    _watchdog = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _lease?.stop();
    _lease = null;
    _recoveryTicket = null;
    _relayRecoveryTicket = null;
    _relayAssignment = null;
    _webRtcAlive = null;
    _dataReady = false;
    _backlog.clear();
    final data = _data;
    final socket = _socket;
    _data = null;
    _socket = null;
    unawaited(data?.close(1000).catchError((Object _) {}));
    unawaited(socket?.close(1000).catchError((Object _) {}));
  }

  void _fail(RemoteTransportClosed reason) {
    if (_closed) return;
    _pendingClose = reason;
    _closeLease();
    _dispose();
    final failure = _asException(reason);
    final opening = _dataOpening;
    if (opening != null && !opening.isCompleted) opening.completeError(failure);
    _dataOpening = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(failure);
      ready.future.ignore();
    } else if (_onClosed != null) {
      if (!_closedNotified) {
        _closedNotified = true;
        _onClosed!(reason);
      }
    }
  }

  RemoteTransportException _asException(RemoteTransportClosed reason) =>
      RemoteTransportException(reason.code, reason.message, retryable: reason.retryable, closeCode: reason.closeCode);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closedNotified = true;
    _fail(const RemoteTransportClosed('CLIENT_CLOSED', 'The client closed the connection.', retryable: false));
  }
}
