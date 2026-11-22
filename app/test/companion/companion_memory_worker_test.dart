// Fixed provider bytes, real stream adapter -> worker -> SQLite queue/receipt.
// These tests use no keys, model, host, or real clock.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
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
      'index': 0,
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
  expect((body['tools'] as List).map((tool) => (tool as Map)['name']), containsAll(['remember', 'merge']));
  final messages = body['messages']! as List;
  return jsonDecode((messages.first as Map)['content'] as String) as Map<String, Object?>;
}

http.Response _tool(String name, String arguments, {String? text}) => http.Response(
  [
    {
      'type': 'message_start',
      'message': {
        'usage': {'input_tokens': 900},
      },
    },
    if (text != null) ...[
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text', 'text': text},
      },
      {'type': 'content_block_stop', 'index': 0},
    ],
    {
      'type': 'content_block_start',
      'index': text == null ? 0 : 1,
      'content_block': {'type': 'tool_use', 'id': 'maintenance-call', 'name': name, 'input': <String, Object?>{}},
    },
    {
      'type': 'content_block_delta',
      'index': text == null ? 0 : 1,
      'delta': {'type': 'input_json_delta', 'partial_json': arguments},
    },
    {'type': 'content_block_stop', 'index': text == null ? 0 : 1},
    {
      'type': 'message_delta',
      'delta': {'stop_reason': 'tool_use'},
      'usage': _usage,
    },
    {'type': 'message_stop'},
  ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

http.Response _merge(Map<String, Object?> input) {
  final rows = (input['cards']! as List).cast<Map>();
  return _tool(
    'merge',
    jsonEncode({
      'card': rows.first['id'],
      'from': [rows.last['id']],
    }),
  );
}

class _Phone {
  _Phone() {
    store = CompanionMemoryStore(db, nowMilliseconds: () => now);
    memory = CompanionMemoryOwner(
      store,
      CompanionLocal.at(Directory('/unused-memory-worker-test')),
      nowMilliseconds: () => now,
    );
    addTearDown(() async {
      await worker?.stop();
      dispose();
    });
  }

  final db = sqlite3.openInMemory();
  int now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;
  late final CompanionMemoryStore store;
  late final CompanionMemoryOwner memory;
  CompanionMemoryWorker? worker;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    memory.dispose();
  }

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

  CompanionMemoryWorker withHttp(
    Future<http.Response> Function(http.Request) answer, {
    String key = 'test',
    int Function(String)? estimate,
  }) {
    final route = CompanionLightMemoryTransport(apiKey: () => key, client: () => MockClient(answer));
    return worker = CompanionMemoryWorker(
      store: store,
      transport: () => route,
      nowMilliseconds: () => now,
      estimateTokens: estimate ?? estimateCompanionMemoryTokens,
      maintenanceTools: (turn, current, committed) => CompanionAgentMemoryTools.maintenance(
        memory: memory,
        turn: turn,
        isCurrent: current,
        forgottenNotice: '',
        onMaintenanceCommitted: ({required memory, required turnId, required beforeRevision, required revision}) {
          committed(memory: memory, turnId: turnId, beforeRevision: beforeRevision, revision: revision);
          expect(
            worker!.acceptsControl(revision),
            isTrue,
            reason: 'the real own commit advances this live claim before changed',
          );
        },
      ),
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

  test('A2 safe exact local consolidation needs no credentials and an oversized model envelope leaves other cards untouched', () async {
    final exact = _Phone()..pair(exact: true);
    var calls = 0;
    Future<http.Response> unexpected(http.Request _) async {
      calls++;
      throw StateError('no request expected');
    }

    final noKey = exact.withHttp(unexpected, key: '');
    expect(await noKey.consolidate(), CompanionMemoryWork.committed);
    expect(exact.store.cards(), hasLength(1));
    expect(exact.store.requests(), isEmpty);
    expect(exact.db.select('SELECT * FROM memory_agent_maintenance_claims'), isEmpty);
    final phone = _Phone()..pair();
    final tooLarge = phone.withHttp(unexpected, estimate: (_) => memoryBatchInputTokens + 1);
    expect(await tooLarge.consolidate(), CompanionMemoryWork.idle);
    expect(phone.store.cards(), hasLength(2), reason: 'different wording is not a local exact merge');
    expect(phone.store.requests(), isEmpty);
    expect(phone.db.select('SELECT * FROM memory_agent_maintenance_claims'), isEmpty);
    expect(calls, 0);
  });

  test('ADD46 character extraction completes two remembered originals with a fully metered continuation', () async {
    final phone = _Phone();
    final role = phone.store.ensureCompanionCharacter(sourceKey: 'local:maintenance-continuation')['id']! as String;
    // The actual owner Page fixture 2 originals and remember arguments. This
    // focused Worker entry does not replace that Page/SQLite reopening case.
    const words = ['我改学长笛了', '老师约在周六'];
    final originals = <MemoryRow>[
      for (var i = 0; i < words.length; i++)
        phone.store.submitMessage(
          id: 'continuation-source-${i + 1}',
          sessionId: 'light',
          text: words[i],
          saidAtUtc: phone.now,
          offsetMinutes: 480,
          characterId: role,
        ),
    ];
    final captured = <({String body, MemoryRow receipt})>[];
    final worker = phone.withHttp((request) async {
      captured.add((
        body: request.body,
        receipt: Map<String, Object?>.from(phone.store.requests().singleWhere((row) => row['state'] == 'sent')),
      ));
      if (captured.length != 1) return _reply('Done.');
      final body = jsonDecode(request.body) as Map;
      final input = jsonDecode(((body['messages'] as List).first as Map)['content'] as String) as Map;
      final sources = (input['sources'] as List).cast<Map>().where((row) => row['role'] == 'user').toList()
        ..sort((a, b) => (a['first_seq']! as int).compareTo(b['first_seq']! as int));
      return http.Response(
        [
          {
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 900},
            },
          },
          for (var i = 0; i < sources.length; i++) ...[
            {
              'type': 'content_block_start',
              'index': i,
              'content_block': {
                'type': 'tool_use',
                'id': 'fixture2-${i + 1}',
                'name': 'remember',
                'input': <String, Object?>{},
              },
            },
            {
              'type': 'content_block_delta',
              'index': i,
              'delta': {
                'type': 'input_json_delta',
                'partial_json': jsonEncode({'source': sources[i]['id'], 'kind': 'fact', 'text': sources[i]['text']}),
              },
            },
            {'type': 'content_block_stop', 'index': i},
          ],
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': _usage,
          },
          {'type': 'message_stop'},
        ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
    });

    expect(await worker.extract(forceTail: true, offsetMinutes: 480), CompanionMemoryWork.committed);
    expect(captured, hasLength(2));
    final bodies = [for (final request in captured) jsonDecode(request.body) as Map];
    final contexts = [
      for (final body in bodies) jsonDecode(((body['messages'] as List).first as Map)['content'] as String) as Map,
    ];
    for (final request in captured) {
      expect(request.receipt['category'], 'extract');
      expect(request.receipt['reserved_input'], estimateCompanionMemoryTokens(request.body));
    }
    expect(estimateCompanionMemoryTokens(captured.first.body), lessThanOrEqualTo(memoryBatchInputTokens));
    expect(bodies.last['tools'], bodies.first['tools'], reason: 'selection and continuation use one fixed profile');
    expect(
      (bodies.first['tools'] as List).map((tool) => (tool as Map)['name']),
      unorderedEquals([
        'remember',
        'forget',
        'revise',
        'related',
        'merge',
        'person',
        'impression',
        'relationship',
        'quiet',
        'cancel',
        'postpone',
        'ask_later',
        'recall',
      ]),
      reason: 'compaction does not silently remove a maintenance capability',
    );
    for (final input in contexts) {
      expect(input['kind'], 'extract');
      expect(input['character_id'], role);
      final sources = (input['sources'] as List).cast<Map>();
      expect(sources, hasLength(2));
      for (final original in originals) {
        final source = sources.singleWhere((row) => row['id'] == original['id']);
        for (final field in [
          'id',
          'first_seq',
          'source_rev',
          'text',
          'said_at_utc',
          'offset_minutes',
          'character_id',
        ]) {
          expect(source[field], original[field], reason: field);
        }
      }
    }
    expect(contexts.first['cards'], isEmpty);
    expect(contexts.last['cards'], hasLength(2), reason: 'the actual writes are reread before the continuation');
    final messages = bodies.last['messages'] as List;
    final calls = ((messages[1] as Map)['content'] as List).cast<Map>();
    expect(calls.map((call) => call['id']), ['fixture2-1', 'fixture2-2']);
    expect(calls.map((call) => (call['input'] as Map)['text']), words);
    final results = ((messages.last as Map)['content'] as List).cast<Map>();
    expect(results.map((result) => result['tool_use_id']), ['fixture2-1', 'fixture2-2']);
    expect(results.first['content'], contains('retired after memory changed'));
    expect((jsonDecode(results.last['content'] as String) as Map)['applied'], isTrue);

    final restored = phone.store.messages();
    final cards = phone.store.cards();
    expect(restored, hasLength(2));
    expect(cards, hasLength(2));
    for (final original in originals) {
      final source = restored.singleWhere((row) => row['id'] == original['id']);
      expect(source['text'], original['text']);
      expect(source['extraction_state'], 'done');
      expect(source['format_failures'], 0);
      final proof = (cards.singleWhere((row) => row['text'] == original['text'])['evidence'] as List).single as Map;
      expect(proof['message_id'], original['id']);
      expect(proof['source_rev'], original['source_rev']);
      expect(proof['quote'], original['text']);
    }
    final receipts = phone.store.requests();
    expect(receipts, hasLength(2));
    expect(receipts.map((row) => row['id']).toSet(), hasLength(2));
    expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(1));
    for (final receipt in receipts) {
      expect(receipt['batch_id'], isA<String>());
      expect(receipt['state'], 'finished');
      expect(receipt['terminal'], 'complete');
      expect(receipt['sent_at_ms'], isNotNull);
      expect((receipt['raw_usage'] as Map)['final_usage'], _usage);
    }
  });

  for (final physicalInput in [6500, 11501]) {
    test('ADD47 maintenance continuation input $physicalInput keeps full accounting and a bounded increment', () async {
      final phone = _Phone();
      phone.say('increment-source', '我的咖啡喝无糖。');
      final allowed = physicalInput == 6500;
      final sent = <MemoryRow>[];
      // Use the existing estimator seam for exact budget boundaries. These
      // controlled costs are not claimed as provider or production estimates;
      // the two-original case above checks the real estimator and wire body.
      int estimate(String text) {
        Object? value;
        try {
          value = jsonDecode(text);
        } on FormatException {
          return estimateCompanionMemoryTokens(text);
        }
        if (value is! Map || value['messages'] is! List || value['tools'] is! List) {
          return estimateCompanionMemoryTokens(text);
        }
        return (value['messages'] as List).length == 1 ? 5500 : physicalInput;
      }

      final worker = phone.withHttp((request) async {
        sent.add(Map<String, Object?>.from(phone.store.requests().singleWhere((row) => row['state'] == 'sent')));
        expect(sent.last['reserved_input'], estimate(request.body));
        if (sent.length == 1) {
          final source = (_input(request)['sources'] as List).single as Map;
          return _tool('remember', jsonEncode({'source': source['id'], 'text': source['text'], 'kind': 'fact'}));
        }
        final body = jsonDecode(request.body) as Map;
        final messages = body['messages'] as List;
        final context = jsonDecode((messages.first as Map)['content'] as String) as Map;
        expect((context['sources'] as List).single, containsPair('text', '我的咖啡喝无糖。'));
        expect(context['cards'], hasLength(1));
        expect(messages, hasLength(3), reason: 'the real tool call/result pair stays on the continuation');
        expect((messages[1] as Map)['role'], 'assistant');
        expect((messages[2] as Map)['role'], 'user');
        return _reply('Done.');
      }, estimate: estimate);

      expect(
        await worker.extract(forceTail: true, offsetMinutes: 480),
        allowed ? CompanionMemoryWork.committed : CompanionMemoryWork.waiting,
      );
      expect(sent, hasLength(allowed ? 2 : 1));
      expect(sent.first['reserved_input'], 5500);
      if (allowed) {
        expect(sent.last['reserved_input'], 6500, reason: 'the full physical cost is reserved, not the 1000 increment');
        expect(phone.store.messages().single['extraction_state'], 'done');
      } else {
        expect(phone.store.messages().single['extraction_state'], 'skipped');
      }
      expect(phone.store.cards().single['text'], '我的咖啡喝无糖。');
      final receipts = phone.store.requests();
      expect(receipts, hasLength(allowed ? 2 : 1));
      for (final receipt in receipts) {
        expect(receipt['state'], 'finished');
        expect((receipt['raw_usage'] as Map)['final_usage'], _usage);
      }
    });
  }

  test(
    'maintenance forget keeps independent local proof out of later HTTP input while fresh OR proof remains usable',
    () async {
      final phone = _Phone();
      const original = '我住杭州，也养猫。';
      const support = '养猫这件事没有变化。';
      phone.say('home-and-cat', original);
      phone.say('cat-support', support);
      final batch = phone.store.nextBatch(forceTail: true, estimateTokens: estimateCompanionMemoryTokens)!;
      final proposal = parseExtractionProposal(
        jsonEncode({
          'schema_version': 2,
          'batch_id': batch.id,
          'covered_message_ids': [for (final source in batch.sources) source['id']],
          'completion': 'complete',
          'operations': [
            {
              'op': 'create',
              'kind': 'fact',
              'text': '我住杭州。',
              'keywords': ['杭州'],
              'evidence': [
                {'message_id': 'home-and-cat', 'quote': original},
              ],
            },
            {
              'op': 'create',
              'kind': 'fact',
              'text': '我养猫。',
              'keywords': ['养猫'],
              'evidence': [
                {'message_id': 'home-and-cat', 'quote': original},
                {'message_id': 'cat-support', 'quote': support},
              ],
            },
          ],
        }),
        batch,
      );
      expect(phone.store.commitExtraction(batch, proposal), isTrue);
      final home = phone.store.cards().singleWhere((row) => row['text'] == '我住杭州。');
      final cat = phone.store.cards().singleWhere((row) => row['text'] == '我养猫。');
      final originalProof = (cat['evidence'] as List).cast<MemoryRow>();
      expect(originalProof.map((proof) => proof['support_group']).toSet(), hasLength(1));
      expect(originalProof.map((proof) => proof['message_id']), unorderedEquals(['home-and-cat', 'cat-support']));
      phone.say('forget-home', '不要记住我的住处，养猫这件事保留。');
      phone.now += const Duration(days: 1).inMilliseconds;
      final bodies = <Map<String, Object?>>[];
      final measured = <int>[];
      final worker = phone.withHttp((request) async {
        bodies.add(Map<String, Object?>.from(jsonDecode(request.body) as Map));
        measured.add(estimateCompanionMemoryTokens(request.body));
        return bodies.length == 1
            ? _tool('forget', jsonEncode({'card': home['id']}), text: '我会忘掉杭州的住处，只保留养猫这件事。')
            : _reply('Done.');
      });
      expect(await worker.consolidate(offsetMinutes: 480), CompanionMemoryWork.committed);
      expect(bodies, hasLength(2));
      expect(jsonEncode(bodies.first), contains(original));
      expect(jsonEncode(bodies.last), isNot(contains('杭州')));
      final continuation = jsonDecode(((bodies.last['messages'] as List).first as Map)['content'] as String) as Map;
      expect(continuation['sources'], isEmpty);
      final kept = (continuation['cards'] as List).single as Map;
      expect(kept['id'], cat['id']);
      expect(kept['row_rev'], cat['row_rev']);
      expect(kept['text'], '我养猫。');
      expect(kept['evidence'], isEmpty);
      final messages = bodies.last['messages'] as List;
      expect(messages, hasLength(3));
      expect((messages[1] as Map)['role'], 'assistant');
      final calls = ((messages[1] as Map)['content'] as List).cast<Map>();
      expect(calls, hasLength(1), reason: 'the pre-forget assistant text is no longer model input');
      expect(calls.single['type'], 'tool_use');
      expect(calls.single['id'], 'maintenance-call');
      expect(calls.single['name'], 'forget');
      expect(calls.single['input'], {'_retired_after_memory_change': true});
      final result = ((messages.last as Map)['content'] as List).single as Map;
      expect(result['tool_use_id'], 'maintenance-call');
      expect((jsonDecode(result['content'] as String) as Map)['applied'], isTrue);
      final keptLocal = phone.store.cards().single;
      expect(keptLocal['id'], cat['id']);
      expect(keptLocal['row_rev'], cat['row_rev']);
      expect(keptLocal['text'], cat['text']);
      expect(keptLocal['evidence'], originalProof, reason: 'the complete independent AND proof remains local');
      expect(phone.store.messages().singleWhere((row) => row['id'] == 'home-and-cat')['text'], original);
      expect(phone.store.requests(), hasLength(2));
      expect(phone.store.requests().map((row) => row['batch_id']).toSet(), hasLength(1));

      // A real later source may independently support the retained fact. Keep
      // the old two-source AND group locally and add a new, valid OR group via
      // the real semantic-merge tool; do not forge rows or trim a quote.
      phone.say('fresh-cat', '我现在仍然养猫。');
      final source = phone.store.messages().singleWhere((row) => row['id'] == 'fresh-cat');
      expect(source['first_seq'], greaterThan(phone.store.archive['history_after_seq']! as int));
      final turn =
          phone.store.beginAgentTurn(
                messageId: source['id']! as String,
                expectedSourceRev: source['source_rev']! as int,
                shownCardRevisions: {cat['id']! as String: cat['row_rev']! as int},
              )['id']!
              as String;
      final fresh = phone.store.applyAgentMemoryTool(
        turnId: turn,
        callId: 'fresh-proof',
        toolName: 'remember',
        input: {'text': '我养猫。'},
      );
      expect(fresh.applied, isTrue);
      expect(
        phone.store
            .applyAgentMemoryTool(
              turnId: turn,
              callId: 'merge-fresh-proof',
              toolName: 'merge',
              input: {
                'card': cat['id'],
                'from': [fresh.targetId],
              },
            )
            .applied,
        isTrue,
      );
      phone.store.closeAgentTurn(turn);
      final retained = phone.store.cards().single;
      final localProof = (retained['evidence'] as List).cast<MemoryRow>();
      final localGroups = <String, Set<Object?>>{};
      for (final proof in localProof) {
        (localGroups[proof['support_group']! as String] ??= {}).add(proof['message_id']);
      }
      expect(
        localGroups.values,
        unorderedEquals([
          {'home-and-cat', 'cat-support'},
          {'fresh-cat'},
        ]),
      );
      expect(await worker.extract(forceTail: true, offsetMinutes: 480), CompanionMemoryWork.committed);
      expect(bodies, hasLength(3));
      final renewed = jsonDecode(((bodies.last['messages'] as List).first as Map)['content'] as String) as Map;
      final renewedCard = (renewed['cards'] as List).single as Map;
      expect(renewedCard['id'], cat['id']);
      expect(renewedCard['row_rev'], retained['row_rev']);
      final visibleProof = (renewedCard['evidence'] as List).single as Map;
      expect(visibleProof['message_id'], 'fresh-cat');
      expect(visibleProof['quote'], source['text']);
      expect(
        visibleProof['support_group'],
        localProof.singleWhere((proof) => proof['message_id'] == 'fresh-cat')['support_group'],
      );
      expect(jsonEncode(bodies.last), isNot(contains('杭州')));
      final finalCard = phone.store.cards().single;
      expect(finalCard['id'], retained['id']);
      expect(finalCard['row_rev'], retained['row_rev']);
      expect(finalCard['text'], retained['text']);
      expect(finalCard['evidence'], localProof);
      expect(phone.store.messages().singleWhere((row) => row['id'] == 'home-and-cat')['text'], original);
      final receipts = phone.store.requests();
      expect(receipts, hasLength(3));
      expect(receipts.map((row) => row['id']).toSet(), hasLength(3));
      expect(receipts.map((row) => row['reserved_input']), unorderedEquals(measured));
      expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(2));
      for (final receipt in receipts) {
        expect(receipt['state'], 'finished');
        expect(receipt['terminal'], 'complete');
        expect((receipt['raw_usage'] as Map)['final_usage'], _usage);
      }
    },
  );

  test('A2 organize uses completed tool results, one parent, and one receipt for each physical request', () async {
    final phone = _Phone()..pair();
    phone.now += const Duration(days: 1).inMilliseconds;
    var calls = 0;
    final worker = phone.withHttp((request) async {
      calls++;
      final input = _input(request);
      expect(input['kind'], 'organize');
      final sent = phone.store.requests().singleWhere((row) => row['state'] == 'sent');
      expect(sent['category'], 'organize');
      expect(
        sent['reserved_input'],
        estimateCompanionMemoryTokens(request.body),
        reason: 'accounting measures the very same complete body that was dispatched',
      );
      if (calls == 1) return _merge(input);
      if (calls == 2) {
        final messages = (jsonDecode(request.body) as Map)['messages'] as List;
        final result = ((messages.last as Map)['content'] as List).single as Map;
        expect(result['tool_use_id'], 'maintenance-call');
        expect((jsonDecode(result['content'] as String) as Map)['applied'], isTrue);
        expect((input['cards'] as List), hasLength(1), reason: 'own commit was reread, not cancelled by its notice');
      }
      return _reply('Done.');
    });
    expect(await worker.consolidate(), CompanionMemoryWork.committed);
    expect(phone.store.cards(), hasLength(1));
    final receipts = phone.store.requests();
    expect(receipts, hasLength(2));
    expect(receipts.map((row) => row['id']).toSet(), hasLength(2));
    expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(1));
    for (final row in receipts) {
      expect(row['state'], 'finished');
      expect((row['raw_usage']! as Map)['final_usage'], _usage);
    }
    expect(phone.db.select('SELECT closed FROM memory_agent_turns').single['closed'], 1);
    final card = phone.store.cards().single;
    phone.store.setPinned(id: card['id'] as String, expectedRowRev: card['row_rev'] as int, pinned: true);
    expect(await worker.consolidate(), CompanionMemoryWork.idle);
    expect(calls, 2, reason: 'a changed card cannot buy a second daily parent');
    phone.now += 86400001;
    expect(await worker.consolidate(), CompanionMemoryWork.committed);
    expect(calls, 3);
  });

  test(
    'A2 organize does not trigger itself across an unchanged day but accepts a later day with real new sources',
    () async {
      final phone = _Phone()..pair();
      // The first organization covers an already complete source day. Merely
      // moving today's raw sources into yesterday would be legitimate new work.
      phone.now += const Duration(days: 1).inMilliseconds;
      var calls = 0;
      final worker = phone.withHttp((request) async {
        calls++;
        final input = _input(request);
        if (calls == 1) return _merge(input);
        if (calls == 3) {
          expect((input['sources']! as List).map((row) => (row as Map)['id']), ['new-day-source']);
        }
        return _reply('Done.');
      });
      expect(await worker.consolidate(), CompanionMemoryWork.committed);
      expect(phone.store.cards(), hasLength(1));
      expect(calls, 2);
      final unchanged = Map<String, Object?>.from(phone.store.cards().single);
      phone.now += 86400001;
      expect(await worker.consolidate(), CompanionMemoryWork.idle);
      expect(calls, 2, reason: 'the date and the prior maintenance write are not new evidence');
      expect(phone.store.cards().single, unchanged);
      expect(phone.db.select('SELECT id FROM memory_agent_maintenance_claims'), hasLength(1));
      phone.say('new-day-source', '今天练了新的一首小曲。');
      expect(await worker.consolidate(), CompanionMemoryWork.idle, reason: 'the new source day is not complete yet');
      expect(calls, 2);
      phone.now += const Duration(days: 1).inMilliseconds;
      expect(await worker.consolidate(), CompanionMemoryWork.committed);
      expect(calls, 3, reason: 'an unprocessed completed day with a real source is a new diary opportunity');
      expect(phone.db.select('SELECT id FROM memory_agent_maintenance_claims'), hasLength(2));
      final receipts = phone.store.requests();
      expect(receipts, hasLength(3));
      expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(2));
      expect(receipts.every((row) => row['state'] == 'finished'), isTrue);
    },
  );

  test('A2 extract and organize share the lane and cancellation preserves the original receipt', () async {
    final phone = _Phone()..pair();
    final started = Completer<Map<String, Object?>>();
    final answer = Completer<http.Response>();
    final worker = phone.withHttp((request) {
      started.complete(_input(request));
      return answer.future;
    });
    final running = worker.consolidate();
    addTearDown(() async {
      if (!answer.isCompleted) answer.complete(_reply('Stopped.'));
      await running;
    });
    final input = await started.future;
    phone.say('s3', '今天练了一会儿琴。');
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.idle);
    expect(await worker.consolidate(), CompanionMemoryWork.idle);
    final stop = worker.stop();
    phone.store.deleteMessage(id: 's1', expectedSourceRev: 1);
    answer.complete(_merge(input));
    expect(await running, CompanionMemoryWork.stale);
    await stop;
    expect(phone.store.cards(), hasLength(1));
    expect(phone.store.requests().single['state'], 'finished');
    expect(phone.store.requests().single['sent_at_ms'], phone.now);
    final later = phone.db.select("SELECT state,reason FROM memory_events WHERE message_id='s3'").single;
    expect(later['state'], 'skipped');
    expect(later['reason'], 'history_cutoff');
    expect(phone.store.messages().singleWhere((row) => row['id'] == 's3')['text'], '今天练了一会儿琴。');
  });

  test('A2 a sent malformed tool turn closes without an automatic format retry or mutation', () async {
    final phone = _Phone()..pair();
    var calls = 0;
    final worker = phone.withHttp((request) async {
      calls++;
      _input(request);
      return _tool('merge', '{broken');
    });
    expect(await worker.consolidate(), CompanionMemoryWork.waiting);
    expect(phone.store.cards(), hasLength(2));
    expect(phone.db.select('SELECT closed FROM memory_agent_turns').single['closed'], 1);
    phone.say('new-source', '我还开始学手风琴。');
    expect(await worker.consolidate(), CompanionMemoryWork.idle);
    expect(calls, 1);
    expect(
      phone.db.select("SELECT state,format_failures FROM memory_events WHERE message_id='new-source'").single,
      allOf(containsPair('state', 'pending'), containsPair('format_failures', 0)),
    );
  });

  test(
    'A2 a failed held extract retires only its captured event while a newer source gets a distinct request',
    () async {
      final phone = _Phone();
      phone.say('u1', '今天咖啡喝无糖。');
      final original = phone.store.messages().single;
      final reached = Completer<void>();
      final answer = Completer<http.Response>();
      var calls = 0;
      MemoryRow? newer;
      final worker = phone.withHttp((request) async {
        calls++;
        final sources = (_input(request)['sources']! as List).cast<Map>();
        expect(sources, hasLength(1));
        final expected = calls == 1 ? original : newer!;
        expect(sources.single['id'], expected['id']);
        expect(sources.single['source_rev'], expected['source_rev']);
        expect(sources.single['event_seq'], expected['event_seq']);
        if (calls == 1) {
          reached.complete();
          return answer.future;
        }
        return _reply('There is nothing durable to save.');
      });
      final first = worker.extract(forceTail: true);
      addTearDown(() async {
        if (!answer.isCompleted) answer.complete(_reply('Stopped.'));
        await first;
      });
      await reached.future;
      phone.say('u2', '我还开始学手风琴。');
      newer = phone.store.messages().singleWhere((row) => row['id'] == 'u2');
      expect(newer['source_rev'], 1);
      expect(newer['event_seq'], greaterThan(original['event_seq']! as int));
      answer.complete(_tool('remember', '{broken'));
      expect(await first, CompanionMemoryWork.waiting);
      final events = phone.db.select('SELECT * FROM memory_events ORDER BY seq');
      expect(events, hasLength(2));
      expect(
        events[0],
        allOf(
          containsPair('message_id', 'u1'),
          containsPair('seq', original['event_seq']),
          containsPair('source_rev', original['source_rev']),
          containsPair('state', 'skipped'),
          containsPair('reason', 'maintenance_incomplete'),
          containsPair('format_failures', 0),
        ),
      );
      expect(
        events[1],
        allOf(
          containsPair('message_id', 'u2'),
          containsPair('seq', newer['event_seq']),
          containsPair('source_rev', newer['source_rev']),
          containsPair('state', 'pending'),
          containsPair('format_failures', 0),
        ),
      );
      expect(phone.store.archive['cursor_seq'], original['event_seq']);
      expect(phone.store.requests().single['state'], 'finished');
      expect(calls, 1, reason: 'failure does not automatically replan either source');
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.committed);
      expect(calls, 2);
      final receipts = phone.store.requests();
      expect(receipts, hasLength(2));
      expect(receipts.map((row) => row['id']).toSet(), hasLength(2));
      expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(2));
      expect(receipts.every((row) => row['state'] == 'finished'), isTrue);
      expect(phone.db.select('SELECT id FROM memory_agent_maintenance_claims'), hasLength(2));
      expect(phone.db.select('SELECT closed FROM memory_agent_turns').every((row) => row['closed'] == 1), isTrue);
      final later = phone.db.select("SELECT * FROM memory_events WHERE message_id='u2'").single;
      expect(
        later,
        allOf(
          containsPair('seq', newer['event_seq']),
          containsPair('source_rev', newer['source_rev']),
          containsPair('state', 'done'),
        ),
      );
      expect(phone.store.archive['cursor_seq'], newer['event_seq']);
      expect(phone.store.cards(), isEmpty);
      expect(phone.store.messages().map((row) => row['text']).toList(), ['今天咖啡喝无糖。', '我还开始学手风琴。']);
    },
  );

  test('A2 a complete no-tool answer processes the exact original sources and preserves provider usage', () async {
    final phone = _Phone();
    phone.say('u1', '  今天就随便聊聊。\n');
    final worker = phone.withHttp((request) async {
      final input = _input(request);
      final source = (input['sources']! as List).single as Map;
      expect(source['id'], 'u1');
      expect(source['text'], '  今天就随便聊聊。\n');
      expect(source['said_at_utc'], phone.now);
      expect(source['offset_minutes'], 480);
      expect(input['presentations'], isEmpty);
      expect(phone.store.requests().single['reserved_input'], estimateCompanionMemoryTokens(request.body));
      return _reply('There is nothing durable to save.');
    });
    expect(await worker.extract(forceTail: true), CompanionMemoryWork.committed);
    expect(phone.db.select('SELECT state FROM memory_events').single['state'], 'done');
    expect(phone.store.cards(), isEmpty);
    expect(phone.store.messages(), hasLength(1), reason: 'maintenance output is not fabricated user/assistant chat');
    final raw = phone.store.requests().single['raw_usage']! as Map;
    expect(raw['final_usage'], _usage);
    expect(raw['input_uncached'], 20);
    expect(raw['start_usage'], {'input_tokens': 900});
  });

  for (final status in [401, 400, 404, 413, 422]) {
    test('A2 HTTP $status configuration failure settles its sent receipt without a format retry', () async {
      final phone = _Phone();
      phone.say('u1', '我的咖啡喝无糖。');
      final worker = phone.withHttp((_) async => http.Response('unsupported or unauthorized', status));
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.configuration);
      expect(phone.store.requests().single['sent_at_ms'], phone.now);
      expect(phone.store.requests().single['state'], 'finished');
      expect(
        phone.db.select('SELECT state,reason,format_failures FROM memory_events').single,
        allOf(
          containsPair('state', 'skipped'),
          containsPair('reason', 'maintenance_incomplete'),
          containsPair('format_failures', 0),
        ),
      );
      expect(phone.store.archive['cursor_seq'], 1);
      expect(
        await worker.extract(forceTail: true),
        CompanionMemoryWork.idle,
        reason: 'a sent failed scope is not automatically replanned with a new claim',
      );
      final noKey = phone.withHttp((_) async => throw StateError('must not send'), key: ' ');
      expect(await noKey.extract(forceTail: true), CompanionMemoryWork.configuration);
      expect(phone.store.requests(), hasLength(1));
    });
  }

  for (final terminal in ['incomplete', 'max_tokens', 'refusal']) {
    test('A2 $terminal keeps its actual usage and cannot complete source processing', () async {
      final phone = _Phone();
      phone.say('u1', '聊两句吧。');
      final worker = phone.withHttp((request) async {
        _input(request);
        return _reply(
          'Not a completed maintenance decision.',
          complete: terminal != 'incomplete',
          stop: terminal == 'incomplete' ? 'end_turn' : terminal,
        );
      });
      expect(
        await worker.extract(forceTail: true),
        terminal == 'incomplete' ? CompanionMemoryWork.waiting : CompanionMemoryWork.invalid,
      );
      expect(phone.store.requests().single['terminal'], terminal);
      expect(
        phone.db.select('SELECT state,reason,format_failures FROM memory_events').single,
        allOf(
          containsPair('state', 'skipped'),
          containsPair('reason', 'maintenance_incomplete'),
          containsPair('format_failures', 0),
        ),
      );
      expect(phone.store.archive['cursor_seq'], 1);
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.idle);
      expect(phone.store.requests(), hasLength(1), reason: 'no automatic second physical request for this source');
      expect(phone.store.cards(), isEmpty);
    });
  }

  test('A2 editing an original source retires a late tool response without changing its original clock', () async {
    final phone = _Phone();
    phone.say('u1', '明天面试。');
    final started = Completer<void>();
    final answer = Completer<http.Response>();
    final worker = phone.withHttp((request) {
      _input(request);
      started.complete();
      return answer.future;
    });
    final running = worker.extract(forceTail: true);
    addTearDown(() async {
      if (!answer.isCompleted) answer.complete(_reply('Stopped.'));
      await running;
    });
    await started.future;
    phone.now += const Duration(days: 2).inMilliseconds;
    phone.store.editMessage(id: 'u1', expectedSourceRev: 1, text: '明天上午面试。');
    answer.complete(_tool('remember', jsonEncode({'text': '明天面试', 'source': 'u1'})));
    expect(await running, CompanionMemoryWork.stale);
    final source = phone.store.messages().single;
    expect(source['first_seq'], 1);
    expect(source['source_rev'], 2);
    expect(source['said_at_utc'], phone.now - const Duration(days: 2).inMilliseconds);
    expect(phone.store.cards(), isEmpty);
    expect(phone.store.requests().single['state'], 'finished');
    expect(phone.db.select('SELECT SUM(format_failures) AS n FROM memory_events').single['n'], 0);
    expect(
      phone.db.select('SELECT state,reason FROM memory_events WHERE source_rev=2').single,
      allOf(containsPair('state', 'pending'), containsPair('reason', isNull)),
      reason: 'retiring the original scope cannot retire a newly edited source revision',
    );
  });

  test('A2 owner disposal waits for the first cancellation drain before closing its receipt database', () async {
    final phone = _Phone();
    phone.say('u1', '你好。');
    final listening = Completer<void>();
    final cancelling = Completer<void>();
    final release = Completer<void>();
    late final StreamController<List<int>> wire;
    wire = StreamController<List<int>>(
      onListen: () {
        wire.add(
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'Still considering.'},
            })}\n\n',
          ),
        );
        listening.complete();
      },
      onCancel: () {
        cancelling.complete();
        return release.future;
      },
    );
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'test',
      client: () => MockClient.streaming((request, body) async {
        await body.drain<void>();
        return http.StreamedResponse(wire.stream, 200);
      }),
    );
    final room = Object();
    phone.memory.enter(room, transport: () => route, estimateTokens: estimateCompanionMemoryTokens);
    var settled = false;
    final running = phone.memory.extract(room, forceTail: true).whenComplete(() => settled = true);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await running;
      await wire.close();
    });
    await listening.future;
    phone.dispose();
    await cancelling.future;
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(phone.store.cards(), isEmpty, reason: 'the original SQLite owner is still draining');
    expect(phone.store.requests().single['state'], 'sent');
    release.complete();
    expect(await running, CompanionMemoryWork.stale);
    expect(settled, isTrue);
  });
}
