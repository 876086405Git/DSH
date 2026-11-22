import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Synthetic cases exercise phone transactions; the separate unchanged H02
// HTTP fixture checks real Host shape. Dart tests do not repeat its file IO.
void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1795219200000;

  MemoryRow agreement({
    String day = '2026-11-20',
    List<String> extensions = const ['md', 'txt'],
    bool allowQueue = true,
  }) => {
    'args': {
      'folderRef': 'bound-speeches',
      'scope': 'currentLevel',
      'localDate': day,
      'timeZone': 'Asia/Shanghai',
      'dateBy': 'modified',
      'extensions': extensions,
    },
    'deadlineAtMs': null,
    'afterExit': 'continue',
    'allowQueue': allowQueue,
  };

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  void say(
    String id, {
    String session = 'light:original-room',
    String role = 'user',
    String scope = 'real',
    bool zone = true,
  }) {
    store.submitMessage(
      id: id,
      sessionId: session,
      role: role,
      scope: scope,
      text: '等电脑开了，在演讲稿文件夹这一层找昨天改的稿子，我走了继续。',
      saidAtUtc: now,
      offsetMinutes: 480,
      zoneId: zone ? 'Asia/Shanghai' : null,
      offsetSeconds: zone ? 28800 : null,
    );
  }

  MemoryRow create(
    String message, {
    MemoryRow? selected,
    String hostStore = 'store-original',
    String hostKey = 'ssh:original-host',
  }) => store.createFindDraftTaskFromMessage(
    messageId: message,
    expectedSourceRev: 1,
    itemNo: 0,
    roomMode: 'light',
    hostKey: hostKey,
    directoryHostStoreId: hostStore,
    agreement: selected ?? agreement(),
    directoryLabels: {'source': '演讲稿'},
  );

  MemoryRow? prepare(String id, int revision, {String hostStore = 'store-original', bool replay = false}) =>
      store.prepareHostTaskOperation(
        taskId: id,
        taskRev: revision,
        hostKey: 'ssh:original-host',
        hostStoreId: hostStore,
        initialOpportunity: true,
        replayAfterRead: replay,
      );

  MemoryRow match({String ref = 'source-A', bool openable = true}) => {
    'sourceRef': ref,
    'relativePath': '$ref.md',
    'size': 120,
    'modifiedAtMs': 1795147200000,
    'modifiedOffsetSeconds': 28800,
    'version': 'original-inode-and-version-$ref',
    'openable': openable,
    'reason': openable ? null : 'not_readable',
  };

  MemoryRow report({
    List<MemoryRow> matches = const [],
    bool enumerationComplete = true,
    bool entryLimit = false,
    bool candidateLimit = false,
    MemoryRow? selected,
  }) => {
    'scope': {
      ...((selected ?? agreement())['args']! as Map<String, Object?>),
      'displayPath': '/home/user/speeches',
      'startAtMs': 1795104000000,
      'endAtMs': 1795190400000,
    },
    'coverage': {
      'entriesChecked': entryLimit
          ? 200
          : candidateLimit
          ? 21
          : 12,
      'supportedFilesChecked': candidateLimit
          ? 21
          : matches.length > 9
          ? matches.length
          : 9,
      'matchingCandidates': candidateLimit ? 21 : matches.length,
      'enumerationComplete': enumerationComplete,
      'entryLimitReached': entryLimit,
      'candidateLimitReached': candidateLimit,
      'gaps': [
        for (final item in matches)
          if (item['openable'] == false) {'relativePath': item['relativePath'], 'reason': item['reason']},
      ],
    },
    'matches': matches,
  };

  MemoryRow snapshot(
    String id, {
    int revision = 1,
    int seq = 1,
    String state = 'running',
    bool original = true,
    Map<int, MemoryRow> reports = const {},
  }) {
    final commands = store.hostTaskCommands(id);
    final first = commands.first['request']! as MemoryRow;
    MemoryRow? value(MemoryRow command) {
      final raw = command['request']! as MemoryRow;
      return switch (command['operation']) {
        'create' => {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: raw[key],
        },
        'amend' => Map<String, Object?>.from(raw['changes']! as MemoryRow),
        _ => null,
      };
    }

    final revisions = commands
        .where((command) => (command['task_rev']! as int) <= revision && (original || command['operation'] != 'create'))
        .toList();
    final active = revisions.last;
    return {
      'v': 1,
      'hostStoreId': 'store-original',
      'taskId': id,
      'hostExecutionId': 'execution-original',
      'kind': 'host.find_draft',
      'taskRev': revision,
      'runnerReceiptSeq': seq,
      'originalCreatePresent': original,
      'origin': original ? first['origin'] : null,
      'hostSessionId': null,
      'state': state,
      'waitReason': original ? null : 'original_create_missing',
      'cancelRequested': active['operation'] == 'cancel',
      'createdAtMs': now,
      'updatedAtMs': now,
      'agreement': value(active) ?? (original ? value(commands.first) : null),
      'revisions': [
        for (final command in revisions)
          {
            'taskRev': command['task_rev'],
            'operation': command['operation'],
            'acceptedAtMs': now,
            'agreement': value(command),
          },
      ],
      'steps': [
        for (final entry in reports.entries)
          {
            'taskRev': entry.key,
            'stepKey': 'readInputs',
            'attemptId': 'read-${entry.key}',
            'state': 'done',
            'startedAtMs': now,
            'finishedAtMs': now,
            'reason': null,
            'result': {'completion': entry.value},
          },
      ],
      'artifacts': <Object?>[],
      'approval': null,
      'budget': {'limitMs': 300000, 'spentMs': 12, 'heldMs': 0},
    };
  }

  MemoryRow accept(String id, MemoryRow value) =>
      store.importHostTaskSnapshot(taskId: id, hostKey: 'ssh:original-host', snapshot: value);

  final conflict = throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/conflict'));
  final invalid = throwsA(
    isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-invalid-request'),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-find-draft-');
    now = 1795219200000;
    open();
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('H binds the selected original store without claiming a socket and preserves the fixed day after restart', () {
    say('source');
    final task = create('source');
    final id = task['task_id']! as String;
    final original = store.hostTaskCommands(id).single;
    expect(task['kind'], 'host.find_draft');
    expect(task['host_store_id'], 'store-original');
    expect(original['possible_sent_at_ms'], isNull);
    expect((original['request']! as MemoryRow).containsKey('hostStoreId'), isFalse);
    expect(task['source_zone_id'], 'Asia/Shanghai');
    expect(task['source_offset_seconds'], 28800);
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    now += const Duration(days: 2).inMilliseconds;
    reopen();
    expect(create('source'), task);
    expect(store.hostTaskCommands(id).single, original);
    expect(store.hostTask(id)!['agreement'], agreement());
    expect(database.select('PRAGMA user_version').single['user_version'], 15);
  });

  test(
    'H same source item retries once while another source is independent and a changed directory store conflicts',
    () {
      say('one');
      say('two');
      final first = create('one');
      expect(create('one')['task_id'], first['task_id']);
      expect(() => create('one', hostStore: 'replacement-store'), conflict);
      expect(create('two')['task_id'], isNot(first['task_id']));
      expect(store.tasks(), hasLength(2));
    },
  );

  for (final provenance in [(role: 'assistant', scope: 'real'), (role: 'user', scope: 'story')]) {
    test('H ${provenance.role}/${provenance.scope} cannot grant a file task', () {
      say('source', role: provenance.role, scope: provenance.scope);
      expect(() => create('source'), throwsA(isA<DshRemoteException>()));
      expect(store.tasks(), isEmpty);
    });
  }

  test('H an old source with no actual zone cannot acquire a guessed IANA zone', () {
    say('source', zone: false);
    expect(() => create('source'), invalid);
    expect(store.tasks(), isEmpty);
  });

  test('H normalizes a chosen format subset before immutable persistence and rejects added scope', () {
    say('source');
    final task = create('source', selected: agreement(extensions: ['txt', 'md']));
    expect((task['agreement']! as MemoryRow)['args'], agreement()['args']);
    expect(create('source')['task_id'], task['task_id']);
    for (final extensions in [
      <String>[],
      ['pdf'],
      ['md', 'md'],
    ]) {
      expect(() => create('source', selected: agreement(extensions: extensions)), invalid);
    }
    final expanded = agreement();
    (expanded['args']! as MemoryRow)['outputName'] = 'not-a-find-task.md';
    expect(() => create('source', selected: expanded), invalid);
  });

  test('H a real command insert failure leaves no task or prebound directory record', () {
    say('source');
    database.execute('''CREATE TRIGGER fail_find_command BEFORE INSERT ON companion_host_commands
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    expect(() => create('source'), throwsA(isA<SqliteException>()));
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_host_tasks'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
  });

  test('H a previously bound directory cannot be handed to a replacement task store', () {
    say('source');
    final id = create('source')['task_id']! as String;
    expect(
      () => prepare(id, 1, hostStore: 'replacement-store'),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-store-mismatch')),
    );
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
    final sent = prepare(id, 1)!;
    expect((sent['request']! as MemoryRow)['hostStoreId'], 'store-original');
    expect(sent['newlyClaimed'], isTrue);
    reopen();
    expect(() => prepare(id, 1), throwsA(isA<DshRemoteException>()));
    expect(prepare(id, 1, replay: true)!['request'], sent['request']);
  });

  test('H recovery keeps an earlier light-room task visible behind one hundred later tasks', () {
    say('original-light-room');
    final id = create('original-light-room')['task_id']! as String;
    for (var index = 0; index < 100; index++) {
      now++;
      say('later-$index', session: 'full:other-room');
      create('later-$index', hostKey: 'ssh:another-host');
    }
    expect(store.tasks().any((task) => task['task_id'] == id), isFalse);
    final pending = store.pendingFindDraftTasks(hostKey: 'ssh:original-host');
    expect(pending, hasLength(1));
    expect(pending.single['task_id'], id);
    expect(pending.single['source_session_id'], 'light:original-room');
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
    expect(store.hostTaskDirectories(hostKey: 'ssh:original-host'), [
      {'hostStoreId': 'store-original', 'folderRef': 'bound-speeches', 'displayPath': '演讲稿'},
    ]);
  });

  test('H recovery includes unknown and pending remote cancel without treating them as new dispatch grants', () {
    say('sent');
    final sent = create('sent')['task_id']! as String;
    prepare(sent, 1);
    say('amend');
    store.amendFindDraftTask(
      taskId: sent,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(extensions: ['txt']),
    );
    expect(store.hostTask(sent)!['state'], 'queued');
    say('cancelled');
    final cancelled = create('cancelled')['task_id']! as String;
    say('cancel-command');
    store.cancelFindDraftTask(
      taskId: cancelled,
      expectedTaskRev: 1,
      messageId: 'cancel-command',
      expectedSourceRev: 1,
      itemNo: 0,
    );
    say('remote-cancel');
    final remoteCancel = create('remote-cancel')['task_id']! as String;
    prepare(remoteCancel, 1);
    say('remote-cancel-command');
    store.cancelFindDraftTask(
      taskId: remoteCancel,
      expectedTaskRev: 1,
      messageId: 'remote-cancel-command',
      expectedSourceRev: 1,
      itemNo: 0,
    );
    say('unsent');
    final unsent = create('unsent')['task_id']! as String;
    reopen();
    expect(store.pendingFindDraftTasks(hostKey: 'ssh:original-host').map((row) => row['task_id']).toSet(), {
      sent,
      remoteCancel,
      unsent,
    });
    expect(store.hostTask(sent)!['state'], 'queued');
    expect(store.hostTask(remoteCancel)!['state'], 'unknown');
    expect(store.hostTask(remoteCancel)!['cancel_requested'], 1);
    expect(() => prepare(remoteCancel, 1, replay: true), conflict);
    expect(store.hostTaskCommands(sent).first['possible_sent_at_ms'], isNotNull);
    expect(store.hostTaskCommands(unsent).single['possible_sent_at_ms'], isNull);
  });

  test('H saved directory choices retain completed and earlier explicit selections on the original store only', () {
    say('original');
    final id = create('original')['task_id']! as String;
    accept(id, snapshot(id, state: 'done', reports: {1: report()}));
    expect(store.hostTaskDirectories(hostKey: 'ssh:original-host'), [
      {'hostStoreId': 'store-original', 'folderRef': 'bound-speeches', 'displayPath': '演讲稿'},
    ]);
    say('amend-directory');
    final changed = agreement();
    (changed['args']! as MemoryRow)['folderRef'] = 'second-directory';
    store.amendFindDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend-directory',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: changed,
      directoryLabels: {'source': '第二目录'},
    );
    say('same-directory');
    create('same-directory');
    say('other-host');
    create('other-host', hostKey: 'ssh:other-host');
    say('notes');
    final notes = store.createNotesTaskFromMessage(
      messageId: 'notes',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      hostKey: 'ssh:original-host',
      directoryLabels: {'source': '笔记目录'},
      agreement: {
        'args': {
          'folderRef': 'notes-folder',
          'localDate': '2026-11-20',
          'timeZone': 'Asia/Shanghai',
          'dateBy': 'modified',
          'outputDirRef': 'notes-folder',
          'outputName': '待办.md',
          'writeMode': 'createNew',
        },
        'deadlineAtMs': null,
        'afterExit': 'continue',
        'allowQueue': true,
      },
    );
    expect(store.hostTaskDirectories(hostKey: 'ssh:original-host'), hasLength(2));
    prepare(notes['task_id']! as String, 1);
    reopen();
    final directories = store.hostTaskDirectories(hostKey: 'ssh:original-host');
    expect(directories.map((row) => row['folderRef']).toSet(), {'bound-speeches', 'second-directory', 'notes-folder'});
    expect(directories.every((row) => row['hostStoreId'] == 'store-original'), isTrue);
    expect(directories, hasLength(3));
  });

  for (final operation in ['amend', 'cancel']) {
    test('H $operation before create includes the actual kind and preserves the original package', () {
      say('source');
      final id = create('source')['task_id']! as String;
      final original = jsonEncode(store.hostTaskCommands(id).first['request']);
      say('operation');
      if (operation == 'amend') {
        store.amendFindDraftTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'operation',
          expectedSourceRev: 1,
          itemNo: 0,
          agreement: agreement(extensions: ['txt']),
        );
      } else {
        prepare(id, 1); // A possible original handoff must be stopped remotely.
        store.cancelFindDraftTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'operation',
          expectedSourceRev: 1,
          itemNo: 0,
        );
      }
      final outgoing = prepare(id, 2)!;
      expect((outgoing['request']! as MemoryRow)['kind'], 'host.find_draft');
      expect((outgoing['request']! as MemoryRow).containsKey('taskId'), isFalse);
      expect(jsonEncode(store.hostTaskCommands(id).first['request']), original);
      final barrier = snapshot(
        id,
        revision: 2,
        original: false,
        state: operation == 'cancel' ? 'cancelled' : 'waiting',
      );
      accept(id, barrier);
      reopen();
      expect(store.hostTask(id)!['snapshot'], barrier);
      expect(store.hostTask(id)!['host_execution_id'], 'execution-original');
      if (operation == 'amend') {
        final originalAfterBarrier = prepare(id, 1, replay: true)!;
        expect((originalAfterBarrier['request']! as MemoryRow)['kind'], 'host.find_draft');
        expect(jsonEncode(store.hostTaskCommands(id).first['request']), original);
      } else {
        expect(() => prepare(id, 1, replay: true), conflict);
      }
    });
  }

  test('H a same-host notes snapshot cannot cross the known task kind', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final wrong = snapshot(id)..['kind'] = 'host.notes_to_todo';
    final notesAgreement = <String, Object?>{
      'args': {
        'folderRef': 'bound-speeches',
        'localDate': '2026-11-20',
        'timeZone': 'Asia/Shanghai',
        'dateBy': 'modified',
        'outputDirRef': 'bound-speeches',
        'outputName': '待办.md',
        'writeMode': 'createNew',
      },
      'deadlineAtMs': null,
      'afterExit': 'continue',
      'allowQueue': true,
    };
    wrong['agreement'] = notesAgreement;
    ((wrong['revisions']! as List<Object?>).single as MemoryRow)['agreement'] = notesAgreement;
    // Valid notes fields still cannot become the known find task.
    expect(() => accept(id, wrong), conflict);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 0);
    expect(store.hostTask(id)!['snapshot'], isNull);
  });

  test('H complete zero matches is a durable done report with no fake artifact or phone receipt', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final done = snapshot(id, state: 'done', reports: {1: report()});
    expect(accept(id, done)['state'], 'done');
    reopen();
    expect(store.hostTask(id)!['snapshot'], done);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
    expect(store.taskReceipts(id), isEmpty);
    expect(done['artifacts'], isEmpty);
    expect(prepare(id, 1, replay: true), isNull);
  });

  test('H a listed unreadable draft is retained as partial and cannot be relabelled done', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final partialReport = report(matches: [match(openable: false)]);
    final value = snapshot(id, state: 'partial', reports: {1: partialReport});
    accept(id, value);
    expect(store.hostTask(id)!['state'], 'partial');
    expect(((partialReport['matches']! as List<Object?>).single as MemoryRow)['openable'], isFalse);
    final falseDone = snapshot(id, state: 'done', seq: 2, reports: {1: partialReport});
    expect(() => accept(id, falseDone), invalid);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
  });

  for (final limit in ['entries', 'candidates']) {
    test('H a reported $limit coverage limit stays partial without an invented total', () {
      say('source');
      final id = create('source')['task_id']! as String;
      final limited = report(
        enumerationComplete: false,
        entryLimit: limit == 'entries',
        candidateLimit: limit == 'candidates',
        matches: limit == 'candidates' ? [for (var index = 0; index < 20; index++) match(ref: 'source-$index')] : [],
      );
      final value = snapshot(id, state: 'partial', reports: {1: limited});
      expect(accept(id, value)['state'], 'partial');
      reopen();
      expect(store.hostTask(id)!['snapshot'], value);
    });
  }

  test('H snapshot storage failure rolls back the result, head and Host watermark together', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    database.execute('''CREATE TRIGGER fail_find_snapshot BEFORE UPDATE ON companion_host_tasks
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    final done = snapshot(
      id,
      state: 'done',
      reports: {
        1: report(matches: [match()]),
      },
    );
    expect(() => accept(id, done), throwsA(isA<SqliteException>()));
    reopen();
    final unchanged = store.hostTask(id)!;
    expect(unchanged['state'], 'unknown');
    expect(unchanged['snapshot'], isNull);
    expect(unchanged['applied_host_receipt_seq'], 0);
  });

  test('H cancellation keeps the old report while later complete snapshots cannot remove or alter it', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final originalReport = report(matches: [match()]);
    accept(id, snapshot(id, state: 'done', reports: {1: originalReport}));
    say('cancel');
    store.cancelFindDraftTask(taskId: id, expectedTaskRev: 1, messageId: 'cancel', expectedSourceRev: 1, itemNo: 0);
    final cancelled = snapshot(id, revision: 2, seq: 2, state: 'cancelled', reports: {1: originalReport});
    accept(id, cancelled);
    reopen();
    expect(store.hostTask(id)!['snapshot'], cancelled);
    expect(store.hostTask(id)!['state'], 'cancelled');
    expect(() => accept(id, snapshot(id, revision: 2, seq: 3, state: 'cancelled')), conflict);
    final changed = report(matches: [match(ref: 'replacement')]);
    expect(() => accept(id, snapshot(id, revision: 2, seq: 3, state: 'cancelled', reports: {1: changed})), conflict);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 2);
    accept(id, snapshot(id, seq: 1, state: 'done', reports: {1: originalReport}));
    expect(store.hostTask(id)!['snapshot'], cancelled);
  });

  test('H an explicit later agreement preserves a completed earlier report and requires the original room', () {
    say('source');
    final id = create('source')['task_id']! as String;
    final first = report(matches: [match()]);
    accept(id, snapshot(id, state: 'done', reports: {1: first}));
    say('wrong-room', session: 'light:another-room');
    expect(
      () => store.amendFindDraftTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'wrong-room',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(extensions: ['txt']),
      ),
      invalid,
    );
    say('amend');
    final selected = agreement(extensions: ['txt']);
    store.amendFindDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: selected,
    );
    final next = snapshot(
      id,
      revision: 2,
      seq: 2,
      state: 'done',
      reports: {
        1: first,
        2: report(selected: selected),
      },
    );
    accept(id, next);
    reopen();
    expect(store.hostTask(id)!['snapshot'], next);
    expect(store.hostTask(id)!['task_rev'], 2);
    expect(store.hostTaskCommands(id), hasLength(2));
  });

  test('H changing format after travel keeps the original window and the new commands actual time zone', () {
    say('source');
    final id = create('source')['task_id']! as String;
    store.submitMessage(
      id: 'travel-command',
      sessionId: 'light:original-room',
      role: 'user',
      scope: 'real',
      text: '这次只找 txt，仍按原来的日子。',
      saidAtUtc: now,
      offsetMinutes: -300,
      zoneId: 'America/New_York',
      offsetSeconds: -18000,
    );
    final amended = store.amendFindDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'travel-command',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(extensions: ['txt']),
    );
    expect(amended['source_zone_id'], 'America/New_York');
    expect(amended['source_offset_seconds'], -18000);
    expect(amended['zone_id'], 'Asia/Shanghai');
    final changes = (store.hostTaskCommands(id).last['request']! as MemoryRow)['changes']! as MemoryRow;
    expect((changes['args']! as MemoryRow)['timeZone'], 'Asia/Shanghai');
    expect((changes['args']! as MemoryRow)['extensions'], ['txt']);
    reopen();
    expect(store.hostTask(id)!['source_zone_id'], 'America/New_York');
    expect(store.hostTask(id)!['zone_id'], 'Asia/Shanghai');
  });

  for (final fixture in [
    (
      file: 'H02-wire.json',
      state: 'done',
      name: 'H imports the unchanged actual Host acceptance and complete find report in one phone ledger',
    ),
    (
      file: 'H02-backslash-wire.json',
      state: 'partial',
      name:
          'H imports an actual partial Host report with an unreadable backslash basename and retains its readable sibling',
    ),
  ]) {
    test(fixture.name, () {
      final wire =
          jsonDecode(File('test/fixtures/companion_find_draft/${fixture.file}').readAsStringSync()) as MemoryRow;
      final request = wire['create']! as MemoryRow;
      final origin = request['origin']! as MemoryRow;
      final id = request['taskId']! as String;
      store.close();
      database = sqlite3.open('${directory.path}/memory.sqlite');
      store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: () => id);
      store.submitMessage(
        id: origin['messageId']! as String,
        sessionId: origin['sourceSessionId']! as String,
        role: 'user',
        scope: 'real',
        text: '在已选演讲稿目录找2026年11月20日改的md和txt。',
        saidAtUtc: now,
        offsetMinutes: 0,
        zoneId: 'UTC',
        offsetSeconds: 0,
      );
      final created = store.createFindDraftTaskFromMessage(
        messageId: origin['messageId']! as String,
        expectedSourceRev: 1,
        itemNo: origin['itemNo']! as int,
        roomMode: 'light',
        hostKey: 'ssh:original-host',
        directoryHostStoreId: request['hostStoreId']! as String,
        agreement: {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: request[key],
        },
        directoryLabels: {'source': (wire['folder']! as MemoryRow)['displayPath']},
      );
      expect(created['task_id'], id);
      expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
      final package = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'ssh:original-host',
        hostStoreId: request['hostStoreId']! as String,
        initialOpportunity: true,
      )!;
      expect(package['request'], request);
      store.importHostTaskSnapshot(
        taskId: id,
        hostKey: 'ssh:original-host',
        snapshot: wire['createReply']! as MemoryRow,
      );
      store.importHostTaskSnapshot(taskId: id, hostKey: 'ssh:original-host', snapshot: wire['complete']! as MemoryRow);
      reopen();
      final current = store.hostTask(id)!;
      expect(current['state'], fixture.state);
      expect(current['snapshot'], wire['complete']);
      expect(current['applied_host_receipt_seq'], (wire['complete']! as MemoryRow)['runnerReceiptSeq']);
      expect(store.taskReceipts(id), isEmpty);
      if (fixture.state == 'partial') {
        final complete = current['snapshot']! as MemoryRow;
        final read = (complete['steps']! as List<Object?>).cast<MemoryRow>().singleWhere(
          (step) => step['stepKey'] == 'readInputs',
        );
        final result = (read['result']! as MemoryRow)['completion']! as MemoryRow;
        final matches = (result['matches']! as List<Object?>).cast<MemoryRow>().toList();
        final unavailable = wire['sourceUnavailable']! as MemoryRow;
        final available = wire['sourceAvailable']! as MemoryRow;
        expect(matches, hasLength(2));
        final bad = matches.singleWhere((match) => match['sourceRef'] == unavailable['sourceRef']);
        expect(bad['relativePath'], unavailable['relativePath']);
        expect((bad['relativePath']! as String).contains(r'\'), isTrue);
        expect(bad['openable'], isFalse);
        expect(bad['reason'], 'original_unavailable');
        final good = matches.singleWhere((match) => match['sourceRef'] == available['sourceRef']);
        expect(good['relativePath'], 'ordinary.md');
        expect(good['openable'], isTrue);
      }
      store.importHostTaskSnapshot(
        taskId: id,
        hostKey: 'ssh:original-host',
        snapshot: wire['createReply']! as MemoryRow,
      );
      expect(store.hostTask(id)!['snapshot'], wire['complete']);
    });
  }
}
