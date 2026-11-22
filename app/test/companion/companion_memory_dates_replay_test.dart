// r2 fixture 2: real store -> worker -> light HTTP/SSE adapter -> receipt.
// Proposals below are fixed test data. Passing proves the outbound clocks and
// acceptance path, not that a model understands relative dates.
import 'dart:convert';

import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _finalUsage = {
  'input_tokens': 20,
  'cache_read_input_tokens': 3,
  'cache_creation_input_tokens': 0,
  'output_tokens': 12,
};
const _afternoon = {'local_date': '2026-11-03', 'precision': 'part_of_day', 'wording': '明天下午'};
const _tuesday = {'local_date': '2026-11-03', 'precision': 'day', 'wording': '明天'};
const _thursday = {'local_date': '2026-11-05', 'precision': 'day', 'wording': '明天'};

MemoryRow _exhibition(String id, String quote, String text, MemoryRow time) => {
  'op': 'create',
  'kind': 'episode',
  'text': text,
  'keywords': ['纸展'],
  'evidence': <MemoryRow>[
    {'message_id': id, 'quote': quote},
  ],
  'event_time': time,
};

http.Response _reply(String proposal) => http.Response.bytes(
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
        'delta': {'type': 'text_delta', 'text': proposal},
      },
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': _finalUsage,
      },
      {'type': 'message_stop'},
    ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  ),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

class _Phone {
  _Phone(this.now) {
    store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now);
    addTearDown(() async {
      await worker?.stop();
      store.close();
    });
  }

  int now;
  late final CompanionMemoryStore store;
  CompanionMemoryWorker? worker;
  final inputs = <MemoryRow>[];

  MemoryRow say(String id, String text) =>
      store.submitMessage(id: id, sessionId: 'light', text: text, saidAtUtc: now, offsetMinutes: 480);

  Future<void> extract(MemoryRow fixedOperation) async {
    final callsBefore = inputs.length;
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'offline-replay-placeholder',
      client: () => MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), companionLightEndpoint);
        final body = jsonDecode(request.body) as MemoryRow;
        expect(body['model'], companionLightModel);
        expect(body['system'], companionMemoryExtractionPrompt);
        expect(body['thinking'], {'type': 'disabled'});
        expect(body['stream'], isTrue);
        expect(body['max_tokens'], 800);
        expect(body.containsKey('tools'), isFalse);
        final messages = (body['messages'] as List).cast<MemoryRow>();
        expect(messages, hasLength(1));
        expect(messages.single['role'], 'user');
        final input = jsonDecode(messages.single['content'] as String) as MemoryRow;
        inputs.add(input);
        // Observe the production onSent callback before returning any bytes.
        final sent = store.requests().last;
        expect(sent['state'], 'sent');
        expect(sent['sent_at_ms'], now);
        expect(sent['batch_id'], input['batch_id']);
        return _reply(
          jsonEncode({
            'schema_version': 2,
            'batch_id': input['batch_id'],
            'covered_message_ids': [(fixedOperation['evidence'] as List<MemoryRow>).single['message_id']],
            'operations': <MemoryRow>[fixedOperation],
            'completion': 'complete',
          }),
        );
      }),
    );
    worker = CompanionMemoryWorker(
      store: store,
      transport: () => route,
      nowMilliseconds: () => now,
      estimateTokens: estimateCompanionMemoryTokens,
    );
    // These opportunities are already beyond the production tail threshold.
    expect(await worker!.extract(), CompanionMemoryWork.committed);
    expect(inputs, hasLength(callsBefore + 1));
    expect(store.messages().every((message) => message['extraction_state'] == 'done'), isTrue);
  }
}

