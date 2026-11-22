// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Control-channel frames of ds-harness-remote protocol v1. Conformance:
// test/fixtures/protocol-v1.
library;

import 'dart:convert';

import '../util/bytes.dart';

const int protocolVersion = 1;

const String webRtcResumeCapability = 'transport.webrtc.resume.v1';
const String relayResumeCapability = 'transport.relay.resume.v1';
const int controlLeaseMs = 300000;

/// UTF-8 JSON limit for non-relay Control frames.
const int maxControlFrameBytes = 64 * 1024;

/// UTF-8 JSON limit for `relay` Control frames and Relay data frames.
const int maxRelayFrameBytes = 1024 * 1024;

/// Most entries in a capability list (`hello`, `hello.ack`,
/// `harness.transport.describe`).
const int maxRemoteCapabilityEntries = 128;

const int _maxProtocolListEntries = 16;

const List<String> controlFrameTypes = [
  'hello',
  'hello.ack',
  'connect.request',
  'connect.incoming',
  'connect.accepted',
  'connect.rejected',
  'secure.handshake',
  'relay',
  'signal.offer',
  'signal.answer',
  'signal.ice',
  'transport.selected',
  'connection.lease.request',
  'connection.lease.ack',
  'connection.lease.close',
  'ping',
  'pong',
  'error',
];

/// `lan | p2p | turn | relay`, in preference order.
const List<String> remoteTransports = ['lan', 'p2p', 'turn', 'relay'];

/// A Control frame failed validation; the receiver must fail closed.
class ProtocolError implements Exception {
  const ProtocolError(this.message, [this.code = 'INVALID_MESSAGE']);
  final String code;
  final String message;

  @override
  String toString() => 'ProtocolError($code): $message';
}

/// Negotiated per-socket frame limits (`hello.ack`); both may only shrink
/// the v1 defaults.
class ControlFrameLimits {
  const ControlFrameLimits({this.maxControlFrameBytes, this.maxRelayFrameBytes});

  final int? maxControlFrameBytes;
  final int? maxRelayFrameBytes;
}

class ControlFrame {
  ControlFrame(this.type, this.payload, {String? id, int? timestamp})
    : id = id ?? uuidV7(),
      timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final String type;
  final int timestamp;
  final JsonMap payload;

  JsonMap toJson() => {'v': protocolVersion, 'id': id, 'type': type, 'timestamp': timestamp, 'payload': payload};
}

/// Validates [input] like upstream `parseControlFrame`: strict envelope,
/// known type, typed payload. Unknown payload fields are tolerated (they are
/// forward-compatible additions) and stripped; unknown envelope fields are not.
ControlFrame parseControlFrame(Object? input) {
  final map = asMap(input);
  if (map == null) throw const ProtocolError('Control frame must be a JSON object.');
  const allowed = {'v', 'id', 'type', 'timestamp', 'payload'};
  for (final key in map.keys) {
    if (!allowed.contains(key)) throw ProtocolError('Unexpected Control envelope field "$key".');
  }
  if (map['v'] != protocolVersion) {
    throw const ProtocolError('Unsupported Control protocol version.', 'UNSUPPORTED_VERSION');
  }
  final id = map['id'];
  if (id is! String || id.isEmpty) throw const ProtocolError('Control frame id is required.');
  final type = map['type'];
  if (type is! String || !controlFrameTypes.contains(type)) {
    throw const ProtocolError('Unknown Control frame type.');
  }
  final timestamp = asInt(map['timestamp']);
  if (timestamp == null || timestamp <= 0 || timestamp > maxSafeInteger) {
    throw const ProtocolError('Control frame timestamp must be a positive safe integer.');
  }
  if (!map.containsKey('payload')) throw const ProtocolError('Control frame payload is required.');
  final payload = asMap(map['payload']);
  if (payload == null) throw ProtocolError('$type payload must be an object.');
  return ControlFrame(type, _parsePayload(type, payload), id: id, timestamp: timestamp);
}

/// Validates and encodes [frame], enforcing the (negotiated) byte limit.
String encodeControlFrame(ControlFrame frame, [ControlFrameLimits limits = const ControlFrameLimits()]) {
  final parsed = parseControlFrame(frame.toJson());
  final encoded = jsonEncode(parsed.toJson());
  _assertSize(utf8.encode(encoded).length, parsed.type, limits);
  return encoded;
}

