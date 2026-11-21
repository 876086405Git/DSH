/// Read-only observations for phone-owned ordinary full-mode chat.
/// This never sends a model request, follows a redirect or recovers a prompt.
library;

import 'dart:convert';

import 'carrier.dart';
import 'errors.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/usage';
const _maxSafe = 9007199254740991;
const _components = ['input_uncached', 'input_cache_read', 'input_cache_write', 'output_tokens'];
const _rawComponents = ['input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens', 'output_tokens'];
const _terminals = {
  'incomplete',
  'complete',
  'max_tokens',
  'tool_calls',
  'refusal',
  'empty_response',
  'cancelled',
  'http_error',
  'network_error',
  'provider_error',
  'preflight_error',
};

/// The immutable phone binding captured when the original prompt was prepared.
class CompanionChatUsageBinding {
  const CompanionChatUsageBinding._(this._json);
  final Map<String, Object?> _json;
  String get archiveId => _json['archiveId'] as String;
  int get controlRevision => _json['controlRevision'] as int;
  int get historyAfterSeq => _json['historyAfterSeq'] as int;
  Map<String, Object?> toJson() => _json;
}

/// One physical fetch observation, proven preflight, or generic adapter handoff.
/// A root prompt may have several receipts. Several same-turn roots may share
/// this exact receipt, so persist by hostKey + instanceId + receiptId.
class CompanionChatUsageReceipt {
  const CompanionChatUsageReceipt._(this._json);
  final Map<String, Object?> _json;
  String get receiptId => _json['receiptId'] as String;
  String get callId => _json['callId'] as String;
  int get revision => _json['revision'] as int;
  List<String> get requestIds => (_json['requestIds'] as List).cast<String>();
  String get provider => _json['provider'] as String;
  String get model => _json['model'] as String;
  String get phase => _json['phase'] as String;
  String get observation => _json['observation'] as String;

  /// A fetch invocation is not proof of provider receipt or billing. Null is
  /// unknown; only a preflight receipt can prove false for this adapter call.
  bool? get dispatched => _json['dispatched'] as bool?;
  int? get dispatchAtMs => _json['dispatchAtMs'] as int?;
  int? get handoffAtMs => _json['handoffAtMs'] as int?;
  int? get physicalRequests => _json['physicalRequests'] as int?;
  String get terminal => _json['terminal'] as String;
  bool get complete => _json['complete'] as bool;
  int? get httpStatus => _json['httpStatus'] as int?;
  String? get errorCode => _json['errorCode'] as String?;

  /// Original Host snapshot, with nullable raw components and any separately
  /// named runtime-normalized events. Do not sum cumulative snapshots/events.
  Map<String, Object?> get usage => _json['usage'] as Map<String, Object?>;
  Map<String, Object?> toJson() => _json;
}

class CompanionChatUsageSnapshot {
  const CompanionChatUsageSnapshot._(this._json, this.binding, this.receipts);

  factory CompanionChatUsageSnapshot.fromJson(Object? json) {
    final map = _map(json);
    if (map == null ||
        map['v'] != 1 ||
        !_id(map['instanceId']) ||
        !_id(map['sessionId']) ||
        !_id(map['requestId']) ||
        !const {'pending', 'running', 'settled', 'unknown'}.contains(map['state']) ||
        map['complete'] is! bool ||
        !_count(map['revision']) ||
        !_count(map['observedAdapterCalls']) ||
        !_count(map['activeCalls']) ||
        !map.containsKey('physicalRequests') ||
        !_nullableCount(map['physicalRequests']) ||
        !_strings(map['gaps']) ||
        map['receipts'] is! List ||
        !map.containsKey('binding')) {
      throw const DshProtocolException('invalid companion chat usage snapshot');
    }
    final state = map['state'], binding = _map(map['binding']);
    final calls = map['observedAdapterCalls'] as int, active = map['activeCalls'] as int;
    final rawReceipts = map['receipts'] as List, gaps = map['gaps'] as List;
    if (active > calls || rawReceipts.length > 1024 || gaps.toSet().length != gaps.length) {
      throw const DshProtocolException('invalid companion chat usage coverage');
    }
    if (state == 'unknown') {
      // Revision zero is a coverage observation, not a new receipt version.
      // Persist this gap even when old receipts have higher revisions; retain
      // those receipts and the original delivery's instanceId unchanged.
      if (map['binding'] != null ||
          map['complete'] != false ||
          map['revision'] != 0 ||
          calls != 0 ||
          active != 0 ||
          map['physicalRequests'] != null ||
          rawReceipts.isNotEmpty ||
          gaps.isEmpty) {
        throw const DshProtocolException('invalid unknown companion chat usage');
      }
    } else if (binding == null ||
        !_id(binding['archiveId']) ||
        !_count(binding['controlRevision']) ||
        !_count(binding['historyAfterSeq']) ||
        map['revision'] == 0) {
      throw const DshProtocolException('invalid companion chat usage binding');
    }
    final receiptIds = <String>{}, callIds = <String>{};
    var physical = 0;
    var physicalKnown = gaps.isEmpty;
    for (final value in rawReceipts) {
      final receipt = _validateReceipt(value, map['requestId'] as String);
      if (!receiptIds.add(receipt['receiptId'] as String) ||
          (receipt['revision'] as int) > (map['revision'] as int) ||
          (state == 'settled' && receipt['phase'] != 'finished')) {
        throw const DshProtocolException('invalid companion chat usage receipt identity');
      }
      callIds.add(receipt['callId'] as String);
      final count = receipt['physicalRequests'] as int?;
      if (count == null) {
        physicalKnown = false;
      } else {
        physical += count;
      }
    }
    if (state != 'unknown' &&
        (callIds.length > calls ||
            (map['physicalRequests'] != null && (!physicalKnown || map['physicalRequests'] != physical)) ||
            (state == 'settled' && active != 0) ||
            (state == 'pending' && (calls != 0 || active != 0 || rawReceipts.isNotEmpty)) ||
            (map['complete'] == true &&
                (state != 'settled' ||
                    calls == 0 ||
                    gaps.isNotEmpty ||
                    map['physicalRequests'] == null ||
                    rawReceipts.isEmpty)))) {
      throw const DshProtocolException('invalid companion chat usage completion');
    }
    final frozen = _freeze(map) as Map<String, Object?>;
    return CompanionChatUsageSnapshot._(
      frozen,
      binding == null ? null : CompanionChatUsageBinding._(frozen['binding'] as Map<String, Object?>),
      List<CompanionChatUsageReceipt>.unmodifiable(
        (frozen['receipts'] as List).map((value) => CompanionChatUsageReceipt._(value as Map<String, Object?>)),
      ),
    );
  }

