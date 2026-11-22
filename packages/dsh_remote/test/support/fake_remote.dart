// In-process imitation of a ds-harness-remote Server (REST + Control
// gateway, modelled on upstream apps/server, plus an optional Relay node for
// `transport.relay.attach` and WebRTC signaling like the hosted Server) and a
// Host plugin (Noise responder + harness.remote.* bridge + WebRTC answerer,
// modelled on upstream packages/plugin/src/server-connection.ts and
// harness-remote-bridge.ts).
// Upstream: https://github.com/liguobao/ds-harness-remote (MIT).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_remote/src/carrier/tunnel_carrier.dart' show harnessRemoteAllowlist;
import 'package:dsh_remote/src/crypto/noise_ik.dart';
import 'package:dsh_remote/src/protocol/control.dart';
import 'package:dsh_remote/src/protocol/messages.dart';
import 'package:dsh_remote/src/transport/rtc_chunking.dart';
import 'package:dsh_remote/src/util/bytes.dart';

import 'fake_rtc.dart';

class FakeDevice {
  FakeDevice(this.descriptor);
  Map<String, Object?> descriptor;
  bool revoked = false;
  String get id => descriptor['deviceId']! as String;
  String get role => descriptor['role']! as String;
}

class FakeToken {
  FakeToken(this.kind, this.deviceId, this.expires);
  final String kind;
  final String deviceId;
  DateTime expires;
  bool used = false;
}

class FakePeer {
  FakePeer(this.ws, this.id, this.role, this.capabilities);
  final WebSocket ws;
  final String id;
  final String role;
  final List<String> capabilities;
}

class FakeLink {
  FakeLink(this.id, this.host, this.client);
  final String id;
  final String host;
  final String client;
  String stage = 'pending';
  final Map<String, int> counters = {};

  // connect.request mints per-device tickets. A matching lease request rotates
  // leases; only that confirmed ticket authorizes hello recovery. Link removal
  // or lease.close retires them; a fresh connection starts with empty maps.
  final Map<String, String> recoveryTickets = {};
  final Map<String, String> relayRecoveryTickets = {};
  final Map<String, String> leases = {};

  /// Relay assignment per device id (`transport.relay.attach`).
  final Map<String, Map<String, Object?>> assignments = {};
}

/// One device side attached to the fake Relay node.
class FakeRelayAttachment {
  FakeRelayAttachment(this.ws, this.connectionId, this.deviceId, this.peerDeviceId);
  final WebSocket ws;
  final String connectionId;
  final String deviceId;
  final String peerDeviceId;
}

class FakeRemoteServer {
  FakeRemoteServer._(this._server);

  static const account = 'e2e@example.test';
  static const password = 'fake-password-123';

  static Future<FakeRemoteServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeRemoteServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  final Map<String, FakeDevice> devices = {};
  final Map<String, FakeToken> _tokens = {};
  final Set<String> _webTokens = {};
  final Map<String, Map<String, Object?>> _qr = {};
  final Map<String, FakePeer> peers = {};
  final Map<String, FakeLink> links = {};
  final List<String> requests = [];

  /// One-shot response gates for real HTTP cancellation tests.
  Future<void> Function()? beforeQrPollResponse;
  Future<void> Function()? beforeAccountLookupResponse;
  Future<void> Function()? beforeRegistrationResponse;
  Future<void> Function()? beforeRefreshRequest;
  Future<void> Function()? beforeRefreshResponse;
  Future<void> Function()? beforeRevokeResponse;
  bool failNextRevoke = false;
  bool failNextRefresh = false;
  final responses = <({String method, String path, int status})>[];
  Duration accessTtl = const Duration(hours: 1);
  int refreshCount = 0;
  int controlConnects = 0;

  /// When set, hello is answered with this error code and the socket closed.
  String? rejectHelloWith;

  Future<void> close() async {
    for (final peer in [...peers.values]) {
      await peer.ws.close();
    }
    await _server.close(force: true);
  }

  String _secret() => toBase64Url(randomBytes(32));

  Map<String, Object?> _issue(String deviceId, {DateTime? refreshExpires}) {
    final access = _secret();
    final refresh = _secret();
    final accessExpires = DateTime.now().add(accessTtl);
    final refreshExpiresAt = refreshExpires ?? DateTime.now().add(const Duration(days: 30));
    _tokens[access] = FakeToken('access', deviceId, accessExpires);
    _tokens[refresh] = FakeToken('refresh', deviceId, refreshExpiresAt);
    return {
      'accessToken': access,
      'accessTokenExpiresAt': accessExpires.millisecondsSinceEpoch,
      'refreshToken': refresh,
      'refreshTokenExpiresAt': refreshExpiresAt.millisecondsSinceEpoch,
    };
  }

  /// Expires access tokens (of [deviceId] only, when given).
  void expireAccessTokens({String? deviceId}) {
    for (final token in _tokens.values) {
      if (token.kind == 'access' && (deviceId == null || token.deviceId == deviceId)) {
        token.expires = DateTime.now().subtract(const Duration(seconds: 1));
      }
    }
  }

  FakeDevice? _authenticate(String? header) {
    if (header == null || !header.startsWith('Bearer ')) return null;
    final token = _tokens[header.substring(7)];
    if (token == null || token.kind != 'access' || token.expires.isBefore(DateTime.now())) {
      return null;
    }
    final device = devices[token.deviceId];
    return device == null || device.revoked ? null : device;
  }

  /// Simulates the user approving a QR sign-in in the browser.
  void approveQr(String qrId) {
    final token = _secret();
    _webTokens.add(token);
    _qr[qrId]!['token'] = token;
  }

  /// Account web token as a password login would mint (for fixture Hosts).
  String mintWebToken() {
    final token = _secret();
    _webTokens.add(token);
    return token;
  }

