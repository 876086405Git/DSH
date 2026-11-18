/// The OHOS phone callback on the existing authenticated local Host listener.
/// The separate owner capability comes only from the local MethodChannel.
library;

import 'dart:convert';
import 'dart:io';

import 'connection.dart';
import 'errors.dart';

const _wireBytes = 4 * 1024 * 1024;
const _safeInteger = 9007199254740991;
const _tools = {
  'mcp__phone__open',
  'mcp__phone__intent',
  'mcp__phone__notify',
  'mcp__phone__clipboard',
  'mcp__phone__handoff',
};

Never _invalid() => throw const DshProtocolException('Invalid phone callback envelope');

Map<String, Object?> _object(Object? raw, Set<String> fields) {
  if (raw is! Map || raw.length != fields.length || raw.keys.any((key) => key is! String || !fields.contains(key))) {
    _invalid();
  }
  return raw.cast<String, Object?>();
}

String _id(Object? value) {
  if (value is! String || value.isEmpty || value.length > 256 || value.contains('\u0000')) _invalid();
  return value;
}

int _positive(Object? value) {
  if (value is! int || value < 1 || value > _safeInteger) _invalid();
  return value;
}

String _uuid(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is bool || value is num && value.isFinite) return value;
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeJson));
  if (value is Map && value.keys.every((key) => key is String)) {
    return Map<String, Object?>.unmodifiable(value.map((key, item) => MapEntry(key as String, _freezeJson(item))));
  }
  _invalid();
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length && Iterable<int>.generate(a.length).every((i) => _sameJson(a[i], b[i]));
  }
  return a == b;
}

/// An in-memory capability for one native engine / Ability / Flutter owner.
/// Do not persist it, put it in generic runtime status, or include it in logs.
final class DshPhoneOwner {
  DshPhoneOwner._(this.engineId, this.bridgeGeneration, this.baseUri, this._owner);

  factory DshPhoneOwner.fromNative(Object? raw) {
    final map = _object(raw, {'v', 'engineId', 'bridgeGeneration', 'baseUrl', 'owner'});
    final url = map['baseUrl'];
    final owner = map['owner'];
    if (map['v'] != 1 ||
        url is! String ||
        !RegExp(r'^http://127\.0\.0\.1:[1-9][0-9]{0,4}/?$').hasMatch(url) ||
        owner is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(owner)) {
      _invalid();
    }
    final uri = Uri.parse(url);
    if (uri.port > 65535) _invalid();
    return DshPhoneOwner._(_id(map['engineId']), _positive(map['bridgeGeneration']), uri.replace(path: ''), owner);
  }

  final String engineId;
  final int bridgeGeneration;
  final Uri baseUri;
  final String _owner;

  /// Identity for the local native channel; the HTTP owner secret stays private.
  Map<String, Object?> get nativeScope => {'engineId': engineId, 'bridgeGeneration': bridgeGeneration};
  Map<String, Object?> get _control => {'v': 1, ...nativeScope, 'owner': _owner};

  bool owns(DshPhoneRequest request) => request.engineId == engineId && request.bridgeGeneration == bridgeGeneration;

  @override
  String toString() => 'DshPhoneOwner(generation: $bridgeGeneration)';
}

/// An immutable request. Its deadline is native BOOTTIME, never wall-clock time.
final class DshPhoneRequest {
  DshPhoneRequest._(
    this.engineId,
    this.bridgeGeneration,
    this.requestId,
    this.sessionId,
    this.callId,
    this.tool,
    this.args,
    this.timeoutMs,
    this.deadlineMs,
  );