/// Decodes one Control text frame, enforcing the (negotiated) byte limit.
ControlFrame decodeControlFrame(String data, [ControlFrameLimits limits = const ControlFrameLimits()]) {
  final bytes = utf8.encode(data).length;
  if (bytes > maxRelayFrameBytes) {
    throw const ProtocolError('Control frame exceeds the Relay frame limit.', 'FRAME_TOO_LARGE');
  }
  final Object? json;
  try {
    json = decodeWireJson(data);
  } on FormatException {
    throw const ProtocolError('Control frame is not JSON.');
  }
  final frame = parseControlFrame(json);
  _assertSize(bytes, frame.type, limits);
  return frame;
}

/// Validates and encodes a frame for the independent Relay data WebSocket.
/// Its envelope is the Control envelope with a free-form `type`; every
/// frame counts against the Relay limit.
String encodeRelayDataFrame(ControlFrame frame, [ControlFrameLimits limits = const ControlFrameLimits()]) {
  final parsed = _parseRelayDataFrame(frame.toJson());
  final encoded = jsonEncode(parsed.toJson());
  _assertSize(utf8.encode(encoded).length, 'relay', limits);
  return encoded;
}

/// Decodes one Relay data text frame (`relay.ready`, `relay`,
/// `relay.detach`, `ping`, ...), checking the size before parsing.
ControlFrame decodeRelayDataFrame(String data, [ControlFrameLimits limits = const ControlFrameLimits()]) {
  _assertSize(utf8.encode(data).length, 'relay', limits);
  final Object? json;
  try {
    json = decodeWireJson(data);
  } on FormatException {
    throw const ProtocolError('Invalid Relay data frame.');
  }
  return _parseRelayDataFrame(json);
}

ControlFrame _parseRelayDataFrame(Object? input) {
  final map = asMap(input);
  final id = map?['id'];
  final type = map?['type'];
  final timestamp = asInt(map?['timestamp']);
  final payload = asMap(map?['payload']);
  if (map == null ||
      map.length != 5 ||
      map['v'] != protocolVersion ||
      id is! String ||
      id.isEmpty ||
      type is! String ||
      type.isEmpty ||
      timestamp == null ||
      timestamp <= 0 ||
      timestamp > maxSafeInteger ||
      payload == null) {
    throw const ProtocolError('Invalid Relay data frame.');
  }
  final parsed = type == 'relay' || type == 'secure.handshake' ? _parsePayload(type, payload) : payload;
  return ControlFrame(type, parsed, id: id, timestamp: timestamp);
}

void _assertSize(int bytes, String type, ControlFrameLimits limits) {
  final relay = type == 'relay';
  final configured = relay ? limits.maxRelayFrameBytes : limits.maxControlFrameBytes;
  final maximum = relay ? maxRelayFrameBytes : maxControlFrameBytes;
  final limit = configured == null ? maximum : (configured < maximum ? configured : maximum);
  if (limit <= 0) throw const ProtocolError('Control frame limit is invalid.');
  if (bytes > limit) {
    throw ProtocolError('${relay ? 'Relay' : 'Control'} frame exceeds its limit.', 'FRAME_TOO_LARGE');
  }
}

// ---------------------------------------------------------------------------
// Negotiation

/// Highest version in both sets, or `null`.
int? selectProtocolVersion(List<int> offered, [List<int> supported = const [protocolVersion]]) {
  final common = offered.where(supported.contains).toList()..sort();
  return common.isEmpty ? null : common.last;
}

/// [supported] filtered to [offered], in [supported] order.
List<String> selectCapabilities(List<String> offered, List<String> supported) {
  final set = offered.toSet();
  return supported.toSet().where(set.contains).toList();
}

/// Validates the Server's `hello.ack.capabilities` against what was offered.
/// A legacy Server omitting the field implies `transport.relay`.
List<String> acceptNegotiatedCapabilities(List<String> offered, List<String>? negotiated) {
  final accepted = negotiated ?? const ['transport.relay'];
  if (selectCapabilities(accepted, offered).length != accepted.length) {
    throw const ProtocolError('Server selected a capability that the peer did not offer.');
  }
  return [...accepted];
}

