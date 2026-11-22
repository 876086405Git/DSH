import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _path = '/dsh-go/v1/companion/tasks';
const _capability = <String, Object?>{
  'v': 1,
  'hostStoreId': 'original-store',
  'durableAcceptance': true,
  'kinds': ['host.find_draft'],
  'artifactRead': false,
  'sourceRead': true,
  'afterExit': ['continue'],
  'pauseBehavior': 'waiting',
  'reason': null,
};

Future<void> _json(HttpRequest request, Object? body, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

Map<String, Object?> _source(String status) => {
  'v': 1,
  'hostStoreId': 'original-store',
  'taskId': 'find-task',
  'hostExecutionId': 'original-execution',
  'sourceRef': 'registered-source',
  'taskRev': 1,
  'stepKey': 'readInputs',
  'relativePath': '开场 A.md',
  'version': 'original-inode-version',
  'mediaType': 'text/markdown',
  'status': status,
  'content': status == 'available' ? '# 原稿🙂\n末段也在。' : null,
  'reason': status == 'available' ? null : 'observed-$status',
};

void main() {
  late HttpServer server;
  late DshClient client;
  late Future<void> Function(HttpRequest, Object?) respond;
  late List<({String method, Uri uri, Object? body})> requests;

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    client = DshClient(
      DshConnection(
        uri,
        hostHeader: uri.authority,
        cookie: DshCookie(name: 'dsh-auth-test', value: 'fixture-cookie', authority: uri.authority),
      ),
    );
    respond = (request, _) => _json(request, _capability);
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final body = text.isEmpty ? null : jsonDecode(text);
      requests.add((method: request.method, uri: request.uri, body: body));
      await respond(request, body);
    });
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  test('H actual HTTP accepts a find-only capability and binds the actual selected directory', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    expect(capability.findDraft, isTrue);
    expect(capability.notes, isFalse);
    expect(capability.sourceRead, isTrue);
    respond = (request, body) {
      expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=fixture-cookie');
      expect(body, {'v': 1, 'hostStoreId': 'original-store', 'path': '/演讲稿/这一层🙂'});
      return _json(request, {
        'v': 1,
        'hostStoreId': 'original-store',
        'folderRef': 'actually-bound-directory',
        'displayPath': '/演讲稿/这一层🙂',
      }, status: 201);
    };
    expect(
      (await client.bindCompanionNotesDirectory(capability, '/演讲稿/这一层🙂'))['folderRef'],
      'actually-bound-directory',
    );
    expect(requests.map((item) => item.uri.path), ['$_path/capabilities', '$_path/folders']);
  });

  test('H an old notes Host without sourceRead remains notes-only and does not manufacture a find route', () async {
    final old = <String, Object?>{
      ..._capability,
      'kinds': ['host.notes_to_todo'],
      'artifactRead': true,
    }..remove('sourceRead');
    respond = (request, _) => _json(request, old);
    final capability = (await client.readCompanionTasksCapability())!;
    expect(capability.notes, isTrue);
    expect(capability.findDraft, isFalse);
    expect(capability.sourceRead, isFalse);
    expect(requests, hasLength(1));
  });

  test('H an advertised find kind without its real source capability is rejected', () async {
    respond = (request, _) => _json(request, {..._capability, 'sourceRead': false});
    await expectLater(client.readCompanionTasksCapability(), throwsA(isA<DshProtocolException>()));
    expect(requests, hasLength(1));
  });

  test('H amend and cancel carry their exact pre-create kind without adding another task ID', () async {
    for (final operation in ['amend', 'cancel']) {
      final request = <String, Object?>{
        'v': 1,
        'hostStoreId': 'original-store',
        'kind': 'host.find_draft',
        'operationId': 'operation-$operation',
        'expectedTaskRev': 1,
        'taskRev': 2,
        if (operation == 'amend')
          'changes': {
            'args': {
              'folderRef': 'actually-bound-directory',
              'scope': 'currentLevel',
              'localDate': '2026-11-20',
              'timeZone': 'Asia/Shanghai',
              'dateBy': 'modified',
              'extensions': ['txt'],
            },
            'deadlineAtMs': null,
            'afterExit': 'continue',
            'allowQueue': true,
          },
      };
      respond = (incoming, body) {
        expect(incoming.uri.path, '$_path/find-task/$operation');
        expect(body, request);
        expect((body! as Map<String, Object?>).containsKey('taskId'), isFalse);
        return _json(incoming, {
          'v': 1,
          'hostStoreId': 'original-store',
          'taskId': 'find-task',
          'hostExecutionId': 'original-execution',
          'kind': 'host.find_draft',
          'originalCreatePresent': false,
          'state': operation == 'cancel' ? 'cancelled' : 'waiting',
        });
      };
      final response = await client.writeCompanionHostTask(taskId: 'find-task', operation: operation, request: request);
      expect(response['originalCreatePresent'], isFalse);
    }
    expect(requests, hasLength(2));
  });

  for (final status in ['available', 'missing', 'changed', 'not_readable', 'unknown']) {
    test('H source $status uses only the original execution and registered reference with no path fallback', () async {
      respond = (request, _) => _json(request, _source(status));
      final result = await client.readCompanionHostSource(
        hostStoreId: 'original-store',
        taskId: 'find-task',
        hostExecutionId: 'original-execution',
        sourceRef: 'registered-source',
      );
      expect(result, _source(status));
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.path, '$_path/find-task/sources/registered-source');
      expect(requests.single.uri.queryParameters, {
        'hostStoreId': 'original-store',
        'hostExecutionId': 'original-execution',
      });
      expect(requests.single.body, isNull);
    });
  }

  for (final field in ['hostStoreId', 'taskId', 'hostExecutionId', 'sourceRef']) {
    test('H source response cannot substitute the known $field', () async {
      respond = (request, _) => _json(request, {..._source('available'), field: 'replacement'});
      await expectLater(
        client.readCompanionHostSource(
          hostStoreId: 'original-store',
          taskId: 'find-task',
          hostExecutionId: 'original-execution',
          sourceRef: 'registered-source',
        ),
        throwsA(isA<DshProtocolException>()),
      );
      expect(requests, hasLength(1));
    });
  }

  test('H missing registered source is a specific error and does not fall back to a general file route', () async {
    respond = (request, _) => _json(request, {
      'error': {'code': 'companion/task-source-not-found', 'message': 'Source is not registered for this task'},
    }, status: 404);
    await expectLater(
      client.readCompanionHostSource(
        hostStoreId: 'original-store',
        taskId: 'find-task',
        hostExecutionId: 'original-execution',
        sourceRef: 'registered-source',
      ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-source-not-found')),
    );
    expect(requests, hasLength(1));
  });

  test('H source redirect never follows an arbitrary path or repeats the request', () async {
    respond = (request, _) async {
      request.response
        ..statusCode = 307
        ..headers.set(HttpHeaders.locationHeader, '/api/file?path=/another/file');
      await request.response.close();
    };
    await expectLater(
      client.readCompanionHostSource(
        hostStoreId: 'original-store',
        taskId: 'find-task',
        hostExecutionId: 'original-execution',
        sourceRef: 'registered-source',
      ),
      throwsA(isA<DshHttpException>().having((error) => error.statusCode, 'status', 307)),
    );
    expect(requests, hasLength(1));
  });

  for (final fixture in [
    (
      file: 'H02-wire.json',
      name: 'H actual Host wire fixture passes capability create snapshot and original-source SDK HTTP paths unchanged',
    ),
    (
      file: 'H02-backslash-wire.json',
      name: 'H actual partial Host wire keeps unreadable and readable sources on their registered SDK HTTP paths',
    ),
  ]) {
    test(fixture.name, () async {
      final wire =
          jsonDecode(File('test/fixtures/companion_find_draft/${fixture.file}').readAsStringSync())
              as Map<String, Object?>;
      final original = wire['create']! as Map<String, Object?>;
      final folder = wire['folder']! as Map<String, Object?>;
      final source = wire['sourceAvailable']! as Map<String, Object?>;
      respond = (request, _) => _json(request, wire['capabilities']);
      final capability = (await client.readCompanionTasksCapability())!;
      expect(capability.findDraft, isTrue);
      respond = (request, body) {
        expect(body, {'v': 1, 'hostStoreId': capability.hostStoreId, 'path': folder['displayPath']});
        return _json(request, folder, status: 201);
      };
      expect(await client.bindCompanionNotesDirectory(capability, folder['displayPath']! as String), folder);
      respond = (request, body) {
        expect(body, original);
        return _json(request, wire['createReply'], status: 201);
      };
      expect(
        await client.writeCompanionHostTask(
          taskId: original['taskId']! as String,
          operation: 'create',
          request: original,
        ),
        wire['createReply'],
      );
      respond = (request, _) => _json(request, wire['complete']);
      expect(
        await client.readCompanionHostTask(hostStoreId: capability.hostStoreId!, taskId: original['taskId']! as String),
        wire['complete'],
      );
      respond = (request, _) => _json(request, source);
      expect(
        await client.readCompanionHostSource(
          hostStoreId: capability.hostStoreId!,
          taskId: original['taskId']! as String,
          hostExecutionId: source['hostExecutionId']! as String,
          sourceRef: source['sourceRef']! as String,
        ),
        source,
      );
      final unavailable = wire['sourceUnavailable'] as Map<String, Object?>?;
      if (unavailable != null) {
        respond = (request, _) => _json(request, unavailable);
        final result = await client.readCompanionHostSource(
          hostStoreId: capability.hostStoreId!,
          taskId: original['taskId']! as String,
          hostExecutionId: unavailable['hostExecutionId']! as String,
          sourceRef: unavailable['sourceRef']! as String,
        );
        expect(result, unavailable);
        expect(result['status'], 'unknown');
        expect(result['content'], isNull);
        expect((result['relativePath']! as String).contains(r'\'), isTrue);
        expect(requests.last.uri.path, '$_path/${original['taskId']}/sources/${unavailable['sourceRef']}');
        expect(requests.last.uri.queryParameters, {
          'hostStoreId': capability.hostStoreId!,
          'hostExecutionId': unavailable['hostExecutionId'],
        });
        expect(requests.last.body, isNull);
      }
      expect(requests.where((request) => request.method == 'POST' && request.uri.path == _path), hasLength(1));
      expect(requests, hasLength(unavailable == null ? 5 : 6));
    });
  }
}
