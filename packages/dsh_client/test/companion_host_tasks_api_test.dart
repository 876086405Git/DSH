import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _path = '/dsh-go/v1/companion/tasks';
const _capability = <String, Object?>{
  'v': 1,
  'hostStoreId': 'original-store',
  'durableAcceptance': true,
  'kinds': ['host.notes_to_todo'],
  'artifactRead': true,
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
      final bytes = await utf8.decoder.bind(request).join();
      final body = bytes.isEmpty ? null : jsonDecode(bytes);
      requests.add((method: request.method, uri: request.uri, body: body));
      await respond(request, body);
    });
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  test('F SDK actual HTTP binds only the picked directory and sends the original task package once', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    expect(capability.notes, isTrue);
    expect(capability.hostStoreId, 'original-store');
    respond = (request, body) {
      expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=fixture-cookie');
      expect(body, {'v': 1, 'hostStoreId': 'original-store', 'path': '/实际目录/笔记🙂'});
      return _json(request, {
        'v': 1,
        'hostStoreId': 'original-store',
        'folderRef': 'durable-directory',
        'displayPath': '/实际目录/笔记🙂',
      });
    };
    final directory = await client.bindCompanionNotesDirectory(capability, '/实际目录/笔记🙂');
    expect(directory['folderRef'], 'durable-directory');
    final package = <String, Object?>{
      'v': 1,
      'hostStoreId': 'original-store',
      'taskId': 'task-1',
      'taskRev': 1,
      'kind': 'host.notes_to_todo',
      'origin': {'sourceSessionId': 'light:original-room', 'messageId': 'raw-1', 'itemNo': 2},
      'hostSessionId': null,
      'deadlineAtMs': null,
      'afterExit': 'pause',
      'allowQueue': true,
      'args': {
        'folderRef': directory['folderRef'],
        'localDate': '2026-11-21',
        'timeZone': 'Asia/Shanghai',
        'dateBy': 'modified',
        'outputDirRef': directory['folderRef'],
        'outputName': '今日待办.md',
        'writeMode': 'createNew',
      },
    };
    respond = (request, body) {
      expect(body, package);
      return _json(request, {
        'v': 1,
        'hostStoreId': 'original-store',
        'taskId': 'task-1',
        'hostExecutionId': 'stable-execution',
        'state': 'waiting',
        'waitReason': 'foreground_control_unavailable',
      }, status: 201);
    };
    final response = await client.writeCompanionHostTask(taskId: 'task-1', operation: 'create', request: package);
    expect(response['waitReason'], 'foreground_control_unavailable');
    expect(requests.map((item) => item.uri.path), ['$_path/capabilities', '$_path/folders', _path]);
    expect(requests.where((item) => item.uri.path == _path), hasLength(1));
  });

  test('F SDK same-store missing task differs from a changed library and never creates a replacement', () async {
    respond = (request, _) => _json(request, {
      'error': {'code': 'companion/task-not-found', 'message': 'missing'},
    }, status: 404);
    expect(await client.readCompanionHostTask(hostStoreId: 'original-store', taskId: 'task-1'), isNull);
    expect(requests.single.uri.queryParameters, {'hostStoreId': 'original-store'});
    respond = (request, _) => _json(request, {
      'error': {'code': 'companion/task-store-mismatch', 'message': 'changed'},
    }, status: 409);
    await expectLater(
      client.readCompanionHostTask(hostStoreId: 'original-store', taskId: 'task-1'),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-store-mismatch')),
    );
    expect(requests.every((item) => item.method == 'GET'), isTrue);
  });

  test('F SDK amend and cancel keep operation identity and preserve conflict snapshots', () async {
    final snapshot = {'v': 1, 'hostStoreId': 'original-store', 'taskId': 'task-1', 'hostExecutionId': 'execution-1'};
    for (final operation in ['amend', 'cancel']) {
      final body = <String, Object?>{
        'v': 1,
        'hostStoreId': 'original-store',
        'operationId': 'stable-$operation',
        'expectedTaskRev': 1,
        'taskRev': 2,
        if (operation == 'amend')
          'changes': {'args': {}, 'deadlineAtMs': null, 'afterExit': 'continue', 'allowQueue': false},
      };
      respond = (request, value) {
        expect(request.uri.path, '$_path/task-1/$operation');
        expect(value, body);
        expect((value! as Map).containsKey('taskId'), isFalse);
        return _json(request, {
          'error': {'code': 'companion/task-conflict', 'message': 'revision changed'},
          'snapshot': snapshot,
        }, status: 409);
      };
      await expectLater(
        client.writeCompanionHostTask(taskId: 'task-1', operation: operation, request: body),
        throwsA(isA<DshRemoteException>().having((error) => error.details['snapshot'], 'snapshot', snapshot)),
      );
    }
    expect(requests, hasLength(2));
  });

  test('F SDK redirect cannot repeat a task mutation at a different route', () async {
    respond = (request, _) async {
      request.response
        ..statusCode = 307
        ..headers.set(HttpHeaders.locationHeader, '/unexpected');
      await request.response.close();
    };
    await expectLater(
      client.writeCompanionHostTask(
        taskId: 'task-1',
        operation: 'cancel',
        request: {
          'v': 1,
          'hostStoreId': 'original-store',
          'operationId': 'cancel-1',
          'expectedTaskRev': 1,
          'taskRev': 2,
        },
      ),
      throwsA(isA<DshHttpException>().having((error) => error.statusCode, 'status', 307)),
    );
    expect(requests, hasLength(1));
  });

  for (final status in ['available', 'missing', 'changed', 'unknown']) {
    test('F SDK artifact $status is an original registered read and cannot claim a replacement file', () async {
      respond = (request, _) => _json(request, {
        'v': 1,
        'hostStoreId': 'original-store',
        'taskId': 'task-1',
        'hostExecutionId': 'execution-1',
        'artifactId': 'file-1',
        'status': status,
        'mediaType': 'text/markdown',
        'content': status == 'available' ? '# 已核待办🙂' : null,
        'reason': status == 'available' ? null : 'observed-$status',
      });
      final artifact = await client.readCompanionHostArtifact(
        hostStoreId: 'original-store',
        taskId: 'task-1',
        hostExecutionId: 'execution-1',
        artifactId: 'file-1',
      );
      expect(artifact['status'], status);
      expect(artifact['content'], status == 'available' ? '# 已核待办🙂' : isNull);
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.path, '$_path/task-1/artifacts/file-1');
      expect(requests.single.uri.queryParameters, {'hostStoreId': 'original-store'});
    });
  }

  test('F SDK artifact reply from another execution is not opened', () async {
    respond = (request, _) => _json(request, {
      'v': 1,
      'hostStoreId': 'original-store',
      'taskId': 'task-1',
      'hostExecutionId': 'replacement-execution',
      'artifactId': 'file-1',
      'status': 'available',
      'mediaType': 'text/plain',
      'content': '别的任务',
      'reason': null,
    });
    await expectLater(
      client.readCompanionHostArtifact(
        hostStoreId: 'original-store',
        taskId: 'task-1',
        hostExecutionId: 'original-execution',
        artifactId: 'file-1',
      ),
      throwsA(isA<DshProtocolException>()),
    );
  });
}
