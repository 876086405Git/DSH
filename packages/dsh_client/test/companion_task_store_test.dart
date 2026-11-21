import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'companion_memory_flow_test.dart' as fixture;
import 'support/old_memory_schema.dart';

const _eight = CompanionReminderSpec(
  text: '带证件',
  localDate: '2026-11-03',
  localTime: '08:00',
  zoneId: 'Asia/Shanghai',
  offsetSeconds: 28800,
  epochMs: 1793664000000,
);
const _eightThirty = CompanionReminderSpec(
  text: '带证件',
  localDate: '2026-11-03',
  localTime: '08:30',
  zoneId: 'Asia/Shanghai',
  offsetSeconds: 28800,
  epochMs: 1793665800000,
);

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1793634900000; // 2026-11-02 23:55 at UTC+08:00.

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow say(
    String id, {
    String text = '明早八点提醒我带证件。',
    String session = 'room:original',
    String role = 'user',
    String scope = 'real',
    String? zone = 'Asia/Shanghai',
    int? offsetSeconds = 28800,
    int offsetMinutes = 480,
  }) => store.submitMessage(
    id: id,
    sessionId: session,
    text: text,
    role: role,
    scope: scope,
    saidAtUtc: now,
    offsetMinutes: offsetMinutes,
    zoneId: zone,
    offsetSeconds: offsetSeconds,
  );

  MemoryRow create(
    String id, {
    int sourceRev = 1,
    int itemNo = 0,
    String roomMode = 'light',
    String? hostKey,
    String? hostSessionId,
    String executor = 'installation-one',
    CompanionReminderSpec reminder = _eight,
  }) => store.createReminderFromMessage(
    messageId: id,
    expectedSourceRev: sourceRev,
    itemNo: itemNo,
    roomMode: roomMode,
    hostKey: hostKey,
    hostSessionId: hostSessionId,
    executorId: executor,
    reminder: reminder,
  );

  MemoryRow amend(String taskId, String command, {int revision = 1, CompanionReminderSpec reminder = _eightThirty}) =>
      store.amendReminder(
        taskId: taskId,
        expectedTaskRev: revision,
        messageId: command,
        expectedSourceRev: 1,
        itemNo: 0,
        reminder: reminder,
      );

  MemoryRow cancel(String taskId, String command, {int revision = 1}) => store.cancelReminder(
    taskId: taskId,
    expectedTaskRev: revision,
    messageId: command,
    expectedSourceRev: 1,
    itemNo: 0,
  );

  Matcher error(String code) => throwsA(isA<DshRemoteException>().having((value) => value.code, 'code', code));

  // Native-shaped persisted receipt fixtures verify only SDK readback/foreign
  // keys. They do not execute the Kotlin runner or prove any Android effect.
  void receipt(
    String taskId, {
    int revision = 1,
    String attempt = 'physical-attempt-one',
    String event = 'claimed',
    String? outcome,
    int? at,
  }) {
    database.execute(
      '''
      INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
        executor_id,occurred_at_ms,effect_id,outcome,detail_json)
      VALUES(?,?,'alarm.register',?,?,'installation-one',?,?,?,?)
    ''',
      [
        taskId,
        revision,
        attempt,
        event,
        at ?? now,
        'dsh-reminder://alarm/$taskId/$revision',
        outcome,
        jsonEncode({'fixture': 'persisted native receipt; no system call'}),
      ],
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-reminder-store-');
    now = 1793634900000;
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('one source and item accepts one agreement across retries and restart', () {
    say('source');
    final accepted = create('source');
    expect(accepted['state'], 'queued');
    expect(accepted['cancel_requested'], 0);
    expect(accepted['runner_receipt_seq'], 0);
    expect(store.taskReceipts(accepted['task_id'] as String), isEmpty);
    expect(create('source'), accepted);
    reopen();
    expect(create('source'), accepted);
    expect(store.taskForCommand('source', 0), accepted);
    expect(store.tasks(), hasLength(1));
    expect(database.select('SELECT * FROM companion_task_revisions'), hasLength(1));
  });

  test('a second item and an independent identical message remain independent tasks', () {
    const two = '明早八点提醒我带证件；再加一条明早八点提醒我带证件。';
    say('source', text: two);
    final first = create('source');
    final secondItem = create('source', itemNo: 1);
    say('independent', text: two);
    final independent = create('independent');
    expect({first['task_id'], secondItem['task_id'], independent['task_id']}, hasLength(3));
    expect(store.tasks(), hasLength(3));
    expect(store.taskForCommand('source', 1)!['task_id'], secondItem['task_id']);
  });

  test('the same command key cannot change time, executor or original host', () {
    say('source');
    final accepted = create('source', roomMode: 'full', hostKey: 'host-one', hostSessionId: 'host-session-one');
    expect(
      () => create(
        'source',
        roomMode: 'full',
        hostKey: 'host-one',
        hostSessionId: 'host-session-one',
        reminder: _eightThirty,
      ),
      error('companion/conflict'),
    );
    expect(
      () => create(
        'source',
        roomMode: 'full',
        hostKey: 'host-one',
        hostSessionId: 'host-session-one',
        executor: 'new-installation',
      ),
      error('companion/conflict'),
    );
    expect(() => create('source', roomMode: 'full', hostKey: 'host-two'), error('companion/conflict'));
    expect(store.task(accepted['task_id'] as String), accepted);
    expect(database.select('SELECT * FROM companion_task_revisions'), hasLength(1));
  });

  for (final source in [(role: 'assistant', scope: 'real'), (role: 'user', scope: 'story')]) {
    test('${source.role}/${source.scope} cannot create a real reminder', () {
      say('source', role: source.role, scope: source.scope);
      expect(() => create('source'), error('companion/task-source-invalid'));
      expect(store.tasks(), isEmpty);
    });
  }

  test('create uses the current source revision and its literal reminder subject', () {
    say('source');
    store.editMessage(id: 'source', expectedSourceRev: 1, text: '明早八点提醒我带钥匙。');
    expect(() => create('source'), error('companion/conflict'));
    expect(() => create('source', sourceRev: 2), error('companion/task-invalid-request'));
    expect(() => create('missing'), error('companion/conflict'));
    expect(store.tasks(), isEmpty);
  });

  test('light has no host and full needs an explicit original host', () {
    say('source');
    expect(() => create('source', hostKey: 'host-one'), error('companion/task-invalid-request'));
    expect(() => create('source', roomMode: 'full'), error('companion/task-invalid-request'));
    expect(() => create('source', executor: ''), error('companion/task-invalid-request'));
    expect(store.tasks(), isEmpty);
    final accepted = create('source', roomMode: 'full', hostKey: 'host-one');
    expect(accepted['host_session_id'], isNull);
  });

  test('a stored source retains its one clock observation through edit and restart', () {
    final original = say('source');
    expect(() => say('source', zone: 'Asia/Singapore'), error('companion/conflict'));
    expect(() => say('source', offsetSeconds: 28801), error('companion/conflict'));
    expect(() => say('bad-offset', offsetSeconds: 0), error('companion/invalid-request'));
    now += const Duration(days: 2).inMilliseconds;
    store.editMessage(id: 'source', expectedSourceRev: 1, text: '明早八点提醒我带证件，别忘了。');
    reopen();
    final edited = store.messages().single;
    expect(edited['said_at_utc'], original['said_at_utc']);
    expect(edited['zone_id'], 'Asia/Shanghai');
    expect(edited['offset_seconds'], 28800);
    expect(edited['offset_minutes'], 480);
    final accepted = create('source', sourceRev: 2);
    expect(accepted['source_said_at_utc'], original['said_at_utc']);
    expect(accepted['source_zone_id'], 'Asia/Shanghai');
    expect(accepted['source_offset_seconds'], 28800);
    expect(accepted['epoch_ms'], _eight.epochMs);
  });

  test('waiting for a missing time is amended on the same task using a new command clock', () {
    say('source', text: '明天提醒我带证件。');
    final waiting = create(
      'source',
      reminder: const CompanionReminderSpec(
        text: '带证件',
        localDate: '2026-11-03',
        zoneId: 'Asia/Shanghai',
        waitReason: 'time_missing',
      ),
    );
    expect(waiting['state'], 'waiting');
    expect(waiting['epoch_ms'], isNull);
    expect(waiting['offset_seconds'], isNull);
    now += const Duration(hours: 12).inMilliseconds;
    say('amend', text: '改到八点半。', zone: 'America/New_York', offsetSeconds: -18000, offsetMinutes: -300);
    final revised = amend(waiting['task_id'] as String, 'amend');
    expect(revised['task_id'], waiting['task_id']);
    expect(revised['task_rev'], 2);
    expect(revised['source_message_id'], 'source');
    expect(revised['command_message_id'], 'amend');
    expect(revised['source_said_at_utc'], now);
    expect(revised['source_zone_id'], 'America/New_York');
    expect(revised['zone_id'], 'Asia/Shanghai');
    expect(revised['executor_id'], 'installation-one');
    expect(revised['state'], 'queued');
    expect(revised['wait_reason'], isNull);
  });

  for (final invalid in <String, CompanionReminderSpec>{
    'nonexistent calendar date': const CompanionReminderSpec(
      text: '带证件',
      localDate: '2026-02-30',
      zoneId: 'Asia/Shanghai',
      waitReason: 'time_missing',
    ),
    'invalid clock': const CompanionReminderSpec(
      text: '带证件',
      localDate: '2026-11-03',
      localTime: '24:00',
      zoneId: 'Asia/Shanghai',
      waitReason: 'time_gap',
    ),
    'epoch without selected offset': const CompanionReminderSpec(
      text: '带证件',
      localDate: '2026-11-03',
      localTime: '08:00',
      zoneId: 'Asia/Shanghai',
      epochMs: 1793664000000,
    ),
    'inconsistent epoch and explicit offset': const CompanionReminderSpec(
      text: '带证件',
      localDate: '2026-11-03',
      localTime: '08:00',
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
      epochMs: 1793665800000,
    ),
    'no actual missing field': const CompanionReminderSpec(
      text: '带证件',
      localDate: '2026-11-03',
      localTime: '08:00',
      zoneId: 'Asia/Shanghai',
      waitReason: 'time_missing',
    ),
  }.entries) {
    test('${invalid.key} is rejected before a reminder is accepted', () {
      say('source');
      expect(() => create('source', reminder: invalid.value), error('companion/task-invalid-request'));
      expect(store.tasks(), isEmpty);
      expect(store.taskForCommand('source', 0), isNull);
    });
  }

  for (final unresolved in [
    (reason: 'time_gap', date: '2026-03-08', time: '02:30'),
    (reason: 'time_overlap', date: '2026-11-01', time: '01:30'),
  ]) {
    test('an unresolved ${unresolved.reason} amendment retains old claims without guessing an instant', () {
      say('source');
      final id = create('source')['task_id'] as String;
      receipt(id);
      database.execute("UPDATE companion_task_revisions SET state='unknown' WHERE task_id=? AND task_rev=1", [id]);
      say('amend', text: '改到 ${unresolved.date} ${unresolved.time}。');
      // The native resolver owns this classification; this checks storage only.
      final task = amend(
        id,
        'amend',
        reminder: CompanionReminderSpec(
          text: '带证件',
          localDate: unresolved.date,
          localTime: unresolved.time,
          zoneId: 'America/Los_Angeles',
          waitReason: unresolved.reason,
        ),
      );
      expect(task['task_rev'], 2);
      expect(task['operation'], 'amend');
      expect(task['state'], 'waiting');
      expect(task['wait_reason'], unresolved.reason);
      expect(task['epoch_ms'], isNull);
      expect(task['offset_seconds'], isNull);
      expect(store.taskReceipts(id).single['task_rev'], 1);
      expect(store.taskReceipts(id).single['event_kind'], 'claimed');
    });
  }

  for (final operation in ['amend', 'cancel']) {
    test('$operation requires a new command in the original room and keeps the original executor', () {
      say('source');
      final accepted = create('source', roomMode: 'full', hostKey: 'host-one', hostSessionId: 'host-session-one');
      final id = accepted['task_id'] as String;
      say('elsewhere', text: '改到八点半。', session: 'room:other');
      expect(
        () => operation == 'amend' ? amend(id, 'elsewhere') : cancel(id, 'elsewhere'),
        error('companion/conflict'),
      );
      expect(store.task(id), accepted);
      expect(store.taskForCommand('elsewhere', 0), isNull);
      say('stale', text: '改到八点半。');
      store.editMessage(id: 'stale', expectedSourceRev: 1, text: '改到八点半，带证件。');
      expect(() => operation == 'amend' ? amend(id, 'stale') : cancel(id, 'stale'), error('companion/conflict'));
      expect(store.task(id), accepted);
      say('original', text: operation == 'amend' ? '改到八点半。' : '取消提醒。');
      final revised = operation == 'amend' ? amend(id, 'original') : cancel(id, 'original');
      expect(revised['source_session_id'], 'room:original');
      expect(revised['room_mode'], 'full');
      expect(revised['host_key'], 'host-one');
      expect(revised['host_session_id'], 'host-session-one');
      expect(revised['executor_id'], 'installation-one');
      expect(store.tasks(sourceSessionId: 'room:other'), isEmpty);
      expect(store.tasks(sourceSessionId: 'room:original').single['task_id'], id);
    });
  }

  test('accepted command retries return the current agreement after amendment and raw source deletion', () {
    say('source');
    final id = create('source')['task_id'] as String;
    say('amend', text: '改到八点半。');
    final revised = amend(id, 'amend');
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    store.deleteMessage(id: 'amend', expectedSourceRev: 1);
    reopen();
    expect(create('source'), revised);
    expect(amend(id, 'amend'), revised);
    expect(store.taskForCommand('source', 0), revised);
    expect(store.taskForCommand('amend', 0), revised);
    expect(database.select('SELECT * FROM companion_task_revisions'), hasLength(2));
  });

  test('ordinary source edits do not amend an accepted task or replace its command key', () {
    say('source');
    final original = create('source');
    store.editMessage(id: 'source', expectedSourceRev: 1, text: '明早八点半提醒我带证件。');
    expect(store.task(original['task_id'] as String), original);
    expect(() => create('source', sourceRev: 2, reminder: _eightThirty), error('companion/conflict'));
    expect(store.taskForCommand('source', 0), original);
  });

  test('new stale commands cannot modify the current revision and an accepted cancel retries once', () {
    say('source');
    final id = create('source')['task_id'] as String;
    say('amend', text: '改到八点半。');
    final revised = amend(id, 'amend');
    say('cancel', text: '取消提醒。');
    expect(() => cancel(id, 'cancel'), error('companion/conflict'));
    expect(store.task(id), revised);
    expect(store.taskForCommand('cancel', 0), isNull);
    final stopped = cancel(id, 'cancel', revision: 2);
    expect(stopped['task_rev'], 3);
    expect(stopped['cancel_requested'], 1);
    expect(stopped['state'], 'cancelled');
    expect(cancel(id, 'cancel', revision: 2), stopped);
    expect(database.select('SELECT * FROM companion_task_revisions'), hasLength(3));
  });

  test('a failed head update rolls back its new revision and command idempotency key', () {
    say('source');
    final accepted = create('source');
    final id = accepted['task_id'] as String;
    say('amend', text: '改到八点半。');
    database.execute('''
      CREATE TRIGGER fail_task_head BEFORE UPDATE OF current_rev ON companion_tasks
      BEGIN SELECT RAISE(ABORT,'task head fixture'); END
    ''');
    expect(() => amend(id, 'amend'), throwsA(isA<SqliteException>()));
    expect(store.task(id), accepted);
    expect(store.taskForCommand('amend', 0), isNull);
    expect(database.select('SELECT * FROM companion_task_revisions'), hasLength(1));
    database.execute('DROP TRIGGER fail_task_head');
    expect(amend(id, 'amend')['task_rev'], 2);
  });

  test('a failed first revision does not leave a task head that claims acceptance', () {
    say('source');
    database.execute('''
      CREATE TRIGGER fail_task_revision BEFORE INSERT ON companion_task_revisions
      BEGIN SELECT RAISE(ABORT,'task revision fixture'); END
    ''');
    expect(() => create('source'), throwsA(isA<SqliteException>()));
    expect(database.select('SELECT * FROM companion_tasks'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
    expect(store.taskForCommand('source', 0), isNull);
  });

  test('a registration claim keeps cancellation queued until native proves stopping', () {
    say('source');
    final id = create('source')['task_id'] as String;
    receipt(id);
    database.execute("UPDATE companion_task_revisions SET state='unknown' WHERE task_id=? AND task_rev=1", [id]);
    say('cancel', text: '取消提醒。');
    final stopped = cancel(id, 'cancel');
    expect(stopped['state'], 'queued');
    expect(stopped['cancel_requested'], 1);
    expect(stopped['task_rev'], 2);
    expect(
      database.select('SELECT state FROM companion_task_revisions WHERE task_id=? AND task_rev=1', [
        id,
      ]).single['state'],
      'unknown',
    );
    expect(store.taskReceipts(id).single['event_kind'], 'claimed');
  });

  test('late old revision receipts remain readable without changing the current plan', () {
    say('source');
    final id = create('source')['task_id'] as String;
    receipt(id);
    final firstSeq = store.taskReceipts(id).single['runner_receipt_seq'] as int;
    say('amend', text: '改到八点半。');
    amend(id, 'amend');
    // This fixture writes the old revision, as the native transaction must.
    receipt(id, event: 'returned', outcome: 'succeeded', at: now - 1000);
    database.execute("UPDATE companion_task_revisions SET state='done' WHERE task_id=? AND task_rev=1", [id]);
    reopen();
    final current = store.task(id)!;
    expect(current['task_rev'], 2);
    expect(current['state'], 'queued');
    expect(current['local_time'], '08:30');
    final late = store.taskReceipts(id, afterSeq: firstSeq).single;
    expect(late['task_rev'], 1);
    expect(late['event_kind'], 'returned');
    expect(late['outcome'], 'succeeded');
    expect(late['occurred_at_ms'], now - 1000);
    expect(late['detail'], {'fixture': 'persisted native receipt; no system call'});
    expect(current['runner_receipt_seq'], late['runner_receipt_seq']);
    expect(store.taskReceipts(id, afterSeq: late['runner_receipt_seq'] as int), isEmpty);
    expect(() => receipt(id, event: 'returned', outcome: 'succeeded'), throwsA(isA<SqliteException>()));
    expect(store.taskReceipts(id), hasLength(2));
  });

  for (final raw in [false, true]) {
    test('memory forget with raw=$raw preserves the independent reminder and its receipts', () {
      final source = say('mixed', text: '我咖啡只喝无糖。明早八点提醒我带证件。');
      final task = create('mixed');
      final id = task['task_id'] as String;
      receipt(id);
      final batch = store.nextBatch(forceTail: true, estimateTokens: fixture.estimate)!;
      expect(
        store.commitExtraction(
          batch,
          fixture.parsed(batch, [
            fixture.create(source, text: '我咖啡只喝无糖。', quote: '我咖啡只喝无糖。', keywords: ['咖啡']),
          ]),
        ),
        isTrue,
      );
      final text = raw ? '忘掉我咖啡只喝无糖，连原话也删' : '忘掉我咖啡只喝无糖';
      say('forget', text: text);
      final control = parseMemoryControl(
        text,
        store.cards(includeInactive: true),
        topicControls: store.topicControls(),
      )!;
      expect(control['ambiguous'], isFalse);
      expect(control['kind'], 'forget');
      store.applyControl(
        topicIds: (control['topic_ids'] as List<Object?>).cast<String>(),
        kind: 'forget',
        controlMessageId: 'forget',
        deleteChat: control['delete_chat'] == true,
      );
      reopen();
      expect(store.cards(), isEmpty);
      expect(store.messages().any((row) => row['id'] == 'mixed'), !raw);
      expect(store.tasks().single['task_id'], id);
      expect(store.task(id)!['cancel_requested'], 0);
      expect(store.task(id)!['epoch_ms'], _eight.epochMs);
      expect(store.taskReceipts(id).single['event_kind'], 'claimed');
      expect(store.taskForCommand('mixed', 0)!['task_id'], id);
    });
  }

  test('task acceptance leaves the other part of a mixed source available to extraction', () {
    say('mixed', text: '明早八点提醒我带证件；我咖啡只喝无糖。');
    create('mixed');
    expect(store.messages().single['extraction_state'], 'pending');
    final batch = store.nextBatch(forceTail: true, estimateTokens: fixture.estimate)!;
    expect(batch.sources.single['id'], 'mixed');
    expect(batch.sources.single['text'], contains('我咖啡只喝无糖。'));
  });

  test('a genuine v10 store upgrades without inventing a source zone or replacing existing facts', () {
    final source = say('old', text: '我咖啡只喝无糖。');
    final batch = store.nextBatch(forceTail: true, estimateTokens: fixture.estimate)!;
    expect(
      store.commitExtraction(
        batch,
        fixture.parsed(batch, [
          fixture.create(source, keywords: ['咖啡']),
        ]),
      ),
      isTrue,
    );
    final card = store.cards().single;
    restoreOldMemorySchema(database, 10);
    expect(database.select('PRAGMA table_info(memory_messages)').map((row) => row['name']), isNot(contains('zone_id')));
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 13);
    expect(store.messages().single['zone_id'], isNull);
    expect(store.messages().single['offset_seconds'], isNull);
    expect(store.messages().single['said_at_utc'], source['said_at_utc']);
    expect(store.messages().single['offset_minutes'], 480);
    expect(store.cards().single, card);
    expect(store.tasks(), isEmpty);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    expect(database.select('PRAGMA busy_timeout').single['timeout'], 1000);
  });

  test('a v11 migration failure rolls back both source columns and its new schema version', () {
    final path = '${directory.path}/migration-failure.sqlite';
    final oldDatabase = sqlite3.open(path);
    final oldStore = CompanionMemoryStore(oldDatabase, nowMilliseconds: () => now);
    restoreOldMemorySchema(oldDatabase, 10);
    oldDatabase.execute('CREATE TABLE companion_tasks (fixture INTEGER)');
    oldStore.close();
    expect(() => CompanionMemoryStore(sqlite3.open(path), nowMilliseconds: () => now), throwsA(isA<SqliteException>()));
    final failed = sqlite3.open(path);
    try {
      expect(failed.select('PRAGMA user_version').single['user_version'], 10);
      final columns = failed.select('PRAGMA table_info(memory_messages)').map((row) => row['name']);
      expect(columns, isNot(contains('zone_id')));
      expect(columns, isNot(contains('offset_seconds')));
      expect(failed.select("SELECT name FROM sqlite_schema WHERE name='companion_task_revisions'"), isEmpty);
      expect(failed.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      failed.close();
    }
  });
}
