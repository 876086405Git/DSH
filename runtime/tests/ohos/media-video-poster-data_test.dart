import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/media/video.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The consumers, HTTP transport, materialization, file I/O and channel codec
// are real. A finite local Session service and the platform poster encoder are
// explicit boundaries. Marker bytes below are not actual MP4 or JPEG media.
class _HttpBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _mediaChannel = MethodChannel('dsh/media_video');
const _filesChannel = MethodChannel('test/media-poster-files');
const _session = 'poster-session';

class _Rig {
  _Rig(this.root, this.server, this.platform, this.useDefaultChannel);
  final Directory root;
  final HttpServer server;
  final String platform;
  final bool useDefaultChannel;
  final requests = <Map<String, Object?>>[];
  final posterCalls = <Map<String, Object?>>[];
  final serviceErrors = <Object>[];
  final resolvedPaths = <String>[];
  late final StreamSubscription<HttpRequest> serving;
  late final DshClient client;
  late final ProviderContainer container;
  late final ArtifactFiles files;
  late final MediaVideoChannel video;
  Future<Uint8List?> Function(int call, Uint8List bytes)? encode;

  static Future<_Rig> create(String platform, {bool useDefaultChannel = false}) async {
    final root = await Directory.systemTemp.createTemp('media-poster-1325-');
    await Directory('${root.path}/source').create();
    await Directory('${root.path}/cache').create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rig = _Rig(root, server, platform, useDefaultChannel);
    rig.serving = server.listen(rig.serve, onError: (Object error) => rig.serviceErrors.add(error));
    rig.client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    rig.container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(platform)]);
    rig.video = useDefaultChannel ? const MediaVideoChannel() : rig.container.read(mediaVideoChannelProvider);
    rig.files = ArtifactFiles(
      connection: HostConnection(client: rig.client, isLocal: true, hostId: 'host-1325'),
      channel: const FilesChannel(_filesChannel),
      cacheRoot: () async => Directory('${root.path}/cache'),
      operatingSystem: platform,
    );
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_filesChannel, (call) async {
      expect(call.method, 'resolveGuest');
      final path = (call.arguments as Map)['path'] as String;
      rig.resolvedPaths.add(path);
      return rig.sourceFor(path).path;
    });
    messenger.setMockMethodCallHandler(_mediaChannel, (call) async {
      expect(call.method, 'poster');
      final path = (call.arguments as Map)['path'] as String;
      final bytes = await File(path).readAsBytes();
      rig.posterCalls.add({'path': path, 'inputBytes': bytes.toList()});
      final encode = rig.encode;
      return encode == null ? bytes : await encode(rig.posterCalls.length, bytes);
    });
    addTearDown(rig.close);
    return rig;
  }

  String path(int index) => '/workspaces/media-1325/clip-$index.mp4';
  MediaItem item(int index) => MediaItem(path: path(index), mime: 'video/mp4');
  Artifact artifact(int index) => Artifact(path: path(index), origin: ArtifactOrigin.linked, turn: 0);
  File sourceFor(String logicalPath) => File('${root.path}/source/${logicalPath.split('/').last}');

  Future<void> write(int index, List<int> bytes) async {
    await sourceFor(path(index)).writeAsBytes(bytes, flush: true);
  }

  Future<File> materialize(int index) => files.materialize(_session, artifact(index));

  Future<ImageProvider?> seed(int index, File file) =>
      cacheMediaVideoThumbnail(files, video, _session, item(index), materialized: file);

  Future<void> serve(HttpRequest request) async {
    try {
      expect(request.method, 'POST');
      final input = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      final method = input['method'] as String;
      expect(request.uri.path, '/api/$method');
      final args = Map<String, Object?>.from((input['payload'] as Map)['args'] as Map);
      expect(args['workspaceFileScopeId'], _session);
      final source = sourceFor(args['path'] as String);
      final stat = await source.stat();
      final bytes = await source.readAsBytes();
      final version = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
      final value = <String, Object?>{'absolutePath': args['path'], 'version': version, 'bytes': bytes.length};
      if (method == 'workspaceFiles/readBytes') {
        value.addAll({'offset': 0, 'data': bytes, 'eof': true});
      } else {
        expect(method, 'workspaceFiles/stat');
      }
      requests.add({'method': method, 'path': args['path'], 'version': version});
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'type': 'server-response',
          'rpcId': input['rpcId'],
          'result': {'ok': true, 'value': value},
        }),
      );
      await request.response.close();
    } catch (error) {
      serviceErrors.add(error);
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('local Session boundary failed');
      await request.response.close();
    }
  }

  Future<void> close() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_mediaChannel, null);
    messenger.setMockMethodCallHandler(_filesChannel, null);
    container.dispose();
    await client.close();
    await server.close(force: true);
    await serving.cancel();
    await root.delete(recursive: true);
    expect(serviceErrors, isEmpty, reason: 'boundary setup failures are not cache failures');
  }
}