  factory DshPhoneRequest.fromJson(Object? raw) {
    final map = _object(raw, {
      'v',
      'engineId',
      'bridgeGeneration',
      'requestId',
      'sessionId',
      'callId',
      'tool',
      'args',
      'timeoutMs',
      'deadlineMs',
    });
    final tool = map['tool'];
    final args = _freezeJson(map['args']);
    if (map['v'] != 1 || tool is! String || !_tools.contains(tool) || args is! Map<String, Object?>) _invalid();
    final budget = tool == 'mcp__phone__handoff' ? 600000 : 30000;
    if (map['timeoutMs'] != budget) _invalid();
    final deadline = _positive(map['deadlineMs']);
    if (deadline < budget) _invalid();
    return DshPhoneRequest._(
      _id(map['engineId']),
      _positive(map['bridgeGeneration']),
      _uuid(map['requestId']),
      _id(map['sessionId']),
      _id(map['callId']),
      tool,
      args,
      budget,
      deadline,
    );
  }

  final String engineId;
  final int bridgeGeneration;
  final String requestId;
  final String sessionId;
  final String callId;
  final String tool;
  final Map<String, Object?> args;
  final int timeoutMs;
  final int deadlineMs;
  bool get isHandoff => tool == 'mcp__phone__handoff';

  Map<String, Object?> toJson() => {
    'v': 1,
    'engineId': engineId,
    'bridgeGeneration': bridgeGeneration,
    'requestId': requestId,
    'sessionId': sessionId,
    'callId': callId,
    'tool': tool,
    'args': args,
    'timeoutMs': timeoutMs,
    'deadlineMs': deadlineMs,
  };

  @override
  String toString() => 'DshPhoneRequest($tool)';
}

/// One claim attempt. A lost claim response is never retried as a new action.
final class DshPhoneClaim {
  DshPhoneClaim._(this.request, this.executionNonce);
  final DshPhoneRequest request;
  final String executionNonce;

  /// No tool arguments: native code retrieves its immutable claim by identity.
  Map<String, Object?> get nativeIdentity => {
    'engineId': request.engineId,
    'bridgeGeneration': request.bridgeGeneration,
    'requestId': request.requestId,
    'executionNonce': executionNonce,
  };

  @override
  String toString() => 'DshPhoneClaim(${request.tool})';
}

enum DshPhoneStatus {
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled'),
  timedOut('timed_out'),
  unknown('unknown');

  const DshPhoneStatus(this.wire);
  final String wire;
}

enum DshPhoneEffect {
  none('none'),
  openedUi('opened_ui'),
  notificationPublished('notification_published'),
  clipboardWritten('clipboard_written'),
  reminderScheduled('reminder_scheduled');

  const DshPhoneEffect(this.wire);
  final String wire;
}

enum DshPhoneEvidence {
  openedUi('opened_ui'),
  userConfirmed('user_confirmed'),
  unknown('unknown');

  const DshPhoneEvidence(this.wire);
  final String wire;
}

T _enum<T extends Enum>(List<T> values, Object? raw, String Function(T) wire) {
  for (final value in values) {
    if (wire(value) == raw) return value;
  }
  _invalid();
}

final class DshPhoneResult {
  const DshPhoneResult({
    required this.status,
    required this.effect,
    required this.evidence,
    required this.dispatched,
    required this.code,
    required this.message,
  });

  factory DshPhoneResult.fromJson(Object? raw) {
    final map = _object(raw, {'status', 'effect', 'evidence', 'dispatched', 'code', 'message'});
    final code = map['code'];
    final message = map['message'];
    if (map['dispatched'] is! bool ||
        code is! String ||
        !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(code) ||
        message is! String ||
        utf8.encode(message).length > 8192) {
      _invalid();
    }
    return DshPhoneResult(
      status: _enum(DshPhoneStatus.values, map['status'], (value) => value.wire),
      effect: _enum(DshPhoneEffect.values, map['effect'], (value) => value.wire),
      evidence: _enum(DshPhoneEvidence.values, map['evidence'], (value) => value.wire),
      dispatched: map['dispatched'] as bool,
      code: code,
      message: message,
    );
  }

  final DshPhoneStatus status;
  final DshPhoneEffect effect;
  final DshPhoneEvidence evidence;
  final bool dispatched;
  final String code;
  final String message;