  Map<String, Object?> _descriptor(FakeDevice d) => {
    ...d.descriptor,
    'membershipId': 'account:fake',
    'online': peers.containsKey(d.id),
    'lastSeenAt': 1786000000000,
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final response = request.response;
    final beforeResponse = switch (path) {
      '/api/v1/auth/me' => beforeAccountLookupResponse,
      '/api/v1/devices/register' => beforeRegistrationResponse,
      '/api/v1/auth/refresh' => beforeRefreshResponse,
      '/api/v1/devices/self' => beforeRevokeResponse,
      _ => null,
    };
    if (path == '/api/v1/auth/me') beforeAccountLookupResponse = null;
    if (path == '/api/v1/devices/register') beforeRegistrationResponse = null;
    if (path == '/api/v1/auth/refresh') beforeRefreshResponse = null;
    if (path == '/api/v1/devices/self') beforeRevokeResponse = null;
    Future<void> json(int status, Object? body) async {
      if (beforeResponse != null) await beforeResponse();
      responses.add((method: request.method, path: path, status: status));
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    }

    Future<void> error(int status, String code) => json(status, {
      'error': {'code': code, 'message': code, 'requestId': 'r', 'retryable': status >= 500},
    });

    Future<Map<String, Object?>> body() async =>
        (jsonDecode(await utf8.decodeStream(request)) as Map).cast<String, Object?>();

    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (path == '/ws/v1/connect') {
      final ws = await WebSocketTransformer.upgrade(request);
      _accept(ws);
      return;
    }
    if (path == '/ws/v1/relay') {
      final ws = await WebSocketTransformer.upgrade(request);
      _acceptRelay(ws);
      return;
    }
    if (request.method == 'GET' && path == '/health') return json(200, {'status': 'ok'});
    if (request.method == 'GET' && path == '/api/v1/auth/oauth/providers') {
      return json(200, {
        'items': [
          {
            'id': 'github',
            'displayName': 'GitHub',
            'startUrl': '/api/v1/auth/oauth/github/start',
            'qrStartUrl': '/api/v1/auth/oauth/qr/start?provider=github',
          },
        ],
      });
    }
    if (request.method == 'POST' && path == '/api/v1/auth/oauth/qr/start') {
      final qrId = 'qr-${_secret()}';
      _qr[qrId] = {'expires': DateTime.now().add(const Duration(minutes: 2))};
      return json(200, {'qrId': qrId, 'scanUrl': '$url/app/qr/$qrId', 'expiresIn': 120, 'provider': 'github'});
    }
    if (request.method == 'GET' && path.startsWith('/api/v1/auth/oauth/qr/')) {
      final beforePoll = beforeQrPollResponse;
      beforeQrPollResponse = null;
      if (beforePoll != null) await beforePoll();
      final session = _qr[Uri.decodeComponent(path.substring('/api/v1/auth/oauth/qr/'.length))];
      if (session == null) return error(404, 'NOT_FOUND');
      final token = session.remove('token');
      if (token != null) {
        session['claimed'] = true;
        return json(200, {'status': 'complete', 'token': token});
      }
      return json(200, {'status': session['claimed'] == true ? 'expired' : 'pending'});
    }
    if (request.method == 'POST' && path == '/api/v1/auth/login') {
      final b = await body();
      if (b['email'] != account || b['password'] != password) return error(401, 'AUTH_INVALID');
      return json(200, {'token': mintWebToken(), 'expiresAt': 1786000000000, 'account': account, 'isAdmin': false});
    }
    if (request.method == 'GET' && path == '/api/v1/auth/me') {
      if (auth == null || !_webTokens.contains(auth.substring(7))) {
        return error(401, 'ACCOUNT_AUTH_REQUIRED');
      }
      return json(200, {'account': account, 'isAdmin': false});
    }
    if (request.method == 'POST' && path == '/api/v1/devices/register') {
      if (auth == null || !_webTokens.contains(auth.substring(7))) {
        return error(401, 'ACCOUNT_AUTH_REQUIRED');
      }
      final device = ((await body())['device']! as Map).cast<String, Object?>();
      final old = devices[device['deviceId']];
      if (old != null && old.revoked) return error(403, 'DEVICE_REVOKED');
      if (old != null && old.descriptor['identityKey'] != device['identityKey']) {
        return error(409, 'PEER_IDENTITY_MISMATCH');
      }
      devices[device['deviceId']! as String] = FakeDevice(device);
      _tokens.removeWhere((_, t) => t.deviceId == device['deviceId']);
      return json(200, _issue(device['deviceId']! as String));
    }
    if (request.method == 'POST' && path == '/api/v1/auth/refresh') {
      if (failNextRefresh) {
        failNextRefresh = false;
        return error(503, 'SERVICE_UNAVAILABLE');
      }
      final beforeRequest = beforeRefreshRequest;
      beforeRefreshRequest = null;
      if (beforeRequest != null) await beforeRequest();
      final b = await body();
      final token = _tokens[b['refreshToken']];
      if (token == null || token.kind != 'refresh' || token.deviceId != b['deviceId']) {
        return error(401, 'AUTH_INVALID');
      }
      if (token.used) {
        _tokens.removeWhere((_, t) => t.deviceId == token.deviceId);
        return error(401, 'AUTH_INVALID');
      }
      token.used = true;
      refreshCount++;
      return json(200, _issue(token.deviceId, refreshExpires: token.expires));
    }
    final source = _authenticate(auth);
    if (source == null) return error(401, 'AUTH_INVALID');
    if (request.method == 'DELETE' && path == '/api/v1/devices/self') {
      if (failNextRevoke) {
        failNextRevoke = false;
        return error(503, 'SERVICE_UNAVAILABLE');
      }
      source.revoked = true;
      return json(200, {'status': 'revoked'});
    }
    if (request.method == 'GET' && path == '/api/v1/devices') {
      if (source.role != 'client') return error(403, 'MEMBERSHIP_REQUIRED');
      return json(200, {
        'items': devices.values.where((d) => d.role == 'host' && !d.revoked).map((d) {
          final result = _descriptor(d)..remove('identityKey');
          if (separatePresence) result.remove('online');
          return result;
        }).toList(),
        'nextCursor': null,
      });
    }
    if (request.method == 'GET' && path == '/api/v1/turn/credentials') {
      final connectionId = request.uri.queryParameters['connection_id'] ?? '';
      turnRequests.add(connectionId);
      final servers = await (iceServersForRequest?.call(connectionId) ?? Future.value(iceServers));
      return json(200, {'iceServers': servers});
    }
    final presenceMatch = RegExp(r'^/api/v1/devices/([^/]+)/presence$').firstMatch(path);
    if (request.method == 'GET' && presenceMatch != null) {
      presenceRequests++;
      final target = devices[presenceMatch.group(1)];
      if (target == null) return error(404, 'DEVICE_NOT_FOUND');
      if (target.role == source.role) return error(403, 'MEMBERSHIP_REQUIRED');
      if (presenceError != null) return error(503, presenceError!);
      final d = _descriptor(target);
      return json(200, {'deviceId': d['deviceId'], 'online': d['online'], 'lastSeenAt': d['lastSeenAt']});
    }
    final match = RegExp(r'^/api/v1/devices/([^/]+)$').firstMatch(path);
    if (request.method == 'GET' && match != null) {
      final target = devices[match.group(1)];
      if (target == null) return error(404, 'DEVICE_NOT_FOUND');
      if (target.role == source.role) return error(403, 'MEMBERSHIP_REQUIRED');
      final result = _descriptor(target);
      if (separatePresence) result.remove('online');
      return json(200, result);
    }
    return error(404, 'METHOD_NOT_FOUND');
  }

