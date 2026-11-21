// Fixed provider bytes, real stream adapter -> worker -> SQLite queue/receipt.
// These tests use no keys, model, host, or real clock.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _usage = {
  'input_tokens': 20,
  'cache_read_input_tokens': 0,
  'cache_creation_input_tokens': 0,
  'output_tokens': 12,
};

http.Response _reply(String text, {String stop = 'end_turn', bool complete = true}) => http.Response(
  [
    {
      'type': 'message_start',
      'message': {
        'usage': {'input_tokens': 900},
      },
    },
    {
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': text},
    },
    {
      'type': 'message_delta',
      'delta': {'stop_reason': stop},
      'usage': _usage,
    },
    if (complete) {'type': 'message_stop'},
  ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

Map<String, Object?> _input(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, Object?>;
  expect(body['thinking'], {'type': 'disabled'});
  expect(body['max_tokens'], 800);
  expect(body.containsKey('tools'), isFalse);
  final messages = body['messages']! as List;
  expect(messages, hasLength(1));
  return jsonDecode((messages.single as Map)['content'] as String) as Map<String, Object?>;
}

String _empty(Map<String, Object?> input) => jsonEncode({
  'schema_version': 2,
  'batch_id': input['batch_id'],
  'covered_message_ids': [for (final source in input['source']! as List) (source as Map)['id']],
  'operations': [],
  'completion': 'complete',
});

String _merge(Map<String, Object?> input, {bool empty = false}) {
  final rows = (input['rows']! as List).cast<Map>();
  return jsonEncode({
    'schema_version': 2,
    'batch_id': input['batch_id'],
    'completion': 'complete',
    'operations': empty
        ? []
        : [
            {
              'op': 'merge',
              'target_id': rows.first['id'],
              'expected_row_rev': rows.first['row_rev'],
              'from': [
                {'id': rows.last['id'], 'expected_row_rev': rows.last['row_rev']},
              ],
              'text': rows.first['text'],
              'evidence': [
                for (final row in rows)
                  for (final proof in (row['evidence'] as List).cast<Map>())
                    {'message_id': proof['message_id'], 'quote': proof['quote']},
              ],
            },
          ],
  });
}

class _Phone {
  _Phone() {
    store = CompanionMemoryStore(db, nowMilliseconds: () => now);
    addTearDown(() async {
      await worker?.stop();
      store.close();
    });
  }

  final db = sqlite3.openInMemory();
  int now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;
  late final CompanionMemoryStore store;
  CompanionMemoryWorker? worker;

  void say(String id, String text) =>
      store.submitMessage(id: id, sessionId: 'light', text: text, saidAtUtc: now, offsetMinutes: 480);

  MemoryRow invite({bool waitForCompletion = false}) {
    final raw = waitForCompletion ? '册子校对的事，等我说结束再问我想不想聊。' : '今天去修琴，今天可以问我琴修好没。';
    say('invitation', raw);
    final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
    final proposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'covered_message_ids': ['invitation'],
        'completion': 'complete',
        'operations': [
          {
            'op': 'create',
            'kind': 'episode',
            'text': waitForCompletion ? '我在校对册子' : '今天去修琴',
            'keywords': waitForCompletion ? ['册子'] : ['修琴'],
            'evidence': [
              {'message_id': 'invitation', 'quote': raw},
            ],
            'followup': {
              'local_date': waitForCompletion ? null : '2026-11-21',
              'precision': waitForCompletion ? 'unspecified' : 'day',
              'wording': waitForCompletion ? raw : '今天可以问我琴修好没',
              'basis': 'explicit_invitation',
            },
          },
        ],
      }),
      batch,
    );
    expect(store.commitExtraction(batch, proposal), isTrue);
    if (waitForCompletion) {
      now += const Duration(hours: 1).inMilliseconds;
      say('completion', '那本册子的校对结束了。');
    }
    return store.nextFollowup(nowMs: now)!;
  }

  void pair({bool exact = false}) {
    say('s1', '酸奶我只买原味。');
    if (!exact) say('s2', '我买酸奶一直只选原味。');
    final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
    final proposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'covered_message_ids': [for (final source in batch.sources) source['id']],
        'completion': 'complete',
        'operations': [
          for (var i = 0; i < 2; i++)
            {
              'op': 'create',
              'kind': 'preference',
              'text': exact || i == 0 ? '你买酸奶只选原味。' : '酸奶你只买原味的。',
              'keywords': ['酸奶'],
              'evidence': [
                {'message_id': batch.sources[exact ? 0 : i]['id'], 'quote': batch.sources[exact ? 0 : i]['text']},
              ],
            },
        ],
      }),
      batch,
    );
    expect(store.commitExtraction(batch, proposal), isTrue);
    expect(store.cards(), hasLength(2));
  }

  CompanionMemoryWorker withHttp(Future<http.Response> Function(http.Request) answer, {String key = 'test'}) {
    final route = CompanionLightMemoryTransport(apiKey: () => key, client: () => MockClient(answer));
    return worker = CompanionMemoryWorker(
      store: store,
      transport: () => route,
      nowMilliseconds: () => now,
      estimateTokens: (text) => text.runes.length,
    );
  }
}

