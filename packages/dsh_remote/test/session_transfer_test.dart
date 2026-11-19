import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dsh_remote/src/carrier/tunnel_carrier.dart';
import 'package:dsh_remote/src/channel/rpc_client.dart';
import 'package:dsh_remote/src/session_transfer.dart';
import 'package:test/test.dart';

const _maxBytes = 8 * 1024 * 1024;
const _maxChunk = 256 * 1024;

TypeMatcher<RemoteRpcException> _code(String code) => isA<RemoteRpcException>().having((e) => e.code, 'code', code);

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());

  test('capabilities are independent and a closed connection cannot transfer', () async {
    f.session.capabilities.remove('session.transfer.import.v1');
    expect(f.transfer.canExport, isTrue);
    expect(f.transfer.canImport, isFalse);
    await expectLater(f.restore(), throwsA(_code('SESSION_TRANSFER_IMPORT_UNSUPPORTED')));
    f.session.capabilities
      ..clear()
      ..add('session.transfer.import.v1');
    expect(f.transfer.canImport, isTrue);
    expect(f.transfer.canExport, isFalse);
    await expectLater(
      f.transfer.openExport(sessionId: 'source'),
      throwsA(_code('SESSION_TRANSFER_EXPORT_UNSUPPORTED')),
    );
    await f.rpc.close();
    expect(f.transfer.canImport, isFalse);
    await expectLater(f.restore(), throwsA(_code('TRANSPORT_CLOSED')));
    expect(f.rpc.calls, isEmpty);
  });

  test('opens exactly one scope and preserves the frozen manifest', () async {
    await expectLater(f.transfer.openExport(), throwsArgumentError);
    await expectLater(f.transfer.openExport(sessionId: 's', workspaceId: 'w'), throwsArgumentError);
    expect(f.rpc.calls, isEmpty);
    final opened = await f.transfer.openExport(sessionId: 'source');
    expect(opened.handle, 'export-handle');
    expect(opened.chunkBytes, f.rpc.chunkBytes);
    expect(opened.sessions.single.sessionId, 'source');
    expect(opened.sessions.single.throughSeq, 42);
    expect(f.rpc.calls.single.$2, {
      'scope': {'kind': 'session', 'sessionId': 'source'},
    });
    await f.transfer.closeExport(opened);
    expect(f.rpc.calls.last.$2, {'handle': 'export-handle'});
    await f.transfer.openExport(workspaceId: 'workspace');
    expect(f.rpc.calls.last.$2, {
      'scope': {'kind': 'workspace', 'workspaceId': 'workspace'},
    });
  });

  test('reads exact gzip bytes with sequential compressed offsets and validates the trailer', () async {
    final opened = await f.open();
    final data = await f.transfer.readSession(opened, opened.sessions.single);
    expect(data.gzipBytes, f.rpc.bytes);
    expect(gzip.decode(data.gzipBytes), utf8.encode('session snapshot'));
    expect(data.totalBytes, f.rpc.bytes.length);
    expect(data.sha256, crypto.sha256.convert(f.rpc.bytes).toString());
    final reads = f.rpc.calls.where((call) => call.$1 == 'session.transfer.export.read').toList();
    expect(reads.map((call) => call.$2['offset']), [
      for (var offset = 0; offset < data.totalBytes; offset += f.rpc.chunkBytes) offset,
    ]);
    for (final call in reads) {
      expect(call.$2.keys, unorderedEquals(['handle', 'sessionId', 'offset']));
      expect(call.$2['handle'], 'export-handle');
      expect(call.$2['sessionId'], 'source');
    }
    await f.transfer.closeExport(opened);
    expect(f.rpc.methods.last, 'session.transfer.export.close');
  });

  for (final chunkBytes in [0, -1, _maxChunk + 1, 1.5, null]) {
    test('rejects invalid export chunk size $chunkBytes and closes its handle', () async {
      f.rpc.handler = (method, params) => method.endsWith('export.open')
          ? {'handle': 'export-handle', 'sessions': <Object?>[], 'chunkBytes': chunkBytes}
          : f.rpc.reply(method, params);
      await expectLater(f.open(), throwsA(_code('INVALID_MESSAGE')));
      expect(f.rpc.methods, ['session.transfer.export.open', 'session.transfer.export.close']);
    });
  }

  final invalidChunks = <String, Map<String, Object?>>{
    'wrong offset': {'offset': 1, 'data': 'YQ=='},
    'nonintegral offset': {'offset': 0.0, 'data': 'YQ=='},
    'malformed Base64': {'offset': 0, 'data': '!!!='},
    'URL-safe Base64': {'offset': 0, 'data': '____'},
    'unpadded Base64': {'offset': 0, 'data': 'YQ'},
    'chunk exceeds returned size': {'offset': 0, 'data': base64Encode(List<int>.filled(9, 0))},
    'empty nonfinal chunk': {'offset': 0, 'data': ''},
    'partial trailer': {'offset': 0, 'data': 'YQ==', 'totalBytes': 1},
    'size mismatch': {
      'offset': 0,
      'data': 'YQ==',
      'totalBytes': 2,
      'sha256': crypto.sha256.convert([97]).toString(),
    },
    'digest mismatch': {'offset': 0, 'data': 'YQ==', 'totalBytes': 1, 'sha256': '0' * 64},
    'uppercase digest': {
      'offset': 0,
      'data': 'YQ==',
      'totalBytes': 1,
      'sha256': crypto.sha256.convert([97]).toString().toUpperCase(),
    },
  };
  for (final entry in invalidChunks.entries) {
    test('rejects export ${entry.key} without reading further', () async {
      final opened = await f.open();
      f.rpc.handler = (_, _) => entry.value;
      final integrity = ['size mismatch', 'digest mismatch', 'uppercase digest'].contains(entry.key);
      await expectLater(
        f.transfer.readSession(opened, opened.sessions.single),
        throwsA(_code(integrity ? 'SESSION_TRANSFER_INTEGRITY' : 'INVALID_MESSAGE')),
      );
      expect(f.rpc.methods, ['session.transfer.export.open', 'session.transfer.export.read']);
    });
  }

  test('bounds export accumulation at 8 MiB even without a final trailer', () async {
    f.rpc.chunkBytes = _maxChunk;
    final opened = await f.open();
    final encoded = base64Encode(Uint8List(_maxChunk));
    f.rpc.handler = (_, params) => {'offset': params['offset'], 'data': encoded};
    await expectLater(
      f.transfer.readSession(opened, opened.sessions.single),
      throwsA(_code('SESSION_TRANSFER_TOO_LARGE')),
    );
    expect(f.rpc.methods.where((method) => method.endsWith('export.read')).length, 33);
  });

  test('export cancellation stops before the next chunk and caller can close', () async {
    final opened = await f.open();
    var cancelled = false;
    f.rpc.handler = (method, params) {
      if (method.endsWith('export.read')) cancelled = true;
      return f.rpc.reply(method, params);
    };
    await expectLater(
      f.transfer.readSession(opened, opened.sessions.single, isCancelled: () => cancelled),
      throwsA(isA<SessionTransferCancelledException>()),
    );
    expect(f.rpc.methods.where((method) => method.endsWith('export.read')).length, 1);
    await f.transfer.closeExport(opened);
    expect(f.rpc.methods.last, 'session.transfer.export.close');
  });

  test('restore validates local metadata before opening any import', () async {
    for (final data in [
      SessionTransferData(gzipBytes: f.rpc.bytes, totalBytes: f.rpc.bytes.length + 1, sha256: f.data.sha256),
      SessionTransferData(gzipBytes: f.rpc.bytes, totalBytes: f.rpc.bytes.length, sha256: '0' * 64),
      SessionTransferData(gzipBytes: Uint8List(0), totalBytes: 0, sha256: crypto.sha256.convert([]).toString()),
    ]) {
      await expectLater(f.restore(data: data), throwsA(_code('SESSION_TRANSFER_INTEGRITY')));
    }
    final large = SessionTransferData(gzipBytes: Uint8List(_maxBytes + 1), totalBytes: _maxBytes + 1, sha256: '0' * 64);
    await expectLater(f.restore(data: large), throwsA(_code('SESSION_TRANSFER_TOO_LARGE')));
    expect(f.rpc.calls, isEmpty);
  });

  test('restore awaits each acknowledgement and durable pending before committing', () async {
    final firstChunk = Completer<void>();
    final chunkAck = Completer<void>();
    final pendingStarted = Completer<void>();
    final pendingSaved = Completer<void>();
    f.rpc.handler = (method, params) async {
      if (method.endsWith('import.chunk') && params['offset'] == 0) {
        firstChunk.complete();
        await chunkAck.future;
      }
      if (method.endsWith('import.commit')) {
        expect(pendingSaved.isCompleted, isTrue);
      }
      return f.rpc.reply(method, params);
    };
    final restoring = f.restore(
      beforeCommit: () async {
        pendingStarted.complete();
        await pendingSaved.future;
      },
    );
    await firstChunk.future;
    expect(f.rpc.methods, ['session.transfer.import.open', 'session.transfer.import.chunk']);
    chunkAck.complete();
    await pendingStarted.future;
    expect(f.rpc.methods, isNot(contains('session.transfer.import.commit')));
    pendingSaved.complete();
    final result = await restoring;
    expect(result.sessionId, 'restored');
    expect(result.workspaceAttached, isTrue);
    expect(f.rpc.calls.first.$2, {
      'workspaceId': 'target-workspace',
      'batchId': 'batch',
      'sourceSessionId': 'source',
      'formatVersion': 1,
    });
    final uploaded = BytesBuilder();
    for (final call in f.rpc.calls.where((call) => call.$1.endsWith('import.chunk'))) {
      expect(call.$2.keys, unorderedEquals(['handle', 'offset', 'data']));
      expect(call.$2['handle'], 'import-handle');
      expect(call.$2['offset'], uploaded.length);
      final encoded = call.$2['data']! as String;
      final decoded = base64Decode(encoded);
      expect(base64Encode(decoded), encoded);
      expect(decoded.length, inInclusiveRange(1, f.rpc.chunkBytes));
      uploaded.add(decoded);
    }
    expect(uploaded.takeBytes(), f.rpc.bytes);
    expect(f.rpc.calls.last.$2, {
      'handle': 'import-handle',
      'requestId': 'request',
      'totalBytes': f.data.totalBytes,
      'sha256': f.data.sha256,
    });
    expect(f.rpc.methods, isNot(contains('session.transfer.import.abort')));
  });

  test('workspaceAttached false is successful and is not aborted', () async {
    f.rpc.workspaceAttached = false;
    final result = await f.restore();
    expect(result.sessionId, 'restored');
    expect(result.workspaceAttached, isFalse);
    expect(f.rpc.methods.last, 'session.transfer.import.commit');
  });

  for (final limits in <Map<String, Object?>>[
    {'chunkBytes': 0, 'maxBytes': _maxBytes},
    {'chunkBytes': _maxChunk + 1, 'maxBytes': _maxBytes},
    {'chunkBytes': 8, 'maxBytes': _maxBytes + 1},
    {'chunkBytes': 8, 'maxBytes': 0},
    {'chunkBytes': 8, 'maxBytes': null},
  ]) {
    test('invalid import limits $limits abort the returned handle', () async {
      f.rpc.handler = (method, params) =>
          method.endsWith('import.open') ? {'handle': 'import-handle', ...limits} : f.rpc.reply(method, params);
      await expectLater(f.restore(), throwsA(_code('INVALID_MESSAGE')));
      expect(f.rpc.methods, ['session.transfer.import.open', 'session.transfer.import.abort']);
      expect(f.rpc.calls.last.$2, {'handle': 'import-handle'});
    });
  }

  test('honors a smaller Host maxBytes without uploading', () async {
    f.rpc.maxBytes = f.rpc.bytes.length - 1;
    await expectLater(f.restore(), throwsA(_code('SESSION_TRANSFER_TOO_LARGE')));
    expect(f.rpc.methods, ['session.transfer.import.open', 'session.transfer.import.abort']);
  });

  for (final ack in [0, 8.0, null]) {
    test('incorrect upload acknowledgement $ack aborts before commit', () async {
      f.rpc.handler = (method, params) =>
          method.endsWith('import.chunk') ? {'receivedBytes': ack} : f.rpc.reply(method, params);
      await expectLater(f.restore(), throwsA(_code('INVALID_MESSAGE')));
      expect(f.rpc.methods, [
        'session.transfer.import.open',
        'session.transfer.import.chunk',
        'session.transfer.import.abort',
      ]);
    });
  }

  test('a failure saving pending aborts and preserves the original error even if abort fails', () async {
    final failure = StateError('pending write failed');
    f.rpc.handler = (method, params) {
      if (method.endsWith('import.abort')) {
        throw const RemoteRpcException('TRANSPORT_CLOSED', 'abort failed', isLocal: true);
      }
      return f.rpc.reply(method, params);
    };
    await expectLater(f.restore(beforeCommit: () async => throw failure), throwsA(same(failure)));
    expect(f.rpc.methods.last, 'session.transfer.import.abort');
    expect(f.rpc.methods, isNot(contains('session.transfer.import.commit')));
  });

  test('upload failure aborts on the original RPC without reopening', () async {
    const failure = RemoteRpcException('TRANSPORT_CLOSED', 'upload failed', isLocal: true);
    f.rpc.handler = (method, params) {
      if (method.endsWith('import.chunk')) throw failure;
      return f.rpc.reply(method, params);
    };
    await expectLater(f.restore(), throwsA(same(failure)));
    expect(f.rpc.methods, [
      'session.transfer.import.open',
      'session.transfer.import.chunk',
      'session.transfer.import.abort',
    ]);
  });

  test('cancelling an upload aborts before the next chunk', () async {
    var cancelled = false;
    f.rpc.handler = (method, params) {
      if (method.endsWith('import.chunk')) cancelled = true;
      return f.rpc.reply(method, params);
    };
    await expectLater(f.restore(isCancelled: () => cancelled), throwsA(isA<SessionTransferCancelledException>()));
    expect(f.rpc.methods, [
      'session.transfer.import.open',
      'session.transfer.import.chunk',
      'session.transfer.import.abort',
    ]);
  });

  test('cancelling while pending is saved still aborts without commit', () async {
    var cancelled = false;
    await expectLater(
      f.restore(
        beforeCommit: () async {
          cancelled = true;
        },
        isCancelled: () => cancelled,
      ),
      throwsA(isA<SessionTransferCancelledException>()),
    );
    expect(f.rpc.methods.last, 'session.transfer.import.abort');
    expect(f.rpc.methods, isNot(contains('session.transfer.import.commit')));
  });

  test('cancellation does not interrupt an already sent commit', () async {
    var cancelled = false;
    f.rpc.handler = (method, params) {
      if (method.endsWith('import.commit')) cancelled = true;
      return f.rpc.reply(method, params);
    };
    final result = await f.restore(isCancelled: () => cancelled);
    expect(cancelled, isTrue);
    expect(result.sessionId, 'restored');
    expect(f.rpc.methods.last, 'session.transfer.import.commit');
  });

  for (final failure in <Object>[
    const RemoteRpcException('TRANSPORT_CLOSED', 'lost', isLocal: true),
    const RemoteRpcException('RPC_TIMEOUT', 'late', isLocal: true),
    StateError('unexpected transport failure'),
  ]) {
    test('commit failure $failure is uncertain and never aborts or replays', () async {
      f.rpc.handler = (method, params) {
        if (method.endsWith('import.commit')) throw failure;
        return f.rpc.reply(method, params);
      };
      await expectLater(
        f.restore(),
        throwsA(
          isA<SessionImportOutcomeUnknownException>()
              .having((e) => e.batchId, 'batchId', 'batch')
              .having((e) => e.requestId, 'requestId', 'request')
              .having((e) => e.cause, 'cause', same(failure)),
        ),
      );
      expect(f.rpc.methods.last, 'session.transfer.import.commit');
      expect(f.rpc.methods.where((method) => method.endsWith('import.commit')).length, 1);
      expect(f.rpc.methods.where((method) => method.endsWith('import.open')).length, 1);
      expect(f.rpc.methods, isNot(contains('session.transfer.import.abort')));
    });
  }

  test('explicit Host commit rejection propagates without aborting', () async {
    const failure = RemoteRpcException('IMPORT_INVALID_HISTORY', 'Host refused snapshot');
    f.rpc.handler = (method, params) {
      if (method.endsWith('import.commit')) throw failure;
      return f.rpc.reply(method, params);
    };
    await expectLater(f.restore(), throwsA(same(failure)));
    expect(f.rpc.methods.last, 'session.transfer.import.commit');
  });

  test('malformed commit success is uncertain rather than safe to retry', () async {
    f.rpc.handler = (method, params) => method.endsWith('import.commit')
        ? {'sessionId': 'restored', 'workspaceAttached': 'yes'}
        : f.rpc.reply(method, params);
    await expectLater(f.restore(), throwsA(isA<SessionImportOutcomeUnknownException>()));
    expect(f.rpc.methods.last, 'session.transfer.import.commit');
  });

  test('status uses only batch and request, distinguishes unknown and completed', () async {
    expect(await f.transfer.status(batchId: 'batch', requestId: 'request'), isNull);
    expect(f.rpc.calls.single.$2, {'batchId': 'batch', 'requestId': 'request'});
    f.rpc.statusResult = {'status': 'completed', 'sessionId': 'known', 'workspaceAttached': false};
    final result = await f.transfer.status(batchId: 'batch', requestId: 'request');
    expect(result!.sessionId, 'known');
    expect(result.workspaceAttached, isFalse);
    expect(f.rpc.methods, everyElement('session.transfer.import.status'));
  });

  test('status returns the original Host commit error and rejects malformed statuses', () async {
    const failure = RemoteRpcException('IMPORT_INVALID_HISTORY', 'prior commit failed');
    f.rpc.handler = (_, _) => throw failure;
    await expectLater(f.transfer.status(batchId: 'batch', requestId: 'request'), throwsA(same(failure)));
    f.rpc.handler = null;
    for (final result in <Object?>[
      null,
      {'status': 'pending'},
      {'status': 'completed', 'sessionId': 'known'},
    ]) {
      f.rpc.statusResult = result;
      await expectLater(f.transfer.status(batchId: 'batch', requestId: 'request'), throwsA(_code('INVALID_MESSAGE')));
    }
  });
}