void main() {
  _HttpBinding();

  test('actual OH provider refreshes an explicitly materialized newer version', () async {
    final rig = await _Rig.create('ohos');
    await rig.write(0, [11, 12, 13, 14]);
    final firstFile = await rig.materialize(0);
    final firstVersion = File('${firstFile.parent.path}/.version').readAsStringSync();
    final first = await rig.seed(0, firstFile) as MemoryImage;
    expect(first.bytes, [11, 12, 13, 14]);
    await rig.write(0, [21, 22, 23, 24, 25]);
    final newerFile = await rig.materialize(0);
    final newerVersion = File('${newerFile.parent.path}/.version').readAsStringSync();
    expect(newerFile.path, firstFile.path);
    expect(newerVersion, isNot(firstVersion));
    expect(await newerFile.readAsBytes(), [21, 22, 23, 24, 25]);
    final newer = await rig.seed(0, newerFile) as MemoryImage;
    // Retained JSON trace binds the actual file update to channel requests.
    // ignore: avoid_print
    print(
      '1325-TRACE ${jsonEncode({'platform': rig.platform, 'oldVersion': firstVersion, 'newVersion': newerVersion, 'samePosterObject': identical(first, newer), 'posterCalls': rig.posterCalls, 'newPosterBytes': newer.bytes.toList(), 'fileRpcCount': rig.requests.length})}',
    );
    expect(rig.posterCalls, hasLength(2));
    expect(newer.bytes, [21, 22, 23, 24, 25]);
    expect(newer, isNot(same(first)));
    // Deliberate cost: explicit reopen refreshes even an unchanged version.
    final again = await rig.seed(0, newerFile) as MemoryImage;
    expect(again.bytes, newer.bytes);
    expect(rig.posterCalls, hasLength(3));
  });

  for (final useDefault in [false, true]) {
    test(
      useDefault
          ? 'default channel retains the original poster cache'
          : 'actual Android provider retains the original poster cache',
      () async {
        final rig = await _Rig.create('android', useDefaultChannel: useDefault);
        await rig.write(0, [1, 2, 3]);
        final first = await rig.seed(0, await rig.materialize(0));
        await rig.write(0, [4, 5, 6, 7]);
        final newerFile = await rig.materialize(0);
        expect(await newerFile.readAsBytes(), [4, 5, 6, 7]);
        final again = await rig.seed(0, newerFile);
        expect(again, same(first));
        expect((again as MemoryImage).bytes, [1, 2, 3]);
        expect(rig.posterCalls, hasLength(1));
        expect(rig.resolvedPaths, hasLength(2));
        expect(rig.requests, isEmpty);
      },
    );
  }

  test('OH scrolling without materialized input neither downloads nor decodes again', () async {
    final rig = await _Rig.create('ohos');
    await rig.write(0, [1, 2, 3]);
    final first = await mediaVideoThumbnail(rig.files, rig.video, _session, rig.item(0));
    expect(first, isA<MemoryImage>());
    final rpcCount = rig.requests.length;
    expect(rpcCount, greaterThan(0));
    expect(rig.posterCalls, hasLength(1));
    await rig.write(0, [4, 5, 6, 7]);
    final again = await mediaVideoThumbnail(rig.files, rig.video, _session, rig.item(0));
    expect(again, same(first));
    expect(rig.requests, hasLength(rpcCount));
    expect(rig.posterCalls, hasLength(1));
  });

  test('OH replacement at 24 cached keys does not evict another key', () async {
    final rig = await _Rig.create('ohos');
    final images = <ImageProvider?>[];
    for (var index = 0; index < 24; index++) {
      await rig.write(index, [index, 1]);
      images.add(await rig.seed(index, await rig.materialize(index)));
    }
    expect(rig.posterCalls, hasLength(24));
    // Replace a non-oldest key: a naive full-cache eviction would lose key 0.
    await rig.write(7, [7, 2, 3]);
    final changed = await rig.seed(7, await rig.materialize(7)) as MemoryImage;
    expect(changed.bytes, [7, 2, 3]);
    expect(rig.posterCalls, hasLength(25));
    final rpcCount = rig.requests.length;
    expect(await mediaVideoThumbnail(rig.files, rig.video, _session, rig.item(0)), same(images.first));
    expect(rig.requests, hasLength(rpcCount));
    expect(rig.posterCalls, hasLength(25));
  });

  test('an older failed poster future cannot remove the newer OH replacement', () async {
    final rig = await _Rig.create('ohos');
    final entered = Completer<void>();
    final oldResult = Completer<Uint8List?>();
    addTearDown(() {
      if (!oldResult.isCompleted) oldResult.complete(null);
    });
    rig.encode = (call, bytes) async {
      if (call != 1) return bytes;
      entered.complete();
      return oldResult.future;
    };
    await rig.write(0, [1, 2]);
    final old = rig.seed(0, await rig.materialize(0));
    await entered.future.timeout(const Duration(seconds: 5));
    await rig.write(0, [3, 4, 5]);
    final next = rig.seed(0, await rig.materialize(0));
    oldResult.completeError(PlatformException(code: 'timeout'));
    expect(await old, isNull);
    final image = await next.timeout(const Duration(seconds: 5));
    expect(image, isA<MemoryImage>());
    expect((image as MemoryImage).bytes, [3, 4, 5]);
    expect(rig.posterCalls, hasLength(2));
    expect(await mediaVideoThumbnail(rig.files, rig.video, _session, rig.item(0)), same(image));
    expect(rig.posterCalls, hasLength(2));
  });
}
