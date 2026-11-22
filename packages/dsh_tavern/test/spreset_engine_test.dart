import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'support/stage1_engine_harness.dart';
import 'support/t24_engine_harness.dart';

class SPresetHost extends ScriptHost implements TavernSPresetScriptHost, TavernSPresetRequestObserver {
  final evaluations = <TavernSPresetEvaluationRequest>[];
  final requests = <Map<String, Object?>>[];
  final released = <String>[];
  bool failFirstRelease = false;
  int actions = 0;
  // Boundary fake only: actual page registration/cache/session semantics are
  // covered by the Node tests loading the shipped asset.
  final _registeredToolsByChat = <String, List<Map<String, Object?>>>{};
  Future<TavernSPresetEvaluationResult> Function(TavernSPresetEvaluationRequest)? handler;
  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    evaluations.add(request);
    if (handler != null) return handler!(request);
    return defaultEvaluate(request);
  }

  Future<TavernSPresetEvaluationResult> defaultEvaluate(TavernSPresetEvaluationRequest request) async {
    Object? value;
    final args = request.arguments;
    switch (request.kind) {
      case TavernSPresetEvaluationKind.validateFunctionExpression:
        value = true;
      case TavernSPresetEvaluationKind.toolDefinition:
        value = {
          'name': 'fixture_tool',
          'description': 'fixture',
          'parameters': {'type': 'object'},
          'hasAction': true,
        };
      case TavernSPresetEvaluationKind.toolRegistry:
        final input = args.single! as Map;
        final mode = input['registryMode'] ?? 'sync';
        if (mode != 'read') {
          _registeredToolsByChat[request.chatId] = [
            for (final binding in (input['bindings']! as List))
              {
                'identifier': (binding as Map)['identifier'],
                'code': binding['code'],
                'sessionId': 'tool:fixture_tool',
                'definition': {
                  'name': 'fixture_tool',
                  'description': 'fixture',
                  'parameters': {'type': 'object'},
                  'hasAction': true,
                },
              },
          ];
        }
        final active = (input['activeIdentifiers']! as List).toSet();
        value = {
          'registryMode': mode,
          'registryModes': ['sync', 'read', 'refresh'],
          'tools': [
            if (mode != 'refresh')
              for (final tool in _registeredToolsByChat[request.chatId] ?? const [])
                if (active.contains(tool['identifier'])) tool,
          ],
        };
      case TavernSPresetEvaluationKind.toolAction:
        value = 'answer-${++actions}';
      case TavernSPresetEvaluationKind.toolFormatMessage:
        value = 'fixture action';
      case TavernSPresetEvaluationKind.functionExpression:
      case TavernSPresetEvaluationKind.syncFunctionExpression:
        if (request.stage == 'OutputPreprocessing') {
          value = ((args.single! as Map<String, Object?>)['chunk']! as String).toUpperCase();
        } else if (request.stage == 'FinalRequestProcessing') {
          final input = args.single! as Map<String, Object?>;
          (input['request']! as Map<String, Object?>)['model'] = 'final-model';
          return TavernSPresetEvaluationResult(requestId: request.requestId, isUndefined: true, arguments: args);
        } else {
          value = args.firstOrNull;
        }
    }
    return TavernSPresetEvaluationResult(requestId: request.requestId, value: value, committed: false, arguments: args);
  }

  @override
  Future<void> releaseSPresetSession(String sessionId) async {
    released.add(sessionId);
    if (failFirstRelease && released.length == 1) throw StateError('synthetic release failure');
  }

  @override
  Future<void> observeSPresetRequest(
    TavernSPresetRequestSnapshot request,
    TavernScriptCancellation cancellation,
  ) async {
    requests.add(request.body);
    request.body['model'] = 'observer-cannot-mutate';
  }
}