  // --- Control gateway (relay only) ----------------------------------------

  bool separatePresence = false;
  String? presenceError;
  int presenceRequests = 0;

  final List<String> protocolErrors = [];

  /// Raw Control frames received from client devices.
  final List<String> clientControlFrames = [];

  /// Opt-in current resume/lease support; all older fixtures keep their behavior.
  bool controlResume = false;
  bool acknowledgeLeases = true;

  /// One-shot recovery rejection: retires the old link before a fresh hello.
  bool rejectNextRecovery = false;

  /// One-shot gate, cleared before awaiting; data sockets stay usable meanwhile.
  Future<void> Function()? beforeRecoveryHelloAck;

  /// One-shot lease-ack gate, cleared before awaiting; link removal retires it.
  Future<void> Function()? beforeLeaseAck;
  final List<Map<String, Object?>> clientHellos = [];
  final List<Map<String, Object?>> leaseRequests = [];

  /// `relay` frames forwarded on Control sockets.
  int controlRelayFrames = 0;

  // --- WebRTC (hosted Server) --------------------------------------------------

  /// Negotiates the direct transports in [webrtcTransports] with peers that
  /// offer them, sends `webrtcEnabled: true` and forwards signaling.
  bool webrtc = false;
  Set<String> webrtcTransports = {'transport.lan', 'transport.p2p', 'transport.turn'};
  int? webrtcFallbackTimeoutMs;

  /// `GET /api/v1/turn/credentials` answer, and the connection ids asked.
  List<Map<String, Object?>> iceServers = [];
  final List<String> turnRequests = [];

  /// Optional per-request response/gate, allowing concurrent credential fetches.
  Future<List<Map<String, Object?>>> Function(String connectionId)? iceServersForRequest;

  // --- Relay node (`transport.relay.attach`) ---------------------------------

  /// Negotiates `transport.relay.attach` and assigns this node when both
  /// sides offer it (upstream hosted Server); off = self-hosted apps/server.
  bool relayAttach = false;
  int relayEpoch = 7;

  /// Pings every attached socket right after `relay.ready`.
  bool relayPing = true;
  final Map<String, Map<String, Object?>> _tickets = {};
  final Map<String, FakeRelayAttachment> relayAttachments = {};

  /// Every `relay.attach` payload the node accepted, in order.
  final List<Map<String, Object?>> relayAttaches = [];

  /// `<deviceId> <nonce>` of every pong the node received.
  final List<String> relayPongs = [];
  int relayFrames = 0;

  Map<String, Object?> _assign(FakeLink link, String deviceId, String peerDeviceId) {
    final ticket = 'dshrt.${_secret()}';
    _tickets[ticket] = {'connectionId': link.id, 'deviceId': deviceId, 'peerDeviceId': peerDeviceId};
    return link.assignments[deviceId] = {
      'relayEndpoint': '${url.toString().replaceFirst('http', 'ws')}/ws/v1/relay',
      'relayTicket': ticket,
      'relayNodeId': 'fake-relay-1',
      'relayEpoch': relayEpoch,
    };
  }

  void _acceptRelay(WebSocket ws) {
    FakeRelayAttachment? attached;
    void send(String type, Map<String, Object?> payload) {
      if (ws.closeCode == null) ws.add(encodeRelayDataFrame(ControlFrame(type, payload)));
    }

    ws.listen(
      (raw) {
        final frame = decodeRelayDataFrame(raw as String);
        final p = frame.payload;
        final current = attached;
        if (current == null) {
          final ticket = frame.type == 'relay.attach' ? _tickets.remove(p['ticket']) : null;
          if (ticket == null ||
              ticket['connectionId'] != p['connectionId'] ||
              ticket['deviceId'] != p['deviceId'] ||
              ticket['peerDeviceId'] != p['peerDeviceId']) {
            unawaited(ws.close(4001, 'RELAY_TICKET_INVALID'));
            return;
          }
          final side = attached = FakeRelayAttachment(
            ws,
            p['connectionId']! as String,
            p['deviceId']! as String,
            p['peerDeviceId']! as String,
          );
          relayAttachments['${side.connectionId}:${side.deviceId}'] = side;
          relayAttaches.add(p);
          send('relay.ready', {'connectionId': side.connectionId, 'epoch': relayEpoch});
          if (relayPing) send('ping', {'nonce': 'node-${_secret()}'});
          return;
        }
        switch (frame.type) {
          case 'pong':
            relayPongs.add('${current.deviceId} ${p['nonce']}');
          case 'relay':
            if (p['connectionId'] != current.connectionId || p['targetDeviceId'] != current.peerDeviceId) {
              unawaited(ws.close(4001, 'INVALID_MESSAGE'));
              return;
            }
            relayFrames++;
            relayAttachments['${current.connectionId}:${current.peerDeviceId}']?.ws.add(raw);
        }
      },
      onDone: () {
        final side = attached;
        if (side == null || relayAttachments['${side.connectionId}:${side.deviceId}'] != side) return;
        relayAttachments.remove('${side.connectionId}:${side.deviceId}');
        final peer = relayAttachments['${side.connectionId}:${side.peerDeviceId}']?.ws;
        if (peer != null && peer.closeCode == null) {
          peer.add(encodeRelayDataFrame(ControlFrame('relay.detach', {'connectionId': side.connectionId})));
        }
      },
    );
  }

  void _send(FakePeer peer, String type, Map<String, Object?> payload) {
    if (peer.ws.closeCode != null) return;
    try {
      peer.ws.add(encodeControlFrame(ControlFrame(type, payload)));
    } on StateError {
      // socket already closing
    }
  }

  void _dropLink(FakeLink link, String code) {
    links.remove(link.id);
    link.leases.clear();
    link.recoveryTickets.clear();
    link.relayRecoveryTickets.clear();
    for (final id in [link.host, link.client]) {
      final peer = peers[id];
      if (peer != null) {
        _send(peer, 'error', {'code': code, 'message': code, 'connectionId': link.id, 'retryable': true});
      }
    }
  }

  void disconnectPeer(String id, String code) {
    final peer = peers.remove(id);
    for (final link in [...links.values]) {
      if (link.host == id || link.client == id) _dropLink(link, code);
    }
    if (peer != null) unawaited(peer.ws.close(code == 'CONNECTION_REPLACED' ? 4003 : 4001, code));
  }

  /// Drops only the Control socket; onDone retains a confirmed leased link.
  Future<void> dropControl(String id, {int code = 4001, String reason = 'server shutdown'}) async {
    await peers[id]!.ws.close(code, reason);
  }