class _Fixture {
  _Fixture() {
    session = RemoteHostSession(rpc: rpc, capabilities: ['session.transfer.export.v1', 'session.transfer.import.v1']);
    transfer = RemoteSessionTransfer(session);
  }

  final rpc = _TransferRpc();
  late final RemoteHostSession session;
  late final RemoteSessionTransfer transfer;

  SessionTransferData get data => SessionTransferData(
    gzipBytes: rpc.bytes,
    totalBytes: rpc.bytes.length,
    sha256: crypto.sha256.convert(rpc.bytes).toString(),
  );

  Future<SessionExport> open() => transfer.openExport(sessionId: 'source');

  Future<SessionImportResult> restore({
    SessionTransferData? data,
    Future<void> Function()? beforeCommit,
    bool Function()? isCancelled,
  }) => transfer.restore(
    data ?? this.data,
    workspaceId: 'target-workspace',
    batchId: 'batch',
    sourceSessionId: 'source',
    requestId: 'request',
    beforeCommit: beforeCommit ?? () async {},
    isCancelled: isCancelled,
  );
}

class _TransferRpc implements RemoteRpcClient {
  final calls = <(String, Map<String, Object?>)>[];
  final bytes = Uint8List.fromList(gzip.encode(utf8.encode('session snapshot')));
  int chunkBytes = 8;
  int maxBytes = _maxBytes;
  bool workspaceAttached = true;
  Object? statusResult = {'status': 'unknown'};
  FutureOr<Object?> Function(String, Map<String, Object?>)? handler;
  bool _closed = false;

