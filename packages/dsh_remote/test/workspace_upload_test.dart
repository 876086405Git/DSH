import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

const _limit = 1024 * 1024 * 1024;
const _chunkBytes = 64 * 1024;

TypeMatcher<DshRemoteException> _code(String code) => isA<DshRemoteException>().having((e) => e.code, 'code', code);

void main() {
  group('workspace upload carrier', () {
    late _Fixture f;
    setUp(() => f = _Fixture());
    tearDown(() => f.carrier.close());

    test('requires a live capability, never cached capabilities or an implicit reconnect', () async {
      expect(f.carrier, isA<WorkspaceUploadCarrier>());
      expect(f.carrier.supportsWorkspaceUpload, isFalse);
      await expectLater(
        f.carrier.uploadWorkspaceFile('session-1', const [], name: 'empty.txt'),
        throwsA(_code('WORKSPACE_UPLOAD_UNSUPPORTED')),
      );
      expect(f.opens, 0);
      await f.connect();
      expect(f.carrier.supportsWorkspaceUpload, isTrue);
      await f.rpc.close();
      expect(f.carrier.capabilities, contains('workspace.upload.v1'));
      expect(f.carrier.supportsWorkspaceUpload, isFalse);
      await expectLater(
        f.carrier.uploadWorkspaceFile('session-1', const [], name: 'empty.txt'),
        throwsA(_code('WORKSPACE_UPLOAD_UNSUPPORTED')),
      );
      expect(f.opens, 1);
      expect(f.rpc.calls, isEmpty);
    });

    test('old Host is refused before any upload mutation', () async {
      f.session.capabilities.clear();
      await f.connect();
      await expectLater(
        f.carrier.uploadWorkspaceFile('session-1', const [], name: 'empty.txt'),
        throwsA(_code('WORKSPACE_UPLOAD_UNSUPPORTED')),
      );
      expect(f.rpc.calls, isEmpty);
      expect(f.carrier.allowsEndpoint('fileUploads/upload'), isFalse);
    });

    test('closed carrier cannot claim upload support', () async {
      await f.connect();
      await f.carrier.close();
      expect(f.carrier.supportsWorkspaceUpload, isFalse);
    });

    for (final path in [null, ...RemoteTransportMode.values]) {
      test('absolute 1 GiB protocol limit for $path, independent of claimed P2P', () async {
        final fixture = _Fixture(path: path, transport: 'p2p');
        addTearDown(fixture.carrier.close);
        await fixture.connect();
        expect(fixture.carrier.maxWorkspaceUploadBytes, _limit);
        await expectLater(
          fixture.carrier.uploadWorkspaceFile('session-1', _LengthOnlyBytes(_limit + 1), name: 'too-big.bin'),
          throwsA(_code('WORKSPACE_UPLOAD_TOO_LARGE')),
        );
        expect(fixture.rpc.calls, isEmpty);
      });

      test('Host decides its 20 MiB limit on $path without reading or sending file bytes', () async {
        final fixture = _Fixture(path: path, transport: 'p2p');
        addTearDown(fixture.carrier.close);
        await fixture.connect();
        fixture.rpc.handler = (method, params) {
          if (method == 'workspace.upload.open') {
            expect(params['totalBytes'], 20 * 1024 * 1024 + 1);
            throw const RemoteRpcException('UPLOAD_LIMIT', 'Host path limit');
          }
          return fixture.rpc.reply(method, params);
        };
        await expectLater(
          fixture.carrier.uploadWorkspaceFile('session-1', _LengthOnlyBytes(20 * 1024 * 1024 + 1), name: 'large.bin'),
          throwsA(_code('UPLOAD_LIMIT')),
        );
        expect(fixture.rpc.methods, ['workspace.upload.open', 'workspace.upload.abort']);
        _expectAbortScope(fixture.rpc);
      });
    }

    test('uploads sequential canonical 64 KiB slices and accepts a collision rename', () async {
      await f.connect();
      final bytes = Uint8List.fromList(List.generate(2 * _chunkBytes + 1, (i) => i % 256));
      final firstAck = Completer<void>();
      final firstChunk = Completer<void>();
      f.rpc.handler = (method, params) async {
        if (method == 'workspace.upload.chunk' && params['offset'] == 0) {
          firstChunk.complete();
          await firstAck.future;
        }
        return f.rpc.reply(method, params);
      };
      f.rpc.finalName = 'report (1).bin';
      final uploaded = f.carrier.uploadWorkspaceFile('session-1', bytes, name: 'report.bin');
      await firstChunk.future;
      expect(f.rpc.methods, ['workspace.upload.open', 'workspace.upload.chunk']);
      firstAck.complete();
      final result = await uploaded;
      expect(result.name, 'report (1).bin');
      expect(result.path, './report (1).bin');
      expect(result.bytes, bytes.length);
      expect(f.rpc.methods, [
        'workspace.upload.open',
        'workspace.upload.chunk',
        'workspace.upload.chunk',
        'workspace.upload.chunk',
        'workspace.upload.commit',
      ]);
      final chunks = f.rpc.calls.where((c) => c.$1 == 'workspace.upload.chunk').map((c) => c.$2).toList();
      expect(chunks.map((p) => p['offset']), [0, _chunkBytes, 2 * _chunkBytes]);
      expect(chunks.map((p) => base64Decode(p['data']! as String).length), [_chunkBytes, _chunkBytes, 1]);
      expect(chunks.last['data'], base64Encode(bytes.sublist(2 * _chunkBytes)));
      expect(chunks.expand((p) => base64Decode(p['data']! as String)).toList(), bytes);
      expect(f.traces, isEmpty, reason: 'file bytes and names must not enter carrier tracing');
    });

    for (final chunkBytes in [32 * 1024, 1]) {
      test('respects Host negotiated $chunkBytes-byte chunks and cumulative offsets', () async {
        await f.connect();
        f.rpc.chunkBytes = chunkBytes;
        final bytes = Uint8List.fromList(List.generate(2 * chunkBytes + 1, (i) => i % 256));
        final result = await f.carrier.uploadWorkspaceFile('session-1', bytes, name: 'file.bin');
        final chunks = f.rpc.calls.where((c) => c.$1 == 'workspace.upload.chunk').map((c) => c.$2).toList();
        expect(chunks.map((p) => p['offset']), [0, chunkBytes, 2 * chunkBytes]);
        expect(chunks.map((p) => base64Decode(p['data']! as String).length), [chunkBytes, chunkBytes, 1]);
        expect(chunks.expand((p) => base64Decode(p['data']! as String)).toList(), bytes);
        expect(result.bytes, bytes.length);
        expect(f.rpc.methods, [
          'workspace.upload.open',
          'workspace.upload.chunk',
          'workspace.upload.chunk',
          'workspace.upload.chunk',
          'workspace.upload.commit',
        ]);
      });
    }

    test('zero-byte file is open then commit, with no chunk', () async {
      await f.connect();
      final result = await f.carrier.uploadWorkspaceFile('session-1', const [], name: 'empty.txt');
      expect(result.bytes, 0);
      expect(f.rpc.methods, ['workspace.upload.open', 'workspace.upload.commit']);
    });

    test('open accepts 220 UTF-8 bytes and commit accepts longest collision suffix', () async {
      await f.connect();
      final name = '${'a' * 216}.txt';
      f.rpc.finalName = '${'a' * 216} (9999).txt';
      final result = await f.carrier.uploadWorkspaceFile('session-1', const [], name: name);
      expect(utf8.encode(result.name), hasLength(227));
    });

    final badNames = [
      '',
      '.',
      '..',
      '../x',
      'a/b',
      r'a\b',
      'x\u0000',
      'x\u001f',
      'x\u007f',
      'a<b',
      'a>b',
      'a:b',
      'a"b',
      'a|b',
      'a?b',
      'a*b',
      'name.',
      'name ',
      'CON',
      'con.txt',
      'PrN',
      'aux',
      'nul.bin',
      'COM1.log',
      'lpt9',
      '.dsh-upload-test',
      'x' * 221,
      '\u00e9' * 111,
    ];
    for (var index = 0; index < badNames.length; index++) {
      test('unsafe input basename $index is refused without mutation', () async {
        await f.connect();
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', const [], name: badNames[index]),
          throwsA(_code('UPLOAD_INVALID_NAME')),
        );
        expect(f.rpc.calls, isEmpty);
      });
    }

    test('invalid session is refused without mutation', () async {
      await f.connect();
      for (final session in ['', 'x' * 513]) {
        await expectLater(
          f.carrier.uploadWorkspaceFile(session, const [], name: 'file'),
          throwsA(_code('INVALID_MESSAGE')),
        );
      }
      expect(f.rpc.calls, isEmpty);
    });

    for (final byte in [-1, 256]) {
      test('invalid byte $byte aborts before any chunk is sent', () async {
        await f.connect();
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', [byte], name: 'file'),
          throwsA(_code('INVALID_MESSAGE')),
        );
        expect(f.rpc.methods, ['workspace.upload.open', 'workspace.upload.abort']);
        _expectAbortScope(f.rpc);
      });
    }

    final badOpens = <Object? Function(Map<String, Object?>)>[
      (_) => null,
      (_) => <Object?>[],
      (p) => {'uploadId': 'wrong', 'chunkBytes': _chunkBytes},
      for (final chunkBytes in [0, -1, _chunkBytes + 1, 1.5, 65536.0, '65536', null])
        (p) => {'uploadId': p['uploadId'], 'chunkBytes': chunkBytes},
      (p) => {'uploadId': p['uploadId']},
    ];
    for (var index = 0; index < badOpens.length; index++) {
      test('invalid open acknowledgement $index aborts before sending chunks', () async {
        await f.connect();
        f.rpc.handler = (method, params) =>
            method == 'workspace.upload.open' ? badOpens[index](params) : f.rpc.reply(method, params);
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', [1], name: 'file.bin'),
          throwsA(_code('INVALID_MESSAGE')),
        );
        expect(f.rpc.methods, ['workspace.upload.open', 'workspace.upload.abort']);
        _expectAbortScope(f.rpc);
      });
    }

    final badChunks = <Object? Function(Map<String, Object?>)>[
      (_) => null,
      (p) => {'uploadId': 'wrong', 'receivedBytes': _chunkBytes},
      (p) => {'uploadId': p['uploadId'], 'receivedBytes': 0},
      (p) => {'uploadId': p['uploadId'], 'receivedBytes': _chunkBytes + 1},
      (p) => {'uploadId': p['uploadId'], 'receivedBytes': 65536.0},
      (p) => {'uploadId': p['uploadId']},
    ];
    for (var index = 0; index < badChunks.length; index++) {
      test('invalid chunk acknowledgement $index cannot advance or commit', () async {
        await f.connect();
        f.rpc.handler = (method, params) =>
            method == 'workspace.upload.chunk' ? badChunks[index](params) : f.rpc.reply(method, params);
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', Uint8List(_chunkBytes + 1), name: 'file.bin'),
          throwsA(_code('INVALID_MESSAGE')),
        );
        expect(f.rpc.methods, ['workspace.upload.open', 'workspace.upload.chunk', 'workspace.upload.abort']);
        _expectAbortScope(f.rpc);
      });
    }

    final badCommits = <Object?>[
      null,
      {'name': 'ok.txt', 'path': './ok.txt', 'bytes': 1},
      {'name': 'ok.txt', 'path': './ok.txt', 'bytes': 0.0},
      {'name': 'ok.txt', 'path': '/ok.txt', 'bytes': 0},
      {'name': 'ok.txt', 'path': './other.txt', 'bytes': 0},
      {'name': 'ok.txt', 'path': './sub/../ok.txt', 'bytes': 0},
      {'name': '../escape', 'path': './../escape', 'bytes': 0},
      {'name': 42, 'path': './42', 'bytes': 0},
      for (final name in badNames.where((n) => utf8.encode(n).length <= 220))
        {'name': name, 'path': './$name', 'bytes': 0},
      {'name': 'x' * 228, 'path': './${'x' * 228}', 'bytes': 0},
    ];
    for (var index = 0; index < badCommits.length; index++) {
      test('invalid commit result $index is never exposed as an uploaded path', () async {
        await f.connect();
        f.rpc.handler = (method, params) =>
            method == 'workspace.upload.commit' ? badCommits[index] : f.rpc.reply(method, params);
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', const [], name: 'ok.txt'),
          throwsA(_code('INVALID_MESSAGE')),
        );
        expect(f.rpc.methods, ['workspace.upload.open', 'workspace.upload.commit', 'workspace.upload.abort']);
        _expectAbortScope(f.rpc);
      });
    }

    for (final stage in ['open', 'chunk', 'commit']) {
      test('Host $stage failure keeps its code/details and is not retried', () async {
        await f.connect();
        f.rpc.handler = (method, params) {
          if (method == 'workspace.upload.$stage') {
            throw const RemoteRpcException(
              'UPLOAD_WORKSPACE_CHANGED',
              'Host refusal',
              details: {'scope': 'changed'},
              retryable: true,
            );
          }
          if (method == 'workspace.upload.abort') throw StateError('abort also failed');
          return f.rpc.reply(method, params);
        };
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', [1], name: 'file.bin'),
          throwsA(
            _code('UPLOAD_WORKSPACE_CHANGED').having((e) => e.message, 'message', 'Host refusal').having(
              (e) => e.details,
              'details',
              {'scope': 'changed', 'remote': true, 'retryable': true},
            ),
          ),
        );
        expect(f.rpc.methods.where((m) => m == 'workspace.upload.$stage'), hasLength(1));
        _expectAbortScope(f.rpc);
      });

      test('local $stage timeout remains a transport failure with no mutation replay', () async {
        await f.connect();
        const error = RemoteRpcException('RPC_TIMEOUT', 'deadline', isLocal: true, retryable: true);
        f.rpc.handler = (method, params) {
          if (method == 'workspace.upload.$stage') throw error;
          return f.rpc.reply(method, params);
        };
        await expectLater(
          f.carrier.uploadWorkspaceFile('session-1', [1], name: 'file.bin'),
          throwsA(isA<DshTransportException>().having((e) => e.cause, 'cause', same(error))),
        );
        expect(f.rpc.methods.where((m) => m == 'workspace.upload.$stage'), hasLength(1));
        _expectAbortScope(f.rpc);
        expect(f.opens, 1);
      });
    }

    test('abort cannot delay or replace the original failure', () async {
      await f.connect();
      final abort = Completer<Object?>();
      f.rpc.handler = (method, params) {
        if (method == 'workspace.upload.open') throw const RemoteRpcException('UPLOAD_LIMIT', 'Host limit');
        if (method == 'workspace.upload.abort') return abort.future;
        return f.rpc.reply(method, params);
      };
      await expectLater(
        f.carrier.uploadWorkspaceFile('session-1', const [], name: 'file'),
        throwsA(_code('UPLOAD_LIMIT')),
      );
      expect(abort.isCompleted, isFalse);
      abort.complete({'aborted': true});
    });

    for (final stage in ['open', 'chunk', 'commit']) {
      test('late $stage reply cannot continue or publish into a replacement connection', () async {
        await f.connect();
        final arrived = Completer<void>();
        final reply = Completer<Object?>();
        final oldRpc = f.rpc;
        oldRpc.handler = (method, params) {
          if (method == 'workspace.upload.$stage') {
            arrived.complete();
            return reply.future;
          }
          return oldRpc.reply(method, params);
        };
        final upload = f.carrier.uploadWorkspaceFile('session-1', [1], name: 'file.bin');
        final failure = expectLater(upload, throwsA(isA<DshTransportException>()));
        await arrived.future;
        f.carrier.reconnect();
        await f.carrier.openLink(const MuxOptions());
        expect(f.opens, 2);
        final params = oldRpc.calls.last.$2;
        reply.complete(oldRpc.reply('workspace.upload.$stage', params));
        await failure;
        expect(f.rpc, isNot(same(oldRpc)));
        expect(f.rpc.calls, isEmpty);
        _expectAbortScope(oldRpc);
      });
    }
  });

  test('real encrypted tunnel uses only top-level upload RPCs with exact wire params', () async {
    final server = await FakeRemoteServer.start();
    final host = await FakeRemoteHost.start(server);
    final account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
    addTearDown(() async {
      await account.close();
      await host.close();
      await server.close();
      expect(server.protocolErrors, isEmpty);
    });
    host.capabilities.add('workspace.upload.v1');
    final protocol = _UploadRpc();
    host.workspaceUpload = (method, params) async => protocol.call(method, params);
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final client = await account.connectHost((await account.listHosts()).single);
    final carrier = client.remoteCarrier!;
    expect(carrier.supportsWorkspaceUpload, isTrue);
    final result = await carrier.uploadWorkspaceFile('session-1', [97, 98, 99], name: 'report.txt');
    expect(result.path, './report.txt');
    expect(result.bytes, 3);
    expect(host.rpcMethods, [
      'harness.transport.describe',
      'harness.remote.stream.open',
      'workspace.upload.open',
      'workspace.upload.chunk',
      'workspace.upload.commit',
    ]);
    expect(protocol.calls[1].$2['data'], 'YWJj');
    expect(host.calls, isEmpty, reason: 'workspace uploads must not use Gateway or fileUploads/upload');
  });
}

