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
  'kinds': ['host.compare_drafts'],
  'artifactRead': false,
  'sourceRead': false,
  'afterExit': ['continue'],
  'pauseBehavior': 'waiting',
  'reason': null,
};

Map<String, Object?> _binding(String name, {String ref = 'bound-original-input'}) => {
  'v': 1,
  'hostStoreId': 'original-store',
  'sourceRef': ref,
  'displayName': name,
  'version': 'actual-original-object-version-$ref',
  'size': 32,
  'mediaType': 'text/markdown',
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

  test('I actual HTTP accepts comparison without borrowing find source download capability', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    expect(capability.compareDrafts, isTrue);
    expect(capability.findDraft, isFalse);
    expect(capability.sourceRead, isFalse);
    expect(capability.notes, isFalse);
    respond = (request, body) {
      expect(body, {'v': 1, 'hostStoreId': 'original-store', 'path': '/我选择的稿件'});
      return _json(request, {
        'v': 1,
        'hostStoreId': 'original-store',
        'folderRef': 'original-folder',
        'displayPath': '/我选择的稿件',
      }, status: 201);
    };
    expect((await client.bindCompanionNotesDirectory(capability, '/我选择的稿件'))['folderRef'], 'original-folder');
    expect(requests.map((request) => request.uri.path), ['$_path/capabilities', '$_path/folders']);
  });

  test(
    'I binding sends only the exact selected directory reference and name through existing authentication',
    () async {
      final capability = (await client.readCompanionTasksCapability())!;
      const name = '旧稿 A🙂.MD';
      respond = (request, body) {
        expect(request.method, 'POST');
        expect(request.uri.path, '$_path/inputs');
        expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=fixture-cookie');
        expect(body, {'v': 1, 'hostStoreId': 'original-store', 'folderRef': 'original-folder', 'name': name});
        return _json(request, _binding(name), status: 201);
      };
      expect(
        await client.bindCompanionDraftInput(capability, folderRef: 'original-folder', name: name),
        _binding(name),
      );
      expect(requests, hasLength(2));
      expect(
        requests.where((request) => request.uri.path.contains('/sources/') || request.uri.path == '/api/file'),
        isEmpty,
      );
    },
  );

  test('I two real HTTP binding replies enter one phone transaction before the actual task POST', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    respond = (request, body) {
      final input = body! as Map<String, Object?>;
      return _json(
        request,
        _binding(input['name']! as String, ref: input['name'] == 'A.md' ? 'input-A' : 'input-B'),
        status: 201,
      );
    };
    final a = await client.bindCompanionDraftInput(capability, folderRef: 'folder-A', name: 'A.md');
    final b = await client.bindCompanionDraftInput(capability, folderRef: 'folder-B', name: 'B.md');
    final database = sqlite3.openInMemory();
    final store = CompanionMemoryStore(database, nowMilliseconds: () => 1795219200000);
    try {
      store.submitMessage(
        id: 'source',
        sessionId: 'light:room',
        role: 'user',
        scope: 'real',
        text: '我选了这两份原稿，帮我比较，离开继续。',
        saidAtUtc: 1795219200000,
        offsetMinutes: 480,
        zoneId: 'Asia/Shanghai',
        offsetSeconds: 28800,
      );
      final task = store.createCompareDraftTaskFromMessage(
        messageId: 'source',
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: 'light',
        hostKey: 'original-host',
        inputs: {'a': a, 'b': b},
        agreement: {
          'args': {
            'a': {'sourceRef': a['sourceRef'], 'version': a['version']},
            'b': {'sourceRef': b['sourceRef'], 'version': b['version']},
            'maxHighlights': 3,
          },
          'deadlineAtMs': null,
          'afterExit': 'continue',
          'allowQueue': true,
        },
      );
      final id = task['task_id']! as String;
      expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
      final command = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'original-host',
        hostStoreId: capability.hostStoreId!,
        initialOpportunity: true,
      )!;
      final persisted = command['request']! as Map<String, Object?>;
      respond = (request, body) {
        final wire = body! as Map<String, Object?>;
        expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], 1795219200000);
        expect(body, persisted);
        expect(wire['kind'], 'host.compare_drafts');
        expect((wire['args']! as Map<String, Object?>).keys, ['a', 'b', 'maxHighlights']);
        expect(wire.containsKey('inputs'), isFalse);
        return _json(request, {
          'v': 1,
          'hostStoreId': 'original-store',
          'taskId': id,
          'hostExecutionId': 'original-execution',
          'kind': 'host.compare_drafts',
          'state': 'running',
        }, status: 201);
      };
      await client.writeCompanionHostTask(taskId: id, operation: 'create', request: persisted);
      expect(requests.where((request) => request.method == 'POST' && request.uri.path == _path), hasLength(1));
      expect(store.hostTaskInputs(hostKey: 'original-host'), [a, b]);
    } finally {
      store.close();
    }
  });

  test('I an old notes Host cannot trigger an input route or ordinary chat fallback', () async {
    respond = (request, _) => _json(request, {
      ..._capability,
      'kinds': ['host.notes_to_todo'],
    });
    final capability = (await client.readCompanionTasksCapability())!;
    expect(capability.compareDrafts, isFalse);
    await expectLater(
      client.bindCompanionDraftInput(capability, folderRef: 'folder', name: 'A.md'),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-unavailable')),
    );
    expect(requests, hasLength(1));
  });

  test('I a capability from another live client cannot bind through this connection', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    final second = DshClient(DshConnection(uri));
    try {
      await expectLater(
        second.bindCompanionDraftInput(capability, folderRef: 'folder', name: 'A.md'),
        throwsA(isA<DshRemoteException>()),
      );
      expect(requests, hasLength(1));
    } finally {
      await second.close();
    }
  });

  test('I unsupported names and paths are not turned into arbitrary input requests', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    for (final name in ['', '../A.md', r'parent\A.md', '/A.md', 'A.pdf', 'A\u0000.md']) {
      await expectLater(
        client.bindCompanionDraftInput(capability, folderRef: 'folder', name: name),
        throwsA(isA<DshProtocolException>()),
      );
    }
    expect(requests, hasLength(1));
  });

  final invalidFields = <String, Object?>{
    'hostStoreId': 'replacement-store',
    'sourceRef': '',
    'displayName': 'not-chosen.md',
    'version': '',
    'size': 65537,
    'mediaType': 'application/pdf',
    'content': 'Not a public source attachment',
  };
  for (final entry in invalidFields.entries) {
    test('I rejects a binding with ${entry.key} substituted and does not retry', () async {
      final capability = (await client.readCompanionTasksCapability())!;
      respond = (request, _) => _json(request, {..._binding('A.md'), entry.key: entry.value}, status: 201);
      await expectLater(
        client.bindCompanionDraftInput(capability, folderRef: 'folder', name: 'A.md'),
        throwsA(isA<DshProtocolException>()),
      );
      expect(requests, hasLength(2));
    });
  }

  test('I original input unavailable and replacement store errors do not rebind or download a path', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    for (final error in [
      (status: 400, code: 'companion/task-input-unavailable'),
      (status: 409, code: 'companion/task-store-mismatch'),
    ]) {
      respond = (request, _) => _json(request, {
        'error': {'code': error.code, 'message': 'Original input unavailable'},
      }, status: error.status);
      await expectLater(
        client.bindCompanionDraftInput(capability, folderRef: 'folder', name: 'A.md'),
        throwsA(isA<DshRemoteException>().having((value) => value.code, 'code', error.code)),
      );
    }
    expect(requests.map((request) => request.uri.path), ['$_path/capabilities', '$_path/inputs', '$_path/inputs']);
  });

  test('I an input redirect is not followed and the same request is not automatically repeated', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    respond = (request, _) async {
      request.response
        ..statusCode = 307
        ..headers.set(HttpHeaders.locationHeader, '/api/file?path=/different.md');
      await request.response.close();
    };
    await expectLater(
      client.bindCompanionDraftInput(capability, folderRef: 'folder', name: 'A.md'),
      throwsA(isA<DshHttpException>().having((error) => error.statusCode, 'status', 307)),
    );
    expect(requests, hasLength(2));
  });

  test('I report lookup stays on the same task and source GET failure never falls back to a file path', () async {
    respond = (request, _) => _json(request, {
      'v': 1,
      'hostStoreId': 'original-store',
      'taskId': 'compare-task',
      'hostExecutionId': 'original-execution',
      'kind': 'host.compare_drafts',
      'state': 'partial',
    });
    await client.readCompanionHostTask(hostStoreId: 'original-store', taskId: 'compare-task');
    respond = (request, _) => _json(request, {
      'error': {
        'code': 'companion/task-source-not-found',
        'message': 'Compare input is not a public source attachment',
      },
    }, status: 404);
    await expectLater(
      client.readCompanionHostSource(
        hostStoreId: 'original-store',
        taskId: 'compare-task',
        hostExecutionId: 'original-execution',
        sourceRef: 'input-A',
      ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-source-not-found')),
    );
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(requests.map((request) => request.uri.path), ['$_path/compare-task', '$_path/compare-task/sources/input-A']);
  });

  test('I actual Host wire survives SDK HTTP, phone acceptance, report import and reopen unchanged', () async {
    // The fixture is actual pinned Host Domain/JSON/anchored FS/loopback output
    // from synthetic originals and a controlled model. This test replays that
    // wire through the SDK; it does not repeat Host IO or call a paid model.
    final wire =
        jsonDecode(File('test/fixtures/companion_compare_host_wire.json').readAsStringSync()) as Map<String, Object?>;
    expect(wire['scope'], 'ACTUAL_PINNED_SOURCE_LOOPBACK_SYNTHETIC_IO_CONTROLLED_MODEL');
    final original = wire['create']! as Map<String, Object?>;
    final origin = original['origin']! as Map<String, Object?>;
    final folder = wire['folder']! as Map<String, Object?>;
    final selected = wire['inputs']! as Map<String, Object?>;
    final accepted = wire['createReply']! as Map<String, Object?>;
    final completed = wire['complete']! as Map<String, Object?>;
    final id = original['taskId']! as String;
    final now = accepted['createdAtMs']! as int;
    final directory = await Directory.systemTemp.createTemp('companion-compare-wire-');
    var database = sqlite3.open('${directory.path}/memory.sqlite');
    var store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: () => id);
    try {
      respond = (request, body) {
        if (request.method == 'GET' && request.uri.path == '$_path/capabilities') {
          return _json(request, wire['capabilities']);
        }
        if (request.uri.path == '$_path/folders') {
          expect(body, {'v': 1, 'hostStoreId': original['hostStoreId'], 'path': folder['displayPath']});
          return _json(request, folder, status: 201);
        }
        if (request.uri.path == '$_path/inputs') {
          final input = body! as Map<String, Object?>;
          final binding = selected.values.cast<Map<String, Object?>>().singleWhere(
            (value) => value['displayName'] == input['name'],
          );
          expect(input, {
            'v': 1,
            'hostStoreId': original['hostStoreId'],
            'folderRef': folder['folderRef'],
            'name': binding['displayName'],
          });
          return _json(request, binding, status: 201);
        }
        if (request.method == 'POST' && request.uri.path == _path) {
          expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], now);
          expect(body, original);
          return _json(request, accepted, status: 201);
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '$_path/$id');
        expect(request.uri.queryParameters, {'hostStoreId': original['hostStoreId']});
        return _json(request, completed);
      };
      final capability = (await client.readCompanionTasksCapability())!;
      expect(capability.compareDrafts, isTrue);
      final boundFolder = await client.bindCompanionNotesDirectory(capability, folder['displayPath']! as String);
      final bindings = <String, Object?>{};
      for (final side in const ['a', 'b']) {
        bindings[side] = await client.bindCompanionDraftInput(
          capability,
          folderRef: boundFolder['folderRef']! as String,
          name: (selected[side]! as Map<String, Object?>)['displayName']! as String,
        );
      }
      expect(bindings, selected);
      store.submitMessage(
        id: origin['messageId']! as String,
        sessionId: origin['sourceSessionId']! as String,
        role: 'user',
        scope: 'real',
        text: '已选 A 旧稿与 B 新稿，离开也继续比较，原件别动。',
        saidAtUtc: now,
        offsetMinutes: 0,
        zoneId: 'UTC',
        offsetSeconds: 0,
      );
      final task = store.createCompareDraftTaskFromMessage(
        messageId: origin['messageId']! as String,
        expectedSourceRev: 1,
        itemNo: origin['itemNo']! as int,
        roomMode: 'light',
        hostKey: 'fixture-original-host',
        inputs: bindings,
        agreement: {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: original[key],
        },
      );
      expect(task['task_id'], id);
      expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
      final command = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'fixture-original-host',
        hostStoreId: capability.hostStoreId!,
        initialOpportunity: true,
      )!;
      final reply = await client.writeCompanionHostTask(
        taskId: id,
        operation: 'create',
        request: command['request']! as Map<String, Object?>,
      );
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: reply);
      expect(store.hostTask(id)!['snapshot'], accepted);
      final completion = (await client.readCompanionHostTask(hostStoreId: capability.hostStoreId!, taskId: id))!;
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: completion);
      store.close();
      database = sqlite3.open('${directory.path}/memory.sqlite');
      store = CompanionMemoryStore(database, nowMilliseconds: () => now);
      final current = store.hostTask(id)!;
      expect(current['state'], 'done');
      expect(current['snapshot'], completed);
      expect(current['applied_host_receipt_seq'], completed['runnerReceiptSeq']);
      expect(store.hostTaskInputs(hostKey: 'fixture-original-host'), [selected['a'], selected['b']]);
      expect(store.taskReceipts(id), isEmpty);
      final steps = (completion['steps']! as List<Object?>).cast<Map<String, Object?>>();
      final report =
          (steps.singleWhere((step) => step['stepKey'] == 'report')['result']! as Map<String, Object?>)['completion']!
              as Map<String, Object?>;
      final differences = (report['differences']! as List<Object?>).cast<Map<String, Object?>>().toList();
      expect(differences, hasLength(2));
      expect((differences.first['a']! as Map<String, Object?>)['paragraphs'], {'from': 3, 'to': 3});
      expect((differences.last['a']! as Map<String, Object?>)['paragraphs'], {'from': 1, 'to': 1});
      for (final difference in differences) {
        for (final side in const ['a', 'b']) {
          final text = (wire['originals']! as Map<String, Object?>)[side]! as String;
          for (final excerpt
              in ((difference[side]! as Map<String, Object?>)['excerpts']! as List<Object?>)
                  .cast<Map<String, Object?>>()) {
            expect(text.substring(excerpt['from']! as int, excerpt['to']! as int), excerpt['text']);
          }
        }
      }
      final readAgain = (await client.readCompanionHostTask(hostStoreId: capability.hostStoreId!, taskId: id))!;
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: readAgain);
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: accepted);
      expect(store.hostTask(id)!['snapshot'], completed);
      expect(requests.where((request) => request.method == 'POST' && request.uri.path == _path), hasLength(1));
      expect(
        requests.any((request) => request.uri.path.contains('/sources/') || request.uri.path == '/api/file'),
        isFalse,
      );
    } finally {
      store.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'I actual cancelled Host wire preserves its old unpublished report and current cancellation after reopen',
    () async {
      // Actual Host cancellation during the fourth whole-file read. The fixture
      // contains the resulting wire, not a newly synthesized report envelope.
      final wire =
          jsonDecode(File('test/fixtures/companion_compare_cancelled_host_wire.json').readAsStringSync())
              as Map<String, Object?>;
      expect(wire['scope'], 'ACTUAL_PINNED_SOURCE_LOOPBACK_SYNTHETIC_IO_CONTROLLED_MODEL_AND_READ_GATE');
      final original = wire['create']! as Map<String, Object?>;
      final origin = original['origin']! as Map<String, Object?>;
      final completed = wire['complete']! as Map<String, Object?>;
      final id = original['taskId']! as String;
      final now = completed['createdAtMs']! as int;
      final directory = await Directory.systemTemp.createTemp('companion-compare-cancel-wire-');
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
          text: '比较我已选的这两稿，离开继续。',
          saidAtUtc: now,
          offsetMinutes: 0,
        );
        store.createCompareDraftTaskFromMessage(
          messageId: origin['messageId']! as String,
          expectedSourceRev: 1,
          itemNo: origin['itemNo']! as int,
          roomMode: 'light',
          hostKey: 'fixture-original-host',
          inputs: wire['inputs']! as Map<String, Object?>,
          agreement: {
            for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: original[key],
          },
        );
        store.prepareHostTaskOperation(
          taskId: id,
          taskRev: 1,
          hostKey: 'fixture-original-host',
          hostStoreId: original['hostStoreId']! as String,
          initialOpportunity: true,
        );
        store.submitMessage(
          id: 'explicit-cancel-source',
          sessionId: origin['sourceSessionId']! as String,
          role: 'user',
          scope: 'real',
          text: '取消这次比稿。',
          saidAtUtc: now,
          offsetMinutes: 0,
        );
        expect(
          store.cancelCompareDraftTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'explicit-cancel-source',
            expectedSourceRev: 1,
            itemNo: 0,
          )['state'],
          'unknown',
        );
        store.prepareHostTaskOperation(
          taskId: id,
          taskRev: 2,
          hostKey: 'fixture-original-host',
          hostStoreId: original['hostStoreId']! as String,
          initialOpportunity: false,
        );
        respond = (request, _) {
          expect(request.method, 'GET');
          expect(request.uri.path, '$_path/$id');
          expect(request.uri.queryParameters, {'hostStoreId': original['hostStoreId']});
          return _json(request, completed);
        };
        final received = (await client.readCompanionHostTask(
          hostStoreId: original['hostStoreId']! as String,
          taskId: id,
        ))!;
        store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: received);
        store.close();
        store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
        final current = store.hostTask(id)!;
        expect(current['task_rev'], 2);
        expect(current['state'], 'cancelled');
        expect(current['snapshot'], completed);
        expect(current['applied_host_receipt_seq'], completed['runnerReceiptSeq']);
        final step = (received['steps']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
          (value) => value['stepKey'] == 'report',
        );
        final report = (step['result']! as Map<String, Object?>)['completion']! as Map<String, Object?>;
        expect(step['taskRev'], 1);
        expect(step['state'], 'partial');
        expect(report['published'], isFalse);
        expect((report['coverage']! as Map<String, Object?>)['comparisonComplete'], isTrue);
        expect(report['differences'], hasLength(2));
        expect(
          (report['sources']! as List<Object?>).cast<Map<String, Object?>>().map(
            (source) => source['verifiedAtPublish'],
          ),
          [true, false],
        );
        final readAgain = (await client.readCompanionHostTask(
          hostStoreId: original['hostStoreId']! as String,
          taskId: id,
        ))!;
        store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: readAgain);
        expect(store.hostTask(id)!['state'], 'cancelled');
        expect(store.hostTask(id)!['snapshot'], completed);
        expect(requests, hasLength(2));
        expect(requests.every((request) => request.method == 'GET'), isTrue);
        expect(store.taskReceipts(id), isEmpty);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'I actual owner-stop recovery keeps both attempts and imports one published report after the original unknown',
    () async {
      final wire =
          jsonDecode(File('test/fixtures/companion_compare_owner_stopped_host_wire.json').readAsStringSync())
              as Map<String, Object?>;
      expect(wire['scope'], 'ACTUAL_PINNED_SOURCE_LOOPBACK_OWNER_STOP_AND_DOMAIN_REOPEN_WITH_CONTROLLED_MODEL');
      final original = wire['create']! as Map<String, Object?>;
      final origin = original['origin']! as Map<String, Object?>;
      final before = wire['before']! as Map<String, Object?>;
      final completed = wire['complete']! as Map<String, Object?>;
      final id = original['taskId']! as String;
      final now = before['createdAtMs']! as int;
      final directory = await Directory.systemTemp.createTemp('companion-compare-owner-wire-');
      var store = CompanionMemoryStore(
        sqlite3.open('${directory.path}/memory.sqlite'),
        nowMilliseconds: () => now,
        createId: () => id,
      );
      Map<String, Object?> copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;
      List<Map<String, Object?>> reports(Map<String, Object?> value) => (value['steps']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((step) => step['stepKey'] == 'report')
          .toList();
      try {
        store.submitMessage(
          id: origin['messageId']! as String,
          sessionId: origin['sourceSessionId']! as String,
          role: 'user',
          scope: 'real',
          text: '比较这两份已选原稿，离开继续。',
          saidAtUtc: now,
          offsetMinutes: 0,
        );
        store.createCompareDraftTaskFromMessage(
          messageId: origin['messageId']! as String,
          expectedSourceRev: 1,
          itemNo: origin['itemNo']! as int,
          roomMode: 'light',
          hostKey: 'fixture-original-host',
          inputs: wire['inputs']! as Map<String, Object?>,
          agreement: {
            for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: original[key],
          },
        );
        store.prepareHostTaskOperation(
          taskId: id,
          taskRev: 1,
          hostKey: 'fixture-original-host',
          hostStoreId: original['hostStoreId']! as String,
          initialOpportunity: true,
        );
        var response = before;
        respond = (request, _) {
          expect(request.method, 'GET');
          expect(request.uri.path, '$_path/$id');
          expect(request.uri.queryParameters, {'hostStoreId': original['hostStoreId']});
          return _json(request, response);
        };
        final observed = (await client.readCompanionHostTask(
          hostStoreId: original['hostStoreId']! as String,
          taskId: id,
        ))!;
        expect(
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: observed)['state'],
          'unknown',
        );
        expect(reports(observed), hasLength(1));
        final oldAttempt = copy(reports(observed).single);
        for (final fault in ['two-published', 'published-then-running', 'ordinary-false-retry', 'changed-history']) {
          final malformed = copy(completed);
          final attempted = reports(malformed);
          if (fault == 'two-published') {
            (malformed['steps']! as List<Object?>).add(
              copy(attempted.last)..['attemptId'] = 'another-published-report',
            );
          } else if (fault == 'published-then-running') {
            (malformed['steps']! as List<Object?>).add(
              copy(attempted.last)
                ..['attemptId'] = 'another-running-report'
                ..['state'] = 'running'
                ..['finishedAtMs'] = null
                ..['result'] = null,
            );
          } else if (fault == 'ordinary-false-retry') {
            attempted.first['reason'] = 'report_not_published';
          } else {
            final report = (attempted.first['result']! as Map<String, Object?>)['completion']! as Map<String, Object?>;
            (((report['suggestions']! as Map<String, Object?>)['items']! as List<Object?>).first!
                    as Map<String, Object?>)['practice'] =
                '改写旧建议';
          }
          expect(
            () => store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: malformed),
            throwsA(
              isA<DshRemoteException>().having(
                (error) => error.code,
                'code',
                fault == 'changed-history' ? 'companion/conflict' : 'companion/task-invalid-request',
              ),
            ),
          );
          expect(store.hostTask(id)!['snapshot'], before);
          expect(store.hostTask(id)!['applied_host_receipt_seq'], before['runnerReceiptSeq']);
        }
        response = completed;
        final recovered = (await client.readCompanionHostTask(
          hostStoreId: original['hostStoreId']! as String,
          taskId: id,
        ))!;
        expect(
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: recovered)['state'],
          'done',
        );
        expect(reports(recovered), hasLength(2));
        expect(reports(recovered).first, oldAttempt);
        expect(
          reports(recovered)
              .map((step) => (step['result']! as Map<String, Object?>)['completion'])
              .cast<Map<String, Object?>>()
              .map((report) => report['published']),
          [false, true],
        );
        store.close();
        store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
        expect(store.hostTask(id)!['snapshot'], completed);
        expect(store.hostTask(id)!['state'], 'done');
        response = before;
        final delayed = (await client.readCompanionHostTask(
          hostStoreId: original['hostStoreId']! as String,
          taskId: id,
        ))!;
        store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: delayed);
        expect(store.hostTask(id)!['snapshot'], completed);
        expect(store.hostTask(id)!['state'], 'done');
        expect(store.hostTask(id)!['applied_host_receipt_seq'], completed['runnerReceiptSeq']);
        expect(requests, hasLength(3));
        expect(requests.every((request) => request.method == 'GET'), isTrue);
        expect(store.taskReceipts(id), isEmpty);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