  void _accept(WebSocket ws) {
    controlConnects++;
    FakePeer? peer;
    ws.listen(
      (raw) async {
        try {
          if (peer?.role == 'client') clientControlFrames.add(raw as String);
          final frame = decodeControlFrame(raw as String);
          if (peer == null) {
            if (frame.type != 'hello') throw const ProtocolError('AUTH_REQUIRED');
            final p = frame.payload;
            if (p['role'] == 'client') clientHellos.add(p);
            if (rejectHelloWith != null) {
              ws.add(
                encodeControlFrame(ControlFrame('error', {'code': rejectHelloWith!, 'message': rejectHelloWith!})),
              );
              unawaited(ws.close(4001, rejectHelloWith));
              return;
            }
            final device = _authenticate('Bearer ${p['accessToken']}');
            if (device == null || device.id != p['deviceId'] || device.role != p['role']) {
              ws.add(encodeControlFrame(ControlFrame('error', {'code': 'AUTH_INVALID', 'message': 'AUTH_INVALID'})));
              unawaited(ws.close(4001, 'AUTH_INVALID'));
              return;
            }
            final tickets = (p['recoveryTickets'] as List<Object?>?)?.cast<String>() ?? const <String>[];
            if (tickets.isNotEmpty) {
              final owned = links.values.where((link) => link.client == device.id || link.host == device.id).toList();
              final valid =
                  controlResume && tickets.every((ticket) => owned.any((link) => link.leases[device.id] == ticket));
              if (rejectNextRecovery || !valid) {
                rejectNextRecovery = false;
                await ws.close(4012, 'recovery authorization rejected');
                for (final link in owned) {
                  _dropLink(link, 'CONNECTION_FAILED');
                }
                return;
              }
              // Replacing a socket after valid recovery must not replace its link.
              final previous = peers.remove(device.id);
              unawaited(previous?.ws.close(4003, 'CONNECTION_REPLACED'));
            } else {
              disconnectPeer(device.id, 'CONNECTION_REPLACED');
            }
            final caps = (p['capabilities']! as List).cast<String>();
            final created = peer = FakePeer(ws, device.id, device.role, caps);
            peers[device.id] = created;
            if (tickets.isNotEmpty) {
              final gate = beforeRecoveryHelloAck;
              beforeRecoveryHelloAck = null;
              if (gate != null) await gate();
              if (peers[device.id] != created || ws.closeCode != null) return;
            }
            _send(created, 'hello.ack', {
              'protocol': 1,
              'serverVersion': 'fake/0.1.0',
              'connectionSessionId': uuidV7(),
              'heartbeatIntervalMs': 25000,
              'maxControlFrameBytes': maxControlFrameBytes,
              'maxRelayFrameBytes': maxRelayFrameBytes,
              'capabilities': [
                if (controlResume && caps.contains(webRtcResumeCapability)) webRtcResumeCapability,
                if (controlResume && caps.contains(relayResumeCapability)) relayResumeCapability,
                if (webrtc) ...webrtcTransports.where(caps.contains),
                if (caps.contains('transport.relay')) 'transport.relay',
                if (relayAttach && caps.contains('transport.relay.attach')) 'transport.relay.attach',
              ],
              'webrtcEnabled': webrtc,
              'webrtcFallbackTimeoutMs': ?webrtcFallbackTimeoutMs,
            });
            return;
          }
          _route(peer!, frame);
        } on ProtocolError catch (error) {
          protocolErrors.add(error.code);
          final connectionId = asString(asMap(asMap(tryDecodeJson(raw as String))?['payload'])?['connectionId']);
          if (peer != null && connectionId != null) {
            // Connection-scoped failure: tell the peer, keep its socket.
            _send(peer!, 'error', {'code': error.code, 'message': error.code, 'connectionId': connectionId});
          } else if (peer != null) {
            _send(peer!, 'error', {'code': error.code, 'message': error.message});
            disconnectPeer(peer!.id, error.code);
          } else {
            unawaited(ws.close(4001, error.code));
          }
        }
      },
      onDone: () {
        final current = peer;
        if (current != null && peers[current.id] == current) {
          final leased = controlResume && links.values.any((link) => link.leases.containsKey(current.id));
          if (leased) {
            peers.remove(current.id);
          } else {
            disconnectPeer(current.id, 'CONNECTION_FAILED');
          }
        }
      },
    );
  }

  Future<void> _ackLease(FakePeer peer, FakeLink link, Map<String, Object?> request) async {
    final gate = beforeLeaseAck;
    beforeLeaseAck = null;
    if (gate != null) await gate();
    if (links[link.id] != link || peers[peer.id] != peer || peer.ws.closeCode != null) return;
    final rotated = link.leases[peer.id] = 'dshlease.${_secret()}';
    _send(peer, 'connection.lease.ack', {
      'connectionId': link.id,
      'requestId': request['requestId'],
      'ticket': rotated,
      'leaseMs': controlLeaseMs,
    });
  }