void _expectAbortScope(_UploadRpc rpc) {
  expect(rpc.methods.last, 'workspace.upload.abort');
  final opened = rpc.calls.first.$2;
  expect(rpc.calls.last.$2, {'sessionId': opened['sessionId'], 'uploadId': opened['uploadId']});
}

class _Fixture {
  _Fixture({RemoteTransportMode? path, String transport = 'relay'}) {
    session = RemoteHostSession(
      rpc: rpc,
      capabilities: ['harness.remote.v3', 'workspace.upload.v1'],
      transport: transport,
      networkDiagnostics: path == null
          ? null
          : RemoteNetworkDiagnostics(transportMode: path, observedAt: DateTime.now()),
    );
    carrier = RemoteTunnelCarrier(
      hostId: 'host-1',
      healthInterval: const Duration(days: 1),
      tracer: traces.add,
      open: (_) async {
        opens++;
        if (opens > 1) {
          rpc = _UploadRpc();
          session = RemoteHostSession(rpc: rpc, capabilities: ['harness.remote.v3', 'workspace.upload.v1']);
        }
        return session;
      },
    );
  }

  _UploadRpc rpc = _UploadRpc();
  late RemoteHostSession session;
  late RemoteTunnelCarrier carrier;
  final List<DshTraceEntry> traces = [];
  int opens = 0;