  final Map<String, Object?> _json;
  final CompanionChatUsageBinding? binding;
  final List<CompanionChatUsageReceipt> receipts;
  String get instanceId => _json['instanceId'] as String;
  String get sessionId => _json['sessionId'] as String;
  String get requestId => _json['requestId'] as String;
  String get state => _json['state'] as String;

  /// Only closes coverage of the captured phone-owned main-loop chat calls.
  /// It says nothing about unmarked background/compaction calls, other Agents,
  /// answer success, price completeness, or all provider token components.
  bool get complete => _json['complete'] as bool;
  int get revision => _json['revision'] as int;
  List<String> get gaps => (_json['gaps'] as List).cast<String>();
  int get observedAdapterCalls => _json['observedAdapterCalls'] as int;
  int get activeCalls => _json['activeCalls'] as int;
  int? get physicalRequests => _json['physicalRequests'] as int?;
  Map<String, Object?> toJson() => _json;
}

extension CompanionChatUsageApi on DshClient {
  /// Read the exact previously persisted delivery identity. Never replace its
  /// instance ID with a freshly discovered capability to recover a missing
  /// receipt. A different Host instance is accepted only as an empty explicit
  /// unknown/instance-changed response; it is never evidence of zero cost.
  ///
  /// Null denotes a carrier without HTTP or an older unclaimed 404 route.
  /// Both null and read failures leave existing accounting evidence intact.
  Future<CompanionChatUsageSnapshot?> readCompanionChatUsage({
    required String instanceId,
    required String sessionId,
    required String requestId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_id(instanceId) || !_id(sessionId) || !_id(requestId) || timeout <= Duration.zero) {
      throw ArgumentError('invalid companion chat usage identity');
    }
    final transport = carrier;
    if (transport is! DshHttpCarrier) return null;
    final response = await transport.connection.get(
      _path,
      query: {'instanceId': instanceId, 'sessionId': sessionId, 'requestId': requestId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 8 * 1024 * 1024,
    );
    Map<String, Object?>? map;
    if (response.contentType == 'application/json') {
      try {
        map = _map(jsonDecode(utf8.decode(response.body)));
      } on FormatException {
        throw const DshProtocolException('invalid companion chat usage JSON');
      }
    }
    final code = _map(map?['error'])?['code'];
    if (response.statusCode == 404 && (code == null || code == 'companion/not-found')) return null;
    if (response.statusCode != 200) {
      if (code is String && code.startsWith('companion/usage-')) {
        throw DshRemoteException(code, 'Companion chat usage read failed', {'httpStatus': response.statusCode});
      }
      throw DshHttpException(response.statusCode, 'Companion chat usage read failed');
    }
    final snapshot = CompanionChatUsageSnapshot.fromJson(map);
    if (snapshot.sessionId != sessionId ||
        snapshot.requestId != requestId ||
        (snapshot.instanceId != instanceId &&
            (snapshot.state != 'unknown' || !snapshot.gaps.contains('instance-changed')))) {
      throw const DshProtocolException('companion chat usage identity changed');
    }
    return snapshot;
  }
}

Map<String, Object?> _validateReceipt(Object? value, String requestId) {
  final map = _map(value);
  if (map == null ||
      !_id(map['receiptId']) ||
      !_id(map['callId']) ||
      !_routeName(map['provider']) ||
      !_routeName(map['model']) ||
      !_count(map['revision']) ||
      map['revision'] == 0 ||
      !_strings(map['requestIds']) ||
      !const {'active', 'finished'}.contains(map['phase']) ||
      !_terminals.contains(map['terminal']) ||
      map['complete'] is! bool ||
      !map.containsKey('dispatched') ||
      (map['dispatched'] != null && map['dispatched'] is! bool) ||
      !map.containsKey('dispatchAtMs') ||
      !_nullableCount(map['dispatchAtMs']) ||
      !map.containsKey('handoffAtMs') ||
      !_nullableCount(map['handoffAtMs']) ||
      !map.containsKey('physicalRequests') ||
      !_nullableCount(map['physicalRequests']) ||
      !map.containsKey('httpStatus') ||
      !_status(map['httpStatus']) ||
      !map.containsKey('errorCode') ||
      (map['errorCode'] != null && !_label(map['errorCode']))) {
    throw const DshProtocolException('invalid companion chat usage receipt');
  }
  final ids = map['requestIds'] as List;
  if (ids.isEmpty ||
      ids.length > 128 ||
      ids.toSet().length != ids.length ||
      !ids.contains(requestId) ||
      ids.any((id) => !_id(id))) {
    throw const DshProtocolException('invalid companion chat usage request ownership');
  }
  final observation = map['observation'];
  if (observation == 'fetch-invoked') {
    if (map['dispatched'] != true || map['physicalRequests'] != 1) {
      throw const DshProtocolException('invalid companion physical fetch evidence');
    }
  } else if (observation == 'preflight') {
    if (map['dispatched'] != false ||
        map['physicalRequests'] != 0 ||
        map['dispatchAtMs'] != null ||
        map['complete'] != false) {
      throw const DshProtocolException('invalid companion preflight evidence');
    }
  } else if (observation == 'adapter-invoked') {
    if (map['dispatched'] != null || map['physicalRequests'] != null || map['dispatchAtMs'] != null) {
      throw const DshProtocolException('generic adapter cannot prove physical dispatch');
    }
  } else {
    throw const DshProtocolException('unknown companion usage observation');
  }
  final usage = _map(map['usage']);
  if (usage == null ||
      usage['provider'] != map['provider'] ||
      usage['model'] != map['model'] ||
      usage['terminal'] != map['terminal'] ||
      usage['complete'] != map['complete'] ||
      !usage.containsKey('http_status') ||
      usage['http_status'] != map['httpStatus'] ||
      !usage.containsKey('stop_reason') ||
      (usage['stop_reason'] != null && usage['stop_reason'] is! String) ||
      !usage.containsKey('start_usage') ||
      !usage.containsKey('final_usage') ||
      (usage['start_usage'] != null && _map(usage['start_usage']) == null) ||
      (usage['final_usage'] != null && _map(usage['final_usage']) == null) ||
      !usage.containsKey('start_event') ||
      !usage.containsKey('final_event') ||
      usage['start_event'] != (usage['start_usage'] == null ? null : 'message_start') ||
      usage['final_event'] != (usage['final_usage'] == null ? null : 'message_delta') ||
      _components.any((key) => !usage.containsKey(key) || !_nullableCount(usage[key]))) {
    throw const DshProtocolException('invalid companion usage metadata');
  }
  if (observation == 'adapter-invoked') {
    if (usage['usage_semantics'] != 'unknown' ||
        usage['start_usage'] != null ||
        usage['final_usage'] != null ||
        _components.any((key) => usage[key] != null) ||
        usage['runtime_normalized_usage'] is! List ||
        (usage['runtime_normalized_usage'] as List).any((value) => _map(value) == null) ||
        usage['runtime_normalized_usage_semantics'] != 'runtime-normalized-events') {
      throw const DshProtocolException('invalid generic companion usage evidence');
    }
  } else {
    if (usage['usage_semantics'] != 'cumulative') {
      throw const DshProtocolException('invalid companion raw usage semantics');
    }
    final raw = _map(usage['final_usage']);
    for (var index = 0; index < _components.length; index++) {
      final value = raw?[_rawComponents[index]];
      if (usage[_components[index]] != (_count(value) ? value : null)) {
        throw const DshProtocolException('companion usage component differs from final raw object');
      }
    }
  }
  return map;
}

Map<String, Object?>? _map(Object? value) =>
    value is Map && value.keys.every((key) => key is String) ? Map<String, Object?>.from(value) : null;
bool _count(Object? value) => value is int && value >= 0 && value <= _maxSafe;
bool _nullableCount(Object? value) => value == null || _count(value);
bool _status(Object? value) => value == null || value is int && value >= 100 && value <= 599;
bool _label(Object? value) =>
    value is String && value.isNotEmpty && value.runes.length <= 128 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool _strings(Object? value) => value is List && value.every(_label);
bool _id(Object? value) => _label(value) && _unicode(value as String);
bool _routeName(Object? value) => value is String && value.isNotEmpty && _unicode(value);
bool _unicode(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) return false;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(value.map((key, value) => MapEntry(key as String, _freeze(value))));
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
