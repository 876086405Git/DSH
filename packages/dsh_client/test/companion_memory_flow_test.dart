import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

const manualCard = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

int estimate(String text) => (text.runes.length / 4).ceil();

MemoryRow create(MemoryRow source, {String? text, String? quote, List<String>? keywords}) => {
  'op': 'create',
  'kind': 'fact',
  'text': text ?? source['text'],
  'keywords': ?keywords,
  'evidence': [
    {'message_id': source['id'], 'quote': quote ?? source['text']},
  ],
};

MemoryRow parsed(MemoryBatch batch, [List<MemoryRow> operations = const []]) => parseExtractionProposal(
  jsonEncode({
    'schema_version': 2,
    'batch_id': batch.id,
    'covered_message_ids': [for (final source in batch.sources) source['id']],
    'operations': operations,
    'completion': 'complete',
  }),
  batch,
);

MemoryRow usage({int? input, int? read, int? write, int? output, bool complete = true}) => {
  'provider': 'deepseek',
  'model': 'deepseek-flash',
  'start_usage': {'input_tokens': 999, 'output_tokens': 1},
  'final_usage': {
    'input_tokens': ?input,
    'cache_read_input_tokens': ?read,
    'cache_creation_input_tokens': ?write,
    'output_tokens': ?output,
    'vendor_extension': {'counter': 7},
  },
  'start_event': 'message_start',
  'final_event': 'message_delta',
  'usage_semantics': 'cumulative',
  'input_uncached': input,
  'input_cache_read': read,
  'input_cache_write': write,
  'output_tokens': output,
  'stop_reason': 'end_turn',
  'terminal': complete ? 'complete' : 'incomplete',
  'complete': complete,
  'http_status': 200,
};

MemoryRow normalizedUsage(List<MemoryRow> events) => {
  'provider': 'deepseek',
  'model': 'deepseek-flash',
  'start_usage': null,
  'final_usage': null,
  'start_event': null,
  'final_event': null,
  'usage_semantics': 'unknown',
  'input_uncached': null,
  'input_cache_read': null,
  'input_cache_write': null,
  'output_tokens': null,
  'stop_reason': null,
  'terminal': 'incomplete',
  'complete': false,
  'http_status': null,
  'runtime_normalized_usage': events,
  'runtime_normalized_usage_semantics': 'runtime-normalized-events',
};

MemoryRow hostReceipt({
  String id = 'physical-1',
  String call = 'call-1',
  int revision = 2,
  List<String> requestIds = const ['rpc-1'],
  String phase = 'finished',
  String observation = 'fetch-invoked',
  MemoryRow? raw,
}) {
  final data = raw ?? usage(input: 100, read: 25, write: 0, output: 37);
  return {
    'receiptId': id,
    'callId': call,
    'revision': revision,
    'requestIds': requestIds,
    'provider': data['provider'],
    'model': data['model'],
    'phase': phase,
    'observation': observation,
    'dispatched': observation == 'adapter-invoked' ? null : observation == 'fetch-invoked',
    'dispatchAtMs': observation == 'fetch-invoked' ? 900000 : null,
    'handoffAtMs': 899000,
    'physicalRequests': observation == 'adapter-invoked'
        ? null
        : observation == 'fetch-invoked'
        ? 1
        : 0,
    'terminal': data['terminal'],
    'complete': data['complete'],
    'httpStatus': data['http_status'],
    'errorCode': null,
    'usage': data,
  };
}

MemoryRow hostSnapshot(
  MemoryRow delivery,
  List<MemoryRow> receipts, {
  int revision = 5,
  String state = 'settled',
  List<String> gaps = const [],
}) {
  final calls = receipts.map((row) => row['callId']).toSet();
  final active = receipts.where((row) => row['phase'] == 'active').map((row) => row['callId']).toSet();
  final physical = gaps.isNotEmpty || receipts.any((row) => row['physicalRequests'] == null)
      ? null
      : receipts.fold<int>(0, (sum, row) => sum + (row['physicalRequests'] as int));
  return {
    'v': 1,
    'instanceId': delivery['instance_id'],
    'sessionId': delivery['session_id'],
    'requestId': delivery['request_id'],
    'binding': {
      'archiveId': delivery['archive_id'],
      'controlRevision': delivery['control_revision'],
      'historyAfterSeq': delivery['history_after_seq'],
    },
    'state': state,
    'complete': state == 'settled' && calls.isNotEmpty && gaps.isEmpty && physical != null,
    'revision': revision,
    'gaps': gaps,
    'observedAdapterCalls': calls.length,
    'activeCalls': active.length,
    'physicalRequests': physical,
    'receipts': receipts,
  };
}

