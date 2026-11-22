import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

// Only the page's evaluation result and HTTP peer are supplied. Requests use
// the real engine, SQLite, prompt pipeline, model encoder and HTTP decoder.
class _ArrayHost extends SPresetHost {
  _ArrayHost({this.result = const ['A'], this.hold}) {
    handler = (request) async {
      final arguments = request.arguments;
      if (request.stage == 'ChatSquash') {
        postInputs.add(arguments.single! as List<Object?>);
        if (!entered.isCompleted) entered.complete();
        await hold;
        return TavernSPresetEvaluationResult(requestId: request.requestId, value: result);
      }
      if (request.stage == 'FinalRequestProcessing') {
        final body = (arguments.single! as Map<String, Object?>)['request']! as Map<String, Object?>;
        finalInputs.add(scriptMap(jsonDecode(jsonEncode(body))));
        body['messages'] = [
          {'role': 'user', 'content': 'repaired A'},
        ];
        return TavernSPresetEvaluationResult(requestId: request.requestId, isUndefined: true, arguments: arguments);
      }
      return defaultEvaluate(request);
    };
  }

  final List<Object?> result;
  final Future<void>? hold;
  final entered = Completer<void>();
  final postInputs = <List<Object?>>[];
  final finalInputs = <Map<String, Object?>>[];
}

ChatPreset _arrayPreset({String mode = '', bool finalScript = true}) {
  final raw = scriptPreset(main: 'admitted instruction').raw;
  raw['custom_prompt_post_processing'] = mode;
  raw['extensions'] = {
    'SPreset': {
      'ChatSquash': {
        'enabled': false,
        'squashed_post_script_enable': true,
        'squashed_post_script': 'synthetic-array-result',
      },
      'FinalRequestProcessing': {'enabled': finalScript, 'script': 'synthetic-array-repair'},
    },
  };
  return ChatPreset(raw);
}

Future<({ScriptFixture h, String chatId, _ArrayHost host})> _ordinary({
  String mode = '',
  bool finalScript = true,
  _ArrayHost? host,
  bool deepseek = false,
}) async {
  final h = await generationFixture();
  if (deepseek) {
    h.engine.configure(
      TavernModelConfig(apiKey: h.config.apiKey, baseUrl: h.config.baseUrl, model: h.config.model, deepseek: true),
    );
  }
  final character = await h.card('Message array boundary');
  final chatId = await h.engine.createChat(character);
  final page = host ?? _ArrayHost();
  h.bridge.attachHost(page);
  await h.engine.setPreset(_arrayPreset(mode: mode, finalScript: finalScript));
  return (h: h, chatId: chatId, host: page);
}