// ---------------------------------------------------------------------------
// Payload schemas

JsonMap _parsePayload(String type, JsonMap input) {
  final p = Map<String, Object?>.of(input);
  switch (type) {
    case 'hello':
      _enum(p, 'role', const ['host', 'client']);
      _nonEmpty(p, 'deviceId');
      _nonEmpty(p, 'accessToken');
      final protocols = _list(p, 'protocols');
      if (protocols.isEmpty ||
          protocols.length > _maxProtocolListEntries ||
          protocols.any((v) => !isSafeInteger(v) || asInt(v)! < 0) ||
          protocols.toSet().length != protocols.length) {
        throw const ProtocolError('hello.protocols is invalid.');
      }
      p['protocols'] = protocols.map((v) => asInt(v)!).toList();
      _capabilities(p, required: true);
      _optionalString(p, 'clientVersion');
      _optionalString(p, 'harnessVersion');
      if (p.containsKey('recoveryTickets')) {
        final tickets = _list(p, 'recoveryTickets');
        if (tickets.length > 64 || tickets.any((v) => v is! String || v.isEmpty || v.length > 4096)) {
          throw const ProtocolError('hello.recoveryTickets is invalid.');
        }
      }
      return _fields(p, const [
        'recoveryTickets',
        'role',
        'deviceId',
        'accessToken',
        'protocols',
        'capabilities',
        'clientVersion',
        'harnessVersion',
      ]);
    case 'hello.ack':
      if (p['protocol'] != protocolVersion) {
        throw const ProtocolError('hello.ack selected an unsupported protocol.', 'UNSUPPORTED_VERSION');
      }
      p['protocol'] = protocolVersion;
      _nonEmpty(p, 'serverVersion');
      _nonEmpty(p, 'connectionSessionId');
      _positiveInt(p, 'heartbeatIntervalMs');
      _positiveInt(p, 'maxControlFrameBytes', max: maxControlFrameBytes);
      _positiveInt(p, 'maxRelayFrameBytes', max: maxRelayFrameBytes);
      _capabilities(p, required: false);
      _optionalBool(p, 'webrtcEnabled');
      if (p.containsKey('webrtcFallbackTimeoutMs')) _positiveInt(p, 'webrtcFallbackTimeoutMs');
      return _fields(p, const [
        'protocol',
        'serverVersion',
        'connectionSessionId',
        'heartbeatIntervalMs',
        'maxControlFrameBytes',
        'maxRelayFrameBytes',
        'capabilities',
        'webrtcEnabled',
        'webrtcFallbackTimeoutMs',
      ]);
    case 'connect.request':
      _nonEmpty(p, 'hostDeviceId');
      _transports(p);
      return _fields(p, const ['hostDeviceId', 'preferredTransports']);
    case 'connect.incoming':
      _nonEmpty(p, 'connectionId');
      _nonEmpty(p, 'clientDeviceId');
      final key = p['clientIdentityKey'];
      if (key is! String || !identityKeyPattern.hasMatch(key)) {
        throw const ProtocolError('connect.incoming.clientIdentityKey is not a canonical X25519 key.');
      }
      if (p['authorization'] != 'account') {
        throw const ProtocolError('connect.incoming.authorization must be "account".');
      }
      _transports(p);
      _recoveryTickets(p);
      _relayAssignment(p);
      return _fields(p, const [
        'relayRecoveryTicket',
        'recoveryTicket',
        'connectionId',
        'clientDeviceId',
        'clientIdentityKey',
        'authorization',
        'preferredTransports',
        'relayEndpoint',
        'relayTicket',
        'relayNodeId',
        'relayEpoch',
      ]);
    case 'connect.accepted':
      _nonEmpty(p, 'connectionId');
      _recoveryTickets(p);
      _relayAssignment(p);
      if (p.containsKey('webrtcFallbackTimeoutMs')) _positiveInt(p, 'webrtcFallbackTimeoutMs', max: 2147483647);
      _optionalBool(p, 'parallelConnections');
      return _fields(p, const [
        'webrtcFallbackTimeoutMs',
        'parallelConnections',
        'relayRecoveryTicket',
        'recoveryTicket',
        'connectionId',
        'relayEndpoint',
        'relayTicket',
        'relayNodeId',
        'relayEpoch',
      ]);
    case 'connect.rejected':
      _nonEmpty(p, 'connectionId');
      _optionalString(p, 'code');
      _optionalString(p, 'message');
      return _fields(p, const ['connectionId', 'code', 'message']);
    case 'secure.handshake':
      _nonEmpty(p, 'connectionId');
      _nonEmpty(p, 'targetDeviceId');
      if (p['step'] != 1 && p['step'] != 2) throw const ProtocolError('secure.handshake.step must be 1 or 2.');
      p['step'] = asInt(p['step'])!;
      _base64Url(p, 'data');
      return _fields(p, const ['connectionId', 'targetDeviceId', 'step', 'data']);
    case 'relay':
      _nonEmpty(p, 'connectionId');
      _nonEmpty(p, 'targetDeviceId');
      _nonnegativeInt(p, 'counter');
      _base64Url(p, 'ciphertext');
      return _fields(p, const ['connectionId', 'targetDeviceId', 'counter', 'ciphertext']);
    case 'signal.offer' || 'signal.answer':
      _nonEmpty(p, 'connectionId');
      _nonEmpty(p, 'targetDeviceId');
      _nonEmpty(p, 'sdp');
      return _fields(p, const ['connectionId', 'targetDeviceId', 'sdp']);
    case 'signal.ice':
      _nonEmpty(p, 'connectionId');
      _nonEmpty(p, 'targetDeviceId');
      final candidate = asMap(p['candidate']);
      if (candidate == null) throw const ProtocolError('signal.ice.candidate must be an object.');
      final ice = _fields(candidate, const ['candidate', 'sdpMid', 'sdpMLineIndex', 'usernameFragment']);
      _optionalString(ice, 'candidate');
      _optionalString(ice, 'sdpMid', nullable: true);
      _optionalString(ice, 'usernameFragment', nullable: true);
      if (ice.containsKey('sdpMLineIndex')) {
        final index = asInt(ice['sdpMLineIndex']);
        ice['sdpMLineIndex'] = index == null || index < 0 ? null : index;
        if (ice['sdpMLineIndex'] != null) _nonnegativeInt(ice, 'sdpMLineIndex');
      }
      p['candidate'] = ice;
      return _fields(p, const ['connectionId', 'targetDeviceId', 'candidate']);
    case 'transport.selected':
      _nonEmpty(p, 'connectionId');
      _nonEmpty(p, 'targetDeviceId');
      _enum(p, 'transport', remoteTransports);
      if (p.containsKey('turnNode')) _nonEmpty(p, 'turnNode', max: 253);
      return _fields(p, const ['connectionId', 'targetDeviceId', 'transport', 'turnNode']);
    case 'connection.lease.request' || 'connection.lease.ack':
      _nonEmpty(p, 'connectionId', max: 128);
      _nonEmpty(p, 'requestId', max: 128);
      _nonEmpty(p, 'ticket', max: 4096);
      if (type == 'connection.lease.ack') {
        if (p['leaseMs'] != controlLeaseMs) throw const ProtocolError('connection.lease.ack.leaseMs is invalid.');
        p['leaseMs'] = controlLeaseMs;
        return _fields(p, const ['connectionId', 'requestId', 'ticket', 'leaseMs']);
      }
      return _fields(p, const ['connectionId', 'requestId', 'ticket']);
    case 'connection.lease.close':
      _nonEmpty(p, 'connectionId', max: 128);
      return _fields(p, const ['connectionId']);
    case 'ping' || 'pong':
      _nonEmpty(p, 'nonce');
      return _fields(p, const ['nonce']);
    case 'error':
      _nonEmpty(p, 'code');
      _nonEmpty(p, 'message');
      _optionalBool(p, 'retryable');
      if (p.containsKey('connectionId')) _nonEmpty(p, 'connectionId');
      return _fields(p, const ['code', 'message', 'retryable', 'connectionId']);
    default:
      throw const ProtocolError('Unknown Control frame type.');
  }
}