  void _route(FakePeer peer, ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'ping':
        _send(peer, 'pong', {'nonce': p['nonce']});
        return;
      case 'pong':
        return;
      case 'connect.request':
        final host = peers[p['hostDeviceId']];
        if (host == null || host.role != 'host') {
          _send(peer, 'error', {'code': 'HOST_OFFLINE', 'message': 'Host is offline.', 'retryable': true});
          return;
        }
        for (final old in [...links.values]) {
          if (old.client == peer.id) _dropLink(old, 'CONNECTION_REPLACED');
        }
        final link = FakeLink(uuidV7(), host.id, peer.id);
        links[link.id] = link;
        if (controlResume) {
          for (final id in [host.id, peer.id]) {
            if (peer.capabilities.contains(webRtcResumeCapability) &&
                host.capabilities.contains(webRtcResumeCapability)) {
              link.recoveryTickets[id] = 'dshwr.${_secret()}';
            }
            if (peer.capabilities.contains(relayResumeCapability) &&
                host.capabilities.contains(relayResumeCapability)) {
              link.relayRecoveryTickets[id] = 'dshrr.${_secret()}';
            }
          }
        }
        final attach =
            relayAttach &&
            peer.capabilities.contains('transport.relay.attach') &&
            host.capabilities.contains('transport.relay.attach');
        _send(host, 'connect.incoming', {
          'connectionId': link.id,
          'clientDeviceId': peer.id,
          'clientIdentityKey': devices[peer.id]!.descriptor['identityKey'],
          'authorization': 'account',
          'preferredTransports': webrtc ? p['preferredTransports'] : ['relay'],
          'recoveryTicket': ?link.recoveryTickets[host.id],
          'relayRecoveryTicket': ?link.relayRecoveryTickets[host.id],
          if (attach) ..._assign(link, host.id, peer.id),
        });
        if (attach) _assign(link, peer.id, host.id);
        return;
    }
    final link = links[p['connectionId']];
    if (frame.type == 'connection.lease.close' && link == null) return;
    if (link == null || (peer.id != link.host && peer.id != link.client)) {
      throw const ProtocolError('CONNECTION_NOT_FOUND', 'CONNECTION_NOT_FOUND');
    }
    if (frame.type == 'connection.lease.close') {
      _dropLink(link, 'CONNECTION_FAILED');
      return;
    }
    if (frame.type == 'connection.lease.request') {
      leaseRequests.add({...p, 'deviceId': peer.id});
      final current = link.leases[peer.id];
      final ticket = p['ticket'];
      final valid = current == null
          ? ticket == link.recoveryTickets[peer.id] || ticket == link.relayRecoveryTickets[peer.id]
          : ticket == current;
      if (!controlResume || link.stage != 'ready' || !valid) throw const ProtocolError('INVALID_MESSAGE');
      if (!acknowledgeLeases) return;
      unawaited(_ackLease(peer, link, p));
      return;
    }
    final other = peers[peer.id == link.host ? link.client : link.host];
    if (other == null) throw const ProtocolError('CONNECTION_FAILED', 'CONNECTION_FAILED');
    switch (frame.type) {
      case 'connect.accepted' || 'connect.rejected':
        if (peer.id != link.host) throw const ProtocolError('INVALID_MESSAGE');
        if (frame.type == 'connect.rejected') links.remove(link.id);
        link.stage = 'accepted';
        final assignment = link.assignments[link.client];
        if (frame.type == 'connect.accepted' &&
            (assignment != null ||
                link.recoveryTickets.containsKey(link.client) ||
                link.relayRecoveryTickets.containsKey(link.client))) {
          _send(other, 'connect.accepted', {
            ...p,
            ...?assignment,
            'recoveryTicket': ?link.recoveryTickets[link.client],
            'relayRecoveryTicket': ?link.relayRecoveryTickets[link.client],
          });
          return;
        }
      case 'transport.selected':
        // The Host confirms its own WebRTC selection too (plugin 0.6.0).
        if (p['transport'] != 'relay' ? !webrtc : peer.id != link.client) {
          throw const ProtocolError('INVALID_MESSAGE');
        }
      case 'signal.offer' || 'signal.answer' || 'signal.ice':
        if (!webrtc) return;
      case 'secure.handshake':
        final step = p['step'];
        if (step == 1 && peer.id == link.client && link.stage == 'accepted') {
          link.stage = 'handshake';
        } else if (step == 2 && peer.id == link.host && link.stage == 'handshake') {
          link.stage = 'ready';
        } else {
          throw const ProtocolError('INVALID_MESSAGE');
        }
      case 'relay':
        final counter = p['counter']! as int;
        if (link.stage != 'ready' || counter <= (link.counters[peer.id] ?? -1)) {
          throw const ProtocolError('INVALID_MESSAGE');
        }
        link.counters[peer.id] = counter;
        controlRelayFrames++;
      default:
        return;
    }
    if (other.ws.closeCode == null) other.ws.add(encodeControlFrame(frame));
  }
}

/// Handle on one logical stream the fake Host opened.
class FakeHostStream {
  FakeHostStream(this._connection, this.streamId, this.endpoint, this.payload);

  final FakeHostConnection _connection;
  final String streamId;
  final String endpoint;
  final Map<String, Object?> payload;
  bool closed = false;

  Map<String, Object?> get args => (payload['args']! as Map).cast<String, Object?>();

  void push(Object? value) {
    if (closed) return;
    _connection.event('harness.remote.frame', {'streamId': streamId, 'hasValue': true, 'value': value});
  }

  /// Exact #161 Host wire shape, using the production chunk size.
  void pushTransferred(
    Object? value, {
    Map<String, Object?> Function(Map<String, Object?>)? changeDescriptor,
    Map<String, Object?> Function(Map<String, Object?>)? changeFrame,
  }) {
    final id = uuidV7();
    final frame = {'streamId': streamId, 'hasValue': true, 'value': value};
    final bytes = utf8.encode(jsonEncode(changeFrame?.call(frame) ?? frame));
    _connection.transfers[id] = {'out': bytes};
    final descriptor = <String, Object?>{
      'kind': 'chunked',
      'transferId': id,
      'totalBytes': bytes.length,
      'totalChunks': (bytes.length + 512 * 1024 - 1) ~/ (512 * 1024),
    };
    _connection.event('harness.remote.frame', {
      'streamId': streamId,
      'hasValue': true,
      'transfer': changeDescriptor?.call(descriptor) ?? descriptor,
    });
  }

  void complete() => _close('completed');

  void fail(String code, String message) =>
      _close('failed', {'code': code, 'message': message, 'details': <String, Object?>{}});

  void _close(String reason, [Map<String, Object?>? failure]) {
    if (closed) return;
    closed = true;
    _connection.streams.remove(streamId);
    _connection.event('harness.remote.stream.closed', {'streamId': streamId, 'reason': reason, 'failure': ?failure});
  }
}

class FakeHostConnection {
  FakeHostConnection(this.host, this.connectionId, this.clientId, this.noise, this.assignment);

  final FakeRemoteHost host;
  final String connectionId;
  final String clientId;
  final NoiseIkSession noise;

  /// Relay assignment from `connect.incoming`; the Host then holds the
  /// handshake until `transport.selected`, and attaches (plugin 0.6.0).
  final Map<String, Object?>? assignment;
  WebSocket? dataSocket;
  bool selected = false;
  Map<String, Object?>? pendingHandshake;

  /// WebRTC answer to the client's offer; ciphertext uses it once the client
  /// selected `lan` / `p2p` / `turn`.
  FakeHostPeer? rtc;
  String? selectedTransport;
  bool get viaRtc => rtc != null && selectedTransport != null && selectedTransport != 'relay';
  final RtcChunkCodec rtcIn = RtcChunkCodec();
  final RtcChunkCodec rtcOut = RtcChunkCodec();
  final SecureMessageCodec incoming = SecureMessageCodec();
  final SecureMessageCodec outgoing = SecureMessageCodec();
  final Map<String, FakeHostStream> streams = {};
  final Map<String, Map<String, Object?>> transfers = {};
  bool ready = false;
  int eventsGeneration = 0;

  void send(RemoteMessage message) {
    for (final fragment in outgoing.encode(message.encode())) {
      if (viaRtc) {
        rtcOut.encode(noise.encrypt(fragment)).forEach(rtc!.send);
        continue;
      }
      final counter = noise.sendingCounter;
      final payload = {
        'connectionId': connectionId,
        'targetDeviceId': clientId,
        'counter': counter,
        'ciphertext': toBase64Url(noise.encrypt(fragment)),
      };
      final data = dataSocket;
      if (data != null) {
        data.add(encodeRelayDataFrame(ControlFrame('relay', payload)));
      } else {
        host._sendControl('relay', payload);
      }
    }
  }

