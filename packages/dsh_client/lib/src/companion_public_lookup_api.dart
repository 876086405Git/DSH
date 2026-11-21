/// Explicit public lookup steps on the original full-room Host. No Session
/// prompt, tool loop, fallback, automatic retry or credential export.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/lookup';
typedef _Row = Map<String, Object?>;

class CompanionLookupCapability {
  const CompanionLookupCapability._(
    this._owner,
    this.sessionId,
    this.instanceId,
    this.provider,
    this.model,
    this.search,
    this.fetch,
    this.answer,
  );

  final DshClient _owner;
  final String sessionId;
  final String instanceId;
  final String provider;
  final String model;
  final bool search;
  final bool fetch;
  final bool answer;
}

/// Only a verified preflight failure establishes notSent. A stale instance,
/// duplicate ID, missing receipt or broken stream cannot release its attempt.
class CompanionLookupFailure implements Exception {
  const CompanionLookupFailure(this.code, {required this.notSent, this.httpStatus});
  final String code;
  final bool notSent;
  final int? httpStatus;
  @override
  String toString() => 'CompanionLookupFailure($code, notSent: $notSent)';
}

extension CompanionPublicLookupApi on DshClient {
  Future<CompanionLookupCapability?> readCompanionLookupCapability(
    String sessionId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) {
      return null;
    }
    final response = await transport.connection.get(
      _path,
      query: {'sessionId': sessionId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 4096,
    );
    final map = response.contentType == 'application/json' ? _json(response.body) : <String, Object?>{};
    final code = _map(map['error'])?['code'];
    if (response.statusCode == 404 && (code == null || code == 'companion/not-found')) {
      return null;
    }
    if (response.statusCode != 200) {
      throw _failure(map, response.statusCode);
    }
    final direct = _map(map['direct']);
    final answer = _map(map['answer']);
    if (map['v'] != 1 ||
        !_id(map['instanceId']) ||
        !_id(map['provider']) ||
        !_id(map['model']) ||
        direct == null ||
        direct['search'] is! bool ||
        direct['fetch'] is! bool ||
        ((direct['search'] == true || direct['fetch'] == true) &&
            (direct['physicalDispatch'] != 'fetch-invoked' || direct['maxPhysicalRequests'] != 1)) ||
        (map['answer'] != null && (answer == null || answer['noTools'] != true))) {
      _invalid();
    }
    return CompanionLookupCapability._(
      this,
      sessionId,
      map['instanceId']! as String,
      map['provider']! as String,
      map['model']! as String,
      direct['search']! as bool,
      direct['fetch']! as bool,
      answer != null,
    );
  }