  void validateFor(DshPhoneRequest request) {
    // Validate constructed results too, before any capability-bearing HTTP call.
    DshPhoneResult.fromJson(toJson());
    if (status != DshPhoneStatus.succeeded) {
      if (effect != DshPhoneEffect.none || evidence != DshPhoneEvidence.unknown) _invalid();
      return;
    }
    if (effect == DshPhoneEffect.reminderScheduled) {
      if (!dispatched ||
          evidence != DshPhoneEvidence.unknown ||
          request.tool != 'mcp__phone__intent' ||
          !const {'alarm', 'timer'}.contains(request.args['kind'])) {
        _invalid();
      }
      return;
    }
    final expected = switch (request.tool) {
      'mcp__phone__open' || 'mcp__phone__intent' => (DshPhoneEffect.openedUi, DshPhoneEvidence.openedUi),
      'mcp__phone__notify' => (DshPhoneEffect.notificationPublished, DshPhoneEvidence.unknown),
      'mcp__phone__clipboard' => (DshPhoneEffect.clipboardWritten, DshPhoneEvidence.unknown),
      'mcp__phone__handoff' => (DshPhoneEffect.none, DshPhoneEvidence.userConfirmed),
      _ => _invalid(),
    };
    if (!dispatched || effect != expected.$1 || evidence != expected.$2) _invalid();
  }

  /// Field order is part of the native completion encoding contract.
  Map<String, Object?> toJson() => {
    'status': status.wire,
    'effect': effect.wire,
    'evidence': evidence.wire,
    'dispatched': dispatched,
    'code': code,
    'message': message,
  };

  @override
  String toString() => 'DshPhoneResult(${status.name}, ${effect.name}, $code)';
}

final class DshPhoneReceipt {
  const DshPhoneReceipt(this.accepted, this.result);
  final bool accepted;
  final DshPhoneResult result;
}

/// An error includes no raw response, token, arguments or native exception text.
final class DshPhoneException implements Exception {
  const DshPhoneException(this.code, this.httpStatus);
  final String code;
  final int httpStatus;
  @override
  String toString() => 'DshPhoneException($httpStatus, $code)';
}

/// Owns a bounded local HTTP connection, while using the current signed cookie
/// from [authenticated]. Closing it aborts its long poll without closing the
/// application's normal DSH connection. No redirect, tunnel, proxy override or
/// remote endpoint may receive the native owner capability.
final class DshPhoneClient {
  factory DshPhoneClient(DshConnection authenticated, DshPhoneOwner owner) {
    _checkConnection(authenticated, owner);
    if (HttpOverrides.current != null) throw const DshPhoneException('transport_override', 0);
    return DshPhoneClient._(
      authenticated,
      owner,
      DshConnection(
        owner.baseUri,
        connectTimeout: const Duration(seconds: 5),
        requestTimeout: const Duration(seconds: 20),
      ),
    );
  }

  DshPhoneClient._(this._authenticated, this.owner, this._wire);
  final DshConnection _authenticated;
  final DshPhoneOwner owner;
  final DshConnection _wire;
  final _abort = DshHttpAbort();
  bool _closed = false;
  bool _reading = false;

  static void _checkConnection(DshConnection connection, DshPhoneOwner owner) {
    final cookie = connection.cookie;
    if (connection.baseUri != owner.baseUri ||
        connection.authority != owner.baseUri.authority ||
        cookie == null ||
        cookie.authority != owner.baseUri.authority ||
        cookie.isExpiredAt(DateTime.now())) {
      throw const DshPhoneException('local_connection_required', 0);
    }
  }

  void _checkRequest(DshPhoneRequest request) {
    if (!owner.owns(request)) throw const DshPhoneException('wrong_generation', 0);
  }