JsonMap _fields(JsonMap p, List<String> keys) => {
  for (final key in keys)
    if (p.containsKey(key)) key: p[key],
};

void _nonEmpty(JsonMap p, String key, {int? max}) {
  final value = p[key];
  if (value is! String || value.isEmpty || (max != null && value.length > max)) {
    throw ProtocolError('$key must be a non-empty string${max == null ? '' : ' of at most $max characters'}.');
  }
}

void _optionalString(JsonMap p, String key, {bool nullable = false}) {
  if (p.containsKey(key) && p[key] is! String && !(nullable && p[key] == null)) {
    throw ProtocolError('$key must be a string.');
  }
}

void _optionalBool(JsonMap p, String key) {
  if (p.containsKey(key) && p[key] is! bool) throw ProtocolError('$key must be a boolean.');
}

void _recoveryTickets(JsonMap p) {
  for (final key in const ['recoveryTicket', 'relayRecoveryTicket']) {
    if (p.containsKey(key)) _nonEmpty(p, key, max: 4096);
  }
}

void _enum(JsonMap p, String key, List<String> values) {
  if (!values.contains(p[key])) throw ProtocolError('$key is not one of $values.');
}

void _positiveInt(JsonMap p, String key, {int? max}) {
  final value = asInt(p[key]);
  if (value == null || value <= 0 || value > maxSafeInteger || (max != null && value > max)) {
    throw ProtocolError('$key must be a positive integer${max == null ? '' : ' ≤ $max'}.');
  }
  p[key] = value;
}

