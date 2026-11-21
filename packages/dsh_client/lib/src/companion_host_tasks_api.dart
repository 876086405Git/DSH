/// Durable, explicit notes tasks on the originally selected Host. These
/// methods never run a Session prompt or retry a mutation automatically.
library;

import 'dart:convert';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/tasks';
typedef _Row = Map<String, Object?>;

class CompanionTasksCapability {
  const CompanionTasksCapability._(this._owner, this.hostStoreId, this.notes, this.artifactRead, this.reason);
  final DshClient _owner;
  final String? hostStoreId;
  final bool notes;
  final bool artifactRead;
  final String? reason;
}

extension CompanionHostTasksApi on DshClient {
  Future<CompanionTasksCapability?> readCompanionTasksCapability({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) {
      return null;
    }
    final response = await transport.connection.get(
      '$_path/capabilities',
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 4096,
    );
    final map = _decode(response);
    final error = map['error'];
    if (response.statusCode == 404 && (error == null || error is Map && error['code'] == 'companion/not-found')) {
      return null;
    }
    _success(response, map);
    final kinds = map['kinds'];
    if (map['v'] != 1 ||
        map['durableAcceptance'] is! bool ||
        map['artifactRead'] is! bool ||
        (map['hostStoreId'] != null && !_id(map['hostStoreId'])) ||
        kinds is! List ||
        kinds.any((kind) => kind != 'host.notes_to_todo') ||
        (kinds.isNotEmpty && (map['durableAcceptance'] != true || !_id(map['hostStoreId']))) ||
        map['afterExit'] is! List ||
        jsonEncode(map['afterExit']) != '["continue"]' ||
        map['pauseBehavior'] != 'waiting' ||
        (map['reason'] != null && map['reason'] is! String)) {
      _invalid();
    }
    return CompanionTasksCapability._(
      this,
      map['hostStoreId'] as String?,
      kinds.contains('host.notes_to_todo'),
      map['artifactRead']! as bool,
      map['reason'] as String?,
    );
  }

  /// path is from the actual Host directory picker. Only the Host can resolve
  /// and bind its directory identity; an entered path is not a folderRef.
  Future<Map<String, Object?>> bindCompanionNotesDirectory(
    CompanionTasksCapability host,
    String path, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!identical(host._owner, this) || !host.notes || host.hostStoreId == null) {
      throw const DshRemoteException('companion/task-unavailable', 'Notes tasks are unavailable');
    }
    final response = await _connection(this).postBytes(
      '$_path/folders',
      utf8.encode(jsonEncode({'v': 1, 'hostStoreId': host.hostStoreId, 'path': path})),
      contentType: 'application/json',
      followRedirects: false,
      timeout: timeout,
      maxResponseBytes: 16384,
    );
    final map = _decode(response);
    _success(response, map);
    if (map['v'] != 1 ||
        map['hostStoreId'] != host.hostStoreId ||
        !_id(map['folderRef']) ||
        map['displayPath'] is! String ||
        (map['displayPath']! as String).isEmpty) {
      _invalid();
    }
    return map;
  }

  /// request is the already persisted, immutable package returned by
  /// prepareHostTaskOperation. Its possible handoff must be committed first.
  Future<Map<String, Object?>> writeCompanionHostTask({
    required String taskId,
    required String operation,
    required Map<String, Object?> request,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!_id(taskId) || !_id(request['hostStoreId']) || !const ['create', 'amend', 'cancel'].contains(operation)) {
      throw const DshProtocolException('Invalid persisted task operation');
    }
    final suffix = operation == 'create' ? '' : '/${Uri.encodeComponent(taskId)}/$operation';
    final response = await _connection(this).postBytes(
      '$_path$suffix',
      utf8.encode(jsonEncode(request)),
      contentType: 'application/json',
      followRedirects: false,
      timeout: timeout,
      maxResponseBytes: 1024 * 1024,
    );
    final map = _decode(response);
    _success(response, map);
    _identity(map, request['hostStoreId']! as String, taskId);
    return map;
  }

  /// A same-store 404 is a missing observation, not proof that an old request
  /// was never sent. The coordinator alone decides whether the same ID can be
  /// replayed. A changed store is an error, never a new empty task list.
  Future<Map<String, Object?>?> readCompanionHostTask({
    required String hostStoreId,
    required String taskId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await _connection(this).get(
      '$_path/${Uri.encodeComponent(taskId)}',
      query: {'hostStoreId': hostStoreId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 1024 * 1024,
    );
    final map = _decode(response);
    if (response.statusCode == 404 &&
        map['error'] is Map &&
        (map['error']! as Map)['code'] == 'companion/task-not-found') {
      return null;
    }
    _success(response, map);
    _identity(map, hostStoreId, taskId);
    return map;
  }

  Future<Map<String, Object?>> readCompanionHostArtifact({
    required String hostStoreId,
    required String taskId,
    required String hostExecutionId,
    required String artifactId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await _connection(this).get(
      '$_path/${Uri.encodeComponent(taskId)}/artifacts/${Uri.encodeComponent(artifactId)}',
      query: {'hostStoreId': hostStoreId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 1024 * 1024,
    );
    final map = _decode(response);
    _success(response, map);
    _identity(map, hostStoreId, taskId);
    if (map['hostExecutionId'] != hostExecutionId ||
        map['artifactId'] != artifactId ||
        !const ['available', 'missing', 'changed', 'unknown'].contains(map['status']) ||
        !const ['text/markdown', 'text/plain'].contains(map['mediaType']) ||
        (map['status'] == 'available' ? map['content'] is! String : map['content'] != null) ||
        (map['reason'] != null && map['reason'] is! String)) {
      _invalid();
    }
    return map;
  }
}

DshConnection _connection(DshClient client) {
  final transport = client.carrier;
  if (transport is! DshHttpCarrier) {
    throw const DshRemoteException('companion/task-unavailable', 'This connection has no task route');
  }
  return transport.connection;
}

_Row _decode(DshHttpResponse response) {
  if (response.contentType != 'application/json') {
    if (response.statusCode != 200 && response.statusCode != 201) {
      return {};
    }
    _invalid();
  }
  try {
    final value = jsonDecode(utf8.decode(response.body));
    if (value is Map<String, Object?>) {
      return value;
    }
  } on FormatException {
    _invalid();
  }
  _invalid();
}

void _success(DshHttpResponse response, _Row map) {
  if (response.statusCode == 200 || response.statusCode == 201) {
    return;
  }
  final error = map['error'];
  if (error is Map && error['code'] is String && error['message'] is String) {
    throw DshRemoteException(error['code']! as String, error['message']! as String, {
      'status': response.statusCode,
      if (map['snapshot'] is Map) 'snapshot': map['snapshot'],
    });
  }
  throw DshHttpException(response.statusCode, 'Task request did not return a successful response');
}

void _identity(_Row map, String hostStoreId, String taskId) {
  if (map['v'] != 1 || map['hostStoreId'] != hostStoreId || map['taskId'] != taskId || !_id(map['hostExecutionId'])) {
    _invalid();
  }
}

bool _id(Object? value) => value is String && value.isNotEmpty && value.length <= 128 && !value.contains('\u0000');
Never _invalid() => throw const DshProtocolException('Invalid Host task response');
