import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'companion_memory_flow_test.dart' as fixture;
import 'support/old_memory_schema.dart';

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow say(String id, String text) =>
      store.submitMessage(id: id, sessionId: 'room', text: text, saidAtUtc: now, offsetMinutes: 480);

  MemoryRow remember(String id, String text, List<String> words) {
    final source = say(id, text);
    final batch = store.nextBatch(forceTail: true, estimateTokens: fixture.estimate)!;
    expect(store.commitExtraction(batch, fixture.parsed(batch, [fixture.create(source, keywords: words)])), isTrue);
    return store.cards().singleWhere(
      (card) => (card['evidence'] as List<Object?>).cast<MemoryRow>().any((proof) => proof['message_id'] == id),
    );
  }

  List<String> anchors(String topic) =>
      (jsonDecode(
                database.select('SELECT control_anchors FROM memory_topics WHERE id=?', [
                      topic,
                    ]).single['control_anchors']
                    as String,
              )
              as List<Object?>)
          .cast<String>();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-control-anchor-');
    now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  for (final mode in ['less', 'never']) {
    test('$mode control survives sole-proof withdrawal and restart without becoming fact evidence', () {
      final old = remember('old', '我周五复诊，周六去公园。', ['复诊']);
      final topic = old['topic_id'] as String;
      store.applyControl(topicIds: [topic], kind: mode);
      expect(anchors(topic), ['复诊']);
      now += 60000;
      store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周五复诊，周日去公园。');
      expect(store.cards(), isEmpty);
      reopen();
      final withdrawn = store.cards(includeInactive: true).single;
      expect(withdrawn['eligible'], isFalse);
      expect(withdrawn['status'], 'withdrawn');
      expect(withdrawn['keywords'], isEmpty);
      expect(withdrawn['evidence'], isEmpty);
      expect(anchors(topic), ['复诊']);
      final current = remember('new', '我周六复诊。', ['复诊']);
      expect(current['topic_id'], topic);
      expect(current['topic_mode'], mode);
      expect((current['evidence'] as List<Object?>).cast<MemoryRow>().map((proof) => proof['message_id']), ['new']);
      expect(current.containsKey('control_anchors'), isFalse);
    });
  }

  test('reaffirming and switching less or never retains proved anchors until explicit normal', () {
    final old = remember('old', '我周五复诊。', ['复诊']);
    final topic = old['topic_id'] as String;
    say('control', '别主动提复诊');
    store.applyControl(topicIds: [topic], kind: 'never', controlMessageId: 'control');
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周六复诊。');
    expect(store.cards(), isEmpty);
    final revision = store.archive['control_revision'];
    store.applyControl(topicIds: [topic], kind: 'never', controlMessageId: 'control');
    expect(store.archive['control_revision'], revision);
    expect(anchors(topic), ['复诊']);
    var commandNumber = 0;
    for (final text in ['别主动提复诊', '少提复诊', '少提复诊', '别主动提复诊']) {
      final source = say('repeat-${commandNumber++}', text);
      final control = parseMemoryControl(text, store.cards(), topicControls: store.topicControls())!;
      expect(control['ambiguous'], isFalse);
      expect(control['topic_ids'], [topic]);
      store.applyControl(
        topicIds: (control['topic_ids'] as List<Object?>).cast<String>(),
        kind: control['kind'] as String,
        controlMessageId: source['id'] as String,
      );
      reopen();
      expect(anchors(topic), ['复诊'], reason: text);
    }
    const release = '以后可以聊复诊';
    final source = say('release', release);
    final control = parseMemoryControl(release, store.cards(), topicControls: store.topicControls())!;
    expect(control['ambiguous'], isFalse);
    expect(control['kind'], 'normal');
    expect(control['topic_ids'], [topic]);
    expect(
      () => store.finishUnresolvedControl(messageId: 'release', expectedSourceRev: 1),
      throwsA(isA<DshRemoteException>()),
    );
    store.applyControl(
      topicIds: (control['topic_ids'] as List<Object?>).cast<String>(),
      kind: control['kind'] as String,
      controlMessageId: source['id'] as String,
    );
    expect(anchors(topic), isEmpty);
    reopen();
    final fresh = remember('fresh', '我周日复诊。', ['复诊']);
    expect(fresh['topic_id'], isNot(topic));
    expect(fresh['topic_mode'], 'normal');
  });

  test('control-only anchors do not make a forgotten fact or cancelled plan target', () {
    final old = remember('old', '我周五复诊。', ['复诊']);
    store.applyControl(topicIds: [old['topic_id'] as String], kind: 'never');
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周六复诊。');
    final controls = store.topicControls();
    expect(controls.single.keys, unorderedEquals(['topic_id', 'mode', 'anchors']));
    expect(store.cards(), isEmpty);
    for (final text in ['忘掉复诊', '复诊取消了', '复诊改期了，时间还没定']) {
      final parsed = parseMemoryControl(text, store.cards(), topicControls: controls)!;
      expect(parsed['ambiguous'], isTrue, reason: text);
      expect(parsed['topic_ids'], isEmpty);
      expect(parsed['target_card_ids'], isEmpty);
    }
  });

  test('two saved control topics with the same literal anchor remain ambiguous', () {
    final a = remember('a', '我周五复诊。', ['复诊']);
    final b = remember('b', '我周六复诊。', ['复诊']);
    expect(a['topic_id'], isNot(b['topic_id']));
    store.applyControl(topicIds: [a['topic_id'] as String, b['topic_id'] as String], kind: 'never');
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我周日复诊。');
    store.editMessage(id: 'b', expectedSourceRev: 1, text: '我周一复诊。');
    expect(store.cards(), isEmpty);
    final parsed = parseMemoryControl('以后可以聊复诊', store.cards(), topicControls: store.topicControls())!;
    expect(parsed['ambiguous'], isTrue);
    expect(parsed['topic_ids'], isEmpty);
  });

  test('a generated card cannot widen the saved control vocabulary to an independent fact', () {
    final old = remember('old', '我周五复诊。', ['复诊']);
    final topic = old['topic_id'] as String;
    store.applyControl(topicIds: [topic], kind: 'never');
    final combined = remember('combined', '我复诊后去公园。', ['复诊', '公园']);
    expect(combined['topic_id'], topic);
    expect(anchors(topic), ['复诊']);
    final park = remember('park', '我周日去公园。', ['公园']);
    expect(park['topic_mode'], 'normal');
    expect(park['topic_id'], isNot(topic));
  });

  for (final deleteChat in [false, true]) {
    test('forget deletes the final controlled topic and its anchors (raw=$deleteChat)', () {
      final clinic = remember('clinic', '我周五复诊。', ['复诊']);
      final coffee = remember('coffee', '我喝咖啡选无糖。', ['咖啡']);
      final topic = clinic['topic_id'] as String;
      store.applyControl(topicIds: [topic], kind: 'never');
      store.applyControl(topicIds: [topic], kind: 'forget', deleteChat: deleteChat);
      expect(database.select('SELECT * FROM memory_topics WHERE id=?', [topic]), isEmpty);
      expect(store.cards().map((card) => card['id']), [coffee['id']]);
      expect(store.messages().any((source) => source['id'] == 'clinic'), !deleteChat);
      expect(store.messages().any((source) => source['id'] == 'coffee'), isTrue);
      reopen();
      final fresh = remember('fresh', '我周六复诊。', ['复诊']);
      expect(fresh['topic_mode'], 'normal');
      expect(fresh['topic_id'], isNot(topic));
      expect(database.select("SELECT id FROM memory_topics WHERE control_anchors!='[]'"), isEmpty);
    });
  }

  test('deleting the original proved source also deletes its final controlled topic', () {
    final clinic = remember('clinic', '我周五复诊。', ['复诊']);
    final topic = clinic['topic_id'] as String;
    store.applyControl(topicIds: [topic], kind: 'never');
    store.deleteMessage(id: 'clinic', expectedSourceRev: 1);
    expect(store.cards(includeInactive: true), isEmpty);
    expect(database.select('SELECT * FROM memory_topics WHERE id=?', [topic]), isEmpty);
  });

  test('a real v8 upgrade recovers only the still-proved vocabulary of existing controls', () {
    final old = remember('old', '我周五复诊。', ['复诊']);
    final topic = old['topic_id'] as String;
    store.applyControl(topicIds: [topic], kind: 'never');
    final before = store.cards();
    restoreOldMemorySchema(database, 8);
    expect(
      database.select('PRAGMA table_info(memory_topics)').map((row) => row['name']),
      isNot(contains('control_anchors')),
    );
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 15);
    expect(store.cards(), [
      for (final card in before) {...card, 'cleanup_history_complete': 0},
    ]);
    expect(anchors(topic), ['复诊']);
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周六复诊。');
    final fresh = remember('fresh', '我周日复诊。', ['复诊']);
    expect(fresh['topic_id'], topic);
    expect(fresh['topic_mode'], 'never');
  });

  test('a damaged v8 control does not invent lost anchors from withdrawn fact text', () {
    final old = remember('old', '我周五复诊。', ['复诊']);
    final topic = old['topic_id'] as String;
    store.applyControl(topicIds: [topic], kind: 'never');
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周六复诊。');
    restoreOldMemorySchema(database, 8); // Real old schema has already lost the sole keyword.
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 15);
    expect(database.select('SELECT mode FROM memory_topics WHERE id=?', [topic]).single['mode'], 'never');
    expect(anchors(topic), isEmpty);
    expect(store.cards(), isEmpty);
    expect(store.cards(includeInactive: true).single['keywords'], isEmpty);
    // This is a disclosed non-recoverable legacy state, not a promise that
    // unknown associations or already-created normal cards were repaired.
  });

  test('merging two less topics preserves both explicit control vocabularies', () {
    final a = remember('a', '酸奶我只买原味。', ['酸奶']);
    final b = remember('b', '我买原味酸奶。', ['酸奶', '原味']);
    store.applyControl(topicIds: [a['topic_id'] as String], kind: 'less');
    store.applyControl(topicIds: [b['topic_id'] as String], kind: 'less');
    final batch = store.nextMergeBatch(estimateTokens: fixture.estimate)!;
    final target = batch.rows.singleWhere((row) => row['id'] == a['id']);
    final from = batch.rows.singleWhere((row) => row['id'] == b['id']);
    final proposal = parseMergeProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'completion': 'complete',
        'operations': [
          {
            'op': 'merge',
            'target_id': target['id'],
            'expected_row_rev': target['row_rev'],
            'text': target['text'],
            'from': [
              {'id': from['id'], 'expected_row_rev': from['row_rev']},
            ],
            'evidence': [
              for (final row in batch.rows)
                for (final proof in (row['evidence'] as List<Object?>).cast<MemoryRow>())
                  {'message_id': proof['message_id'], 'quote': proof['quote']},
            ],
          },
        ],
      }),
      batch,
    );
    expect(store.commitMerge(batch, proposal), isTrue);
    expect(anchors(target['topic_id'] as String), unorderedEquals(['原味', '酸奶']));
    expect(database.select('SELECT * FROM memory_topics WHERE id=?', [from['topic_id']]), isEmpty);
  });
}
