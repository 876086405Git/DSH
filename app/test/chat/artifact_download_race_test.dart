import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const _artifact = Artifact(path: '/home/me/a.png', origin: ArtifactOrigin.linked, turn: 1);

class _Carrier extends DshCarrier {
  String version = 'v1';
  int? size = 4;
  int stats = 0;
  final requests = <Completer<RpcResult>>[];
  final requestSessions = <String>[];
  String? drainSession;
  int closeCalls = 0;
  void Function(int index, String session)? onRead;
  final entered = List.generate(8, (_) => Completer<void>());

  @override
  String get kind => 'memory';
  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'workspaceFiles/stat') {
      stats++;
      return RpcOk({'absolutePath': args['path'], 'version': version, 'bytes': size});
    }
    if (endpoint == 'workspaceFiles/readBytes') {
      final request = Completer<RpcResult>();
      requests.add(request);
      final session = args['workspaceFileScopeId'] as String;
      requestSessions.add(session);
      entered[requests.length - 1].complete();
      if (closeCalls > 0) {
        request.completeError(const DshClosedException('carrier closed'));
      } else if (session == drainSession) {
        request.complete(const RpcOk({'data': <int>[], 'eof': true}));
      }
      onRead?.call(requests.length - 1, session);
      return request.future;
    }
    return const RpcError(DshRemoteException('gateway/not-found', 'missing'));
  }

  void succeed(int index, {List<int> bytes = const [1, 2, 3, 4], String responseVersion = 'v1', bool eof = true}) {
    requests[index].complete(
      RpcOk({
        'absolutePath': _artifact.path,
        'version': responseVersion,
        'bytes': bytes.length,
        'offset': 0,
        'data': bytes,
        'eof': eof,
      }),
    );
  }

  void fail(int index) {
    requests[index].complete(const RpcError(DshRemoteException('workspace-file/not-allowed', 'synthetic failure')));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<void> close() async {
    closeCalls++;
  }
}

class _Rig {
  _Rig(this.cache);
  final Directory cache;
  final carrier = _Carrier();
  late final client = DshClient.withCarrier(carrier);
  late final files = forHost('host-a');

  ArtifactFiles forHost(String host) => ArtifactFiles(
    connection: HostConnection(client: client, label: host, isLocal: false, hostId: host),
    channel: const FilesChannel(),
    cacheRoot: () async => cache,
  );

  Future<void> noStagingLeft() async {
    final staging = await cache
        .list(recursive: true)
        .where((entry) => entry.path.split('/').last.startsWith('.part-'))
        .toList();
    expect(staging, isEmpty);
  }
}

Future<Object> _observed(Future<Object> future) =>
    future.then<Object>((value) => value, onError: (Object error, StackTrace _) => error);

const _noSpace = FileSystemException('write failed', '', OSError('No space left', 28));

class _FailingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      throw _noSpace;
    }
  }

  @override
  Future<void> close() async {}
}