MemoryRow unknownHostSnapshot(MemoryRow delivery, {String? instanceId, String gap = 'not-retained'}) => {
  'v': 1,
  'instanceId': instanceId ?? delivery['instance_id'],
  'sessionId': delivery['session_id'],
  'requestId': delivery['request_id'],
  'binding': null,
  'state': 'unknown',
  'complete': false,
  'revision': 0,
  'gaps': [gap],
  'observedAdapterCalls': 0,
  'activeCalls': 0,
  'physicalRequests': null,
  'receipts': <MemoryRow>[],
};

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1000000;
  var nextId = 0;
  final forcedIds = <String>[];
  String id() =>
      forcedIds.isEmpty ? '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}' : forcedIds.removeAt(0);
  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: id);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow submit(
    String messageId,
    String text, {
    String session = 'room-a',
    String role = 'user',
    String scope = 'real',
    int? saidAt,
    int offset = 480,
  }) => store.submitMessage(
    id: messageId,
    sessionId: session,
    text: text,
    role: role,
    scope: scope,
    saidAtUtc: saidAt ?? now,
    offsetMinutes: offset,
  );
  MemoryBatch batch() => store.nextBatch(forceTail: true, estimateTokens: estimate)!;
  List<MemoryRow> events() => [
    for (final row in database.select('SELECT * FROM memory_events ORDER BY seq')) {...row},
  ];
  String? reserve({
    String category = 'extract',
    String provider = 'deepseek',
    String model = 'deepseek-flash',
    int input = 6000,
    int output = 800,
  }) => store.reserveRequest(
    category: category,
    provider: provider,
    model: model,
    inputTokens: input,
    outputTokens: output,
  );

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
      expect(
        store.commitExtraction(
          restored,
          parsed(restored, [
            create(restored.sources.single, keywords: ['长笛']),
          ]),
        ),
        isTrue,
      );
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
      expect(
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            {
              'op': 'create',
              'kind': 'fact',
              'text': '住上海，喝无糖咖啡',
              'keywords': ['上海', '咖啡'],
              'evidence': [
                {'message_id': a['id'], 'quote': a['text']},
                {'message_id': b['id'], 'quote': b['text']},
              ],
            },
          ]),
        ),
        isTrue,
      );
      final cardId = store.cards().single['id'];
      // A frozen second proof group, as a later merge would retain; the action
      // under test is the production source-edit invalidation, not merge.
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
        cardId,
        'independent',
        'c',
        1,
        '我住上海，喝无糖咖啡',
      ]);
      store.editMessage(id: 'a', expectedSourceRev: 1, text: '我搬到了杭州');
      final remaining = store.cards().single;
      expect(remaining['eligible'], isTrue);
      expect((remaining['evidence'] as List).map((entry) => (entry as Map)['message_id']), ['c']);
      expect(
        database.select('SELECT * FROM memory_card_sources WHERE message_id=?', ['b']),
        isEmpty,
        reason: 'the surviving half of an invalid proof is not an independent proof',
      );
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
      store.commitExtraction(
        first,
        parsed(first, [
          create(newest, text: '咖啡喝无糖', keywords: ['咖啡', '长笛']),
        ]),
      );
      final cardId = store.cards().single['id'];
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [cardId, 'older-proof', 'a', 1, '咖啡我喝无糖。']);
      expect(store.cards().single['current_basis_seq'], 3);
      now += 100;
      store.editMessage(id: 'newest', expectedSourceRev: 1, text: '那句不成立');
      final remaining = store.cards().single;
      expect(remaining['current_basis_seq'], 1);
      expect(remaining['source_at_ms'], originalAt);
      expect(remaining['keywords'], ['咖啡']);
      expect(
        selectMemoryContext(
          store.cards(),
          input: '长笛',
          nowMs: now,
          controlRevision: store.archive['control_revision'] as int,
        ).ids,
        isEmpty,
      );
      store.editMessage(id: 'middle', expectedSourceRev: 1, text: '小露，咖啡我现在改喝半糖。');
      final next = batch();
      final middle = next.sources.singleWhere((source) => source['id'] == 'middle');
      expect(
        store.commitExtraction(
          next,
          parsed(next, [
            {
              ...create(middle, text: '咖啡现在喝半糖', keywords: ['咖啡']),
              'op': 'replace',
              'target_id': cardId,
              'expected_row_rev': remaining['row_rev'],
              'change_kind': 'new_current_value',
            },
          ]),
        ),
        isTrue,
      );
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
      store.saveManual(
        const CompanionMemory(id: manualCard, text: '本人手改的现值'),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
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
        store.saveManual(
          CompanionMemory(id: id(), text: '第$n张 ${List.filled(490, '字').join()}'),
          expectedRowRev: null,
          currentValueChange: true,
          realityKnown: true,
        );
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
      test(
        'expired existing context is not restored after ${invalidFirst ? 'a format failure' : 'a wait and restart'}',
        () {
          store.saveManual(
            CompanionMemory(
              id: manualCard,
              text: '暂时喝半糖咖啡',
              keywords: const ['咖啡'],
              expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true),
            ),
            expectedRowRev: null,
            currentValueChange: true,
            realityKnown: true,
          );
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
        },
      );
    }

    test('an expired later value cannot permanently skip a supported older create', () {
      final old = submit('old', '我喝无糖咖啡');
      store.saveManual(
        CompanionMemory(
          id: manualCard,
          text: '暂时喝半糖咖啡',
          keywords: const ['咖啡'],
          expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true),
        ),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      now += 1000;
      final claimed = batch();
      expect(claimed.existing, isEmpty);
      expect(
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            create(old, keywords: ['咖啡']),
          ]),
        ),
        isTrue,
      );
      expect(store.cards().where((card) => card['id'] != manualCard).single['text'], '我喝无糖咖啡');
      expect(events().single['reason'], isNull);
      expect(
        selectMemoryContext(
          store.cards(),
          input: '咖啡',
          nowMs: now,
          controlRevision: store.archive['control_revision'] as int,
        ).ids,
        isNot(contains(manualCard)),
      );
    });

    test('a replacement target expiring during the request cannot be revived by its old snapshot', () {
      store.saveManual(
        CompanionMemory(
          id: manualCard,
          text: '暂时喝半糖咖啡',
          keywords: const ['咖啡'],
          expiresAt: DateTime.fromMillisecondsSinceEpoch(now + 1000, isUtc: true),
        ),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      final source = submit('u1', '我现在咖啡喝无糖');
      final claimed = batch();
      final result = parsed(claimed, [
        {
          ...create(source, keywords: ['咖啡']),
          'op': 'replace',
          'target_id': manualCard,
          'expected_row_rev': 1,
        },
      ]);
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
      expect(
        estimate('$companionMemoryExtractionPrompt\n${jsonEncode(extractionInput(first, processedAtUtc: now))}'),
        lessThanOrEqualTo(6000),
      );
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
      expect(
        store.commitExtraction(
          initial,
          parsed(initial, [
            create(initial.sources.single, keywords: ['长笛']),
          ]),
        ),
        isTrue,
      );
      submit('old', '明天去公园', session: 'room-b');
      submit('control', '忘了之前那事', session: 'room-b');
      database.execute('UPDATE memory_archive SET control_revision=control_revision+1,history_after_seq=3');
      store.editMessage(id: 'old', expectedSourceRev: 1, text: '后天去公园');
      submit('new', '今天去书店', session: 'room-a');
      expect(store.messages(), hasLength(4));
      expect(store.messages(forModel: true).map((row) => row['id']), ['new']);
      expect(store.messages(sessionId: 'room-b', limit: 1).single['id'], 'control');
      expect(batch().sources.map((row) => row['id']), ['new']);
      expect(
        store.cards().single['text'],
        '我学长笛',
        reason: 'the cutoff does not invalidate an independent existing card',
      );
    });
  });

  group('current values and atomic proposal commit', () {
    test('illegal generated controls fail before commit; old malformed cards are excluded from selection', () {
      submit('u1', '我学长笛\u0007');
      final claimed = batch();
      for (final code in [0, 8, 11, 12, 31, 127]) {
        expect(
          () => parsed(claimed, [create(claimed.sources.single, text: '长笛${String.fromCharCode(code)}')]),
          throwsFormatException,
        );
      }
      expect(store.cards(), isEmpty);
      expect(events().single['state'], 'pending');
      expect(store.messages().single['text'], '我学长笛\u0007');
      expect(
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            create(claimed.sources.single, text: '我学长笛', keywords: ['长笛']),
          ]),
        ),
        isTrue,
      );
      expect((store.cards().single['evidence'] as List).single, containsPair('quote', '我学长笛\u0007'));
      // Frozen pre-fix persisted row: exercise store read -> production selector.
      database.execute('UPDATE memory_cards SET text=?', ['长笛\u0000']);
      expect(
        selectMemoryContext(
          store.cards(),
          input: '长笛',
          nowMs: now,
          controlRevision: store.archive['control_revision'] as int,
        ).ids,
        isEmpty,
      );
    });

    test('automatic cards do not inherit the old manual 512-scalar write limit', () {
      final text = '长笛${List.filled(598, '字').join()}';
      submit('u1', text);
      final claimed = batch();
      expect(
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            create(claimed.sources.single, keywords: ['长笛']),
          ]),
        ),
        isTrue,
      );
      expect((store.cards().single['text'] as String).runes.length, 600);
      expect(
        selectMemoryContext(
          store.cards(),
          input: '长笛',
          nowMs: now,
          controlRevision: store.archive['control_revision'] as int,
        ).ids,
        [store.cards().single['id']],
      );
    });

    for (final wording in ['我明天面试之前会再看材料。', '我以前喝半糖，现在面试前改喝无糖。']) {
      test('episode wording never grants an old targetless create a current-value bypass: $wording', () {
        submit('old', wording);
        store.saveManual(
          const CompanionMemory(id: manualCard, text: '我的面试计划已经改了', keywords: ['面试']),
          expectedRowRev: null,
          currentValueChange: true,
          realityKnown: true,
        );
        final claimed = batch();
        final operation = {
          ...create(claimed.sources.single, keywords: ['面试']),
          'kind': 'episode',
        };
        expect(store.commitExtraction(claimed, parsed(claimed, [operation])), isTrue);
        expect(store.cards(), hasLength(1));
        expect(store.cards().single['id'], manualCard);
        expect(events().single['reason'], contains('possible_current_conflict'));
      });
    }

    test('an independent supported episode remains current without guessing tense from its words', () {
      submit('u1', '我明天面试之前会再看材料。');
      final claimed = batch();
      store.commitExtraction(
        claimed,
        parsed(claimed, [
          {
            ...create(claimed.sources.single, keywords: ['面试']),
            'kind': 'episode',
          },
        ]),
      );
      expect(store.cards().single['status'], 'current');
      expect(store.cards().single['text'], '我明天面试之前会再看材料。');
    });

    test('editing an old statement cannot undo a later independent current value', () {
      submit('m', '小鹿，我现在喝咖啡要无糖。');
      final original = batch();
      store.commitExtraction(
        original,
        parsed(original, [
          create(original.sources.single, text: '咖啡要无糖', keywords: ['咖啡']),
        ]),
      );
      submit('n', '我现在改喝半糖咖啡了。');
      final newer = batch();
      final card = newer.existing.single;
      MemoryRow replacement(MemoryBatch input, String text) => {
        ...create(input.sources.single, text: text, keywords: ['咖啡']),
        'op': 'replace',
        'target_id': card['id'],
        'expected_row_rev': input.existing.single['row_rev'],
        'change_kind': 'new_current_value',
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
          expectedRowRev: null,
          currentValueChange: true,
          realityKnown: true,
        );
        if (manualBeforeClaim) changeCurrent();
        var claimed = batch();
        if (!manualBeforeClaim) {
          changeCurrent();
          expect(
            store.commitExtraction(claimed, parsed(claimed)),
            isFalse,
            reason: 'a current manual edit invalidates all already prepared replies and extraction',
          );
          claimed = batch();
        }
        final source = claimed.sources.single;
        expect(
          store.commitExtraction(
            claimed,
            parsed(claimed, [
              create(source, text: '咖啡要无糖', quote: '我喝无糖咖啡'),
              create(source, text: '在学手风琴', quote: '在学手风琴', keywords: ['手风琴']),
            ]),
          ),
          isTrue,
        );
        expect(store.cards().map((card) => card['text']), unorderedEquals(['我现在喝半糖咖啡', '在学手风琴']));
        expect(events().single['reason'], contains('possible_current_conflict'));
        expect(events().single['reason'], isNot(contains('手风琴')));
      });
    }

    test('a captured target revision changed by a manual edit makes the whole result obsolete', () {
      submit('u1', '咖啡喝无糖');
      store.saveManual(
        const CompanionMemory(id: manualCard, text: '咖啡喝半糖', keywords: ['咖啡']),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      final claimed = batch();
      final proposal = parsed(claimed, [
        {
          ...create(claimed.sources.single, keywords: ['咖啡']),
          'op': 'replace',
          'target_id': manualCard,
          'expected_row_rev': 1,
        },
      ]);
      store.saveManual(
        const CompanionMemory(id: manualCard, text: '咖啡喝全糖', keywords: ['咖啡']),
        expectedRowRev: 1,
        currentValueChange: true,
        realityKnown: true,
      );
      expect(store.commitExtraction(claimed, proposal), isFalse);
      expect(store.cards().single['text'], '咖啡喝全糖');
      expect(events().single['state'], 'pending');
      expect(events().single['format_failures'], 0);
    });

    test('a write failure rolls back cards, complete proof groups, coverage and cursor together', () {
      submit('u1', '我学长笛');
      final claimed = batch();
      final proposal = parsed(claimed, [
        create(claimed.sources.single, keywords: ['长笛']),
      ]);
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
        final raw = correction
            ? exactA4.replaceAll('以前喝半糖，现在咖啡改喝无糖了。', wording).replaceAll('new_current_value', 'correction_of_error')
            : exactA4;
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

  group('immediate controls and deletion', () {
    MemoryRow remember(
      String messageId,
      String text, {
      List<String> keywords = const [],
      String? cardText,
      String kind = 'fact',
      MemoryRow? followup,
    }) {
      final source = submit(messageId, text);
      final claimed = batch();
      expect(
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            {...create(source, text: cardText, keywords: keywords), 'kind': kind, 'followup': ?followup},
          ]),
        ),
        isTrue,
      );
      return store.cards().singleWhere(
        (card) => (card['evidence'] as List).any((value) => (value as Map)['message_id'] == messageId),
      );
    }

    MemorySelection select(String input, {Set<String> explicit = const {}}) => selectMemoryContext(
      store.cards(),
      input: input,
      nowMs: now,
      controlRevision: store.archive['control_revision'] as int,
      explicitTopicIds: explicit,
    );

    CompanionMigrationSnapshot legacy() => CompanionMigrationSnapshot.fromJson({
      'v': 1,
      'storeId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'revision': 2,
      'memoryRevision': 2,
      'memories': [
        {
          'id': manualCard,
          'kind': 'fact',
          'text': '明天去听演出',
          'keywords': <String>[],
          'pinned': false,
          'source': {'kind': 'manual'},
          'expiresAt': null,
          'createdAt': 1000,
          'updatedAt': 2000,
        },
      ],
    });

    test('an explicit correction replaces the wrong fact and its derivatives with the whole new source', () {
      final before = remember('wrong', '我咖啡喝半糖。', keywords: ['咖啡', '半糖']);
      database.execute(
        '''
        INSERT INTO memory_cards(id,row_rev,kind,text,eligible,manual,topic_id,source_at_ms,created_at_ms,updated_at_ms)
        SELECT 'wrong-derived',1,'fact','我咖啡喝半糖。半糖口味的错误派生',1,0,topic_id,source_at_ms,created_at_ms,updated_at_ms
        FROM memory_cards WHERE id=?
      ''',
        [before['id']],
      );
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
        'wrong-derived',
        'derived-proof',
        'wrong',
        1,
        '我咖啡喝半糖。',
      ]);
      submit('waiting', '今天练长笛');
      final late = batch();
      final originalControl = store.archive['control_revision'] as int;
      const statement = '咖啡改成我咖啡一直喝无糖。';
      final correction = submit('correction', statement);
      store.correctFromMessage(
        cardId: before['id'] as String,
        expectedRowRev: 1,
        messageId: 'correction',
        expectedSourceRev: 1,
        text: '我咖啡一直喝无糖。',
      );
      final changed = store.cards().single;
      expect(changed['text'], '我咖啡一直喝无糖。');
      expect(changed['status'], 'current');
      expect(changed['manual'], isFalse);
      expect(changed['current_basis_seq'], correction['first_seq']);
      expect(changed['keywords'], ['咖啡']);
      expect(changed['followup'], isNull);
      expect(changed['evidence'], [allOf(containsPair('message_id', 'correction'), containsPair('quote', statement))]);
      expect(database.select('SELECT * FROM memory_card_sources WHERE message_id=?', ['wrong']), isEmpty);
      expect(store.messages().first['text'], '我咖啡喝半糖。', reason: 'a correction is not an unrequested raw-chat deletion');
      expect(store.messages().last['extraction_state'], 'done');
      expect(store.archive['control_revision'], originalControl + 1);
      expect(store.commitExtraction(late, parsed(late)), isFalse);
      expect(batch().sources.map((source) => source['id']), ['waiting']);
      expect(select('咖啡').ids, [changed['id']]);
      // Re-delivery of the same command is idempotent, despite its old row CAS.
      store.correctFromMessage(
        cardId: before['id'] as String,
        expectedRowRev: 1,
        messageId: 'correction',
        expectedSourceRev: 1,
        text: '我咖啡一直喝无糖。',
      );
      expect(store.cards().single['row_rev'], changed['row_rev']);
      expect(store.archive['control_revision'], originalControl + 1);
    });

    test('correction rejects stale versions, an older logical statement and unproved scope', () {
      submit('old-correction', '咖啡改成我咖啡一直喝无糖。');
      store.saveManual(
        const CompanionMemory(id: manualCard, text: '我咖啡现在喝半糖。', keywords: ['咖啡']),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      final originalControl = store.archive['control_revision'];
      expect(
        () => store.correctFromMessage(
          cardId: manualCard,
          expectedRowRev: 1,
          messageId: 'old-correction',
          expectedSourceRev: 1,
          text: '我咖啡一直喝无糖。',
        ),
        throwsA(isA<DshRemoteException>()),
      );
      submit('ambiguous', '你记错了，我一直喝无糖。');
      expect(
        () => store.correctFromMessage(
          cardId: manualCard,
          expectedRowRev: 1,
          messageId: 'ambiguous',
          expectedSourceRev: 1,
          text: '我一直喝无糖。',
        ),
        throwsA(isA<DshRemoteException>()),
      );
      submit('current', '咖啡改成我咖啡一直喝无糖。');
      expect(
        () => store.correctFromMessage(
          cardId: manualCard,
          expectedRowRev: 2,
          messageId: 'current',
          expectedSourceRev: 1,
          text: '我咖啡一直喝无糖。',
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(
        () => store.correctFromMessage(
          cardId: manualCard,
          expectedRowRev: 1,
          messageId: 'current',
          expectedSourceRev: 2,
          text: '我咖啡一直喝无糖。',
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(
        () => store.correctFromMessage(
          cardId: manualCard,
          expectedRowRev: 1,
          messageId: 'current',
          expectedSourceRev: 1,
          text: '来源里没有这句',
        ),
        throwsA(isA<DshRemoteException>()),
      );
      for (final scope in ['assistant', 'story']) {
        submit(
          scope,
          '咖啡改成我咖啡一直喝无糖。',
          role: scope == 'assistant' ? 'assistant' : 'user',
          scope: scope == 'story' ? 'story' : 'real',
        );
        expect(
          () => store.correctFromMessage(
            cardId: manualCard,
            expectedRowRev: 1,
            messageId: scope,
            expectedSourceRev: 1,
            text: '我咖啡一直喝无糖。',
          ),
          throwsA(isA<DshRemoteException>()),
        );
      }
      expect(store.cards().single['text'], '我咖啡现在喝半糖。');
      expect(store.archive['control_revision'], originalControl);
      expect(
        () => store.correctFromMessage(
          cardId: manualCard,
          expectedRowRev: 1,
          messageId: 'current',
          expectedSourceRev: 1,
          text: '我咖啡\u0007',
        ),
        throwsFormatException,
      );
    });

    test('cancellation blocks a late reply and old re-extraction while a later independent plan can be created', () {
      submit('old', '小鹿，我周四有面试。');
      final plan = remember(
        'plan',
        '我周四有面试，结束后问问我。',
        keywords: ['面试'],
        kind: 'episode',
        followup: {'local_date': null, 'precision': 'unspecified', 'wording': '结束后问问我', 'basis': 'explicit_invitation'},
      );
      store.editMessage(id: 'old', expectedSourceRev: 1, text: '小露，我周四有面试。');
      final late = batch();
      final cancellation = submit('cancel', '面试取消了');
      store.applyControl(topicIds: [plan['topic_id'] as String], kind: 'cancel', controlMessageId: 'cancel');
      final cancelled = store.cards().single;
      expect(cancelled['text'], plan['text']);
      expect(cancelled['plan_state'], 'cancelled');
      expect(cancelled['followup'], isNull);
      expect(cancelled['current_basis_seq'], cancellation['first_seq']);
      expect(cancelled['evidence'], plan['evidence']);
      expect(store.archive['history_after_seq'], 0);
      expect(store.commitExtraction(late, parsed(late)), isFalse);
      expect(select('面试', explicit: {plan['topic_id'] as String}).ids, isEmpty);
      final retry = batch();
      expect(retry.existing, isEmpty, reason: '09s has no cancellation field, so the old future wording is not sent');
      expect(
        store.commitExtraction(
          retry,
          parsed(retry, [
            create(retry.sources.single, keywords: ['面试']),
          ]),
        ),
        isTrue,
      );
      expect(store.cards(), hasLength(1));
      expect(
        events().firstWhere((event) => event['seq'] == retry.sources.single['event_seq'])['reason'],
        contains('possible_current_conflict'),
      );
      final fresh = remember(
        'new-plan',
        '我重新约了下周面试，结束后问问我。',
        keywords: ['面试'],
        kind: 'episode',
        followup: {'local_date': null, 'precision': 'unspecified', 'wording': '结束后问问我', 'basis': 'explicit_invitation'},
      );
      expect(fresh['id'], isNot(plan['id']));
      expect(fresh['plan_state'], isNull);
      expect(select('面试').ids, [fresh['id']]);
      expect(store.cards().firstWhere((card) => card['id'] == plan['id'])['plan_state'], 'cancelled');
    });

    test('removing one proof group cannot erase a later explicit cancellation order', () {
      submit('early', '我周四有面试');
      now += 100;
      final plan = remember('later', '我周四有面试', keywords: ['面试']);
      // Frozen independent group, representing a completed earlier merge.
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
        plan['id'],
        'independent-early',
        'early',
        1,
        '我周四有面试',
      ]);
      store.applyControl(topicIds: [plan['topic_id'] as String], kind: 'cancel');
      final cancelBasis = store.cards().single['current_basis_seq'];
      now += 100;
      store.editMessage(id: 'later', expectedSourceRev: 1, text: '小露，我周四有面试');
      final remaining = store.cards().single;
      expect(remaining['current_basis_seq'], cancelBasis);
      expect(remaining['source_at_ms'], 1000000);
      expect(remaining['plan_state'], 'cancelled');
      expect((remaining['evidence'] as List).single, containsPair('message_id', 'early'));
      final claimed = batch();
      expect(claimed.existing, isEmpty);
      store.commitExtraction(
        claimed,
        parsed(claimed, [
          create(claimed.sources.single, keywords: ['面试']),
        ]),
      );
      expect(store.cards(), hasLength(1));
      expect(select('面试').ids, isEmpty);
    });

    test('less, never and explicit reopening retain distinct persistent behavior', () {
      store.saveManual(
        const CompanionMemory(
          id: manualCard,
          text: '我希望你先听我讲完，再给建议',
          kind: 'preference',
          pinned: true,
          keywords: ['先听', '讲完', '建议'],
        ),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      final topic = store.cards().single['topic_id'] as String;
      expect(select('你好').ids, [manualCard]);
      store.applyControl(topicIds: [topic], kind: 'less');
      expect(store.archive['history_after_seq'], 0);
      expect(select('你好').ids, isEmpty);
      expect(select('给我建议').ids, [manualCard]);
      store.applyControl(topicIds: [topic], kind: 'never');
      expect(store.archive['history_after_seq'], greaterThan(0));
      expect(select('给我建议').ids, isEmpty);
      expect(select('聊聊建议', explicit: explicitMemoryTopics('聊聊建议', store.cards())).ids, [manualCard]);
      reopen();
      expect(store.cards().single['topic_mode'], 'never');
      expect(select('给我建议').ids, isEmpty);
      final boundary = store.archive['history_after_seq'];
      store.applyControl(topicIds: [topic], kind: 'normal');
      expect(store.archive['history_after_seq'], boundary);
      expect(select('你好').ids, [manualCard]);
    });

    for (final mode in ['less', 'never']) {
      test('a new create inherits a unique $mode topic without taking an independent fact from the same source', () {
        final clinic = remember('old-clinic', '我周五复诊。', keywords: ['复诊']);
        store.applyControl(topicIds: [clinic['topic_id'] as String], kind: mode);
        final source = submit('new', '我周六复诊，也去公园。');
        final claimed = batch();
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            create(source, text: '我周六复诊', quote: '我周六复诊'), // Omitted keywords cannot bypass control.
            create(source, text: '也去公园', quote: '也去公园', keywords: ['公园']),
          ]),
        );
        final newClinic = store.cards().singleWhere((card) => card['text'] == '我周六复诊');
        final park = store.cards().singleWhere((card) => card['text'] == '也去公园');
        expect(newClinic['topic_id'], clinic['topic_id']);
        expect(newClinic['topic_mode'], mode);
        expect(park['topic_id'], isNot(clinic['topic_id']));
        expect(park['topic_mode'], 'normal');
        expect(select('公园').ids, [park['id']]);
        if (mode == 'never') expect(select('复诊').ids, isEmpty);
      });
    }

    test('a create matching multiple controlled topics is skipped without skipping disjoint operations', () {
      final clinic = remember('clinic', '我周五复诊', keywords: ['复诊']);
      final music = remember('music', '我周五上琴课', keywords: ['琴课']);
      store.applyControl(topicIds: [clinic['topic_id'] as String], kind: 'never');
      store.applyControl(topicIds: [music['topic_id'] as String], kind: 'less');
      final source = submit('new', '我复诊后上琴课，也会去公园。');
      final claimed = batch();
      store.commitExtraction(
        claimed,
        parsed(claimed, [
          create(source, text: '复诊后上琴课', quote: '我复诊后上琴课'),
          create(source, text: '也会去公园', quote: '也会去公园', keywords: ['公园']),
        ]),
      );
      expect(store.cards(), hasLength(3));
      expect(events().last['reason'], contains('ambiguous_controlled_topic'));
      expect(store.cards().any((card) => card['text'] == '复诊后上琴课'), isFalse);
      expect(select('公园').ids, hasLength(1));
    });

    test(
      'forget removes controlled working copies, retains disjoint proof and cuts global history through the command',
      () {
        final mixed = submit('mixed', '我周五复诊，周六去公园，我喝无糖咖啡。', session: 'room-a');
        final independent = submit('independent', '我喝无糖咖啡。', session: 'room-b');
        final initial = batch();
        store.commitExtraction(
          initial,
          parsed(initial, [
            create(mixed, text: '我周五复诊', quote: '我周五复诊', keywords: ['复诊']),
            create(mixed, text: '周六去公园', quote: '周六去公园', keywords: ['公园']),
            create(mixed, text: '我周五复诊，周六去公园', keywords: ['复诊', '公园']),
            create(independent, keywords: ['咖啡']),
          ]),
        );
        final clinic = store.cards().singleWhere((card) => card['text'] == '我周五复诊');
        final coffee = store.cards().singleWhere((card) => card['text'] == '我喝无糖咖啡。');
        // A broad quote can support an independent fact. Keeping the original
        // chat must not withdraw this group's authentic proof of coffee.
        database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
          coffee['id'],
          'broad-coffee-proof',
          'mixed',
          1,
          mixed['text'],
        ]);
        final coffeeBefore = store.cards().singleWhere((card) => card['id'] == coffee['id']);
        for (var i = 0; i < 3; i++) {
          expect(reserve(), isNotNull);
        }
        expect(reserve(), isNull);
        submit('waiting', '以前那条尚未抽完', session: 'room-b');
        final late = batch();
        // The short keyword also names the composite card. Select the exact
        // clinic fact; cleanup must discover its dependent working copies.
        final command = submit('forget', '忘掉我周五复诊，聊天留着', session: 'room-a');
        expect(parseMemoryControl(command['text'] as String, store.cards())!['target_card_ids'], [clinic['id']]);
        submit('after', '这是控制之后独立新说的长笛', session: 'room-b');
        store.applyControl(topicIds: [clinic['topic_id'] as String], kind: 'forget', controlMessageId: 'forget');
        expect(store.cards().map((card) => card['text']), unorderedEquals(['周六去公园', '我喝无糖咖啡。']));
        expect(
          database
              .select("SELECT card_id FROM memory_card_sources WHERE instr(quote,'复诊')>0")
              .map((row) => row['card_id']),
          [coffee['id']],
        );
        expect(store.cards().singleWhere((card) => card['id'] == coffee['id']), coffeeBefore);
        expect(select('咖啡').block, isNot(contains('复诊')));
        expect(store.requests(), hasLength(3), reason: 'immediate control is not an auxiliary model request');
        expect(store.messages().first['text'], mixed['text']);
        expect(store.archive['history_after_seq'], command['first_seq']);
        expect(store.messages(forModel: true).map((source) => source['id']), ['after']);
        expect(store.commitExtraction(late, parsed(late)), isFalse);
        expect(
          select('咖啡').ids,
          hasLength(1),
          reason: 'the archive history boundary does not invalidate independent cards',
        );
        final revision = store.archive['control_revision'];
        reopen();
        store.applyControl(topicIds: [clinic['topic_id'] as String], kind: 'forget', controlMessageId: 'forget');
        expect(store.archive['control_revision'], revision);
        final edited = store.editMessage(id: 'mixed', expectedSourceRev: 1, text: '我周五复诊，周日去公园。');
        expect(edited['first_seq'], mixed['first_seq']);
        expect(store.messages().first['text'], '我周五复诊，周日去公园。');
        expect(store.messages().first['extraction_reason'], 'history_cutoff');
        expect(batch().sources.map((source) => source['id']), ['after']);
        expect(select('咖啡').ids, hasLength(1));
      },
    );

    test(
      'forget with raw deletion removes whole source groups before foreign keys and preserves independent proof',
      () {
        final mixed = submit('mixed', '我周五复诊，也去公园。');
        submit('independent-park', '我去公园。');
        final claimed = batch();
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            create(mixed, text: '我周五复诊', quote: '我周五复诊', keywords: ['复诊']),
            create(mixed, text: '我去公园', quote: '也去公园', keywords: ['公园']),
          ]),
        );
        final clinic = store.cards().singleWhere((card) => card['text'] == '我周五复诊');
        final park = store.cards().singleWhere((card) => card['text'] == '我去公园');
        database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
          park['id'],
          'independent-park-proof',
          'independent-park',
          1,
          '我去公园。',
        ]);
        submit('forget', '忘掉复诊，连原话也删');
        store.applyControl(
          topicIds: [clinic['topic_id'] as String],
          kind: 'forget',
          controlMessageId: 'forget',
          deleteChat: true,
        );
        expect(store.messages().map((source) => source['id']), ['independent-park', 'forget']);
        expect(store.cards().single['id'], park['id']);
        expect((store.cards().single['evidence'] as List).single, containsPair('message_id', 'independent-park'));
        expect(database.select('SELECT * FROM memory_events WHERE message_id=?', ['mixed']), isEmpty);
        expect(
          () => submit('mixed', '我周五复诊，也去公园。'),
          throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/deleted-source')),
        );
        expect(store.messages(forModel: true), isEmpty);
        expect(select('公园').ids, [park['id']]);
      },
    );

    for (final hasIndependentProof in [false, true]) {
      for (final deleteChat in [false, true]) {
        test('forget follows a known composite to another source ($hasIndependentProof, raw=$deleteChat)', () {
          final m1 = submit('m1', '我周五复诊');
          final m2 = submit('m2', '我周五复诊，也去公园');
          final m3 = submit('m3', '我去公园');
          final claimed = batch();
          store.commitExtraction(
            claimed,
            parsed(claimed, [
              create(m1, keywords: ['复诊']),
              create(m2, keywords: ['复诊', '公园']),
              create(m2, text: '我去公园', keywords: ['公园']),
            ]),
          );
          final a = store.cards().singleWhere((card) => card['text'] == m1['text']);
          final c = store.cards().singleWhere((card) => card['text'] == '我去公园');
          if (hasIndependentProof) {
            // As retained by a merge: this group is sufficient by itself.
            database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
              c['id'],
              'independent-park',
              m3['id'],
              1,
              m3['text'],
            ]);
          }
          if (deleteChat) {
            store.applyControl(topicIds: [a['topic_id'] as String], kind: 'forget', deleteChat: true);
          } else {
            store.deleteCard(id: a['id'] as String, expectedRowRev: a['row_rev'] as int);
          }
          expect(store.cards().map((card) => card['id']), hasIndependentProof || !deleteChat ? [c['id']] : isEmpty);
          expect(
            database
                .select("SELECT card_id FROM memory_card_sources WHERE instr(quote,'复诊')>0")
                .map((row) => row['card_id']),
            deleteChat ? isEmpty : [c['id']],
          );
          if (deleteChat && hasIndependentProof) {
            expect((store.cards().single['evidence'] as List).single, containsPair('message_id', 'm3'));
          }
          if (!deleteChat) {
            expect(
              (store.cards().single['evidence'] as List).map((proof) => (proof as Map)['message_id']),
              unorderedEquals(['m2', if (hasIndependentProof) 'm3']),
              reason: 'the park fact is independent of the removed composite, even when both quote m2',
            );
          }
          expect(store.messages().map((source) => source['id']), deleteChat ? ['m3'] : ['m1', 'm2', 'm3']);
          expect(database.select('SELECT * FROM memory_deleted_messages'), hasLength(deleteChat ? 2 : 0));
          reopen();
          expect(
            database
                .select("SELECT card_id FROM memory_card_sources WHERE instr(quote,'复诊')>0")
                .map((row) => row['card_id']),
            deleteChat ? isEmpty : [c['id']],
          );
        });
      }
    }

    for (final deleteChat in [false, true]) {
      test('a composite AND proof does not contaminate its independent unrelated member (raw=$deleteChat)', () {
        final x = submit('x', '我周五复诊');
        final y = submit('y', '我去公园');
        final claimed = batch();
        store.commitExtraction(
          claimed,
          parsed(claimed, [
            create(x, keywords: ['复诊']),
            {
              'op': 'create',
              'kind': 'fact',
              'text': '我周五复诊，也去公园',
              'keywords': ['复诊', '公园'],
              'evidence': [
                {'message_id': 'x', 'quote': x['text']},
                {'message_id': 'y', 'quote': y['text']},
              ],
            },
            create(y, keywords: ['公园']),
          ]),
        );
        final a = store.cards().singleWhere((card) => card['text'] == x['text']);
        final independent = store.cards().singleWhere((card) => card['text'] == y['text']);
        store.applyControl(topicIds: [a['topic_id'] as String], kind: 'forget', deleteChat: deleteChat);
        expect(store.cards(), [independent], reason: 'sharing only Y is not sharing the complete X+Y proof');
        expect(store.messages().map((source) => source['id']), deleteChat ? ['y'] : ['x', 'y']);
        expect(database.select('SELECT * FROM memory_card_sources WHERE message_id=?', ['y']), hasLength(1));
      });
    }

    test('independent groups cannot be combined to manufacture a copied AND proof', () {
      final x = submit('x', '我周五复诊');
      final y = submit('y', '我去公园');
      final claimed = batch();
      store.commitExtraction(
        claimed,
        parsed(claimed, [
          // Establish the older X-only fact before the newer X+Y composite,
          // so the current-value collision guard does not skip this fixture.
          create(x, text: '我有外出计划', keywords: []),
          {
            'op': 'create',
            'kind': 'fact',
            'text': '我周五复诊，也去公园',
            'keywords': ['复诊', '公园'],
            'evidence': [
              {'message_id': 'x', 'quote': x['text']},
              {'message_id': 'y', 'quote': y['text']},
            ],
          },
        ]),
      );
      final composite = store.cards().singleWhere((card) => card['text'] == '我周五复诊，也去公园');
      final independent = store.cards().singleWhere((card) => card['text'] == '我有外出计划');
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
        independent['id'],
        'independent-y',
        'y',
        1,
        y['text'],
      ]);
      final before = store.cards().singleWhere((card) => card['id'] == independent['id']);
      store.deleteCard(id: composite['id'] as String, expectedRowRev: composite['row_rev'] as int);
      expect(store.cards(), [before]);
      expect((store.cards().single['evidence'] as List), hasLength(2));
    });

    test('a removed old source revision is not used to delete its independently corrected current version', () {
      final x = submit('x', '我周五复诊');
      final mixed = submit('mixed', '我周五复诊，也去公园');
      final independent = submit('independent', '我去公园');
      final initial = batch();
      store.commitExtraction(
        initial,
        parsed(initial, [
          create(x, keywords: ['复诊']),
          create(mixed, keywords: ['复诊', '公园']),
          create(mixed, text: '我去公园', keywords: ['公园']),
        ]),
      );
      final a = store.cards().singleWhere((card) => card['text'] == x['text']);
      final park = store.cards().singleWhere((card) => card['text'] == '我去公园');
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
        park['id'],
        'independent-park',
        'independent',
        1,
        independent['text'],
      ]);
      store.editMessage(id: 'mixed', expectedSourceRev: 1, text: '我现在学长笛');
      final updated = batch();
      store.commitExtraction(
        updated,
        parsed(updated, [
          create(updated.sources.single, keywords: ['长笛']),
        ]),
      );
      final keep = store.cards().where((card) => card['id'] != a['id']).toList();
      expect(keep, hasLength(2));
      final beforeCards = store.cards(includeInactive: true);
      final beforeMessages = store.messages();
      final beforeArchive = store.archive;
      final beforeControls = store.topicControls();
      // A new fact from the edited ID does not prove its withdrawn old role.
      expect(
        () => store.applyControl(topicIds: [a['topic_id'] as String], kind: 'forget', deleteChat: true),
        throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/cleanup-source-unknown')),
      );
      expect(store.cards(includeInactive: true), beforeCards);
      expect(store.messages(), beforeMessages);
      expect(store.archive, beforeArchive);
      expect(store.topicControls(), beforeControls);
      expect(store.cards().where((card) => card['id'] != a['id']).toList(), keep);
      expect(store.messages().singleWhere((source) => source['id'] == 'mixed')['source_rev'], 2);
      expect(store.messages().singleWhere((source) => source['id'] == 'mixed')['text'], '我现在学长笛');
      expect(
        database.select('SELECT * FROM memory_card_sources WHERE message_id=? AND source_rev=1', ['mixed']),
        isEmpty,
      );
    });

    for (final correction in [false, true]) {
      test(
        'changing a current value keeps independent facts sharing its controlled topic (correction=$correction)',
        () {
          final sugar = remember('sugar', '我咖啡喝半糖。', keywords: ['咖啡']);
          store.applyControl(topicIds: [sugar['topic_id'] as String], kind: 'less');
          final morning = remember('morning', '我只在上午喝咖啡。', keywords: ['咖啡']);
          final alreadyNew = remember('already-new', '我咖啡喝无糖。', keywords: ['咖啡']);
          expect(morning['topic_id'], sugar['topic_id']);
          expect(alreadyNew['topic_id'], sugar['topic_id']);
          if (correction) {
            submit('correct', '把我咖啡喝半糖。改成我咖啡喝无糖。');
            store.correctFromMessage(
              cardId: sugar['id'] as String,
              expectedRowRev: sugar['row_rev'] as int,
              messageId: 'correct',
              expectedSourceRev: 1,
              text: '我咖啡喝无糖。',
            );
          } else {
            store.saveManual(
              CompanionMemory(id: sugar['id'] as String, text: '我咖啡喝无糖。', keywords: const ['咖啡']),
              expectedRowRev: sugar['row_rev'] as int,
              currentValueChange: true,
              realityKnown: true,
            );
          }
          expect(store.cards(), hasLength(3));
          expect(
            store.cards().singleWhere((card) => card['id'] == morning['id']),
            morning,
            reason: 'topic controls expression; it does not prove fact dependence',
          );
          expect(
            store.cards().singleWhere((card) => card['id'] == alreadyNew['id']),
            alreadyNew,
            reason: 'cleanup must inspect the old value, not expand from the newly written text',
          );
          expect(store.cards().every((card) => card['topic_mode'] == 'less'), isTrue);
          expect(store.cards().singleWhere((card) => card['id'] == sugar['id'])['text'], '我咖啡喝无糖。');
        },
      );
    }

    test('deleting one explicit card does not forget every independent fact in its expression topic', () {
      final sugar = remember('sugar', '我咖啡喝半糖。', keywords: ['咖啡']);
      store.applyControl(topicIds: [sugar['topic_id'] as String], kind: 'less');
      final morning = remember('morning', '我只在上午喝咖啡。', keywords: ['咖啡']);
      expect(morning['topic_id'], sugar['topic_id']);
      store.deleteCard(id: sugar['id'] as String, expectedRowRev: sugar['row_rev'] as int);
      expect(store.cards(), [morning]);
      expect(store.cards().single['topic_mode'], 'less');
    });

    for (final action in ['delete', 'forget', 'correct']) {
      test('shared full-statement proof keeps independent facts and removes complete body clauses ($action)', () {
        final mixed = submit('mixed', '我住杭州，也养猫。');
        final prefix = submit('prefix', '我住杭州湾。');
        final claimed = batch();
        expect(
          store.commitExtraction(
            claimed,
            parsed(claimed, [
              create(mixed, text: '我住杭州。', keywords: ['杭州']),
              create(mixed, text: '我养猫。', keywords: ['养猫']),
              for (final text in ['我住杭州，也养猫。', '我住杭州；也养猫。', '我住杭州\n也养猫。'])
                create(mixed, text: text, keywords: ['杭州', '养猫']),
              create(prefix, keywords: ['杭州湾']),
            ]),
          ),
          isTrue,
        );
        expect(store.cards(), hasLength(6));
        final home = store.cards().singleWhere((card) => card['text'] == '我住杭州。');
        final cat = store.cards().singleWhere((card) => card['text'] == '我养猫。');
        final bay = store.cards().singleWhere((card) => card['text'] == prefix['text']);
        final originals = store.messages();
        expect(
          (cat['evidence'] as List).single,
          allOf(containsPair('message_id', 'mixed'), containsPair('quote', mixed['text'])),
        );
        if (action == 'delete') {
          store.deleteCard(id: home['id'] as String, expectedRowRev: home['row_rev'] as int);
        } else if (action == 'forget') {
          final command = submit('control', '忘掉我住杭州，聊天留着');
          final control = parseMemoryControl(command['text'] as String, store.cards())!;
          expect(control['ambiguous'], isFalse);
          expect(control['target_card_ids'], [home['id']]);
          store.applyControl(
            topicIds: (control['topic_ids'] as List<Object?>).cast<String>(),
            kind: 'forget',
            controlMessageId: 'control',
          );
        } else {
          submit('control', '把我住杭州。改成我住苏州。');
          store.correctFromMessage(
            cardId: home['id'] as String,
            expectedRowRev: home['row_rev'] as int,
            messageId: 'control',
            expectedSourceRev: 1,
            text: '我住苏州。',
          );
        }
        expect(
          store.cards().map((card) => card['id']),
          unorderedEquals([cat['id'], bay['id'], if (action == 'correct') home['id']]),
        );
        expect(store.cards().singleWhere((card) => card['id'] == cat['id']), cat);
        expect(
          store.cards().singleWhere((card) => card['id'] == bay['id']),
          bay,
          reason: 'a prefix inside a different complete clause is not the selected fact',
        );
        expect(store.messages().where((row) => const ['mixed', 'prefix'].contains(row['id'])), originals);
        expect(database.select('SELECT * FROM memory_deleted_messages'), isEmpty);
        expect(select('养猫').ids, [cat['id']]);
        expect(select('养猫').block, isNot(contains('我住杭州')));
        if (action == 'correct') {
          final corrected = store.cards().singleWhere((card) => card['id'] == home['id']);
          expect(corrected['text'], '我住苏州。');
          expect((corrected['evidence'] as List).single, containsPair('message_id', 'control'));
        }
        final after = store.cards();
        reopen();
        expect(store.cards(), after);
        expect(store.messages().where((row) => const ['mixed', 'prefix'].contains(row['id'])), originals);
      });
    }

    for (final deleteChat in [false, true]) {
      test('a precise spoken forget retains the independent fact sharing its topic (raw=$deleteChat)', () {
        final sugar = remember('sugar', '我咖啡喝半糖', keywords: ['咖啡']);
        final topic = sugar['topic_id'] as String;
        store.applyControl(topicIds: [topic], kind: 'less');
        final morning = remember('morning', '我只在上午喝咖啡', keywords: ['咖啡']);
        expect(morning['topic_id'], topic);
        final command = submit('forget', '忘掉我咖啡喝半糖${deleteChat ? '，连原话也删' : ''}');
        final parsedControl = parseMemoryControl(command['text'] as String, store.cards())!;
        expect(parsedControl['target_card_ids'], [sugar['id']]);
        store.applyControl(topicIds: [topic], kind: 'forget', controlMessageId: 'forget', deleteChat: deleteChat);
        expect(store.cards(), [morning]);
        expect(store.messages().any((row) => row['id'] == 'morning'), isTrue);
        expect(store.messages().any((row) => row['id'] == 'sugar'), !deleteChat);
        expect(store.archive['history_after_seq'], command['first_seq']);
        final meta = store.archive;
        reopen();
        store.applyControl(
          topicIds: [topic],
          kind: 'forget',
          controlMessageId: 'forget',
          deleteChat: deleteChat,
          targetCardIds: [sugar['id'] as String],
        );
        expect(store.archive, meta, reason: 'an exact replay stays idempotent after the selected card was removed');
        expect(
          () => store.applyControl(
            topicIds: [topic],
            kind: 'forget',
            controlMessageId: 'forget',
            deleteChat: deleteChat,
            targetCardIds: [morning['id'] as String],
          ),
          throwsA(isA<DshRemoteException>()),
        );
        expect(store.cards(), [morning]);
      });
    }

    for (final scope in ['spoken', 'selected-card', 'explicit-topic']) {
      test('cancellation uses the actual explicit target scope ($scope)', () {
        final first = remember('first-plan', '我周五去咖啡馆', keywords: ['咖啡馆'], kind: 'episode');
        final topic = first['topic_id'] as String;
        store.applyControl(topicIds: [topic], kind: 'less');
        final second = remember('second-plan', '我周六在咖啡馆见朋友', keywords: ['咖啡馆'], kind: 'episode');
        expect(second['topic_id'], topic);
        if (scope == 'spoken') submit('cancel', '我周五去咖啡馆取消了');
        store.applyControl(
          topicIds: [topic],
          kind: 'cancel',
          controlMessageId: scope == 'spoken' ? 'cancel' : null,
          targetCardIds: scope == 'selected-card' ? [first['id'] as String] : null,
        );
        expect(store.cards().singleWhere((row) => row['id'] == first['id'])['plan_state'], 'cancelled');
        final remaining = store.cards().singleWhere((row) => row['id'] == second['id']);
        if (scope == 'explicit-topic') {
          expect(remaining['plan_state'], 'cancelled');
        } else {
          expect(remaining, second);
        }
      });
    }

    test('fact control reparses an edited command and cannot expand its original selected IDs', () {
      final sugar = remember('sugar', '我咖啡喝半糖', keywords: ['咖啡']);
      final topic = sugar['topic_id'] as String;
      store.applyControl(topicIds: [topic], kind: 'less');
      final morning = remember('morning', '我只在上午喝咖啡', keywords: ['咖啡']);
      submit('forget', '忘掉我咖啡喝半糖');
      final original = parseMemoryControl('忘掉我咖啡喝半糖', store.cards())!;
      store.editMessage(id: 'forget', expectedSourceRev: 1, text: '忘掉我只在上午喝咖啡');
      final before = store.cards(), meta = store.archive;
      expect(
        () => store.applyControl(
          topicIds: [topic],
          kind: 'forget',
          controlMessageId: 'forget',
          targetCardIds: (original['target_card_ids'] as List).cast<String>(),
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(
        () => store.applyControl(
          topicIds: [topic],
          kind: 'forget',
          controlMessageId: 'forget',
          targetCardIds: [sugar['id'] as String, morning['id'] as String],
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(store.cards(), before);
      expect(store.archive, meta);
      expect(store.messages().last['extraction_state'], 'pending');
    });

    test('current card changes and shared-topic ambiguity are rechecked before fact control', () {
      final sugar = remember('sugar', '我咖啡喝半糖', keywords: ['咖啡']);
      final topic = sugar['topic_id'] as String;
      store.applyControl(topicIds: [topic], kind: 'less');
      final morning = remember('morning', '我只在上午喝咖啡', keywords: ['咖啡']);
      submit('forget', '忘掉我咖啡喝半糖');
      store.saveManual(
        CompanionMemory(id: sugar['id'] as String, text: '我咖啡喝无糖', keywords: const ['咖啡']),
        expectedRowRev: sugar['row_rev'] as int,
        currentValueChange: true,
        realityKnown: true,
      );
      final before = store.cards(), meta = store.archive;
      expect(
        () => store.applyControl(
          topicIds: [topic],
          kind: 'forget',
          controlMessageId: 'forget',
          targetCardIds: [sugar['id'] as String],
        ),
        throwsA(isA<DshRemoteException>()),
      );
      submit('ambiguous-forget', '忘掉咖啡');
      expect(parseMemoryControl('忘掉咖啡', store.cards())!['ambiguous'], isTrue);
      expect(
        () => store.applyControl(topicIds: [topic], kind: 'forget', controlMessageId: 'ambiguous-forget'),
        throwsA(isA<DshRemoteException>()),
      );
      expect(
        () => store.applyControl(topicIds: [topic], kind: 'cancel', targetCardIds: ['missing']),
        throwsA(isA<DshRemoteException>()),
      );
      expect(
        () => store.applyControl(topicIds: [topic], kind: 'less', targetCardIds: [morning['id'] as String]),
        throwsArgumentError,
      );
      expect(store.cards(), before);
      expect(store.archive['control_revision'], meta['control_revision']);
    });

    test('selected-card controls reject a target from another explicit topic', () {
      final coffee = remember('coffee', '我周五去咖啡馆', keywords: ['咖啡馆'], kind: 'episode');
      final flute = remember('flute', '我周六上长笛课', keywords: ['长笛'], kind: 'episode');
      final before = store.cards(), meta = store.archive;
      expect(
        () => store.applyControl(
          topicIds: [coffee['topic_id'] as String],
          kind: 'cancel',
          targetCardIds: [flute['id'] as String],
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(store.cards(), before);
      expect(store.archive, meta);
    });

    test('deleting one source withdraws a complete AND group rather than promoting its surviving half', () {
      final a = submit('a', '我住上海');
      final b = submit('b', '我喝无糖咖啡');
      submit('independent', '我住上海，喝无糖咖啡');
      final claimed = batch();
      store.commitExtraction(
        claimed,
        parsed(claimed, [
          {
            'op': 'create',
            'kind': 'fact',
            'text': '住上海，喝无糖咖啡',
            'keywords': ['上海', '咖啡'],
            'evidence': [
              {'message_id': a['id'], 'quote': a['text']},
              {'message_id': b['id'], 'quote': b['text']},
            ],
          },
          create(a, text: '只依赖 a 的上海卡', keywords: ['上海']),
        ]),
      );
      final combined = store.cards().singleWhere((card) => card['text'] == '住上海，喝无糖咖啡');
      database.execute('INSERT INTO memory_card_sources VALUES(?,?,?,?,?)', [
        combined['id'],
        'independent-proof',
        'independent',
        1,
        '我住上海，喝无糖咖啡',
      ]);
      final beforeControl = store.archive['control_revision'] as int;
      expect(() => store.deleteMessage(id: 'a', expectedSourceRev: 2), throwsA(isA<DshRemoteException>()));
      expect(store.archive['control_revision'], beforeControl);
      store.deleteMessage(id: 'a', expectedSourceRev: 1);
      expect(store.cards().single['id'], combined['id']);
      expect((store.cards().single['evidence'] as List).single, containsPair('message_id', 'independent'));
      expect(database.select('SELECT * FROM memory_card_sources WHERE message_id=?', ['b']), isEmpty);
      expect(store.messages().map((source) => source['id']), ['b', 'independent']);
      expect(store.messages(forModel: true), isEmpty);
      expect(store.archive['control_revision'], beforeControl + 1);
    });

    test('a forgotten migrated card cannot be reimported and leaves only an identity cleanup receipt', () {
      final read = legacy();
      store.importLegacy(read);
      final card = store.cards().single;
      expect(() => store.deleteCard(id: card['id'] as String, expectedRowRev: 2), throwsA(isA<DshRemoteException>()));
      store.deleteCard(id: card['id'] as String, expectedRowRev: 1);
      store.importLegacy(read);
      expect(store.cards(includeInactive: true), isEmpty);
      expect(store.migrationCleanup().single['result'], 'forgotten');
      expect(store.verifyLegacyImport(read, [manualCard]), isTrue);
      expect(jsonEncode(store.migrationCleanup()), isNot(contains('明天去听演出')));
      reopen();
      store.importLegacy(read);
      expect(store.cards(includeInactive: true), isEmpty);
    });

    test('only an explicit legacy reality confirmation changes display-only eligibility', () {
      store.importLegacy(legacy());
      final old = store.cards().single;
      expect(old['reality_unconfirmed'], isTrue);
      final beforePin = store.archive['control_revision'];
      store.setPinned(id: old['id'] as String, expectedRowRev: 1, pinned: true);
      final pinned = store.cards().single;
      expect(pinned['eligible'], isFalse);
      expect(pinned['current_basis_seq'], isNull);
      expect(pinned['source_at_ms'], 2000);
      expect(store.archive['control_revision'], beforePin);
      store.confirmReality(id: old['id'] as String, expectedRowRev: 2);
      final confirmed = store.cards().single;
      expect(confirmed['eligible'], isTrue);
      expect(confirmed['reality_unconfirmed'], isFalse);
      expect(confirmed['current_basis_seq'], isNull);
      expect(confirmed['source_at_ms'], 2000);
      expect(confirmed['event_time'], isNull);
      expect(confirmed['followup'], isNull);
      expect(confirmed['evidence'], isEmpty);
      expect(store.migrationCleanup().single['result'], 'imported');
      expect(
        () => store.confirmReality(id: old['id'] as String, expectedRowRev: 3),
        throwsA(isA<DshRemoteException>()),
      );
    });

    test('pinning a long automatic card does not turn it into a manual statement or apply the legacy text limit', () {
      final text = '长笛${List.filled(598, '字').join()}';
      final card = remember('long', text, keywords: ['长笛']);
      final control = store.archive['control_revision'];
      final sequence = store.archive['next_seq'];
      store.setPinned(id: card['id'] as String, expectedRowRev: 1, pinned: true);
      final pinned = store.cards().single;
      expect(pinned['pinned'], isTrue);
      expect(pinned['row_rev'], 2);
      expect(pinned['text'], text);
      for (final field in [
        'manual',
        'eligible',
        'status',
        'current_basis_seq',
        'source_at_ms',
        'evidence',
        'updated_at_ms',
      ]) {
        expect(pinned[field], card[field], reason: 'pinning does not change $field');
      }
      expect(store.archive['control_revision'], control);
      expect(store.archive['next_seq'], sequence);
      expect(select('长笛').ids, [card['id']]);
      expect(select('你好').ids, isEmpty);
      expect(
        () => store.setPinned(id: card['id'] as String, expectedRowRev: 1, pinned: false),
        throwsA(isA<DshRemoteException>()),
      );
    });

    test('an unresolved control completes its own event without changing topics, cards, history or retry count', () {
      remember('u1', '我学长笛', keywords: ['长笛']);
      final source = submit('ambiguous', '忘掉那件事');
      final claimed = batch();
      store.recordInvalidProposal(claimed);
      final beforeCards = store.cards();
      final beforeControl = store.archive['control_revision'] as int;
      store.finishUnresolvedControl(messageId: 'ambiguous', expectedSourceRev: 1);
      expect(store.cards(), beforeCards);
      expect(store.archive['history_after_seq'], 0);
      expect(store.archive['control_revision'], beforeControl + 1);
      final done = events().singleWhere((event) => event['seq'] == source['event_seq']);
      expect(done['state'], 'done');
      expect(done['reason'], 'ambiguous_control');
      expect(done['format_failures'], 1);
      expect(store.nextBatch(forceTail: true, estimateTokens: estimate), isNull);
      store.finishUnresolvedControl(messageId: 'ambiguous', expectedSourceRev: 1);
      expect(store.archive['control_revision'], beforeControl + 1);
      submit('ordinary', '我去公园');
      expect(
        () => store.finishUnresolvedControl(messageId: 'ordinary', expectedSourceRev: 1),
        throwsA(isA<DshRemoteException>()),
      );
      expect(store.messages().last['extraction_state'], 'pending');
    });

    test('deleted stable source identities cannot be resubmitted after restart as new statements', () {
      final source = submit('old', '我周五复诊');
      store.deleteMessage(id: 'old', expectedSourceRev: 1);
      final sequence = store.archive['next_seq'];
      reopen();
      expect(
        database.select('SELECT * FROM memory_deleted_messages').single,
        allOf(containsPair('id', 'old'), containsPair('first_seq', source['first_seq'])),
      );
      expect(
        () => submit('old', '我周五复诊'),
        throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/deleted-source')),
      );
      expect(() => submit('old', '换字也不能偷换同一已删身份'), throwsA(isA<DshRemoteException>()));
      expect(store.archive['next_seq'], sequence);
      expect(store.messages(), isEmpty);
      submit('new-independent', '我周五复诊');
      expect(batch().sources.single['id'], 'new-independent');
    });

    test('opening a v2 database adds deletion identities without replacing its original data', () {
      final card = remember('u1', '我学长笛', keywords: ['长笛']);
      final originalArchive = store.archive;
      restoreOldMemorySchema(database, 2);
      reopen();
      expect(database.select('PRAGMA user_version').single['user_version'], 17);
      expect(store.archive, originalArchive);
      expect(store.cards().single, {...card, 'cleanup_history_complete': 0});
      expect(store.messages().single['text'], '我学长笛');
      store.deleteMessage(id: 'u1', expectedSourceRev: 1);
      expect(store.messages(), isEmpty);
      expect(database.select('SELECT id FROM memory_deleted_messages').single['id'], 'u1');
    });

    test('widget clears are acknowledged only at the exact current control revision', () {
      final card = remember('u1', '我学长笛', keywords: ['长笛']);
      store.applyControl(topicIds: [card['topic_id'] as String], kind: 'less');
      final older = store.archive['control_revision'] as int;
      expect(store.archive['widget_clear_pending'], 1);
      store.acknowledgeWidgetClear(controlRevision: older);
      expect(store.archive['widget_clear_pending'], 0);
      store.applyControl(topicIds: [card['topic_id'] as String], kind: 'never');
      final current = store.archive['control_revision'] as int;
      store.acknowledgeWidgetClear(controlRevision: older);
      expect(store.archive['widget_clear_pending'], 1);
      reopen();
      expect(store.archive['widget_clear_pending'], 1);
      store.acknowledgeWidgetClear(controlRevision: current);
      expect(store.archive['widget_clear_pending'], 0);
    });

    test('a control transaction failure rolls back deleted data, versions, queue and pending widget clear', () {
      final card = remember('u1', '我学长笛', keywords: ['长笛']);
      submit('waiting', '下一条原话');
      final claimed = batch();
      final before = store.archive;
      final cards = store.cards();
      database.execute("""
        CREATE TRIGGER fail_control BEFORE UPDATE OF control_revision ON memory_archive
        BEGIN SELECT RAISE(ABORT,'fixture'); END
      """);
      expect(
        () => store.applyControl(topicIds: [card['topic_id'] as String], kind: 'forget'),
        throwsA(isA<SqliteException>()),
      );
      expect(store.archive, before);
      expect(store.cards(), cards);
      expect(store.isBatchCurrent(claimed), isTrue);
      expect(store.messages().last['extraction_state'], 'pending');
      database.execute('DROP TRIGGER fail_control');
      store.applyControl(topicIds: [card['topic_id'] as String], kind: 'forget');
      expect(store.cards(), isEmpty);
      expect(store.archive['widget_clear_pending'], 1);
    });

    test('ordinary extraction does not invalidate a prepared chat, but real edits and manual changes do', () {
      final initial = store.archive['control_revision'] as int;
      final card = remember('u1', '我学长笛', keywords: ['长笛']);
      expect(store.archive['control_revision'], initial);
      store.editMessage(id: 'u1', expectedSourceRev: 1, text: '我改学钢琴');
      final edited = store.archive['control_revision'] as int;
      expect(edited, initial + 1);
      final claimed = batch();
      store.commitExtraction(
        claimed,
        parsed(claimed, [
          create(claimed.sources.single, keywords: ['钢琴']),
        ]),
      );
      expect(store.archive['control_revision'], edited);
      final current = store.cards().single;
      store.saveManual(
        CompanionMemory(id: current['id'] as String, text: '我现在学手风琴', keywords: const ['手风琴']),
        expectedRowRev: current['row_rev'] as int,
        currentValueChange: true,
        realityKnown: true,
      );
      expect(store.archive['control_revision'], edited + 1);
      expect(store.cards(includeInactive: true).firstWhere((row) => row['id'] == card['id'])['status'], 'withdrawn');
    });
  });

  group('durable ordinary host chat receipts', () {
    MemoryRow delivery({
      String host = 'host-a',
      String instance = 'instance-a',
      String session = 'session-a',
      String request = 'rpc-1',
    }) => store.rememberHostChatDelivery(
      hostKey: host,
      instanceId: instance,
      sessionId: session,
      requestId: request,
      archiveId: store.archive['id'] as String,
      controlRevision: store.archive['control_revision'] as int,
      historyAfterSeq: store.archive['history_after_seq'] as int,
      observedAt: now,
    );

    test('a body-free delivery survives restart without inventing one charged request', () {
      final first = delivery();
      expect(first['state'], 'pending');
      expect(store.requests(), isEmpty);
      now += 500;
      expect(delivery(), first, reason: 'idempotent delivery keeps its original observation and binding');
      reopen();
      expect(store.pendingHostChatDeliveries('host-a'), [first]);
      expect(store.pendingHostChatDeliveries('host-b'), isEmpty);
      expect(
        () => store.rememberHostChatDelivery(
          hostKey: 'host-a',
          instanceId: 'instance-a',
          sessionId: 'session-a',
          requestId: 'rpc-1',
          archiveId: store.archive['id'] as String,
          controlRevision: 1,
          historyAfterSeq: 0,
          observedAt: now,
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(store.requests(), isEmpty);
      expect(database.select('PRAGMA user_version').single['user_version'], 17);
    });

    test('v3 upgrade preserves sources and existing once-only local receipts', () {
      submit('u1', '原来的本地文字');
      final request = reserve(category: 'chat')!;
      store.markRequestSent(request);
      store.recordUsage(request, usage(input: 2, read: 0, write: 0, output: 1));
      store.finishRequest(request, terminal: 'complete');
      final before = store.requests(), originalArchive = store.archive;
      restoreOldMemorySchema(database, 3);
      reopen();
      expect(store.requests(), before);
      expect(store.archive, originalArchive);
      expect(store.messages().single['text'], '原来的本地文字');
      expect(store.pendingHostChatDeliveries('host-a'), isEmpty);
      expect(delivery()['state'], 'pending');
    });

    test('settled coverage with no retained receipt remains visibly unknown instead of becoming zero fees', () {
      final owner = delivery();
      store.importHostChatUsage(
        deliveryId: owner['id'] as String,
        snapshot: hostSnapshot(owner, [], gaps: const ['no-call-observed']),
      );
      expect(store.requests(), isEmpty);
      expect(store.pendingHostChatDeliveries('host-a'), isEmpty);
      final coverage = store.hostChatDeliveries().single;
      expect(coverage['state'], 'settled');
      expect(coverage['receipt_ids'], isEmpty);
      expect(
        coverage['snapshot_metadata'],
        allOf(
          containsPair('complete', false),
          containsPair('physicalRequests', null),
          containsPair('gaps', ['no-call-observed']),
        ),
      );
      reopen();
      expect(store.hostChatDeliveries(), [coverage]);
    });

    test('one prompt with two physical fetches keeps two exact raw receipts and no auxiliary reservation', () {
      final owner = delivery();
      final first = hostReceipt(
        id: 'physical-1',
        raw: usage(input: 100, read: 25, write: 0, output: 37, complete: false),
      );
      final second = hostReceipt(
        id: 'physical-2',
        call: 'call-2',
        revision: 3,
        raw: usage(input: 7, read: 0, write: 0, output: 5),
      );
      final snapshot = {
        ...hostSnapshot(owner, [first, second]),
        'prompt': 'not retained',
        'binding': {...(hostSnapshot(owner, [])['binding'] as Map), 'responseBody': 'not retained'},
      };
      expect(store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: snapshot), isTrue);
      expect(store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: snapshot), isFalse);
      reopen();
      final rows = store.requests();
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['receipt_id']), ['physical-1', 'physical-2']);
      expect(rows.map((row) => row['output_tokens']), [37, 5]);
      expect(rows.first['raw_usage'], first['usage']);
      expect(rows.first['complete'], isFalse, reason: 'final cumulative counters survive a missing message_stop');
      expect(rows.first['input_uncached'], 100, reason: 'start input=999 is never added to final input');
      expect(rows.first['estimated_cny'], closeTo((100 * 2 + 25 * .04 + 37 * 8) / 1000000, 1e-12));
      for (final row in rows) {
        expect(row['origin'], 'host-chat');
        expect(row['category'], 'chat');
        expect(row['physical_requests'], 1);
        expect(row['reserved_input'], isNull);
        expect(row['reserved_output'], isNull);
        expect(row['sent_at_ms'], isNull);
        expect(row['host_dispatch_at_ms'], 900000);
      }
      expect(store.pendingHostChatDeliveries('host-a'), isEmpty);
      expect(
        database.select('SELECT snapshot_metadata FROM memory_host_chat_deliveries').single['snapshot_metadata'],
        isNot(contains('not retained')),
      );
      expect(reserve(), isNotNull, reason: 'ordinary chat does not spend extraction budgets');
    });

    test('same-turn roots share one global physical receipt instead of charging it twice', () {
      final first = delivery(), second = delivery(request: 'rpc-2');
      final receipt = hostReceipt(requestIds: const ['rpc-1', 'rpc-2']);
      expect(
        store.importHostChatUsage(deliveryId: first['id'] as String, snapshot: hostSnapshot(first, [receipt])),
        isTrue,
      );
      expect(
        store.importHostChatUsage(deliveryId: second['id'] as String, snapshot: hostSnapshot(second, [receipt])),
        isTrue,
      );
      expect(store.requests(), hasLength(1));
      expect(store.requests().single['delivery_ids'], unorderedEquals([first['id'], second['id']]));
      expect(
        store.importHostChatUsage(deliveryId: second['id'] as String, snapshot: hostSnapshot(second, [receipt])),
        isFalse,
      );
      final otherHost = delivery(host: 'host-b');
      store.importHostChatUsage(deliveryId: otherHost['id'] as String, snapshot: hostSnapshot(otherHost, [receipt]));
      expect(store.requests(), hasLength(2), reason: 'a distinct host is a distinct receipt identity');
      final otherInstance = delivery(instance: 'instance-b');
      store.importHostChatUsage(
        deliveryId: otherInstance['id'] as String,
        snapshot: hostSnapshot(otherInstance, [receipt]),
      );
      expect(store.requests(), hasLength(3), reason: 'a restarted bridge has a new receipt namespace');
    });

    test('a globally identified receipt cannot be relabelled onto a different session', () {
      final first = delivery(), otherSession = delivery(session: 'session-b', request: 'rpc-2');
      final receipt = hostReceipt(requestIds: const ['rpc-1', 'rpc-2']);
      store.importHostChatUsage(deliveryId: first['id'] as String, snapshot: hostSnapshot(first, [receipt]));
      expect(
        () => store.importHostChatUsage(
          deliveryId: otherSession['id'] as String,
          snapshot: hostSnapshot(otherSession, [receipt]),
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(store.requests().single['delivery_ids'], [first['id']]);
      expect(store.pendingHostChatDeliveries('host-a'), [otherSession]);
    });

    test('active revisions replace one receipt, older snapshots do not overwrite and finished cannot change', () {
      final owner = delivery();
      final startOnly = {...usage(complete: false), 'final_usage': null, 'final_event': null, 'stop_reason': null};
      final active = hostReceipt(revision: 2, phase: 'active', raw: startOnly);
      final initial = hostSnapshot(owner, [active], revision: 2, state: 'running');
      store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: initial);
      expect(store.requests().single['output_tokens'], isNull);
      expect(store.requests().single['raw_usage'], startOnly);
      final finalReceipt = hostReceipt(
        revision: 4,
        raw: usage(input: 9, read: 3, write: 0, output: 8, complete: false),
      );
      final settled = hostSnapshot(owner, [finalReceipt], revision: 5);
      store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: settled);
      final finished = store.requests().single;
      expect(finished['output_tokens'], 8);
      expect(finished['complete'], isFalse);
      expect(store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: initial), isFalse);
      expect(store.requests().single, finished);
      final changedSameRevision = hostReceipt(revision: 4, raw: usage(input: 9, read: 3, write: 0, output: 9));
      expect(
        () => store.importHostChatUsage(
          deliveryId: owner['id'] as String,
          snapshot: hostSnapshot(owner, [changedSameRevision], revision: 6),
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(
        () => store.importHostChatUsage(
          deliveryId: owner['id'] as String,
          snapshot: hostSnapshot(owner, [hostReceipt(revision: 5)], revision: 6),
        ),
        throwsA(isA<DshRemoteException>()),
      );
      expect(store.requests().single, finished);
    });

    test('an unknown revision-zero coverage gap preserves old receipt evidence and the original instance', () {
      final owner = delivery();
      final raw = usage(input: 9, read: 3, write: 0, output: 8, complete: false);
      final active = hostReceipt(revision: 4, phase: 'active', raw: raw);
      final known = hostSnapshot(owner, [active], revision: 5, state: 'running');
      store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: known);
      final rows = store.requests();
      final unknown = unknownHostSnapshot(owner, instanceId: 'next-instance', gap: 'instance-changed');
      expect(store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: unknown), isTrue);
      expect(store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: unknown), isFalse);
      reopen();
      final pending = store.pendingHostChatDeliveries('host-a').single;
      expect(pending['instance_id'], 'instance-a');
      expect(pending['unknown_instance_id'], 'next-instance');
      expect(pending['state'], 'unknown');
      expect(pending['snapshot_revision'], 5);
      expect(pending['unknown_gaps'], ['instance-changed']);
      expect(store.requests(), rows);
      expect(store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: known), isFalse);
      expect(
        store.pendingHostChatDeliveries('host-a').single['state'],
        'unknown',
        reason: 'an equivalent old reply does not erase a later coverage gap',
      );
    });

    test('generic normalized observations keep physical count and raw charge components unknown', () {
      final owner = delivery();
      final generic = hostReceipt(
        observation: 'adapter-invoked',
        raw: normalizedUsage([
          {'inputTokens': 4, 'outputTokens': 99999, 'totalTokens': 100003},
        ]),
      );
      store.importHostChatUsage(
        deliveryId: owner['id'] as String,
        snapshot: hostSnapshot(owner, [generic], gaps: const ['physical-count-unknown']),
      );
      final row = store.requests().single;
      expect(row['dispatched'], isNull);
      expect(row['physical_requests'], isNull);
      expect(row['output_tokens'], isNull);
      expect(row['estimated_cny'], isNull);
      expect(row['raw_usage'], generic['usage']);
      expect(reserve(), isNotNull, reason: 'ordinary generic chat never spends auxiliary output quota');
    });

    test('preflight and an observed HTTP failure are distinct while missing usage remains unknown', () {
      final owner = delivery();
      final base = {
        ...usage(complete: false),
        'final_usage': null,
        'final_event': null,
        'start_usage': null,
        'start_event': null,
        'stop_reason': null,
      };
      final preflight = hostReceipt(
        id: 'preflight',
        raw: {...base, 'terminal': 'preflight_error', 'http_status': null},
        observation: 'preflight',
      );
      final sent = hostReceipt(
        id: 'http-401',
        call: 'call-2',
        raw: {...base, 'terminal': 'http_error', 'http_status': 401},
      );
      store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: hostSnapshot(owner, [preflight, sent]));
      final rows = {for (final row in store.requests()) row['receipt_id']: row};
      expect(rows['preflight']!['dispatched'], isFalse);
      expect(rows['preflight']!['physical_requests'], 0);
      expect(rows['http-401']!['dispatched'], isTrue);
      expect(rows['http-401']!['physical_requests'], 1);
      expect(rows.values.every((row) => row['output_tokens'] == null && row['estimated_cny'] == null), isTrue);
    });

    test('late usage retains its original control binding after current memory changes', () {
      final owner = delivery();
      store.saveManual(
        const CompanionMemory(id: manualCard, text: '我学长笛', keywords: ['长笛']),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      final currentControl = store.archive['control_revision'];
      expect(currentControl, isNot(owner['control_revision']));
      store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: hostSnapshot(owner, [hostReceipt()]));
      expect(store.archive['control_revision'], currentControl);
      expect(store.cards().single['text'], '我学长笛');
      expect(store.requests(), hasLength(1));
      expect(
        database.select('SELECT control_revision FROM memory_host_chat_deliveries').single['control_revision'],
        owner['control_revision'],
      );
    });

    test('binding, ownership and receipt identity conflicts reject the complete snapshot atomically', () {
      final owner = delivery();
      final active = hostReceipt(phase: 'active', raw: usage(complete: false));
      store.importHostChatUsage(
        deliveryId: owner['id'] as String,
        snapshot: hostSnapshot(owner, [active], state: 'running'),
      );
      final rows = store.requests(), pending = store.pendingHostChatDeliveries('host-a');
      expect(
        () => store.importHostChatUsage(
          deliveryId: owner['id'] as String,
          snapshot: hostSnapshot(owner, [active], state: 'running', gaps: const ['capacity']),
        ),
        throwsA(isA<DshRemoteException>()),
        reason: 'the same root revision cannot change its coverage metadata',
      );
      final valid = hostSnapshot(owner, [
        hostReceipt(id: 'new-physical', call: 'new-call', revision: 3),
        hostReceipt(revision: 3, call: 'different-call'),
      ], revision: 6);
      expect(
        () => store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: valid),
        throwsA(isA<DshRemoteException>()),
      );
      for (final changed in [
        {
          ...hostSnapshot(owner, [active], state: 'running'),
          'sessionId': 'other-session',
        },
        {
          ...hostSnapshot(owner, [active], state: 'running'),
          'instanceId': 'other-instance',
        },
        {
          ...hostSnapshot(owner, [active], state: 'running'),
          'binding': {'archiveId': owner['archive_id'], 'controlRevision': 99, 'historyAfterSeq': 0},
        },
      ]) {
        expect(
          () => store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: changed),
          throwsA(isA<DshRemoteException>()),
        );
      }
      expect(store.requests(), rows);
      expect(store.pendingHostChatDeliveries('host-a'), pending);
      expect(database.select('SELECT * FROM memory_host_chat_receipts'), hasLength(1));
    });

    test('a database failure cannot leave an imported receipt without its delivery linkage', () {
      final owner = delivery();
      database.execute("""
        CREATE TRIGGER fail_usage_link BEFORE INSERT ON memory_host_chat_delivery_receipts
        BEGIN SELECT RAISE(ABORT,'fixture'); END
      """);
      expect(
        () => store.importHostChatUsage(
          deliveryId: owner['id'] as String,
          snapshot: hostSnapshot(owner, [hostReceipt()]),
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(store.requests(), isEmpty);
      expect(store.pendingHostChatDeliveries('host-a'), [owner]);
      database.execute('DROP TRIGGER fail_usage_link');
      expect(
        store.importHostChatUsage(deliveryId: owner['id'] as String, snapshot: hostSnapshot(owner, [hostReceipt()])),
        isTrue,
      );
    });
  });

  group('request receipts and rolling reservations', () {
    test('normalized output overrun closes the actual auxiliary budget without pretending raw usage is known', () {
      final request = reserve()!;
      store.markRequestUncertain(request);
      final raw = normalizedUsage([
        {'inputTokens': 7, 'outputTokens': 99999},
      ]);
      store.recordUsage(request, raw);
      store.finishRequest(request, terminal: 'incomplete');
      reopen();
      final row = store.requests().single;
      expect(row['raw_usage'], raw);
      for (final key in ['input_uncached', 'input_cache_read', 'input_cache_write', 'output_tokens', 'estimated_cny']) {
        expect(row[key], isNull);
      }
      expect(reserve(input: 0, output: 0), isNull);
      now += 86400000;
      expect(reserve(), isNotNull);
    });

    test('normalized observations use per-field maxima rather than adding event totals', () {
      final request = reserve()!;
      store.markRequestSent(request);
      store.recordUsage(
        request,
        normalizedUsage([
          {'inputTokens': 1, 'outputTokens': 1200},
          {'inputTokens': 2, 'outputTokens': 1400},
          {'inputTokens': 1, 'outputTokens': 1300},
        ]),
      );
      store.finishRequest(request, terminal: 'complete');
      expect(reserve(input: 0, output: 1601), isNull);
      expect(reserve(input: 0, output: 1600), isNotNull);
    });

    test('unverified normalized input partitions and reasoning are not added to one another', () {
      final request = reserve()!;
      store.markRequestSent(request);
      store.recordUsage(
        request,
        normalizedUsage([
          {
            'inputTokens': 10000,
            'cacheReadTokens': 14000,
            'cacheWriteTokens': 12000,
            'outputTokens': 10,
            'totalTokens': 99999,
            'reasoningTokens': 99999,
          },
          {'inputTokens': 13000, 'outputTokens': 11},
        ]),
      );
      store.finishRequest(request, terminal: 'complete');
      expect(reserve(input: 10001, output: 0), isNull);
      expect(
        reserve(input: 10000, output: 0),
        isNotNull,
        reason: 'the maximum supported input component is 14000; no disjoint producer proof was assumed',
      );
    });

    test('normalized default zero and malformed counters never release unknown reservations', () {
      for (var index = 0; index < 3; index++) {
        final request = reserve()!;
        store.markRequestSent(request);
        store.recordUsage(
          request,
          normalizedUsage([
            {'inputTokens': 0, 'outputTokens': 0},
            {'inputTokens': -1, 'outputTokens': '90000'},
            {'inputTokens': 9007199254740992, 'outputTokens': 9007199254740992},
            {'inputTokens': 3.5, 'outputTokens': 4.5},
          ]),
        );
        store.finishRequest(request, terminal: 'complete');
      }
      expect(reserve(), isNull);
      expect(store.requests().every((row) => row['output_tokens'] == null), isTrue);
      expect(() => reserve(category: 'chat', input: 9007199254740992), throwsArgumentError);
    });

    test('known raw cumulative usage and normalized lower bounds both constrain the next request', () {
      final request = reserve()!;
      store.markRequestSent(request);
      store.recordUsage(request, {
        ...usage(input: 1, read: 0, write: 0, output: 1),
        'runtime_normalized_usage': [
          {'outputTokens': 4000},
        ],
        'runtime_normalized_usage_semantics': 'runtime-normalized-events',
      });
      store.finishRequest(request, terminal: 'complete');
      expect(store.requests().single['output_tokens'], 1);
      expect(reserve(input: 0, output: 0), isNull);
    });

    test('normalized lower bounds reserve the verified peak estimate but never fabricate an actual price', () {
      final request = reserve()!;
      store.markRequestSent(request);
      store.recordUsage(
        request,
        normalizedUsage([
          {'inputTokens': 2000000, 'outputTokens': 0},
        ]),
      );
      store.finishRequest(request, terminal: 'complete');
      expect(store.requests().single['estimated_cny'], isNull);
      now += 86400000;
      expect(reserve(), isNull);
      final unknownPrice = reserve(provider: 'configured-provider', model: 'configured-model')!;
      expect(store.requests().last['reserved_cny'], isNull);
      store.finishRequest(unknownPrice, terminal: 'not_sent');
      now += 29 * 86400000;
      expect(reserve(), isNotNull);
    });

    test('a maximum safe normalized counter cannot overflow into an available monetary budget', () {
      final request = reserve()!;
      store.markRequestSent(request);
      store.recordUsage(
        request,
        normalizedUsage([
          {'inputTokens': 9007199254740991, 'outputTokens': 9007199254740991},
        ]),
      );
      store.finishRequest(request, terminal: 'complete');
      now += 86400000;
      expect(reserve(input: 0, output: 0), isNull);
    });

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
      expect(store.localRequestCost(request), {
        for (final key in ['sent_at_ms', 'uncertain_at_ms', 'state', 'reserved_at_ms', 'estimated_cny', 'reserved_cny'])
          key: receipt[key],
      });
      expect(store.localRequestCost('missing'), isNull);
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
      expect(
        () => store.recordUsage(request, usage(input: 0, read: 0, write: 0, output: 0)),
        throwsA(isA<DshRemoteException>()),
      );
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
      store.recordUsage(other, {
        ...usage(input: 10, read: 0, write: 0, output: 2),
        'provider': 'configured-provider',
        'model': 'configured-model',
      });
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