void _nonnegativeInt(JsonMap p, String key) {
  final value = asInt(p[key]);
  if (value == null || value < 0 || value > maxSafeInteger) {
    throw ProtocolError('$key must be a non-negative safe integer.');
  }
  p[key] = value;
}

List<Object?> _list(JsonMap p, String key) {
  final value = p[key];
  if (value is! List) throw ProtocolError('$key must be an array.');
  return value.cast<Object?>();
}

void _capabilities(JsonMap p, {required bool required}) {
  if (!p.containsKey('capabilities')) {
    if (required) throw const ProtocolError('capabilities is required.');
    return;
  }
  final values = _list(p, 'capabilities');
  if (values.length > maxRemoteCapabilityEntries ||
      values.any((v) => v is! String || v.isEmpty) ||
      values.toSet().length != values.length) {
    throw const ProtocolError('capabilities must be at most $maxRemoteCapabilityEntries unique non-empty strings.');
  }
}

void _transports(JsonMap p) {
  final values = _list(p, 'preferredTransports');
  if (values.isEmpty || values.length > remoteTransports.length || values.any((v) => !remoteTransports.contains(v))) {
    throw const ProtocolError('preferredTransports is invalid.');
  }
}

void _base64Url(JsonMap p, String key) {
  final value = p[key];
  if (value is! String || !isCanonicalBase64Url(value)) {
    throw ProtocolError('$key must be canonical unpadded base64url.');
  }
}

/// Optional independent Relay assignment (`transport.relay.attach`).
void _relayAssignment(JsonMap p) {
  if (p.containsKey('relayEndpoint')) {
    final endpoint = p['relayEndpoint'];
    final uri = endpoint is String ? Uri.tryParse(endpoint) : null;
    if (uri == null || !uri.hasScheme) throw const ProtocolError('relayEndpoint must be a URL.');
    if (const ['http', 'https', 'ws', 'wss', 'ftp'].contains(uri.scheme)) {
      // WHATWG special URLs also accept scheme:path and normalize slashes;
      // unlike a custom opaque scheme, they must resolve to a nonempty host.
      final target = (endpoint as String)
          .substring(uri.scheme.length + 1)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^/+'), '');
      final authority = Uri.tryParse('${uri.scheme}://$target');
      if (authority == null || authority.host.isEmpty) {
        throw const ProtocolError('relayEndpoint must be a URL.');
      }
    }
  }
  if (p.containsKey('relayTicket')) _nonEmpty(p, 'relayTicket');
  if (p.containsKey('relayNodeId')) _nonEmpty(p, 'relayNodeId');
  if (p.containsKey('relayEpoch')) _nonnegativeInt(p, 'relayEpoch');
}