  List<String> get methods => calls.map((call) => call.$1).toList();

  @override
  bool get isClosed => _closed;

  @override
  Future<Object?> call(String method, Object? params, {Duration? timeout}) async {
    final map = params! as Map<String, Object?>;
    calls.add((method, map));
    if (_closed) {
      throw const RemoteRpcException('TRANSPORT_CLOSED', 'test closed', isLocal: true);
    }
    return handler == null ? reply(method, map) : await handler!(method, map);
  }

  Object? reply(String method, Map<String, Object?> params) {
    switch (method) {
      case 'session.transfer.export.open':
        return {
          'handle': 'export-handle',
          'sessions': [
            {'sessionId': 'source', 'throughSeq': 42},
          ],
          'chunkBytes': chunkBytes,
        };
      case 'session.transfer.export.read':
        final offset = params['offset']! as int;
        final end = offset + chunkBytes < bytes.length ? offset + chunkBytes : bytes.length;
        return {
          'offset': offset,
          'data': base64Encode(bytes.sublist(offset, end)),
          if (end == bytes.length) ...{'totalBytes': bytes.length, 'sha256': crypto.sha256.convert(bytes).toString()},
        };
      case 'session.transfer.export.close':
      case 'session.transfer.import.abort':
        return <String, Object?>{};
      case 'session.transfer.import.open':
        return {'handle': 'import-handle', 'chunkBytes': chunkBytes, 'maxBytes': maxBytes};
      case 'session.transfer.import.chunk':
        return {'receivedBytes': (params['offset']! as int) + base64Decode(params['data']! as String).length};
      case 'session.transfer.import.commit':
        return {'sessionId': 'restored', 'workspaceAttached': workspaceAttached};
      case 'session.transfer.import.status':
        return statusResult;
      default:
        throw StateError('Unexpected RPC $method');
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
