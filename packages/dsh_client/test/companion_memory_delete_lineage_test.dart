import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'companion_memory_flow_test.dart' as fixture;
import 'companion_memory_store_test.dart' as legacy;
import 'support/old_memory_schema.dart';

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  final now = DateTime.utc(2026, 11, 21, 2).millisecondsSinceEpoch;

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

  void extract(List<MemoryRow> operations) {
    final batch = store.nextBatch(forceTail: true, estimateTokens: fixture.estimate)!;
    expect(store.commitExtraction(batch, fixture.parsed(batch, operations)), isTrue);
  }

  List<String> origins(String id) => [
    for (final row in database.select(
      'SELECT message_id FROM memory_card_cleanup_sources WHERE card_id=? ORDER BY message_id',
      [id],
    ))
      row['message_id'] as String,
  ];

  int withdrawn(String cardId, String messageId) =>
      database.select('SELECT proof_withdrawn FROM memory_card_cleanup_sources WHERE card_id=? AND message_id=?', [
            cardId,
            messageId,
          ]).single['proof_withdrawn']
          as int;

  MemoryRow remember(String id, String text, {List<String> words = const ['咖啡']}) {
    final source = say(id, text);
    extract([fixture.create(source, keywords: words)]);
    return store.cards().singleWhere(
      (card) => (card['evidence'] as List<Object?>).cast<MemoryRow>().any((proof) => proof['message_id'] == id),
    );
  }

  MemoryRow merge(MemoryRow target, MemoryRow from) {
    final batch = store.nextMergeBatch(estimateTokens: fixture.estimate)!;
    final a = batch.rows.singleWhere((row) => row['id'] == target['id']);
    final b = batch.rows.singleWhere((row) => row['id'] == from['id']);
    final proposal = parseMergeProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'completion': 'complete',
        'operations': [
          {
            'op': 'merge',
            'target_id': a['id'],
            'expected_row_rev': a['row_rev'],
            'text': a['text'],
            'from': [
              {'id': b['id'], 'expected_row_rev': b['row_rev']},
            ],
            'evidence': [
              for (final row in [a, b])
                for (final proof in (row['evidence'] as List<Object?>).cast<MemoryRow>())
                  {'message_id': proof['message_id'], 'quote': proof['quote']},
            ],
          },
        ],
      }),
      batch,
    );
    expect(store.commitMerge(batch, proposal), isTrue);
    return store.cards().singleWhere((row) => row['id'] == a['id']);
  }

  void forget(String id, String text) {
    final source = say(id, text);
    final control = parseMemoryControl(text, store.cards(includeInactive: true), topicControls: store.topicControls())!;
    expect(control['ambiguous'], isFalse);
    store.applyControl(
      topicIds: (control['topic_ids'] as List<Object?>).cast<String>(),
      kind: 'forget',
      controlMessageId: source['id'] as String,
      deleteChat: control['delete_chat'] == true,
    );
  }

  ({MemoryRow derived, MemoryRow root, MemoryRow edited}) copiedRoot({bool legacyHistory = false}) {
    const x = '我咖啡只喝无糖。';
    const y = '我喝咖啡不放糖。';
    final a = say('a', x);
    extract([
      fixture.create(a, text: y, keywords: ['咖啡']),
    ]);
    final first = store.cards().single;
    if (legacyHistory) {
      restoreOldMemorySchema(database, 9);
      reopen();
    }
    final m = say('m', x);
    extract([
      fixture.create(m, text: y, keywords: ['咖啡']),
      fixture.create(m, text: x, keywords: ['咖啡']),
    ]);
    final second = store.cards().singleWhere((row) => row['text'] == y && row['id'] != first['id']);
    final root = store.cards().singleWhere((row) => row['text'] == x);
    final combined = merge(first, second);
    final edited = store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡只喝无糖。今天阳光很好。');
    final derived = store.cards().singleWhere((row) => row['id'] == combined['id']);
    expect((derived['evidence'] as List<Object?>).cast<MemoryRow>().map((row) => row['message_id']), ['m']);
    return (derived: derived, root: root, edited: edited);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-delete-lineage-');
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'deleting an edited original removes its withdrawn facts and final control while preserving independent coffee',
    () {
      final mixed = say('mixed', '我周五复诊，周六去公园。');
      final coffeeSource = say('coffee', '我喝咖啡只选无糖。');
      extract([
        fixture.create(mixed, text: '你周五复诊。', quote: '我周五复诊', keywords: ['复诊']),
        fixture.create(mixed, text: '你周六去公园。', quote: '周六去公园', keywords: ['公园']),
        fixture.create(coffeeSource, keywords: ['咖啡']),
      ]);
      final clinic = store.cards().singleWhere((row) => row['text'] == '你周五复诊。');
      final coffee = store.cards().singleWhere((row) => row['text'] == coffeeSource['text']);
      final command = say('control', '别主动提复诊');
      final control = parseMemoryControl(
        command['text'] as String,
        store.cards(),
        topicControls: store.topicControls(),
      )!;
      expect(control['ambiguous'], isFalse);
      store.applyControl(
        topicIds: (control['topic_ids'] as List<Object?>).cast<String>(),
        kind: control['kind'] as String,
        controlMessageId: 'control',
      );
      store.editMessage(id: 'mixed', expectedSourceRev: 1, text: '我周五复诊，周日去公园。');
      expect(store.cards().map((row) => row['id']), [coffee['id']]);
      expect(store.cards(includeInactive: true), hasLength(3));
      reopen();
      store.deleteMessage(id: 'mixed', expectedSourceRev: 2);
      reopen();
      // This is the existing v9 failure: current proof rows no longer identify
      // the two withdrawn cards after editing, but raw deletion must clean them.
      expect(store.cards(includeInactive: true).map((row) => row['id']), [coffee['id']]);
      expect(database.select('SELECT id FROM memory_topics WHERE id=?', [clinic['topic_id']]), isEmpty);
      expect(store.topicControls(), isEmpty);
      expect(store.messages().any((row) => row['id'] == 'mixed'), isFalse);
      final fresh = say('fresh', '我周六复诊。');
      extract([
        fixture.create(fresh, keywords: ['复诊']),
      ]);
      final current = store.cards().singleWhere((row) => row['text'] == fresh['text']);
      expect(current['topic_mode'], 'normal');
      expect(current['topic_id'], isNot(clinic['topic_id']));
      final selected = selectMemoryContext(
        store.cards(),
        input: '复诊和咖啡',
        nowMs: now,
        controlRevision: store.archive['control_revision'] as int,
      );
      expect(selected.ids, unorderedEquals([coffee['id'], current['id']]));
      expect(selected.block, isNot(contains('周五')));
      expect(selected.block, isNot(contains('公园')));
    },
  );

  test('an edited member withdraws its whole AND proof and deleting the other original cleans the card', () {
    final day = say('day', '我周五复诊。');
    final place = say('place', '复诊在东门。');
    extract([
      {
        ...fixture.create(day, text: '你周五在东门复诊。', keywords: ['复诊']),
        'evidence': [
          {'message_id': day['id'], 'quote': day['text']},
          {'message_id': place['id'], 'quote': place['text']},
        ],
      },
    ]);
    final id = store.cards().single['id'] as String;
    store.editMessage(id: 'day', expectedSourceRev: 1, text: '我周六复诊。');
    expect(store.cards(), isEmpty);
    expect(origins(id), ['day', 'place']);
    reopen();
    store.deleteMessage(id: 'place', expectedSourceRev: 1);
    expect(store.cards(includeInactive: true), isEmpty);
    expect(store.messages().single['id'], 'day');
  });

  test('deleting a historical source keeps a complete independent OR proof', () {
    final a = remember('a', '我咖啡只喝无糖。');
    final b = remember('b', '我喝咖啡只选无糖。');
    final kept = merge(a, b);
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我今天不喝咖啡。');
    reopen();
    store.deleteMessage(id: 'a', expectedSourceRev: 2);
    final card = store.cards().single;
    expect(card['id'], kept['id']);
    expect(card['eligible'], isTrue);
    expect((card['evidence'] as List<Object?>).cast<MemoryRow>().map((row) => row['message_id']), ['b']);
    expect(origins(card['id'] as String), ['b']);
  });

  test('merge transfers the removed card cleanup identity before its cascade', () {
    final a = remember('a', '我咖啡只喝无糖。');
    final b = remember('b', '我喝咖啡只选无糖。');
    final kept = merge(a, b);
    expect(origins(kept['id'] as String), ['a', 'b']);
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我今天不喝咖啡。');
    store.editMessage(id: 'b', expectedSourceRev: 1, text: '我今天也不喝咖啡。');
    reopen();
    store.deleteMessage(id: 'b', expectedSourceRev: 2);
    expect(store.cards(includeInactive: true), isEmpty);
    expect(database.select('SELECT * FROM memory_card_cleanup_sources'), isEmpty);
  });

  test('replace and a separately sourced past sentence keep only their own new source identities', () {
    final old = remember('old', '我咖啡喝半糖。');
    final current = say('current', '以前喝半糖，现在咖啡改喝无糖了。');
    extract([
      {
        ...fixture.create(current, text: '你现在咖啡喝无糖。', keywords: ['咖啡']),
        'op': 'replace',
        'target_id': old['id'],
        'expected_row_rev': old['row_rev'],
        'change_kind': 'new_current_value',
      },
      fixture.create(current, text: '你以前咖啡喝半糖。', keywords: ['咖啡']),
    ]);
    expect(store.cards(), hasLength(2));
    for (final card in store.cards()) {
      expect(origins(card['id'] as String), ['current']);
    }
    store.editMessage(id: 'current', expectedSourceRev: 1, text: '咖啡我一直喝无糖。');
    store.deleteMessage(id: 'old', expectedSourceRev: 1);
    expect(store.cards(includeInactive: true), hasLength(2));
    store.deleteMessage(id: 'current', expectedSourceRev: 2);
    expect(store.cards(includeInactive: true), isEmpty);
  });

  test('an explicit correction replaces its cleanup source as well as its factual proof', () {
    final old = remember('old', '我咖啡喝半糖。');
    say('correction', '咖啡改成我咖啡喝无糖。');
    store.correctFromMessage(
      cardId: old['id'] as String,
      expectedRowRev: old['row_rev'] as int,
      messageId: 'correction',
      expectedSourceRev: 1,
      text: '我咖啡喝无糖。',
    );
    expect(origins(old['id'] as String), ['correction']);
    store.deleteMessage(id: 'old', expectedSourceRev: 1);
    expect(store.cards().single['text'], '我咖啡喝无糖。');
    store.editMessage(id: 'correction', expectedSourceRev: 1, text: '咖啡改成我咖啡喝半糖。');
    store.deleteMessage(id: 'correction', expectedSourceRev: 2);
    expect(store.cards(includeInactive: true), isEmpty);
  });

  test('manual current wording is independent of the former automatic source', () {
    final old = remember('old', '我咖啡喝半糖。');
    store.saveManual(
      CompanionMemory(id: old['id'] as String, text: '我现在喝绿茶。', keywords: ['绿茶']),
      expectedRowRev: old['row_rev'] as int,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(origins(old['id'] as String), isEmpty);
    store.deleteMessage(id: 'old', expectedSourceRev: 1);
    expect(store.cards().single['text'], '我现在喝绿茶。');
    expect(store.cards().single['manual'], isTrue);
  });

  for (final deleteChat in [false, true]) {
    test('exact withdrawn forget deletes one fact and only deletes its original when requested (raw=$deleteChat)', () {
      final mixed = say('mixed', '我周五复诊，周六去公园。');
      final coffee = say('coffee', '我喝咖啡选无糖。');
      extract([
        fixture.create(mixed, text: '你周五复诊。', quote: '我周五复诊', keywords: ['复诊']),
        fixture.create(mixed, text: '你周六去公园。', quote: '周六去公园', keywords: ['公园']),
        fixture.create(coffee, keywords: ['咖啡']),
      ]);
      final clinic = store.cards().singleWhere((row) => row['text'] == '你周五复诊。');
      store.applyControl(topicIds: [clinic['topic_id'] as String], kind: 'never');
      store.editMessage(id: 'mixed', expectedSourceRev: 1, text: '我周五复诊，周日去公园。');
      reopen();
      forget('forget', '忘掉你周五复诊，${deleteChat ? '连原话也删' : '聊天留着'}');
      expect(store.cards(includeInactive: true).any((row) => row['id'] == clinic['id']), isFalse);
      expect(store.cards().single['text'], coffee['text']);
      expect(store.cards(includeInactive: true).any((row) => row['text'] == '你周六去公园。'), !deleteChat);
      expect(store.messages().any((row) => row['id'] == 'mixed'), !deleteChat);
      expect(store.topicControls(), isEmpty);
    });
  }

  test('raw forget plans its root before an earlier sorted withdrawn derivative', () {
    store.close();
    database = sqlite3.open('${directory.path}/memory.sqlite');
    var nextId = 0;
    store = CompanionMemoryStore(
      database,
      nowMilliseconds: () => now,
      createId: () => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}',
    );
    final mixed = say('mixed', '我周五复诊，周六去公园。');
    extract([
      fixture.create(mixed, text: '你周五复诊。你周六去公园。', keywords: ['复诊', '公园']),
      fixture.create(mixed, text: '你周五复诊。', quote: '我周五复诊', keywords: ['复诊']),
    ]);
    final derivative = store.cards().singleWhere((row) => row['text'] == '你周五复诊。你周六去公园。');
    final root = store.cards().singleWhere((row) => row['text'] == '你周五复诊。');
    expect((derivative['id'] as String).compareTo(root['id'] as String), lessThan(0));
    store.editMessage(id: 'mixed', expectedSourceRev: 1, text: '我周五复诊，周日去公园。');
    reopen();
    expect(store.cards(), isEmpty);
    expect(origins(root['id'] as String), ['mixed']);
    expect(withdrawn(derivative['id'] as String, 'mixed'), 1);
    forget('forget', '忘掉你周五复诊，连原话也删');
    expect(store.cards(includeInactive: true), isEmpty);
    expect(store.messages().any((row) => row['id'] == 'mixed'), isFalse);
    expect(store.messages().singleWhere((row) => row['id'] == 'forget')['extraction_state'], 'done');
  });

  test('an active and withdrawn fact with the same full sentence are two ambiguous forget targets', () {
    remember('a', '我周五复诊。', words: ['复诊']);
    remember('b', '我周五复诊。', words: ['复诊']);
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我周六复诊。');
    final parsed = parseMemoryControl(
      '忘掉我周五复诊。',
      store.cards(includeInactive: true),
      topicControls: store.topicControls(),
    )!;
    expect(parsed['ambiguous'], isTrue);
    expect(parsed['target_card_ids'], isEmpty);
  });

  test('withdrawn cleanup wording does not become a cancellation correction or topic-word forget target', () {
    remember('old', '我周五复诊。', words: ['复诊']);
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周六复诊。');
    for (final text in ['忘掉复诊', '我周五复诊取消了', '我周五复诊改成我周日复诊']) {
      final parsed = parseMemoryControl(
        text,
        store.cards(includeInactive: true),
        topicControls: store.topicControls(),
      )!;
      expect(parsed['ambiguous'], isTrue, reason: text);
    }
  });

  test('real v9 migration backfills current identities before a later edit and raw deletion', () {
    final old = remember('old', '我咖啡喝无糖。');
    restoreOldMemorySchema(database, 9);
    expect(database.select("SELECT name FROM sqlite_master WHERE name='memory_card_cleanup_sources'"), isEmpty);
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 13);
    expect(origins(old['id'] as String), ['old']);
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我今天不喝咖啡。');
    store.deleteMessage(id: 'old', expectedSourceRev: 2);
    expect(store.cards(includeInactive: true), isEmpty);
  });

  test('lost v9 original identity cannot be invented or reported as a successful raw deletion', () {
    final old = remember('old', '我周五复诊。', words: ['复诊']);
    store.editMessage(id: 'old', expectedSourceRev: 1, text: '我周六复诊。');
    restoreOldMemorySchema(database, 9);
    reopen();
    expect(origins(old['id'] as String), isEmpty);
    expect(
      () => forget('raw-forget', '忘掉我周五复诊，连原话也删'),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
    );
    expect(store.cards(includeInactive: true), hasLength(1));
    expect(store.messages().any((row) => row['id'] == 'old'), isTrue);
    forget('fact-forget', '忘掉我周五复诊，聊天留着');
    expect(store.cards(includeInactive: true), isEmpty);
    expect(store.messages().any((row) => row['id'] == 'old'), isTrue);
  });

  test('v9 partial OR history backfill does not invent its previously removed source edge', () {
    final a = remember('a', '我咖啡只喝无糖。');
    final b = remember('b', '我喝咖啡只选无糖。');
    final kept = merge(a, b);
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我今天不喝咖啡。');
    expect(origins(kept['id'] as String), ['a', 'b']);
    restoreOldMemorySchema(database, 9);
    reopen();
    expect(origins(kept['id'] as String), ['b']);
    expect(store.cards().single['eligible'], isTrue);
    expect(store.cards().single['cleanup_history_complete'], 0);
    // A nonempty backfill is not proof that every historical origin survived.
  });

  test('partial legacy OR loss rejects natural raw forget without deleting cards sources or recording success', () {
    final a = remember('a', '我咖啡只喝无糖。');
    final b = remember('b', '我喝咖啡只选无糖。');
    final kept = merge(a, b);
    // v9 could lose A's identity while A still contained the original fact.
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡只喝无糖。今天阳光很好。');
    restoreOldMemorySchema(database, 9);
    reopen();
    expect(origins(kept['id'] as String), ['b']);
    final command = say('raw-forget', '忘掉我咖啡只喝无糖，连原话也删');
    final parsed = parseMemoryControl(
      command['text'] as String,
      store.cards(includeInactive: true),
      topicControls: store.topicControls(),
    )!;
    expect(parsed['ambiguous'], isFalse);
    final beforeCards = jsonEncode(store.cards(includeInactive: true));
    final beforeSources = jsonEncode(store.messages());
    final beforeArchive = jsonEncode(store.archive);
    expect(
      () => store.applyControl(
        topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
        kind: 'forget',
        controlMessageId: 'raw-forget',
        deleteChat: true,
      ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
    );
    expect(jsonEncode(store.cards(includeInactive: true)), beforeCards);
    expect(jsonEncode(store.messages()), beforeSources);
    expect(jsonEncode(store.archive), beforeArchive);
    expect(store.messages().singleWhere((row) => row['id'] == 'raw-forget')['extraction_state'], 'pending');
    expect(store.requests(), isEmpty);
    forget('fact-forget', '忘掉我咖啡只喝无糖，聊天留着');
    expect(store.cards(includeInactive: true), isEmpty);
    expect(store.messages().where((row) => const ['a', 'b'].contains(row['id'])), hasLength(2));
  });

  test('merge preserves incomplete history and pinning cannot certify it', () {
    final a = remember('a', '我咖啡只喝无糖。');
    restoreOldMemorySchema(database, 9);
    reopen();
    expect(store.cards().single['cleanup_history_complete'], 0);
    final b = remember('b', '我喝咖啡只选无糖。');
    expect(b['cleanup_history_complete'], 1);
    final kept = merge(a, b);
    expect(kept['cleanup_history_complete'], 0);
    store.saveManual(
      CompanionMemory(id: kept['id'] as String, text: kept['text'] as String, keywords: ['咖啡'], pinned: true),
      expectedRowRev: kept['row_rev'] as int,
      currentValueChange: false,
      realityKnown: true,
    );
    expect(store.cards().single['cleanup_history_complete'], 0);
  });

  for (final method in ['replace', 'correct', 'manual']) {
    test('a $method with its own new basis can replace incomplete legacy history', () {
      final old = remember('old', '我咖啡喝半糖。');
      restoreOldMemorySchema(database, 9);
      reopen();
      expect(store.cards().single['cleanup_history_complete'], 0);
      if (method == 'manual') {
        store.saveManual(
          CompanionMemory(id: old['id'] as String, text: '我咖啡喝无糖。', keywords: ['咖啡']),
          expectedRowRev: old['row_rev'] as int,
          currentValueChange: true,
          realityKnown: true,
        );
        expect(origins(old['id'] as String), isEmpty);
      } else {
        final source = say('current', '咖啡改成我咖啡喝无糖。');
        if (method == 'correct') {
          store.correctFromMessage(
            cardId: old['id'] as String,
            expectedRowRev: old['row_rev'] as int,
            messageId: 'current',
            expectedSourceRev: 1,
            text: '我咖啡喝无糖。',
          );
        } else {
          extract([
            {
              ...fixture.create(source, text: '我咖啡喝无糖。', keywords: ['咖啡']),
              'op': 'replace',
              'target_id': old['id'],
              'expected_row_rev': old['row_rev'],
            },
          ]);
        }
        expect(origins(old['id'] as String), ['current']);
      }
      expect(store.cards().single['cleanup_history_complete'], 1);
      forget('forget', '忘掉我咖啡喝无糖，连原话也删');
      expect(store.cards(includeInactive: true), isEmpty);
      expect(
        store.messages().any((row) => row['id'] == 'old'),
        isTrue,
        reason: 'the new wording does not claim the previous wording as its source',
      );
    });
  }

  for (final method in ['replace', 'correct']) {
    for (final legacyHistory in [false, true]) {
      test('same-body $method preserves cleanup history when legacy uncertainty is $legacyHistory', () {
        final a = remember('a', '我咖啡喝无糖。');
        final b = remember('b', '我喝咖啡只选无糖。');
        final kept = merge(a, b);
        store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡喝无糖。今天阳光很好。');
        if (legacyHistory) {
          restoreOldMemorySchema(database, 9);
          reopen();
        }
        final target = store.cards().single;
        final current = say('current', '咖啡改成我咖啡喝无糖。');
        if (method == 'correct') {
          store.correctFromMessage(
            cardId: target['id'] as String,
            expectedRowRev: target['row_rev'] as int,
            messageId: 'current',
            expectedSourceRev: 1,
            text: target['text'] as String,
          );
        } else {
          extract([
            {
              ...fixture.create(current, text: target['text'] as String, keywords: ['咖啡']),
              'op': 'replace',
              'target_id': target['id'],
              'expected_row_rev': target['row_rev'],
            },
          ]);
        }
        final actual = store.cards().single;
        expect(actual['id'], kept['id']);
        expect(actual['cleanup_history_complete'], legacyHistory ? 0 : 1);
        expect(origins(actual['id'] as String), legacyHistory ? ['b', 'current'] : ['a', 'b', 'current']);
        expect(withdrawn(actual['id'] as String, 'b'), 1);
        expect(withdrawn(actual['id'] as String, 'current'), 0);
        if (!legacyHistory) {
          expect(withdrawn(actual['id'] as String, 'a'), 1);
        } else {
          expect(
            () => forget('forget', '忘掉我咖啡喝无糖，连原话也删'),
            throwsA(
              isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown'),
            ),
          );
          expect(store.cards().single['id'], kept['id']);
          expect(store.messages().any((row) => row['id'] == 'a'), isTrue);
        }
      });
    }
  }

  test('a manual label cannot bypass an incomplete source history', () {
    remember('old', '我咖啡喝无糖。');
    // An old row labelled manual but still carrying automatic proof is not a
    // known independent manual value. The migration must keep it uncertain.
    database.execute('UPDATE memory_cards SET manual=1');
    restoreOldMemorySchema(database, 9);
    reopen();
    expect(store.cards().single['cleanup_history_complete'], 0);
    expect(
      () => forget('forget', '忘掉我咖啡喝无糖，连原话也删'),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
    );
    expect(store.cards(), hasLength(1));
    expect(store.messages().any((row) => row['id'] == 'old'), isTrue);
  });

  test('legacy imported manual values without phone sources have complete local cleanup history', () {
    store.importLegacy(
      CompanionMigrationSnapshot.fromJson(legacy.legacy(rows: [legacy.legacyCard(text: '我咖啡喝无糖。')])),
      realityKnownIds: {legacy.oldCard},
    );
    final id = store.cards().single['id'] as String;
    expect(store.cards().single['cleanup_history_complete'], 1);
    restoreOldMemorySchema(database, 9);
    reopen();
    expect(store.cards().single['cleanup_history_complete'], 1);
    expect(origins(id), isEmpty);
    forget('forget', '忘掉我咖啡喝无糖，连原话也删');
    expect(store.cards(includeInactive: true), isEmpty);
    expect(
      database.select('SELECT result FROM memory_migrations WHERE local_card_id=?', [id]).single['result'],
      'forgotten',
    );
  });

  for (final legacyHistory in [false, true]) {
    test('raw forget checks a copied-proof card that will lose its last group (legacy=$legacyHistory)', () {
      final pair = copiedRoot(legacyHistory: legacyHistory);
      expect(pair.derived['text'], '我喝咖啡不放糖。');
      expect(pair.derived['cleanup_history_complete'], legacyHistory ? 0 : 1);
      expect(pair.root['cleanup_history_complete'], 1);
      expect(withdrawn(pair.derived['id'] as String, 'a'), 1);
      final command = say('forget', '忘掉我咖啡只喝无糖，连原话也删');
      final parsed = parseMemoryControl(
        command['text'] as String,
        store.cards(includeInactive: true),
        topicControls: store.topicControls(),
      )!;
      expect(parsed['target_card_ids'], [pair.root['id']]);
      final beforeCards = jsonEncode(store.cards(includeInactive: true));
      final beforeSources = jsonEncode(store.messages());
      final beforeArchive = jsonEncode(store.archive);
      final beforeCleanup = [
        for (final row in database.select('SELECT * FROM memory_card_cleanup_sources ORDER BY card_id,message_id'))
          Map<String, Object?>.from(row),
      ];
      void apply() => store.applyControl(
        topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
        kind: 'forget',
        controlMessageId: 'forget',
        deleteChat: true,
      );
      if (legacyHistory) {
        expect(
          apply,
          throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
        );
        expect(jsonEncode(store.cards(includeInactive: true)), beforeCards);
        expect(jsonEncode(store.messages()), beforeSources);
        expect(jsonEncode(store.archive), beforeArchive);
        expect([
          for (final row in database.select('SELECT * FROM memory_card_cleanup_sources ORDER BY card_id,message_id'))
            Map<String, Object?>.from(row),
        ], beforeCleanup);
        expect(store.messages().singleWhere((row) => row['id'] == 'forget')['extraction_state'], 'pending');
      } else {
        apply();
        reopen();
        expect(store.cards(includeInactive: true), isEmpty);
        expect(store.messages().any((row) => const ['a', 'm'].contains(row['id'])), isFalse);
        expect(store.messages().singleWhere((row) => row['id'] == 'forget')['extraction_state'], 'done');
      }
      expect(store.requests(), isEmpty);
    });

    test('a copied-proof card with independent G4 stays outside raw cleanup even with legacy=$legacyHistory', () {
      final pair = copiedRoot(legacyHistory: legacyHistory);
      final g4 = say('g4', '咖啡我不加糖。');
      extract([
        fixture.create(g4, text: '我喝咖啡不放糖。', keywords: ['咖啡']),
      ]);
      final extra = store.cards().singleWhere(
        (row) => (row['evidence'] as List<Object?>).cast<MemoryRow>().any((proof) => proof['message_id'] == 'g4'),
      );
      final kept = merge(pair.derived, extra);
      store.saveManual(
        CompanionMemory(id: legacy.oldCard, text: '我喝咖啡从不加糖。', keywords: ['咖啡']),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      forget('forget', '忘掉我咖啡只喝无糖，连原话也删');
      reopen();
      expect(store.cards().map((row) => row['id']), unorderedEquals([kept['id'], legacy.oldCard]));
      final actual = store.cards().singleWhere((row) => row['id'] == kept['id']);
      expect(actual['cleanup_history_complete'], legacyHistory ? 0 : 1);
      expect((actual['evidence'] as List<Object?>).cast<MemoryRow>().map((row) => row['message_id']), ['g4']);
      expect(store.cards().singleWhere((row) => row['id'] == legacy.oldCard)['manual'], isTrue);
      expect(store.messages().any((row) => row['id'] == 'm'), isFalse);
      expect(store.messages().singleWhere((row) => row['id'] == 'a')['text'], '我咖啡只喝无糖。今天阳光很好。');
      expect(store.messages().singleWhere((row) => row['id'] == 'g4')['text'], g4['text']);
    });
  }

  test('a newly selected raw source expands cleanup through a second nonliteral proof-dependent card', () {
    final pair = copiedRoot();
    const weather = '今天阳光很好。';
    final l = say('l', '我咖啡只喝无糖。今天阳光很好。');
    extract([
      fixture.create(pair.edited, text: weather, quote: weather, keywords: ['阳光']),
      fixture.create(l, text: weather, quote: weather, keywords: ['阳光']),
    ]);
    final rows = store.cards().where((row) => row['text'] == weather).toList();
    expect(rows, hasLength(2));
    final weatherCard = merge(rows.first, rows.last);
    store.editMessage(id: 'l', expectedSourceRev: 1, text: '我咖啡只喝无糖。今天阳光很好。我打开窗户。');
    final current = store.cards().singleWhere((row) => row['id'] == weatherCard['id']);
    expect((current['evidence'] as List<Object?>).cast<MemoryRow>().map((row) => row['message_id']), ['a']);
    expect(withdrawn(weatherCard['id'] as String, 'l'), 1);
    forget('forget', '忘掉我咖啡只喝无糖，连原话也删');
    reopen();
    expect(store.cards(includeInactive: true), isEmpty);
    expect(store.messages().any((row) => const ['a', 'm', 'l'].contains(row['id'])), isFalse);
    expect(database.select('SELECT * FROM memory_card_cleanup_sources'), isEmpty);
    expect(store.messages().singleWhere((row) => row['id'] == 'forget')['extraction_state'], 'done');
  });

  test('raw forget rejects incomplete legacy history anywhere in the literal deletion closure', () {
    remember('a', '我咖啡只喝无糖。晚饭六点吃。');
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡只喝无糖。晚饭六点吃。今天阳光很好。');
    restoreOldMemorySchema(database, 9);
    reopen();
    final root = remember('c', '我咖啡只喝无糖。');
    expect(root['cleanup_history_complete'], 1);
    final command = say('forget', '忘掉我咖啡只喝无糖，连原话也删');
    final parsed = parseMemoryControl(command['text'] as String, store.cards(includeInactive: true))!;
    expect(parsed['target_card_ids'], [root['id']]);
    final beforeCards = jsonEncode(store.cards(includeInactive: true));
    final beforeSources = jsonEncode(store.messages());
    expect(
      () => store.applyControl(
        topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
        kind: 'forget',
        controlMessageId: 'forget',
        deleteChat: true,
      ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
    );
    expect(jsonEncode(store.cards(includeInactive: true)), beforeCards);
    expect(jsonEncode(store.messages()), beforeSources);
  });

  test(
    'raw forget follows a new withdrawn composite identity when its current original still contains the root sentence',
    () {
      remember('a', '我咖啡只喝无糖。晚饭六点吃。');
      store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡只喝无糖。晚饭六点吃。今天阳光很好。');
      final independent = remember('y', '晚饭六点吃。', words: ['晚饭']);
      final root = remember('c', '我咖啡只喝无糖。');
      expect(store.cards(includeInactive: true).every((row) => row['cleanup_history_complete'] == 1), isTrue);
      final parsed = parseMemoryControl('忘掉我咖啡只喝无糖，连原话也删', store.cards(includeInactive: true))!;
      expect(parsed['target_card_ids'], [root['id']]);
      reopen();
      forget('forget', '忘掉我咖啡只喝无糖，连原话也删');
      expect(store.cards(includeInactive: true).map((row) => row['id']), [independent['id']]);
      expect(store.messages().any((row) => const ['a', 'c'].contains(row['id'])), isFalse);
      expect(store.messages().any((row) => row['id'] == 'y'), isTrue);
    },
  );

  test('unproved historical AND contribution refuses raw cleanup without deleting its independent source', () {
    final a = say('a', '我咖啡只喝无糖。');
    final y = say('y', '晚饭六点吃。');
    extract([
      {
        ...fixture.create(a, text: '我咖啡只喝无糖。晚饭六点吃。', keywords: ['咖啡']),
        'evidence': [
          {'message_id': a['id'], 'quote': a['text']},
          {'message_id': y['id'], 'quote': y['text']},
        ],
      },
      fixture.create(y, keywords: ['晚饭']),
    ]);
    store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡只喝无糖。今天阳光很好。');
    final root = remember('c', '我咖啡只喝无糖。');
    final command = say('forget', '忘掉我咖啡只喝无糖，连原话也删');
    final parsed = parseMemoryControl(command['text'] as String, store.cards(includeInactive: true))!;
    expect(parsed['target_card_ids'], [root['id']]);
    final beforeCards = jsonEncode(store.cards(includeInactive: true));
    final beforeSources = jsonEncode(store.messages());
    expect(
      () => store.applyControl(
        topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
        kind: 'forget',
        controlMessageId: 'forget',
        deleteChat: true,
      ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
    );
    expect(jsonEncode(store.cards(includeInactive: true)), beforeCards);
    expect(jsonEncode(store.messages()), beforeSources);
    expect(store.messages().singleWhere((row) => row['id'] == 'y')['text'], y['text']);
  });

  test('fresh complete AND cleanup preserves the independent Y message and card', () {
    final x = say('x', '我咖啡只喝无糖。');
    final y = say('y', '晚饭六点吃。');
    extract([
      {
        ...fixture.create(x, text: '我咖啡只喝无糖。晚饭六点吃。', keywords: ['咖啡']),
        'evidence': [
          {'message_id': x['id'], 'quote': x['text']},
          {'message_id': y['id'], 'quote': y['text']},
        ],
      },
      fixture.create(y, keywords: ['晚饭']),
    ]);
    final composite = store.cards().singleWhere((row) => (row['text'] as String).startsWith('我咖啡'));
    final independent = store.cards().singleWhere((row) => row['text'] == y['text']);
    expect(withdrawn(composite['id'] as String, 'x'), 0);
    expect(withdrawn(composite['id'] as String, 'y'), 0);
    remember('c', '我咖啡只喝无糖。');
    forget('forget', '忘掉我咖啡只喝无糖，连原话也删');
    expect(store.cards().single['id'], independent['id']);
    expect(store.messages().singleWhere((row) => row['id'] == 'y')['text'], y['text']);
    expect(store.messages().any((row) => const ['x', 'c'].contains(row['id'])), isFalse);
  });

  for (final punctuation in ['。', '！']) {
    test('a reused historical source with $punctuation keeps its lost role through a new AND proof and merge', () {
      final a = remember('a', '我咖啡只喝无糖。晚饭六点吃。');
      final d = remember('d', '我咖啡只喝无糖。晚饭固定六点。');
      final original = merge(a, d);
      final edited = store.editMessage(id: 'a', expectedSourceRev: 1, text: '我咖啡只喝无糖$punctuation晚饭六点吃。今天阳光很好。');
      expect(withdrawn(original['id'] as String, 'a'), 1);
      final m3 = say('m3', '我咖啡只喝无糖。');
      extract([
        {
          ...fixture.create(m3, text: '我咖啡只喝无糖。晚饭还是六点吃。', keywords: ['咖啡']),
          'evidence': [
            {'message_id': m3['id'], 'quote': m3['text']},
            {'message_id': edited['id'], 'quote': '晚饭六点吃。'},
          ],
        },
      ]);
      final composite = store.cards().singleWhere((row) => row['id'] != original['id']);
      expect(withdrawn(composite['id'] as String, 'a'), 0);
      final combined = merge(original, composite);
      expect(withdrawn(combined['id'] as String, 'a'), 1, reason: 'merge cannot erase the withdrawn role');
      final reused = (combined['evidence'] as List<Object?>).cast<MemoryRow>().singleWhere(
        (proof) => proof['message_id'] == 'a',
      );
      expect(reused['quote'], '晚饭六点吃。');
      expect(reused['source_rev'], 2);
      remember('c', '我咖啡只喝无糖。');
      reopen();
      if (punctuation == '。') {
        forget('forget', '忘掉我咖啡只喝无糖，连原话也删');
        expect(store.cards(includeInactive: true), isEmpty);
        expect(store.messages().any((row) => const ['a', 'd', 'm3', 'c'].contains(row['id'])), isFalse);
      } else {
        final command = say('forget', '忘掉我咖啡只喝无糖，连原话也删');
        final parsed = parseMemoryControl(command['text'] as String, store.cards(includeInactive: true))!;
        final beforeCards = jsonEncode(store.cards(includeInactive: true));
        final beforeSources = jsonEncode(store.messages());
        final beforeArchive = store.archive;
        expect(
          () => store.applyControl(
            topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
            kind: 'forget',
            controlMessageId: 'forget',
            deleteChat: true,
          ),
          throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
        );
        expect(jsonEncode(store.cards(includeInactive: true)), beforeCards);
        expect(jsonEncode(store.messages()), beforeSources);
        expect(store.archive, beforeArchive);
        expect(store.messages().singleWhere((row) => row['id'] == 'forget')['extraction_state'], 'pending');
      }
    });
  }

  test('editing another AND member marks an unchanged source even when it already has a separate Y role', () {
    final p = say('p', '我咖啡只喝无糖！晚饭六点吃。');
    final q = say('q', '我咖啡只喝无糖。晚饭六点吃。');
    final d = say('d', '我咖啡只喝无糖。晚饭固定六点。');
    final m3 = say('m3', '我咖啡只喝无糖。');
    extract([
      {
        ...fixture.create(p, text: '我咖啡只喝无糖。晚饭六点吃。', keywords: ['咖啡']),
        'evidence': [
          {'message_id': p['id'], 'quote': '我咖啡只喝无糖！'},
          {'message_id': q['id'], 'quote': '晚饭六点吃。'},
        ],
      },
      fixture.create(d, keywords: ['咖啡']),
      {
        ...fixture.create(m3, text: '我咖啡只喝无糖。晚饭还是六点吃。', keywords: ['咖啡']),
        'evidence': [
          {'message_id': m3['id'], 'quote': m3['text']},
          {'message_id': p['id'], 'quote': '晚饭六点吃。'},
        ],
      },
    ]);
    final original = store.cards().singleWhere((row) => row['text'] == '我咖啡只喝无糖。晚饭六点吃。');
    final independent = store.cards().singleWhere((row) => row['text'] == d['text']);
    final alternative = store.cards().singleWhere((row) => row['text'] == '我咖啡只喝无糖。晚饭还是六点吃。');
    final kept = merge(original, independent);
    store.editMessage(id: 'q', expectedSourceRev: 1, text: '我咖啡只喝无糖。晚饭六点吃。今天阳光很好。');
    expect(store.messages().singleWhere((row) => row['id'] == 'p')['source_rev'], 1);
    expect(withdrawn(kept['id'] as String, 'p'), 1);
    expect(withdrawn(kept['id'] as String, 'q'), 1);
    final combined = merge(kept, alternative);
    final reused = (combined['evidence'] as List<Object?>).cast<MemoryRow>().singleWhere(
      (proof) => proof['message_id'] == 'p',
    );
    expect(reused['source_rev'], 1);
    expect(reused['quote'], '晚饭六点吃。');
    expect(withdrawn(combined['id'] as String, 'p'), 1);
    remember('c', '我咖啡只喝无糖。');
    final command = say('forget', '忘掉我咖啡只喝无糖，连原话也删');
    final parsed = parseMemoryControl(command['text'] as String, store.cards(includeInactive: true))!;
    final beforeCards = jsonEncode(store.cards(includeInactive: true));
    final beforeSources = jsonEncode(store.messages());
    final beforeArchive = store.archive;
    expect(
      () => store.applyControl(
        topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
        kind: 'forget',
        controlMessageId: 'forget',
        deleteChat: true,
      ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
    );
    expect(jsonEncode(store.cards(includeInactive: true)), beforeCards);
    expect(jsonEncode(store.messages()), beforeSources);
    expect(store.archive, beforeArchive);
  });
}
