// Channel-boundary tests only. SQLite turn/source ownership is real; native
// permission UI and device actions remain explicit boundaries, not simulated Core.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent.dart';
import 'package:dsh_app/companion/companion_agent_phone_tools.dart';
import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _channel = MethodChannel('dsh/phone');
final _now = DateTime.utc(2026, 11, 22, 9).millisecondsSinceEpoch;
const _catalog = [
  {
    'name': 'open',
    'description': '尝试打开应用或链接。',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'app': {'type': 'string'},
        'url': {'type': 'string'},
      },
      'additionalProperties': false,
    },
  },
];

http.StreamedResponse _modelReply(List<(String, String, Map<String, Object?>)> calls) {
  final events = <Map<String, Object?>>[
    for (var i = 0; i < calls.length; i++) ...[
      {
        'type': 'content_block_start',
        'index': i,
        'content_block': {'type': 'tool_use', 'id': calls[i].$1, 'name': calls[i].$2, 'input': <String, Object?>{}},
      },
      {
        'type': 'content_block_delta',
        'index': i,
        'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(calls[i].$3)},
      },
      {'type': 'content_block_stop', 'index': i},
    ],
    {
      'type': 'message_delta',
      'delta': {'stop_reason': calls.isEmpty ? 'end_turn' : 'tool_use'},
      'usage': {'output_tokens': 5},
    },
    {'type': 'message_stop'},
  ];
  final wire = [for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join();
  return http.StreamedResponse(Stream.value(utf8.encode(wire)), 200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CompanionMemoryOwner memory;
  late MemoryRow source;
  late String turnId;
  late CompanionAgentPhoneTools phone;
  late List<String> steps;
  late List<void Function()> release;
  var current = true;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-phone-tools-');
    memory = CompanionMemoryOwner(
      CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => _now),
      CompanionLocal.at(directory, nowMilliseconds: () => _now),
      nowMilliseconds: () => _now,
    );
    source = memory.store.submitMessage(
      id: 'actual-user-source',
      sessionId: memory.store.lightSessionId,
      text: '请帮我打开日历。',
      saidAtUtc: _now,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
    turnId =
        memory.store.beginAgentTurn(
              messageId: source['id']! as String,
              expectedSourceRev: source['source_rev']! as int,
              shownCardRevisions: const {},
            )['id']!
            as String;
    current = true;
    steps = [];
    release = [];
    phone = CompanionAgentPhoneTools(
      memory: memory,
      source: source,
      turnId: turnId,
      isCurrent: () => current,
      onStep: steps.add,
    );
  });

  tearDown(() async {
    for (final unblock in release) {
      unblock();
    }
    current = false;
    await phone.close(stopped: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    memory.store.closeAgentTurn(turnId);
    memory.dispose();
    // Agent.say has settled its real request receipts before this cleanup.
    // No worker, migration or file-backed local write was started.
    await directory.delete(recursive: true);
  });

  test('phone tools require native approval for the actual user source before dispatch', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'companionPhoneTools' => _catalog,
        'companionPhoneBegin' => {'decision': 'rejected'},
        'companionPhoneEnd' => null,
        _ => throw StateError('Native action must not execute after rejection'),
      };
    });
    await phone.prepare();
    expect(phone.bindings.single.definition.name, 'phone_open');
    final result = await phone.execute(
      const CompanionAgentToolCall(id: 'rejected-open', name: 'phone_open', input: {'app': 'calendar'}),
    );
    expect(result.isError, isTrue);
    expect((jsonDecode(result.content) as Map)['code'], 'phone_not_authorized');
    final begin = calls.singleWhere((call) => call.method == 'companionPhoneBegin').arguments as Map;
    expect(begin['sourceId'], source['id']);
    expect(begin['sourceRev'], source['source_rev']);
    expect(begin['sourceText'], source['text']);
    expect(begin['firstTool'], 'open');
    expect(calls.where((call) => call.method == 'companionPhoneCall'), isEmpty);
    expect(steps, isEmpty);
  });

  test('assistant yields the original task once, after approval and before the first main-screen read', () async {
    const appChannel = MethodChannel('dsh/app');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final order = <String>[];
    messenger.setMockMethodCallHandler(appChannel, (call) async {
      order.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(appChannel, null));
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'companionPhoneTools':
          return [
            {'name': 'screen', 'description': 'Read screen', 'inputSchema': <String, Object?>{}},
          ];
        case 'companionPhoneBegin':
          order.add('approved');
          return {'decision': 'allowed-once'};
        case 'companionPhoneCall':
          final args = call.arguments as Map;
          order.add(args['callId'] as String);
          return '{"result":{"content":[]}}';
        case 'companionPhoneEnd':
          return null;
        default:
          throw StateError(call.method);
      }
    });
    phone = CompanionAgentPhoneTools(
      memory: memory,
      source: source,
      turnId: turnId,
      isCurrent: () => current,
      onStep: steps.add,
      returnToApp: true,
    );
    await phone.prepare();
    for (final (id, input) in [
      ('background', <String, Object?>{'background': true}),
      ('first', <String, Object?>{}),
      ('second', <String, Object?>{}),
    ]) {
      final result = await phone.execute(CompanionAgentToolCall(id: id, name: 'phone_screen', input: input));
      expect(result.isError, isFalse);
    }
    expect(order, ['approved', 'background', 'yieldCompanionAssistant', 'first', 'second']);
  });

  test('stop during native approval fences the late approval and close awaits one original drain', () async {
    final began = Completer<void>();
    final approval = Completer<Map<String, Object?>>();
    final ending = Completer<void>();
    final drain = Completer<void>();
    release.add(() {
      if (!approval.isCompleted) approval.complete({'decision': 'stopped'});
    });
    release.add(() {
      if (!drain.isCompleted) drain.complete();
    });
    var nativeCalls = 0;
    var ends = 0;
    Map? startIdentity, endIdentity;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'companionPhoneTools':
          return _catalog;
        case 'companionPhoneBegin':
          startIdentity = call.arguments as Map;
          began.complete();
          return approval.future;
        case 'companionPhoneCall':
          nativeCalls++;
          return null;
        case 'companionPhoneEnd':
          ends++;
          endIdentity = call.arguments as Map;
          ending.complete();
          await drain.future;
          return null;
        default:
          throw StateError(call.method);
      }
    });
    await phone.prepare();
    final running = phone.execute(
      const CompanionAgentToolCall(id: 'late-open', name: 'phone_open', input: {'app': 'calendar'}),
    );
    await began.future;
    phone.stop();
    final closed = phone.close();
    expect(identical(closed, phone.close()), isTrue);
    var completed = false;
    final completion = closed.then((_) => completed = true);
    await ending.future;
    expect(completed, isFalse);
    expect(endIdentity!['sessionId'], startIdentity!['sessionId']);
    expect(endIdentity!['runId'], startIdentity!['runId']);
    expect(endIdentity!['stopped'], isTrue);
    approval.complete({'decision': 'allowed-once'});
    expect((await running).isError, isTrue);
    expect(nativeCalls, 0);
    drain.complete();
    await completion;
    expect(completed, isTrue);
    expect(ends, 1);
    expect(steps, isEmpty);
  });

  test('phone tools preserve native text without claiming image sight and never replay a call id', () async {
    final dispatched = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'companionPhoneTools':
          return _catalog;
        case 'companionPhoneBegin':
          return {'decision': 'allowed-once'};
        case 'companionPhoneEnd':
          return null;
        case 'companionPhoneCall':
          final args = call.arguments as Map;
          dispatched.add(args);
          return jsonEncode({
            'jsonrpc': '2.0',
            'id': args['callId'],
            'result': {
              'isError': false,
              'content': [
                {'type': 'text', 'text': '已打开日历。\n这是实际返回的第二行。'},
                {'type': 'image', 'data': 'NOT_MODEL_VISUAL_INPUT', 'mimeType': 'image/png'},
              ],
            },
          });
        default:
          throw StateError(call.method);
      }
    });
    await phone.prepare();
    const call = CompanionAgentToolCall(id: 'one-open', name: 'phone_open', input: {'app': 'calendar'});
    final result = await phone.execute(call);
    expect(result.isError, isFalse);
    expect(result.externalWebContent, isTrue);
    final content = jsonDecode(result.content) as Map;
    expect(content['nativeResult'], '已打开日历。\n这是实际返回的第二行。');
    expect(content['imageUnavailable'], isTrue);
    expect(result.content, isNot(contains('NOT_MODEL_VISUAL_INPUT')));
    expect(steps, ['已打开日历。']);
    expect(dispatched.single['name'], 'open');
    expect(dispatched.single['arguments'], call.input);
    final repeat = await phone.execute(
      const CompanionAgentToolCall(id: 'one-open', name: 'phone_open', input: {'app': 'another-app'}),
    );
    expect(repeat.isError, isTrue);
    expect((jsonDecode(repeat.content) as Map)['code'], 'duplicate_phone_call');
    expect(dispatched, hasLength(1));
    expect(steps, hasLength(1));

    // An action reply can contain external screen text too. Exercise the real
    // Agent's same-batch execution gate and next-user reset, not a second loop.
    await phone.close();
    memory.store.closeAgentTurn(turnId);
    const cardId = '11111111-1111-4111-8111-111111111111';
    const cardText = '我喜欢用日历安排事情。';
    memory.store.saveManual(
      const CompanionMemory(id: cardId, text: cardText, keywords: ['日历']),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    source = memory.store.submitMessage(
      id: 'phone-loop-user',
      sessionId: memory.store.lightSessionId,
      text: '请帮我打开日历。',
      saidAtUtc: _now,
      offsetMinutes: 480,
    );
    final requests = <Map<String, Object?>>[];
    final executedMemory = <String>[];
    final agent = CompanionAgent(
      apiKey: () => 'synthetic',
      client: () => MockClient.streaming((request, body) async {
        requests.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
        return _modelReply(switch (requests.length) {
          1 => [
            ('loop-open', 'phone_open', <String, Object?>{'app': 'calendar'}),
            ('same-batch-forget', 'forget', <String, Object?>{'card': cardId}),
          ],
          3 => [
            ('new-user-forget', 'forget', <String, Object?>{'card': cardId}),
          ],
          _ => [],
        });
      }),
    );
    addTearDown(agent.dispose);
    CompanionAgentMemoryTools forSource(MemoryRow row) => CompanionAgentMemoryTools(
      memory: memory,
      source: row,
      isCurrent: () => current,
      onCommitted: agent.confirmControlRevision,
      forgottenNotice: '已忘记。',
    );
    final firstTools = forSource(source);
    turnId = firstTools.turnId;
    firstTools.grantCards(memory.store.cards());
    phone = CompanionAgentPhoneTools(
      memory: memory,
      source: source,
      turnId: turnId,
      isCurrent: () => current && firstTools.isCurrent,
      onStep: steps.add,
    );
    await phone.prepare();
    try {
      await agent.say(
        memory: memory,
        source: source,
        system: 'Synthetic phone-result boundary.',
        isCurrent: () => current,
        onSelected: firstTools.grantSelection,
        tools: [
          ...phone.bindings,
          for (final binding in firstTools.bindings)
            (
              definition: binding.definition,
              execute: (CompanionAgentToolCall tool) {
                executedMemory.add(tool.name);
                return binding.execute(tool);
              },
            ),
        ],
      );
      expect(agent.error, isNull);
      expect(requests, hasLength(2));
      expect(executedMemory, isEmpty);
      expect(memory.store.cards().single['text'], cardText);
      expect(memory.store.cards().single['row_rev'], 1);
      final offered = (requests.last['tools']! as List).cast<Map>();
      expect(offered.map((row) => row['name']), isNot(contains('forget')));
      final results = (((requests.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
      expect(results.map((row) => row['tool_use_id']), ['loop-open', 'same-batch-forget']);
      expect(results.last['is_error'], isTrue);
      expect((jsonDecode(results.last['content']! as String) as Map)['code'], 'memory_change_after_web');
      expect((jsonDecode(results.first['content']! as String) as Map)['nativeResult'], '已打开日历。\n这是实际返回的第二行。');
      expect(dispatched, hasLength(2));
    } finally {
      await phone.close();
      firstTools.close();
    }

    source = memory.store.submitMessage(
      id: 'phone-loop-new-user',
      sessionId: memory.store.lightSessionId,
      text: '现在请忘掉我的日历偏好。',
      saidAtUtc: _now,
      offsetMinutes: 480,
    );
    final nextTools = forSource(source);
    turnId = nextTools.turnId;
    nextTools.grantCards(memory.store.cards());
    try {
      await agent.say(
        memory: memory,
        source: source,
        system: 'Synthetic phone-result boundary.',
        isCurrent: () => current,
        onSelected: nextTools.grantSelection,
        tools: [
          for (final binding in nextTools.bindings)
            (
              definition: binding.definition,
              execute: (CompanionAgentToolCall tool) {
                executedMemory.add(tool.name);
                return binding.execute(tool);
              },
            ),
        ],
      );
      expect(agent.error, isNull);
      expect(requests, hasLength(4));
      expect((requests[2]['tools']! as List).cast<Map>().map((row) => row['name']), contains('forget'));
      expect(executedMemory, ['forget']);
      expect(memory.store.cards().where((row) => row['id'] == cardId), isEmpty);
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
