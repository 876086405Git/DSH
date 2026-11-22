import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/receipt_task_fixtures.dart';

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = receiptTime;
  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  void say(String id, {String session = 'light:original-room', String role = 'user', String scope = 'real'}) {
    store.submitMessage(
      id: id,
      sessionId: session,
      role: role,
      scope: scope,
      text: '这四张票帮我做成差旅小表，新建一个文件，电脑上线后继续，离开也继续。',
      saidAtUtc: now,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
  }

  MemoryRow create(
    String message, {
    List<MemoryRow>? inputs,
    MemoryRow? output,
    MemoryRow? agreement,
    int itemNo = 0,
    String host = 'original-host',
  }) => store.createReceiptsTaskFromMessage(
    messageId: message,
    expectedSourceRev: 1,
    itemNo: itemNo,
    roomMode: 'light',
    hostKey: host,
    inputs: inputs ?? receiptBindings(),
    outputDirectory: output ?? receiptOutput(),
    agreement: agreement ?? receiptAgreement(inputs: inputs, output: output),
  );
  MemoryRow? prepare(
    String id,
    int revision, {
    bool initial = true,
    bool replay = false,
    String hostStore = 'original-store',
  }) => store.prepareHostTaskOperation(
    taskId: id,
    taskRev: revision,
    hostKey: 'original-host',
    hostStoreId: hostStore,
    initialOpportunity: initial,
    replayAfterRead: replay,
  );
  MemoryRow accept(String id, MemoryRow snapshot) =>
      store.importHostTaskSnapshot(taskId: id, hostKey: 'original-host', snapshot: snapshot);
  final invalid = throwsA(
    isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-invalid-request'),
  );
  final conflict = throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/conflict'));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-receipts-');
    now = receiptTime;
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('J saves four original inputs and output on v14 before any possible handoff', () {
    say('source');
    final task = create('source'), id = task['task_id']! as String;
    expect(task['kind'], 'host.receipts_to_sheet');
    expect(task['host_store_id'], 'original-store');
    expect(task['source_session_id'], 'light:original-room');
    expect(task['local_date'], isNull);
    expect(task['epoch_ms'], isNull);
    expect(task['directory_labels'], {'inputs': receiptBindings(), 'outputDirectory': receiptOutput()});
    final command = store.hostTaskCommands(id).single;
    expect(command['possible_sent_at_ms'], isNull);
    expect((command['request']! as MemoryRow)['args'], receiptAgreement()['args']);
    expect((command['request']! as MemoryRow).containsKey('hostStoreId'), isFalse);
    expect(database.select('PRAGMA user_version').single['user_version'], 16);
    expect(store.requests(), isEmpty);
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    reopen();
    expect(create('source'), task);
    expect(store.hostTaskCommands(id).single, command);
  });

  test('J source item retry is one task and a new source or item stays independent', () {
    say('one');
    say('two');
    final one = create('one');
    expect(create('one')['task_id'], one['task_id']);
    expect(create('two')['task_id'], isNot(one['task_id']));
    expect(create('one', itemNo: 1)['task_id'], isNot(one['task_id']));
    expect(() => create('one', inputs: receiptBindings(suffix: '-changed')), conflict);
    expect(store.tasks(), hasLength(3));
  });

  for (final source in [(role: 'assistant', scope: 'real'), (role: 'user', scope: 'story')]) {
    test('J ${source.role}/${source.scope} cannot grant an output', () {
      say('source', role: source.role, scope: source.scope);
      expect(() => create('source'), throwsA(isA<DshRemoteException>()));
      expect(store.tasks(), isEmpty);
    });
  }

  test('J rejects extra or repeated inputs, changed versions and a foreign output store atomically', () {
    say('source');
    expect(() => create('source', inputs: receiptBindings().take(3).toList()), invalid);
    expect(() => create('source', inputs: [...receiptBindings(), receiptBindings().first]), invalid);
    final duplicate = receiptBindings();
    duplicate[3] = duplicate[0];
    expect(() => create('source', inputs: duplicate), invalid);
    final changed = receiptBindings();
    changed[0]['version'] = 'replaced';
    expect(() => create('source', inputs: changed, agreement: receiptAgreement()), invalid);
    final mixed = receiptBindings();
    mixed[3]['hostStoreId'] = 'new-store';
    expect(() => create('source', inputs: mixed), invalid);
    expect(() => create('source', output: receiptOutput(store: 'new-store')), invalid);
    expect(store.tasks(), isEmpty);
  });

  test('J never broadens its selected formats, byte cap, basename or create-new mode', () {
    say('source');
    for (final change in <MemoryRow>[
      {'size': 4194305},
      {'mediaType': 'image/png'},
      {'content': 'whole source'},
    ]) {
      final inputs = receiptBindings();
      inputs[0].addAll(change);
      expect(() => create('source', inputs: inputs), invalid);
    }
    for (final change in <MemoryRow>[
      {'outputName': '../escape.xlsx'},
      {'outputName': 'notes.txt'},
      {'outputName': 'bad\u0000.xlsx'},
      {'writeMode': 'replace'},
      {'path': '/unbound/output'},
    ]) {
      final agreement = receiptAgreement();
      (agreement['args']! as MemoryRow).addAll(change);
      expect(() => create('source', agreement: agreement), invalid);
    }
    expect(store.tasks(), isEmpty);
  });

  test('J input and output names reject Host control characters without committing a task', () {
    say('source');
    for (final code in [...List<int>.generate(32, (index) => index), 127]) {
      final control = String.fromCharCode(code);
      final agreement = receiptAgreement();
      (agreement['args']! as MemoryRow)['outputName'] = 'receipt${control}table.xlsx';
      expect(() => create('source', agreement: agreement), invalid);
      final inputs = receiptBindings();
      inputs.first['displayName'] = 'receipt${control}input.txt';
      expect(() => create('source', inputs: inputs), invalid);
    }
    final tooLong = receiptBindings();
    tooLong.first['displayName'] = '${List<String>.filled(252, 'x').join()}.txt';
    expect(() => create('source', inputs: tooLong), invalid);
    final unsupported = receiptBindings();
    unsupported.first['displayName'] = 'receipt.png';
    expect(() => create('source', inputs: unsupported), invalid);
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_host_commands'), isEmpty);
  });

  test('J a failed immutable command insert rolls back task revision and original-store binding', () {
    say('source');
    database.execute('''CREATE TRIGGER fail_receipt BEFORE INSERT ON companion_host_commands
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    expect(() => create('source'), throwsA(isA<SqliteException>()));
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_host_tasks'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
  });

  test('J offline first delivery remains on its original store and possible delivery requires a read', () {
    say('source');
    final id = create('source')['task_id']! as String;
    expect(() => prepare(id, 1, hostStore: 'replacement-store'), throwsA(isA<DshRemoteException>()));
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
    final command = prepare(id, 1, initial: false)!;
    expect(command['possible_sent_at_ms'], now);
    expect((command['request']! as MemoryRow)['hostStoreId'], 'original-store');
    reopen();
    expect(
      () => prepare(id, 1),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-read-required')),
    );
    expect(prepare(id, 1, replay: true)!['request'], command['request']);
  });

  test('J a missed unqueued opportunity or original deadline never claims a first request', () {
    say('no-queue');
    final waiting = create('no-queue', agreement: receiptAgreement(allowQueue: false))['task_id']! as String;
    expect(prepare(waiting, 1, initial: false), isNull);
    expect(store.hostTask(waiting)!['state'], 'waiting');
    expect(store.hostTaskCommands(waiting).single['possible_sent_at_ms'], isNull);
    say('expired');
    final expired = create('expired', agreement: receiptAgreement(deadline: now + 1))['task_id']! as String;
    now += 1;
    expect(prepare(expired, 1), isNull);
    expect(store.hostTask(expired)!['state'], 'failed');
    expect(store.hostTaskCommands(expired).single['possible_sent_at_ms'], isNull);
  });

  test('J amend and cancel use new real sources in the same room and preserve the original create', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final original = store.hostTaskCommands(id).single;
    say('wrong-room', session: 'full:other');
    expect(
      () => store.amendReceiptsTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'wrong-room',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: receiptAgreement(),
        inputs: receiptBindings(),
        outputDirectory: receiptOutput(),
      ),
      invalid,
    );
    say('change');
    final inputs = receiptBindings(suffix: '-new');
    final changed = store.amendReceiptsTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'change',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: receiptAgreement(inputs: inputs),
      inputs: inputs,
      outputDirectory: receiptOutput(),
    );
    expect(changed['task_rev'], 2);
    expect(store.hostTaskCommands(id).first, original);
    expect(() => prepare(id, 1), conflict);
    say('cancel');
    final cancelled = store.cancelReceiptsTask(
      taskId: id,
      expectedTaskRev: 2,
      messageId: 'cancel',
      expectedSourceRev: 1,
      itemNo: 0,
    );
    expect(cancelled['state'], 'cancelled');
    expect(cancelled['task_rev'], 3);
    expect(() => prepare(id, 2), conflict);
  });

  test('J an unpublished failed or unknown task can still accept an explicit new agreement', () {
    for (final state in ['failed', 'unknown']) {
      say('source-$state');
      final id = create('source-$state')['task_id']! as String;
      accept(id, receiptSnapshot(store, id, state: state));
      say('amend-$state');
      final inputs = receiptBindings(suffix: '-$state');
      final amended = store.amendReceiptsTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'amend-$state',
        expectedSourceRev: 1,
        itemNo: 0,
        inputs: inputs,
        outputDirectory: receiptOutput(),
        agreement: receiptAgreement(inputs: inputs),
      );
      expect(amended['task_rev'], 2);
      expect(store.hostTaskCommands(id), hasLength(2));
    }
  });

  test('J an amend barrier arriving before create only permits the immutable original to fill the missing origin', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final original = store.hostTaskCommands(id).first['request'];
    say('change');
    final inputs = receiptBindings(suffix: '-new');
    store.amendReceiptsTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'change',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: receiptAgreement(inputs: inputs),
      inputs: inputs,
      outputDirectory: receiptOutput(),
    );
    prepare(id, 2);
    final barrier = receiptSnapshot(store, id, revision: 2, state: 'waiting', original: false);
    expect(accept(id, barrier)['task_rev'], 2);
    reopen();
    final fill = prepare(id, 1, replay: true)!;
    expect(fill['request'], {...(original! as MemoryRow), 'hostStoreId': 'original-store'});
    expect(store.hostTask(id)!['task_rev'], 2);
    expect((store.hostTask(id)!['agreement']! as MemoryRow)['args'], receiptAgreement(inputs: inputs)['args']);
  });

  test('J saved input and output choices remain available after 100 unrelated tasks', () {
    say('receipt');
    final id = create('receipt')['task_id']! as String;
    for (var index = 0; index < 101; index++) {
      now++;
      say('later-$index');
      store.createFindDraftTaskFromMessage(
        messageId: 'later-$index',
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: 'light',
        hostKey: 'other-host',
        directoryHostStoreId: 'other-store',
        agreement: {
          'args': {
            'folderRef': 'other-directory',
            'scope': 'currentLevel',
            'localDate': '2026-11-20',
            'timeZone': 'Asia/Shanghai',
            'dateBy': 'modified',
            'extensions': ['md', 'txt'],
          },
          'deadlineAtMs': null,
          'afterExit': 'continue',
          'allowQueue': true,
        },
      );
    }
    expect(store.tasks().any((row) => row['task_id'] == id), isFalse);
    reopen();
    expect(store.pendingReceiptsTasks(hostKey: 'original-host').single['task_id'], id);
    expect(store.hostTaskInputs(hostKey: 'original-host'), receiptBindings());
    expect(store.hostTaskDirectories(hostKey: 'original-host'), [
      {'hostStoreId': 'original-store', 'folderRef': 'original-output', 'displayPath': '/chosen/output'},
    ]);
    expect(store.pendingReceiptsTasks(hostKey: 'replacement-host'), isEmpty);
  });

  test('J three read sources and one unread source keep an honest four-row partial artifact across reopen', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final read = receiptReport(unread: {3}, verifiedAtPublish: false);
    final done = receiptReport(unread: {3});
    final snapshot = receiptSnapshot(
      store,
      id,
      state: 'partial',
      readReports: {1: read},
      writeReports: {1: done},
      artifacts: [receiptArtifact()],
    );
    final result = accept(id, snapshot);
    expect(result['state'], 'partial');
    expect(result['snapshot'], snapshot);
    expect((done['coverage']! as MemoryRow)['rowsWithVerifiedFields'], 3);
    expect(((snapshot['artifacts']! as List<Object?>).single as MemoryRow)['sourceCount'], 4);
    reopen();
    expect(store.hostTask(id)!['snapshot'], snapshot);
    expect(store.requests(), isEmpty);
  });

  test('J all unverified observations fail without a workbook rather than manufacturing an empty success', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final report = receiptReport(unread: {0, 1, 2, 3}, verifiedAtPublish: false);
    final snapshot = receiptSnapshot(
      store,
      id,
      state: 'failed',
      reason: 'receipt_fields_unavailable',
      readReports: {1: report},
    );
    expect(accept(id, snapshot)['state'], 'failed');
    expect(snapshot['artifacts'], isEmpty);
    expect((snapshot['steps']! as List<Object?>), hasLength(1));
    final falseSuccess = receiptSnapshot(
      store,
      id,
      seq: 2,
      state: 'partial',
      readReports: {1: report},
      writeReports: {1: report},
      artifacts: [receiptArtifact()],
    );
    expect(() => accept(id, falseSuccess), invalid);
    expect(store.hostTask(id)!['snapshot'], snapshot);
  });

  test('J completing input observation alone never claims that an output was delivered', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final read = receiptReport(verifiedAtPublish: false);
    final running = receiptSnapshot(store, id, readReports: {1: read});
    expect(accept(id, running)['state'], 'running');
    final falseDone = receiptCopy(running)
      ..['state'] = 'done'
      ..['runnerReceiptSeq'] = 2;
    expect(() => accept(id, falseDone), invalid);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
  });

  test('J observed fields are kept before publication but cannot be written from an unverified original', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final observed = receiptReport(verifiedAtPublish: false);
    final before = receiptSnapshot(store, id, readReports: {1: observed});
    accept(id, before);
    final invalidWrite = receiptSnapshot(
      store,
      id,
      seq: 2,
      state: 'partial',
      readReports: {1: observed},
      writeReports: {1: observed},
      artifacts: [receiptArtifact()],
    );
    expect(() => accept(id, invalidWrite), invalid);
    expect(store.hostTask(id)!['snapshot'], before);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
  });

  test('J a failed write keeps its observed report without claiming an artifact or permitting another attempt', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final observed = receiptReport(verifiedAtPublish: false);
    final failed = receiptSnapshot(
      store,
      id,
      state: 'failed',
      readReports: {1: observed},
      extraSteps: [
        {
          'taskRev': 1,
          'stepKey': 'writeSheet',
          'attemptId': 'failed-write',
          'state': 'failed',
          'startedAtMs': receiptTime,
          'finishedAtMs': receiptTime,
          'reason': 'original_changed',
          'result': {
            'completion': {'report': observed},
          },
        },
      ],
    );
    expect(accept(id, failed)['state'], 'failed');
    expect(failed['artifacts'], isEmpty);
    final retry = receiptCopy(failed)
      ..['runnerReceiptSeq'] = 2
      ..['state'] = 'running';
    (retry['steps']! as List<Object?>).add({
      'taskRev': 1,
      'stepKey': 'writeSheet',
      'attemptId': 'unproved-retry',
      'state': 'running',
      'startedAtMs': receiptTime,
      'finishedAtMs': null,
      'reason': null,
      'result': null,
    });
    expect(() => accept(id, retry), invalid);
    expect(store.hostTask(id)!['snapshot'], failed);
  });

  test('J only an interrupted read can precede another same-revision read and old facts stay immutable', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final report = receiptReport(unread: {2, 3}, verifiedAtPublish: false);
    final before = receiptSnapshot(store, id, state: 'waiting', readReports: {1: report});
    final first = (before['steps']! as List<Object?>).single! as MemoryRow;
    first['state'] = 'waiting';
    first['reason'] = 'receipt_read_interrupted';
    accept(id, before);
    final after = receiptCopy(before)
      ..['runnerReceiptSeq'] = 2
      ..['state'] = 'running';
    (after['steps']! as List<Object?>).add({
      'taskRev': 1,
      'stepKey': 'readInputs',
      'attemptId': 'recovered-read',
      'state': 'done',
      'startedAtMs': receiptTime,
      'finishedAtMs': receiptTime,
      'reason': null,
      'result': {
        'completion': {'report': receiptReport(verifiedAtPublish: false)},
      },
    });
    final wrongReason = receiptCopy(after);
    ((wrongReason['steps']! as List<Object?>).first! as MemoryRow)['reason'] = 'ordinary_read_failure';
    expect(() => accept(id, wrongReason), invalid);
    final changedHistory = receiptCopy(after);
    ((changedHistory['steps']! as List<Object?>).first! as MemoryRow)['finishedAtMs'] = receiptTime + 1;
    expect(() => accept(id, changedHistory), conflict);
    expect(accept(id, after)['snapshot'], after);
    reopen();
    expect(accept(id, before)['snapshot'], after);
    final third = receiptCopy(after)..['runnerReceiptSeq'] = 3;
    (third['steps']! as List<Object?>).add({
      'taskRev': 1,
      'stepKey': 'readInputs',
      'attemptId': 'after-completed-read',
      'state': 'running',
      'startedAtMs': receiptTime,
      'finishedAtMs': null,
      'reason': null,
      'result': null,
    });
    expect(() => accept(id, third), invalid);
    expect(store.hostTask(id)!['snapshot'], after);
  });

  test('J a saved publication-not-attempted proof without a report permits only its next write attempt', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final before = receiptSnapshot(
      store,
      id,
      state: 'waiting',
      readReports: {1: receiptReport(verifiedAtPublish: false)},
      extraSteps: [
        {
          'taskRev': 1,
          'stepKey': 'writeSheet',
          'attemptId': 'unstarted-write',
          'state': 'waiting',
          'startedAtMs': receiptTime,
          'finishedAtMs': receiptTime,
          'reason': 'publication_not_started',
          'result': {
            'completion': {'publicationNotAttempted': true},
          },
        },
      ],
    );
    before['budget'] = {'limitMs': 300000, 'spentMs': 120, 'heldMs': 60000};
    accept(id, before);
    final active = receiptCopy(before)
      ..['runnerReceiptSeq'] = 2
      ..['state'] = 'running';
    (active['steps']! as List<Object?>).add({
      'taskRev': 1,
      'stepKey': 'writeSheet',
      'attemptId': 'first-publication',
      'state': 'running',
      'startedAtMs': receiptTime,
      'finishedAtMs': null,
      'reason': null,
      'result': null,
    });
    for (final change in <MemoryRow>[
      {'state': 'unknown'},
      {'reason': 'publication_unconfirmed'},
      {'finishedAtMs': null},
      {
        'result': {
          'completion': {'publicationNotAttempted': false},
        },
      },
    ]) {
      final bad = receiptCopy(active);
      ((bad['steps']! as List<Object?>)[1]! as MemoryRow).addAll(change);
      expect(() => accept(id, bad), invalid);
    }
    expect(accept(id, active)['snapshot'], active);
    expect((store.hostTask(id)!['snapshot']! as MemoryRow)['budget'], before['budget']);
    final another = receiptCopy(active)..['runnerReceiptSeq'] = 3;
    (another['steps']! as List<Object?>).add({
      'taskRev': 1,
      'stepKey': 'writeSheet',
      'attemptId': 'second-unproved-publication',
      'state': 'running',
      'startedAtMs': receiptTime,
      'finishedAtMs': null,
      'reason': null,
      'result': null,
    });
    expect(() => accept(id, another), invalid);
  });

  final corruptReports = <String, void Function(MemoryRow)>{
    'fifth source': (report) => (report['sources']! as List<Object?>).add((report['sources']! as List<Object?>).first),
    'swapped original': (report) =>
        ((report['sources']! as List<Object?>).first as MemoryRow)['sourceRef'] = 'unselected',
    'other version': (report) => ((report['rows']! as List<Object?>).first as MemoryRow)['version'] = 'new-version',
    'false read count': (report) => (report['coverage']! as MemoryRow)['readCompleteCount'] = 4,
    'missing unread gap': (report) => ((report['coverage']! as MemoryRow)['gaps']! as List<Object?>).removeLast(),
    'duplicate gap': (report) {
      final gaps = (report['coverage']! as MemoryRow)['gaps']! as List<Object?>;
      gaps.add(gaps.first);
    },
    'not-present inference': (report) =>
        (((report['rows']! as List<Object?>).last as MemoryRow)['date']! as MemoryRow)['state'] = 'not_present',
    'unverified value': (report) =>
        (((report['rows']! as List<Object?>).last as MemoryRow)['date']! as MemoryRow)['value'] = '2026-11-21',
    'verified without evidence': (report) =>
        (((report['rows']! as List<Object?>).first as MemoryRow)['amount']! as MemoryRow)['evidence'] = null,
    'PDF false page': (report) =>
        ((((report['rows']! as List<Object?>)[2] as MemoryRow)['date']! as MemoryRow)['evidence']!
                as MemoryRow)['page'] =
            2,
    'image contents claimed': (report) =>
        ((report['sources']! as List<Object?>)[2] as MemoryRow)['textLayerOnly'] = false,
  };
  for (final entry in corruptReports.entries) {
    test('J rejects ${entry.key} without advancing its complete snapshot watermark', () {
      say('source');
      final id = create('source')['task_id']! as String;
      final before = receiptSnapshot(store, id);
      accept(id, before);
      final report = receiptReport(unread: {3});
      entry.value(report);
      final invalidSnapshot = receiptSnapshot(
        store,
        id,
        seq: 2,
        state: 'partial',
        writeReports: {1: report},
        artifacts: [receiptArtifact()],
      );
      expect(() => accept(id, invalidSnapshot), invalid);
      expect(store.hostTask(id)!['snapshot'], before);
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
    });
  }

  test('J refuses a model step, mismatched output or duplicate successful write attempt', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final report = receiptReport();
    final completed = receiptSnapshot(
      store,
      id,
      state: 'done',
      writeReports: {1: report},
      artifacts: [receiptArtifact()],
    );
    final model = receiptCopy(completed);
    ((model['steps']! as List<Object?>).first as MemoryRow)['stepKey'] = 'model';
    expect(() => accept(id, model), invalid);
    final path = receiptCopy(completed);
    ((path['artifacts']! as List<Object?>).first as MemoryRow)['relativePath'] = 'another.xlsx';
    expect(() => accept(id, path), invalid);
    final duplicate = receiptCopy(completed);
    final extra = receiptCopy((duplicate['steps']! as List<Object?>).first as MemoryRow)..['attemptId'] = 'other-write';
    (duplicate['steps']! as List<Object?>).add(extra);
    expect(() => accept(id, duplicate), invalid);
    expect(store.hostTask(id)!['snapshot'], isNull);
  });

  test('J amendment accepted before an old artifact preserves that effect and blocks further amendments', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final read = receiptReport(verifiedAtPublish: false), report = receiptReport(), artifact = receiptArtifact();
    final original = receiptSnapshot(
      store,
      id,
      state: 'done',
      readReports: {1: read},
      writeReports: {1: report},
      artifacts: [artifact],
    );
    // The real amendment is accepted before the old possible write is observed.
    say('amend');
    final inputs = receiptBindings(suffix: '-new');
    store.amendReceiptsTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: receiptAgreement(inputs: inputs),
      inputs: inputs,
      outputDirectory: receiptOutput(),
    );
    final waiting = receiptSnapshot(
      store,
      id,
      revision: 2,
      seq: 2,
      state: 'partial',
      reason: 'prior_revision_effect',
      readReports: {1: read},
      writeReports: {1: report},
      artifacts: [artifact],
    );
    waiting['budget'] = {'limitMs': 300000, 'spentMs': 120, 'heldMs': 60000};
    expect(accept(id, waiting)['state'], 'partial');
    expect(accept(id, original)['state'], 'partial');
    say('amend-again');
    final commands = store.hostTaskCommands(id);
    expect(
      () => store.amendReceiptsTask(
        taskId: id,
        expectedTaskRev: 2,
        messageId: 'amend-again',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: receiptAgreement(inputs: inputs),
        inputs: inputs,
        outputDirectory: receiptOutput(),
      ),
      conflict,
    );
    expect(store.hostTaskCommands(id), commands);
    expect(store.hostTask(id)!['task_rev'], 2);
    final noEffect = receiptCopy(waiting)
      ..['runnerReceiptSeq'] = 3
      ..['steps'] = <Object?>[]
      ..['artifacts'] = <Object?>[];
    expect(() => accept(id, noEffect), invalid);
    say('cancel');
    store.cancelReceiptsTask(taskId: id, expectedTaskRev: 2, messageId: 'cancel', expectedSourceRev: 1, itemNo: 0);
    final cancelled = receiptSnapshot(
      store,
      id,
      revision: 3,
      seq: 3,
      state: 'cancelled',
      readReports: {1: read},
      writeReports: {1: report},
      artifacts: [artifact],
    );
    cancelled['budget'] = waiting['budget'];
    expect(accept(id, cancelled)['state'], 'cancelled');
    reopen();
    expect((store.hostTask(id)!['snapshot']! as MemoryRow)['artifacts'], [artifact]);
    expect((store.hostTask(id)!['snapshot']! as MemoryRow)['budget'], waiting['budget']);
    expect(store.hostTaskInputs(hostKey: 'original-host'), [...inputs, ...receiptBindings()]);
  });

  test('J importing a newer report cannot alter previously observed facts or lose its artifact', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final read = receiptReport(verifiedAtPublish: false), report = receiptReport();
    final original = receiptSnapshot(
      store,
      id,
      state: 'done',
      readReports: {1: read},
      writeReports: {1: report},
      artifacts: [receiptArtifact()],
    );
    accept(id, original);
    final changed = receiptCopy(original)..['runnerReceiptSeq'] = 2;
    final savedRead =
        (((changed['steps']! as List<Object?>).first as MemoryRow)['result']! as MemoryRow)['completion']! as MemoryRow;
    final field =
        ((((savedRead['report']! as MemoryRow)['rows']! as List<Object?>).first as MemoryRow)['item']! as MemoryRow);
    field['value'] = 'later altered fact';
    expect(() => accept(id, changed), conflict);
    final lost = receiptCopy(original)
      ..['runnerReceiptSeq'] = 2
      ..['artifacts'] = <Object?>[];
    expect(() => accept(id, lost), throwsA(isA<DshRemoteException>()));
    expect(store.hostTask(id)!['snapshot'], original);
  });
}
