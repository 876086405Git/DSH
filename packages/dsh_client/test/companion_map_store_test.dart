import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'companion_memory_flow_test.dart' as fixture;
import 'support/old_memory_schema.dart';

const _address = '上海市 科创路 18 号 & 展厅（东门）';
const _selected = CompanionMapSpec(
  address: _address,
  placeName: '东门',
  targetKind: 'selected',
  packageName: 'example.maps',
  componentName: 'example.maps.GeoActivity',
  packageUid: 10234,
  targetLabel: '测试地图',
);
const _choice = CompanionMapSpec(address: _address, placeName: '东门');

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  const now = 1795219200000;

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void restart() {
    store.close();
    open();
  }

  MemoryRow say(
    String id, {
    String text = '把 $_address 在地图打开。',
    String session = 'light:map-room',
    String role = 'user',
    String scope = 'real',
  }) => store.submitMessage(
    id: id,
    sessionId: session,
    text: text,
    role: role,
    scope: scope,
    saidAtUtc: now,
    offsetMinutes: 480,
    zoneId: 'Asia/Shanghai',
    offsetSeconds: 28800,
  );

  MemoryRow create(
    String source, {
    int itemNo = 0,
    int sourceRev = 1,
    CompanionMapSpec map = _selected,
    String roomMode = 'light',
    String? hostKey,
    String? hostSessionId,
  }) => store.createMapOpenFromMessage(
    messageId: source,
    expectedSourceRev: sourceRev,
    itemNo: itemNo,
    roomMode: roomMode,
    hostKey: hostKey,
    hostSessionId: hostSessionId,
    executorId: 'this-installation',
    map: map,
  );

  MemoryRow amend(String id, String command, {int revision = 1, CompanionMapSpec map = _selected}) =>
      store.amendMapOpen(
        taskId: id,
        expectedTaskRev: revision,
        messageId: command,
        expectedSourceRev: 1,
        itemNo: 0,
        map: map,
      );

  MemoryRow cancel(String id, String command, {int revision = 1}) =>
      store.cancelMapOpen(taskId: id, expectedTaskRev: revision, messageId: command, expectedSourceRev: 1, itemNo: 0);

  MemoryRow reopen(String id, String command, {int revision = 1}) => store.reopenMapOpenFromMessage(
    oldTaskId: id,
    expectedTaskRev: revision,
    messageId: command,
    expectedSourceRev: 1,
    itemNo: 0,
    executorId: 'this-installation',
  );

  Matcher error(String code) => throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', code));

  // These exact public-table fixtures test only Dart readback and CAS. They do
  // not call the Android adapter or prove a map/chooser was physically opened.
  void receipt(
    String id, {
    int revision = 1,
    String attempt = 'native-attempt',
    String event = 'claimed',
    String? outcome,
    String? result,
  }) {
    database.execute(
      '''
      INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
        executor_id,occurred_at_ms,outcome,detail_json)
      VALUES(?,?,'map.handoff',?,?,'this-installation',?,?,?)
    ''',
      [
        id,
        revision,
        attempt,
        event,
        now,
        outcome,
        jsonEncode({'fixture': 'native-shaped receipt; no Android call', 'result': ?result}),
      ],
    );
  }

  void nativeState(String id, String state, {int revision = 1, String? reason}) {
    database.execute('UPDATE companion_task_revisions SET state=?,wait_reason=? WHERE task_id=? AND task_rev=?', [
      state,
      reason,
      id,
      revision,
    ]);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-map-store-');
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('scope invalidation commits before another connection can pass the final stored gate', () {
    say('original');
    final task = create('original');
    // Native owns scope creation. This row is its exact SQL shape, not a
    // claim that the Android adapter ran in this Dart test.
    database.execute("INSERT INTO companion_map_scopes VALUES('scope-original','light:map-room',0)");
    final native = sqlite3.open('${directory.path}/memory.sqlite');
    try {
      expect(
        native.select(
          "SELECT scope_id FROM companion_map_scopes WHERE scope_id='scope-original' "
          "AND source_session_id='light:map-room' AND closed=0",
        ),
        hasLength(1),
      );
      store.closeMapHandoffScope(scopeId: 'scope-original', sourceSessionId: 'light:map-room');
      expect(
        native.select(
          "SELECT scope_id FROM companion_map_scopes WHERE scope_id='scope-original' "
          "AND source_session_id='light:map-room' AND closed=0",
        ),
        isEmpty,
      );
      expect(store.mapTask(task['task_id']! as String), task);
      expect(store.taskReceipts(task['task_id']! as String), isEmpty);
    } finally {
      native.close();
    }
  });

  test('wrong-room and delayed old-scope closes cannot revoke the new scope', () {
    database.execute("INSERT INTO companion_map_scopes VALUES('old','light:map-room',0),('new','light:map-room',0)");
    store.closeMapHandoffScope(scopeId: 'old', sourceSessionId: 'light:unrelated');
    expect(database.select('SELECT closed FROM companion_map_scopes').map((row) => row['closed']), [0, 0]);
    store.closeMapHandoffScope(scopeId: 'old', sourceSessionId: 'light:map-room');
    store.closeMapHandoffScope(scopeId: 'old', sourceSessionId: 'light:map-room');
    restart();
    expect(database.select("SELECT closed FROM companion_map_scopes WHERE scope_id='old'").single['closed'], 1);
    expect(database.select("SELECT closed FROM companion_map_scopes WHERE scope_id='new'").single['closed'], 0);
    expect(store.tasks(), isEmpty);
  });

  test('closing a missing scope never grants one or creates a task effect', () {
    store.closeMapHandoffScope(scopeId: 'not-native-created', sourceSessionId: 'light:map-room');
    expect(database.select('SELECT * FROM companion_map_scopes'), isEmpty);
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_receipts'), isEmpty);
  });

  test('a failed scope close throws and does not pretend its fence committed', () {
    database.execute("INSERT INTO companion_map_scopes VALUES('original','light:map-room',0)");
    database.execute('''
      CREATE TRIGGER refuse_scope_close BEFORE UPDATE OF closed ON companion_map_scopes BEGIN
        SELECT RAISE(ABORT,'fixture scope write refusal');
      END
    ''');
    expect(
      () => store.closeMapHandoffScope(scopeId: 'original', sourceSessionId: 'light:map-room'),
      throwsA(isA<SqliteException>()),
    );
    expect(database.select('SELECT closed FROM companion_map_scopes').single['closed'], 0);
    expect(database.select('SELECT * FROM companion_task_receipts'), isEmpty);
  });

  test('same original source and item returns one exact map agreement after restart', () {
    say('original');
    final accepted = create('original');
    final id = accepted['task_id']! as String;
    expect(accepted['kind'], 'phone.map_open');
    expect(accepted['address'], _address);
    expect(accepted['place_name'], '东门');
    expect(accepted['package_name'], 'example.maps');
    expect(accepted['component_name'], 'example.maps.GeoActivity');
    expect(accepted['package_uid'], 10234);
    expect(accepted['target_label'], '测试地图');
    expect(accepted['state'], 'queued');
    expect(accepted['reminder_text'], isNull);
    expect(accepted['lookup_question'], isNull);
    expect(accepted['cancel_requested'], 0);
    expect(accepted['reopens_task_id'], isNull);
    expect(store.taskReceipts(id), isEmpty);
    restart();
    expect(create('original'), accepted);
    expect(store.taskForCommand('original', 0)!['task_id'], id);
    expect(store.tasks(), hasLength(1));
    expect(database.select('SELECT * FROM companion_map_revisions'), hasLength(1));
  });

  test('another item and an independent identical message each create a new action', () {
    say('original', text: '把 $_address 在地图打开；然后再次打开 $_address。');
    say('separate');
    final first = create('original');
    final second = create('original', itemNo: 1);
    final third = create('separate');
    expect({first['task_id'], second['task_id'], third['task_id']}, hasLength(3));
    expect(store.tasks(sourceSessionId: 'light:map-room'), hasLength(3));
    expect(store.messages().first['extraction_state'], 'pending');
  });

  test('same command with different target conflicts without changing the accepted choice', () {
    say('original');
    final accepted = create('original', map: _choice);
    expect(accepted['state'], 'waiting');
    expect(accepted['wait_reason'], 'map_target_choice');
    expect(() => create('original'), error('companion/conflict'));
    expect(store.mapTask(accepted['task_id']! as String), accepted);
    expect(store.taskReceipts(accepted['task_id']! as String), isEmpty);
  });

  for (final entry in [('assistant', 'real'), ('user', 'story')]) {
    test('map task rejects ${entry.$1}/${entry.$2} source before writing an agreement', () {
      say('original', role: entry.$1, scope: entry.$2);
      expect(() => create('original'), error('companion/task-source-invalid'));
      expect(store.tasks(), isEmpty);
    });
  }

  test('current original words are required for a new address and optional place name', () {
    say('original');
    store.editMessage(id: 'original', expectedSourceRev: 1, text: '今天先不打开地图。');
    expect(() => create('original'), error('companion/conflict'));
    expect(() => create('original', sourceRev: 2), error('companion/task-invalid-request'));
    say('other');
    expect(
      () => create(
        'other',
        map: const CompanionMapSpec(address: _address, placeName: '西门'),
      ),
      error('companion/task-invalid-request'),
    );
    expect(store.tasks(), isEmpty);
  });

  for (final invalid in [
    const CompanionMapSpec(address: _address, targetKind: 'selected'),
    const CompanionMapSpec(address: _address, packageName: 'example.maps'),
    const CompanionMapSpec(
      address: _address,
      targetKind: 'default',
      packageName: 'example.maps',
      componentName: 'example.maps.GeoActivity',
      packageUid: -1,
    ),
  ]) {
    test(
      'target ${invalid.targetKind}/${invalid.packageName}/${invalid.packageUid} needs an actual complete identity',
      () {
        say('original');
        expect(() => create('original', map: invalid), error('companion/task-invalid-request'));
        expect(store.tasks(), isEmpty);
      },
    );
  }

  test('full room attribution stays separate from the local map executor', () {
    say('original', session: 'full:original-room');
    final accepted = create('original', roomMode: 'full', hostKey: 'ssh:offline-host', hostSessionId: 'agent-original');
    expect(accepted['source_session_id'], 'full:original-room');
    expect(accepted['host_key'], 'ssh:offline-host');
    expect(accepted['host_session_id'], 'agent-original');
    expect(accepted['executor_id'], 'this-installation');
    expect(accepted['state'], 'queued');
  });

  test('explicit target selection amends only an unperformed agreement and repeats idempotently', () {
    say('original');
    final id = create('original', map: _choice)['task_id']! as String;
    say('selection', text: '用这张地图打开。');
    final selected = amend(id, 'selection');
    expect(selected['task_rev'], 2);
    expect(selected['address'], _address);
    expect(selected['state'], 'queued');
    restart();
    expect(amend(id, 'selection'), selected);
    say('stale', text: '改一下地图。');
    expect(() => amend(id, 'stale'), error('companion/conflict'));
    expect(database.select('SELECT * FROM companion_map_revisions'), hasLength(2));
  });

  test('cross-room amendment and cancellation cannot act on the original task', () {
    say('original');
    final id = create('original')['task_id']! as String;
    say('other', text: '换地图并取消。', session: 'light:unrelated');
    expect(() => amend(id, 'other'), error('companion/conflict'));
    expect(() => cancel(id, 'other'), error('companion/conflict'));
    expect(store.mapTask(id)!['task_rev'], 1);
  });

  for (final chooser in [false, true]) {
    test('${chooser ? 'chooser return' : 'unsettled claim'} cannot be amended into another handoff', () {
      say('original');
      final id = create('original', map: chooser ? _choice : _selected)['task_id']! as String;
      receipt(id);
      nativeState(id, chooser ? 'waiting' : 'unknown', reason: chooser ? 'map_target_choice' : 'map_handoff_pending');
      if (chooser) {
        receipt(id, event: 'returned', outcome: 'unknown', result: 'chooser_shown');
      }
      final before = store.taskReceipts(id);
      restart();
      say('change', text: '现在用这张地图。');
      expect(() => amend(id, 'change'), error('companion/conflict'));
      expect(create('original', map: chooser ? _choice : _selected)['task_id'], id);
      expect(store.taskReceipts(id), before);
      expect(store.mapTask(id)!['task_rev'], 1);
    });
  }

  test('a proven not-performed block permits a new explicit amendment without erasing the old receipt', () {
    say('original');
    final id = create('original')['task_id']! as String;
    receipt(id);
    receipt(id, event: 'blocked', outcome: 'not_performed', result: 'locked');
    nativeState(id, 'waiting', reason: 'locked');
    say('change', text: '现在用系统默认地图。');
    final changed = amend(
      id,
      'change',
      map: const CompanionMapSpec(
        address: _address,
        placeName: '东门',
        targetKind: 'default',
        packageName: 'another.maps',
        componentName: 'another.maps.Geo',
        packageUid: 10345,
      ),
    );
    expect(changed['task_rev'], 2);
    expect(changed['target_kind'], 'default');
    expect(store.taskReceipts(id), hasLength(2));
    expect(store.taskReceipts(id).last['outcome'], 'not_performed');
  });

  test('cancel commits a new fence while old unknown and late original-revision effects remain readable', () {
    say('original');
    final id = create('original')['task_id']! as String;
    receipt(id);
    nativeState(id, 'unknown', reason: 'map_handoff_pending');
    say('cancel', text: '不用打开了。');
    final stopped = cancel(id, 'cancel');
    expect(stopped['task_rev'], 2);
    expect(stopped['state'], 'cancelled');
    expect(stopped['cancel_requested'], 1);
    expect(cancel(id, 'cancel')['task_rev'], 2);
    // Exact old-revision update shape; this does not exercise native's physical
    // SQLite/startActivity transaction, which has its own platform test gate.
    receipt(id, event: 'returned', outcome: 'succeeded', result: 'handoff_dispatched');
    nativeState(id, 'done');
    restart();
    expect(store.mapTask(id)!['state'], 'cancelled');
    expect(store.mapTask(id)!['task_rev'], 2);
    final old = store.taskReceipts(id).last;
    expect(old['task_rev'], 1);
    expect((old['detail']! as Map<String, Object?>)['result'], 'handoff_dispatched');
    expect(store.mapTask(id)!['runner_receipt_seq'], old['runner_receipt_seq']);
    expect(store.taskReceipts(id, afterSeq: old['runner_receipt_seq']! as int), isEmpty);
  });

  test('explicit reopen without repeating the address creates a new task and preserves old unknown', () {
    say('original');
    final oldId = create('original')['task_id']! as String;
    receipt(oldId);
    nativeState(oldId, 'unknown', reason: 'map_handoff_pending');
    final before = store.mapTask(oldId);
    final receipts = store.taskReceipts(oldId);
    say('again', text: '重新打开。');
    final fresh = reopen(oldId, 'again');
    expect(fresh['task_id'], isNot(oldId));
    expect(fresh['task_rev'], 1);
    expect(fresh['address'], _address);
    expect(fresh['package_uid'], 10234);
    expect(fresh['reopens_task_id'], oldId);
    expect(fresh['source_message_id'], 'again');
    expect(fresh['state'], 'queued');
    expect(store.taskReceipts(fresh['task_id']! as String), isEmpty);
    expect(store.mapTask(oldId), before);
    expect(store.taskReceipts(oldId), receipts);
    restart();
    expect(reopen(oldId, 'again'), fresh);
    expect(store.tasks(), hasLength(2));
  });

  test('reopen is bound to the original room, explicit old task revision and a new command', () {
    say('original');
    final id = create('original')['task_id']! as String;
    say('wrong-room', text: '重新打开。', session: 'light:other');
    expect(() => reopen(id, 'wrong-room'), error('companion/conflict'));
    say('new', text: '重新打开。');
    expect(() => reopen(id, 'new', revision: 2), error('companion/conflict'));
    expect(() => reopen(id, 'original'), error('companion/conflict'));
    expect(store.tasks(), hasLength(1));
  });

  test('accepted reopen remains independent if its old task is later removed', () {
    say('original');
    final old = create('original')['task_id']! as String;
    say('again', text: '重新打开。');
    final accepted = reopen(old, 'again');
    database.execute('DELETE FROM companion_tasks WHERE task_id=?', [old]);
    restart();
    expect(store.mapTask(old), isNull);
    expect(reopen(old, 'again'), accepted);
    expect(store.mapTask(accepted['task_id']! as String)!['reopens_task_id'], old);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('raw memory forget removes the source but preserves its independent map agreement and receipt', () {
    final source = say('mixed', text: '我咖啡只喝无糖。把 $_address 在地图打开。');
    final id = create('mixed')['task_id']! as String;
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
    const words = '忘掉我咖啡只喝无糖，连原话也删';
    say('forget', text: words);
    final control = parseMemoryControl(
      words,
      store.cards(includeInactive: true),
      topicControls: store.topicControls(),
    )!;
    store.applyControl(
      topicIds: (control['topic_ids']! as List).cast<String>(),
      kind: 'forget',
      controlMessageId: 'forget',
      deleteChat: control['delete_chat'] == true,
    );
    restart();
    expect(store.messages().any((row) => row['id'] == 'mixed'), isFalse);
    expect(store.cards(), isEmpty);
    expect(store.mapTask(id)!['address'], _address);
    expect(store.mapTask(id)!['cancel_requested'], 0);
    expect(store.taskReceipts(id).single['event_kind'], 'claimed');
  });

  test('a map-row commit failure rolls back common task acceptance and keeps the source pending', () {
    say('original');
    database.execute('''
      CREATE TRIGGER reject_map BEFORE INSERT ON companion_map_revisions BEGIN
        SELECT RAISE(ABORT,'fixture commit refusal');
      END
    ''');
    expect(() => create('original'), throwsA(isA<SqliteException>()));
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_receipts'), isEmpty);
    expect(store.messages().single['extraction_state'], 'pending');
  });

  test('a genuine v13 database gains the map and agent tables and retains earlier task rows and schemas', () {
    say('reminder', text: '提醒我带证件。');
    final prior = store.createReminderFromMessage(
      messageId: 'reminder',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      executorId: 'this-installation',
      reminder: const CompanionReminderSpec(text: '带证件', waitReason: 'date_missing'),
    );
    restoreOldMemorySchema(database, 13);
    final schema = database
        .select("SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    expect(
      database.select(
        "SELECT name FROM sqlite_master WHERE name IN ('companion_map_revisions','companion_map_scopes')",
      ),
      isEmpty,
    );
    restart();
    expect(database.select('PRAGMA user_version').single['user_version'], 17);
    expect(store.task(prior['task_id']! as String), prior);
    // Tables that existed before the upgrade keep their schema, except the
    // ones later versions deliberately alter. New tables are not compared.
    const altered = {'memory_followups', 'memory_cards', 'memory_messages', 'memory_topics', 'memory_requests'};
    final before = {for (final row in schema) row['name']};
    expect(
      [
        for (final row in database.select(
          "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
        ))
          if (before.contains(row['name']) && !altered.contains(row['name'])) Map<String, Object?>.from(row),
      ],
      [
        for (final row in schema)
          if (!altered.contains(row['name'])) row,
      ],
    );
    expect(database.select('SELECT * FROM companion_map_scopes'), isEmpty);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('a failed v14 schema creation does not advance the genuine v13 database', () {
    final path = '${directory.path}/broken-upgrade.sqlite';
    final oldDb = sqlite3.open(path);
    final oldStore = CompanionMemoryStore(oldDb, nowMilliseconds: () => now);
    restoreOldMemorySchema(oldDb, 13);
    // The second CREATE fails: the first table must roll back too.
    oldDb.execute('CREATE TABLE companion_map_scopes(fixture TEXT)');
    oldStore.close();
    expect(() => CompanionMemoryStore(sqlite3.open(path), nowMilliseconds: () => now), throwsA(isA<SqliteException>()));
    final failed = sqlite3.open(path);
    try {
      expect(failed.select('PRAGMA user_version').single['user_version'], 13);
      expect(failed.select('PRAGMA table_info(companion_map_scopes)').single['name'], 'fixture');
      expect(failed.select("SELECT name FROM sqlite_master WHERE name='companion_map_revisions'"), isEmpty);
      expect(failed.select('SELECT * FROM companion_tasks'), isEmpty);
      expect(failed.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      failed.close();
    }
  });
}
