import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:dsh_client/src/companion_memory_rules.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const manualCard = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

int estimate(String text) => (text.runes.length / 4).ceil();

MemoryRow create(MemoryRow source, {String? text, String? quote, List<String>? keywords}) => {
  'op': 'create', 'kind': 'fact', 'text': text ?? source['text'],
  if (keywords != null) 'keywords': keywords,
  'evidence': [{'message_id': source['id'], 'quote': quote ?? source['text']}],
};

MemoryRow parsed(MemoryBatch batch, [List<MemoryRow> operations = const []]) => parseExtractionProposal(jsonEncode({
  'schema_version': 2, 'batch_id': batch.id,
  'covered_message_ids': [for (final source in batch.sources) source['id']],
  'operations': operations, 'completion': 'complete',
}), batch);

MemoryRow usage({int? input, int? read, int? write, int? output, bool complete = true}) => {
  'provider': 'deepseek', 'model': 'deepseek-flash',
  'start_usage': {'input_tokens': 999, 'output_tokens': 1},
  'final_usage': {
    if (input != null) 'input_tokens': input,
    if (read != null) 'cache_read_input_tokens': read,
    if (write != null) 'cache_creation_input_tokens': write,
    if (output != null) 'output_tokens': output,
    'vendor_extension': {'counter': 7},
  },
  'start_event': 'message_start', 'final_event': 'message_delta', 'usage_semantics': 'cumulative',
  'input_uncached': input, 'input_cache_read': read, 'input_cache_write': write, 'output_tokens': output,
  'stop_reason': 'end_turn', 'terminal': complete ? 'complete' : 'incomplete',
  'complete': complete, 'http_status': 200,
};

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1000000;
  var nextId = 0;
  final forcedIds = <String>[];
  String id() => forcedIds.isEmpty
      ? '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}' : forcedIds.removeAt(0);
  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: id);
  }
  void reopen() {
    store.close();
    open();
  }
  MemoryRow submit(String messageId, String text, {
    String session = 'room-a', String role = 'user', String scope = 'real', int? saidAt, int offset = 480,
  }) => store.submitMessage(id: messageId, sessionId: session, text: text, role: role, scope: scope,
    saidAtUtc: saidAt ?? now, offsetMinutes: offset);
  MemoryBatch batch() => store.nextBatch(forceTail: true, estimateTokens: estimate)!;
  List<MemoryRow> events() => [for (final row in database.select('SELECT * FROM memory_events ORDER BY seq')) {...row}];
  String? reserve({String category = 'extract', String provider = 'deepseek', String model = 'deepseek-flash',
    int input = 6000, int output = 800}) => store.reserveRequest(category: category, provider: provider,
      model: model, inputTokens: input, outputTokens: output);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-memory-flow-');
    now = 1000000;
    nextId = 0;
    forcedIds.clear();
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  group('durable source and ordered queue', () {
    test('a new light conversation persists its identity and keeps old visible history out of the model', () {
      final first = store.lightSessionId;
      expect(first, startsWith('light:'));
      submit('u1', '上一场聊天', session: first);
      final next = store.startLightConversation();
      expect(next, isNot(first));
      expect(store.messages(sessionId: next, forModel: true), isEmpty);
      expect(store.messages().single['text'], '上一场聊天');
      reopen();
      expect(store.lightSessionId, next);
      expect(store.messages(sessionId: first).single['id'], 'u1');
    });

    test('a stable send and its claimed batch survive reopen without duplicating a statement', () {
      final source = submit('u1', '我改学长笛了');
      expect(submit('u1', '我改学长笛了'), source);
      expect(store.archive['next_seq'], 2);
      expect(() => submit('u1', '把同 ID 偷换成别的话'), throwsA(isA<DshRemoteException>()));
      final first = batch();
      reopen();
      final restored = store.nextBatch(estimateTokens: estimate)!;
      expect(restored.id, first.id);
      expect(restored.sources, first.sources);
      expect(store.messages().single['text'], '我改学长笛了');
      expect(store.commitExtraction(restored, parsed(restored, [create(restored.sources.single, keywords: ['长笛'])])), isTrue);
      expect(store.commitExtraction(restored, parsed(restored)), isFalse);
      reopen();
      expect(store.cards(), hasLength(1));
      expect(store.cards().single['evidence'], [containsPair('message_id', 'u1')]);
      expect(events().single['state'], 'done');
    });

    test('source save failure rolls back the message and sequence before any request can leave', () {
      database.execute("""
        CREATE TRIGGER fail_event BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END
      """);
      expect(() => submit('u1', '本地还没保存'), throwsA(isA<SqliteException>()));
      expect(store.messages(), isEmpty);
      expect(store.archive['next_seq'], 1);
      expect(store.requests(), isEmpty);
      expect(store.nextBatch(forceTail: true, estimateTokens: estimate), isNull);
    });

    test('malformed source text or an unavailable clock does not allocate an event', () {
      for (final text in ['  ', 'bad\u0000text', String.fromCharCode(0xd800)]) {
        expect(() => submit('bad', text), throwsA(isA<DshRemoteException>()));
      }
      now = -1;
      expect(() => submit('clock', '仍然保留在输入框', saidAt: 1), throwsA(isA<DshRemoteException>()));
      expect(store.messages(), isEmpty);
      expect(store.archive['next_seq'], 1);
    });

    test('editing preserves first identity, original clock and offset while superseding the event', () {
      final original = DateTime.utc(2026, 11, 2, 15, 55).millisecondsSinceEpoch;
      now = original;
      final first = submit('u1', '小鹿，明天去看纸展', saidAt: original);
      now = DateTime.utc(2026, 11, 4, 1).millisecondsSinceEpoch;
      final edited = store.editMessage(id: 'u1', expectedSourceRev: 1, text: '小露，明天去看纸展');
      expect(edited['first_seq'], first['first_seq']);
      expect(edited['said_at_utc'], original);
      expect(edited['offset_minutes'], 480);
      expect(edited['source_rev'], 2);
      expect(edited['event_seq'], greaterThan(first['event_seq'] as int));
      expect(edited['edited_at_utc'], now);
      expect(events().map((event) => event['state']), ['superseded', 'pending']);
      final outgoing = extractionInput(batch(), processedAtUtc: now);
      final sent = (outgoing['source'] as List).single as Map;
      expect(sent['said_at_utc'], '2026-11-02T15:55:00.000Z');
      expect(sent['edited_at_utc'], '2026-11-04T01:00:00.000Z');
      expect(sent['offset_minutes'], 480);
      expect(() => store.editMessage(id: 'u1', expectedSourceRev: 1, text: '过期编辑'), throwsA(isA<DshRemoteException>()));
    });

    test('editing one member removes its whole support group and retains an independent complete group', () {
      final a = submit('a', '我住上海');
      final b = submit('b', '我喝无糖咖啡');
      submit('c', '我住上海，喝无糖咖啡');
      final claimed = batch();
      expect(store.commitExtraction(claimed, parsed(claimed, [{
        'op': 'create', 'kind': 'fact', 'text': '住上海，喝无糖咖啡', 'keywords': ['上海', '咖啡'],
        'evidence': [{'message_id': a['id'], 'quote': a['text']}, {'message_id': b['id'], 'quote': b['text']}],
      }])), isTrue);
      final cardId = store.cards().single['id'];
      // A frozen second proof group, as a later merge would retain; the action
      // under test is the production source-edit invalidation, not merge.
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)',
        [cardId, 'independent', 'c', 1, '我住上海，喝无糖咖啡']);
      store.editMessage(id: 'a', expectedSourceRev: 1, text: '我搬到了杭州');
      final remaining = store.cards().single;
      expect(remaining['eligible'], isTrue);
      expect((remaining['evidence'] as List).map((entry) => (entry as Map)['message_id']), ['c']);
      expect(database.select('SELECT * FROM memory_card_sources WHERE message_id=?', ['b']), isEmpty,
        reason: 'the surviving half of an invalid proof is not an independent proof');
      store.editMessage(id: 'c', expectedSourceRev: 1, text: '那段记错了');
      expect(store.cards(), isEmpty);
      expect(store.cards(includeInactive: true).single['eligible'], isFalse);
      expect(store.cards(includeInactive: true).single['status'], 'withdrawn');
    });

    test('removing the newest proof recalculates the current basis, recency and supported keywords', () {
      final originalAt = now;
      submit('a', '咖啡我喝无糖。');
      now += 100;
      submit('middle', '咖啡我现在改喝半糖。');
      now += 100;
      submit('newest', '咖啡我喝无糖，也学长笛。');
      final first = batch();
      final newest = first.sources.last;
      store.commitExtraction(first, parsed(first, [create(newest, text: '咖啡喝无糖', keywords: ['咖啡', '长笛'])]));
      final cardId = store.cards().single['id'];
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [cardId, 'older-proof', 'a', 1, '咖啡我喝无糖。']);
      expect(store.cards().single['current_basis_seq'], 3);
      now += 100;
      store.editMessage(id: 'newest', expectedSourceRev: 1, text: '那句不成立');
      final remaining = store.cards().single;
      expect(remaining['current_basis_seq'], 1);
      expect(remaining['source_at_ms'], originalAt);
      expect(remaining['keywords'], ['咖啡']);
      expect(selectMemoryContext(store.cards(), input: '长笛', nowMs: now,
        controlRevision: store.archive['control_revision'] as int).ids, isEmpty);
      store.editMessage(id: 'middle', expectedSourceRev: 1, text: '小露，咖啡我现在改喝半糖。');
      final next = batch();
      final middle = next.sources.singleWhere((source) => source['id'] == 'middle');
      expect(store.commitExtraction(next, parsed(next, [{
        ...create(middle, text: '咖啡现在喝半糖', keywords: ['咖啡']), 'op': 'replace',
        'target_id': cardId, 'expected_row_rev': remaining['row_rev'], 'change_kind': 'new_current_value',
      }])), isTrue);
      expect(store.cards().single['current_basis_seq'], 2);
      expect(store.cards().single['text'], '咖啡现在喝半糖');
    });

    test('only real user inputs count toward eight, and a 1500-token source also triggers', () {
      for (var n = 0; n < 7; n++) {
        submit('u$n', '短句 $n');
      }
      submit('assistant', '助手说的话', role: 'assistant');
      submit('story', '故事里叫我校长', scope: 'story');
      expect(store.nextBatch(estimateTokens: estimate), isNull);
      submit('u7', '第八句');
      final eight = store.nextBatch(estimateTokens: estimate)!;
      expect(eight.sources.map((source) => source['id']), List.generate(8, (n) => 'u$n'));
      expect(store.commitExtraction(eight, parsed(eight)), isTrue);
      submit('long', List.filled(6000, '字').join());
      expect(store.nextBatch(estimateTokens: estimate)!.sources.single['id'], 'long');
    });

    test('the two-minute quiet tail uses queue time, not an old statement date', () {
      submit('u1', '我学长笛', saidAt: 1);
      now += 119999;
      expect(store.nextBatch(estimateTokens: estimate), isNull);
      submit('assistant', '嗯', role: 'assistant');
      now++;
      final tail = store.nextBatch(estimateTokens: estimate)!;
      expect(tail.sources.single['id'], 'u1');
      expect(tail.sources.single['said_at_utc'], 1);
    });

    test('a batch has at most 32 intact sources and advances across manual sequence gaps', () {
      submit('first', '第一句');
      store.saveManual(const CompanionMemory(id: manualCard, text: '本人手改的现值'),
        expectedRowRev: null, currentValueChange: true, realityKnown: true);
      for (var n = 1; n < 40; n++) {
        submit('u$n', '完整原话 $n');
      }
      final claimed = store.nextBatch(estimateTokens: estimate)!;
      expect(claimed.sources, hasLength(32));
      expect(claimed.sources[1]['first_seq'], 3);
      expect(store.commitExtraction(claimed, parsed(claimed)), isTrue);
      expect(store.archive['cursor_seq'], 33);
      final next = store.nextBatch(estimateTokens: estimate)!;
      expect(next.sources, hasLength(8));
      expect(store.commitExtraction(next, parsed(next)), isTrue);
      expect(store.archive['cursor_seq'], 41);
    });

    test('optional existing context cannot make a short source look oversized', () {
      for (var n = 0; n < 12; n++) {
        store.saveManual(CompanionMemory(id: id(), text: '第$n张 ${List.filled(490, '字').join()}'),
          expectedRowRev: null, currentValueChange: true, realityKnown: true);
      }
      submit('short', '我学长笛');
      final inspected = <String>[];
      int conservative(String text) {
        inspected.add(text);
        return text.runes.length;
      }
      final claimed = store.nextBatch(forceTail: true, estimateTokens: conservative)!;
      expect(claimed.sources.single['id'], 'short');
      expect(claimed.existing.length, lessThan(12));
      expect(events().single['state'], 'pending');
      final whole = '$companionMemoryExtractionPrompt\n${jsonEncode(extractionInput(claimed, processedAtUtc: now))}';
      expect(whole.runes.length, lessThanOrEqualTo(6000));
      expect(inspected, contains(whole));
    });

    for (final invalidFirst in [false, true]) {
      test('expired existing context is not restored after ${invalidFirst ? 'a format failure' : 'a wait and restart'}', () {
        store.saveManual(CompanionMemory(id: manualCard, text: '暂时喝半糖咖啡', keywords: const ['咖啡'],
          expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true)),
          expectedRowRev: null, currentValueChange: true, realityKnown: true);
        submit('u1', '今天练长笛');
        final first = batch();
        expect(first.existing.single['id'], manualCard);
        if (invalidFirst) {
          store.recordInvalidProposal(first);
        } else {
          store.releaseBatch(first, reason: 'waiting_network');
        }
        now += 1000; // Equality is expired; no row revision changed.
        reopen();
        final reclaimed = batch();
        expect(reclaimed.id, isNot(first.id));
        expect(reclaimed.sources.single['id'], 'u1');
        expect(reclaimed.existing, isEmpty);
        expect(store.cards().single['row_rev'], 1);
        expect(events().single['format_failures'], invalidFirst ? 1 : 0);
        expect(store.isBatchCurrent(first), isFalse);
        if (invalidFirst) {
          store.recordInvalidProposal(reclaimed);
          expect(events().single['state'], 'skipped');
          expect(events().single['format_failures'], 2);
        } else {
          expect(store.commitExtraction(reclaimed, parsed(reclaimed)), isTrue);
        }
      });
    }

    test('an expired later value cannot permanently skip a supported older create', () {
      final old = submit('old', '我喝无糖咖啡');
      store.saveManual(CompanionMemory(id: manualCard, text: '暂时喝半糖咖啡', keywords: const ['咖啡'],
        expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true)),
        expectedRowRev: null, currentValueChange: true, realityKnown: true);
      now += 1000;
      final claimed = batch();
      expect(claimed.existing, isEmpty);
      expect(store.commitExtraction(claimed, parsed(claimed, [create(old, keywords: ['咖啡'])])), isTrue);
      expect(store.cards().where((card) => card['id'] != manualCard).single['text'], '我喝无糖咖啡');
      expect(events().single['reason'], isNull);
      expect(selectMemoryContext(store.cards(), input: '咖啡', nowMs: now,
        controlRevision: store.archive['control_revision'] as int).ids, isNot(contains(manualCard)));
    });

    test('a replacement target expiring during the request cannot be revived by its old snapshot', () {
      store.saveManual(CompanionMemory(id: manualCard, text: '暂时喝半糖咖啡', keywords: const ['咖啡'],
        expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true)),
        expectedRowRev: null, currentValueChange: true, realityKnown: true);
      final source = submit('u1', '我现在咖啡喝无糖');
      final claimed = batch();
      final result = parsed(claimed, [{
        ...create(source, keywords: ['咖啡']), 'op': 'replace',
        'target_id': manualCard, 'expected_row_rev': 1,
      }]);
      now += 1000;
      expect(store.commitExtraction(claimed, result), isFalse);
      expect(store.cards().single['text'], '暂时喝半糖咖啡');
      expect(store.cards().single['expires_at_ms'], now);
      expect(events().single['state'], 'pending');
      expect(events().single['format_failures'], 0);
      store.releaseBatch(claimed, reason: 'stale_target');
      final reclaimed = batch();
      expect(reclaimed.id, isNot(claimed.id));
      expect(reclaimed.existing, isEmpty);
      expect(events().single['format_failures'], 0);
    });

    test('one individually oversized source is visibly skipped without blocking the next source', () {
      final tooLong = List.filled(25000, '字').join();
      submit('long', tooLong);
      submit('short', '我改学长笛了');
      final claimed = store.nextBatch(estimateTokens: estimate)!;
      expect(claimed.sources.single['id'], 'short');
      expect(events().first['state'], 'skipped');
      expect(events().first['reason'], 'input_too_long');
      expect(store.messages().first['text'], tooLong);
      expect(store.archive['cursor_seq'], 1);
      expect(store.commitExtraction(claimed, parsed(claimed)), isTrue);
      expect(store.archive['cursor_seq'], 2);
    });

    test('a full input cap leaves the next intact source pending instead of truncating it', () {
      final long = List.filled(10000, '字').join();
      for (var n = 0; n < 3; n++) {
        submit('u$n', '$n$long');
      }
      final first = store.nextBatch(estimateTokens: estimate)!;
      expect(first.sources.map((row) => row['id']), ['u0', 'u1']);
      expect(first.sources.last['text'], '1$long');
      expect(estimate('$companionMemoryExtractionPrompt\n${jsonEncode(extractionInput(first, processedAtUtc: now))}'),
        lessThanOrEqualTo(6000));
      expect(events().last['state'], 'pending');
      expect(events().last['reason'], isNull);
      expect(store.commitExtraction(first, parsed(first)), isTrue);
      expect(store.nextBatch(estimateTokens: estimate)!.sources.single['text'], '2$long');
    });

    test('a bad proposal retries the same batch once; newer input cannot reset its failures', () {
      submit('old', '我学长笛');
      final first = batch();
      expect(() => parseExtractionProposal('{', first), throwsFormatException);
      store.recordInvalidProposal(first);
      store.recordInvalidProposal(first);
      expect(events().single['format_failures'], 1, reason: 'the same settled attempt is not a second attempt');
      submit('new', '后来的一句');
      reopen();
      final retry = store.nextBatch(estimateTokens: estimate)!;
      expect(retry.id, first.id);
      expect(retry.sources.map((source) => source['id']), ['old']);
      expect(() => parseExtractionProposal('{', retry), throwsFormatException);
      store.recordInvalidProposal(retry);
      expect(events().first['format_failures'], 2);
      expect(events().first['state'], 'skipped');
      expect(events().first['reason'], 'invalid_proposal');
      expect(events().last['format_failures'], 0);
      expect(batch().sources.single['id'], 'new');
    });

    test('network waiting preserves the head and does not consume format retries', () {
      submit('head', '我学长笛');
      final first = batch();
      store.releaseBatch(first, reason: 'network');
      store.releaseBatch(first, reason: 'network');
      submit('later', '稍后又说');
      final retry = store.nextBatch(estimateTokens: estimate)!;
      expect(retry.id, first.id);
      expect(retry.sources.map((source) => source['id']), ['head']);
      expect(events().first['format_failures'], 0);
      expect(events().first['state'], 'pending');
      expect(store.archive['cursor_seq'], 0);
      expect(store.commitExtraction(retry, parsed(retry)), isTrue);
      expect(batch().sources.single['id'], 'later');
    });

    test('source or control changes before an invalid response do not spend a format attempt', () {
      submit('u1', '我学长笛');
      final first = batch();
      store.editMessage(id: 'u1', expectedSourceRev: 1, text: '我改学竹笛');
      store.recordInvalidProposal(first);
      expect(events().map((event) => event['format_failures']), [0, 0]);
      expect(store.commitExtraction(first, parsed(first)), isFalse);
      final second = batch();
      database.execute('UPDATE memory_archive SET control_revision=control_revision+1');
      store.recordInvalidProposal(second);
      expect(events().last['format_failures'], 0);
      expect(store.commitExtraction(second, parsed(second)), isFalse);
    });

    test('model history and future extraction respect the first-sequence cutoff across rooms', () {
      submit('kept', '我学长笛');
      final initial = batch();
      expect(store.commitExtraction(initial, parsed(initial, [create(initial.sources.single, keywords: ['长笛'])])), isTrue);
      submit('old', '明天去公园', session: 'room-b');
      submit('control', '忘了之前那事', session: 'room-b');
      database.execute('UPDATE memory_archive SET control_revision=control_revision+1,history_after_seq=3');
      store.editMessage(id: 'old', expectedSourceRev: 1, text: '后天去公园');
      submit('new', '今天去书店', session: 'room-a');
      expect(store.messages(), hasLength(4));
      expect(store.messages(forModel: true).map((row) => row['id']), ['new']);
      expect(store.messages(sessionId: 'room-b', limit: 1).single['id'], 'control');
      expect(batch().sources.map((row) => row['id']), ['new']);
      expect(store.cards().single['text'], '我学长笛', reason: 'the cutoff does not invalidate an independent existing card');
    });
  });

  group('current values and atomic proposal commit', () {
    test('illegal generated controls fail before commit; old malformed cards are excluded from selection', () {
      submit('u1', '我学长笛\u0007');
      final claimed = batch();
      for (final code in [0, 8, 11, 12, 31, 127]) {
        expect(() => parsed(claimed, [create(claimed.sources.single, text: '长笛${String.fromCharCode(code)}')]),
          throwsFormatException);
      }
      expect(store.cards(), isEmpty);
      expect(events().single['state'], 'pending');
      expect(store.messages().single['text'], '我学长笛\u0007');
      expect(store.commitExtraction(claimed, parsed(claimed,
        [create(claimed.sources.single, text: '我学长笛', keywords: ['长笛'])])), isTrue);
      expect((store.cards().single['evidence'] as List).single, containsPair('quote', '我学长笛\u0007'));
      // Frozen pre-fix persisted row: exercise store read -> production selector.
      database.execute('UPDATE memory_cards SET text=?', ['长笛\u0000']);
      expect(selectMemoryContext(store.cards(), input: '长笛', nowMs: now,
        controlRevision: store.archive['control_revision'] as int).ids, isEmpty);
    });

    test('automatic cards do not inherit the old manual 512-scalar write limit', () {
      final text = '长笛${List.filled(598, '字').join()}';
      submit('u1', text);
      final claimed = batch();
      expect(store.commitExtraction(claimed, parsed(claimed, [create(claimed.sources.single, keywords: ['长笛'])])), isTrue);
      expect((store.cards().single['text'] as String).runes.length, 600);
      expect(selectMemoryContext(store.cards(), input: '长笛', nowMs: now,
        controlRevision: store.archive['control_revision'] as int).ids, [store.cards().single['id']]);
    });

    for (final wording in ['我明天面试之前会再看材料。', '我以前喝半糖，现在面试前改喝无糖。']) {
      test('episode wording never grants an old targetless create a current-value bypass: $wording', () {
        submit('old', wording);
        store.saveManual(const CompanionMemory(id: manualCard, text: '我的面试计划已经改了', keywords: ['面试']),
          expectedRowRev: null, currentValueChange: true, realityKnown: true);
        final claimed = batch();
        final operation = {...create(claimed.sources.single, keywords: ['面试']), 'kind': 'episode'};
        expect(store.commitExtraction(claimed, parsed(claimed, [operation])), isTrue);
        expect(store.cards(), hasLength(1));
        expect(store.cards().single['id'], manualCard);
        expect(events().single['reason'], contains('possible_current_conflict'));
      });
    }

    test('an independent supported episode remains current without guessing tense from its words', () {
      submit('u1', '我明天面试之前会再看材料。');
      final claimed = batch();
      store.commitExtraction(claimed, parsed(claimed, [{...create(claimed.sources.single, keywords: ['面试']), 'kind': 'episode'}]));
      expect(store.cards().single['status'], 'current');
      expect(store.cards().single['text'], '我明天面试之前会再看材料。');
    });

    test('editing an old statement cannot undo a later independent current value', () {
      submit('m', '小鹿，我现在喝咖啡要无糖。');
      final original = batch();
      store.commitExtraction(original, parsed(original, [create(original.sources.single, text: '咖啡要无糖', keywords: ['咖啡'])]));
      submit('n', '我现在改喝半糖咖啡了。');
      final newer = batch();
      final card = newer.existing.single;
      MemoryRow replacement(MemoryBatch input, String text) => {
        ...create(input.sources.single, text: text, keywords: ['咖啡']), 'op': 'replace',
        'target_id': card['id'], 'expected_row_rev': input.existing.single['row_rev'], 'change_kind': 'new_current_value',
      };
      store.commitExtraction(newer, parsed(newer, [replacement(newer, '咖啡改喝半糖')]));
      final half = store.cards().single;
      store.editMessage(id: 'm', expectedSourceRev: 1, text: '小露，我现在喝咖啡要无糖。');
      final oldEdit = batch();
      expect(store.commitExtraction(oldEdit, parsed(oldEdit, [replacement(oldEdit, '咖啡要无糖')])), isTrue);
      expect(store.cards().single['text'], '咖啡改喝半糖');
      expect(store.cards().single['current_basis_seq'], half['current_basis_seq']);
      expect(events().last['reason'], contains('older_than_current'));
      submit('p', '小露，我现在喝咖啡要无糖。');
      final newStatement = batch();
      expect(store.commitExtraction(newStatement, parsed(newStatement, [replacement(newStatement, '咖啡要无糖')])), isTrue);
      expect(store.cards().single['text'], '咖啡要无糖');
      expect(store.cards().single['current_basis_seq'], newStatement.sources.single['first_seq']);
    });

    for (final manualBeforeClaim in [true, false]) {
      test('A3 create without proposed keywords cannot bypass a later manual value ($manualBeforeClaim)', () {
        submit('u3', '我喝无糖咖啡，也在学手风琴。');
        void changeCurrent() => store.saveManual(
          const CompanionMemory(id: manualCard, text: '我现在喝半糖咖啡', keywords: ['咖啡']),
          expectedRowRev: null, currentValueChange: true, realityKnown: true,
        );
        if (manualBeforeClaim) changeCurrent();
        final claimed = batch();
        if (!manualBeforeClaim) changeCurrent();
        final source = claimed.sources.single;
        expect(store.commitExtraction(claimed, parsed(claimed, [
          create(source, text: '咖啡要无糖', quote: '我喝无糖咖啡'),
          create(source, text: '在学手风琴', quote: '在学手风琴', keywords: ['手风琴']),
        ])), isTrue);
        expect(store.cards().map((card) => card['text']), unorderedEquals(['我现在喝半糖咖啡', '在学手风琴']));
        expect(events().single['reason'], contains('possible_current_conflict'));
        expect(events().single['reason'], isNot(contains('手风琴')));
      });
    }

    test('a captured target revision changed by a manual edit makes the whole result obsolete', () {
      submit('u1', '咖啡喝无糖');
      store.saveManual(const CompanionMemory(id: manualCard, text: '咖啡喝半糖', keywords: ['咖啡']),
        expectedRowRev: null, currentValueChange: true, realityKnown: true);
      final claimed = batch();
      final proposal = parsed(claimed, [{
        ...create(claimed.sources.single, keywords: ['咖啡']), 'op': 'replace',
        'target_id': manualCard, 'expected_row_rev': 1,
      }]);
      store.saveManual(const CompanionMemory(id: manualCard, text: '咖啡喝全糖', keywords: ['咖啡']),
        expectedRowRev: 1, currentValueChange: true, realityKnown: true);
      expect(store.commitExtraction(claimed, proposal), isFalse);
      expect(store.cards().single['text'], '咖啡喝全糖');
      expect(events().single['state'], 'pending');
      expect(events().single['format_failures'], 0);
    });

    test('a write failure rolls back cards, complete proof groups, coverage and cursor together', () {
      submit('u1', '我学长笛');
      final claimed = batch();
      final proposal = parsed(claimed, [create(claimed.sources.single, keywords: ['长笛'])]);
      database.execute("""
        CREATE TRIGGER fail_finish BEFORE UPDATE OF state ON memory_events
        WHEN NEW.state='done' BEGIN SELECT RAISE(ABORT,'fixture'); END
      """);
      expect(() => store.commitExtraction(claimed, proposal), throwsA(isA<SqliteException>()));
      expect(store.cards(), isEmpty);
      expect(database.select('SELECT * FROM memory_topics'), isEmpty);
      expect(database.select('SELECT * FROM memory_card_sources'), isEmpty);
      expect(events().single['state'], 'pending');
      expect(store.archive['cursor_seq'], 0);
      expect(store.archive['memory_revision'], 0);
      expect(store.isBatchCurrent(claimed), isTrue);
      database.execute('DROP TRIGGER fail_finish');
      expect(store.commitExtraction(claimed, proposal), isTrue);
      expect(store.cards(), hasLength(1));
      expect(events().single['state'], 'done');
    });

    for (final correction in [false, true]) {
      test('09s A4 exact proposal retains u4 evidence without inventing a past card ($correction)', () {
        now = DateTime.utc(2026, 11, 19, 2).millisecondsSinceEpoch;
        database.execute("INSERT INTO memory_topics(id) VALUES('coffee')");
        database.execute('''
          INSERT INTO memory_cards(id,row_rev,kind,text,keywords,eligible,manual,topic_id,current_basis_seq,
            source_at_ms,created_at_ms,updated_at_ms) VALUES('k3',8,'preference','你现在咖啡喝半糖。','["咖啡"]',1,1,'coffee',102,1,1,1)
        ''');
        database.execute('UPDATE memory_archive SET next_seq=104');
        final wording = correction ? '咖啡我一直喝无糖，是之前记错了。' : '以前喝半糖，现在咖啡改喝无糖了。';
        submit('u4', wording, saidAt: DateTime.utc(2026, 11, 19, 1).millisecondsSinceEpoch);
        forcedIds.add('a4');
        final claimed = batch();
        const exactA4 = '''
{
  "schema_version": 2,
  "batch_id": "a4",
  "covered_message_ids": ["u4"],
  "operations": [
    {
      "op": "replace",
      "kind": "preference",
      "text": "你现在咖啡喝无糖。",
      "keywords": ["咖啡","无糖"],
      "evidence": [{"message_id":"u4","quote":"以前喝半糖，现在咖啡改喝无糖了。"}],
      "target_id": "k3",
      "expected_row_rev": 8,
      "change_kind": "new_current_value"
    }
  ],
  "completion": "complete"
}
''';
        final raw = correction ? exactA4.replaceAll('以前喝半糖，现在咖啡改喝无糖了。', wording)
          .replaceAll('new_current_value', 'correction_of_error') : exactA4;
        expect(store.commitExtraction(claimed, parseExtractionProposal(raw, claimed)), isTrue);
        final current = store.cards().single;
        expect(current['text'], '你现在咖啡喝无糖。');
        expect(current['current_basis_seq'], 104);
        expect(current['row_rev'], 9);
        expect(current['status'], 'current');
        expect(current['source_at_ms'], DateTime.utc(2026, 11, 19, 1).millisecondsSinceEpoch);
        expect((current['evidence'] as List).single, containsPair('quote', wording));
        expect(store.cards(includeInactive: true), hasLength(1));
        if (correction) expect(jsonEncode(current['evidence']), isNot(contains('半糖')));
      });
    }
  });

  group('request receipts and rolling reservations', () {
    test('known-unsent release and observed HTTP failure have distinct costs and request times', () {
      final notSent = reserve()!;
      store.finishRequest(notSent, terminal: 'no_key');
      expect(store.requests().single['state'], 'released');
      expect(store.requests().single['sent_at_ms'], isNull);
      final request = reserve()!;
      now += 5000;
      store.markRequestSent(request);
      final sentAt = now;
      now++;
      store.markRequestSent(request);
      store.finishRequest(request, terminal: 'http_error');
      final receipt = store.requests().last;
      expect(receipt['sent_at_ms'], sentAt);
      expect(receipt['state'], 'finished');
      expect(receipt['terminal'], 'http_error');
      expect(receipt['input_uncached'], isNull);
      expect(receipt['output_tokens'], isNull);
      expect(receipt['estimated_cny'], isNull);
    });

    test('frozen final SSE usage survives storage unchanged, even without stop, and a replay is idempotent', () {
      final request = reserve()!;
      store.markRequestSent(request);
      final raw = usage(input: 100, read: 25, write: 0, output: 37, complete: false);
      store.recordUsage(request, raw);
      store.recordUsage(request, raw);
      store.finishRequest(request, terminal: 'incomplete');
      store.finishRequest(request, terminal: 'incomplete');
      reopen();
      final receipt = store.requests().single;
      expect(receipt['raw_usage'], raw);
      expect(receipt['usage_semantics'], 'cumulative');
      expect(receipt['input_uncached'], 100);
      expect(receipt['input_cache_read'], 25);
      expect(receipt['input_cache_write'], 0);
      expect(receipt['output_tokens'], 37);
      expect(receipt['terminal'], 'incomplete');
      expect(receipt['estimated_cny'], closeTo((100 * 2 + 25 * .04 + 37 * 8) / 1000000, 1e-12));
      final retry = reserve()!;
      store.markRequestSent(retry);
      expect(store.requests(), hasLength(2));
      expect(() => store.recordUsage(request, usage(input: 0, read: 0, write: 0, output: 0)),
        throwsA(isA<DshRemoteException>()));
    });

    test('a cancelled chat accepts its once-only late finally usage without losing its terminal state', () {
      final request = reserve(category: 'chat', input: 10000)!;
      store.markRequestSent(request);
      store.finishRequest(request, terminal: 'cancelled');
      final raw = {...usage(input: 10, read: 0, write: 0, output: 1, complete: false), 'terminal': 'cancelled'};
      store.recordUsage(request, raw);
      expect(store.requests().single['terminal'], 'cancelled');
      expect(store.requests().single['raw_usage'], raw);
      expect(store.requests().single['output_tokens'], 1);
      expect(store.requests().single['estimated_cny'], closeTo(.000028, 1e-12));
    });

    test('start-only and missing final components keep reservations instead of becoming free', () {
      final startOnly = {...usage(complete: false), 'final_usage': null, 'final_event': null};
      for (var i = 0; i < 3; i++) {
        final request = reserve()!;
        store.markRequestSent(request);
        store.recordUsage(request, i == 0 ? startOnly : usage(input: 0, read: 0, output: 0));
        store.finishRequest(request, terminal: 'incomplete');
      }
      expect(store.requests().first['raw_usage'], startOnly);
      expect(store.requests().first['output_tokens'], isNull);
      expect(store.requests().last['input_cache_write'], isNull);
      expect(reserve(), isNull, reason: 'three 800-output reservations leave only 600, despite partial zero reports');
      now += 86400000;
      expect(reserve(), isNotNull);
    });

    test('ten real extraction attempts include retries and failures even when actual usage is zero', () {
      for (var i = 0; i < 10; i++) {
        final request = reserve()!;
        store.markRequestSent(request);
        store.recordUsage(request, usage(input: 0, read: 0, write: 0, output: 0));
        store.finishRequest(request, terminal: i.isEven ? 'invalid_proposal' : 'complete');
      }
      expect(reserve(input: 0, output: 0), isNull);
      now += 86400000 - 1;
      expect(reserve(input: 0, output: 0), isNull);
      now++;
      expect(reserve(), isNotNull);
      expect(store.requests().where((row) => row['sent_at_ms'] != null), hasLength(10));
    });

    test('extraction and organization share token reservations, while chat retains a separate receipt', () {
      for (final setting in [
        (category: 'extract', input: 6000, output: 800),
        (category: 'organize', input: 6000, output: 800),
        (category: 'extract', input: 6000, output: 800),
        (category: 'extract', input: 6000, output: 600),
      ]) {
        final request = reserve(category: setting.category, input: setting.input, output: setting.output)!;
        store.markRequestSent(request);
        store.finishRequest(request, terminal: 'network_error');
      }
      expect(reserve(input: 1, output: 0), isNull);
      expect(reserve(input: 0, output: 1), isNull);
      expect(reserve(category: 'organize', input: 0, output: 0), isNull);
      final chat = reserve(category: 'chat', input: 100000, output: 10000);
      expect(chat, isNotNull);
      store.markRequestSent(chat!);
      expect(store.requests().last['category'], 'chat');
    });

    test('the verified default peak estimate has a rolling 30-day cap and unknown providers remain unknown', () {
      final request = reserve()!;
      expect(store.requests().single['reserved_cny'], closeTo(.0184, 1e-12));
      store.markRequestSent(request);
      // A frozen reported overrun exercises the monetary gate independently
      // of the lower normal daily token allowance; it is not a model run.
      store.recordUsage(request, usage(input: 1500000, read: 0, write: 0, output: 0));
      store.finishRequest(request, terminal: 'complete');
      expect(store.requests().single['estimated_cny'], 3);
      now += 86400000;
      expect(reserve(), isNull);
      final other = reserve(provider: 'configured-provider', model: 'configured-model');
      expect(other, isNotNull);
      store.markRequestSent(other!);
      store.recordUsage(other, {...usage(input: 10, read: 0, write: 0, output: 2),
        'provider': 'configured-provider', 'model': 'configured-model'});
      store.finishRequest(other, terminal: 'complete');
      expect(store.requests().last['reserved_cny'], isNull);
      expect(store.requests().last['estimated_cny'], isNull);
      now += 29 * 86400000;
      expect(reserve(), isNotNull);
    });

    test('restart releases an unsent reservation but retains observed and uncertain attempts', () {
      final unsent = reserve()!;
      final sent = reserve()!;
      store.markRequestSent(sent);
      final unknown = reserve()!;
      now += 100;
      store.markRequestUncertain(unknown);
      final uncertainAt = now;
      reopen();
      final receipts = {for (final row in store.requests()) row['id']: row};
      expect(receipts[unsent]!['state'], 'released');
      expect(receipts[unsent]!['sent_at_ms'], isNull);
      expect(receipts[sent]!['terminal'], 'interrupted');
      expect(receipts[sent]!['sent_at_ms'], isNotNull);
      expect(receipts[unknown]!['terminal'], 'dispatch_unknown');
      expect(receipts[unknown]!['sent_at_ms'], isNull);
      expect(receipts[unknown]!['uncertain_at_ms'], uncertainAt);
      final third = reserve();
      expect(third, isNotNull);
      expect(reserve(), isNull);
      store.finishRequest(unknown, terminal: 'not_sent');
      expect(reserve(), isNotNull, reason: 'an explicit dispatched=false acknowledgement releases the unknown attempt');
    });

    test('unknown dispatch can gain observed-send evidence without inventing an earlier send time', () {
      final request = reserve()!;
      store.markRequestUncertain(request);
      final uncertainAt = now;
      store.finishRequest(request, terminal: 'network_error');
      expect(store.requests().single['terminal'], 'dispatch_unknown');
      now += 200;
      store.markRequestSent(request);
      expect(store.requests().single['sent_at_ms'], now);
      expect(store.requests().single['uncertain_at_ms'], uncertainAt);
      expect(store.requests().single['terminal'], isNull);
      expect(() => store.finishRequest(request, terminal: 'not_sent'), throwsA(isA<DshRemoteException>()));
      store.recordUsage(request, usage(input: 2, read: 0, write: 0, output: 1));
      store.finishRequest(request, terminal: 'complete');
      expect(store.requests().single['state'], 'finished');
      expect(store.requests().single['terminal'], 'complete');
    });
  });
}
