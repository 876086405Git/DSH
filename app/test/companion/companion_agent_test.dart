import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

String _sse(List<Map<String, Object?>> events) =>
    [for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join();

Map<String, Object?> _words(String text) => {
  'type': 'content_block_delta',
  'index': 0,
  'delta': {'type': 'text_delta', 'text': text},
};

List<Map<String, Object?>> _call(int index, String id, List<String> arguments) => [
  {
    'type': 'content_block_start',
    'index': index,
    'content_block': {'type': 'tool_use', 'id': id, 'name': 'sample', 'input': <String, Object?>{}},
  },
  for (final part in arguments)
    {
      'type': 'content_block_delta',
      'index': index,
      'delta': {'type': 'input_json_delta', 'partial_json': part},
    },
  {'type': 'content_block_stop', 'index': index},
];

CompanionMemoryOwner _memory() => CompanionMemoryOwner(
  CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => 1795309200000),
  CompanionLocal.at(Directory('/unused-companion-agent-test')),
);

MemoryRow _source(CompanionMemoryOwner memory) => memory.store.submitMessage(
  id: 'agent-user',
  sessionId: memory.store.lightSessionId,
  text: '帮我看看这两件事。',
  saidAtUtc: 1795309200000,
  offsetMinutes: 480,
);

const _tool = CompanionAgentTool(
  name: 'sample',
  description: 'Synthetic operation for the protocol test.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'n': {'type': 'integer'},
    },
    'required': ['n'],
  },
);

void main() {
  test('continues with every result after one complete tool call is rejected', () async {
    final memory = _memory();
    addTearDown(memory.dispose);
    final requests = <Map<String, Object?>>[];
    final called = <int>[];
    final usage = <CompanionUsage>[];
    final agent = CompanionAgent(
      apiKey: () => 'synthetic',
      client: () => MockClient.streaming((request, body) async {
        requests.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
        final events = requests.length == 1
            ? <Map<String, Object?>>[
                _words('我先看看。'),
                ..._call(1, 'call-one', ['{"n":', '1}']),
                ..._call(2, 'call-two', ['{"n":2}']),
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'tool_use'},
                  'usage': {'output_tokens': 5},
                },
                {'type': 'message_stop'},
              ]
            : <Map<String, Object?>>[
                _words('第一件没改，第二件处理好了。'),
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'end_turn'},
                  'usage': {'output_tokens': 7},
                },
                {'type': 'message_stop'},
              ];
        return http.StreamedResponse(Stream.value(utf8.encode(_sse(events))), 200);
      }),
      onUsage: usage.add,
    );
    addTearDown(agent.dispose);

    await agent.say(
      memory: memory,
      source: _source(memory),
      system: 'Synthetic test persona.',
      isCurrent: () => true,
      tools: [
        (
          definition: _tool,
          execute: (call) async {
            final n = call.input['n']! as int;
            called.add(n);
            return CompanionAgentToolResult(
              content: n == 1 ? '{"ok":false,"message":"Not applied."}' : '{"ok":true}',
              isError: n == 1,
            );
          },
        ),
      ],
    );

    expect(called, [1, 2]);
    expect(requests, hasLength(2));
    final continuation = requests.last['messages']! as List;
    final assistant = continuation[continuation.length - 2] as Map;
    final resultMessage = continuation.last as Map;
    expect(assistant['role'], 'assistant');
    expect(resultMessage['role'], 'user');
    final results = (resultMessage['content'] as List).cast<Map>();
    expect(results.map((result) => result['tool_use_id']), ['call-one', 'call-two']);
    expect(results.first['is_error'], isTrue);
    expect(results.first['content'], contains('Not applied'));
    expect(agent.text, '我先看看。\n第一件没改，第二件处理好了。');
    expect(agent.error, isNull);
    expect(agent.running, isFalse);
    expect(usage.map((receipt) => receipt.outputTokens), [5, 7]);
    expect(usage.every((receipt) => receipt.complete), isTrue);
  });

  test('keeps the memory owner open until the first stream cancellation drains', () async {
    final memory = _memory();
    var ownerDisposed = false;
    final releaseCancellation = Completer<void>();
    final heard = Completer<void>();
    final usage = <CompanionUsage>[];
    late final StreamController<List<int>> wire;
    wire = StreamController<List<int>>(
      onListen: () => wire.add(utf8.encode(_sse([_words('还在说。')]))),
      onCancel: () => releaseCancellation.future,
    );
    final agent = CompanionAgent(
      apiKey: () => 'synthetic',
      client: () => MockClient.streaming((request, body) async {
        await body.drain<void>();
        return http.StreamedResponse(wire.stream, 200);
      }),
      onUsage: usage.add,
    );
    agent.addListener(() {
      if (agent.text == '还在说。' && !heard.isCompleted) heard.complete();
    });
    var turnSettled = false;
    final turn = agent
        .say(
          memory: memory,
          source: _source(memory),
          system: 'Synthetic test persona.',
          tools: const [],
          isCurrent: () => true,
        )
        .whenComplete(() => turnSettled = true);
    addTearDown(() async {
      if (!releaseCancellation.isCompleted) releaseCancellation.complete();
      agent.dispose();
      await turn;
      if (!ownerDisposed) memory.dispose();
      await wire.close();
    });

    await heard.future;
    agent.stop(discard: true);
    memory.dispose();
    ownerDisposed = true;
    // Give queued cancellation continuations their turn without releasing the
    // actual subscription cleanup. No wall-time delay decides the outcome.
    await Future<void>.delayed(Duration.zero);
    expect(turnSettled, isFalse);
    expect(usage, isEmpty);
    expect(memory.store.cards(), isEmpty);

    releaseCancellation.complete();
    await turn;
    expect(usage, hasLength(1));
    expect(usage.single.complete, isFalse);
    expect(turnSettled, isTrue);
  });
}
