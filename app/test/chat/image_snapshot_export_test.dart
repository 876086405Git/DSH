import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/image_snapshots.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('test/image-snapshot-export');
const _session = 'session';

Artifact _image(int turn, {bool snapshot = true, String path = '/workspace/chart.png'}) =>
    Artifact(path: path, origin: ArtifactOrigin.linked, turn: turn, snapshotImage: snapshot);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory support;
  late Directory cache;
  late File source;
  late DshClient client;
  late ImageSnapshots snapshots;
  final calls = <({String action, String path, String name, String mime, List<int> bytes})>[];
  Future<void> Function(String method, String path)? native;

  Future<void> record(String action, String path, String name, String mime) async {
    calls.add((action: action, path: path, name: name, mime: mime, bytes: await File(path).readAsBytes()));
    await native?.call(action, path);
  }

  ArtifactFiles files({String os = 'ohos'}) => ArtifactFiles(
    connection: HostConnection(client: client, hostId: 'local', isLocal: true),
    channel: const FilesChannel(_channel),
    operatingSystem: os,
    cacheRoot: () async => cache,
    snapshots: snapshots,
    share: (params) async {
      expect(params.files, hasLength(1));
      final file = params.files!.single;
      await record('share', file.path, params.fileNameOverrides!.single, file.mimeType!);
    },
  );

  Future<List<Directory>> exports() async {
    final entries = await cache.list(followLinks: false).toList();
    return entries
        .whereType<Directory>()
        .where((entry) => entry.path.split('/').last.startsWith('image-snapshot-export-'))
        .toList();
  }

  Future<void> overwrite(String text) async {
    await source.writeAsString(text, flush: true);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('snapshot-export-');
    support = await Directory('${root.path}/support').create();
    cache = await Directory('${root.path}/cache').create();
    final workspace = await Directory('${root.path}/workspace').create();
    source = File('${workspace.path}/chart.png');
    await overwrite('old image');
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
    snapshots = ImageSnapshots(root: () async => support);
    calls.clear();
    native = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      if (call.method == 'resolveGuest') return source.path;
      if (call.method != 'open' && call.method != 'saveToDownloads') {
        throw StateError('Unexpected native method ${call.method}');
      }
      await record(call.method, args['path'] as String, args['name'] as String, args['mime'] as String);
      if (call.method == 'saveToDownloads') return 'file://downloads/${args['name']}';
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    await client.close();
    await root.delete(recursive: true);
  });

  test('Harmony open save and share get named cache copies of the old durable snapshot', () async {
    final artifacts = files();
    final old = _image(1);
    final durable = await artifacts.materialize(_session, old);
    expect(durable.path, startsWith('${support.path}/image-snapshots/'));
    await overwrite('current image');
    final nativeCopies = <File>[];
    native = (method, path) async {
      expect(path, startsWith('${cache.path}/image-snapshot-export-'));
      expect(path, isNot(startsWith('${support.path}/')));
      expect(File(path).uri.pathSegments.last, 'chart.png');
      // The real Harmony handlers copy before settling their Dart Future.
      nativeCopies.add(await File(path).copy('${root.path}/native-${nativeCopies.length}.png'));
    };

    await artifacts.open(_session, old, chooser: true);
    expect(await artifacts.saveToDownloads(_session, old), 'file://downloads/chart.png');
    await artifacts.share(_session, old);

    expect(calls.map((call) => call.action), ['open', 'saveToDownloads', 'share']);
    for (final call in calls) {
      expect(call.name, 'chart.png');
      expect(call.mime, 'image/png');
      expect(call.bytes, utf8.encode('old image'));
      expect(await File(call.path).exists(), isFalse);
    }
    for (final file in nativeCopies) {
      expect(await file.readAsString(), 'old image', reason: 'external readers keep the native copy, not the bridge');
    }
    expect(await exports(), isEmpty);
    expect(await durable.readAsString(), 'old image');
    expect(await source.readAsString(), 'current image');
  });

  test('concurrent turns own distinct exports and never overwrite an older in-flight input', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    native = (method, path) async {
      if (calls.length == 1) {
        expect(await File(path).exists(), isTrue);
        expect(await File(path).parent.exists(), isTrue);
        expect(await exports(), hasLength(1));
        entered.complete();
        await release.future;
      }
    };
    final pending = files().open(_session, _image(1));
    late String first;
    try {
      await Future.any([
        entered.future,
        pending.then<void>((_) => throw StateError('Native boundary was not reached')),
      ]);
      first = calls.first.path;
      await overwrite('new image');
      await files().open(_session, _image(2));
      final next = calls.last.path;
      expect(next, isNot(first));
      expect(calls.last.bytes, utf8.encode('new image'));
      expect(await File(next).exists(), isFalse);
      expect(await File(first).readAsString(), 'old image');
      expect(await exports(), hasLength(1));
    } finally {
      release.complete();
      await pending;
    }
    expect(await File(first).exists(), isFalse);
    await files().share(_session, _image(1));
    expect(calls.last.bytes, utf8.encode('old image'));
    expect(await exports(), isEmpty);
  });

  test('repeated operations do not accumulate exports and preserve a safe image filename', () async {
    final image = _image(1, path: '/workspace/chart:old.png');
    for (var i = 0; i < 12; i++) {
      await files().open(_session, image);
      expect(File(calls.last.path).uri.pathSegments.last, 'chart_old.png');
      expect(calls.last.bytes, utf8.encode('old image'));
      expect(await exports(), isEmpty);
    }
  });

  for (final action in ['open', 'saveToDownloads', 'share']) {
    test('failed $action removes its bridge directory and leaves history retryable', () async {
      native = (method, path) async {
        expect(await File(path).exists(), isTrue);
        expect(await exports(), hasLength(1));
        throw PlatformException(code: 'failed');
      };
      Future<void> invoke() async {
        final artifacts = files();
        switch (action) {
          case 'open':
            await artifacts.open(_session, _image(1));
            break;
          case 'saveToDownloads':
            await artifacts.saveToDownloads(_session, _image(1));
            break;
          case 'share':
            await artifacts.share(_session, _image(1));
            break;
        }
      }

      await expectLater(invoke(), throwsA(isA<PlatformException>()));
      expect(await exports(), isEmpty);
      native = null;
      await overwrite('new source');
      await invoke();
      expect(calls.last.bytes, utf8.encode('old image'));
      expect(await exports(), isEmpty);
    });
  }

  test('missing durable history never exports the current workspace image', () async {
    snapshots = ImageSnapshots(root: () async => support, maxBytes: 9);
    await files().materialize(_session, _image(1));
    await overwrite('new image');
    await files().materialize(_session, _image(2));
    await expectLater(files().open(_session, _image(1)), throwsA(isA<ImageSnapshotMissing>()));
    expect(calls, isEmpty);
    expect(await exports(), isEmpty);
  });

  test('Android snapshot actions still use the durable file directly', () async {
    final artifacts = files(os: 'android');
    await artifacts.open(_session, _image(1));
    await artifacts.saveToDownloads(_session, _image(1));
    await artifacts.share(_session, _image(1));
    expect(calls, hasLength(3));
    for (final call in calls) {
      expect(call.path, startsWith('${support.path}/image-snapshots/'));
      expect(await File(call.path).readAsString(), 'old image');
    }
    expect(await exports(), isEmpty);
  });

  test('Harmony live preview and non-image actions do not enter snapshot exports', () async {
    await files().open(_session, _image(1, snapshot: false));
    final document = Artifact(
      path: '/workspace/report.pdf',
      origin: ArtifactOrigin.linked,
      turn: 1,
      snapshotImage: true,
    );
    await files().saveToDownloads(_session, document);
    expect(calls.map((call) => call.path), [source.path, source.path]);
    expect(await exports(), isEmpty);
  });
}
