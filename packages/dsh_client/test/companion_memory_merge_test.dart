import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

int _estimate(String text) => (text.runes.length / 4).ceil();

MemoryRow _create(
  MemoryRow source,
  String text, {
  String kind = 'preference',
  List<String> keywords = const ['酸奶'],
  List<MemoryRow>? evidence,
}) => {
  'op': 'create',
  'kind': kind,
  'text': text,
  'keywords': keywords,
  'evidence':
      evidence ??
      <MemoryRow>[
        {'message_id': source['id'], 'quote': source['text']},
      ],
};

MemoryRow _proposal(MemoryMergeBatch batch, {String? target, String? from, Set<String>? citations}) =>
    parseMergeProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'completion': 'complete',
        'operations': target == null
            ? <Object?>[]
            : [
                {
                  'op': 'merge',
                  'target_id': target,
                  'expected_row_rev': batch.rows.singleWhere((row) => row['id'] == target)['row_rev'],
                  'from': [
                    {'id': from, 'expected_row_rev': batch.rows.singleWhere((row) => row['id'] == from)['row_rev']},
                  ],
                  'text': batch.rows.singleWhere((row) => row['id'] == target)['text'],
                  'evidence': [
                    for (final row in batch.rows.where((row) => row['id'] == target || row['id'] == from))
                      for (final proof in (row['evidence'] as List<Object?>).cast<MemoryRow>())
                        if (citations == null || citations.contains(proof['message_id']))
                          {'message_id': proof['message_id'], 'quote': proof['quote']},
                  ],
                },
              ],
      }),
      batch,
    );

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = DateTime.utc(2026, 11, 20, 2).millisecondsSinceEpoch;
  var nextId = 0;
  String createId() => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';
  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: createId);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow source(String id, String text, {int? saidAt, String scope = 'real', String role = 'user'}) =>
      store.submitMessage(
        id: id,
        sessionId: 'room',
        text: text,
        scope: scope,
        role: role,
        saidAtUtc: saidAt ?? now,
        offsetMinutes: 480,
      );
  void extract(List<MemoryRow> operations) {
    final batch = store.nextBatch(forceTail: true, estimateTokens: _estimate)!;
    final parsed = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'completion': 'complete',
        'covered_message_ids': [for (final row in batch.sources) row['id']],
        'operations': operations,
      }),
      batch,
    );
    expect(store.commitExtraction(batch, parsed), isTrue);
  }

  List<MemoryRow> pair() {
    final a = source('s11', '酸奶我只买原味。', saidAt: now - 60000);
    final b = source('s12', '我买酸奶还是只选原味。');
    extract([_create(a, '你买酸奶只选原味。'), _create(b, '酸奶你只买原味的。')]);
    return store.cards();
  }

  MemoryMergeBatch claim({int Function(String) estimate = _estimate}) =>
      store.nextMergeBatch(estimateTokens: estimate)!;
  void merge(MemoryMergeBatch batch, MemoryRow target, MemoryRow from) {
    expect(
      store.commitMerge(batch, _proposal(batch, target: target['id'] as String, from: from['id'] as String)),
      isTrue,
    );
  }

  Set<String> proofIds(MemoryRow row) =>
      (row['evidence'] as List<Object?>).cast<MemoryRow>().map((proof) => proof['message_id'] as String).toSet();
  String? reserveOrganize() => store.reserveRequest(
    category: 'organize',
    provider: 'deepseek',
    model: 'deepseek-flash',
    inputTokens: 6000,
    outputTokens: 800,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-memory-merge-');
    now = DateTime.utc(2026, 11, 20, 2).millisecondsSinceEpoch;
    nextId = 0;
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  for (final version in [6, 7]) {
    test('a real v$version upgrade preserves B initiative data, source groups and request receipts', () {
      pair();
      final unresolved = source('unclear', '忘掉那件事');
      store.finishUnresolvedControl(messageId: 'unclear', expectedSourceRev: 1);
      expect(store.archive['followup_after_seq'], unresolved['first_seq']);
      final initiative = {
        'v': 2,
        'lastGreetingAtMs': now - 3600000,
        'inviteAtMs': <int>[now - 60000],
        'signalAtMs': <int>[],
        'declinedUntilMs': 0,
        'night': null,
      };
      store.initializeInitiative(initiative);
      final request = version == 6
          ? reserveOrganize()!
          : store.reserveRequest(
              category: 'followup',
              provider: 'deepseek',
              model: 'deepseek-flash',
              inputTokens: 2000,
              outputTokens: 128,
              batchId: 'followup:upgrade:1',
            )!;
      store.markRequestUncertain(request);
      final before = store.cards();
      final meta = store.archive;
      final receipts = store.requests();
      restoreOldMemorySchema(database, version);
      reopen();
      expect(database.select('PRAGMA user_version').single['user_version'], 16);
      expect(store.cards(), [
        for (final card in before) {...card, 'cleanup_history_complete': 0},
      ]);
      expect(store.archive, meta);
      expect(store.initiativeRecord(), initiative);
      expect(store.requests(), receipts);
      expect(claim().rows, hasLength(2));
    });
  }

  test('an identical sentence with the same complete source is deduplicated locally without a claim', () {
    final original = source('same-source', '酸奶我只买原味。');
    extract([_create(original, '你买酸奶只选原味。'), _create(original, '你买酸奶只选原味。')]);
    expect(store.cards(), hasLength(2));
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
    expect(store.cards(), hasLength(1));
    expect(store.cards().single['text'], '你买酸奶只选原味。');
    expect(proofIds(store.cards().single), {'same-source'});
    expect(store.cards().single['source_at_ms'], original['said_at_utc']);
    expect(store.requests(), isEmpty);
  });

  test('same raw tomorrow text from different original days is not locally declared equal', () {
    final monday = source('monday', '我明天去琴课。', saidAt: now - 86400000);
    final tuesday = source('tuesday', '我明天去琴课。');
    extract([
      _create(monday, '你明天去琴课。', kind: 'episode', keywords: ['琴课']),
      _create(tuesday, '你明天去琴课。', kind: 'episode', keywords: ['琴课']),
    ]);
    expect(claim().rows, hasLength(2));
    expect(store.cards(), hasLength(2));
  });

  test('B1 semantic merge keeps target sentence, actual source time and both independent proofs', () {
    final rows = pair();
    final target = rows.first;
    final from = rows.last;
    store.setPinned(id: from['id'] as String, expectedRowRev: from['row_rev'] as int, pinned: true);
    final batch = claim();
    final beforeRevision = store.archive['memory_revision'] as int;
    merge(batch, target, from);
    final kept = store.cards().single;
    expect(kept['id'], target['id']);
    expect(kept['text'], target['text']);
    expect(kept['row_rev'], (target['row_rev'] as int) + 1);
    expect(kept['pinned'], isTrue);
    expect(kept['created_at_ms'], target['created_at_ms']);
    expect(kept['source_at_ms'], now);
    expect(proofIds(kept), {'s11', 's12'});
    final evidence = (kept['evidence'] as List<Object?>).cast<MemoryRow>();
    expect(evidence.map((proof) => proof['support_group']).toSet(), hasLength(2));
    expect(store.archive['memory_revision'], beforeRevision + 1);
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
  });

  test('fixture 13 merges the two daily preferences while keeping the birthday cup exception', () {
    final first = source('daily-a', '我平常喝拿铁不加糖。', saidAt: now - 172800000);
    final second = source('daily-b', '拿铁我平时都选无糖。', saidAt: now - 86400000);
    final birthday = source('birthday', '生日这杯拿铁，我想喝半糖。');
    extract([
      _create(first, '你平常点无糖拿铁。', keywords: ['拿铁']),
      _create(second, '平时你喝拿铁不加糖。', keywords: ['拿铁']),
      _create(birthday, '你生日这杯拿铁要半糖。', keywords: ['拿铁']),
    ]);
    final batch = claim();
    final target = batch.rows.singleWhere((row) => proofIds(row).contains('daily-a'));
    final from = batch.rows.singleWhere((row) => proofIds(row).contains('daily-b'));
    final exception = batch.rows.singleWhere((row) => proofIds(row).contains('birthday'));
    final wrong = _proposal(batch, target: target['id'] as String, from: from['id'] as String);
    (wrong['operations'] as List<MemoryRow>).single['text'] = '以后所有日子都加糖。';
    final before = store.cards();
    expect(() => parseMergeProposal(jsonEncode(wrong), batch), throwsFormatException);
    expect(store.cards(), before);
    merge(batch, target, from);
    final kept = store.cards().singleWhere((row) => row['id'] == target['id']);
    final keptException = store.cards().singleWhere((row) => row['id'] == exception['id']);
    expect(store.cards(), hasLength(2));
    expect(kept['text'], '你平常点无糖拿铁。');
    expect(proofIds(kept), {'daily-a', 'daily-b'});
    for (final field in ['text', 'row_rev', 'evidence', 'event_time', 'plan_state', 'created_at_ms']) {
      expect(keptException[field], exception[field], reason: field);
    }
  });

  test('a later merge keeps all earlier independent groups, not just the latest model citations', () {
    final rows = pair();
    merge(claim(), rows.first, rows.last);
    final third = source('s13', '原味酸奶还是我唯一买的。');
    extract([_create(third, '原味是你买酸奶时唯一选的口味。')]);
    final batch = claim();
    final target = batch.rows.singleWhere((row) => row['id'] == rows.first['id']);
    final from = batch.rows.singleWhere((row) => row['id'] != rows.first['id']);
    // A model can cite one proof of the target; the store must keep its others.
    final proposal = _proposal(
      batch,
      target: target['id'] as String,
      from: from['id'] as String,
      citations: {'s12', 's13'},
    );
    expect(store.commitMerge(batch, proposal), isTrue);
    expect(proofIds(store.cards().single), {'s11', 's12', 's13'});
    store.deleteMessage(id: 's11', expectedSourceRev: 1);
    expect(proofIds(store.cards().single), {'s12', 's13'});
    store.deleteMessage(id: 's12', expectedSourceRev: 1);
    expect(proofIds(store.cards().single), {'s13'});
    store.deleteMessage(id: 's13', expectedSourceRev: 1);
    expect(store.cards(), isEmpty);
  });

  test('merging preserves AND inside a support group and OR between complete groups', () {
    final a = source('a', '酸奶我只买原味。');
    final b = source('b', '这是我一直买酸奶的习惯。');
    final c = source('c', '我买酸奶还是只选原味。');
    extract([
      _create(
        a,
        '你买酸奶只选原味。',
        evidence: [
          {'message_id': a['id'], 'quote': a['text']},
          {'message_id': b['id'], 'quote': b['text']},
        ],
      ),
      _create(c, '酸奶你只买原味的。'),
    ]);
    final rows = store.cards();
    merge(claim(), rows.first, rows.last);
    store.deleteMessage(id: 'a', expectedSourceRev: 1);
    expect(proofIds(store.cards().single), {'c'});
    store.deleteMessage(id: 'c', expectedSourceRev: 1);
    expect(store.cards(), isEmpty);
    expect(store.messages().single['id'], 'b');
  });

  for (final empty in [false, true]) {
    for (final change in ['pin', 'manual edit', 'source edit', 'delete', 'never']) {
      test('whole ${empty ? 'empty' : 'merge'} response is stale after $change', () {
        final rows = pair();
        final batch = claim();
        final proposal = empty
            ? _proposal(batch)
            : _proposal(batch, target: rows.first['id'] as String, from: rows.last['id'] as String);
        switch (change) {
          case 'pin':
            store.setPinned(id: rows.first['id'] as String, expectedRowRev: rows.first['row_rev'] as int, pinned: true);
            break;
          case 'source edit':
            store.editMessage(id: 's11', expectedSourceRev: 1, text: '酸奶我现在也买桃味。');
            break;
          case 'manual edit':
            store.saveManual(
              CompanionMemory(
                id: rows.first['id'] as String,
                kind: 'preference',
                text: '酸奶你也买桃味。',
                keywords: const ['酸奶'],
              ),
              expectedRowRev: rows.first['row_rev'] as int,
              currentValueChange: true,
              realityKnown: true,
            );
            break;
          case 'delete':
            store.deleteCard(id: rows.first['id'] as String, expectedRowRev: rows.first['row_rev'] as int);
            break;
          case 'never':
            store.applyControl(topicIds: [rows.first['topic_id'] as String], kind: 'never');
            break;
        }
        final current = jsonEncode(store.cards(includeInactive: true));
        expect(store.isMergeBatchCurrent(batch), isFalse);
        expect(store.commitMerge(batch, proposal), isFalse);
        store.releaseMergeBatch(batch, examined: true);
        expect(jsonEncode(store.cards(includeInactive: true)), current);
        reopen();
        expect(jsonEncode(store.cards(includeInactive: true)), current);
      });
    }
  }

  test('old source text cannot cross the archive boundary into consolidation', () {
    pair();
    final unrelated = source('clinic', '我周五去复诊。');
    extract([
      _create(unrelated, '你周五去复诊。', kind: 'episode', keywords: ['复诊']),
    ]);
    final clinic = store.cards().singleWhere((row) => row['kind'] == 'episode');
    store.applyControl(topicIds: [clinic['topic_id'] as String], kind: 'never');
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
    expect(store.cards().where((row) => row['kind'] == 'preference'), hasLength(2));
    final a = source('new-a', '酸奶我现在还是只买原味。');
    final b = source('new-b', '原味酸奶是我现在的选择。');
    extract([_create(a, '你现在还是只买原味酸奶。'), _create(b, '原味酸奶是你现在的选择。')]);
    final outgoing = consolidationInput(claim());
    final body = jsonEncode(outgoing);
    expect(body, isNot(contains('s11')));
    expect(body, isNot(contains('s12')));
    expect(body, isNot(contains('clinic')));
    expect(body, contains('new-a'));
    expect(body, contains('new-b'));
  });

  test('valid independent proofs omitted by the outbound cutoff survive a later merge', () {
    final old = source('old', '酸奶我只买原味。');
    final clinic = source('clinic', '我周五去复诊。');
    source('control', '别再提复诊');
    final recent = source('recent', '我买酸奶还是只选原味。');
    extract([
      _create(old, '你买酸奶只选原味。'),
      _create(recent, '酸奶你只买原味的。'),
      _create(clinic, '你周五去复诊。', kind: 'episode', keywords: ['复诊']),
    ]);
    final first = claim();
    final target = first.rows.singleWhere((row) => proofIds(row).contains('old'));
    final from = first.rows.singleWhere((row) => proofIds(row).contains('recent'));
    merge(first, target, from);
    final clinicCard = store.cards().singleWhere((row) => row['kind'] == 'episode');
    store.applyControl(topicIds: [clinicCard['topic_id'] as String], kind: 'never', controlMessageId: 'control');
    final newest = source('newest', '原味酸奶还是我唯一买的。');
    extract([_create(newest, '你买的酸奶还是原味的。')]);
    final batch = claim();
    expect(jsonEncode(consolidationInput(batch)), isNot(contains('"message_id":"old"')));
    expect(batch.rows.singleWhere((row) => row['id'] == target['id'])['evidence'], hasLength(1));
    final other = batch.rows.singleWhere((row) => row['id'] != target['id']);
    merge(batch, target, other);
    expect(proofIds(store.cards().singleWhere((row) => row['id'] == target['id'])), {'old', 'recent', 'newest'});
  });

  test('expiry invalidates a captured complete result without changing a plan into an outcome', () {
    for (final row in pair()) {
      store.saveManual(
        CompanionMemory(
          id: row['id'] as String,
          kind: row['kind'] as String,
          text: row['text'] as String,
          keywords: row['keywords'] as List<String>,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true),
        ),
        expectedRowRev: row['row_rev'] as int,
        currentValueChange: false,
        realityKnown: true,
      );
    }
    final batch = claim();
    final before = store.cards();
    now += 1000;
    expect(store.isMergeBatchCurrent(batch), isFalse);
    expect(store.commitMerge(batch, _proposal(batch)), isFalse);
    store.releaseMergeBatch(batch, examined: true);
    expect(store.cards(), before);
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
  });

  test('story and assistant lines never become real consolidation evidence', () {
    pair();
    source('story', '故事里我开了酸奶店。', scope: 'story');
    source('assistant', '你是酸奶店老板。', role: 'assistant');
    final batch = claim();
    expect(batch.rows, hasLength(2));
    final body = jsonEncode(consolidationInput(batch));
    expect(body, isNot(contains('酸奶店')));
    expect(body, isNot(contains('"message_id":"story"')));
    expect(body, isNot(contains('"message_id":"assistant"')));
  });

  test('fixture 14 deletes a source before the reply; restart and the next actual input omit it and roleplay', () {
    final rows = pair();
    final oldBatch = claim();
    final late = _proposal(oldBatch, target: rows.first['id'] as String, from: rows.last['id'] as String);
    source('roleplay', '故事里的我开了茶馆。', scope: 'story');
    store.deleteMessage(id: 's11', expectedSourceRev: 1);
    expect(store.commitMerge(oldBatch, late), isFalse);
    store.releaseMergeBatch(oldBatch, examined: true);
    reopen();
    expect(store.messages().any((row) => row['id'] == 's11'), isFalse);
    expect(store.messages().singleWhere((row) => row['id'] == 'roleplay')['text'], '故事里的我开了茶馆。');
    final a = source('new-a', '我爱吃酸苹果。');
    final b = source('new-b', '酸苹果是我爱吃的。');
    extract([
      _create(a, '你爱吃酸苹果。', keywords: ['苹果']),
      _create(b, '酸苹果是你爱吃的。', keywords: ['苹果']),
    ]);
    final body = jsonEncode(consolidationInput(claim()));
    for (final absent in ['s11', 's12', '酸奶', '茶馆', 'roleplay']) {
      expect(body, isNot(contains(absent)), reason: absent);
    }
    expect(body, contains('new-a'));
    expect(body, contains('new-b'));
  });

  test('fixture 15 passing the planned day cannot become an invented successful interview', () {
    final first = source('interview-a', '我明天去面试。', saidAt: now - 172800000);
    final second = source('interview-b', '我的面试安排在明天。', saidAt: now - 172700000);
    MemoryRow plan(MemoryRow original, String text) => {
      ..._create(original, text, kind: 'episode', keywords: ['面试']),
      'event_time': {'local_date': '2026-11-19', 'precision': 'day', 'wording': '明天'},
    };
    extract([plan(first, '你11月19日去面试。'), plan(second, '你的面试安排在11月19日。')]);
    final batch = claim();
    final wrong = _proposal(batch, target: batch.rows.first['id'] as String, from: batch.rows.last['id'] as String);
    (wrong['operations'] as List<MemoryRow>).single['text'] = '你的面试已经成功。';
    final before = store
        .cards()
        .map((row) => [row['text'], row['row_rev'], row['event_time'], row['plan_state']])
        .toList();
    expect(() => parseMergeProposal(jsonEncode(wrong), batch), throwsFormatException);
    store.releaseMergeBatch(batch, examined: true);
    expect(
      store.cards().map((row) => [row['text'], row['row_rev'], row['event_time'], row['plan_state']]).toList(),
      before,
    );
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
  });

  test('a third related card brings the whole previously checked group back', () {
    pair();
    final first = claim();
    expect(store.commitMerge(first, _proposal(first)), isTrue);
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
    final third = source('third', '酸奶我还是选原味。');
    extract([_create(third, '你仍然选原味酸奶。')]);
    expect(claim().rows, hasLength(3));
  });

  test('a card added outside an in-flight batch remains unchecked after that batch finishes', () {
    pair();
    final first = claim();
    final third = source('third', '酸奶我还是选原味。');
    extract([_create(third, '你仍然选原味酸奶。')]);
    expect(store.commitMerge(first, _proposal(first)), isTrue);
    expect(claim().rows, hasLength(3));
  });

  test('a changed topic condition reopens its comparison; the same control value does not', () {
    final rows = pair();
    final batch = claim();
    expect(store.commitMerge(batch, _proposal(batch)), isTrue);
    final topic = rows.first['topic_id'] as String;
    store.applyControl(topicIds: [topic], kind: 'normal');
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
    store.applyControl(topicIds: [topic], kind: 'less');
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
    store.applyControl(topicIds: [topic], kind: 'normal');
    expect(claim().rows, hasLength(2));
  });

  test('three equivalent cards get one non-reusing merge round, without a self-triggered cloud chain', () {
    pair();
    final third = source('third', '原味酸奶还是我唯一买的。');
    extract([_create(third, '你买的酸奶还是原味的。')]);
    final batch = claim();
    expect(batch.rows, hasLength(3));
    merge(batch, batch.rows[0], batch.rows[1]);
    expect(store.cards(), hasLength(2));
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
    // 09s B permits disjoint pairs only. One round is not exhaustive deduplication.
    // A later external change, not this merge's own new row_rev, opens another comparison.
  });

  test('an oversized connected group stays unchecked while another complete group can proceed', () {
    pair();
    final third = source('third', '酸奶我还是选原味。');
    final appleA = source('apple-a', '我爱吃酸苹果。');
    final appleB = source('apple-b', '酸苹果是我爱吃的。');
    extract([
      _create(third, '你仍然选原味酸奶。'),
      _create(appleA, '你爱吃酸苹果。', keywords: ['苹果']),
      _create(appleB, '酸苹果是你爱吃的。', keywords: ['苹果']),
    ]);
    int twoOnly(String text) => RegExp('"row_rev":').allMatches(text).length * 2500;
    final batch = claim(estimate: twoOnly);
    expect(batch.rows, hasLength(2));
    expect(batch.rows.every((row) => (row['text'] as String).contains('苹果')), isTrue);
    expect(store.commitMerge(batch, _proposal(batch)), isTrue);
    expect(store.nextMergeBatch(estimateTokens: twoOnly), isNull);
    final unchecked = store.cards().where((row) => (row['text'] as String).contains('酸奶'));
    expect(unchecked.every((row) => row['maintenance_row_rev'] != row['row_rev']), isTrue);
    expect(claim().rows, hasLength(3)); // A later usable estimate can take the intact group.
  });

  test('complete independent groups progress across batches without marking the unseen group', () {
    pair();
    final a = source('apple-a', '我爱吃酸苹果。');
    final b = source('apple-b', '酸苹果是我爱吃的。');
    extract([
      _create(a, '你爱吃酸苹果。', keywords: ['苹果']),
      _create(b, '酸苹果是你爱吃的。', keywords: ['苹果']),
    ]);
    int oneGroup(String text) => RegExp('"row_rev":').allMatches(text).length * 2500;
    final first = claim(estimate: oneGroup);
    expect(first.rows, hasLength(2));
    expect(store.commitMerge(first, _proposal(first)), isTrue);
    final second = claim(estimate: oneGroup);
    expect(second.rows, hasLength(2));
    expect(
      second.rows.map((row) => row['id']).toSet().intersection(first.rows.map((row) => row['id']).toSet()),
      isEmpty,
    );
    expect(store.commitMerge(second, _proposal(second)), isTrue);
    expect(store.nextMergeBatch(estimateTokens: oneGroup), isNull);
  });

  test('waiting keeps work; a definitely ended bad proposal advances only the current checked group', () {
    pair();
    final waiting = claim();
    store.releaseMergeBatch(waiting);
    final retry = claim();
    expect(retry.id, isNot(waiting.id));
    final before = store.cards().map((row) => [row['id'], row['text'], row['row_rev']]).toList();
    store.releaseMergeBatch(retry, examined: true);
    expect(store.cards().map((row) => [row['id'], row['text'], row['row_rev']]).toList(), before);
    expect(store.nextMergeBatch(estimateTokens: _estimate), isNull);
  });

  test('the current claim restores in-process and releasing an older claim cannot clear its replacement', () {
    pair();
    final first = claim();
    final restored = claim();
    expect(restored.id, first.id);
    expect(restored.rows, first.rows);
    final changed = first.rows.first;
    store.setPinned(id: changed['id'] as String, expectedRowRev: changed['row_rev'] as int, pinned: true);
    final current = claim();
    expect(current.id, isNot(first.id));
    expect(store.commitMerge(first, _proposal(first)), isFalse);
    store.releaseMergeBatch(first, examined: true);
    expect(store.isMergeBatchCurrent(current), isTrue);
    expect(current.rows.every((row) => row['maintenance_row_rev'] != row['row_rev']), isTrue);
  });

  test('restart discards the stale claim while an uncertain physical dispatch keeps its budget hold', () {
    pair();
    final old = claim();
    final request = reserveOrganize()!;
    store.markRequestUncertain(request);
    reopen();
    expect(store.isMergeBatchCurrent(old), isFalse);
    expect(claim().id, isNot(old.id));
    expect(store.requests().single['terminal'], 'dispatch_unknown');
    expect(reserveOrganize(), isNull);
  });

  test('one ended rejected consolidation consumes the shared rolling day request opportunity', () {
    pair();
    final batch = claim();
    final request = reserveOrganize()!;
    store.markRequestSent(request);
    store.finishRequest(request, terminal: 'invalid_proposal');
    store.releaseMergeBatch(batch, examined: true);
    expect(reserveOrganize(), isNull);
    now += 86400001;
    expect(reserveOrganize(), isNotNull);
  });

  test('copy failure rolls back the whole merge and keeps its current claim', () {
    final rows = pair();
    final batch = claim();
    final before = jsonEncode(store.cards());
    database.execute(
      "CREATE TRIGGER fail_merge BEFORE INSERT ON memory_card_sources BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    expect(
      () => store.commitMerge(
        batch,
        _proposal(batch, target: rows.first['id'] as String, from: rows.last['id'] as String),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(jsonEncode(store.cards()), before);
    expect(store.isMergeBatchCurrent(batch), isTrue);
  });

  test('a migrated card later grounded by real source moves its cleanup mapping to the retained target', () {
    const oldStore = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const oldCard = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final legacy = CompanionMigrationSnapshot.fromJson({
      'v': 1,
      'storeId': oldStore,
      'revision': 2,
      'memoryRevision': 2,
      'memories': [
        {
          'id': oldCard,
          'kind': 'preference',
          'text': '你买酸奶只选原味。',
          'keywords': ['酸奶'],
          'pinned': true,
          'source': {'kind': 'manual'},
          'createdAt': 1000,
          'updatedAt': 2000,
          'expiresAt': null,
        },
      ],
    });
    store.importLegacy(legacy, realityKnownIds: {oldCard});
    final imported = store.cards().single;
    final a = source('a', '酸奶我只买原味。');
    final b = source('b', '我买酸奶还是只选原味。');
    extract([
      {
        ..._create(a, '你买酸奶只选原味。'),
        'op': 'replace',
        'target_id': imported['id'],
        'expected_row_rev': imported['row_rev'],
      },
      _create(b, '酸奶你只买原味的。'),
    ]);
    final batch = claim();
    final retained = batch.rows.singleWhere((row) => row['id'] != imported['id']);
    final removed = batch.rows.singleWhere((row) => row['id'] == imported['id']);
    merge(batch, retained, removed);
    final mapping = database.select('SELECT * FROM memory_migrations').single;
    expect(mapping['local_card_id'], retained['id']);
    expect(mapping['result'], 'imported');
    expect(mapping['source_fingerprint'], startsWith('sha256-v1:'));
    expect(store.verifyLegacyImport(legacy, [oldCard]), isTrue);
    store.importLegacy(legacy, realityKnownIds: {oldCard});
    expect(store.cards(), hasLength(1));
    expect(store.cards().single['text'], retained['text']);
  });

  for (final outcome in ['shown', 'unknown']) {
    test('merging an already $outcome invitation preserves consumption and invalidates the old ticket', () {
      store.initializeInitiative({
        'v': 2,
        'lastGreetingAtMs': null,
        'inviteAtMs': <int>[],
        'signalAtMs': <int>[],
        'declinedUntilMs': 0,
        'night': null,
      });
      MemoryRow invitation(MemoryRow source, String text) => {
        ..._create(source, text, kind: 'episode', keywords: ['修琴']),
        'followup': {
          'local_date': '2026-11-20',
          'precision': 'day',
          'wording': '周五可以问我修琴的进展',
          'basis': 'explicit_invitation',
        },
      };
      final a = source('invitation-a', '我周五去修琴，周五可以问我修琴的进展。');
      extract([invitation(a, '你周五去修琴。')]);
      final originalCard = store.cards().single;
      final original = store.nextFollowup(nowMs: now)!;
      final spend = store.reserveInitiative(
        kind: 'followup',
        nowMs: now,
        maxPerDay: 2,
        gapMs: 0,
        followupId: original['id'] as String,
      )!;
      store.settleInitiative(spend, outcome: outcome);
      final consumed = store.followups().single;
      now += 100;
      final b = source('invitation-b', '我周五准备去修琴，周五可以问我修琴的进展。');
      extract([invitation(b, '周五去修琴是你的安排。')]);
      final batch = claim();
      final retained = batch.rows.singleWhere((row) => row['id'] != originalCard['id']);
      final removed = batch.rows.singleWhere((row) => row['id'] == originalCard['id']);
      merge(batch, retained, removed);
      final moved = store.followups().singleWhere((row) => row['id'] == original['id']);
      for (final field in [
        'id',
        'time_key',
        'message_id',
        'source_rev',
        'invitation',
        'said_at_utc',
        'offset_minutes',
        'opens_at_ms',
        'expires_at_ms',
        'state',
        'reason',
        'presented_at_ms',
      ]) {
        expect(moved[field], consumed[field], reason: field);
      }
      expect(moved['card_id'], retained['id']);
      expect(moved['row_rev'], (consumed['row_rev'] as int) + 1);
      expect(store.isFollowupCurrent(original, nowMs: now), isFalse);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(database.select("SELECT * FROM memory_initiative_spends WHERE state!='released'"), hasLength(1));
      reopen();
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(
        store.followups().singleWhere((row) => row['id'] == original['id'])['state'],
        outcome == 'shown' ? 'asked' : 'maybe_shown',
      );
    });
  }
}
