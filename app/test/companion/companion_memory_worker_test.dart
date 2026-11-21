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

const _usage = {'input_tokens': 20, 'cache_read_input_tokens': 0, 'cache_creation_input_tokens': 0, 'output_tokens': 12};

http.Response _reply(String text, {String stop = 'end_turn', bool complete = true}) => http.Response([
  {'type': 'message_start', 'message': {'usage': {'input_tokens': 900}}},
  {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': text}},
  {'type': 'message_delta', 'delta': {'stop_reason': stop}, 'usage': _usage},
  if (complete) {'type': 'message_stop'},
].map((event) => 'data: ${jsonEncode(event)}\n\n').join(), 200);

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

  void say(String id, String text) => store.submitMessage(
    id: id, sessionId: 'light', text: text, saidAtUtc: now, offsetMinutes: 480,
  );

  CompanionMemoryWorker withHttp(Future<http.Response> Function(http.Request) answer, {String key = 'test'}) {
    final route = CompanionLightMemoryTransport(apiKey: () => key, client: () => MockClient(answer));
    return worker = CompanionMemoryWorker(store: store, transport: () => route,
      nowMilliseconds: () => now, estimateTokens: (text) => text.runes.length);
  }
}

void main() {
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
    expect(phone.db.select('SELECT state,format_failures FROM memory_events').single,
      containsPair('state', 'pending'));
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
