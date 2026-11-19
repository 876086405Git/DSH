import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'carrier/tunnel_carrier.dart';
import 'channel/rpc_client.dart';
import 'util/bytes.dart';

const _maxSessionBytes = 8 * 1024 * 1024;
const _maxChunkBytes = 256 * 1024;
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

class SessionExportEntry {
  const SessionExportEntry({required this.sessionId, required this.throughSeq});

  final String sessionId;
  final int throughSeq;
}

class SessionExport {
  const SessionExport({required this.handle, required this.sessions, required this.chunkBytes});

  final String handle;
  final List<SessionExportEntry> sessions;
  final int chunkBytes;
}

/// The opaque gzip snapshot and the metadata persisted with its local backup.
/// [RemoteSessionTransfer.restore] revalidates both before uploading.
class SessionTransferData {
  const SessionTransferData({required this.gzipBytes, required this.totalBytes, required this.sha256});

  final Uint8List gzipBytes;
  final int totalBytes;
  final String sha256;
}

class SessionImportResult {
  const SessionImportResult({required this.sessionId, required this.workspaceAttached});

  final String sessionId;

  /// False still means the history was restored; do not import it again.
  final bool workspaceAttached;
}

class SessionTransferCancelledException implements Exception {
  const SessionTransferCancelledException();

  @override
  String toString() => 'SessionTransferCancelledException';
}

/// A commit was invoked, but its outcome cannot be established locally.
/// Keep the pending record and query [RemoteSessionTransfer.status] using the
/// same device identity. Even an unknown status must not trigger an automatic
/// retry: the Host only retains outcomes for five minutes.
class SessionImportOutcomeUnknownException implements Exception {
  const SessionImportOutcomeUnknownException({required this.batchId, required this.requestId, required this.cause});

  final String batchId;
  final String requestId;
  final Object cause;

  @override
  String toString() => 'SessionImportOutcomeUnknownException: query import status before any further action.';
}

/// Session snapshots over one authenticated connection. This class never
/// reconnects, reopens handles or replays mutations.
class RemoteSessionTransfer {
  RemoteSessionTransfer(this._session);

  final RemoteHostSession _session;

  bool get canExport => !_session.isClosed && _session.capabilities.contains('session.transfer.export.v1');
  bool get canImport => !_session.isClosed && _session.capabilities.contains('session.transfer.import.v1');

  Future<SessionExport> openExport({String? sessionId, String? workspaceId}) async {
    _requireCapability('export');
    if ((sessionId == null) == (workspaceId == null)) {
      throw ArgumentError('Specify exactly one sessionId or workspaceId.');
    }
    final opened = _object(
      await _session.rpc.call('session.transfer.export.open', {
        'scope': sessionId != null
            ? {'kind': 'session', 'sessionId': sessionId}
            : {'kind': 'workspace', 'workspaceId': workspaceId},
      }),
    );
    final handle = _string(opened['handle']);
    try {
      final chunkBytes = _chunkSize(opened['chunkBytes']);
      final sessions = opened['sessions'];
      if (sessions is! List<Object?> || sessions.length > 2048) {
        throw _invalid('Invalid session export manifest.');
      }
      final entries = sessions
          .map((value) {
            final entry = _object(value);
            final throughSeq = entry['throughSeq'];
            if (throughSeq is! int || throughSeq < -1) {
              throw _invalid('Invalid session export boundary.');
            }
            return SessionExportEntry(sessionId: _string(entry['sessionId']), throughSeq: throughSeq);
          })
          .toList(growable: false);
      return SessionExport(handle: handle, sessions: List.unmodifiable(entries), chunkBytes: chunkBytes);
    } on Object {
      await _discard('export.close', handle);
      rethrow;
    }
  }

  /// Reads compressed bytes only; the Host validates the snapshot's inflated
  /// size and event schema. The caller closes the export in a finally block.
  Future<SessionTransferData> readSession(
    SessionExport export,
    SessionExportEntry entry, {
    bool Function()? isCancelled,
  }) async {
    _requireCapability('export');
    final chunkBytes = _chunkSize(export.chunkBytes);
    final bytes = BytesBuilder(copy: false);
    while (true) {
      _checkCancelled(isCancelled);
      final chunk = _object(
        await _session.rpc.call('session.transfer.export.read', {
          'handle': export.handle,
          'sessionId': entry.sessionId,
          'offset': bytes.length,
        }),
      );
      if (chunk['offset'] is! int || chunk['offset'] != bytes.length) {
        throw _invalid('Invalid session export offset.');
      }
      final encoded = chunk['data'];
      if (encoded is! String || encoded.length > ((chunkBytes + 2) ~/ 3) * 4) {
        throw _invalid('Invalid session export chunk.');
      }
      final Uint8List decoded;
      try {
        decoded = base64Decode(encoded);
      } on FormatException {
        throw _invalid('Invalid session export Base64.');
      }
      if (decoded.length > chunkBytes || base64Encode(decoded) != encoded) {
        throw _invalid('Invalid session export chunk encoding or size.');
      }
      if (bytes.length + decoded.length > _maxSessionBytes) throw _tooLarge();
      bytes.add(decoded);
      if (chunk.containsKey('totalBytes') || chunk.containsKey('sha256')) {
        final totalBytes = chunk['totalBytes'];
        final digest = chunk['sha256'];
        if (totalBytes is! int || digest is! String) {
          throw _invalid('Invalid session export trailer.');
        }
        final data = SessionTransferData(gzipBytes: bytes.takeBytes(), totalBytes: totalBytes, sha256: digest);
        _validateData(data);
        _checkCancelled(isCancelled);
        return data;
      }
      if (decoded.isEmpty) throw _invalid('Session export did not advance.');
    }
  }

