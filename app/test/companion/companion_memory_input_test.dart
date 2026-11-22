// Production whole-body estimate -> SQLite claim -> worker -> real Light bytes.
// MockClient provides fixed Messages SSE; no real model, host, or network runs.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _at = 1795260000123;

class _InputPhone {
  _InputPhone() {
    store = CompanionMemoryStore(db, nowMilliseconds: () => _at);
    memory = CompanionMemoryOwner(
      store,
      CompanionLocal.at(Directory('/unused-memory-input-test')),
      nowMilliseconds: () => _at,
    );
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'offline-replay-placeholder',
      client: () => MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url, Uri.parse(companionLightEndpoint));
        final bytes = List<int>.of(request.bodyBytes);
        bodies.add(bytes);
        final wire = utf8.decode(bytes);
        final body = jsonDecode(wire) as MemoryRow;
        final messages = body['messages']! as List;
        expect(messages, hasLength(1));
        final input = jsonDecode((messages.single as Map)['content'] as String) as MemoryRow;
        inputs.add(input);
        expect(input['type'], 'memory_maintenance_context');
        expect(input['kind'], 'extract');
        final receipt = store.requests().single;
        expect(receipt['state'], 'sent');
        expect(receipt['category'], 'extract');
        expect(receipt['batch_id'], claimId);
        expect(receipt['sent_at_ms'], _at);
        // Budget the actual serialized request, including tools, system and
        // nested JSON escaping, not just the decoded original source.
        expect(receipt['reserved_input'], estimateCompanionMemoryTokens(wire));
        expect(receipt['reserved_input'], lessThanOrEqualTo(memoryBatchInputTokens));
        expect(receipt['reserved_output'], memoryBatchOutputTokens);
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
                'delta': {'type': 'text_delta', 'text': '原话已检查，没有新增条目。'},
              },
              {'type': 'content_block_stop', 'index': 0},
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'end_turn'},
                'usage': {'input_tokens': 20, 'output_tokens': 12},
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
      nowMilliseconds: () => _at,
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
  }

  final db = sqlite3.openInMemory();
  late final CompanionMemoryStore store;
  late final CompanionMemoryOwner memory;
  late final CompanionMemoryWorker worker;
  String? claimId;
  final bodies = <List<int>>[];
  final inputs = <MemoryRow>[];

  Future<void> close() async {
    await worker.stop();
    memory.dispose();
  }
}

void main() {
  for (final entry in {'whitespace': '原话${' ' * 100000}', 'emoji': '🙂' * 10000}.entries) {
    test('${entry.key}: oversized raw source stays exact without an auxiliary POST or a format retry', () async {
      final phone = _InputPhone();
      try {
        phone.store.submitMessage(
          id: 'source',
          sessionId: 'light',
          text: entry.value,
          saidAtUtc: _at,
          offsetMinutes: 480,
        );
        expect(await phone.worker.extract(forceTail: true, offsetMinutes: 480), CompanionMemoryWork.idle);
        expect(phone.bodies, isEmpty);
        expect(phone.store.requests(), isEmpty);
        expect(phone.store.messages().single['text'], entry.value);
        final event = phone.db.select('SELECT state,reason,format_failures FROM memory_events').single;
        expect(event['state'], 'skipped');
        expect(event['reason'], 'input_too_long');
        expect(event['format_failures'], 0);
      } finally {
        await phone.close();
      }
    });
  }

  test('escaped input fits the actual SDK envelope and preserves the original clock and text', () async {
    final phone = _InputPhone();
    // The Messages envelope now includes the actual tool definitions. This
    // shorter whole source keeps the same repeated escaping categories; no
    // saved source is shortened or split to make a request fit.
    final raw = '  原话🙂：${'\\"\t\n' * 128}';
    try {
      phone.store.submitMessage(
        id: 'source',
        sessionId: 'light',
        text: raw,
        saidAtUtc: _at - 60000,
        offsetMinutes: -330,
      );
      expect(await phone.worker.extract(forceTail: true, offsetMinutes: 480), CompanionMemoryWork.committed);
      expect(phone.bodies, hasLength(1));
      expect(phone.bodies.single.length, lessThanOrEqualTo(65536));
      final wire = utf8.decode(phone.bodies.single);
      final sent = jsonDecode(wire) as MemoryRow;
      expect(sent['max_tokens'], memoryBatchOutputTokens);
      expect(sent['thinking'], {'type': 'disabled'});
      expect(sent['tools'], [
        for (final definition in CompanionAgentMemoryTools.definitionsFor(originKind: 'extract', characterId: null))
          definition.toJson(),
      ]);
      expect(estimateCompanionMemoryTokens(wire), lessThanOrEqualTo(memoryBatchInputTokens));
      expect(phone.store.requests().single['reserved_input'], estimateCompanionMemoryTokens(wire));
      expect(phone.store.requests().single['terminal'], 'complete');
      final source = (phone.inputs.single['sources']! as List).single as Map;
      expect(source['text'], raw);
      expect(source['said_at_utc'], _at - 60000);
      expect(source['offset_minutes'], -330);
      expect(phone.store.messages().single['text'], raw);
      expect(phone.db.select('SELECT state FROM memory_events').single['state'], 'done');
    } finally {
      await phone.close();
    }
  });
}