void _receipt(MemoryRow receipt, int attemptedAt, String localDay) {
  expect(receipt['category'], 'extract');
  expect(receipt['provider'], 'deepseek');
  expect(receipt['model'], companionLightModel);
  expect(receipt['reserved_at_ms'], attemptedAt);
  expect(receipt['sent_at_ms'], attemptedAt);
  expect(receipt['state'], 'finished');
  expect(receipt['terminal'], 'complete');
  // The store keeps instants and rolling windows, not a local-day column.
  // This projection only checks the fixture's stated UTC+8 calling day.
  final local = DateTime.fromMillisecondsSinceEpoch(
    receipt['sent_at_ms'] as int,
    isUtc: true,
  ).add(const Duration(hours: 8));
  expect(local.toIso8601String().substring(0, 10), localDay);
  final raw = receipt['raw_usage'] as MemoryRow;
  expect(raw['start_usage'], {'input_tokens': 900});
  expect(raw['final_usage'], _finalUsage);
  expect(raw['usage_semantics'], 'cumulative');
  expect(raw['complete'], isTrue);
  expect(raw['http_status'], 200);
  expect(receipt['input_uncached'], 20);
  expect(receipt['input_cache_read'], 3);
  expect(receipt['input_cache_write'], 0);
  expect(receipt['output_tokens'], 12);
}

void _noFollowup(_Phone phone) {
  for (final card in phone.store.cards()) {
    expect(card['followup'], isNull);
  }
  // Invoke the real lazy derivation, so an empty table before derivation cannot pass.
  expect(phone.store.nextFollowup(nowMs: phone.now), isNull);
  expect(phone.store.followups(), isEmpty);
}