class _FailingHandle implements RandomAccessFile {
  _FailingHandle(this.file);
  final RandomAccessFile file;
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async => throw _noSpace;
  @override
  Future<void> close() => file.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultFile implements File {
  _FaultFile(this.file, {required this.openFailure, required this.makeFile});
  final File file;
  final bool openFailure;
  final File Function(String) makeFile;
  File get missing => makeFile('${file.path}.missing-parent/clip');
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      openFailure ? missing.openWrite(mode: mode, encoding: encoding) : IOSink(_FailingConsumer());
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      openFailure ? await missing.open(mode: mode) : _FailingHandle(await file.open(mode: mode));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Rig rig;
  setUp(() async {
    rig = _Rig(await Directory.systemTemp.createTemp('artifact-download-test-'));
  });
  tearDown(() async {
    await rig.client.close();
    await rig.cache.delete(recursive: true);
  });

  test('a warm chat image checks the remote version once and still reports the inline size limit', () async {
    final download = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[0].future;
    rig.carrier.succeed(0);
    final cached = await download;

    final reader = ArtifactImageReader(rig.files);
    final previous = rig.carrier.stats;
    final image = await reader.read('s1', _artifact.path) as RasterImage;
    expect((image.provider as FileImage).file.path, cached.path);
    expect(rig.carrier.stats - previous, 1);
    expect(rig.carrier.requests, hasLength(1));

    rig.carrier.size = maxMarkdownImageBytes + 1;
    await expectLater(
      reader.read('s1', _artifact.path),
      throwsA(isA<ImageTooLarge>().having(imageErrorText, 'message', appL10n.chatImageTooLarge)),
    );
    expect(rig.carrier.requests, hasLength(1));
  });

  for (final thumbnailFirst in [true, false]) {
    test('thumbnail and preview both finish, thumbnailFirst=$thumbnailFirst', () async {
      final progress = <double?>[];
      final thumbnail = rig.files.thumbnail('s1', _artifact.path);
      await rig.carrier.entered[0].future;
      final preview = rig.files.materialize('s1', _artifact, onProgress: progress.add);
      await rig.carrier.entered[1].future;
      // The real thumbnail entry and preview download overlap, without decoding an image.
      if (thumbnailFirst) {
        rig.carrier.succeed(0);
        await thumbnail;
        rig.carrier.succeed(1);
      } else {
        rig.carrier.succeed(1);
        await preview;
        rig.carrier.succeed(0);
      }
      final image = await thumbnail as FileImage;
      final file = await preview;
      expect(image.file.path, file.path);
      expect(await image.file.readAsBytes(), [1, 2, 3, 4]);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      expect(progress.first, 0);
      expect(progress.last, 1);
      await rig.noStagingLeft();
    });
  }

  test('a failed download only removes its own staging, leaving the peer usable', () async {
    final failed = _observed(rig.files.materialize('s1', _artifact));
    await rig.carrier.entered[0].future;
    final peer = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[1].future;
    rig.carrier.fail(0);
    expect(await failed, isA<DshRemoteException>());
    rig.carrier.succeed(1);
    expect(await (await peer).readAsBytes(), [1, 2, 3, 4]);
    await rig.noStagingLeft();
  });

  test('failure can be retried, and a successful retry is reused from cache', () async {
    final failed = _observed(rig.files.materialize('s1', _artifact));
    await rig.carrier.entered[0].future;
    rig.carrier.fail(0);
    expect(await failed, isA<DshRemoteException>());
    await rig.noStagingLeft();
    final retry = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[1].future;
    rig.carrier.succeed(1);
    final file = await retry;
    final cached = await rig.files.materialize('s1', _artifact);
    expect(cached.path, file.path);
    expect(await cached.readAsBytes(), [1, 2, 3, 4]);
    expect(rig.carrier.requests.length, 2);
    await rig.noStagingLeft();
  });

  test('different Hosts keep separate cache files for the same session and path', () async {
    final first = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[0].future;
    final second = rig.forHost('host-b').materialize('s1', _artifact);
    await rig.carrier.entered[1].future;
    rig.carrier.succeed(0, bytes: [1, 1, 1, 1]);
    rig.carrier.succeed(1, bytes: [2, 2, 2, 2]);
    final a = await first;
    final b = await second;
    expect(a.path, isNot(b.path));
    expect(await a.readAsBytes(), [1, 1, 1, 1]);
    expect(await b.readAsBytes(), [2, 2, 2, 2]);
    await rig.noStagingLeft();
  });

  test('a stricter caller keeps its byte limit during overlap and after a cache hit', () async {
    rig.carrier.size = null;
    final strict = _observed(rig.files.materialize('s1', _artifact, maxBytes: 3));
    await rig.carrier.entered[0].future;
    final wider = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[1].future;
    rig.carrier.succeed(0);
    expect(await strict, isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/too-large'));
    rig.carrier.succeed(1);
    expect(await (await wider).readAsBytes(), [1, 2, 3, 4]);
    await expectLater(
      rig.files.materialize('s1', _artifact, maxBytes: 3),
      throwsA(isA<ArtifactError>().having((e) => e.code, 'code', 'workspace-file/too-large')),
    );
    expect(rig.carrier.requests.length, 2);
    await rig.noStagingLeft();
  });

  test('overlapping versions publish matching bytes and marker, then refresh as needed', () async {
    final old = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[0].future;
    rig.carrier.version = 'v2';
    final newer = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[1].future;
    rig.carrier.succeed(1, bytes: [2, 2, 2, 2], responseVersion: 'v2');
    await newer;
    rig.carrier.succeed(0, bytes: [1, 1, 1, 1]);
    final last = await old;
    expect(await last.readAsBytes(), [1, 1, 1, 1]);
    expect(await File('${last.parent.path}/.version').readAsString(), 'v1');
    final refresh = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[2].future;
    rig.carrier.succeed(2, bytes: [2, 2, 2, 2], responseVersion: 'v2');
    final current = await refresh;
    expect(await current.readAsBytes(), [2, 2, 2, 2]);
    expect(await File('${current.parent.path}/.version').readAsString(), 'v2');
    await rig.files.materialize('s1', _artifact);
    expect(rig.carrier.requests.length, 3);
    await rig.noStagingLeft();
  });
  for (final openFailure in [false, true]) {
    test('async ${openFailure ? 'open' : 'write'} failure stays in materialize and leaves its peer alive', () async {
      // The peer already owns a staging directory, and shares the real DshClient.
      final peer = _observed(rig.files.materialize('peer', _artifact));
      await rig.carrier.entered[0].future;
      final outer = Zone.current;
      File realFile(String path) => outer.run(() => File(path));
      final zoneErrors = <Object>[];
      final firstFailure = Completer<void>();
      final finished = Completer<Object>();
      void signal() {
        if (!firstFailure.isCompleted) firstFailure.complete();
      }

      runZonedGuarded(
        () => IOOverrides.runZoned(
          () async {
            try {
              finished.complete(await rig.files.materialize('s1', _artifact));
            } catch (error) {
              finished.complete(error);
            } finally {
              signal();
            }
          },
          createFile: (path) {
            final file = realFile(path);
            return path.split('/').any((part) => part.startsWith('.part-'))
                ? _FaultFile(file, openFailure: openFailure, makeFile: realFile)
                : file;
          },
        ),
        (error, _) {
          zoneErrors.add(error);
          signal();
        },
      );
      if (!openFailure) {
        await rig.carrier.entered[1].future;
        rig.carrier.succeed(1, bytes: [1, 2], eof: false);
      }
      await firstFailure.future;
      // Old code can be awaiting a second RPC after losing the sink error to the zone.
      // Settle every outstanding/future window deterministically before asserting.
      rig.carrier.drainSession = 's1';
      for (var i = 1; i < rig.carrier.requests.length; i++) {
        if (rig.carrier.requestSessions[i] == 's1' && !rig.carrier.requests[i].isCompleted) {
          rig.carrier.succeed(i, bytes: const []);
        }
      }
      final failure = await finished.future;
      final filesBeforePeer = await rig.cache.list(recursive: true).where((f) => f is File).toList();
      final stagesBeforePeer = await rig.cache
          .list(recursive: true)
          .where((f) => f is Directory && f.path.split('/').last.startsWith('.part-'))
          .toList();
      // The peer must issue a fresh window after the failure has fully settled.
      final peerWindow = Completer<int>();
      rig.carrier.onRead = (index, session) {
        if (session == 'peer' && !peerWindow.isCompleted) peerWindow.complete(index);
      };
      rig.carrier.succeed(0, bytes: [1, 2], eof: false);
      final nextPeerIndex = await Future.any<int?>([peerWindow.future, peer.then((_) => null)]);
      if (nextPeerIndex != null && !rig.carrier.requests[nextPeerIndex].isCompleted) {
        rig.carrier.succeed(nextPeerIndex, bytes: [3, 4]);
      }
      final successful = await peer;
      final bytes = successful is File ? await successful.readAsBytes() : null;
      await rig.noStagingLeft();
      expect(zoneErrors, isEmpty, reason: 'Every async file error belongs to the materialize Future');
      if (openFailure) {
        expect(
          failure,
          isA<FileSystemException>()
              .having((e) => e.osError?.errorCode, 'errno', 2)
              .having((e) => e.path, 'path', endsWith('.missing-parent/clip')),
        );
      } else {
        expect(failure, same(_noSpace), reason: 'close must not replace the original ENOSPC');
      }
      expect(
        rig.carrier.requestSessions.where((s) => s == 's1'),
        hasLength(openFailure ? 0 : 1),
        reason: 'All requests are recorded, including drain and after the failure Future',
      );
      expect(rig.carrier.closeCalls, 0, reason: 'A file failure must not close the shared client');
      expect(nextPeerIndex, isNotNull);
      expect(rig.carrier.requestSessions.where((s) => s == 'peer'), hasLength(2));
      expect(successful, isA<File>());
      expect(
        filesBeforePeer.where((f) => !f.path.contains('/.part-')),
        isEmpty,
        reason: 'No target or version marker is published by the failed download',
      );
      expect(stagesBeforePeer, hasLength(1), reason: 'Only the peer staging survives failure cleanup');
      expect(bytes, [1, 2, 3, 4]);
      expect(await File('${(successful as File).parent.path}/.version').readAsString(), 'v1');
    });
  }

  test('a real zero-byte eof publishes an empty file and matching marker', () async {
    rig.carrier.size = 0;
    final download = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[0].future;
    rig.carrier.succeed(0, bytes: const []);
    final file = await download;
    expect(await file.length(), 0);
    expect(await File('${file.parent.path}/.version').readAsString(), 'v1');
    expect(rig.carrier.requests, hasLength(1));
    await rig.noStagingLeft();
  });
}