  void event(String name, Object? data) => send(RemoteMessage('event', {'event': name, 'data': data}));
}

/// Fake Host plugin: registers, keeps a Control socket, answers clients.
class FakeRemoteHost {
  FakeRemoteHost._(this.server, this.deviceId, this.keys);

  static Future<FakeRemoteHost> start(
    FakeRemoteServer server, {
    String name = 'Fake Workstation',
    X25519KeyPair? keys,
    String? deviceId,
  }) async {
    final identity = keys ?? X25519KeyPair.generate();
    final host = FakeRemoteHost._(server, deviceId ?? uuidV7(), identity);
    final client = HttpClient();
    try {
      final request = await client.postUrl(server.url.resolve('/api/v1/devices/register'));
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${server.mintWebToken()}');
      request.write(
        jsonEncode({
          'v': 1,
          'device': {
            'deviceId': host.deviceId,
            'name': name,
            'role': 'host',
            'platform': 'linux',
            'identityKey': identity.publicKeyBase64Url,
            'clientVersion': '0.5.17',
            'harnessVersion': '0.2.1-rc.2',
          },
        }),
      );
      final response = await request.close();
      host._tokens = (jsonDecode(await utf8.decodeStream(response)) as Map).cast<String, Object?>();
    } finally {
      client.close();
    }
    await host.goOnline();
    return host;
  }

  final FakeRemoteServer server;
  final String deviceId;
  X25519KeyPair keys;
  late Map<String, Object?> _tokens;
  WebSocket? _ws;
  final Map<String, FakeHostConnection> connections = {};

  /// Offers `transport.relay.attach` in hello (plugin 0.6.0); false = an
  /// older Host.
  bool relayAttach = true;

  /// Offers `transport.lan/p2p/turn` and answers offers over [rtcNetwork]
  /// (a plugin with a WebRTC backend).
  bool webrtc = false;
  FakeRtcNetwork? rtcNetwork;

  /// Candidates the Host received, by connection id, and offers in order.
  final Map<String, int> rtcCandidates = {};
  String rtcAnswerSdp = 'v=0 fake-answer';
  final List<Map<String, Object?>> extraRtcCandidates = [];
  final List<String> rtcOffers = [];

  /// `harness.transport.describe` capabilities.
  List<String> capabilities = ['transport.relay', 'harness.remote.v3', 'harness.remote.transfer.v1'];

  /// Unary handlers by endpoint; default: `gateway/not-found`.
  final Map<String, Map<String, Object?> Function(Map<String, Object?> args)> handlers = {};

  /// Optional unary reply gate, after execution but before the encrypted reply.
  Future<void> Function(String endpoint)? beforeUnaryResponse;

  /// Called for each non-`$events` stream a client opens.
  void Function(FakeHostStream stream)? onOpen;

  /// Waterfalls replayed to every new `$events` stream.
  final List<Map<String, Object?>> pendingWaterfalls = [];

  /// Every unary call: endpoint and args.
  final List<(String, Map<String, Object?>)> calls = [];

  /// Every tunnel RPC method in order.
  final List<String> rpcMethods = [];
  final List<Map<String, Object?>> openedStreamParams = [];
  Future<Map<String, Object?>> Function(Map<String, Object?>)? transferRead;

  /// Holds an open reply after the Host has registered its incoming transfer.
  Future<void> Function(String transferId)? beforeTransferOpenResponse;

  /// Independent top-level workspace upload RPCs (plugin 0.6.2).
  Future<Object?> Function(String method, Map<String, Object?> params)? workspaceUpload;

  /// Optional connection-scoped history configuration and its exact requests.
  Future<Object?> Function(Map<String, Object?> params)? configureHistory;
  final List<(String, Map<String, Object?>)> historyConfigurations = [];

  /// Responses above this many bytes answer RESPONSE_TOO_LARGE on the
  /// direct path (forces the transfer path).
  int? directResponseLimit;

  /// Simulates a Host whose plugin predates `harness.transport.describe`.
  bool describeUnsupported = false;
  bool stallDescribe = false;

  final Map<String, FakeHostStream> eventStreams = {};
  int _clientIds = 0;

  /// Connection ids whose Noise handshake this Host completed, in order.
  final List<String> handshakes = [];

  Future<void> goOnline() async {
    final ws = _ws = await WebSocket.connect('${server.url.toString().replaceFirst('http', 'ws')}/ws/v1/connect');
    final acked = Completer<void>();
    ws.listen((raw) {
      final frame = decodeControlFrame(raw as String);
      if (frame.type == 'hello.ack') {
        acked.complete();
        return;
      }
      unawaited(_onControl(frame));
    });
    _sendControl('hello', {
      'role': 'host',
      'deviceId': deviceId,
      'accessToken': _tokens['accessToken'],
      'protocols': [1],
      'capabilities': [
        if (server.controlResume) ...[webRtcResumeCapability, relayResumeCapability],
        if (webrtc) ...['transport.lan', 'transport.p2p', 'transport.turn'],
        'transport.relay',
        if (relayAttach) 'transport.relay.attach',
      ],
      'clientVersion': '0.5.17',
      'harnessVersion': '0.2.1-rc.2',
    });
    await acked.future;
  }