  /// The caller commits its claim before this call. onHandoff is the last
  /// synchronous current-revision/deadline check before the HTTP socket opens.
  /// Each valid event keeps its actual request/task identity for persistence.
  Future<Map<String, Object?>> callCompanionLookup(
    CompanionLookupCapability host, {
    required String requestId,
    required String taskId,
    required int taskRev,
    required int deadlineAtMs,
    required String kind,
    required Map<String, Object?> task,
    required Map<String, Object?> payload,
    required DshHttpAbort abort,
    required void Function() onHandoff,
    required void Function(Map<String, Object?>) onEvent,
    Duration headerTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 100),
  }) async {
    final transport = carrier;
    final supported = switch (kind) {
      'search' => host.search,
      'fetch' => host.fetch,
      'answer' => host.answer,
      _ => false,
    };
    if (!identical(host._owner, this) || transport is! DshHttpCarrier || !supported || abort.isAborted) {
      throw const CompanionLookupFailure('route-unavailable', notSent: true);
    }
    if (!_id(requestId) || !_id(taskId) || taskRev <= 0 || !_count(deadlineAtMs)) {
      throw const CompanionLookupFailure('invalid-request', notSent: true);
    }
    final body = <String, Object?>{
      'v': 1,
      'instanceId': host.instanceId,
      'requestId': requestId,
      'sessionId': host.sessionId,
      'taskId': taskId,
      'taskRev': taskRev,
      'deadlineAtMs': deadlineAtMs,
      'provider': host.provider,
      'model': host.model,
      'kind': kind,
      'task': task,
      'payload': payload,
    };
    if (utf8.encode(jsonEncode(body)).length > 65536) {
      throw const CompanionLookupFailure('request-limit', notSent: true);
    }
    onHandoff();
    DshHttpStreamResponse? response;
    var accepted = false;
    int? dispatchAt;
    int? httpStatus;
    try {
      response = await transport.connection.postJsonStream(
        _path,
        body,
        abort: abort,
        headerTimeout: headerTimeout,
        idleTimeout: idleTimeout,
      );
      if (response.statusCode != 200) {
        final bytes = await _bytes(response.body, 256 * 1024);
        throw _failure(response.contentType == 'application/json' ? _json(bytes) : {}, response.statusCode);
      }
      if (response.contentType != 'application/x-ndjson') {
        _invalid();
      }
      await for (final line in _lines(response.body)) {
        final frame = _map(jsonDecode(line));
        if (frame == null ||
            frame['requestId'] != requestId ||
            frame['taskId'] != taskId ||
            frame['taskRev'] != taskRev) {
          _invalid();
        }
        final type = frame['type'];
        if (type == 'accepted') {
          if (accepted ||
              frame['instanceId'] != host.instanceId ||
              frame['provider'] != host.provider ||
              frame['model'] != host.model) {
            _invalid();
          }
          accepted = true;
        } else {
          if (!accepted) {
            _invalid();
          }
          switch (type) {
            case 'dispatch':
              if (dispatchAt != null || frame['boundary'] != 'fetch-invoked' || !_count(frame['atMs'])) {
                _invalid();
              }
              dispatchAt = frame['atMs']! as int;
            case 'http':
              if (!_status(frame['status']) || !_count(frame['atMs'])) {
                _invalid();
              }
              httpStatus = frame['status']! as int;
            case 'provider-result':
              if (kind == 'answer' || !frame.containsKey('raw')) {
                _invalid();
              }
            case 'text':
              if (kind != 'answer' || frame['text'] is! String) {
                _invalid();
              }
            case 'usage':
              if (kind != 'answer' ||
                  frame['semantics'] != 'cumulative' ||
                  _map(frame['raw']) == null ||
                  !const {'message_start', 'message_delta'}.contains(frame['event'])) {
                _invalid();
              }
            case 'runtime-usage':
              if (kind != 'answer' || frame['semantics'] != 'runtime-normalized' || _map(frame['usage']) == null) {
                _invalid();
              }
            case 'finish':
              _finish(frame, dispatchAt: dispatchAt, httpStatus: httpStatus);
              final usage = _map(frame['usage']);
              if (kind == 'answer'
                  ? usage == null || usage['provider'] != host.provider || usage['model'] != host.model
                  : frame['usage'] != null) {
                _invalid();
              }
              onEvent(frame);
              return frame;
          }
        }
        onEvent(frame);
      }
      throw const CompanionLookupFailure('missing-finish', notSent: false);
    } on CompanionLookupFailure {
      rethrow;
    } on DshException {
      throw CompanionLookupFailure(abort.isAborted ? 'cancelled' : 'transport-error', notSent: false);
    } on FormatException {
      throw const CompanionLookupFailure('invalid-response', notSent: false);
    } finally {
      await response?.cancel();
    }
  }

  /// Read the original instance only. Returned metadata explicitly has no
  /// Fetch body; it cannot be treated as a source or a licence to fetch again.
  Future<Map<String, Object?>?> readCompanionLookupRequest({
    required String instanceId,
    required String requestId,
    required String taskId,
    required int taskRev,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) {
      return null;
    }
    final response = await transport.connection.get(
      '$_path/requests/${Uri.encodeComponent(requestId)}',
      query: {'instanceId': instanceId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 256 * 1024,
    );
    final map = response.contentType == 'application/json' ? _json(response.body) : <String, Object?>{};
    if (response.statusCode != 200) {
      throw _failure(map, response.statusCode);
    }
    if (map['v'] != 1 ||
        map['instanceId'] != instanceId ||
        map['requestId'] != requestId ||
        map['taskId'] != taskId ||
        map['taskRev'] != taskRev ||
        map['bodyRetained'] != false ||
        !const {'accepted', 'finished'}.contains(map['phase'])) {
      _invalid();
    }
    final finish = _map(map['finish']);
    if (map['phase'] == 'finished') {
      if (finish == null ||
          finish['requestId'] != requestId ||
          finish['taskId'] != taskId ||
          finish['taskRev'] != taskRev) {
        _invalid();
      }
      _finish(finish);
    }
    return map;
  }

  Future<void> fenceCompanionLookup({
    required String instanceId,
    required String sessionId,
    required String taskId,
    required int taskRev,
    required bool cancelled,
    required int deadlineAtMs,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) {
      throw const CompanionLookupFailure('route-unavailable', notSent: true);
    }
    final response = await transport.connection.postBytes(
      '$_path/fence',
      utf8.encode(
        jsonEncode({
          'v': 1,
          'instanceId': instanceId,
          'sessionId': sessionId,
          'taskId': taskId,
          'taskRev': taskRev,
          'cancelled': cancelled,
          'deadlineAtMs': deadlineAtMs,
        }),
      ),
      contentType: 'application/json',
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 4096,
    );
    final map = response.contentType == 'application/json' ? _json(response.body) : <String, Object?>{};
    if (response.statusCode != 200) {
      throw _failure(map, response.statusCode);
    }
    if (map['v'] != 1 ||
        map['instanceId'] != instanceId ||
        map['taskId'] != taskId ||
        map['taskRev'] != taskRev ||
        map['cancelled'] != cancelled ||
        map['received'] != true) {
      _invalid();
    }
  }
}