void main() {
  test('fixture 2 original time crosses midnight in actual extraction POST and usage receipt', () async {
    final saidAt = DateTime.utc(2026, 11, 2, 15, 55).millisecondsSinceEpoch; // 23:55 UTC+8.
    final firstCall = DateTime.utc(2026, 11, 2, 15, 58).millisecondsSinceEpoch; // 23:58 UTC+8.
    final laterCall = DateTime.utc(2026, 11, 3).millisecondsSinceEpoch; // Next day 08:00 UTC+8.
    final first = _Phone(saidAt);
    final later = _Phone(saidAt);
    expect(first.store.archive['id'], isNot(later.store.archive['id']));
    final original = <MemoryRow>[first.say('paper', '明天下午去看纸展'), later.say('paper', '明天下午去看纸展')];
    // The second archive gets no running opportunity overnight; no HTTP call
    // or reservation is invented for that period.
    expect(first.store.requests(), isEmpty);
    expect(later.store.requests(), isEmpty);
    first.now = firstCall;
    await first.extract(_exhibition('paper', '明天下午去看纸展', '你计划在11月3日下午去看纸展。', _afternoon));
    expect(later.inputs, isEmpty);
    expect(later.store.requests(), isEmpty);
    expect(later.store.messages().single['extraction_state'], 'pending');
    later.now = laterCall;
    await later.extract(_exhibition('paper', '明天下午去看纸展', '你计划在11月3日下午去看纸展。', _afternoon));

    for (var i = 0; i < 2; i++) {
      final phone = [first, later][i];
      final input = phone.inputs.single;
      expect(input['scope'], 'real');
      expect(input['processed_at_utc'], i == 0 ? '2026-11-02T15:58:00.000Z' : '2026-11-03T00:00:00.000Z');
      expect(input['source'], [
        {
          'id': 'paper',
          'first_seq': original[i]['first_seq'],
          'source_rev': 1,
          'said_at_utc': '2026-11-02T15:55:00.000Z',
          'offset_minutes': 480,
          'text': '明天下午去看纸展',
        },
      ]);
      expect(input['existing'], isEmpty);
      final card = phone.store.cards().single;
      expect(card['event_time'], _afternoon); // Exact three keys: no invented clock hour.
      expect(card['text'], '你计划在11月3日下午去看纸展。');
      final proof = (card['evidence'] as List).cast<MemoryRow>().single;
      expect(proof['said_at_utc'], saidAt);
      expect(proof['offset_minutes'], 480);
      expect(proof['source_rev'], 1);
      _noFollowup(phone);
      _receipt(phone.store.requests().single, i == 0 ? firstCall : laterCall, i == 0 ? '2026-11-02' : '2026-11-03');
    }
  });

  test('fixture 2 editing Monday text keeps Tuesday while a new Wednesday source stores Thursday', () async {
    final monday = DateTime.utc(2026, 11, 2, 15, 55).millisecondsSinceEpoch;
    final mondayCall = DateTime.utc(2026, 11, 2, 15, 58).millisecondsSinceEpoch;
    final wednesday = DateTime.utc(2026, 11, 4).millisecondsSinceEpoch; // Wednesday 08:00 UTC+8.
    final wednesdayCall = DateTime.utc(2026, 11, 4, 0, 3).millisecondsSinceEpoch;
    final edited = _Phone(monday);
    final fresh = _Phone(monday);
    final originals = <MemoryRow>[];
    for (final phone in [edited, fresh]) {
      originals.add(phone.say('monday', '小鹿，明天去看纸展'));
      phone.now = mondayCall;
      await phone.extract(_exhibition('monday', '小鹿，明天去看纸展', '你计划在11月3日去看纸展。', _tuesday));
      expect(phone.store.cards().single['event_time'], _tuesday);
    }

    edited.now = wednesday;
    final correction = edited.store.editMessage(id: 'monday', expectedSourceRev: 1, text: '小露，明天去看纸展');
    expect(correction['first_seq'], originals[0]['first_seq']);
    expect(correction['said_at_utc'], monday);
    expect(correction['source_rev'], 2);
    expect(correction['edited_at_utc'], wednesday);
    fresh.now = wednesday;
    final newSource = fresh.say('wednesday', '小露，明天去看纸展');
    expect(newSource['first_seq'] as int, greaterThan(originals[1]['first_seq'] as int));
    expect(newSource['source_rev'], 1);
    expect(newSource['said_at_utc'], wednesday);
    expect(newSource['edited_at_utc'], isNull);

    edited.now = wednesdayCall;
    await edited.extract(_exhibition('monday', '小露，明天去看纸展', '你计划在11月3日去看纸展。', _tuesday));
    fresh.now = wednesdayCall;
    await fresh.extract(_exhibition('wednesday', '小露，明天去看纸展', '你计划在11月5日去看纸展。', _thursday));

    expect(edited.inputs.last['source'], [
      {
        'id': 'monday',
        'first_seq': originals[0]['first_seq'],
        'source_rev': 2,
        'said_at_utc': '2026-11-02T15:55:00.000Z',
        'offset_minutes': 480,
        'text': '小露，明天去看纸展',
        'edited_at_utc': '2026-11-04T00:00:00.000Z',
      },
    ]);
    expect(fresh.inputs.last['source'], [
      {
        'id': 'wednesday',
        'first_seq': newSource['first_seq'],
        'source_rev': 1,
        'said_at_utc': '2026-11-04T00:00:00.000Z',
        'offset_minutes': 480,
        'text': '小露，明天去看纸展',
      },
    ]);
    final kept = edited.store.cards().single;
    expect(kept['event_time'], _tuesday);
    expect((kept['evidence'] as List).cast<MemoryRow>().single['source_rev'], 2);
    expect(fresh.store.cards(), hasLength(2));
    final added = fresh.store.cards().singleWhere(
      (card) => (card['evidence'] as List).cast<MemoryRow>().any((proof) => proof['message_id'] == 'wednesday'),
    );
    expect(added['event_time'], _thursday);
    for (final phone in [edited, fresh]) {
      expect(phone.inputs, hasLength(2));
      expect(phone.inputs.first['source'], [
        {
          'id': 'monday',
          'first_seq': originals[phone == edited ? 0 : 1]['first_seq'],
          'source_rev': 1,
          'said_at_utc': '2026-11-02T15:55:00.000Z',
          'offset_minutes': 480,
          'text': '小鹿，明天去看纸展',
        },
      ]);
      expect(phone.inputs.last['processed_at_utc'], '2026-11-04T00:03:00.000Z');
      final receipts = phone.store.requests();
      expect(receipts, hasLength(2));
      expect(receipts.first['id'], isNot(receipts.last['id']));
      _receipt(receipts.first, mondayCall, '2026-11-02');
      _receipt(receipts.last, wednesdayCall, '2026-11-04');
      _noFollowup(phone);
    }
  });
}