ChatPreset preset(Map<String, Object?> extension, {bool stream = true, Object? limit, bool calling = false}) {
  final raw = t24Preset().raw;
  raw['openai_max_context'] = 32768;
  raw['show_thoughts'] = false;
  raw['stream_openai'] = stream;
  raw['function_calling'] = calling;
  raw['custom_prompt_post_processing'] = 'merge_tools';
  if (limit != null) raw['tool_call_recurse_limit'] = limit;
  raw['extensions'] = {'SPreset': extension};
  final prompts = raw['prompts']! as List<Object?>;
  prompts.add({'identifier': 'fixture-slot', 'role': 'system', 'content': '', 'injection_position': 0});
  final orders = raw['prompt_order']! as List<Object?>;
  final group = orders.whereType<Map<String, Object?>>().firstWhere((value) => value['character_id'] == 100001);
  (group['order']! as List<Object?>).add({'identifier': 'fixture-slot', 'enabled': true});
  return ChatPreset(raw);
}

Map<String, Object?> toolExtension({Map<String, Object?> extra = const {}}) => {
  'ToolBindings': {
    'fixture-slot': {'enabled': true, 'valid': true, 'uuid': 'fixture-uuid', 'code': 'fixture-definition'},
  },
  ...extra,
};

void main() {
  test('close attempts every retained session when the first release fails', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = SPresetHost()..failFirstRelease = true;
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(
      preset({
        'FinalRequestProcessing': {'enabled': true, 'script': 'fixture-final'},
        'OutputPreprocessing': {'enabled': true, 'script': 'fixture-output'},
      }),
    );
    final active = await h.start();
    await stage1Finish(active.call, content: 'hello');
    await active.events.done.future;
    await h.reopen();
    final expected = host.evaluations.map((request) => request.sessionId).toSet();
    expect(expected.length, greaterThan(1));
    expect(host.released.toSet(), expected);
  });

  test('ordinary generation observes exact final body and persists processed output', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = SPresetHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(
      preset({
        'FinalRequestProcessing': {'enabled': true, 'script': 'fixture-final'},
        'OutputPreprocessing': {'enabled': true, 'script': 'fixture-output'},
      }),
    );
    final active = await h.start();
    expect(active.call.body!['model'], 'final-model');
    expect(host.requests.single, active.call.body);
    await stage1Finish(active.call, content: 'hello');
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(active.events.values.whereType<TavernTurnDone>().single.message.text, 'HELLO');
    expect((await h.engine.path(h.chatId)).last.text, 'HELLO');
  });

  test('nonstream processor is called once with full content and final=true', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = SPresetHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(
      preset({
        'OutputPreprocessing': {'enabled': true, 'script': 'fixture-output'},
      }, stream: false),
    );
    final active = await h.start();
    await stage1Finish(active.call, content: 'whole');
    await active.events.done.future;
    final calls = host.evaluations.where((call) => call.stage == 'OutputPreprocessing').toList();
    expect(calls, hasLength(1));
    expect((calls.single.arguments.single! as Map)['final'], isTrue);
    expect((calls.single.arguments.single! as Map)['chunk'], 'whole');
    expect(active.events.values.whereType<TavernTurnDone>().single.message.text, 'WHOLE');
  });

  test('missing final-request host is visible and aborts before model send', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    await h.engine.setPreset(
      preset({
        'FinalRequestProcessing': {'enabled': true, 'script': 'requires-page'},
      }),
    );
    final events = await h.engine.send(h.chatId, 'question').toList();
    expect(h.model.generated, 0);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.hookIssues.any((issue) => issue.stage == 'FinalRequestProcessing'), isTrue);
  });

  for (final entry in <(Object?, int, int)>[(null, 5, 6), (7, 7, 8), (2.5, 3, 4), (-1, 0, 1), ('NaN', 0, 1)]) {
    test('ToolBindings limit ${entry.$1} allows ${entry.$2} actions and ${entry.$3} requests', () async {
      final h = await Stage1Harness.open(state: false, deepseek: false);
      final host = SPresetHost();
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(preset(toolExtension(), limit: entry.$1, calling: true));
      final active = await h.start();
      var current = active.call;
      for (var index = 0; index < entry.$3; index++) {
        final next = index + 1 < entry.$3 ? h.model.prepare() : null;
        expect(
          stage1Rows(current.body!['tools']).any((tool) => stage1Map(tool['function'])['name'] == 'fixture_tool'),
          isTrue,
        );
        await stage1Finish(
          current,
          content: '$index',
          reason: 'tool_calls',
          tools: [
            Stage1Call(0, 'call-$index', 'fixture_tool', {'n': index}),
          ],
        );
        if (next != null) {
          await Stage1Harness.listening(next, active.events);
          expect(stage1Rows(next.body!['messages']).last['content'], 'answer-${index + 1}');
          current = next;
        }
      }
      await active.events.done.future;
      expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(host.actions, entry.$2);
      expect(h.model.generated, entry.$3);
      final turn = await h.turn(active.events);
      expect(turn.budgetUsed, entry.$3);
      expect(
        turn.budgetMax,
        entry.$1 == 7
            ? 8
            : entry.$1 == null
            ? 6
            : 4,
      );
      expect(h.database((db) => db.select('PRAGMA foreign_key_check')), isEmpty);
    });
  }

  test('native fourth-roll budget does not swallow an allowed SPreset call in the same batch', () async {
    final h = await Stage1Harness.open(state: false);
    final host = SPresetHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), limit: 5, calling: true));
    final active = await h.start();
    var current = active.call;
    for (var index = 0; index < 5; index++) {
      final next = index < 4 ? h.model.prepare() : null;
      await stage1Finish(
        current,
        content: 'x',
        reason: index < 4 ? 'tool_calls' : 'stop',
        tools: [
          if (index < 4) Stage1Call(0, 'roll-$index', 'roll', {'dice': 'd6'}),
          if (index < 4) Stage1Call(1, 'custom-$index', 'fixture_tool', {}),
        ],
      );
      if (next != null) {
        await Stage1Harness.listening(next, active.events);
        current = next;
      }
    }
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.dice.calls, 3);
    expect(host.actions, 4);
    final turn = await h.turn(active.events);
    final receipts = [for (final id in turn.receiptIds) (await h.engine.readToolReceipt(id))!];
    expect(receipts.where((r) => r.error?['code'] == 'native_roll_budget_exhausted'), hasLength(1));
  });

  test('string Infinity preserves an explicit unbounded SPreset budget as JSON null', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = SPresetHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), limit: 'Infinity', calling: true));
    final active = await h.start();
    final next = h.model.prepare();
    await stage1Finish(active.call, reason: 'tool_calls', tools: [Stage1Call(0, 'infinite', 'fixture_tool', {})]);
    await Stage1Harness.listening(next, active.events);
    await stage1Finish(next, content: 'done');
    await active.events.done.future;
    final turn = await h.turn(active.events);
    expect(turn.budgetMax, isNull);
    expect(jsonDecode(jsonEncode(turn.toJson()))['budgetMax'], isNull);
    expect(host.actions, 1);
    expect(h.model.generated, 2);
  });

  test('truthy stealth binding stops after the actual action without a follow-up request', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = SPresetHost();
    host.handler = (request) async {
      final response = await host.defaultEvaluate(request);
      if (request.kind != TavernSPresetEvaluationKind.toolRegistry) return response;
      final registry = response.value! as Map<String, Object?>;
      for (final tool in (registry['tools']! as List).cast<Map<String, Object?>>()) {
        (tool['definition']! as Map<String, Object?>)['stealth'] = 'yes';
      }
      return TavernSPresetEvaluationResult(requestId: request.requestId, value: registry);
    };
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), calling: true));
    final active = await h.start();
    await stage1Finish(
      active.call,
      content: 'before',
      reason: 'tool_calls',
      tools: [Stage1Call(0, 'stealth', 'fixture_tool', {})],
    );
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(host.actions, 1);
    expect(h.model.generated, 1);
  });

  for (final undefined in [false, true]) {
    test('empty action result undefined=$undefined uses the ST tool content placeholder', () async {
      final h = await Stage1Harness.open(state: false, deepseek: false);
      final host = SPresetHost();
      host.handler = (request) async => request.kind == TavernSPresetEvaluationKind.toolAction
          ? TavernSPresetEvaluationResult(
              requestId: request.requestId,
              value: undefined ? null : '',
              isUndefined: undefined,
              committed: false,
            )
          : host.defaultEvaluate(request);
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(preset(toolExtension(), calling: true));
      final active = await h.start();
      final next = h.model.prepare();
      await stage1Finish(active.call, reason: 'tool_calls', tools: [Stage1Call(0, 'empty', 'fixture_tool', {})]);
      await Stage1Harness.listening(next, active.events);
      expect(stage1Rows(next.body!['messages']).last['content'], '[No content]');
      await stage1Finish(next, content: 'done');
      await active.events.done.future;
      expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    });
  }

  test('background generate uses final processing at actual HTTP and output before result', () async {
    final h = await generationFixture();
    final character = await h.card('SPreset character');
    final chat = await h.engine.createChat(character);
    final host = SPresetHost();
    h.bridge.attachHost(host);
    await h.engine.setPreset(
      preset({
        'FinalRequestProcessing': {'enabled': true, 'script': 'fixture-final'},
        'OutputPreprocessing': {'enabled': true, 'script': 'fixture-output'},
      }),
    );
    final context = await h.context(chat);
    final plan = generationJsonResponse(h, {
      'choices': [
        {
          'message': {'role': 'assistant', 'content': 'background'},
          'finish_reason': 'stop',
        },
      ],
    });
    final generation = await h.bridge.generate(context.id, TavernScriptGenerateRequest(stream: false));
    final request = await generationRequest(generation, plan);
    expect(request.body['model'], 'final-model');
    expect(host.requests.single, request.body);
    expect((await generation.result).text, 'BACKGROUND');
  });

  test('fixed-name conflict retains import and marker, accent-insensitive name comparison', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final first = await h.engine.importPreset(
      jsonEncode(preset({'FixedPresetName': 'Café'}).raw),
      fileName: 'one.json',
    );
    expect(first.preset.name, 'Café');
    expect(spresetFixedPresetName(first.preset.raw), '');
    final second = await h.engine.importPreset(
      jsonEncode(preset({'FixedPresetName': 'CAFE'}).raw),
      fileName: 'two.json',
    );
    expect(second.preset.name, 'two');
    expect(spresetFixedPresetName(second.preset.raw), 'CAFE');
    expect(second.issues.any((issue) => issue.code == 'spreset-fixed-name-conflict'), isTrue);
    expect(first.preset.sourceText, contains('FixedPresetName'));
  });

  test('format callback ownership loss prevents action entry', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = SPresetHost();
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    host.handler = (request) async {
      if (request.kind == TavernSPresetEvaluationKind.toolRegistry) {
        final normal = await host.defaultEvaluate(request);
        final registry = normal.value! as Map<String, Object?>;
        for (final tool in (registry['tools']! as List).cast<Map<String, Object?>>()) {
          (tool['definition']! as Map<String, Object?>)['hasFormatMessage'] = true;
        }
        return TavernSPresetEvaluationResult(requestId: request.requestId, value: registry);
      }
      if (request.kind == TavernSPresetEvaluationKind.toolFormatMessage) {
        entered.complete();
        await release.future;
      }
      return host.defaultEvaluate(request);
    };
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), calling: true));
    final active = await h.start();
    await stage1Finish(
      active.call,
      content: 'before',
      reason: 'tool_calls',
      tools: [Stage1Call(0, 't', 'fixture_tool', {})],
    );
    await entered.future;
    h.database(
      (db) => db.execute(
        "UPDATE nodes SET text = 'external-edit' WHERE id = (SELECT current_leaf_id FROM chats WHERE id = ?)",
        [h.chatId],
      ),
    );
    release.complete();
    await active.events.done.future;
    expect(host.actions, 0);
    expect(active.events.values.whereType<TavernTurnFailed>(), hasLength(1));
    final turn = await h.turn(active.events);
    final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
    expect(receipt.committed, isFalse);
  });

  for (final actualCommitted in [true, false]) {
    test(
      'cancelled action adopts late committed=$actualCommitted without changing wire bytes or releasing an active host',
      () async {
        final h = await Stage1Harness.open(state: false, deepseek: false);
        final host = SPresetHost();
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        host.handler = (request) async {
          if (request.kind != TavernSPresetEvaluationKind.toolAction) return host.defaultEvaluate(request);
          host.actions++;
          entered.complete();
          await release.future;
          return TavernSPresetEvaluationResult(
            requestId: request.requestId,
            value: 'actual-result-$actualCommitted',
            committed: actualCommitted,
          );
        };
        h.engine.scripts.attachHost(host);
        await h.engine.setPreset(preset(toolExtension(), calling: true));
        final active = await h.start();
        await stage1Finish(active.call, reason: 'tool_calls', tools: [Stage1Call(0, 't', 'fixture_tool', {})]);
        await entered.future;
        h.engine.stop(h.chatId);
        await active.events.done.future;
        final turn = await h.turn(active.events);
        final before = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
        expect(before.committed, isNull);
        final sealed = before.wireResult;
        String sealedBytes() => h.database(
          (db) =>
              db.select('SELECT wire_result_json FROM tool_receipts WHERE id = ?', [
                    before.executionId,
                  ]).single['wire_result_json']!
                  as String,
        );
        final originalWireBytes = sealedBytes();
        var reopened = false;
        final reopening = h.reopen().then((_) {
          reopened = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(reopened, isFalse);
        expect(host.released, isEmpty);
        expect(h.model.generated, 1);
        release.complete();
        await reopening;
        final after = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
        expect(after.committed, actualCommitted);
        expect(after.status, actualCommitted ? 'committed' : 'completed_no_change');
        expect(after.wireResult, sealed);
        expect(sealedBytes(), originalWireBytes);
        expect((after.result!['value']! as Map)['observedLate'], isTrue);
        expect((after.result!['value']! as Map)['result'], 'actual-result-$actualCommitted');
        expect(host.released, isNotEmpty);
        expect(host.actions, 1);
        expect(h.model.generated, 1);
      },
    );
  }

  for (final streaming in [true, false]) {
    test(
      'tool consumption preprocessing failure has upstream ${streaming ? 'stream' : 'nonstream'} fallback',
      () async {
        final h = await Stage1Harness.open(state: false, deepseek: false);
        final host = SPresetHost();
        host.handler = (request) async {
          if (request.stage == 'OutputPreprocessing') {
            final arg = request.arguments.single! as Map<String, Object?>;
            if ((arg['chunk']! as String).contains('bad')) throw StateError('synthetic processor failure');
          }
          return host.defaultEvaluate(request);
        };
        h.engine.scripts.attachHost(host);
        await h.engine.setPreset(
          preset({
            'OutputPreprocessing': {'enabled': true, 'script': 'fixture-output', 'consumeToolCalls': true},
          }, stream: streaming),
        );
        final active = await h.start();
        await stage1Finish(
          active.call,
          content: 'hello',
          reason: 'tool_calls',
          tools: [
            Stage1Call(0, 't', 'unregistered', {'text': 'bad'}),
          ],
        );
        await active.events.done.future;
        expect(
          active.events.values.whereType<TavernTurnFailed>(),
          isEmpty,
          reason: active.events.values.whereType<TavernTurnFailed>().map((event) => event.detail).join('\n'),
        );
        expect(
          active.events.values.whereType<TavernTurnDone>().single.message.text,
          streaming ? 'HELLO' : 'hello\nbad',
        );
        final turn = await h.turn(active.events);
        expect(turn.receiptIds.length, streaming ? 1 : 0);
        expect(host.actions, 0);
      },
    );
  }

  for (final value in <(bool, bool?)>[(false, null), (false, false), (true, null), (true, true)]) {
    test('effective show_thoughts deepseek=${value.$1} explicit=${value.$2}', () async {
      final h = await Stage1Harness.open(state: false, deepseek: value.$1, thinking: false);
      final raw = t24Preset().raw;
      if (value.$2 != null) raw['show_thoughts'] = value.$2;
      await h.engine.setPreset(ChatPreset(raw));
      final active = await h.start();
      active.call.add(const ModelReasoning('visible thought'));
      await stage1Finish(active.call, content: 'answer');
      await active.events.done.future;
      final done = active.events.values.whereType<TavernTurnDone>().single;
      expect(done.message.reasoning ?? '', (value.$2 ?? !value.$1) ? 'visible thought' : '');
      if (value.$1) expect(active.call.body!['thinking'], {'type': value.$2 == true ? 'enabled' : 'disabled'});
    });
  }
}
