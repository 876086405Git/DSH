// r2 fixture 15. A fixed complete opportunity sequence, not an OS scheduling
// promise. HTTP is the real light request path with fixed MockClient SSE.
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
  'cache_read_input_tokens': 3,
  'cache_creation_input_tokens': 0,
  'output_tokens': 12,
};
const _offsetMinutes = 480;

class _Phone {
  _Phone() {
    store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now);
    memory = CompanionMemoryOwner(
      store,
      CompanionLocal.at(Directory('/unused-memory-idle-replay-test')),
      nowMilliseconds: () => now,
    );
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'offline-replay-placeholder',
      client: () => MockClient((request) async {
        final body = jsonDecode(request.body) as MemoryRow;
        posts.add(body);
        expect(body['thinking'], {'type': 'disabled'});
        expect((body['tools'] as List).map((tool) => (tool as Map)['name']), containsAll(['remember', 'merge']));
        final messages = (body['messages'] as List).cast<MemoryRow>();
        expect(messages, hasLength(1));
        final input = jsonDecode(messages.single['content'] as String) as MemoryRow;
        expect(input['type'], 'memory_maintenance_context');
        expect(claimId, isNotNull);
        final receipt = store.requests().singleWhere((row) => row['batch_id'] == claimId && row['terminal'] == null);
        expect(receipt['state'], 'sent');
        expect(receipt['sent_at_ms'], now);
        expect(receipt['batch_id'], claimId);
        expect(receipt['category'], input['kind']);
        final text = answer(input);
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
                'type': 'content_block_start',
                'index': 0,
                'content_block': {'type': 'text', 'text': ''},
              },
              {
                'type': 'content_block_delta',
                'index': 0,
                'delta': {'type': 'text_delta', 'text': text},
              },
              {'type': 'content_block_stop', 'index': 0},
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
      maintenanceTools: (turn, current, committed) {
        claimId = turn['claim_id']! as String;
        return CompanionAgentMemoryTools.maintenance(
          memory: memory,
          turn: turn,
          isCurrent: current,
          onMaintenanceCommitted: committed,
          forgottenNotice: '',
        );
      },
    );
    addTearDown(() async {
      await worker.stop();
      memory.dispose();
    });
  }

  int now = DateTime.utc(2026, 11, 21).millisecondsSinceEpoch;
  late final CompanionMemoryStore store;
  late final CompanionMemoryOwner memory;
  late final CompanionMemoryWorker worker;
  String? claimId;
  final posts = <MemoryRow>[];
  String Function(MemoryRow) answer = (_) => throw StateError('No cloud request expected');

  MemoryRow say(String id, String text) =>
      store.submitMessage(id: id, sessionId: 'light', text: text, saidAtUtc: now, offsetMinutes: _offsetMinutes);

  // Prepare the two cards through the public memory tool transaction. The
  // later empty extract response examines sources; it does not create cards.
  void remember(MemoryRow source, String text) {
    final turn = store.beginAgentTurn(
      messageId: source['id']! as String,
      expectedSourceRev: source['source_rev']! as int,
      shownCardRevisions: const {},
    );
    final turnId = turn['id']! as String;
    try {
      final result = store.applyAgentMemoryTool(
        turnId: turnId,
        callId: 'prepare-${source['id']}',
        toolName: 'remember',
        input: {
          'kind': 'preference',
          'text': text,
          'keywords': ['酸奶'],
        },
      );
      expect(result.applied, isTrue);
    } finally {
      store.closeAgentTurn(turnId);
    }
  }
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
    expect(
      await phone.worker.extract(offsetMinutes: _offsetMinutes),
      CompanionMemoryWork.idle,
      reason: 'extract at hour $hour',
    );
    expect(
      await phone.worker.consolidate(offsetMinutes: _offsetMinutes),
      CompanionMemoryWork.idle,
      reason: 'organize at hour $hour',
    );
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
    final a = phone.say('a', '酸奶我只买原味。');
    final b = phone.say('b', '我买酸奶一直只选原味。');
    phone.remember(a, '你买酸奶只选原味。');
    phone.remember(b, '酸奶你只买原味的。');
    expect(phone.store.cards(), hasLength(2));
    expect(phone.store.requests(), isEmpty);
    // Day-0 sources are already a complete local day before the first
    // organize request. A later date alone must not create another request.
    phone.now += const Duration(days: 1, minutes: 3).inMilliseconds;
    phone.answer = (input) {
      expect(input['kind'], 'extract');
      expect((input['sources'] as List).map((row) => (row as Map)['id']), unorderedEquals(['a', 'b']));
      return '原话已检查，没有新增条目。';
    };
    expect(await phone.worker.extract(offsetMinutes: _offsetMinutes), CompanionMemoryWork.committed);
    phone.answer = (input) {
      expect(input['kind'], 'organize');
      expect(input['local_day'], '2026-11-21');
      expect((input['sources'] as List).map((row) => (row as Map)['id']), unorderedEquals(['a', 'b']));
      expect(input['cards'], hasLength(2));
      return '已有条目已检查，没有修改。';
    };
    expect(await phone.worker.consolidate(offsetMinutes: _offsetMinutes), CompanionMemoryWork.committed);
    expect(phone.posts, hasLength(2));
    expect(phone.posts.first['system'], isA<String>());
    expect(phone.posts.last['system'], phone.posts.first['system']);
    final receipts = phone.store.requests();
    expect(receipts, hasLength(2));
    expect(receipts.map((row) => row['category']), unorderedEquals(['extract', 'organize']));
    expect(receipts.map((row) => row['id']).toSet(), hasLength(2));
    expect(receipts.map((row) => row['batch_id']).toSet(), hasLength(2));
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