  Future<void> connect() async {
    await carrier.openLink(const MuxOptions());
  }
}

class _UploadRpc implements RemoteRpcClient {
  final calls = <(String, Map<String, Object?>)>[];
  FutureOr<Object?> Function(String, Map<String, Object?>)? handler;
  String? finalName;
  int chunkBytes = _chunkBytes;
  String? _sessionId;
  String? _uploadId;
  String? _name;
  int _totalBytes = 0;
  int _receivedBytes = 0;
  final _done = Completer<SecureChannelClosed>();

  List<String> get methods => calls.map((c) => c.$1).toList();

  @override
  bool get isClosed => _done.isCompleted;

  @override
  Future<SecureChannelClosed> get done => _done.future;

  @override
  Future<Object?> call(String method, Object? params, {Duration? timeout}) async {
    final map = (params! as Map).cast<String, Object?>();
    calls.add((method, map));
    return handler == null ? reply(method, map) : await handler!(method, map);
  }

  Object? reply(String method, Map<String, Object?> params) {
    if (method == 'workspace.upload.abort') {
      expect(params.keys, unorderedEquals(['sessionId', 'uploadId']));
      return {'aborted': true};
    }
    if (method == 'workspace.upload.open') {
      expect(params.keys, unorderedEquals(['sessionId', 'uploadId', 'name', 'totalBytes']));
      expect(params['uploadId'], matches(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'));
      _sessionId = params['sessionId']! as String;
      _uploadId = params['uploadId']! as String;
      _name = params['name']! as String;
      _totalBytes = params['totalBytes']! as int;
      return {'uploadId': _uploadId, 'chunkBytes': chunkBytes};
    }
    expect(params['sessionId'], _sessionId);
    expect(params['uploadId'], _uploadId);
    if (method == 'workspace.upload.chunk') {
      expect(params.keys, unorderedEquals(['sessionId', 'uploadId', 'offset', 'data']));
      expect(params['offset'], _receivedBytes);
      final data = params['data']! as String;
      final decoded = base64Decode(data);
      expect(base64Encode(decoded), data);
      expect(decoded.length, inInclusiveRange(1, chunkBytes));
      _receivedBytes += decoded.length;
      expect(_receivedBytes, lessThanOrEqualTo(_totalBytes));
      return {'uploadId': _uploadId, 'receivedBytes': _receivedBytes};
    }
    expect(method, 'workspace.upload.commit');
    expect(params.keys, unorderedEquals(['sessionId', 'uploadId']));
    expect(_receivedBytes, _totalBytes);
    final name = finalName ?? _name;
    return {'name': name, 'path': './$name', 'bytes': _totalBytes};
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete(const SecureChannelClosed('CLIENT_CLOSED', 'test closed'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Oversize rejection must inspect only the length, not allocate/read file data.
class _LengthOnlyBytes extends ListBase<int> {
  _LengthOnlyBytes(this.length);

  @override
  int length;

  @override
  int operator [](int index) => throw StateError('oversize bytes must not be read');

  @override
  void operator []=(int index, int value) => throw UnsupportedError('read only');
}