  Future<void> closeExport(SessionExport export) async {
    await _session.rpc.call('session.transfer.export.close', {'handle': export.handle});
  }

  Future<SessionImportResult> restore(
    SessionTransferData data, {
    required String workspaceId,
    required String batchId,
    required String sourceSessionId,
    required String requestId,
    required Future<void> Function() beforeCommit,
    bool Function()? isCancelled,
  }) async {
    _requireCapability('import');
    _validateData(data);
    _checkCancelled(isCancelled);
    String? handle;
    var commitStarted = false;
    try {
      final opened = _object(
        await _session.rpc.call('session.transfer.import.open', {
          'workspaceId': workspaceId,
          'batchId': batchId,
          'sourceSessionId': sourceSessionId,
          'formatVersion': 1,
        }),
      );
      handle = _string(opened['handle']);
      final chunkBytes = _chunkSize(opened['chunkBytes']);
      final maxBytes = opened['maxBytes'];
      if (maxBytes is! int || maxBytes < 1 || maxBytes > _maxSessionBytes) {
        throw _invalid('Invalid session import size limit.');
      }
      if (data.totalBytes > maxBytes) throw _tooLarge();
      for (var offset = 0; offset < data.totalBytes;) {
        _checkCancelled(isCancelled);
        final end = offset + chunkBytes < data.totalBytes ? offset + chunkBytes : data.totalBytes;
        final ack = _object(
          await _session.rpc.call('session.transfer.import.chunk', {
            'handle': handle,
            'offset': offset,
            'data': base64Encode(data.gzipBytes.sublist(offset, end)),
          }),
        );
        if (ack['receivedBytes'] is! int || ack['receivedBytes'] != end) {
          throw _invalid('Invalid session import acknowledgement.');
        }
        offset = end;
      }
      _checkCancelled(isCancelled);
      // The UI must durably save pending IDs before a commit can leave here.
      await beforeCommit();
      _checkCancelled(isCancelled);
      commitStarted = true;
      try {
        return _importResult(
          await _session.rpc.call('session.transfer.import.commit', {
            'handle': handle,
            'requestId': requestId,
            'totalBytes': data.totalBytes,
            'sha256': data.sha256,
          }),
        );
      } on Object catch (error) {
        // An explicit Host error is a known outcome; all other failures leave
        // the durable pending record authoritative. Never abort after commit.
        if (error is RemoteRpcException && !error.isLocal && !error.isTransportClosed) {
          rethrow;
        }
        throw SessionImportOutcomeUnknownException(batchId: batchId, requestId: requestId, cause: error);
      }
    } finally {
      if (handle != null && !commitStarted) {
        await _discard('import.abort', handle);
      }
    }
  }

  /// Null means unknown, including an expired result, not safe to reimport.
  /// Explicit Host commit errors are propagated unchanged.
  Future<SessionImportResult?> status({required String batchId, required String requestId}) async {
    _requireCapability('import');
    final result = _object(
      await _session.rpc.call('session.transfer.import.status', {'batchId': batchId, 'requestId': requestId}),
    );
    switch (result['status']) {
      case 'unknown':
        return null;
      case 'completed':
        return _importResult(result);
      default:
        throw _invalid('Invalid session import status.');
    }
  }

  void _requireCapability(String operation) {
    if (_session.isClosed) {
      throw const RemoteRpcException('TRANSPORT_CLOSED', 'The session transfer connection ended.', isLocal: true);
    }
    if (!_session.capabilities.contains('session.transfer.$operation.v1')) {
      throw RemoteRpcException(
        'SESSION_TRANSFER_${operation.toUpperCase()}_UNSUPPORTED',
        'Host does not support session $operation.',
      );
    }
  }

  Future<void> _discard(String operation, String handle) async {
    try {
      await _session.rpc.call('session.transfer.$operation', {'handle': handle}, timeout: const Duration(seconds: 5));
    } on Object {
      // Best effort on the original connection. Preserve the actual failure;
      // the Host also releases handles when that connection closes or idles.
    }
  }
}

void _checkCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) {
    throw const SessionTransferCancelledException();
  }
}

void _validateData(SessionTransferData data) {
  if (data.totalBytes > _maxSessionBytes || data.gzipBytes.length > _maxSessionBytes) {
    throw _tooLarge();
  }
  if (data.totalBytes < 1 ||
      data.totalBytes != data.gzipBytes.length ||
      !_digestPattern.hasMatch(data.sha256) ||
      crypto.sha256.convert(data.gzipBytes).toString() != data.sha256) {
    throw const RemoteRpcException(
      'SESSION_TRANSFER_INTEGRITY',
      'Session snapshot length or SHA-256 mismatch.',
      isLocal: true,
    );
  }
}

Map<String, Object?> _object(Object? value) {
  final object = asMap(value);
  if (object == null) throw _invalid('Invalid session transfer response.');
  return object;
}

String _string(Object? value) {
  if (value is! String || value.isEmpty) {
    throw _invalid('Invalid session transfer identifier.');
  }
  return value;
}

int _chunkSize(Object? value) {
  if (value is! int || value < 1 || value > _maxChunkBytes) {
    throw _invalid('Invalid session transfer chunk size.');
  }
  return value;
}

SessionImportResult _importResult(Object? value) {
  final result = _object(value);
  final attached = result['workspaceAttached'];
  if (attached is! bool) throw _invalid('Invalid session import result.');
  return SessionImportResult(sessionId: _string(result['sessionId']), workspaceAttached: attached);
}

RemoteRpcException _invalid(String message) => RemoteRpcException('INVALID_MESSAGE', message, isLocal: true);

RemoteRpcException _tooLarge() =>
    const RemoteRpcException('SESSION_TRANSFER_TOO_LARGE', 'Session snapshot exceeds the 8 MiB limit.', isLocal: true);
