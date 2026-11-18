import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

// Real Dart consumer, HTTP carrier and cache I/O. The HTTP server is an
// explicit Session-file-service fixture, not a Native grant or a full Host.
class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _paths = MethodChannel('plugins.flutter.io/path_provider');
const _files = MethodChannel('test/ohos-workspace-materialize');
const _logicalPath = '/workspaces/5a34caf8-df40-447f-9453-0b734ce1fdd4/materialize-marker.txt';
const _sessionId = 'session-941';
const _version = 'selected-file-version-one';
const _bytes = <int>[65, 66, 228, 184, 173, 230, 150, 135, 67, 68, 10];

void main() {
  _LoopbackBinding();
  test('OH local logical artifact materializes through its Session byte service', () async {
    final root = await Directory.systemTemp.createTemp('ohos-materialize-');
    final source = File('${root.path}/source/materialize-marker.txt');
    await source.parent.create();
    await source.writeAsBytes(_bytes, flush: true);
    final sourceBefore = await source.stat();
    final cache = await Directory('${root.path}/cache').create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, Object?>>[];
    final serverErrors = <Object>[];
    final serving = server.listen((request) async {
      try {
        expect(request.method, 'POST');
        final input = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        expect(input.keys.toSet(), {'type', 'rpcId', 'method', 'payload'});
        expect(input['type'], 'client-request');
        expect(input['rpcId'], isA<String>());
        final method = input['method'] as String;
        expect(request.uri.path, '/api/$method');
        final payload = input['payload'] as Map;
        expect(payload.keys, ['args']);
        final args = Map<String, Object?>.from(payload['args'] as Map);
        requests.add({'method': method, 'args': args});
        final Object value;
        if (method == 'workspaceFiles/stat') {
          expect(args, {'workspaceFileScopeId': _sessionId, 'path': _logicalPath});
          value = {'absolutePath': _logicalPath, 'version': _version, 'bytes': await source.length()};
        } else if (method == 'workspaceFiles/readBytes') {
          expect(args, {
            'workspaceFileScopeId': _sessionId,
            'path': _logicalPath,
            'options': {
              'range': {'offset': 0, 'length': 1048576},
            },
          });
          final data = await source.readAsBytes();
          expect(data, _bytes);
          value = {
            'absolutePath': _logicalPath,
            'version': _version,
            'bytes': data.length,
            'offset': 0,
            'data': data,
            'eof': true,
          };
        } else {
          throw StateError('unexpected RPC $method');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'type': 'server-response',
          'rpcId': input['rpcId'],
          'result': {'ok': true, 'value': value},
        }));
        await request.response.close();
      } catch (error) {
        serverErrors.add(error);
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('normal file fixture failed');
          await request.response.close();
        } catch (closeError) {
          serverErrors.add(closeError);
        }
      }
    }, onError: (Object error) => serverErrors.add(error));
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    final connection = HostConnection(client: client, hostId: 'host-941', isLocal: true);
    final platformCalls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_files, (call) async {
      platformCalls.add(call);
      expect(call.method, 'resolveGuest');
      expect(call.arguments, {'path': _logicalPath});
      // The unchanged platform handler's observed logical-path result in
      // 941-01. This is a channel carrier, not a rerun of that Native handler.
      return null;
    });
    messenger.setMockMethodCallHandler(_paths, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return cache.path;
    });
    final container = ProviderContainer(overrides: [
      operatingSystemProvider.overrideWithValue('ohos'),
      activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection)),
      filesChannelProvider.overrideWithValue(const FilesChannel(_files)),
    ]);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(_files, null);
      messenger.setMockMethodCallHandler(_paths, null);
      try {
        container.dispose();
      } finally {
        try {
          await client.close();
        } finally {
          try {
            await server.close(force: true);
          } finally {
            try {
              await serving.cancel();
            } finally {
              await root.delete(recursive: true);
            }
          }
        }
      }
      expect(serverErrors, isEmpty, reason: 'fixture failures are setup failures, not target behavior');
    });
    final files = container.read(artifactFilesProvider);
    final artifact = Artifact(path: _logicalPath, origin: ArtifactOrigin.linked, turn: 0);
    expect(files.isLocal, isTrue);
    expect(files.canFetch, isTrue);
    expect(artifact.path, _logicalPath);
    expect(artifact.name, 'materialize-marker.txt');
    expect(await source.readAsBytes(), _bytes);
    expect(await cache.list().isEmpty, isTrue);
    expect((await getTemporaryDirectory()).path, cache.path, reason: 'the cache-root carrier must be ready before the target');

    File? materialized;
    Object? targetError;
    final progress = <double?>[];
    try {
      materialized = await files.materialize(_sessionId, artifact, onProgress: progress.add);
    } catch (error) {
      targetError = error;
    }
    // One target call. Capture its actual result before assertions or cleanup
    // so a baseline missing result cannot be confused with a preparation error.
    final observation = <String, Object?>{
      'targetCalls': 1,
      'targetAwaitSettled': true,
      'isLocal': files.isLocal,
      'logicalPath': artifact.path,
      'returnedFile': materialized != null,
      'errorType': targetError?.runtimeType.toString(),
      'artifactErrorCode': targetError is ArtifactError ? targetError.code : null,
      'platformMethods': platformCalls.map((call) => call.method).toList(),
      'rpcMethods': requests.map((request) => request['method']).toList(),
      'fixtureErrors': serverErrors.map((error) => error.toString()).toList(),
    };
    // ignore: avoid_print
    print('OH_MATERIALIZE_TARGET ${jsonEncode(observation)}');
    expect(serverErrors, isEmpty);
    expect(targetError, isNull, reason: 'the actual Dart materialize call must return a file');
    expect(materialized, isNotNull);
    final target = materialized!;
    // Fixed FNV-1a oracle for host-941, session-941 and the literal logical
    // path. It is not computed with, or imported from, the product helper.
    final expectedDirectory = Directory('${cache.path}/artifacts/b68c0ce4');
    expect(target.path, '${expectedDirectory.path}/materialize-marker.txt');
    expect(await target.readAsBytes(), _bytes);
    expect(await target.length(), 11);
    expect(await File('${expectedDirectory.path}/.version').readAsString(), _version);
    final names = await expectedDirectory.list().map((file) => file.uri.pathSegments.last).toList();
    expect(names..sort(), ['.version', 'materialize-marker.txt']);
    expect(platformCalls, isEmpty, reason: 'OH logical paths use the Session service, not private host roots');
    expect(requests, [
      {'method': 'workspaceFiles/stat', 'args': {'workspaceFileScopeId': _sessionId, 'path': _logicalPath}},
      {'method': 'workspaceFiles/stat', 'args': {'workspaceFileScopeId': _sessionId, 'path': _logicalPath}},
      {
        'method': 'workspaceFiles/readBytes',
        'args': {
          'workspaceFileScopeId': _sessionId,
          'path': _logicalPath,
          'options': {'range': {'offset': 0, 'length': 1048576}},
        },
      },
    ]);
    expect(progress, [0.0, 1.0]);
    final sourceAfter = await source.stat();
    expect(await source.readAsBytes(), _bytes);
    expect(sourceAfter.type, sourceBefore.type);
    expect(sourceAfter.mode, sourceBefore.mode);
    expect(sourceAfter.size, sourceBefore.size);
    expect(sourceAfter.modified, sourceBefore.modified);
  });
}
