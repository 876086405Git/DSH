import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dsh_client/dsh_client.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/receipt_task_fixtures.dart';

const _path = '/dsh-go/v1/companion/tasks';
const _capability = <String, Object?>{
  'v': 1,
  'hostStoreId': 'original-store',
  'durableAcceptance': true,
  'kinds': ['host.receipts_to_sheet'],
  'artifactRead': true,
  'sourceRead': false,
  'afterExit': ['continue'],
  'pauseBehavior': 'waiting',
  'reason': null,
  'receiptInputs': {
    'formats': ['md', 'txt', 'pdf'],
    'maxFiles': 4,
    'maxBytes': 4194304,
    'maxPdfPages': 5,
    'workbookBytes': 262144,
  },
};

Future<void> _json(HttpRequest request, Object? body, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

Future<void> _bytes(HttpRequest request, List<int> body, {String mime = workbookMediaType}) async {
  request.response.headers.contentType = ContentType.parse(mime);
  request.response.contentLength = body.length;
  request.response.add(body);
  await request.response.close();
}

void main() {
  late HttpServer server;
  late HttpClient http;
  late DshClient client;
  late Future<void> Function(HttpRequest, Object?) respond;
  late List<({String method, Uri uri, Object? body})> requests;
  final workbook = File('test/fixtures/companion_receipt_workbook.xlsx').readAsBytesSync();
  final artifact = receiptArtifact(size: workbook.length, hash: sha256.convert(workbook).toString());

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    http = HttpClient();
    http.userAgent = 'original-receipt-client';
    client = DshClient(
      DshConnection(
        uri,
        httpClient: http,
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
    http.close(force: true);
    await server.close(force: true);
  });

  test('J advertises only its actual formats and binds input with an explicit receipt kind', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    expect(capability.receiptsToSheet, isTrue);
    expect(capability.compareDrafts, isFalse);
    expect(capability.sourceRead, isFalse);
    expect(capability.receiptInputs, _capability['receiptInputs']);
    expect(() => capability.receiptInputs!['maxBytes'] = 99, throwsUnsupportedError);
    expect(() => (capability.receiptInputs!['formats']! as List<Object?>).add('png'), throwsUnsupportedError);
    respond = (request, body) {
      expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=fixture-cookie');
      expect(body, {
        'v': 1,
        'hostStoreId': 'original-store',
        'folderRef': 'picked-folder',
        'name': '票据.PDF',
        'kind': 'host.receipts_to_sheet',
      });
      return _json(request, {...receiptBindings()[2], 'displayName': '票据.PDF'}, status: 201);
    };
    expect(
      (await client.bindCompanionReceiptInput(capability, folderRef: 'picked-folder', name: '票据.PDF'))['mediaType'],
      'application/pdf',
    );
    expect(requests.map((request) => request.uri.path), ['$_path/capabilities', '$_path/inputs']);
  });

  test('J a text-only Host does not send a PDF input or borrow ordinary file access', () async {
    respond = (request, _) => _json(request, {
      ..._capability,
      'receiptInputs': {
        ...(_capability['receiptInputs']! as Map<String, Object?>),
        'formats': ['md', 'txt'],
      },
    });
    final capability = (await client.readCompanionTasksCapability())!;
    await expectLater(
      client.bindCompanionReceiptInput(capability, folderRef: 'picked-folder', name: 'receipt.pdf'),
      throwsA(isA<DshProtocolException>()),
    );
    await expectLater(
      client.bindCompanionDraftInput(capability, folderRef: 'picked-folder', name: 'receipt.txt'),
      throwsA(isA<DshRemoteException>()),
    );
    expect(requests, hasLength(1));
  });

  test('J advertising the kind without its bounded parser and artifact capability is rejected', () async {
    for (final change in <MemoryRow>[
      {'receiptInputs': null},
      {'artifactRead': false},
      {
        'receiptInputs': {...(_capability['receiptInputs']! as MemoryRow), 'maxFiles': 5},
      },
      {
        'receiptInputs': {
          ...(_capability['receiptInputs']! as MemoryRow),
          'formats': ['pdf', 'png'],
        },
      },
    ]) {
      respond = (request, _) => _json(request, {..._capability, ...change});
      await expectLater(client.readCompanionTasksCapability(), throwsA(isA<DshProtocolException>()));
    }
    expect(requests, hasLength(4));
    expect(requests.every((request) => request.uri.path.endsWith('/capabilities')), isTrue);
  });

  test('J an old Host or another client cannot use a receipt capability as a grant', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    final second = DshClient(DshConnection(uri));
    try {
      await expectLater(
        second.bindCompanionReceiptInput(capability, folderRef: 'folder', name: 'receipt.txt'),
        throwsA(isA<DshRemoteException>()),
      );
    } finally {
      await second.close();
    }
    respond = (request, _) => _json(request, {
      ..._capability,
      'kinds': ['host.notes_to_todo'],
    });
    final older = (await client.readCompanionTasksCapability())!;
    expect(older.receiptsToSheet, isFalse);
    await expectLater(
      client.bindCompanionReceiptInput(older, folderRef: 'folder', name: 'receipt.txt'),
      throwsA(isA<DshRemoteException>()),
    );
    expect(requests, hasLength(2));
  });

  for (final name in ['../receipt.txt', 'folder/receipt.pdf', r'folder\receipt.pdf', 'receipt.png', 'bad\u0000.pdf']) {
    test('J refuses unsupported input $name before HTTP', () async {
      final capability = (await client.readCompanionTasksCapability())!;
      await expectLater(
        client.bindCompanionReceiptInput(capability, folderRef: 'folder', name: name),
        throwsA(isA<DshProtocolException>()),
      );
      expect(requests, hasLength(1));
    });
  }

  test('J receipt input C0 and DEL names are rejected before HTTP', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    for (final code in [...List<int>.generate(32, (index) => index), 127]) {
      await expectLater(
        client.bindCompanionReceiptInput(
          capability,
          folderRef: 'folder',
          name: 'receipt${String.fromCharCode(code)}.txt',
        ),
        throwsA(isA<DshProtocolException>()),
      );
    }
    expect(requests, hasLength(1));
    expect(requests.single.uri.path, '$_path/capabilities');
  });

  final invalidBinding = <String, Object?>{
    'hostStoreId': 'replacement-store',
    'version': '',
    'size': 4194305,
    'mediaType': 'text/plain',
    'content': 'Not a binding response',
  };
  for (final entry in invalidBinding.entries) {
    test('J refuses a receipt binding with substituted ${entry.key}', () async {
      final capability = (await client.readCompanionTasksCapability())!;
      respond = (request, _) => _json(request, {...receiptBindings()[2], entry.key: entry.value}, status: 201);
      await expectLater(
        client.bindCompanionReceiptInput(capability, folderRef: 'folder', name: '3.pdf'),
        throwsA(isA<DshProtocolException>()),
      );
      expect(requests, hasLength(2));
    });
  }

  test('J four actual HTTP bindings and output are persisted before the immutable create POST', () async {
    final capability = (await client.readCompanionTasksCapability())!;
    respond = (request, body) {
      final name = (body! as Map<String, Object?>)['name'];
      return _json(request, receiptBindings().singleWhere((input) => input['displayName'] == name), status: 201);
    };
    final inputs = <MemoryRow>[];
    for (final input in receiptBindings()) {
      inputs.add(
        await client.bindCompanionReceiptInput(
          capability,
          folderRef: 'original-inputs',
          name: input['displayName']! as String,
        ),
      );
    }
    respond = (request, body) {
      expect(body, {'v': 1, 'hostStoreId': 'original-store', 'path': '/chosen/output'});
      return _json(request, receiptOutput(), status: 201);
    };
    final output = await client.bindCompanionNotesDirectory(capability, '/chosen/output');
    final store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => receiptTime);
    try {
      store.submitMessage(
        id: 'source',
        sessionId: 'light:room',
        role: 'user',
        scope: 'real',
        text: '把四张原票整理成新表，离开也继续。',
        saidAtUtc: receiptTime,
        offsetMinutes: 480,
      );
      final task = store.createReceiptsTaskFromMessage(
        messageId: 'source',
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: 'light',
        hostKey: 'original-host',
        agreement: receiptAgreement(inputs: inputs, output: output),
        inputs: inputs,
        outputDirectory: output,
      );
      final id = task['task_id']! as String;
      expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
      final command = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'original-host',
        hostStoreId: 'original-store',
        initialOpportunity: true,
      )!;
      respond = (request, body) {
        expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], receiptTime);
        expect(body, command['request']);
        expect((body! as MemoryRow)['kind'], 'host.receipts_to_sheet');
        return _json(request, receiptSnapshot(store, id), status: 201);
      };
      final snapshot = await client.writeCompanionHostTask(
        taskId: id,
        operation: 'create',
        request: command['request']! as MemoryRow,
      );
      expect(
        store.importHostTaskSnapshot(taskId: id, hostKey: 'original-host', snapshot: snapshot)['state'],
        'running',
      );
      expect(requests.where((request) => request.uri.path == _path), hasLength(1));
      expect(requests.any((request) => request.uri.path == '/api/file'), isFalse);
    } finally {
      store.close();
    }
  });

  test('J actual Host wire survives four bindings, immutable POST, partial report and original workbook GET', () async {
    // Actual pinned Domain/JSON/anchored FS/HTTP/PDF/workbook producer output.
    // Only its fixed-turn owner was controlled, with zero model calls. This
    // consumer replays the captured bytes; it does not rerun Host or PDF IO.
    final wire = jsonDecode(File('test/fixtures/companion_receipts_host_wire.json').readAsStringSync()) as MemoryRow;
    expect(wire['scope'], 'ACTUAL_PINNED_DOMAIN_FS_HTTP_PDF_WORKBOOK_CONTROLLED_FIXED_TURN_OWNER_NO_MODEL');
    final original = wire['create']! as MemoryRow, origin = original['origin']! as MemoryRow;
    final folder = wire['folder']! as MemoryRow;
    final selected = (wire['inputs']! as List<Object?>).cast<MemoryRow>().toList();
    final accepted = wire['createReply']! as MemoryRow, completed = wire['complete']! as MemoryRow;
    final id = original['taskId']! as String, originalStore = original['hostStoreId']! as String;
    final now = accepted['createdAtMs']! as int;
    final bytes = File('test/fixtures/companion_receipts_host_workbook.xlsx').readAsBytesSync();
    expect(bytes, base64Decode(wire['workbookBase64']! as String));
    final directory = await Directory.systemTemp.createTemp('companion-receipts-wire-');
    var store = CompanionMemoryStore(
      sqlite3.open('${directory.path}/memory.sqlite'),
      nowMilliseconds: () => now,
      createId: () => id,
    );
    try {
      respond = (request, body) {
        if (request.uri.path == '$_path/capabilities') return _json(request, wire['capabilities']);
        if (request.uri.path == '$_path/folders') {
          expect(body, {'v': 1, 'hostStoreId': originalStore, 'path': folder['displayPath']});
          return _json(request, folder, status: 201);
        }
        if (request.uri.path == '$_path/inputs') {
          final input = body! as MemoryRow;
          final binding = selected.singleWhere((value) => value['displayName'] == input['name']);
          expect(input, {
            'v': 1,
            'hostStoreId': originalStore,
            'folderRef': folder['folderRef'],
            'name': binding['displayName'],
            'kind': 'host.receipts_to_sheet',
          });
          return _json(request, binding, status: 201);
        }
        if (request.method == 'POST' && request.uri.path == _path) {
          expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], now);
          expect(body, original);
          return _json(request, accepted, status: 201);
        }
        expect(request.method, 'GET');
        if (request.uri.path.endsWith('/content')) {
          final registered = (completed['artifacts']! as List<Object?>).single! as MemoryRow;
          expect(request.uri.path, '$_path/$id/artifacts/${registered['artifactId']}/content');
          expect(request.uri.queryParameters, {
            'hostStoreId': originalStore,
            'hostExecutionId': completed['hostExecutionId'],
          });
          return _bytes(request, bytes);
        }
        expect(request.uri.path, '$_path/$id');
        expect(request.uri.queryParameters, {'hostStoreId': originalStore});
        return _json(request, completed);
      };
      final capability = (await client.readCompanionTasksCapability())!;
      expect(capability.receiptsToSheet, isTrue);
      final output = await client.bindCompanionNotesDirectory(capability, folder['displayPath']! as String);
      final bindings = <MemoryRow>[];
      for (final input in selected) {
        bindings.add(
          await client.bindCompanionReceiptInput(
            capability,
            folderRef: output['folderRef']! as String,
            name: input['displayName']! as String,
          ),
        );
      }
      expect(bindings, selected);
      store.submitMessage(
        id: origin['messageId']! as String,
        sessionId: origin['sourceSessionId']! as String,
        role: 'user',
        scope: 'real',
        text: '这四张已选原票帮我新建差旅小表，离开也继续。',
        saidAtUtc: now,
        offsetMinutes: 0,
      );
      final task = store.createReceiptsTaskFromMessage(
        messageId: origin['messageId']! as String,
        expectedSourceRev: 1,
        itemNo: origin['itemNo']! as int,
        roomMode: 'light',
        hostKey: 'fixture-original-host',
        inputs: bindings,
        outputDirectory: output,
        agreement: {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: original[key],
        },
      );
      expect(task['task_id'], id);
      final command = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'fixture-original-host',
        hostStoreId: originalStore,
        initialOpportunity: true,
      )!;
      final reply = await client.writeCompanionHostTask(
        taskId: id,
        operation: 'create',
        request: command['request']! as MemoryRow,
      );
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: reply);
      expect(store.hostTask(id)!['snapshot'], accepted);
      final snapshot = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: snapshot);
      expect(store.hostTask(id)!['snapshot'], completed);
      final steps = (snapshot['steps']! as List<Object?>).cast<MemoryRow>().toList();
      final read = ((steps.first['result']! as MemoryRow)['completion']! as MemoryRow)['report']! as MemoryRow;
      final report = ((steps.last['result']! as MemoryRow)['completion']! as MemoryRow)['report']! as MemoryRow;
      final coverage = report['coverage']! as MemoryRow;
      expect(steps.first['state'], 'done');
      expect(snapshot['state'], 'partial');
      expect(coverage['readCompleteCount'], 4);
      expect(coverage['parseCompleteCount'], 4);
      expect(coverage['rowsWithVerifiedFields'], 3);
      expect(coverage['fullyVerifiedRows'], 3);
      expect(
        (read['sources']! as List<Object?>).cast<MemoryRow>().every((source) => source['verifiedAtPublish'] == false),
        isTrue,
      );
      final scan = (report['sources']! as List<Object?>).last! as MemoryRow;
      expect(scan['reason'], 'pdf_empty_text');
      expect(scan['textLayerOnly'], isTrue);
      expect(scan['verifiedAtPublish'], isTrue);
      final scanRow = (report['rows']! as List<Object?>).last! as MemoryRow;
      for (final name in const ['date', 'item', 'amount']) {
        expect((scanRow[name]! as MemoryRow)['state'], 'unverified');
        expect((scanRow[name]! as MemoryRow)['value'], isNull);
      }
      final originalCommands = store.hostTaskCommands(id);
      store.submitMessage(
        id: 'later-amend',
        sessionId: origin['sourceSessionId']! as String,
        role: 'user',
        scope: 'real',
        text: '已经有表，再改一个名字。',
        saidAtUtc: now,
        offsetMinutes: 0,
      );
      expect(
        () => store.amendReceiptsTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'later-amend',
          expectedSourceRev: 1,
          itemNo: 0,
          inputs: bindings,
          outputDirectory: output,
          agreement: {
            for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: original[key],
          },
        ),
        throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/conflict')),
      );
      expect(store.hostTaskCommands(id), originalCommands);
      expect(store.hostTask(id)!['task_rev'], 1);
      expect(store.taskForCommand('later-amend', 0), isNull);
      expect(store.hostTask(id)!['snapshot'], completed);
      final registered = (snapshot['artifacts']! as List<Object?>).single! as MemoryRow;
      expect(
        await client.readCompanionHostArtifactBytes(
          hostStoreId: originalStore,
          taskId: id,
          hostExecutionId: snapshot['hostExecutionId']! as String,
          artifact: registered,
        ),
        bytes,
      );
      store.close();
      store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
      expect(store.hostTask(id)!['snapshot'], completed);
      expect(store.hostTask(id)!['state'], 'partial');
      expect(store.hostTaskInputs(hostKey: 'fixture-original-host'), selected);
      store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: accepted);
      expect(store.hostTask(id)!['applied_host_receipt_seq'], completed['runnerReceiptSeq']);
      expect(requests.where((request) => request.method == 'POST' && request.uri.path == _path), hasLength(1));
      expect(requests.where((request) => request.uri.path.endsWith('/content')), hasLength(1));
      expect(
        requests.any((request) => request.uri.path.contains('/sources/') || request.uri.path == '/api/file'),
        isFalse,
      );
      expect(store.taskReceipts(id), isEmpty);
    } finally {
      store.close();
      await directory.delete(recursive: true);
    }
  });

  for (final variant in const ['mixed', 'owner_stopped', 'read_stopped', 'all_changed']) {
    test(
      'J actual $variant Host report keeps its original identity and complete history across HTTP and reopen',
      () async {
        final wire =
            jsonDecode(File('test/fixtures/companion_receipts_${variant}_host_wire.json').readAsStringSync())
                as MemoryRow;
        final original = wire['create']! as MemoryRow, origin = original['origin']! as MemoryRow;
        final before = wire['before'] as MemoryRow?, completed = wire['complete']! as MemoryRow;
        final id = original['taskId']! as String, originalStore = original['hostStoreId']! as String;
        final now = completed['createdAtMs']! as int;
        final directory = await Directory.systemTemp.createTemp('companion-receipts-$variant-');
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
            text: '四张原票，新建表格，离开继续。',
            saidAtUtc: now,
            offsetMinutes: 0,
          );
          // These smaller producer captures omit the directory's UI label. Only
          // that phone label is controlled; the actual accepted store/ref and all
          // input bindings, source identities and Host snapshots stay unchanged.
          store.createReceiptsTaskFromMessage(
            messageId: origin['messageId']! as String,
            expectedSourceRev: 1,
            itemNo: origin['itemNo']! as int,
            roomMode: 'light',
            hostKey: 'fixture-original-host',
            inputs: (wire['inputs']! as List<Object?>).cast<MemoryRow>().toList(),
            outputDirectory: {
              'v': 1,
              'hostStoreId': originalStore,
              'folderRef': (original['args']! as MemoryRow)['outputDirRef'],
              'displayPath': 'Original selected output (controlled display label)',
            },
            agreement: {
              for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: original[key],
            },
          );
          final command = store.prepareHostTaskOperation(
            taskId: id,
            taskRev: 1,
            hostKey: 'fixture-original-host',
            hostStoreId: originalStore,
            initialOpportunity: true,
          )!;
          expect(command['request'], original);
          var response = before ?? completed;
          respond = (request, _) {
            expect(request.method, 'GET');
            expect(request.uri.path, '$_path/$id');
            expect(request.uri.queryParameters, {'hostStoreId': originalStore});
            return _json(request, response);
          };
          final first = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: first);
          expect(store.hostTask(id)!['snapshot'], response);
          if (before != null) {
            final oldSteps = (before['steps']! as List<Object?>).cast<MemoryRow>().toList();
            for (final fault in ['unproved-retry', 'changed-old-step', 'published-then-running']) {
              final malformed = receiptCopy(completed);
              final steps = (malformed['steps']! as List<Object?>).cast<MemoryRow>().toList();
              if (fault == 'unproved-retry') {
                if (variant == 'read_stopped') {
                  steps.first['reason'] = 'ordinary_read_failure';
                } else {
                  final old = steps.singleWhere((step) => step['attemptId'] == oldSteps.last['attemptId']);
                  (old['result']! as MemoryRow)['completion'] = {
                    'report': ((old['result']! as MemoryRow)['completion']! as MemoryRow)['report'],
                  };
                }
              } else if (fault == 'changed-old-step') {
                steps.first['finishedAtMs'] = (steps.first['finishedAtMs']! as int) + 1;
              } else {
                (malformed['steps']! as List<Object?>).add({
                  'taskRev': 1,
                  'stepKey': 'writeSheet',
                  'attemptId': 'extra-write',
                  'state': 'running',
                  'startedAtMs': now,
                  'finishedAtMs': null,
                  'reason': null,
                  'result': null,
                });
              }
              expect(
                () => store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: malformed),
                throwsA(
                  isA<DshRemoteException>().having(
                    (error) => error.code,
                    'code',
                    fault == 'changed-old-step' ? 'companion/conflict' : 'companion/task-invalid-request',
                  ),
                ),
              );
              expect(store.hostTask(id)!['snapshot'], before);
            }
            response = completed;
            final recovered = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
            store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: recovered);
            final steps = (recovered['steps']! as List<Object?>).cast<MemoryRow>().toList();
            for (final old in oldSteps) {
              expect(steps.singleWhere((step) => step['attemptId'] == old['attemptId']), old);
            }
            expect(
              steps.where((step) => step['stepKey'] == (variant == 'read_stopped' ? 'readInputs' : 'writeSheet')),
              hasLength(2),
            );
          } else if (variant == 'mixed') {
            final steps = (completed['steps']! as List<Object?>).cast<MemoryRow>();
            final report = ((steps.last['result']! as MemoryRow)['completion']! as MemoryRow)['report']! as MemoryRow;
            final row = (report['rows']! as List<Object?>).last! as MemoryRow;
            expect((row['amount']! as MemoryRow)['state'], 'verified');
            expect((row['date']! as MemoryRow)['state'], 'unverified');
            expect((row['item']! as MemoryRow)['state'], 'unverified');
            expect(((report['sources']! as List<Object?>).last! as MemoryRow)['textLayerOnly'], isTrue);
          }
          if (variant == 'all_changed') {
            final steps = (completed['steps']! as List<Object?>).cast<MemoryRow>().toList();
            final read = ((steps.first['result']! as MemoryRow)['completion']! as MemoryRow)['report']! as MemoryRow;
            final write = ((steps.last['result']! as MemoryRow)['completion']! as MemoryRow)['report']! as MemoryRow;
            expect((read['coverage']! as MemoryRow)['rowsWithVerifiedFields'], 4);
            expect((write['coverage']! as MemoryRow)['rowsWithVerifiedFields'], 0);
            expect(steps.last['state'], 'failed');
            expect(steps.last['reason'], 'receipt_fields_unavailable');
            for (final fault in ['false-partial', 'missing-zero-write', 'wrong-stage-reason']) {
              final malformed = receiptCopy(completed)
                ..['runnerReceiptSeq'] = (completed['runnerReceiptSeq']! as int) + 1;
              if (fault == 'false-partial') {
                malformed['state'] = 'partial';
              } else if (fault == 'missing-zero-write') {
                (malformed['steps']! as List<Object?>).removeLast();
              } else {
                ((malformed['steps']! as List<Object?>).last! as MemoryRow)['reason'] = 'other_failure';
              }
              expect(
                () => store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: malformed),
                throwsA(
                  isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-invalid-request'),
                ),
              );
              expect(store.hostTask(id)!['snapshot'], completed);
            }
          }
          store.close();
          store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
          expect(store.hostTask(id)!['snapshot'], completed);
          expect(store.hostTask(id)!['state'], variant == 'all_changed' ? 'failed' : 'partial');
          expect((completed['artifacts']! as List<Object?>), hasLength(variant == 'all_changed' ? 0 : 1));
          if (before != null) {
            response = before;
            final delayed = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
            store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: delayed);
            expect(store.hostTask(id)!['snapshot'], completed);
          }
          expect(store.hostTask(id)!['applied_host_receipt_seq'], completed['runnerReceiptSeq']);
          expect(requests, hasLength(before == null ? 1 : 3));
          expect(requests.every((request) => request.method == 'GET'), isTrue);
          expect(store.taskReceipts(id), isEmpty);
        } finally {
          store.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  for (final operation in const ['amend', 'cancel']) {
    test(
      'J actual late artifact after accepted $operation remains an old effect without completing the new agreement',
      () async {
        // Actual SIGKILL-after-link -> original-store reopen -> accepted rev2 ->
        // read-only reconciliation. This consumer keeps every original wire ID.
        final wire =
            jsonDecode(File('test/fixtures/companion_receipts_late_${operation}_host_wire.json').readAsStringSync())
                as MemoryRow;
        final create = wire['create']! as MemoryRow, origin = create['origin']! as MemoryRow;
        final original = wire['original']! as MemoryRow, commandWire = wire['operation']! as MemoryRow;
        final accepted = wire['accepted']! as MemoryRow, completed = wire['complete']! as MemoryRow;
        final id = create['taskId']! as String, originalStore = create['hostStoreId']! as String;
        final inputs = (wire['inputs']! as List<Object?>).cast<MemoryRow>().toList();
        final output = <String, Object?>{
          'v': 1,
          'hostStoreId': originalStore,
          'folderRef': (create['args']! as MemoryRow)['outputDirRef'],
          'displayPath': 'Original selected output (controlled display label)',
        };
        final now = original['createdAtMs']! as int;
        var nextId = id;
        final directory = await Directory.systemTemp.createTemp('companion-receipts-late-$operation-');
        var store = CompanionMemoryStore(
          sqlite3.open('${directory.path}/memory.sqlite'),
          nowMilliseconds: () => now,
          createId: () => nextId,
        );
        try {
          store.submitMessage(
            id: origin['messageId']! as String,
            sessionId: origin['sourceSessionId']! as String,
            role: 'user',
            scope: 'real',
            text: '这四份票据，新建一张表，离开继续。',
            saidAtUtc: now,
            offsetMinutes: 0,
          );
          store.createReceiptsTaskFromMessage(
            messageId: origin['messageId']! as String,
            expectedSourceRev: 1,
            itemNo: origin['itemNo']! as int,
            roomMode: 'light',
            hostKey: 'fixture-original-host',
            inputs: inputs,
            outputDirectory: output,
            agreement: {
              for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: create[key],
            },
          );
          final firstCommand = store.prepareHostTaskOperation(
            taskId: id,
            taskRev: 1,
            hostKey: 'fixture-original-host',
            hostStoreId: originalStore,
            initialOpportunity: true,
          )!;
          expect(firstCommand['request'], create);
          var response = original;
          respond = (request, body) {
            if (request.method == 'POST') {
              expect(request.uri.path, '$_path/$id/$operation');
              expect(body, commandWire);
              expect(store.hostTaskCommands(id).last['possible_sent_at_ms'], now);
              return _json(request, accepted);
            }
            expect(request.method, 'GET');
            expect(request.uri.path, '$_path/$id');
            expect(request.uri.queryParameters, {'hostStoreId': originalStore});
            return _json(request, response);
          };
          final observed = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: observed);
          expect(observed['artifacts'], isEmpty);
          expect((observed['budget']! as MemoryRow)['heldMs'], 120000);
          final oldRead = receiptCopy((observed['steps']! as List<Object?>).first! as MemoryRow);
          nextId = commandWire['operationId']! as String;
          store.submitMessage(
            id: 'new-$operation-source',
            sessionId: origin['sourceSessionId']! as String,
            role: 'user',
            scope: 'real',
            text: operation == 'cancel' ? '取消这次整理票据。' : '把未完成的约定按新文件名改好。',
            saidAtUtc: now,
            offsetMinutes: 0,
          );
          if (operation == 'amend') {
            store.amendReceiptsTask(
              taskId: id,
              expectedTaskRev: 1,
              messageId: 'new-$operation-source',
              expectedSourceRev: 1,
              itemNo: 0,
              inputs: inputs,
              outputDirectory: output,
              agreement: commandWire['changes']! as MemoryRow,
            );
          } else {
            store.cancelReceiptsTask(
              taskId: id,
              expectedTaskRev: 1,
              messageId: 'new-$operation-source',
              expectedSourceRev: 1,
              itemNo: 0,
            );
          }
          final savedCommand = store.prepareHostTaskOperation(
            taskId: id,
            taskRev: 2,
            hostKey: 'fixture-original-host',
            hostStoreId: originalStore,
            initialOpportunity: true,
          )!;
          expect(savedCommand['request'], commandWire);
          final reply = await client.writeCompanionHostTask(
            taskId: id,
            operation: operation,
            request: savedCommand['request']! as MemoryRow,
          );
          expect(
            store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: reply)['state'],
            'unknown',
          );
          response = completed;
          final reconciled = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: reconciled);
          expect(store.hostTask(id)!['snapshot'], completed);
          expect(store.hostTask(id)!['task_rev'], 2);
          expect(store.hostTask(id)!['state'], operation == 'amend' ? 'partial' : 'cancelled');
          final savedArtifact = (reconciled['artifacts']! as List<Object?>).single! as MemoryRow;
          expect(savedArtifact['taskRev'], 1);
          final steps = (reconciled['steps']! as List<Object?>).cast<MemoryRow>().toList();
          expect(steps.every((step) => step['taskRev'] == 1), isTrue);
          expect(steps.first, oldRead);
          expect((reconciled['budget']! as MemoryRow)['heldMs'], 120000);
          if (operation == 'amend') {
            expect(reconciled['waitReason'], 'prior_revision_effect');
            for (final fault in ['promoted-current-done', 'unexplained-partial', 'no-artifact']) {
              final malformed = receiptCopy(completed)
                ..['runnerReceiptSeq'] = (completed['runnerReceiptSeq']! as int) + 1;
              if (fault == 'promoted-current-done') {
                malformed['state'] = 'done';
              } else if (fault == 'unexplained-partial') {
                malformed['waitReason'] = 'other_partial';
              } else {
                malformed['steps'] = <Object?>[];
                malformed['artifacts'] = <Object?>[];
              }
              expect(
                () => store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: malformed),
                throwsA(
                  isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-invalid-request'),
                ),
              );
            }
            store.submitMessage(
              id: 'third-agreement',
              sessionId: origin['sourceSessionId']! as String,
              role: 'user',
              scope: 'real',
              text: '再改一个表名。',
              saidAtUtc: now,
              offsetMinutes: 0,
            );
            final commands = store.hostTaskCommands(id);
            expect(
              () => store.amendReceiptsTask(
                taskId: id,
                expectedTaskRev: 2,
                messageId: 'third-agreement',
                expectedSourceRev: 1,
                itemNo: 0,
                inputs: inputs,
                outputDirectory: output,
                agreement: commandWire['changes']! as MemoryRow,
              ),
              throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/conflict')),
            );
            expect(store.hostTaskCommands(id), commands);
            expect(store.taskForCommand('third-agreement', 0), isNull);
          }
          store.close();
          store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
          expect(store.hostTask(id)!['snapshot'], completed);
          response = accepted;
          final delayed = (await client.readCompanionHostTask(hostStoreId: originalStore, taskId: id))!;
          store.importHostTaskSnapshot(taskId: id, hostKey: 'fixture-original-host', snapshot: delayed);
          expect(store.hostTask(id)!['snapshot'], completed);
          expect(store.hostTask(id)!['applied_host_receipt_seq'], completed['runnerReceiptSeq']);
          expect((store.hostTask(id)!['snapshot']! as MemoryRow)['artifacts'], [savedArtifact]);
          expect(requests, hasLength(4));
          expect(requests.where((request) => request.method == 'POST'), hasLength(1));
          expect(requests.any((request) => request.uri.path == _path), isFalse);
          expect(store.taskReceipts(id), isEmpty);
        } finally {
          store.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test('J original artifact bytes use the same authenticated custom client and exact size and digest', () async {
    final store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => receiptTime);
    try {
      store.submitMessage(
        id: 'source',
        sessionId: 'light:room',
        role: 'user',
        scope: 'real',
        text: '请新建差旅小表。',
        saidAtUtc: receiptTime,
        offsetMinutes: 480,
      );
      final id =
          store.createReceiptsTaskFromMessage(
                messageId: 'source',
                expectedSourceRev: 1,
                itemNo: 0,
                roomMode: 'light',
                hostKey: 'original-host',
                agreement: receiptAgreement(),
                inputs: receiptBindings(),
                outputDirectory: receiptOutput(),
              )['task_id']!
              as String;
      final snapshot = receiptSnapshot(
        store,
        id,
        state: 'done',
        writeReports: {1: receiptReport()},
        artifacts: [artifact],
      );
      final imported = store.importHostTaskSnapshot(taskId: id, hostKey: 'original-host', snapshot: snapshot);
      final registered = (((imported['snapshot']! as MemoryRow)['artifacts']! as List<Object?>).single as MemoryRow);
      respond = (request, body) {
        expect(request.method, 'GET');
        expect(request.uri.path, '$_path/$id/artifacts/original-artifact/content');
        expect(request.uri.queryParameters, {'hostStoreId': 'original-store', 'hostExecutionId': 'original-execution'});
        expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=fixture-cookie');
        expect(request.headers.value(HttpHeaders.userAgentHeader), 'original-receipt-client');
        return _bytes(request, workbook);
      };
      expect(
        await client.readCompanionHostArtifactBytes(
          hostStoreId: 'original-store',
          taskId: id,
          hostExecutionId: 'original-execution',
          artifact: registered,
        ),
        workbook,
      );
      expect(requests, hasLength(1));
      expect(store.hostTask(id)!['snapshot'], snapshot);
    } finally {
      store.close();
    }
  });

  for (final problem in ['mime', 'length', 'hash']) {
    test('J workbook $problem mismatch is not returned or retried', () async {
      respond = (request, _) => _bytes(
        request,
        problem == 'length'
            ? workbook.take(workbook.length - 1).toList()
            : problem == 'hash'
            ? [workbook.first ^ 1, ...workbook.skip(1)]
            : workbook,
        mime: problem == 'mime' ? 'text/plain' : workbookMediaType,
      );
      await expectLater(
        client.readCompanionHostArtifactBytes(
          hostStoreId: 'original-store',
          taskId: 'task',
          hostExecutionId: 'original-execution',
          artifact: artifact,
        ),
        throwsA(isA<DshProtocolException>()),
      );
      expect(requests, hasLength(1));
    });
  }

  test('J oversized streaming body is stopped by the connection cap without a fallback GET', () async {
    respond = (request, _) async {
      request.response.headers.contentType = ContentType.parse(workbookMediaType);
      request.response.add(List<int>.filled(262145, 1));
      await request.response.close();
    };
    await expectLater(
      client.readCompanionHostArtifactBytes(
        hostStoreId: 'original-store',
        taskId: 'task',
        hostExecutionId: 'original-execution',
        artifact: artifact,
      ),
      throwsA(isA<DshProtocolException>()),
    );
    expect(requests, hasLength(1));
  });

  test('J artifact redirects and missing or changed originals never turn into path reads', () async {
    respond = (request, _) async {
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/api/file?path=/other.xlsx');
      await request.response.close();
    };
    await expectLater(
      client.readCompanionHostArtifactBytes(
        hostStoreId: 'original-store',
        taskId: 'task',
        hostExecutionId: 'original-execution',
        artifact: artifact,
      ),
      throwsA(isA<DshHttpException>()),
    );
    for (final status in [404, 409, 503]) {
      respond = (request, _) => _json(request, {
        'error': {'code': 'companion/task-artifact-unavailable', 'message': 'Original unavailable'},
      }, status: status);
      await expectLater(
        client.readCompanionHostArtifactBytes(
          hostStoreId: 'original-store',
          taskId: 'task',
          hostExecutionId: 'original-execution',
          artifact: artifact,
        ),
        throwsA(isA<DshRemoteException>()),
      );
    }
    expect(requests, hasLength(4));
    expect(requests.every((request) => request.uri.path.endsWith('/content') && request.method == 'GET'), isTrue);
  });

  test('J rejects unimportable artifact metadata before contacting the Host', () async {
    for (final change in <MemoryRow>[
      {'size': 262145},
      {'size': -1},
      {'mediaType': 'text/plain'},
      {'sha256': 'unknown'},
      {'artifactId': ''},
    ]) {
      await expectLater(
        client.readCompanionHostArtifactBytes(
          hostStoreId: 'original-store',
          taskId: 'task',
          hostExecutionId: 'original-execution',
          artifact: {...artifact, ...change},
        ),
        throwsA(isA<DshProtocolException>()),
      );
    }
    expect(requests, isEmpty);
  });
}
