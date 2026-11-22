// r2 fixture 2: real store -> shared tool loop -> light HTTP/SSE -> receipts.
// Fixed tool bytes prove outbound clocks, validation and storage, not model
// understanding of relative dates. Each physical continuation owns a receipt.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
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

MemoryRow _exhibition(String id, String text, MemoryRow time) => {
  'source': id,
  'kind': 'episode',
  'text': text,
  'keywords': ['纸展'],
  'event_time': time,
};

http.Response _reply({MemoryRow? input, String? callId}) => http.Response.bytes(
  utf8.encode(
    [
      {
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 900},
        },
      },
      if (input != null) ...[
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'tool_use', 'id': callId, 'name': 'remember', 'input': <String, Object?>{}},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
        },
        {'type': 'content_block_stop', 'index': 0},
      ] else
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': '已按原话保存。'},
        },
      {
        'type': 'message_delta',
        'delta': {'stop_reason': input == null ? 'end_turn' : 'tool_use'},
        'usage': _finalUsage,
      },
      {'type': 'message_stop'},
    ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  ),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

// Compare actual outbound source values, without rebuilding the old envelope.
List<MemoryRow> _sourceClocks(MemoryRow input) => [
  for (final source in (input['sources'] as List).cast<MemoryRow>())
    {
      'id': source['id'],
      'first_seq': source['first_seq'],
      'source_rev': source['source_rev'],
      'said_at_utc': source['said_at_utc'],
      'offset_minutes': source['offset_minutes'],
      'text': source['text'],
      if (source['edited_at_utc'] != null) 'edited_at_utc': source['edited_at_utc'],
    },
];