void _finish(_Row frame, {int? dispatchAt, int? httpStatus}) {
  final dispatched = frame['dispatched'];
  final at = frame['dispatchAtMs'];
  final status = frame['httpStatus'];
  if (!frame.containsKey('dispatched') ||
      (dispatched != null && dispatched is! bool) ||
      !frame.containsKey('dispatchAtMs') ||
      (at != null && !_count(at)) ||
      (dispatched == true) != (at != null) ||
      (dispatchAt != null && (dispatched != true || at != dispatchAt)) ||
      !frame.containsKey('httpStatus') ||
      (status != null && !_status(status)) ||
      (httpStatus != null && status != httpStatus) ||
      frame['complete'] is! bool ||
      frame['terminal'] is! String ||
      (frame['terminal'] as String).isEmpty ||
      frame['bodyRetained'] != false) {
    _invalid();
  }
}

CompanionLookupFailure _failure(_Row map, int status) {
  final code = _map(map['error'])?['code'];
  final uncertain = const {
    'companion/lookup-instance-changed',
    'companion/lookup-request-used',
    'companion/lookup-request-conflict',
    'companion/lookup-request-unknown',
  }.contains(code);
  return CompanionLookupFailure(
    code is String ? code : 'http-error',
    httpStatus: status,
    notSent:
        status >= 400 &&
        code is String &&
        code.startsWith('companion/lookup-') &&
        map['dispatched'] == false &&
        !uncertain,
  );
}

_Row _json(List<int> bytes) {
  final map = _map(jsonDecode(utf8.decode(bytes)));
  if (map == null) {
    _invalid();
  }
  return map;
}

_Row? _map(Object? value) => value is _Row ? value : null;
bool _count(Object? value) => value is int && value >= 0 && value <= 9007199254740991;
bool _status(Object? value) => value is int && value >= 100 && value <= 599;
bool _id(Object? value) =>
    value is String && value.isNotEmpty && value.runes.length <= 128 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
Never _invalid() => throw const CompanionLookupFailure('invalid-response', notSent: false);

Future<Uint8List> _bytes(Stream<Uint8List> body, int limit) async {
  final result = BytesBuilder(copy: false);
  await for (final chunk in body) {
    if (result.length + chunk.length > limit) {
      _invalid();
    }
    result.add(chunk);
  }
  return result.takeBytes();
}

// A Fetch body may exceed the answer window. Read it whole within this
// explicit transport bound, then let the owner return partial, never a cut page.
Stream<String> _lines(Stream<Uint8List> body) async* {
  final pending = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in body) {
    total += chunk.length;
    if (total > 16 * 1024 * 1024) {
      _invalid();
    }
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) {
        continue;
      }
      if (pending.length + i - start > 8 * 1024 * 1024) {
        _invalid();
      }
      pending.add(chunk.sublist(start, i));
      final line = utf8.decode(pending.takeBytes());
      if (line.trim().isNotEmpty) {
        yield line;
      }
      start = i + 1;
    }
    if (pending.length + chunk.length - start > 8 * 1024 * 1024) {
      _invalid();
    }
    pending.add(chunk.sublist(start));
  }
  if (pending.isNotEmpty) {
    _invalid();
  }
}
