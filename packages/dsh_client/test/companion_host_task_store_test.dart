import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1795219200000;
  MemoryRow agreement({String output = '今日待办.md', String afterExit = 'continue', bool allowQueue = false}) => {
    'args': {
      'folderRef': 'bound-notes',
      'localDate': '2026-11-21',
      'timeZone': 'Asia/Shanghai',
      'dateBy': 'modified',
      'outputDirRef': 'bound-notes',
      'outputName': output,
      'writeMode': 'createNew',
    },
    'deadlineAtMs': 1795219500000,
    'afterExit': afterExit,
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

  void say(String id, {String session = 'light:original-room', String role = 'user', String scope = 'real'}) {
    store.submitMessage(
      id: id,
      sessionId: session,
      text: '请电脑把今天的笔记另存成一页待办，原件别动。',
      role: role,
      scope: scope,
      saidAtUtc: now,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
  }

  MemoryRow create(String source, {int itemNo = 0, MemoryRow? selected}) => store.createNotesTaskFromMessage(
    messageId: source,
    expectedSourceRev: 1,
    itemNo: itemNo,
    roomMode: 'light',
    hostKey: 'ssh:original-host',
    agreement: selected ?? agreement(),
  );

  MemoryRow? prepare(
    String id,
    int revision, {
    bool initial = true,
    bool replay = false,
    String hostStore = 'store-original',
  }) => store.prepareHostTaskOperation(
    taskId: id,
    taskRev: revision,
    hostKey: 'ssh:original-host',
    hostStoreId: hostStore,
    initialOpportunity: initial,
    replayAfterRead: replay,
  );

  MemoryRow snapshot(
    String id, {
    int revision = 1,
    int seq = 1,
    String state = 'running',
    bool original = true,
    List<MemoryRow> steps = const [],
    List<MemoryRow> artifacts = const [],
    MemoryRow? approval,
  }) {
    final commands = store.hostTaskCommands(id);
    final first = commands.first['request']! as Map;
    MemoryRow? value(MemoryRow command) {
      final raw = command['request']! as Map;
      return switch (command['operation']) {
        'create' => {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: raw[key],
        },
        'amend' => Map<String, Object?>.from(raw['changes']! as Map),
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
      'kind': 'host.notes_to_todo',
      'taskRev': revision,
      'runnerReceiptSeq': seq,
      'originalCreatePresent': original,
      'origin': original ? first['origin'] : null,
      'hostSessionId': original ? first['hostSessionId'] : null,
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
      'steps': steps,
      'artifacts': artifacts,
      'approval': approval,
      'budget': {'limitMs': 300000, 'spentMs': 12, 'heldMs': 0},
    };
  }

  MemoryRow acceptSnapshot(String id, MemoryRow value) =>
      store.importHostTaskSnapshot(taskId: id, hostKey: 'ssh:original-host', snapshot: value);

  MemoryRow artifact() => {
    'artifactId': 'file-1',
    'taskRev': 1,
    'stepKey': 'writePage',
    'relativePath': '今日待办.md',
    'mediaType': 'text/markdown',
    'size': 25,
    'sha256': List.filled(64, 'a').join(),
    'verifiedAtMs': now,
    'sourceCount': 2,
  };

  final Matcher conflict = throwsA(
    isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/conflict'),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-host-task-');
    now = 1795219200000;
    open();
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('F foreground prepare persists uncertainty and the same real snapshot settles it after reopen', () {
    say('foreground-source');
    final task = create('foreground-source', selected: agreement(afterExit: 'pause'));
    final id = task['task_id']! as String;
    prepare(id, 1);
    final received = snapshot(id, state: 'waiting')..['waitReason'] = 'foreground_control_unavailable';
    acceptSnapshot(id, received);
    final commands = jsonEncode(store.hostTaskCommands(id));
    final before = store.hostTask(id)!;
    final request = store.prepareHostTaskForeground(
      taskId: id,
      taskRev: 1,
      hostKey: 'ssh:original-host',
      hostStoreId: 'store-original',
      hostExecutionId: 'execution-original',
    );
    expect(request, {
      'v': 1,
      'hostStoreId': 'store-original',
      'hostExecutionId': 'execution-original',
      'taskRev': 1,
      'sourceSessionId': 'light:original-room',
    });
    expect(store.hostTask(id)!['state'], 'unknown');
    expect(store.hostTask(id)!['wait_reason'], 'host_receipt_unknown');
    expect(store.hostTask(id)!['applied_host_receipt_seq'], before['applied_host_receipt_seq']);
    expect(jsonEncode(store.hostTaskCommands(id)), commands);
    reopen();
    expect(store.hostTask(id)!['state'], 'unknown');
    final imported = acceptSnapshot(id, received);
    expect(imported['state'], 'waiting');
    expect(imported['wait_reason'], 'foreground_control_unavailable');
    expect(imported['snapshot'], received);
    expect(imported['applied_host_receipt_seq'], 1);
    expect(jsonEncode(store.hostTaskCommands(id)), commands);
    expect(prepare(id, 1, replay: true), isNull); // A read is not a new foreground request.
  });

  test('F foreground prepare rejects stale identities continue agreements cancellation and elapsed deadlines', () {
    say('foreground-source');
    final task = create('foreground-source', selected: agreement(afterExit: 'pause'));
    final id = task['task_id']! as String;
    prepare(id, 1);
    acceptSnapshot(id, snapshot(id, state: 'waiting'));
    final before = jsonEncode(store.hostTask(id));
    for (final wrong in ['host', 'store', 'execution', 'revision']) {
      expect(
        () => store.prepareHostTaskForeground(
          taskId: id,
          taskRev: wrong == 'revision' ? 2 : 1,
          hostKey: wrong == 'host' ? 'ssh:other-host' : 'ssh:original-host',
          hostStoreId: wrong == 'store' ? 'other-store' : 'store-original',
          hostExecutionId: wrong == 'execution' ? 'other-execution' : 'execution-original',
        ),
        conflict,
      );
      expect(jsonEncode(store.hostTask(id)), before);
    }
    now = 1795219500000;
    expect(
      () => store.prepareHostTaskForeground(
        taskId: id,
        taskRev: 1,
        hostKey: 'ssh:original-host',
        hostStoreId: 'store-original',
        hostExecutionId: 'execution-original',
      ),
      conflict,
    );
    now = 1795219200000;
    say('continue-source');
    final continuing = create('continue-source');
    final continuingId = continuing['task_id']! as String;
    prepare(continuingId, 1);
    acceptSnapshot(continuingId, snapshot(continuingId, state: 'waiting'));
    expect(
      () => store.prepareHostTaskForeground(
        taskId: continuingId,
        taskRev: 1,
        hostKey: 'ssh:original-host',
        hostStoreId: 'store-original',
        hostExecutionId: 'execution-original',
      ),
      conflict,
    );
    say('cancel-foreground');
    store.cancelNotesTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'cancel-foreground',
      expectedSourceRev: 1,
      itemNo: 0,
    );
    expect(
      () => store.prepareHostTaskForeground(
        taskId: id,
        taskRev: 1,
        hostKey: 'ssh:original-host',
        hostStoreId: 'store-original',
        hostExecutionId: 'execution-original',
      ),
      conflict,
    );
    expect(store.hostTask(id)!['task_rev'], 2);
    expect(store.hostTask(id)!['cancel_requested'], 1);
  });

  test('F foreground uncertainty preserves receipts and cannot overwrite a newer receipt revision or result', () {
    say('foreground-source');
    final task = create('foreground-source', selected: agreement(afterExit: 'pause'));
    final id = task['task_id']! as String;
    prepare(id, 1);
    final first = snapshot(id, state: 'waiting');
    acceptSnapshot(id, first);
    bool mark(int seq) => store.markHostTaskForegroundUncertain(
      taskId: id,
      taskRev: 1,
      hostKey: 'ssh:original-host',
      hostStoreId: 'store-original',
      hostExecutionId: 'execution-original',
      expectedHostReceiptSeq: seq,
    );
    final commands = jsonEncode(store.hostTaskCommands(id));
    expect(mark(1), isTrue);
    reopen();
    expect(store.hostTask(id)!['state'], 'unknown');
    expect(store.hostTask(id)!['snapshot'], first);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
    expect(jsonEncode(store.hostTaskCommands(id)), commands);
    expect(acceptSnapshot(id, first)['state'], 'waiting');
    final newer = snapshot(id, seq: 2, state: 'running');
    acceptSnapshot(id, newer);
    expect(mark(1), isFalse);
    expect(store.hostTask(id)!['state'], 'running');
    expect(store.hostTask(id)!['snapshot'], newer);
    final complete = snapshot(id, seq: 3, state: 'done', artifacts: [artifact()]);
    acceptSnapshot(id, complete);
    expect(mark(3), isFalse);
    expect(store.hostTask(id)!['state'], 'done');
    say('cancel-foreground');
    store.cancelNotesTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'cancel-foreground',
      expectedSourceRev: 1,
      itemNo: 0,
    );
    final cancelled = jsonEncode(store.hostTask(id));
    expect(mark(3), isFalse);
    expect(jsonEncode(store.hostTask(id)), cancelled);
  });

  test('F local notes command keeps original room day and args after source deletion and restart', () {
    say('source');
    final accepted = create('source');
    final id = accepted['task_id']! as String;
    final original = store.hostTaskCommands(id).single;
    expect(accepted['host_store_id'], isNull);
    expect(original['possible_sent_at_ms'], isNull);
    expect(accepted['state'], 'queued');
    expect((original['request']! as Map)['hostSessionId'], isNull);
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    now += const Duration(days: 1).inMilliseconds;
    reopen();
    expect(create('source'), accepted);
    expect(store.hostTaskCommands(id).single, original);
    expect(store.hostTask(id)!['agreement'], agreement());
    expect(store.tasks(), hasLength(1));
    expect(store.taskForCommand('source', 0)!['task_id'], id);
  });

  test('F same command different target conflicts while independent identical sources stay distinct', () {
    say('one');
    say('two');
    final first = create('one');
    expect(() => create('one', selected: agreement(output: '另一个目标.md')), conflict);
    final second = create('two');
    expect(first['task_id'], isNot(second['task_id']));
    expect(store.tasks(), hasLength(2));
  });

  for (final length in [129, 256]) {
    test(
      'F complete Host snapshot accepts the protocol source room length $length without changing other identities',
      () {
        final room = List.filled(length, 's').join();
        say('source', session: room);
        final id = create('source')['task_id']! as String;
        prepare(id, 1);
        final accepted = acceptSnapshot(id, snapshot(id));
        expect(accepted['source_session_id'], room);
        expect((accepted['snapshot']! as Map)['origin'], {'sourceSessionId': room, 'messageId': 'source', 'itemNo': 0});
        reopen();
        expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
        expect(store.hostTask(id)!['source_session_id'], room);
      },
    );
  }

  final wire = jsonDecode(File('test/fixtures/companion_host_tasks/F03-wire.json').readAsStringSync()) as Map;
  for (final fixture in (wire['cases']! as List).cast<Map<String, Object?>>()) {
    test('F imports the unchanged frozen Host HTTP snapshot ${fixture['name']}', () {
      final response = Map<String, Object?>.from((fixture['response']! as Map)['body']! as Map);
      final id = response['taskId']! as String;
      // Only ID generation is deterministic. Every source, revision, binding
      // and snapshot goes through the production database methods.
      store.close();
      database = sqlite3.open('${directory.path}/memory.sqlite');
      store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: () => id);
      final origin = response['origin'] as Map?;
      final room = origin?['sourceSessionId'] as String? ?? 'light:original-before-barrier';
      final message = origin?['messageId'] as String? ?? 'original-before-barrier';
      say(message, session: room);
      final selected = Map<String, Object?>.from(response['agreement']! as Map);
      final original = store.createNotesTaskFromMessage(
        messageId: message,
        expectedSourceRev: 1,
        itemNo: origin?['itemNo'] as int? ?? 0,
        roomMode: response['hostSessionId'] == null ? 'light' : 'full',
        hostKey: 'ssh:original-host',
        hostSessionId: response['hostSessionId'] as String?,
        agreement: selected,
      );
      expect(original['task_id'], id);
      store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'ssh:original-host',
        hostStoreId: response['hostStoreId']! as String,
        initialOpportunity: true,
      );
      if (response['taskRev'] == 2) {
        final operation = ((response['revisions']! as List).last as Map)['operation'];
        if (operation == 'cancel') {
          final accepted = Map<String, Object?>.from(((wire['cases']! as List).first as Map)['response']! as Map);
          acceptSnapshot(id, Map<String, Object?>.from(accepted['body']! as Map));
        }
        say('fixture-new-command', session: room);
        if (operation == 'cancel') {
          store.cancelNotesTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'fixture-new-command',
            expectedSourceRev: 1,
            itemNo: 0,
          );
        } else {
          store.amendNotesTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'fixture-new-command',
            expectedSourceRev: 1,
            itemNo: 0,
            agreement: selected,
          );
        }
      }
      final imported = acceptSnapshot(id, response);
      expect(imported['snapshot'], response);
      expect(imported['state'], response['state']);
      expect(imported['task_rev'], response['taskRev']);
      expect(imported['applied_host_receipt_seq'], response['runnerReceiptSeq']);
      reopen();
      expect(store.hostTask(id)!['snapshot'], response);
      if (response['approval'] case final Map<String, Object?> approval) {
        expect(approval['approvalId'], isNot(approval['eventId']));
        expect(store.taskReceipts(id), isEmpty);
      }
    });
  }

  for (final provenance in [(role: 'assistant', scope: 'real'), (role: 'user', scope: 'story')]) {
    test('F ${provenance.role}/${provenance.scope} cannot create a real host task', () {
      say('source', role: provenance.role, scope: provenance.scope);
      expect(() => create('source'), throwsA(isA<DshRemoteException>()));
      expect(store.tasks(), isEmpty);
    });
  }

  test('F command persistence failure rolls back the task and revision together', () {
    say('source');
    database.execute('''
      CREATE TRIGGER fail_host_command BEFORE INSERT ON companion_host_commands
      BEGIN SELECT RAISE(ABORT,'disk full'); END;
    ''');
    expect(() => create('source'), throwsA(isA<SqliteException>()));
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_host_tasks'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
    database.execute('DROP TRIGGER fail_host_command');
    expect(create('source')['state'], 'queued');
  });

  test('F amendment is a new same-room source and never replaces the stored revision one create', () {
    say('create');
    final task = create('create');
    final id = task['task_id']! as String;
    final original = jsonEncode(store.hostTaskCommands(id).single['request']);
    say('other-room', session: 'light:other-room');
    expect(
      () => store.amendNotesTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'other-room',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(output: '更名.md'),
      ),
      throwsA(isA<DshRemoteException>()),
    );
    say('amend');
    final amended = store.amendNotesTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(output: '更名.md'),
    );
    expect(amended['task_rev'], 2);
    expect(amended['source_session_id'], 'light:original-room');
    expect(jsonEncode(store.hostTaskCommands(id).first['request']), original);
    final operation = store.hostTaskCommands(id).last['operation_id'];
    reopen();
    expect(
      store.amendNotesTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'amend',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(output: '更名.md'),
      ),
      amended,
    );
    expect(store.hostTaskCommands(id).last['operation_id'], operation);
    say('stale');
    expect(
      () => store.amendNotesTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'stale',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(),
      ),
      conflict,
    );
  });

  test('F certainly never dispatched task cancels locally and preserves its original agreement', () {
    say('create');
    final task = create('create');
    say('cancel');
    final cancelled = store.cancelNotesTask(
      taskId: task['task_id']! as String,
      expectedTaskRev: 1,
      messageId: 'cancel',
      expectedSourceRev: 1,
      itemNo: 0,
    );
    expect(cancelled['state'], 'cancelled');
    expect(cancelled['cancel_requested'], 1);
    expect(cancelled['agreement'], agreement());
    expect(store.hostTaskCommands(task['task_id']! as String), hasLength(2));
    reopen();
    expect(
      store.cancelNotesTask(
        taskId: task['task_id']! as String,
        expectedTaskRev: 1,
        messageId: 'cancel',
        expectedSourceRev: 1,
        itemNo: 0,
      ),
      cancelled,
    );
  });

  test('F handoff persists original store before HTTP and requires an original read before replay', () {
    say('create');
    final id = create('create')['task_id']! as String;
    final claimed = prepare(id, 1)!;
    expect(claimed['newlyClaimed'], isTrue);
    expect(store.hostTask(id)!['host_store_id'], 'store-original');
    expect(store.hostTask(id)!['state'], 'unknown');
    final body = claimed['request'];
    reopen();
    expect(
      () => prepare(id, 1),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/task-read-required')),
    );
    expect(
      () => prepare(id, 1, replay: true, hostStore: 'replacement-store'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/task-store-mismatch')),
    );
    final replay = prepare(id, 1, replay: true)!;
    expect(replay['newlyClaimed'], isFalse);
    expect(replay['request'], body);
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], claimed['possible_sent_at_ms']);
  });

  test('F failed handoff transaction keeps binding and possible dispatch absent', () {
    say('create');
    final id = create('create')['task_id']! as String;
    database.execute('''CREATE TRIGGER fail_handoff BEFORE UPDATE ON companion_host_commands
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    expect(() => prepare(id, 1), throwsA(isA<SqliteException>()));
    expect(store.hostTask(id)!['host_store_id'], isNull);
    expect(store.hostTask(id)!['state'], 'queued');
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
  });

  test('F null deadline stays null and a lost initial opportunity is not a new automatic queue permission', () {
    say('create');
    final selected = {...agreement(), 'deadlineAtMs': null};
    final id = create('create', selected: selected)['task_id']! as String;
    now += const Duration(days: 1).inMilliseconds;
    expect(prepare(id, 1, initial: false), isNull);
    expect(store.hostTask(id)!['wait_reason'], 'host_initial_opportunity_lost');
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
    expect(store.hostTask(id)!['agreement'], selected);
    say('queue');
    final queued = create('queue', selected: {...selected, 'allowQueue': true, 'afterExit': 'pause'});
    final command = prepare(queued['task_id']! as String, 1, initial: false)!;
    expect((command['request']! as Map)['deadlineAtMs'], isNull);
    expect((command['request']! as Map)['afterExit'], 'pause');
    expect(store.hostTask(queued['task_id']! as String)!['state'], 'unknown');
  });

  test('F explicit elapsed deadline blocks a new create without changing its original day', () {
    say('create');
    final id = create('create')['task_id']! as String;
    now = 1795219500000;
    expect(prepare(id, 1), isNull);
    expect(store.hostTask(id)!['state'], 'failed');
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
    expect((store.hostTask(id)!['agreement']! as Map)['args'], agreement()['args']);
  });

  test('F early amendment barrier is imported before supplying the unchanged original create', () {
    say('create');
    final id = create('create')['task_id']! as String;
    final original = store.hostTaskCommands(id).single['request'];
    say('amend');
    store.amendNotesTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(output: '新名.md'),
    );
    prepare(id, 2);
    expect(() => prepare(id, 1), conflict);
    acceptSnapshot(id, snapshot(id, revision: 2, original: false, state: 'waiting'));
    final creation = prepare(id, 1)!;
    expect(creation['request'], {...(original! as Map), 'hostStoreId': 'store-original'});
    final resolved = acceptSnapshot(id, snapshot(id, revision: 2, seq: 2));
    expect(resolved['state'], 'running');
    expect((resolved['agreement']! as Map)['args'], agreement(output: '新名.md')['args']);
    expect(() => prepare(id, 1, replay: true), conflict);
    expect(prepare(id, 2, replay: true), isNull);
  });

  test('F cancellation revision keeps old file effects while applying complete Host watermark seven', () {
    say('create');
    final id = create('create')['task_id']! as String;
    prepare(id, 1);
    say('cancel');
    store.cancelNotesTask(taskId: id, expectedTaskRev: 1, messageId: 'cancel', expectedSourceRev: 1, itemNo: 0);
    prepare(id, 2);
    final old = snapshot(id, seq: 6, state: 'done', artifacts: [artifact()]);
    final late = acceptSnapshot(id, old);
    expect(late['task_rev'], 2);
    expect(late['state'], 'unknown');
    final complete = snapshot(id, revision: 2, seq: 7, state: 'cancelled', artifacts: [artifact()]);
    final settled = acceptSnapshot(id, complete);
    expect(settled['state'], 'cancelled');
    expect(settled['applied_host_receipt_seq'], 7);
    expect((settled['snapshot']! as Map)['artifacts'], [artifact()]);
    expect(store.taskReceipts(id), isEmpty); // Host sequence is not the phone receipt sequence.
    reopen();
    expect(acceptSnapshot(id, complete), settled);
    expect(acceptSnapshot(id, old), settled);
    expect(() => prepare(id, 1, replay: true), conflict);
    expect(() => acceptSnapshot(id, {...complete, 'waitReason': 'same-seq-different-body'}), conflict);
    expect(() => acceptSnapshot(id, {...complete, 'runnerReceiptSeq': 8, 'artifacts': []}), conflict);
  });

  test('F complete snapshot rollback never advances only the watermark', () {
    say('create');
    final id = create('create')['task_id']! as String;
    prepare(id, 1);
    final previous = acceptSnapshot(id, snapshot(id));
    database.execute('''CREATE TRIGGER fail_head BEFORE UPDATE ON companion_task_revisions
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    expect(
      () => acceptSnapshot(id, snapshot(id, seq: 7, state: 'done', artifacts: [artifact()])),
      throwsA(isA<SqliteException>()),
    );
    expect(store.hostTask(id), previous);
    reopen();
    expect(store.hostTask(id), previous);
  });

  test('F bound identity and complete old steps are checked before changing any saved effects', () {
    say('create');
    final id = create('create')['task_id']! as String;
    prepare(id, 1);
    final step = <String, Object?>{
      'taskRev': 1,
      'stepKey': 'model',
      'attemptId': 'actual-attempt',
      'state': 'unknown',
      'startedAtMs': now,
      'finishedAtMs': null,
      'reason': 'receipt_lost',
      'result': null,
    };
    final original = snapshot(
      id,
      steps: [step],
      approval: {
        'taskRev': 1,
        'stepKey': 'readInputs',
        'agentId': 'real-task-agent',
        'approvalId': 'session-asked-A',
        'eventId': 'gateway-event-E1',
        'callId': 'actual-call',
      },
    );
    final accepted = acceptSnapshot(id, original);
    for (final changed in [
      {...original, 'runnerReceiptSeq': 2, 'hostStoreId': 'new-store'},
      {...original, 'runnerReceiptSeq': 2, 'hostExecutionId': 'new-execution'},
      {
        ...original,
        'runnerReceiptSeq': 2,
        'origin': {'sourceSessionId': 'other-room', 'messageId': 'create', 'itemNo': 0},
      },
      {...original, 'runnerReceiptSeq': 2, 'steps': []},
    ]) {
      expect(() => acceptSnapshot(id, changed), conflict);
      expect(store.hostTask(id), accepted);
    }
    expect(((accepted['snapshot']! as Map)['approval']! as Map)['approvalId'], 'session-asked-A');
    expect(((accepted['snapshot']! as Map)['approval']! as Map)['eventId'], 'gateway-event-E1');
    expect(() => acceptSnapshot(id, snapshot(id, seq: 2, state: 'done')), throwsA(isA<DshRemoteException>()));
  });

  test('F v12 upgrade keeps existing reminder agreement and adds only its two durable tables', () {
    say('reminder');
    final reminder = store.createReminderFromMessage(
      messageId: 'reminder',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      executorId: 'phone-install',
      reminder: const CompanionReminderSpec(
        text: '笔记',
        localDate: '2026-11-21',
        localTime: '08:10',
        zoneId: 'Asia/Shanghai',
        offsetSeconds: 28800,
        epochMs: 1795219800000,
      ),
    );
    restoreOldMemorySchema(database, 12);
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 16);
    expect(store.task(reminder['task_id']! as String), reminder);
    expect(database.select('SELECT * FROM companion_host_tasks'), isEmpty);
    expect(database.select('SELECT * FROM companion_host_commands'), isEmpty);
  });
}
