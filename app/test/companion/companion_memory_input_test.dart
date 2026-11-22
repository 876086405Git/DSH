// Production estimate -> SQLite batching -> worker -> real SDK HTTP bytes.
// The loopback responder is a protocol fixture, never a real model or host.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_host_memory_transport.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

const _at = 1795260000123;

class _InputHost {
  _InputHost(this.server) {
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    server.listen((request) async {
      final bytes = await request.fold<List<int>>([], (all, part) => all..addAll(part));
      expect(request.uri.path, '/dsh-go/v1/companion/auxiliary');
      if (request.method == 'GET') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'v': 1,
            'instanceId': 'capacity-host',
            'provider': 'deepseek',
            'model': 'deepseek-flash',
            'supported': true,
            'capability': {
              'physicalDispatch': 'fetch-invoked',
              'rawUsage': 'deepseek-messages-cumulative',
              'maxPhysicalRequests': 1,
              'noTools': true,
            },
          }),
        );
      } else {
        bodies.add(bytes);
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        final input = jsonDecode(body['input']! as String) as Map<String, Object?>;
        inputs.add(input);
        final id = body['requestId'];
        final usage = {
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
          'stop_reason': 'end_turn',
          'terminal': 'complete',
          'complete': true,
          'http_status': 200,
        };
        request.response.headers.contentType = ContentType('application', 'x-ndjson');
        for (final frame in [
          {
            'type': 'accepted',
            'requestId': id,
            'instanceId': 'capacity-host',
            'provider': 'deepseek',
            'model': 'deepseek-flash',
          },
          {'type': 'dispatch', 'requestId': id, 'atMs': _at, 'boundary': 'fetch-invoked'},
          {
            'type': 'text',
            'requestId': id,
            'text': jsonEncode({
              'schema_version': 2,
              'batch_id': input['batch_id'],
              'covered_message_ids': [for (final source in input['source']! as List) (source as Map)['id']],
              'operations': [],
              'completion': 'complete',
            }),
          },
          {
            'type': 'finish',
            'requestId': id,
            'dispatched': true,
            'dispatchAtMs': _at,
            'terminal': 'complete',
            'complete': true,
            'stopReason': 'end_turn',
            'httpStatus': 200,
            'usage': usage,
          },
        ]) {
          request.response.write('${jsonEncode(frame)}\n');
        }
      }
      await request.response.close();
    });
  }

  final HttpServer server;
  late final DshClient client;
  final bodies = <List<int>>[];
  final inputs = <Map<String, Object?>>[];

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

void main() {
  for (final entry in {'whitespace': '原话${' ' * 100000}', 'emoji': '🙂' * 10000}.entries) {
    test('${entry.key}: oversized raw source stays exact without an auxiliary POST or a format retry', () async {
      final db = sqlite3.openInMemory();
      final store = CompanionMemoryStore(db, nowMilliseconds: () => _at);
      final host = _InputHost(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      final cap = (await host.client.readCompanionAuxiliaryCapability('full-session'))!;
      final worker = CompanionMemoryWorker(
        store: store,
        transport: () => CompanionHostMemoryTransport(client: host.client, capability: cap),
        nowMilliseconds: () => _at,
        estimateTokens: estimateCompanionMemoryTokens,
      );
      try {
        store.submitMessage(
          id: 'source',
          sessionId: 'full:local',
          text: entry.value,
          saidAtUtc: _at,
          offsetMinutes: 480,
        );
        expect(await worker.extract(forceTail: true), CompanionMemoryWork.idle);
        expect(host.bodies, isEmpty);
        expect(store.requests(), isEmpty);
        expect(store.messages().single['text'], entry.value);
        final event = db.select('SELECT state,reason,format_failures FROM memory_events').single;
        expect(event['state'], 'skipped');
        expect(event['reason'], 'input_too_long');
        expect(event['format_failures'], 0);
      } finally {
        await worker.stop();
        store.close();
        await host.close();
      }
    });
  }

  test('escaped input fits the actual SDK envelope and preserves the original clock and text', () async {
    final db = sqlite3.openInMemory();
    final store = CompanionMemoryStore(db, nowMilliseconds: () => _at);
    final host = _InputHost(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    final cap = (await host.client.readCompanionAuxiliaryCapability('full-session'))!;
    final worker = CompanionMemoryWorker(
      store: store,
      transport: () => CompanionHostMemoryTransport(client: host.client, capability: cap),
      nowMilliseconds: () => _at,
      estimateTokens: estimateCompanionMemoryTokens,
    );
    final raw = '  原话🙂：${'\\"\t\n' * 700}';
    try {
      store.submitMessage(
        id: 'source',
        sessionId: 'full:local',
        text: raw,
        saidAtUtc: _at - 60000,
        offsetMinutes: -330,
      );
      expect(await worker.extract(forceTail: true), CompanionMemoryWork.committed);
      expect(host.bodies, hasLength(1));
      expect(host.bodies.single.length, lessThanOrEqualTo(65536));
      final sent = jsonDecode(utf8.decode(host.bodies.single)) as Map;
      expect(sent['maxTokens'], memoryBatchOutputTokens);
      expect(sent.containsKey('tools'), isFalse);
      expect(
        estimateCompanionMemoryTokens('${sent['system']}\n${sent['input']}'),
        lessThanOrEqualTo(memoryBatchInputTokens),
      );
      final source = (host.inputs.single['source']! as List).single as Map;
      expect(source['text'], raw);
      expect(source['said_at_utc'], DateTime.fromMillisecondsSinceEpoch(_at - 60000, isUtc: true).toIso8601String());
      expect(source['offset_minutes'], -330);
      expect(store.messages().single['text'], raw);
      expect(db.select('SELECT state FROM memory_events').single['state'], 'done');
    } finally {
      await worker.stop();
      store.close();
      await host.close();
    }
  });
}
