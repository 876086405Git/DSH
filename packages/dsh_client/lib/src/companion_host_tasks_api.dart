/// Durable, explicit tasks on the originally selected Host. These
/// methods never run a Session prompt or retry a mutation automatically.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'session_api.dart';

const _path = '/dsh-go/v1/companion/tasks';
const _workbookMediaType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
typedef _Row = Map<String, Object?>;

class CompanionTasksCapability {
  const CompanionTasksCapability._(
    this._owner,
    this.hostStoreId,
    this.notes,
    this.findDraft,
    this.compareDrafts,
    this.receiptsToSheet,
    this.receiptInputs,
    this.artifactRead,
    this.sourceRead,
    this.notesForeground,
    this.reason,
  );
  final DshClient _owner;
  final String? hostStoreId;
  final bool notes;
  final bool findDraft;
  final bool compareDrafts;
  final bool receiptsToSheet;
  final Map<String, Object?>? receiptInputs;
  final bool artifactRead;
  final bool sourceRead;
  final bool notesForeground;
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
        kinds.any(
          (kind) => !const [
            'host.notes_to_todo',
            'host.find_draft',
            'host.compare_drafts',
            'host.receipts_to_sheet',
          ].contains(kind),
        ) ||
        (kinds.isNotEmpty && (map['durableAcceptance'] != true || !_id(map['hostStoreId']))) ||
        (map.containsKey('sourceRead') && map['sourceRead'] is! bool) ||
        (map.containsKey('notesForeground') && map['notesForeground'] is! bool) ||
        (kinds.contains('host.find_draft') && map['sourceRead'] != true) ||
        map['afterExit'] is! List ||
        jsonEncode(map['afterExit']) != '["continue"]' ||
        map['pauseBehavior'] != 'waiting' ||
        (map['reason'] != null && map['reason'] is! String)) {
      _invalid();
    }
    final receiptInputs = map['receiptInputs'];
    final Map<String, Object?>? receiptLimits;
    if (receiptInputs == null) {
      receiptLimits = null;
    } else {
      if (receiptInputs is! _Row ||
          receiptInputs.length != 5 ||
          receiptInputs['formats'] is! List<Object?> ||
          (receiptInputs['formats']! as List<Object?>).isEmpty ||
          (receiptInputs['formats']! as List<Object?>).toSet().length !=
              (receiptInputs['formats']! as List<Object?>).length ||
          (receiptInputs['formats']! as List<Object?>).any((format) => !const ['md', 'txt', 'pdf'].contains(format)) ||
          receiptInputs['maxFiles'] != 4 ||
          receiptInputs['maxBytes'] != 4194304 ||
          receiptInputs['maxPdfPages'] != 5 ||
          receiptInputs['workbookBytes'] != 262144) {
        _invalid();
      }
      receiptLimits = Map<String, Object?>.unmodifiable({
        ...receiptInputs,
        'formats': List<Object?>.unmodifiable(receiptInputs['formats']! as List<Object?>),
      });
    }
    if (kinds.contains('host.receipts_to_sheet') && (receiptLimits == null || map['artifactRead'] != true)) {
      _invalid();
    }
    return CompanionTasksCapability._(
      this,
      map['hostStoreId'] as String?,
      kinds.contains('host.notes_to_todo'),
      kinds.contains('host.find_draft'),
      kinds.contains('host.compare_drafts'),
      kinds.contains('host.receipts_to_sheet'),
      receiptLimits,
      map['artifactRead']! as bool,
      map['sourceRead'] == true,
      kinds.contains('host.notes_to_todo') && map['notesForeground'] == true,
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
    if (!identical(host._owner, this) ||
        (!host.notes && !host.findDraft && !host.compareDrafts && !host.receiptsToSheet) ||
        host.hostStoreId == null) {
      throw const DshRemoteException('companion/task-unavailable', 'Directory tasks are unavailable');
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

  /// Bind one explicitly selected name inside an actual bound directory.
  /// The reply is metadata for that original object, never a whole-file read.
  Future<Map<String, Object?>> bindCompanionDraftInput(
    CompanionTasksCapability host, {
    required String folderRef,
    required String name,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!identical(host._owner, this) || !host.compareDrafts || host.hostStoreId == null) {
      throw const DshRemoteException('companion/task-unavailable', 'Draft comparison is unavailable');
    }
    if (!_id(folderRef) ||
        name.isEmpty ||
        name.length > 255 ||
        RegExp(r'[/\\\x00]').hasMatch(name) ||
        !RegExp(r'\.(md|txt)$', caseSensitive: false).hasMatch(name)) {
      throw const DshProtocolException('Choose one supported file name inside the selected directory');
    }
    final response = await _connection(this).postBytes(
      '$_path/inputs',
      utf8.encode(jsonEncode({'v': 1, 'hostStoreId': host.hostStoreId, 'folderRef': folderRef, 'name': name})),
      contentType: 'application/json',
      followRedirects: false,
      timeout: timeout,
      maxResponseBytes: 16384,
    );
    final map = _decode(response);
    _success(response, map);
    if (map.length != 7 ||
        map['v'] != 1 ||
        map['hostStoreId'] != host.hostStoreId ||
        !_id(map['sourceRef']) ||
        map['displayName'] != name ||
        map['version'] is! String ||
        (map['version']! as String).isEmpty ||
        map['size'] is! int ||
        (map['size']! as int) < 0 ||
        (map['size']! as int) > 65536 ||
        !const ['text/plain', 'text/markdown'].contains(map['mediaType'])) {
      _invalid();
    }
    return map;
  }

  /// Bind exactly one original receipt. This never downloads its contents or
  /// broadens the older draft-input route's text-only, 64 KiB contract.
  Future<Map<String, Object?>> bindCompanionReceiptInput(
    CompanionTasksCapability host, {
    required String folderRef,
    required String name,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!identical(host._owner, this) || !host.receiptsToSheet || host.hostStoreId == null) {
      throw const DshRemoteException('companion/task-unavailable', 'Receipt tasks are unavailable');
    }
    final extension = RegExp(r'\.([^.]+)$').firstMatch(name)?.group(1)?.toLowerCase();
    if (!_id(folderRef) ||
        name.isEmpty ||
        name.length > 255 ||
        RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name) ||
        !(host.receiptInputs!['formats']! as List<Object?>).contains(extension)) {
      throw const DshProtocolException('Choose one supported receipt file inside the selected directory');
    }
    final response = await _connection(this).postBytes(
      '$_path/inputs',
      utf8.encode(
        jsonEncode({
          'v': 1,
          'hostStoreId': host.hostStoreId,
          'folderRef': folderRef,
          'name': name,
          'kind': 'host.receipts_to_sheet',
        }),
      ),
      contentType: 'application/json',
      followRedirects: false,
      timeout: timeout,
      maxResponseBytes: 16384,
    );
    final map = _decode(response);
    _success(response, map);
    final mediaType = switch (extension) {
      'md' => 'text/markdown',
      'txt' => 'text/plain',
      'pdf' => 'application/pdf',
      _ => null,
    };
    if (map.length != 7 ||
        map['v'] != 1 ||
        map['hostStoreId'] != host.hostStoreId ||
        !_id(map['sourceRef']) ||
        map['displayName'] != name ||
        map['version'] is! String ||
        (map['version']! as String).isEmpty ||
        map['size'] is! int ||
        (map['size']! as int) < 0 ||
        (map['size']! as int) > 4194304 ||
        map['mediaType'] != mediaType) {
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

  /// One explicitly requested foreground opportunity for an existing F task.
  /// Persist prepareHostTaskForeground before calling. Every line is a complete
  /// original snapshot, not a grant or a fabricated execution receipt.
  Future<void> runCompanionNotesForeground(
    CompanionTasksCapability host, {
    required String taskId,
    required Map<String, Object?> request,
    required DshHttpAbort abort,
    required void Function(Map<String, Object?> snapshot) onSnapshot,
    void Function(Object error, StackTrace stack)? onAbnormal,
  }) async {
    final session = request['sourceSessionId'];
    if (!identical(host._owner, this) || !host.notesForeground || host.hostStoreId != request['hostStoreId']) {
      throw const DshRemoteException('companion/task-unavailable', 'Foreground notes tasks are unavailable');
    }
    if (!_id(taskId) ||
        request.length != 5 ||
        request['v'] != 1 ||
        !_id(request['hostStoreId']) ||
        !_id(request['hostExecutionId']) ||
        request['taskRev'] is! int ||
        (request['taskRev']! as int) < 1 ||
        session is! String ||
        session.isEmpty ||
        session.length > 256 ||
        session.contains('\u0000')) {
      throw const DshProtocolException('Invalid persisted foreground task');
    }
    final response = await _connection(this).postJsonStream(
      '$_path/${Uri.encodeComponent(taskId)}/foreground',
      request,
      abort: abort,
      headerTimeout: const Duration(seconds: 15),
      idleTimeout: null,
    );
    var reportedAbnormal = false;
    void abnormal(Object error, StackTrace stack) {
      if (!reportedAbnormal) {
        reportedAbnormal = true;
        onAbnormal?.call(error, stack);
      }
    }

    try {
      if (response.statusCode != 200) {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.body) {
          try {
            if (bytes.length + chunk.length > 16384) {
              _invalid();
            }
            bytes.add(chunk);
          } on Object catch (error, stack) {
            abnormal(error, stack);
            rethrow;
          }
        }
        final error = DshHttpResponse(response.statusCode, response.contentType, bytes.takeBytes());
        _success(error, _decode(error));
      }
      if (response.contentType != 'application/x-ndjson') {
        _invalid();
      }
      final line = BytesBuilder(copy: false);
      var received = false;
      void emit() {
        if (line.isEmpty) {
          return;
        }
        final Object? value;
        try {
          value = jsonDecode(utf8.decode(line.takeBytes()));
        } on FormatException {
          _invalid();
        }
        if (value is! Map<String, Object?>) {
          _invalid();
        }
        _identity(value, host.hostStoreId!, taskId);
        if (value['hostExecutionId'] != request['hostExecutionId'] ||
            value['kind'] != 'host.notes_to_todo' ||
            value['taskRev'] is! int ||
            (value['taskRev']! as int) < (request['taskRev']! as int)) {
          _invalid();
        }
        onSnapshot(value);
        received = true;
      }

      await for (final chunk in response.body) {
        try {
          var start = 0;
          for (var index = 0; index <= chunk.length; index++) {
            if (index != chunk.length && chunk[index] != 10) {
              continue;
            }
            if (line.length + index - start > 1024 * 1024) {
              _invalid();
            }
            line.add(Uint8List.sublistView(chunk, start, index));
            if (index != chunk.length) {
              emit();
            }
            start = index + 1;
          }
        } on Object catch (error, stack) {
          // await-for cancels its subscription before an exception leaves
          // the loop. Record uncertainty before that cancellation can wait.
          abnormal(error, stack);
          rethrow;
        }
      }
      emit();
      if (!received && !abort.isAborted) {
        _invalid();
      }
    } on Object catch (error, stack) {
      // Notify the owner before cancellation can await reader retirement.
      // A later GET must not be overwritten by a delayed outer catch.
      abnormal(error, stack);
      rethrow;
    } finally {
      await response.cancel();
    }
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

  /// Fetch only an already imported workbook artifact on its original task.
  /// The existing connection owns authentication, proxy/TLS and the byte cap.
  Future<Uint8List> readCompanionHostArtifactBytes({
    required String hostStoreId,
    required String taskId,
    required String hostExecutionId,
    required Map<String, Object?> artifact,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final size = artifact['size'];
    final hash = artifact['sha256'];
    if (!_id(hostStoreId) ||
        !_id(taskId) ||
        !_id(hostExecutionId) ||
        !_id(artifact['artifactId']) ||
        artifact['mediaType'] != _workbookMediaType ||
        size is! int ||
        size < 0 ||
        size > 262144 ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const DshProtocolException('Invalid original workbook artifact');
    }
    final response = await _connection(this).get(
      '$_path/${Uri.encodeComponent(taskId)}/artifacts/${Uri.encodeComponent(artifact['artifactId']! as String)}/content',
      query: {'hostStoreId': hostStoreId, 'hostExecutionId': hostExecutionId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 262144,
    );
    if (response.statusCode != 200) {
      _success(response, _decode(response));
      _invalid();
    }
    if (response.contentType != _workbookMediaType ||
        response.body.length != size ||
        sha256.convert(response.body).toString() != hash) {
      _invalid();
    }
    return response.body;
  }

  /// Read only an original source registered in this task's saved report.
  /// This is not a path API, a task wake, or a replacement-version fallback.
  Future<Map<String, Object?>> readCompanionHostSource({
    required String hostStoreId,
    required String taskId,
    required String hostExecutionId,
    required String sourceRef,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await _connection(this).get(
      '$_path/${Uri.encodeComponent(taskId)}/sources/${Uri.encodeComponent(sourceRef)}',
      query: {'hostStoreId': hostStoreId, 'hostExecutionId': hostExecutionId},
      timeout: timeout,
      followRedirects: false,
      maxResponseBytes: 1024 * 1024,
    );
    final map = _decode(response);
    _success(response, map);
    _identity(map, hostStoreId, taskId);
    if (map['hostExecutionId'] != hostExecutionId ||
        map['sourceRef'] != sourceRef ||
        map['taskRev'] is! int ||
        (map['taskRev']! as int) < 1 ||
        map['stepKey'] != 'readInputs' ||
        map['relativePath'] is! String ||
        (map['relativePath']! as String).isEmpty ||
        map['version'] is! String ||
        (map['version']! as String).isEmpty ||
        !const ['available', 'missing', 'changed', 'not_readable', 'unknown'].contains(map['status']) ||
        !const ['text/markdown', 'text/plain'].contains(map['mediaType']) ||
        (map['status'] == 'available' ? map['content'] is! String : map['content'] != null) ||
        !map.containsKey('reason') ||
        (map['status'] == 'available'
            ? map['reason'] != null
            : map['reason'] is! String || (map['reason']! as String).isEmpty)) {
      _invalid();
    }
    if (map['status'] == 'available' && utf8.encode(map['content']! as String).length > 65536) {
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