void main() {
  // The fixed ST switch defaults to returning messages for every unrecognized
  // mode, not only ''. Keep that distinction observable at actual transport.
  for (final mode in ['', 'none', 'future-unknown-mode']) {
    test('ordinary no-op mode "$mode" lets final processing repair primitive messages', () async {
      final fixture = await _ordinary(mode: mode);
      final h = fixture.h;
      final response = h.reply('accepted');
      final events = ScriptEvents(h.engine.send(fixture.chatId, 'admitted question'));
      final request = await events.waitRequest(response);
      await events.done.future;
      expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(events.values.whereType<TavernTurnDone>().single.message.text, 'accepted');
      expect(fixture.host.postInputs, hasLength(1));
      expect(fixture.host.finalInputs.single['messages'], ['A']);
      expect(request.body['messages'], [
        {'role': 'user', 'content': 'repaired A'},
      ]);
      expect(fixture.host.requests.single, request.body);
      expect(request.body['temperature'], 0.4);
      expect(request.body['max_tokens'], 73);
      final assembly = (await h.engine.inspectTurn(fixture.chatId))!.prompt!;
      expect(assembly.body['messages'], ['A']);
      expect(assembly.budget, 8192 - 73);
      expect(assembly.remainingBudget, greaterThan(0));
      expect(assembly.afterPostProcessing.map((segment) => segment.message), fixture.host.postInputs.single);
      expect(assembly.afterPostProcessing.any((segment) => segment.message['content'] == 'admitted question'), isTrue);
      expect(h.requests, hasLength(1));
    });
  }

  test('unrepaired primitive array reaches HTTP and preserves the provider error', () async {
    final fixture = await _ordinary(finalScript: false);
    final h = fixture.h;
    final response = generationJsonResponse(h, {
      'error': {'message': 'provider requires message objects'},
    }, status: 400);
    final events = ScriptEvents(h.engine.send(fixture.chatId, 'question'));
    final request = await events.waitRequest(response);
    await events.done.future;
    expect(request.body['messages'], ['A']);
    expect(fixture.host.requests.single, request.body);
    expect(fixture.host.finalInputs, isEmpty);
    final failed = events.values.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.invalidParameters);
    expect(failed.detail, contains('provider requires message objects'));
    expect(failed.hookIssues.where((issue) => issue.stage == 'ChatSquash'), isEmpty);
    expect(h.requests, hasLength(1));
  });

  test('background raw carries mixed JSON to final once and retains sampling and literal admission', () async {
    final h = await generationFixture();
    final host = _ArrayHost(
      result: const [
        {'role': 'system', 'content': 'kept object'},
        null,
        false,
        'A',
      ],
    );
    h.bridge.attachHost(host);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'raw-array'));
    final presetId = (await h.engine.importPreset(jsonEncode(_arrayPreset().raw))).preset.id;
    final response = h.reply('raw accepted');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        presetId: presetId,
        samplingOverrides: {'temperature': 0.6, 'max_tokens': 41, 'seed': 17},
        orderedPrompts: const [
          TavernScriptPromptPart.literal(
            role: TavernScriptPromptRole.user,
            content: 'RAW {{incglobalvar::must-not-run}}',
          ),
        ],
      ),
    );
    final request = await generationRequest(generation, response);
    expect((await generation.result).text, 'raw accepted');
    expect(host.postInputs, [
      [
        {'role': 'user', 'content': 'RAW {{incglobalvar::must-not-run}}'},
      ],
    ]);
    expect(host.finalInputs.single['messages'], host.result);
    expect(host.requests.single, request.body);
    expect(request.body['messages'], [
      {'role': 'user', 'content': 'repaired A'},
    ]);
    expect(request.body['temperature'], 0.6);
    expect(request.body['max_tokens'], 41);
    expect(request.body['seed'], 17);
    expect(h.engine.globalVariables.containsKey('must-not-run'), isFalse);
    expect(h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM nodes').single['n']), 0);
    expect(h.requests, hasLength(1));
  });

  for (final mode in ['', 'merge']) {
    test('Map-only result still takes the typed "$mode" conversion', () async {
      final host = _ArrayHost(
        result: const [
          {'role': 'user', 'content': 'first'},
          {'role': 'user', 'content': 'second'},
        ],
      );
      final fixture = await _ordinary(mode: mode, finalScript: false, host: host);
      final response = fixture.h.reply('accepted');
      final events = ScriptEvents(fixture.h.engine.send(fixture.chatId, 'question'));
      final request = await events.waitRequest(response);
      await events.done.future;
      expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(
        request.body['messages'],
        mode.isEmpty
            ? host.result
            : [
                {'role': 'user', 'content': 'first\n\nsecond'},
              ],
      );
      final assembly = (await fixture.h.engine.inspectTurn(fixture.chatId))!.prompt!;
      expect(assembly.afterPostProcessing.map((segment) => segment.message), request.body['messages']);
      expect(host.postInputs, hasLength(1));
    });
  }

  for (final mode in ['merge', 'claude', 'merge_tools', 'semi', 'semi_tools', 'strict', 'strict_tools', 'single']) {
    test('recognized conversion "$mode" preserves its pre-final typed failure', () async {
      final fixture = await _ordinary(mode: mode);
      final events = await fixture.h.engine.send(fixture.chatId, 'question').toList();
      expect(events.whereType<TavernTurnFailed>(), hasLength(1));
      expect(fixture.host.postInputs, hasLength(1));
      expect(fixture.host.finalInputs, isEmpty);
      fixture.h.expectNoGeneration();
    });
  }

  test('DeepSeek retains provider conversion before final even with no custom mode', () async {
    final fixture = await _ordinary(deepseek: true);
    final events = await fixture.h.engine.send(fixture.chatId, 'question').toList();
    expect(events.whereType<TavernTurnFailed>(), hasLength(1));
    expect(fixture.host.postInputs, hasLength(1));
    expect(fixture.host.finalInputs, isEmpty);
    fixture.h.expectNoGeneration();
  });

  test('ordinary cancellation during the page postprocessor adopts no late raw array', () async {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final host = _ArrayHost(hold: release.future);
    final fixture = await _ordinary(host: host);
    final events = ScriptEvents(fixture.h.engine.send(fixture.chatId, 'question'));
    await Future.any([
      host.entered.future,
      events.done.future.then((_) => throw TestFailure('Ended before the page postprocessor.')),
    ]);
    fixture.h.engine.stop(fixture.chatId);
    release.complete();
    await events.done.future;
    expect(events.values.whereType<TavernTurnDone>(), isEmpty);
    expect(events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(host.finalInputs, isEmpty);
    expect(host.requests, isEmpty);
    fixture.h.expectNoGeneration();
  });

  test('background raw cancellation during the postprocessor adopts no late array', () async {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final h = await generationFixture();
    final host = _ArrayHost(hold: release.future);
    h.bridge.attachHost(host);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'cancel-array'));
    final presetId = (await h.engine.importPreset(jsonEncode(_arrayPreset().raw))).preset.id;
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        generationId: 'held-array',
        presetId: presetId,
        orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
      ),
    );
    await generationSignal(generation, host.entered.future);
    expect(h.bridge.stopGenerationById(generation.id), isTrue);
    release.complete();
    expect((await generationFailure(generation)).code, TavernScriptErrorCode.cancelled);
    expect(host.finalInputs, isEmpty);
    expect(host.requests, isEmpty);
    h.expectNoGeneration();
  });
}
