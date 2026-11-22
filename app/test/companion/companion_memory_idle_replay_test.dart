// r2 fixture 15. A fixed complete opportunity sequence, not an OS scheduling
// promise. HTTP is the real light request path with fixed MockClient SSE.
import 'dart:convert';

import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _usage = {
  'input_tokens': 20,
  'cache_read_input_tokens': 3,
  'cache_creation_input_tokens': 0,
  'output_tokens': 12,
};

class _Phone {
  _Phone() {
    store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now);
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'offline-replay-placeholder',
      client: () => MockClient((request) async {
        final body = jsonDecode(request.body) as MemoryRow;
        posts.add(body);
        final messages = (body['messages'] as List).cast<MemoryRow>();
        expect(messages, hasLength(1));
        final input = jsonDecode(messages.single['content'] as String) as MemoryRow;
        final receipt = store.requests().singleWhere((row) => row['batch_id'] == input['batch_id']);
        expect(receipt['state'], 'sent');
        expect(receipt['sent_at_ms'], now);
        expect(receipt['batch_id'], input['batch_id']);
        final proposal = answer(input);
        return http.Response.bytes(
          utf8.encode(
            [
              {
                'type': 'message_start',
                'message': {
                  'usage': {'input_tokens': 900},
                },
              },
              {
                'type': 'content_block_delta',
                'delta': {'type': 'text_delta', 'text': jsonEncode(proposal)},
              },
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'end_turn'},
                'usage': _usage,
              },
              {'type': 'message_stop'},
            ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
          ),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }),
    );
    worker = CompanionMemoryWorker(
      store: store,
      transport: () => route,
      nowMilliseconds: () => now,
      estimateTokens: estimateCompanionMemoryTokens,
    );
    addTearDown(() async {
      await worker.stop();
      store.close();
    });
  }

  int now = DateTime.utc(2026, 11, 21).millisecondsSinceEpoch;
  late final CompanionMemoryStore store;
  late final CompanionMemoryWorker worker;
  final posts = <MemoryRow>[];
  MemoryRow Function(MemoryRow) answer = (_) => throw StateError('No cloud request expected');

  void say(String id, String text) =>
      store.submitMessage(id: id, sessionId: 'light', text: text, saidAtUtc: now, offsetMinutes: 480);
}

Future<void> _quietDay(_Phone phone) async {
  final start = phone.now;
  final before = phone.store.requests();
  final postsBefore = phone.posts.length;
  phone.answer = (_) => throw StateError('An unchanged archive must not send');
  // This is the entire predefined sequence: 25 opportunities, including both
  // endpoints of the 24-hour interval. No opportunity is skipped or sampled.
  for (var hour = 0; hour <= 24; hour++) {
    phone.now = start + Duration(hours: hour).inMilliseconds;
    expect(await phone.worker.extract(), CompanionMemoryWork.idle, reason: 'extract at hour $hour');
    expect(await phone.worker.consolidate(), CompanionMemoryWork.idle, reason: 'organize at hour $hour');
    expect(phone.posts, hasLength(postsBefore), reason: 'HTTP at hour $hour');
    expect(phone.store.requests(), before, reason: 'receipts at hour $hour');
  }
}

void main() {
  test('fixture 15 empty archive makes no auxiliary HTTP request across 24 hours of opportunities', () async {
    final phone = _Phone();
    await _quietDay(phone);
    expect(phone.posts, isEmpty);
    expect(phone.store.requests(), isEmpty);
    expect(phone.store.cards(), isEmpty);
  });

  test('fixture 15 an examined unchanged archive makes no auxiliary HTTP request across 24 hours', () async {
    final phone = _Phone();
    phone.say('a', '酸奶我只买原味。');
    phone.say('b', '我买酸奶一直只选原味。');
    phone.now += const Duration(minutes: 3).inMilliseconds;
    phone.answer = (input) => {
      'schema_version': 2,
      'batch_id': input['batch_id'],
      'covered_message_ids': ['a', 'b'],
      'completion': 'complete',
      'operations': <MemoryRow>[
        {
          'op': 'create',
          'kind': 'preference',
          'text': '你买酸奶只选原味。',
          'keywords': ['酸奶'],
          'evidence': <MemoryRow>[
            {'message_id': 'a', 'quote': '酸奶我只买原味。'},
          ],
        },
        {
          'op': 'create',
          'kind': 'preference',
          'text': '酸奶你只买原味的。',
          'keywords': ['酸奶'],
          'evidence': <MemoryRow>[
            {'message_id': 'b', 'quote': '我买酸奶一直只选原味。'},
          ],
        },
      ],
    };
    expect(await phone.worker.extract(), CompanionMemoryWork.committed);
    phone.answer = (input) {
      expect((input['rows'] as List), hasLength(2));
      return {'schema_version': 2, 'batch_id': input['batch_id'], 'operations': [], 'completion': 'complete'};
    };
    expect(await phone.worker.consolidate(), CompanionMemoryWork.committed);
    expect(phone.posts, hasLength(2));
    expect(phone.posts.first['system'], companionMemoryExtractionPrompt);
    expect(phone.posts.last['system'], companionMemoryConsolidationPrompt);
    final receipts = phone.store.requests();
    expect(receipts, hasLength(2));
    expect(receipts.map((row) => row['category']), unorderedEquals(['extract', 'organize']));
    for (final receipt in receipts) {
      expect(receipt['sent_at_ms'], phone.now);
      expect(receipt['terminal'], 'complete');
      expect((receipt['raw_usage'] as MemoryRow)['final_usage'], _usage);
    }
    // Two distinct sentences still exist. Zero subsequent cloud work is due
    // to examined versions, not to an empty candidate set after a local merge.
    final retained = phone.store.cards().map((row) => row['text']).toSet();
    expect(retained, {'你买酸奶只选原味。', '酸奶你只买原味的。'});
    await _quietDay(phone);
    expect(phone.store.cards().map((row) => row['text']).toSet(), retained);
  });
}
