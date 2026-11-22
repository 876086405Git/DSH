import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:sqlite3/sqlite3.dart';
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

  test('F foreground actual Host wire imports every HTTP frame and survives SQLite reopen', () async {
    // These bytes came from the actual Host foreground HTTP route, Domain and
    // fixed F runner. Its model/agent were controlled; this consumer does not
    // repeat Host execution or claim a real model decision.
    final wire =
        jsonDecode(File('test/fixtures/companion_notes_foreground_host_wire.json').readAsStringSync())
            as Map<String, Object?>;
    expect(wire['scope'], 'ACTUAL_HOST_FOREGROUND_HTTP_WITH_CONTROLLED_MODEL_AND_FIXED_AGENT');
    final create = wire['create']! as Map<String, Object?>;
    final origin = create['origin']! as Map<String, Object?>;
    final requestBody = wire['foreground']! as Map<String, Object?>;
    final snapshots = (wire['snapshots']! as List<Object?>).cast<Map<String, Object?>>();
    final id = create['taskId']! as String;
    final originalStore = create['hostStoreId']! as String;
    final now = snapshots.first['createdAtMs']! as int;
    final directory = await Directory.systemTemp.createTemp('notes-foreground-wire-');
    var store = CompanionMemoryStore(
      sqlite3.open('${directory.path}/memory.sqlite'),
      nowMilliseconds: () => now,
      createId: () => id,
    );
    try {
      store.submitMessage(
        id: origin['messageId']! as String,
        sessionId: origin['sourceSessionId']! as String,
        role: 'user',
        scope: 'real',
        text: '整理选定目录昨天改的笔记，在这里时继续，原文件不动。',
        saidAtUtc: now,
        offsetMinutes: 0,
        offsetSeconds: 0,
        zoneId: 'UTC',
      );
      store.createNotesTaskFromMessage(
        messageId: origin['messageId']! as String,
        expectedSourceRev: 1,
        itemNo: origin['itemNo']! as int,
        roomMode: 'light',
        hostKey: 'fixture-original-host',
        agreement: {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: create[key],
        },
      );
      final original = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'fixture-original-host',
        hostStoreId: originalStore,
        initialOpportunity: true,
      )!;
      expect(original['request'], create);
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: snapshots.first);
      final commands = store.hostTaskCommands(id);
      final prepared = store.prepareHostTaskForeground(
        taskId: id,
        taskRev: 1,
        hostKey: 'fixture-original-host',
        hostStoreId: originalStore,
        hostExecutionId: requestBody['hostExecutionId']! as String,
      );
      expect(prepared, requestBody);
      expect(store.hostTask(id)!['state'], 'unknown');
      respond = (request, _) async {
        if (request.method == 'GET') {
          await _json(request, wire['capability']);
        } else {
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
          for (final snapshot in snapshots) {
            request.response.write('${jsonEncode(snapshot)}\n');
            await request.response.flush();
          }
          await request.response.close();
        }
      };
      final capability = (await client.readCompanionTasksCapability())!;
      expect(capability.notesForeground, isTrue);
      final seen = <Map<String, Object?>>[];
      var abnormalities = 0;
      await client.runCompanionNotesForeground(
        capability,
        taskId: id,
        request: prepared,
        abort: DshHttpAbort(),
        onSnapshot: (snapshot) {
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: snapshot);
          seen.add(snapshot);
        },
        onAbnormal: (_, _) => abnormalities++,
      );
      expect(seen, snapshots);
      expect(seen, hasLength(22));
      expect(abnormalities, 0);
      expect(store.hostTaskCommands(id), commands);
      expect(store.hostTask(id)!['state'], 'done');
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 23);
      expect(store.hostTask(id)!['snapshot'], snapshots.last);
      final sent = requests.where((request) => request.method == 'POST').toList();
      expect(sent, hasLength(1));
      expect(sent.single.uri.path, '$_path/$id/foreground');
      expect(sent.single.body, requestBody);
      store.close();
      store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
      expect(store.hostTask(id)!['snapshot'], snapshots.last);
      expect(store.hostTaskCommands(id), commands);
    } finally {
      store.close();
      await directory.delete(recursive: true);
    }
  });

  test('F foreground SDK preserves each real HTTP snapshot and aborts only its owned response', () async {
    respond = (request, _) => _json(request, {..._capability, 'notesForeground': true});
    final capability = (await client.readCompanionTasksCapability())!;
    final requestBody = <String, Object?>{
      'v': 1,
      'hostStoreId': 'original-store',
      'hostExecutionId': 'execution-original',
      'taskRev': 1,
      'sourceSessionId': 'light:original-room',
    };
    final first = <String, Object?>{
      'v': 1,
      'hostStoreId': 'original-store',
      'taskId': 'task-1',
      'hostExecutionId': 'execution-original',
      'kind': 'host.notes_to_todo',
      'taskRev': 1,
      'runnerReceiptSeq': 3,
      'state': 'waiting',
      'waitReason': 'approval',
      'label': '本人原话🙂',
    };
    final second = <String, Object?>{...first, 'runnerReceiptSeq': 4, 'state': 'running', 'waitReason': null};
    final seen = <Map<String, Object?>>[];
    final observed = Completer<void>();
    final release = Completer<void>();
    respond = (request, body) async {
      if (request.method == 'GET') {
        await _json(request, first);
        return;
      }
      request.response
        ..bufferOutput = false
        ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
      final encoded = utf8.encode('${jsonEncode(first)}\n${jsonEncode(second)}\n');
      final split = encoded.indexOf(0xf0) + 2;
      request.response.add(encoded.sublist(0, split));
      await request.response.flush();
      request.response.add(encoded.sublist(split));
      await request.response.flush();
      await release.future;
      try {
        await request.response.close();
      } on Object {
        // The client explicitly closed this held response.
      }
    };
    final abort = DshHttpAbort();
    final work = client.runCompanionNotesForeground(
      capability,
      taskId: 'task-1',
      request: requestBody,
      abort: abort,
      onSnapshot: (value) {
        seen.add(value);
        if (seen.length == 2) {
          observed.complete();
        }
      },
    );
    await observed.future;
    expect(seen, [first, second]);
    expect(requests.last.body, requestBody);
    expect(requests.last.uri.path, '$_path/task-1/foreground');
    abort.abort();
    await work;
    release.complete();
    expect(await client.readCompanionHostTask(hostStoreId: 'original-store', taskId: 'task-1'), first);
    expect(requests.where((entry) => entry.method == 'POST'), hasLength(1));
  });

  test('F foreground SDK requires the optional capability and never treats old pause metadata as a grant', () async {
    final old = (await client.readCompanionTasksCapability())!;
    expect(old.notesForeground, isFalse);
    await expectLater(
      client.runCompanionNotesForeground(
        old,
        taskId: 'task-1',
        request: {
          'v': 1,
          'hostStoreId': 'original-store',
          'hostExecutionId': 'execution-original',
          'taskRev': 1,
          'sourceSessionId': 'light:original-room',
        },
        abort: DshHttpAbort(),
        onSnapshot: (_) {},
      ),
      throwsA(isA<DshRemoteException>()),
    );
    expect(requests.every((entry) => entry.method == 'GET'), isTrue);
  });

  for (final failure in ['execution', 'oversized-line', 'partial-json', 'empty']) {
    test('F foreground SDK rejects $failure without a replacement POST', () async {
      respond = (request, _) => _json(request, {..._capability, 'notesForeground': true});
      final capability = (await client.readCompanionTasksCapability())!;
      var callbacks = 0;
      var abnormalities = 0;
      respond = (request, _) async {
        request.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
        final text = switch (failure) {
          'execution' =>
            '${jsonEncode({'v': 1, 'hostStoreId': 'original-store', 'taskId': 'task-1', 'hostExecutionId': 'other-execution', 'kind': 'host.notes_to_todo', 'taskRev': 1})}\n',
          'oversized-line' => List<String>.filled(1024 * 1024 + 1, 'x').join(),
          'partial-json' => '{"v":1',
          _ => '',
        };
        request.response.write(text);
        try {
          await request.response.close();
        } on Object {
          // The bounded decoder may cancel before the oversized response ends.
        }
      };
      await expectLater(
        client.runCompanionNotesForeground(
          capability,
          taskId: 'task-1',
          request: {
            'v': 1,
            'hostStoreId': 'original-store',
            'hostExecutionId': 'execution-original',
            'taskRev': 1,
            'sourceSessionId': 'light:original-room',
          },
          abort: DshHttpAbort(),
          onSnapshot: (_) => callbacks++,
          onAbnormal: (_, _) => abnormalities++,
        ),
        throwsA(isA<DshProtocolException>()),
      );
      expect(callbacks, 0);
      expect(abnormalities, 1);
      expect(requests.where((entry) => entry.method == 'POST'), hasLength(1));
    });
  }

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