class _Phone {
  _Phone(this.now) {
    store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now);
    owner = CompanionMemoryOwner(
      store,
      CompanionLocal.at(Directory('/unused-dates-replay')),
      nowMilliseconds: () => now,
    );
    addTearDown(() async {
      await worker?.stop();
      owner.dispose();
    });
  }

  int now;
  late final CompanionMemoryStore store;
  late final CompanionMemoryOwner owner;
  CompanionMemoryWorker? worker;
  final inputs = <MemoryRow>[];

  MemoryRow say(String id, String text) =>
      store.submitMessage(id: id, sessionId: 'light', text: text, saidAtUtc: now, offsetMinutes: 480);

  Future<void> extract(MemoryRow fixedInput) async {
    final inputsBefore = inputs.length;
    final requestIdsBefore = store.requests().map((row) => row['id']).toSet();
    final sentIds = <String>[];
    final callId = 'date-$inputsBefore';
    var posts = 0;
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'offline-replay-placeholder',
      client: () => MockClient((request) async {
        posts++;
        expect(request.method, 'POST');
        expect(request.url.toString(), companionLightEndpoint);
        final body = jsonDecode(request.body) as MemoryRow;
        expect(body['model'], companionLightModel);
        expect(body['system'], contains('phone memory using the supplied memory tools'));
        expect(body['thinking'], {'type': 'disabled'});
        expect(body['stream'], isTrue);
        expect(body['max_tokens'], 800);
        expect((body['tools'] as List).map((tool) => (tool as Map)['name']), contains('remember'));
        final messages = (body['messages'] as List).cast<MemoryRow>();
        expect(messages.first['role'], 'user');
        final input = jsonDecode(messages.first['content'] as String) as MemoryRow;
        expect(input['type'], 'memory_maintenance_context');
        expect(input['kind'], 'extract');
        expect((input['sources'] as List).cast<MemoryRow>().every((source) => source['scope'] == 'real'), isTrue);
        expect(input['processed_at_utc'], DateTime.fromMillisecondsSinceEpoch(now, isUtc: true).toIso8601String());
        // Observe production onSent before returning any provider bytes.
        final sent = store.requests().singleWhere((row) => row['state'] == 'sent' && row['terminal'] == null);
        expect(sent['sent_at_ms'], now);
        expect(requestIdsBefore, isNot(contains(sent['id'])));
        sentIds.add(sent['id'] as String);
        if (posts == 1) {
          expect(messages, hasLength(1));
          inputs.add(input);
          return _reply(input: fixedInput, callId: callId);
        }
        expect(posts, 2);
        expect(messages, hasLength(3));
        final results = (messages.last['content'] as List).cast<MemoryRow>();
        expect(results, hasLength(1));
        expect(results.single['type'], 'tool_result');
        expect(results.single['tool_use_id'], callId);
        expect((jsonDecode(results.single['content'] as String) as Map)['applied'], isTrue);
        return _reply();
      }),
    );
    worker = CompanionMemoryWorker(
      store: store,
      transport: () => route,
      nowMilliseconds: () => now,
      estimateTokens: estimateCompanionMemoryTokens,
      maintenanceTools: (turn, current, committed) => CompanionAgentMemoryTools.maintenance(
        memory: owner,
        turn: turn,
        isCurrent: current,
        forgottenNotice: '',
        onMaintenanceCommitted: ({required memory, required turnId, required beforeRevision, required revision}) {
          committed(memory: memory, turnId: turnId, beforeRevision: beforeRevision, revision: revision);
        },
      ),
    );
    // These opportunities are already beyond the production tail threshold.
    expect(await worker!.extract(offsetMinutes: 480), CompanionMemoryWork.committed);
    expect(inputs, hasLength(inputsBefore + 1));
    expect(posts, 2);
    expect(sentIds.toSet(), hasLength(2));
    final receipts = store.requests().where((row) => sentIds.contains(row['id'])).toList();
    expect(receipts, hasLength(2));
    expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(1));
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
    await first.extract(_exhibition('paper', '你计划在11月3日下午去看纸展。', _afternoon));
    expect(later.inputs, isEmpty);
    expect(later.store.requests(), isEmpty);
    expect(later.store.messages().single['extraction_state'], 'pending');
    later.now = laterCall;
    await later.extract(_exhibition('paper', '你计划在11月3日下午去看纸展。', _afternoon));

    for (var i = 0; i < 2; i++) {
      final phone = [first, later][i];
      final input = phone.inputs.single;
      expect((input['sources'] as List).cast<MemoryRow>().single['scope'], 'real');
      expect(input['processed_at_utc'], i == 0 ? '2026-11-02T15:58:00.000Z' : '2026-11-03T00:00:00.000Z');
      expect(_sourceClocks(input), [
        {
          'id': 'paper',
          'first_seq': original[i]['first_seq'],
          'source_rev': 1,
          'said_at_utc': DateTime.utc(2026, 11, 2, 15, 55).millisecondsSinceEpoch,
          'offset_minutes': 480,
          'text': '明天下午去看纸展',
        },
      ]);
      expect(input['cards'], isEmpty);
      final card = phone.store.cards().single;
      expect(card['event_time'], _afternoon); // Exact three keys: no invented clock hour.
      expect(card['text'], '你计划在11月3日下午去看纸展。');
      final proof = (card['evidence'] as List).cast<MemoryRow>().single;
      expect(proof['said_at_utc'], saidAt);
      expect(proof['offset_minutes'], 480);
      expect(proof['source_rev'], 1);
      _noFollowup(phone);
      expect(phone.store.requests(), hasLength(2));
      for (final receipt in phone.store.requests()) {
        _receipt(receipt, i == 0 ? firstCall : laterCall, i == 0 ? '2026-11-02' : '2026-11-03');
      }
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
      await phone.extract(_exhibition('monday', '你计划在11月3日去看纸展。', _tuesday));
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
    await edited.extract(_exhibition('monday', '你计划在11月3日去看纸展。', _tuesday));
    fresh.now = wednesdayCall;
    await fresh.extract(_exhibition('wednesday', '你计划在11月5日去看纸展。', _thursday));

    expect(_sourceClocks(edited.inputs.last), [
      {
        'id': 'monday',
        'first_seq': originals[0]['first_seq'],
        'source_rev': 2,
        'said_at_utc': DateTime.utc(2026, 11, 2, 15, 55).millisecondsSinceEpoch,
        'offset_minutes': 480,
        'text': '小露，明天去看纸展',
        'edited_at_utc': DateTime.utc(2026, 11, 4).millisecondsSinceEpoch,
      },
    ]);
    expect(_sourceClocks(fresh.inputs.last), [
      {
        'id': 'wednesday',
        'first_seq': newSource['first_seq'],
        'source_rev': 1,
        'said_at_utc': DateTime.utc(2026, 11, 4).millisecondsSinceEpoch,
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
      expect(_sourceClocks(phone.inputs.first), [
        {
          'id': 'monday',
          'first_seq': originals[phone == edited ? 0 : 1]['first_seq'],
          'source_rev': 1,
          'said_at_utc': DateTime.utc(2026, 11, 2, 15, 55).millisecondsSinceEpoch,
          'offset_minutes': 480,
          'text': '小鹿，明天去看纸展',
        },
      ]);
      expect(phone.inputs.last['processed_at_utc'], '2026-11-04T00:03:00.000Z');
      final receipts = phone.store.requests();
      expect(receipts, hasLength(4));
      expect(receipts.map((row) => row['id']).toSet(), hasLength(4));
      expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(2));
      for (final receipt in receipts) {
        final first = receipt['sent_at_ms'] == mondayCall;
        _receipt(receipt, first ? mondayCall : wednesdayCall, first ? '2026-11-02' : '2026-11-04');
      }
      _noFollowup(phone);
    }
  });
}