  Future<void> goOffline() async {
    await _ws?.close();
    _ws = null;
    connections.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Drops every client connection (the Server reports CONNECTION_FAILED).
  void dropClients() {
    for (final link in [...server.links.values]) {
      if (link.host == deviceId) server._dropLink(link, 'CONNECTION_FAILED');
    }
    connections.clear();
  }

  void _sendControl(String type, Map<String, Object?> payload) =>
      _ws?.add(encodeControlFrame(ControlFrame(type, payload)));

  Future<void> _onControl(ControlFrame frame) async {
    final p = frame.payload;
    switch (frame.type) {
      case 'ping':
        _sendControl('pong', {'nonce': p['nonce']});
      case 'connect.incoming':
        final clientId = p['clientDeviceId']! as String;
        final client = HttpClient();
        try {
          final request = await client.getUrl(server.url.resolve('/api/v1/devices/$clientId'));
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${_tokens['accessToken']}');
          final response = await request.close();
          final descriptor = (jsonDecode(await utf8.decodeStream(response)) as Map).cast<String, Object?>();
          if (descriptor['identityKey'] != p['clientIdentityKey'] || descriptor['role'] != 'client') {
            _sendControl('connect.rejected', {'connectionId': p['connectionId']});
            return;
          }
        } finally {
          client.close();
        }
        final connectionId = p['connectionId']! as String;
        connections[connectionId] = FakeHostConnection(
          this,
          connectionId,
          clientId,
          NoiseIkSession(
            role: NoiseRole.responder,
            localPrivateKey: keys.privateKeyBase64Url,
            localPublicKey: keys.publicKeyBase64Url,
            remotePublicKey: p['clientIdentityKey']! as String,
            prologue: createNoisePrologue(connectionId, deviceId, clientId),
          ),
          p['relayTicket'] == null ? null : p,
        );
        _sendControl('connect.accepted', {'connectionId': connectionId});
      case 'secure.handshake':
        final connection = connections[p['connectionId']];
        if (connection == null) return;
        // Like the plugin: with a data plane still to choose, wait for the
        // client's transport.selected.
        if ((connection.assignment != null || connection.rtc != null) && !connection.selected) {
          connection.pendingHandshake = p;
          return;
        }
        _completeHandshake(connection, p);
      case 'signal.offer':
        final connection = connections[p['connectionId']];
        if (connection == null || !webrtc || connection.rtc != null || connection.selected) return;
        rtcOffers.add(connection.connectionId);
        final rtc = rtcNetwork!.answer(
          p['sdp']! as String,
          onMessage: (data) => unawaited(_receiveRtc(connection, data)),
          onOpen: () => _sendControl('transport.selected', {
            'connectionId': connection.connectionId,
            'targetDeviceId': connection.clientId,
            'transport': 'p2p',
          }),
        );
        if (rtc == null) return;
        connection.rtc = rtc;
        _sendControl('signal.answer', {
          'connectionId': connection.connectionId,
          'targetDeviceId': connection.clientId,
          'sdp': rtcAnswerSdp,
        });
        _sendControl('signal.ice', {
          'connectionId': connection.connectionId,
          'targetDeviceId': connection.clientId,
          'candidate': {'candidate': 'candidate:2 1 udp 2122260223 192.168.1.30 40000 typ host', 'sdpMid': '0'},
        });
        for (final candidate in extraRtcCandidates) {
          _sendControl('signal.ice', {
            'connectionId': connection.connectionId,
            'targetDeviceId': connection.clientId,
            'candidate': candidate,
          });
        }
      case 'signal.ice':
        final id = p['connectionId']! as String;
        rtcCandidates[id] = (rtcCandidates[id] ?? 0) + 1;
      case 'transport.selected':
        final connection = connections[p['connectionId']];
        if (connection == null) return;
        connection.selectedTransport = p['transport']! as String;
        if (!connection.viaRtc) {
          connection.rtc?.close();
          connection.rtc = null;
          // The plugin serializes Control frames, so a handshake that arrives
          // while it attaches still waits for the data socket.
          if (connection.assignment != null) await _attach(connection);
        }
        connection.selected = true;
        final pending = connection.pendingHandshake;
        if (pending != null) _completeHandshake(connection, pending);
      case 'relay':
        final connection = connections[p['connectionId']];
        if (connection == null || connection.dataSocket != null) return;
        await _receiveRelay(connection, p);
      case 'error':
        final id = p['connectionId'];
        if (id == null) return;
        final connection = connections.remove(id);
        connection?.rtc?.close();
        unawaited(connection?.dataSocket?.close());
    }
  }

  Future<void> _receiveRtc(FakeHostConnection connection, Uint8List data) async {
    if (!connection.viaRtc) throw StateError('ciphertext on a DataChannel the client did not select');
    final ciphertext = connection.rtcIn.decode(data);
    if (ciphertext == null) return;
    final plain = connection.incoming.decode(connection.noise.decrypt(ciphertext));
    if (plain == null) return;
    await _onMessage(connection, RemoteMessage.decode(plain));
  }

  /// Closes every client's DataChannel from the Host side.
  void closeRtc() {
    for (final connection in connections.values) {
      connection.rtc?.close();
    }
  }

  void _completeHandshake(FakeHostConnection connection, Map<String, Object?> p) {
    connection.pendingHandshake = null;
    connection.noise.readHandshake(fromBase64Url(p['data']! as String));
    final reply = connection.noise.writeHandshake();
    connection.ready = true;
    handshakes.add(connection.connectionId);
    _sendControl('secure.handshake', {
      'connectionId': connection.connectionId,
      'targetDeviceId': connection.clientId,
      'step': 2,
      'data': toBase64Url(reply),
    });
  }

  Future<void> _receiveRelay(FakeHostConnection connection, Map<String, Object?> p) async {
    if (p['counter'] != connection.noise.receivingCounter) {
      throw StateError('relay counter mismatch');
    }
    final plain = connection.incoming.decode(connection.noise.decrypt(fromBase64Url(p['ciphertext']! as String)));
    if (plain == null) return;
    await _onMessage(connection, RemoteMessage.decode(plain));
  }

  /// Attaches [connection] to its assigned Relay node, like plugin 0.6.0.
  Future<void> _attach(FakeHostConnection connection) async {
    final assignment = connection.assignment!;
    final ws = connection.dataSocket = await WebSocket.connect(assignment['relayEndpoint']! as String);
    final ready = Completer<void>();
    ws.listen(
      (raw) {
        final frame = decodeRelayDataFrame(raw as String);
        switch (frame.type) {
          case 'relay.ready':
            ready.complete();
          case 'ping':
            ws.add(encodeRelayDataFrame(ControlFrame('pong', frame.payload)));
          case 'relay':
            unawaited(_receiveRelay(connection, frame.payload));
          case 'relay.detach':
            connections.remove(connection.connectionId);
            unawaited(ws.close());
        }
      },
      onDone: () {
        if (connections[connection.connectionId] == connection) connections.remove(connection.connectionId);
      },
    );
    ws.add(
      encodeRelayDataFrame(
        ControlFrame('relay.attach', {
          'connectionId': connection.connectionId,
          'deviceId': deviceId,
          'peerDeviceId': connection.clientId,
          'ticket': assignment['relayTicket'],
        }),
      ),
    );
    await ready.future;
  }

  /// Closes the Host side of every attached Relay data socket (the node
  /// then sends `relay.detach` to the clients).
  Future<void> detachClients() async {
    for (final connection in [...connections.values]) {
      connections.remove(connection.connectionId);
      await connection.dataSocket?.close();
    }
  }

  Future<void> _onMessage(FakeHostConnection connection, RemoteMessage message) async {
    if (message.type != 'rpc.request') return;
    final payload = (message.payload! as Map).cast<String, Object?>();
    final method = payload['method']! as String;
    final params = (payload['params'] as Map?)?.cast<String, Object?>() ?? const {};
    rpcMethods.add(method);
    void respond(Object? result) =>
        connection.send(RemoteMessage('rpc.response', {'requestId': message.id, 'result': result}));
    void reject(String code, String text) => connection.send(
      RemoteMessage('rpc.error', {'requestId': message.id, 'code': code, 'message': text, 'retryable': false}),
    );
    switch (method) {
      case 'harness.transport.describe':
        if (stallDescribe) return;
        if (describeUnsupported) return reject('METHOD_NOT_FOUND', 'Unknown method.');
        respond({'capabilities': capabilities});
      case 'remote.history.configure':
        historyConfigurations.add((connection.connectionId, params));
        final configure = configureHistory;
        if (configure == null) return reject('METHOD_NOT_FOUND', 'Unknown history configuration method.');
        respond(await configure(params));
      case 'workspace.upload.open' || 'workspace.upload.chunk' || 'workspace.upload.commit' || 'workspace.upload.abort':
        final upload = workspaceUpload;
        if (upload == null) return reject('FEATURE_NOT_SUPPORTED', 'No workspace upload handler.');
        respond(await upload(method, params));
      case 'harness.remote.call':
        final endpoint = params['endpoint']! as String;
        if (!harnessRemoteAllowlist.contains(endpoint)) {
          return reject('METHOD_NOT_ALLOWED', 'Not allowed.');
        }
        final result = _dispatch(connection, endpoint, params['payload']);
        final beforeResponse = beforeUnaryResponse;
        if (beforeResponse != null) {
          await beforeResponse(endpoint);
          if (connections[connection.connectionId] != connection) return;
        }
        final limit = directResponseLimit;
        if (limit != null && utf8.encode(jsonEncode(result)).length > limit) {
          return reject('RESPONSE_TOO_LARGE', 'Too large for a direct response.');
        }
        respond(result);
      case 'harness.remote.stream.open':
        openedStreamParams.add(params);
        if (params.containsKey('transferFrames') && !capabilities.contains('harness.remote.stream.transfer.v1')) {
          return reject('INVALID_MESSAGE', 'Old Host rejects unknown stream fields.');
        }
        final streamId = params['streamId']! as String;
        final endpoint = params['endpoint']! as String;
        if (!harnessRemoteAllowlist.contains(endpoint)) {
          return reject('METHOD_NOT_ALLOWED', 'Not allowed.');
        }
        if (connection.streams.length >= 16) return reject('RATE_LIMITED', 'Too many streams.');
        final stream = FakeHostStream(
          connection,
          streamId,
          endpoint,
          (params['payload']! as Map).cast<String, Object?>(),
        );
        connection.streams[streamId] = stream;
        respond({'opened': true, 'streamId': streamId});
        if (endpoint == r'$events') {
          eventStreams[connection.connectionId] = stream;
          stream.push({
            'type': 'ready',
            'clientId': 'remote-client-${++_clientIds}',
            'host': {'home': '/home/host'},
          });
          pendingWaterfalls.forEach(stream.push);
        } else {
          onOpen?.call(stream);
        }
      case 'harness.remote.stream.close':
        connection.streams[params['streamId']]?._close('cancelled');
        respond({'closed': true, 'streamId': params['streamId']});
      case 'harness.remote.transfer.open':
        connection.transfers[params['transferId']! as String] = {
          'totalBytes': params['totalBytes'],
          'totalChunks': params['totalChunks'],
          'chunks': <List<int>>[],
        };
        final beforeOpenResponse = beforeTransferOpenResponse;
        if (beforeOpenResponse != null) await beforeOpenResponse(params['transferId']! as String);
        respond({'opened': true, 'transferId': params['transferId']});
      case 'harness.remote.transfer.chunk':
        final transfer = connection.transfers[params['transferId']]!;
        final chunks = transfer['chunks']! as List<List<int>>;
        if (params['index'] != chunks.length) return reject('INVALID_MESSAGE', 'Out of order.');
        chunks.add(base64Decode(params['data']! as String));
        respond({'accepted': true, 'transferId': params['transferId'], 'index': params['index']});
      case 'harness.remote.transfer.commit':
        final transfer = connection.transfers.remove(params['transferId'])!;
        final bytes = (transfer['chunks']! as List<List<int>>).expand((c) => c).toList();
        final request = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
        final result = _dispatch(connection, request['endpoint']! as String, request['payload']);
        final encoded = utf8.encode(jsonEncode(result));
        if (encoded.length <= 2 * 1024 * 1024) {
          respond({'kind': 'inline', 'response': result});
        } else {
          final total = (encoded.length + 512 * 1024 - 1) ~/ (512 * 1024);
          connection.transfers[params['transferId']! as String] = {'out': encoded};
          respond({
            'kind': 'chunked',
            'transferId': params['transferId'],
            'totalBytes': encoded.length,
            'totalChunks': total,
          });
        }
      case 'harness.remote.transfer.read':
        final out = connection.transfers[params['transferId']]!['out']! as List<int>;
        final index = params['index']! as int;
        final start = index * 512 * 1024;
        final end = start + 512 * 1024 < out.length ? start + 512 * 1024 : out.length;
        final result = <String, Object?>{
          'transferId': params['transferId'],
          'index': index,
          'data': base64Encode(out.sublist(start, end)),
        };
        respond(transferRead == null ? result : await transferRead!(result));
      case 'harness.remote.transfer.close':
        connection.transfers.remove(params['transferId']);
        respond({'closed': true, 'transferId': params['transferId']});
      default:
        reject('METHOD_NOT_FOUND', 'Unknown method $method.');
    }
  }

  Map<String, Object?> _dispatch(FakeHostConnection connection, String endpoint, Object? payload) {
    final args = ((payload! as Map)['args']! as Map).cast<String, Object?>();
    calls.add((endpoint, args));
    final handler = handlers[endpoint];
    if (handler == null) {
      return {
        'ok': false,
        'error': {'code': 'gateway/not-found', 'message': 'No handler for $endpoint', 'details': <String, Object?>{}},
      };
    }
    return handler(args);
  }

  /// Pushes a `$events` item to every connected client.
  void emitHostEvent(Map<String, Object?> value) {
    for (final stream in eventStreams.values) {
      stream.push(value);
    }
  }

  Future<void> close() async => goOffline();
}

/// Minimal session/follow snapshot as DSH 0.2 sends it.
Map<String, Object?> followSnapshot(
  String sessionId, {
  int cursor = -1,
  List<Map<String, Object?>> records = const [],
}) => {
  'type': 'snapshot',
  'header': {'version': 4, 'id': sessionId, 'createdAt': 1786000000000, 'cwd': '/home/host/ws', 'isSeeded': false},
  'cursor': cursor,
  'records': records,
  'hasMore': false,
  'projections': {'asOfSeq': cursor, 'values': <String, Object?>{}},
  'assistantStream': {'revision': 0},
};

Map<String, Object?> logRecord(int seq, String type, Map<String, Object?> data) => {
  'type': 'event',
  'event': {'type': type, 'seq': seq, 'time': 1786000000000 + seq, 'data': data},
};

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));
