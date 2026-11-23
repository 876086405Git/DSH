import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent.dart';
import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_context.dart';
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

List<Map<String, Object?>> _call(int index, String id, List<String> arguments, {String name = 'sample'}) => [
  {
    'type': 'content_block_start',
    'index': index,
    'content_block': {'type': 'tool_use', 'id': id, 'name': name, 'input': <String, Object?>{}},
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
  nowMilliseconds: () => 1795309200000,
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

  for (final route in ['selection', 'recall', 'related']) {
    test(
      '$route of a real notice narrows even same-response memory rewrites, keeps the answer live, and resets next turn',
      () async {
        final memory = _memory();
        addTearDown(memory.dispose);
        const summary = '河边驿站包裹待取';
        final card = memory.store.rememberNotice(
          eventId: 'a' * 64,
          notificationKey: 'b' * 64,
          packageName: 'test.app',
          appName: '测试',
          text: summary,
          observedAtMs: 1795309200000,
          expectedControlRevision: memory.store.archive['control_revision'] as int,
        )!;
        final source = memory.store.submitMessage(
          id: 'notice-user',
          sessionId: memory.store.lightSessionId,
          text: route == 'selection' ? summary : '帮我了解一下。',
          saidAtUtc: 1795309200000,
          offsetMinutes: 480,
        );
        final requests = <Map>[];
        final agent = CompanionAgent(
          apiKey: () => 'synthetic',
          client: () => MockClient((request) async {
            requests.add(jsonDecode(request.body) as Map);
            final events = <Map<String, Object?>>[];
            if (requests.length == 1) {
              var idx = 0;
              if (route == 'recall')
                events.addAll(
                  _call(idx++, 'read', [
                    jsonEncode({'query': summary}),
                  ], name: 'recall'),
                );
              if (route == 'related')
                events.addAll(
                  _call(idx++, 'read', [
                    jsonEncode({'card': card['id']}),
                  ], name: 'related'),
                );
              events.addAll(
                _call(idx++, 'new-card', [
                  jsonEncode({'text': '越界推断'}),
                ], name: 'remember'),
              );
              events.addAll(
                _call(idx++, 'overwrite', [
                  jsonEncode({
                    'changes': [
                      {'card': card['id'], 'text': '伪装成删除的写入'},
                    ],
                  }),
                ], name: 'forget'),
              );
              events.addAll(_call(idx, 'real-user-task', ['{}'], name: 'task_status'));
            } else {
              events.add(_words(requests.length == 2 ? '她的临时通知回答。' : '普通回答。'));
            }
            events.addAll([
              {
                'type': 'message_delta',
                'delta': {'stop_reason': requests.length == 1 ? 'tool_use' : 'end_turn'},
                'usage': {'output_tokens': 8},
              },
              {'type': 'message_stop'},
            ]);
            return http.Response.bytes(utf8.encode(_sse(events)), 200);
          }),
        );
        addTearDown(agent.dispose);
        final tools = CompanionAgentMemoryTools(
          memory: memory,
          source: source,
          isCurrent: () => true,
          onCommitted: agent.confirmControlRevision,
          forgottenNotice: '已忘记。',
        );
        if (route == 'related') tools.grantCards([card]);
        addTearDown(tools.close);
        var userTaskCalls = 0;
        await agent.say(
          memory: memory,
          source: source,
          system: '测试',
          isCurrent: () => true,
          onSelected: tools.grantSelection,
          tools: [
            ...tools.bindings,
            (
              definition: const CompanionAgentTool(
                name: 'task_status',
                description: 'test',
                inputSchema: {'type': 'object'},
              ),
              execute: (_) async {
                userTaskCalls++;
                return const CompanionAgentToolResult(content: '{}');
              },
            ),
          ],
        );
        expect(agent.error, isNull);
        expect(agent.text, '她的临时通知回答。');
        expect(userTaskCalls, 1);
        expect(memory.store.messages().map((r) => r['role']), ['user']);
        expect(memory.store.cards().map((r) => r['text']), [summary]);
        final firstNames = (requests.first['tools'] as List).map((t) => t['name']);
        expect(firstNames.contains('remember'), route != 'selection');
        final results = (requests[1]['messages'] as List).last['content'] as List;
        for (final id in ['new-card', 'overwrite']) {
          final result = results.singleWhere((r) => r['tool_use_id'] == id);
          expect(jsonDecode(result['content'])['code'], 'memory_change_after_notice');
        }
        final offered = (requests[1]['tools'] as List).map((t) => t['name']);
        expect(offered, unorderedEquals(['recall', 'related', 'forget', 'task_status']));
        final next = memory.store.submitMessage(
          id: 'ordinary-next',
          sessionId: memory.store.lightSessionId,
          text: '今天看看日历。',
          saidAtUtc: 1795309200001,
          offsetMinutes: 480,
        );
        await agent.say(memory: memory, source: next, system: '测试', isCurrent: () => true, tools: const []);
        expect(memory.store.messages().where((r) => r['role'] == 'assistant').map((r) => r['text']), ['普通回答。']);
      },
    );
  }

  test(
    'pure group deletion still commits and its acknowledgment stays live after notice selection disappears',
    () async {
      final memory = _memory();
      addTearDown(memory.dispose);
      const summary = '车站包裹待取';
      final card = memory.store.rememberNotice(
        eventId: 'c' * 64,
        notificationKey: 'd' * 64,
        packageName: 'test.app',
        appName: '测试',
        text: summary,
        observedAtMs: 1795309200000,
        expectedControlRevision: memory.store.archive['control_revision'] as int,
      )!;
      final source = memory.store.submitMessage(
        id: 'forget-from-notice',
        sessionId: memory.store.lightSessionId,
        text: '忘掉$summary',
        saidAtUtc: 1795309200000,
        offsetMinutes: 480,
      );
      var calls = 0;
      final agent = CompanionAgent(
        apiKey: () => 'synthetic',
        client: () => MockClient((request) async {
          calls++;
          final events = <Map<String, Object?>>[
            if (calls == 1)
              ..._call(0, 'delete', [
                jsonEncode({
                  'changes': [
                    {'card': card['id'], 'forget': true},
                  ],
                }),
              ], name: 'forget')
            else
              _words('没问题。'),
            {
              'type': 'message_delta',
              'delta': {'stop_reason': calls == 1 ? 'tool_use' : 'end_turn'},
            },
            {'type': 'message_stop'},
          ];
          return http.Response.bytes(utf8.encode(_sse(events)), 200);
        }),
      );
      addTearDown(agent.dispose);
      final adapter = CompanionAgentMemoryTools(
        memory: memory,
        source: source,
        isCurrent: () => true,
        onCommitted: agent.confirmControlRevision,
        forgottenNotice: '那条已经忘掉了。',
      );
      addTearDown(adapter.close);
      await agent.say(
        memory: memory,
        source: source,
        system: '测试',
        tools: adapter.bindings,
        isCurrent: () => true,
        onSelected: adapter.grantSelection,
      );
      expect(agent.error, isNull);
      expect(agent.text, '那条已经忘掉了。\n没问题。');
      expect(memory.store.noticeSuppressed('c' * 64), isTrue);
      expect(memory.store.messages().map((r) => r['role']), ['user']);
    },
  );

  test('partial reply to the displayed notice stays in RAM after cancellation', () async {
    final memory = _memory();
    addTearDown(memory.dispose);
    final heard = Completer<void>();
    late final StreamController<List<int>> body;
    body = StreamController(onListen: () => body.add(utf8.encode(_sse([_words('草稿开头')]))));
    final agent = CompanionAgent(
      apiKey: () => 'synthetic',
      client: () => MockClient.streaming((request, stream) async {
        await stream.drain<void>();
        return http.StreamedResponse(body.stream, 200);
      }),
    );
    agent.addListener(() {
      if (agent.text.isNotEmpty && !heard.isCompleted) heard.complete();
    });
    addTearDown(agent.dispose);
    final run = agent.say(
      memory: memory,
      source: _source(memory),
      system: '测试',
      context: CompanionTurnContext(
        const {
          'noticeReply': {'phase': 'draft'},
        },
        const [],
        sampledAt: DateTime(2026),
        hasClock: false,
      ),
      tools: const [],
      isCurrent: () => true,
    );
    await heard.future;
    agent.stop();
    await run;
    await body.close();
    expect(agent.text, '草稿开头');
    expect(memory.store.messages().map((r) => r['role']), ['user']);
  });

  for (final webTool in ['public_lookup', 'task_status']) {
    test('$webTool narrows memory capabilities in the same batch and the next user turn restores them', () async {
      final memory = _memory();
      addTearDown(memory.dispose);
      const seedId = '11111111-1111-4111-8111-111111111111';
      const seedText = '公开查询前保存的原卡';
      memory.store.saveManual(
        const CompanionMemory(id: seedId, text: seedText, keywords: ['公开']),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      MemoryRow source(String id, String text) => memory.store.submitMessage(
        id: id,
        sessionId: memory.store.lightSessionId,
        text: text,
        saidAtUtc: 1795309200000,
        offsetMinutes: 480,
      );
      final firstSource = source('web-user', '先查公开资料；我喜欢简短回答。');
      final requests = <Map<String, Object?>>[];
      final executed = <String>[];
      late List<String> forbidden;
      final agent = CompanionAgent(
        apiKey: () => 'synthetic',
        client: () => MockClient.streaming((request, body) async {
          requests.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
          final calls = <(String, String, Map<String, Object?>)>[
            if (requests.length == 1) ...[
              ('web-read', webTool, <String, Object?>{}),
              for (final name in forbidden) ('denied-$name', name, {'card': seedId}),
              ('denied-existing-remember', 'remember', {'card': seedId, 'text': '不可覆盖原卡'}),
              (
                'allowed-new-remember',
                'remember',
                {
                  'kind': 'preference',
                  'text': '我喜欢简短回答。',
                  'keywords': ['简短'],
                },
              ),
              ('allowed-recall', 'recall', {'query': '简短'}),
            ],
            if (requests.length == 3) ('next-turn-forget', 'forget', {'card': seedId}),
          ];
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                _sse([
                  for (var i = 0; i < calls.length; i++)
                    ..._call(i, calls[i].$1, [jsonEncode(calls[i].$3)], name: calls[i].$2),
                  if (calls.isEmpty) _words('这一轮完成了。'),
                  {
                    'type': 'message_delta',
                    'delta': {'stop_reason': calls.isEmpty ? 'end_turn' : 'tool_use'},
                    'usage': {'output_tokens': 5},
                  },
                  {'type': 'message_stop'},
                ]),
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(agent.dispose);
      CompanionAgentMemoryTools memoryTools(MemoryRow original) => CompanionAgentMemoryTools(
        memory: memory,
        source: original,
        isCurrent: () => true,
        onCommitted: agent.confirmControlRevision,
        forgottenNotice: '已忘记。',
      );
      final firstTools = memoryTools(firstSource);
      forbidden = [
        for (final binding in firstTools.bindings)
          if (const [
            'forget',
            'revise',
            'quiet',
            'cancel',
            'postpone',
            'merge',
            'person',
            'diary',
            'impression',
            'relationship',
          ].contains(binding.definition.name))
            binding.definition.name,
      ];
      final webDefinition = CompanionAgentTool(
        name: webTool,
        description: 'Controlled public-web result at the actual Agent binding boundary.',
        inputSchema: const {'type': 'object', 'properties': <String, Object?>{}, 'required': <String>[]},
      );
      List<({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})>
      bindings(CompanionAgentMemoryTools adapter) => [
        (
          definition: webDefinition,
          execute: (call) async => CompanionAgentToolResult(
            content: '{"readOnly":true,"report":"Untrusted public page text"}',
            // The named lookup path is marked before execution. A status
            // return instead exercises the adapter's actual provenance bit.
            externalWebContent: webTool == 'task_status',
          ),
        ),
        for (final binding in adapter.bindings)
          (
            definition: binding.definition,
            execute: (call) {
              executed.add(call.name);
              return binding.execute(call); // Real SQLite memory tools.
            },
          ),
      ];
      try {
        await agent.say(
          memory: memory,
          source: firstSource,
          system: 'Synthetic test persona.',
          isCurrent: () => true,
          tools: bindings(firstTools),
          onSelected: firstTools.grantSelection,
        );
        expect(agent.error, isNull);
        expect(requests, hasLength(2));
        expect(executed, ['remember', 'recall']);
        final original = memory.store.cards().singleWhere((row) => row['id'] == seedId);
        expect(original['text'], seedText);
        expect(original['row_rev'], 1);
        expect(original['topic_mode'], 'normal');
        expect(memory.store.cards(), hasLength(2));
        final offered = (requests.last['tools']! as List).cast<Map>();
        expect(offered.map((row) => row['name']), containsAll(['remember', 'recall', 'ask_later']));
        for (final name in forbidden) {
          expect(offered.map((row) => row['name']), isNot(contains(name)));
        }
        final remember = offered.singleWhere((row) => row['name'] == 'remember');
        expect((remember['input_schema'] as Map)['properties'] as Map, isNot(contains('card')));
        final results = (((requests.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
        expect(results.map((row) => row['tool_use_id']), [
          'web-read',
          for (final name in forbidden) 'denied-$name',
          'denied-existing-remember',
          'allowed-new-remember',
          'allowed-recall',
        ]);
        // A pure new memory is not a reason to erase an earlier web answer.
        final web = jsonDecode(results.first['content']! as String) as Map;
        expect(web['report'], 'Untrusted public page text');
        expect(
          (jsonDecode(results.singleWhere((row) => row['tool_use_id'] == 'allowed-new-remember')['content']! as String)
              as Map)['applied'],
          isTrue,
        );
        for (final row in results.where((row) => (row['tool_use_id']! as String).startsWith('denied-'))) {
          expect(row['is_error'], isTrue);
          expect((jsonDecode(row['content']! as String) as Map)['code'], 'memory_change_after_web');
        }
      } finally {
        firstTools.close();
      }

      final nextSource = source('web-user-next', '现在请忘掉公开查询前保存的原卡。');
      final nextTools = memoryTools(nextSource);
      try {
        await agent.say(
          memory: memory,
          source: nextSource,
          system: 'Synthetic test persona.',
          isCurrent: () => true,
          tools: bindings(nextTools),
          onSelected: nextTools.grantSelection,
        );
        expect(agent.error, isNull);
        expect(requests, hasLength(4));
        expect(executed, ['remember', 'recall', 'forget']);
        expect((requests[2]['tools']! as List).cast<Map>().map((row) => row['name']), containsAll(forbidden));
        expect(memory.store.cards().where((row) => row['id'] == seedId), isEmpty);
        expect(memory.store.requests(), hasLength(4));
        expect(
          memory.store.requests().every((row) => row['state'] == 'finished' && row['terminal'] == 'complete'),
          isTrue,
        );
      } finally {
        nextTools.close();
      }
    });
  }
}