void main() {
  test(
    'B03 actual followup POST carries original invitation support and persona with a separate usage receipt',
    () async {
      final phone = _Phone();
      final capture = phone.invite(waitForCompletion: true);
      const persona = '你叫鲸鱼娘，说话自然简短。';
      final worker = phone.withHttp((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['system'], companionMemoryFollowupPrompt);
        expect(body['max_tokens'], 128);
        expect(body.containsKey('tools'), isFalse);
        final messages = body['messages'] as List;
        expect(messages, hasLength(1));
        final input = jsonDecode((messages.single as Map)['content'] as String) as Map;
        expect(input['card'], {'text': '我在校对册子'});
        expect(input['persona'], persona);
        expect(input['invitation'], {
          'message_id': 'invitation',
          'source_rev': 1,
          'said_at_utc': DateTime.fromMillisecondsSinceEpoch(phone.now - 3600000, isUtc: true).toIso8601String(),
          'offset_minutes': 480,
          'quote': '册子校对的事，等我说结束再问我想不想聊。',
        });
        expect(input['support'], [
          {
            'message_id': 'completion',
            'source_rev': 1,
            'said_at_utc': DateTime.fromMillisecondsSinceEpoch(phone.now, isUtc: true).toIso8601String(),
            'offset_minutes': 480,
            'quote': '那本册子的校对结束了。',
          },
        ]);
        expect(input['offset_minutes'], -240, reason: 'the current offset does not reinterpret the original source');
        expect(phone.store.requests().single['category'], 'followup');
        expect(phone.store.requests().single['batch_id'], 'followup:${capture['id']}:${capture['row_rev']}');
        return _reply('{"action":"line","text":"那本册子校对完了，想聊聊吗？"}');
      });
      expect(
        await worker.followup(capture, persona: persona, offsetMinutes: -240, isCurrent: () => true),
        '那本册子校对完了，想聊聊吗？',
      );
      expect(phone.store.followups().single['state'], 'pending', reason: 'generation is not presentation');
      final receipt = phone.store.requests().single;
      expect(receipt['state'], 'finished');
      expect((receipt['raw_usage']! as Map)['final_usage'], _usage);
    },
  );

  test(
    'B03 extraction and wording share one actual request lane while a late cancelled answer is still charged',
    () async {
      final phone = _Phone();
      final capture = phone.invite();
      phone.say('next-message', '我还学了长笛。');
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      var calls = 0;
      final worker = phone.withHttp((_) {
        calls++;
        started.complete();
        return reply.future;
      });
      final wording = worker.followup(capture, persona: '温柔简短', offsetMinutes: 480, isCurrent: () => true);
      await started.future;
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.idle);
      expect(await worker.followup(capture, persona: '温柔简短', offsetMinutes: 480, isCurrent: () => true), isNull);
      expect(calls, 1);
      worker.cancel();
      reply.complete(_reply('{"action":"line","text":"那把琴修好了吗？"}'));
      expect(await wording, isNull);
      expect(phone.store.requests().single['sent_at_ms'], isNotNull);
      expect((phone.store.requests().single['raw_usage']! as Map)['final_usage'], _usage);
      expect(phone.store.followups().single['state'], 'pending');
      expect(
        phone.db.select("SELECT state FROM memory_events WHERE message_id='next-message'").single['state'],
        'pending',
      );
    },
  );

  test('B03 oversize whole input and an absent key never create a request or truncate evidence', () async {
    final phone = _Phone();
    final capture = phone.invite();
    final worker = phone.withHttp((_) async => throw StateError('no request expected'));
    expect(await worker.followup(capture, persona: '长人设' * 2000, offsetMinutes: 480, isCurrent: () => true), isNull);
    final noKey = phone.withHttp((_) async => throw StateError('no request expected'), key: '');
    expect(await noKey.followup(capture, persona: '简短', offsetMinutes: 480, isCurrent: () => true), isNull);
    expect(phone.store.requests(), isEmpty);
    expect(phone.store.followups().single['state'], 'pending');
  });

  test('followup stays pending when the full room has no model route', () async {
    final phone = _Phone();
    final capture = phone.invite();
    final worker = phone.worker = CompanionMemoryWorker(
      store: phone.store,
      transport: () => null,
      nowMilliseconds: () => phone.now,
      estimateTokens: (text) => text.runes.length,
    );
    expect(await worker.followup(capture, persona: '简短', offsetMinutes: 480, isCurrent: () => true), isNull);
    expect(phone.store.requests(), isEmpty);
    expect(phone.store.followups().single['state'], 'pending');
    expect(phone.store.isFollowupCurrent(capture, nowMs: phone.now), isTrue);
  });

  test('exact local consolidation works without credentials and sends no request', () async {
    final phone = _Phone()..pair(exact: true);
    var calls = 0;
    final worker = phone.withHttp((_) async {
      calls++;
      throw StateError('no cloud request expected');
    }, key: '');
    await worker.consolidate();
    expect(phone.store.cards(), hasLength(1));
    expect(phone.store.requests(), isEmpty);
    expect(calls, 0);
  });

  test('consolidation sends the exact prompt and retains raw usage without triggering itself again', () async {
    final phone = _Phone()..pair();
    var calls = 0;
    final worker = phone.withHttp((request) async {
      calls++;
      expect((jsonDecode(request.body) as Map)['system'], companionMemoryConsolidationPrompt);
      expect(phone.store.requests().single['category'], 'organize');
      expect(phone.store.requests().single['state'], 'sent');
      return _reply(_merge(_input(request)));
    });
    expect(await worker.consolidate(), CompanionMemoryWork.committed);
    expect(phone.store.cards(), hasLength(1));
    final receipt = phone.store.requests().single;
    final raw = receipt['raw_usage'] is String ? jsonDecode(receipt['raw_usage'] as String) : receipt['raw_usage'];
    expect((raw as Map)['final_usage'], _usage);
    phone.now += 86400001;
    expect(await worker.consolidate(), CompanionMemoryWork.idle);
    expect(calls, 1);
  });

  test(
    'extract and consolidate share the active request and a cancelled late merge only settles its receipt',
    () async {
      final phone = _Phone()..pair();
      final started = Completer<Map<String, Object?>>();
      final response = Completer<http.Response>();
      final worker = phone.withHttp((request) {
        started.complete(_input(request));
        return response.future;
      });
      final running = worker.consolidate();
      final input = await started.future;
      phone.say('s3', '今天练了一会儿琴。');
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.idle);
      expect(await worker.consolidate(), CompanionMemoryWork.idle);
      expect(phone.db.select("SELECT state FROM memory_events WHERE message_id='s3'").single['state'], 'pending');
      final stop = worker.stop();
      phone.store.deleteMessage(id: 's1', expectedSourceRev: 1);
      // Deleting a source advances the archive history boundary before the
      // provider returns. The unrelated raw message remains, not its old job.
      final skipped = phone.db.select("SELECT state,reason FROM memory_events WHERE message_id='s3'").single;
      expect(skipped['state'], 'skipped');
      expect(skipped['reason'], 'history_cutoff');
      response.complete(_reply(_merge(input)));
      expect(await running, CompanionMemoryWork.stale);
      await stop;
      expect(phone.store.cards(), hasLength(1));
      expect(phone.store.requests(), hasLength(1));
      expect(phone.store.requests().single['state'], 'finished');
      final after = phone.db.select("SELECT state,reason FROM memory_events WHERE message_id='s3'").single;
      expect(after['state'], 'skipped');
      expect(after['reason'], 'history_cutoff');
      expect(phone.store.messages().singleWhere((row) => row['id'] == 's3')['text'], '今天练了一会儿琴。');
    },
  );

  test(
    'a new change waits for the same rolling organize allowance rather than opening another model request',
    () async {
      final phone = _Phone()..pair();
      var calls = 0;
      final worker = phone.withHttp((request) async {
        calls++;
        return _reply(_merge(_input(request), empty: true));
      });
      expect(await worker.consolidate(), CompanionMemoryWork.committed);
      final row = phone.store.cards().first;
      phone.store.setPinned(id: row['id'] as String, expectedRowRev: row['row_rev'] as int, pinned: true);
      expect(await worker.consolidate(), CompanionMemoryWork.waiting);
      expect(calls, 1);
      phone.now += 86400001;
      expect(await worker.consolidate(), CompanionMemoryWork.committed);
      expect(calls, 2);
    },
  );

  test('a complete invalid consolidation is examined once and does not become an automatic format retry', () async {
    final phone = _Phone()..pair();
    var calls = 0;
    final worker = phone.withHttp((request) async {
      calls++;
      _input(request);
      return _reply('{broken');
    });
    expect(await worker.consolidate(), CompanionMemoryWork.invalid);
    phone.now += 86400001;
    expect(await worker.consolidate(), CompanionMemoryWork.idle);
    expect(phone.store.cards(), hasLength(2));
    expect(calls, 1);
  });

  test('complete empty result commits the exact saved source and raw final receipt', () async {
    final phone = _Phone();
    phone.say('u1', '  今天就随便聊聊。\n');
    final worker = phone.withHttp((request) async {
      expect(phone.store.requests().single['state'], 'sent');
      final input = _input(request);
      final source = (input['source']! as List).single as Map;
      expect(source['id'], 'u1');
      expect(source['text'], '  今天就随便聊聊。\n');
      expect(source['said_at_utc'], DateTime.fromMillisecondsSinceEpoch(phone.now, isUtc: true).toIso8601String());
      expect(source['offset_minutes'], 480);
      return _reply(_empty(input));
    });
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.committed);
    expect(phone.db.select('SELECT state FROM memory_events').single['state'], 'done');
    expect(phone.store.cards(), isEmpty);
    final receipt = phone.store.requests().single;
    final raw = receipt['raw_usage'] is String ? jsonDecode(receipt['raw_usage'] as String) : receipt['raw_usage'];
    expect((raw as Map)['final_usage'], _usage);
    expect(raw['input_uncached'], 20);
    expect(raw['start_usage'], {'input_tokens': 900});
  });

  test('two complete malformed replies skip only their stable batch despite a newer input', () async {
    final phone = _Phone();
    phone.say('u1', '今天咖啡喝无糖。');
    final batches = <Object?>[];
    final worker = phone.withHttp((request) async {
      final input = _input(request);
      batches.add(input['batch_id']);
      expect((input['source']! as List).map((s) => (s as Map)['id']), ['u1']);
      return _reply('{broken');
    });
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.invalid);
    phone.say('u2', '我还开始学手风琴。');
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.invalid);
    expect(batches[0], batches[1]);
    final rows = phone.db.select('SELECT message_id,state,format_failures FROM memory_events ORDER BY seq');
    expect(rows[0]['state'], 'skipped');
    expect(rows[0]['format_failures'], 2);
    expect(rows[1]['state'], 'pending');
    expect(rows[1]['format_failures'], 0);
    expect(phone.store.requests(), hasLength(2));
  });

  test('401 counts a sent request but consumes no format retry; empty key sends nothing', () async {
    final phone = _Phone();
    phone.say('u1', '我的咖啡喝无糖。');
    final worker = phone.withHttp((_) async => http.Response('unauthorized', 401));
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.configuration);
    expect(phone.store.requests().single['sent_at_ms'], phone.now);
    expect(phone.db.select('SELECT format_failures FROM memory_events').single['format_failures'], 0);
    expect(phone.store.archive['cursor_seq'], 0);
    final noKey = phone.withHttp((_) async => throw StateError('must not send'), key: ' ');
    expect(await noKey.extract(forceTail: true), CompanionMemoryWork.configuration);
    expect(phone.store.requests(), hasLength(1));
  });

  test('missing message_stop preserves usage and leaves the batch waiting', () async {
    final phone = _Phone();
    phone.say('u1', '聊两句吧。');
    final worker = phone.withHttp((request) async => _reply(_empty(_input(request)), complete: false));
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.waiting);
    expect(phone.store.requests().single['terminal'], 'incomplete');
    expect(phone.db.select('SELECT state,format_failures FROM memory_events').single, containsPair('state', 'pending'));
    expect(phone.db.select('SELECT format_failures FROM memory_events').single['format_failures'], 0);
  });

  test('unsupported model or request parameters are configuration, not network or bad JSON', () async {
    for (final status in [400, 404, 422]) {
      final phone = _Phone();
      phone.say('u1', '咖啡不要糖。');
      final worker = phone.withHttp((_) async => http.Response('unsupported request', status));
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.configuration);
      expect(phone.store.requests().single['sent_at_ms'], phone.now);
      expect(phone.db.select('SELECT format_failures FROM memory_events').single['format_failures'], 0);
      expect(phone.store.archive['cursor_seq'], 0);
    }
  });

  test('a source edit while the provider is away discards even a malformed old answer', () async {
    final phone = _Phone();
    phone.say('u1', '明天面试。');
    final started = Completer<void>();
    final answer = Completer<http.Response>();
    final worker = phone.withHttp((_) {
      started.complete();
      return answer.future;
    });
    final result = worker.extract(forceTail: true);
    await started.future;
    phone.now += const Duration(days: 2).inMilliseconds;
    phone.store.editMessage(id: 'u1', expectedSourceRev: 1, text: '明天上午面试。');
    answer.complete(_reply('{bad'));
    expect(await result, CompanionMemoryWork.stale);
    final message = phone.store.messages().single;
    expect(message['first_seq'], 1);
    expect(message['source_rev'], 2);
    expect(message['said_at_utc'], phone.now - const Duration(days: 2).inMilliseconds);
    expect(phone.db.select('SELECT SUM(format_failures) AS n FROM memory_events').single['n'], 0);
    expect(phone.store.cards(), isEmpty);
  });

  test('max_tokens with message_stop is a failed proposal, never empty success', () async {
    final phone = _Phone();
    phone.say('u1', '咖啡不要糖。');
    final worker = phone.withHttp((request) async => _reply(_empty(_input(request)), stop: 'max_tokens'));
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.invalid);
    expect(phone.store.archive['cursor_seq'], 0);
    expect(phone.db.select('SELECT format_failures FROM memory_events').single['format_failures'], 1);
  });

  test('room cancellation fences a late valid answer and retains its sent receipt', () async {
    final phone = _Phone();
    phone.say('u1', '你好。');
    final started = Completer<Map<String, Object?>>();
    final answer = Completer<http.Response>();
    final worker = phone.withHttp((request) {
      started.complete(_input(request));
      return answer.future;
    });
    final result = worker.extract(forceTail: true);
    final input = await started.future;
    worker.cancel();
    answer.complete(_reply(_empty(input)));
    expect(await result, CompanionMemoryWork.stale);
    expect(phone.store.requests().single['sent_at_ms'], phone.now);
    expect(phone.store.archive['cursor_seq'], 0);
    expect(phone.db.select('SELECT format_failures FROM memory_events').single['format_failures'], 0);
  });
}
