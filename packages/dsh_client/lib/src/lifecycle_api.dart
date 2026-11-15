/// Optional authenticated lifecycle reconciliation API (protocol v1).
/// Reads never resume, acknowledge or replay work. No automatic subscriptions.
library;

import 'dart:convert';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const lifecyclePath = '/dsh-go/v1/lifecycle';
const lifecycleResultPath = '$lifecyclePath/result';
const _safeInteger = 9007199254740991;

Never _malformed() => throw const DshProtocolException('Invalid lifecycle response');
JsonMap _map(Object? value) => asMap(value) ?? _malformed();
String _string(JsonMap map, String key) => switch (map[key]) {
  final String s when s.isNotEmpty => s,
  _ => _malformed(),
};
bool _bool(JsonMap map, String key) => switch (map[key]) {
  final bool b => b,
  _ => _malformed(),
};
int _integer(JsonMap map, String key, {int minimum = 0}) => switch (map[key]) {
  final int n when n >= minimum && n <= _safeInteger => n,
  _ => _malformed(),
};

/// Durable identity: callId alone is not unique across sessions.
class LifecycleCallIdentity {
  LifecycleCallIdentity.fromJson(Object? value) {
    final map = _map(value);
    sessionId = _string(map, 'sessionId');
    callSeq = _integer(map, 'callSeq');
    callId = _string(map, 'callId');
    name = _string(map, 'name');
    turn = _integer(map, 'turn', minimum: 1);
    step = _integer(map, 'step', minimum: 1);
    originBootId = _string(map, 'originBootId');
    callHash = _string(map, 'callHash');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(callHash)) _malformed();
  }

  late final String sessionId, callId, name, originBootId, callHash;
  late final int callSeq, turn, step;
}

class LifecycleCall {
  LifecycleCall.fromJson(Object? value) {
    final map = _map(value);
    identity = LifecycleCallIdentity.fromJson(map);
    phase = _string(map, 'phase');
    active = _bool(map, 'active');
    dispatchActive = _bool(map, 'dispatchActive');
    hasReturned = _bool(map, 'hasReturned');
    hasFinalOutcome = _bool(map, 'hasFinalOutcome');
    final reconciliation = map['reconciliation'];
    if (reconciliation != null) {
      final row = _map(reconciliation);
      reconciliationBasis = _string(row, 'basis');
      reconciliationBlocking = _bool(row, 'blocking');
    } else {
      reconciliationBasis = null;
      reconciliationBlocking = null;
    }
  }

  late final LifecycleCallIdentity identity;
  late final String phase;
  late final bool active, dispatchActive, hasReturned, hasFinalOutcome;
  late final String? reconciliationBasis;
  late final bool? reconciliationBlocking;

  /// Matches the server's unresolved-call predicate. A missing reconciliation
  /// is not evidence of success, nor is a raw/final stored result by itself.
  bool get isUnresolved =>
      !active && (reconciliationBlocking == true || phase != 'committed') && reconciliationBlocking != false;
}

enum LifecycleState {
  running('running'),
  paused('paused'),
  cancelling('cancelling'),
  terminated('terminated'),
  completed('completed'),
  resultUnknown('result-unknown');

  const LifecycleState(this.wire);
  final String wire;
}

/// A server snapshot filtered to exactly the requested session.
/// [blocked] is a global persistence fault; an ack cannot repair it.
class LifecycleSnapshot {
  LifecycleSnapshot.fromJson(Object? value, {required this.sessionId}) {
    final map = _map(value);
    if (map['v'] != 1) _malformed();
    bootId = _string(map, 'bootId');
    final wire = _string(map, 'state');
    state = LifecycleState.values.firstWhere((s) => s.wire == wire, orElse: _malformed);
    closed = _bool(map, 'closed');
    paused = _bool(map, 'paused');
    confirmedPause = _bool(map, 'confirmedPause');
    blocked = _bool(map, 'blocked');
    controlVersion = _integer(map, 'controlVersion');
    final entries = map['calls'];
    if (entries is! List) _malformed();
    calls = List.unmodifiable(entries.map(LifecycleCall.fromJson));
    final sequences = <int>{};
    for (final call in calls) {
      if (call.identity.sessionId != sessionId || !sequences.add(call.identity.callSeq)) _malformed();
    }
  }

  final String sessionId;
  late final String bootId;
  late final LifecycleState state;
  late final bool closed, paused, confirmedPause, blocked;
  late final int controlVersion;
  late final List<LifecycleCall> calls;
  bool get hasUnknownResult => state == LifecycleState.resultUnknown;
  Iterable<LifecycleCall> get unresolvedCalls => calls.where((call) => call.isUnresolved);
}

