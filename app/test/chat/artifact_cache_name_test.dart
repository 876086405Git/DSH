import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// This non-widget regression exercises the real loopback HTTP transport.
class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _LoopbackBinding();
  // The last: a legal Windows name too long for an Android file name (262 UTF-8 bytes).
  for (final name in ['.version', '.version ', 'report.txt', '${'文' * 86}.txt']) {
    test('remote cache preserves $name body, version refresh and outgoing name', () async {
      final cache = await Directory.systemTemp.createTemp('artifact-cache-name-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var version = 'version-one';
      var content = utf8.encode('ordinary file body one');
      var reads = 0;
      final serverErrors = <Object>[];
      final path = '/workspace/$name';
      final serving = server.listen((request) async {
        try {
          final input = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
          final Object value;
          if (request.uri.path == '/api/workspaceFiles/stat') {
            value = {'absolutePath': path, 'version': version, 'bytes': content.length};
          } else if (request.uri.path == '/api/workspaceFiles/readBytes') {
            reads++;
            value = {
              'absolutePath': path,
              'version': version,
              'bytes': content.length,
              'offset': 0,
              'data': content,
              'eof': true,
            };
          } else {
            throw StateError('unexpected RPC ${request.uri.path}');
          }
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
          serverErrors.add(error);
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.write('synthetic server failed');
            await request.response.close();
          } catch (closeError) {
            serverErrors.add(closeError);
          }
        }
      }, onError: (Object error) => serverErrors.add(error));
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      const channel = MethodChannel('test/artifact-cache-name');
      final handedOff = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        handedOff.add(call);
        final args = call.arguments as Map;
        expect(args['name'], name, reason: 'cache naming must preserve outgoing original name');
        expect(await File(args['path'] as String).readAsBytes(), content);
        return call.method == 'saveToDownloads' ? 'Downloads/$name' : null;
      });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        await client.close();
        await server.close(force: true);
        await serving.cancel();
        await cache.delete(recursive: true);
        expect(serverErrors, isEmpty, reason: 'loopback RPC failures must not escape the test');
      });
      final files = ArtifactFiles(
        connection: HostConnection(client: client, label: 'synthetic', hostId: 'host', isLocal: false),
        channel: const FilesChannel(channel),
        cacheRoot: () async => cache,
      );
      final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0);
      expect(artifact.name, name);
      final first = await files.materialize('session', artifact);
      expect(await first.readAsBytes(), content, reason: 'version metadata must not overwrite content');
      expect(reads, 1);
      final hit = await files.materialize('session', artifact);
      expect(hit.path, first.path);
      expect(await hit.readAsBytes(), content);
      expect(reads, 1, reason: 'unchanged version is a cache hit');
      version = 'version-two';
      content = utf8.encode('new ordinary body two');
      final refreshed = await files.materialize('session', artifact);
      expect(await refreshed.readAsBytes(), content);
      expect(reads, 2);
      await files.open('session', artifact);
      expect(await files.saveToDownloads('session', artifact), 'Downloads/$name');
      expect(handedOff.map((call) => call.method), ['open', 'saveToDownloads']);
      expect(reads, 2, reason: 'open and save reuse refreshed cache');
    });
  }
}