  Future<Map<String, Object?>> _post(String action, Map<String, Object?> body) async {
    if (_closed) throw const DshClosedException('Phone callback closed');
    _checkConnection(_authenticated, owner);
    if (HttpOverrides.current != null) throw const DshPhoneException('transport_override', 0);
    _wire.cookie = _authenticated.cookie;
    final bytes = utf8.encode(jsonEncode({...owner._control, ...body}));
    if (bytes.length > 16384) _invalid();
    DshHttpResponse response;
    try {
      response = await _wire.postBytes(
        '/dsh-go/v1/phone/$action',
        bytes,
        contentType: 'application/json',
        followRedirects: false,
        maxResponseBytes: _wireBytes,
        timeout: const Duration(seconds: 20),
        abort: _abort,
      );
    } catch (_) {
      if (_closed) throw const DshClosedException('Phone callback closed');
      rethrow;
    }
    if (_closed) throw const DshClosedException('Phone callback closed');
    if (response.statusCode != 200) {
      var code = 'http_rejected';
      try {
        final raw = jsonDecode(utf8.decode(response.body));
        final value = raw is Map && raw['error'] is Map ? raw['error']['code'] : null;
        if (value is String && RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(value)) code = value;
      } catch (_) {
        /* An error body never becomes user-visible raw data. */
      }
      throw DshPhoneException(code, response.statusCode);
    }
    if (response.contentType != 'application/json') _invalid();
    Object? raw;
    try {
      raw = jsonDecode(utf8.decode(response.body));
    } catch (_) {
      _invalid();
    }
    if (raw is! Map || raw.keys.any((key) => key is! String)) _invalid();
    return raw.cast<String, Object?>();
  }

  Future<DshPhoneRequest?> next() async {
    if (_reading) throw const DshPhoneException('read_in_progress', 0);
    _reading = true;
    try {
      final map = _object(await _post('next', const {}), {'v', 'request'});
      if (map['v'] != 1) _invalid();
      if (map['request'] == null) return null;
      final request = DshPhoneRequest.fromJson(map['request']);
      _checkRequest(request);
      return request;
    } finally {
      _reading = false;
    }
  }

  Future<DshPhoneClaim> claim(DshPhoneRequest request) async {
    _checkRequest(request);
    final map = _object(await _post('claim', {'requestId': request.requestId}), {'request', 'executionNonce'});
    final returned = DshPhoneRequest.fromJson(map['request']);
    if (!_sameJson(returned.toJson(), request.toJson())) _invalid();
    return DshPhoneClaim._(returned, _uuid(map['executionNonce']));
  }

  Future<void> waiting(DshPhoneClaim claim) async {
    _checkRequest(claim.request);
    if (!claim.request.isHandoff) _invalid();
    final map = _object(
      await _post('result', {
        'requestId': claim.request.requestId,
        'executionNonce': claim.executionNonce,
        'phase': 'waiting_user',
      }),
      {'accepted', 'phase'},
    );
    if (map['accepted'] != true || map['phase'] != 'waiting_user') _invalid();
  }

  Future<DshPhoneReceipt> report(DshPhoneClaim claim, DshPhoneResult result) async {
    _checkRequest(claim.request);
    result.validateFor(claim.request);
    final map = _object(
      await _post('result', {
        'requestId': claim.request.requestId,
        'executionNonce': claim.executionNonce,
        'result': result.toJson(),
      }),
      {'accepted', 'result'},
    );
    if (map['accepted'] is! bool) _invalid();
    final returned = DshPhoneResult.fromJson(map['result']);
    returned.validateFor(claim.request);
    if (map['accepted'] == true && !_sameJson(result.toJson(), returned.toJson())) _invalid();
    return DshPhoneReceipt(map['accepted'] as bool, returned);
  }

  Future<bool> cancel(DshPhoneRequest request) async {
    _checkRequest(request);
    final map = _object(await _post('cancel', {'requestId': request.requestId}), {'accepted'});
    if (map['accepted'] is! bool) _invalid();
    return map['accepted'] as bool;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _abort.abort();
    _wire.close(force: true);
  }
}