/// Saved JSON is inspection evidence, never an instruction to apply/replay it.
/// Even a final result may refer to external resources that no longer exist.
class LifecycleStoredResult {
  LifecycleStoredResult.fromJson(Object? value) {
    final map = _map(value);
    identity = LifecycleCallIdentity.fromJson(map['identity']);
    isFinal = _bool(map, 'final');
    if (!map.containsKey('result')) _malformed();
    result = map['result'];
    sessionData = map['sessionData'];
    if (isFinal && (!map.containsKey('sessionData') || map['resources'] is! List)) _malformed();
    resources = List.unmodifiable(asListOrEmpty(map['resources']));
  }

  late final LifecycleCallIdentity identity;
  late final bool isFinal;
  late final Object? result, sessionData;
  late final List<Object?> resources;
}

void _session(String value) {
  if (value.isEmpty || value.length > 4096 || value.contains('\u0000')) {
    throw ArgumentError.value(value, 'sessionId');
  }
}

DshConnection _connection(DshClient client) {
  final carrier = client.carrier;
  if (carrier is! DshHttpCarrier) {
    throw const DshRemoteException('unavailable', 'Lifecycle HTTP routes are unavailable on this carrier');
  }
  return carrier.connection;
}

JsonMap _response(DshHttpResponse response) {
  final body = response.contentType == 'application/json' ? asMap(tryDecodeJson(response.text)) : null;
  if (response.statusCode != 200) {
    final code = asString(asMap(body?['error'])?['code']);
    if (code != null && code.length <= 80 && RegExp(r'^ERR_OHOS_LIFECYCLE_[A-Z_]+$').hasMatch(code)) {
      throw DshRemoteException(code, 'Host refused lifecycle operation');
    }
    if ([404, 405, 501].contains(response.statusCode)) {
      throw const DshRemoteException('unavailable', 'Lifecycle route is unavailable');
    }
    throw DshHttpException(response.statusCode, 'Lifecycle request failed');
  }
  return body ?? _malformed();
}

extension LifecycleApi on DshClient {
  /// Authenticated inspection only. An unsupported route is not an empty list.
  Future<LifecycleSnapshot> getLifecycleStatus(
    String sessionId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _session(sessionId);
    final response = await _connection(this).get(
      lifecyclePath,
      query: {'sessionId': sessionId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 8 * 1024 * 1024,
    );
    return LifecycleSnapshot.fromJson(_response(response), sessionId: sessionId);
  }

  /// Null means the exact authenticated RESULT_ABSENT response, not success.
  /// Does not acknowledge the unknown, mutate history or reopen a resource.
  Future<LifecycleStoredResult?> getLifecycleResult(
    String sessionId,
    int callSeq, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _session(sessionId);
    if (callSeq < 0 || callSeq > _safeInteger) throw ArgumentError.value(callSeq, 'callSeq');
    final response = await _connection(this).get(
      lifecycleResultPath,
      query: {'sessionId': sessionId, 'callSeq': '$callSeq'},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 17 * 1024 * 1024,
    );
    if (response.statusCode == 404 &&
        response.contentType == 'application/json' &&
        asMap(asMap(tryDecodeJson(response.text))?['error'])?['code'] == 'ERR_OHOS_LIFECYCLE_RESULT_ABSENT') {
      return null;
    }
    final result = LifecycleStoredResult.fromJson(_response(response));
    if (result.identity.sessionId != sessionId || result.identity.callSeq != callSeq) _malformed();
    return result;
  }

  /// Call only from an explicit user decision to abandon pursuit of ALL old
  /// unknowns in this session. This is not confirmation of tool success.
  /// Never call on load, reconnect, notification open or after a result read.
  ///
  /// Caller must retain/recheck Host and connection-generation authority. The
  /// v1 server has no bootId/callSeq compare-and-swap: this acknowledges current
  /// session unknowns, not a selected historical row. There is no auto retry.
  /// A lost response leaves the acknowledgement outcome unknown; re-read first.
  Future<LifecycleSnapshot> acknowledgeLifecycleUnknown(
    String sessionId, {
    required bool userConfirmed,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _session(sessionId);
    if (!userConfirmed) throw ArgumentError('Explicit user confirmation is required');
    final bytes = utf8.encode(jsonEncode({'operation': 'acknowledgeUnknown', 'sessionId': sessionId}));
    if (bytes.length > 8192) throw ArgumentError('Lifecycle control exceeds the server byte limit');
    final response = await _connection(this).postBytes(
      lifecyclePath,
      bytes,
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: 8 * 1024 * 1024,
      timeout: timeout,
    );
    return LifecycleSnapshot.fromJson(_response(response), sessionId: sessionId);
  }
}
