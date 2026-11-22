import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;

void main() {
  test('A nested ordinary legacy preparation preserves the active native Entry map', () async {
    final f = await _fixture(defaultEnabled: false, condition: true);
    final h = f.h, host = f.host;
    final ordinary = (await h.engine.importPreset(jsonEncode(scriptPreset().raw))).preset.id;
    TavernScriptGeneration? nested;
    ScriptResponsePlan? nestedPlan;
    host.onDispatch = (event, _) async {
      if (event.namespace == 'tavern' && event.name == 'GENERATION_STARTED') {
        nestedPlan = h.stream();
        nested = await h.bridge.generate(
          f.context.id,
          TavernScriptGenerateRequest(presetId: ordinary, userInput: 'ordinary background', stream: true),
        );
        await generationSignal(nested!, nestedPlan!.listening.future);
        h.reply('native completed');
      }
      return TavernScriptDispatchAck(eventId: event.eventId);
    };
    final events = await h.engine.send(f.chat, 'native input').toList();
    // Finish the independent background stream before assertion/teardown.
    nestedPlan!.delta('background completed');
    nestedPlan!.finish();
    await nested!.result;
    _succeeded(events);
    expect(host.conditions, 1);
    expect(_visible(h.requests.last), isTrue);
  });

  test('Entry completes before ordinary START and a real nested Helper sees its map', () async {
    final f = await _fixture();
    final h = f.h, host = f.host;
    int? atStart;
    ScriptRequest? nested;
    host.onDispatch = (event, _) async {
      if (event.namespace == 'tavern' && event.name == 'GENERATION_STARTED') {
        atStart = host.conditions;
        nested = await _helper(h, f.context.id);
        h.reply('native completed');
      }
      return TavernScriptDispatchAck(eventId: event.eventId);
    };
    final events = await h.engine.send(f.chat, 'native input').toList();
    _succeeded(events);
    expect(atStart, 1);
    expect(host.conditions, 1, reason: 'Late prepare must not reevaluate or republish early decisions.');
    expect(nested, isNotNull);
    expect(_visible(nested!), isFalse);
    expect(_visible(h.requests.last), isFalse);
    expect(_modes(host), ['sync', 'read', 'read', 'refresh']);
  });

  test('Each Entry condition reads live chat after the preceding real message edit', () async {
    final f = await _fixture(second: true, greeting: 'ORIGINAL HISTORY');
    final h = f.h, host = f.host;
    final original = (await h.engine.path(f.chat)).single;
    final observed = <List<String>>[];
    host.onCondition = (request) async {
      final args = request.arguments;
      final input = args.single! as Map<String, Object?>;
      final chat = (input['chat']! as List<Object?>).cast<Map<String, Object?>>();
      observed.add([for (final item in chat) item['mes']! as String]);
      if (host.conditions == 1) {
        await h.bridge.setChatMessages(f.context.id, [
          TavernScriptMessagePatch(
            ref: TavernScriptMessageRef(chatId: f.chat, nodeId: original.nodeId),
            fields: {'message': 'EDITED BY FIRST CONDITION'},
          ),
        ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
        chat.first['mes'] = 'ARGUMENT COPY ONLY';
      }
      return false;
    };
    h.reply('completed');
    _succeeded(await h.engine.send(f.chat, 'native input').toList());
    expect(host.conditions, 2);
    expect(observed[0], contains('ORIGINAL HISTORY'));
    expect(observed[1], contains('EDITED BY FIRST CONDITION'));
    expect(observed[1], isNot(contains('ARGUMENT COPY ONLY')));
    expect(_text(h.requests.single), contains('EDITED BY FIRST CONDITION'));
    expect(_text(h.requests.single), isNot(contains('ARGUMENT COPY ONLY')));
    expect((await h.engine.path(f.chat)).first.text, 'EDITED BY FIRST CONDITION');
  });

  for (final nestedReady in [false, true]) {
    test('START STOP restores prompt defaults; nested READY=$nestedReady selects current shared tools', () async {
      final f = await _fixture();
      final h = f.h, host = f.host;
      final held = await _heldHelper(h, f.context.id);
      var stopped = false;
      ScriptRequest? nested;
      host.onDispatch = (event, _) async {
        if (event.namespace == 'tavern' && event.name == 'GENERATION_STARTED') {
          stopped = await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(held.generation.id);
          held.plan.finish();
          expect((await generationFailure(held.generation)).code, TavernScriptErrorCode.cancelled);
          if (nestedReady) nested = await _helper(h, f.context.id);
          h.reply('native completed');
        }
        return TavernScriptDispatchAck(eventId: event.eventId);
      };
      _succeeded(await h.engine.send(f.chat, 'native input').toList());
      expect(stopped, isTrue);
      expect(host.conditions, 1);
      final native = h.requests.last;
      expect(_visible(native), isTrue, reason: 'Late prepare reads STOP-cleared map, not its earlier false map.');
      expect(native.body['tools'] ?? const [], nestedReady ? hasLength(1) : isEmpty);
      if (nestedReady) expect(nested!.body['tools'], hasLength(1));
      expect(_modes(host), ['sync', 'read', 'read', 'refresh']);
      // The refresh really appears after wire selection in the request trace.
      final next = await _helper(h, f.context.id);
      expect(next.body['tools'], hasLength(1));
      expect(host.conditions, 1);
    });
  }

  test('Wire tools reread the map after ChatSquash without changing admitted prompts', () async {
    final f = await _fixture(
      defaultEnabled: false,
      condition: true,
      extra: {
        'ChatSquash': {'squashed_post_script_enable': true, 'squashed_post_script': 'synthetic identity'},
      },
    );
    final h = f.h, host = f.host;
    final held = await _heldHelper(h, f.context.id);
    var stoppedAtSquash = false;
    host.handler = (request) async {
      if (request.stage == 'ChatSquash' && request.generationId == host.nativeGenerationId) {
        stoppedAtSquash = await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(
          held.generation.id,
        );
        held.plan.finish();
        await generationFailure(held.generation);
      }
      return host.defaultEvaluate(request);
    };
    h.reply('native completed');
    _succeeded(await h.engine.send(f.chat, 'native input').toList());
    expect(stoppedAtSquash, isTrue);
    final native = h.requests.last;
    expect(_visible(native), isTrue, reason: 'Prompt admission happened while the condition was true.');
    expect(native.body['tools'] ?? const [], isEmpty, reason: 'Wire selection follows the STOP in ChatSquash.');
    expect(_modes(host), ['sync', 'read', 'read', 'refresh']);
  });

  for (final responseCase in ['legacy capability', 'missing read ack']) {
    test('A $responseCase fails visibly before HTTP without a sync fallback', () async {
      final f = await _fixture();
      final h = f.h, host = f.host;
      host.handler = (request) async {
        final result = await host.defaultEvaluate(request);
        if (request.kind != TavernSPresetEvaluationKind.toolRegistry) return result;
        final value = result.value! as Map<String, Object?>;
        if (responseCase == 'legacy capability') {
          value.remove('registryModes');
        } else if ((request.arguments.single! as Map)['registryMode'] == 'read') {
          value.remove('registryMode');
        }
        return TavernSPresetEvaluationResult(requestId: request.requestId, value: value);
      };
      final events = await h.engine.send(f.chat, 'native input').toList();
      final failure = events.whereType<TavernTurnFailed>().single;
      final issues = failure.hookIssues.where((issue) => issue.stage == 'ToolBindings');
      expect(issues, isNotEmpty);
      expect(
        issues.any(
          (issue) =>
              issue.message.contains(responseCase == 'legacy capability' ? 'not advertised' : 'did not acknowledge'),
        ),
        isTrue,
      );
      expect(_modes(host), responseCase == 'legacy capability' ? ['sync'] : ['sync', 'read']);
      h.expectNoGeneration();
    });
  }

  test('A data-only preset without a JavaScript host keeps its native path', () async {
    final h = await generationFixture();
    await h.engine.setPreset(
      preset({
        'ChatSquash': {'enabled': true},
      }, stream: false),
    );
    final actor = await h.card('No page host');
    final chat = await h.emptyChat(actor);
    h.reply('completed');
    final events = await h.engine.send(chat, 'native input').toList();
    _succeeded(events);
    expect(h.requests, hasLength(1));
    expect(events.whereType<TavernTurnDone>().single.hookIssues, isEmpty);
  });

  test('A plain native START host replacement keeps its existing issue-only behavior', () async {
    final h = await generationFixture();
    final actor = await h.card('Plain native actor');
    final chat = await h.emptyChat(actor);
    await h.context(chat, characterId: actor);
    final host = ScriptHost();
    host.onDispatch = (event, _) async {
      if (event.namespace == 'tavern' && event.name == 'GENERATION_STARTED') h.bridge.attachHost(null);
      return TavernScriptDispatchAck(eventId: event.eventId);
    };
    h.bridge.attachHost(host);
    h.reply('plain native survived');
    final events = await h.engine.send(chat, 'native input').toList();
    _succeeded(events);
    expect(events.whereType<TavernTurnDone>().single.message.text, 'plain native survived');
    expect(events.whereType<TavernTurnDone>().single.hookIssues, isNotEmpty);
    expect(h.requests, hasLength(1));
  });

  for (final invalidation in ['cancel', 'page reset', 'host replace']) {
    test('Early Entry $invalidation refuses late results before ordinary START', () async {
      final f = await _fixture();
      final h = f.h, host = f.host;
      final entered = Completer<void>(), release = Completer<void>();
      final replacement = SPresetHost();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      host.onCondition = (_) async {
        entered.complete();
        await release.future;
        return false;
      };
      final native = ScriptEvents(h.engine.send(f.chat, 'native input'));
      await Future.any([
        entered.future,
        native.done.future.then((_) => throw TestFailure('Native ended before the Entry barrier.')),
      ]);
      if (invalidation == 'cancel') {
        h.engine.stop(f.chat);
      } else if (invalidation == 'page reset') {
        (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(f.chat);
      } else {
        h.bridge.attachHost(replacement);
      }
      release.complete();
      await native.done.future;
      expect(native.values.whereType<TavernTurnFailed>(), hasLength(1));
      expect(
        host.deliveries.where((event) => event.namespace == 'tavern' && event.name == 'GENERATION_STARTED'),
        isEmpty,
      );
      expect(
        replacement.deliveries.where((event) => event.namespace == 'tavern' && event.name == 'GENERATION_STARTED'),
        isEmpty,
      );
      h.expectNoGeneration();
    });
  }
}

class _PhaseHost extends SPresetHost {
  _PhaseHost(this.condition);
  final bool condition;
  int conditions = 0;
  String? nativeGenerationId;
  Future<bool> Function(TavernSPresetEvaluationRequest)? onCondition;

  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    if (request.stage != 'EntryCondition') return super.evaluateSPreset(request, cancellation);
    evaluations.add(request);
    conditions++;
    nativeGenerationId = request.generationId;
    return TavernSPresetEvaluationResult(
      requestId: request.requestId,
      value: await onCondition?.call(request) ?? condition,
    );
  }
}

Future<({ScriptFixture h, _PhaseHost host, String chat, TavernScriptContext context})> _fixture({
  bool defaultEnabled = true,
  bool condition = false,
  bool second = false,
  String greeting = '',
  Map<String, Object?> extra = const {},
}) async {
  final h = await generationFixture();
  final host = _PhaseHost(condition);
  h.bridge.attachHost(host);
  final raw = preset(toolExtension(extra: extra), stream: false, calling: true).raw;
  raw.addAll({'temperature': 0.4, 'frequency_penalty': 0, 'presence_penalty': 0, 'top_p': 1, 'top_k': 0});
  final prompts = (raw['prompts']! as List<Object?>).cast<Map<String, Object?>>();
  prompts.singleWhere((entry) => entry['identifier'] == 'fixture-slot').addAll({
    'content': 'CONDITIONALLY VISIBLE',
    'system_prompt': false,
    'spreset_condition_enabled': true,
    'spreset_condition_script': 'synthetic condition',
  });
  final group = (raw['prompt_order']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
    (entry) => entry['character_id'] == 100001,
  );
  final order = group['order']! as List<Object?>;
  order.cast<Map<String, Object?>>().singleWhere((entry) => entry['identifier'] == 'fixture-slot')['enabled'] =
      defaultEnabled;
  if (second) {
    prompts.add({
      'identifier': 'second-condition',
      'role': 'system',
      'content': 'SECOND',
      'injection_position': 0,
      'spreset_condition_enabled': true,
      'spreset_condition_script': 'second condition',
    });
    order.add({'identifier': 'second-condition', 'enabled': true});
  }
  await h.engine.setPreset(ChatPreset(raw));
  final actor = await h.card('Phase actor', greeting: greeting);
  final chat = greeting.isEmpty ? await h.emptyChat(actor) : await h.engine.createChat(actor);
  final context = await h.context(chat, characterId: actor);
  return (h: h, host: host, chat: chat, context: context);
}

Future<ScriptRequest> _helper(ScriptFixture h, String contextId) async {
  final plan = h.reply('helper completed');
  final generation = await h.bridge.generate(
    contextId,
    TavernHelperGenerateRequest.fromJson({'user_input': 'helper input'}),
  );
  final request = await generationRequest(generation, plan);
  await generation.result;
  return request;
}

Future<({TavernScriptGeneration generation, ScriptResponsePlan plan})> _heldHelper(
  ScriptFixture h,
  String contextId,
) async {
  final plan = h.stream();
  final generation = await h.bridge.generateRaw(
    contextId,
    TavernHelperRawRequest.fromJson({
      'should_stream': true,
      'ordered_prompts': [
        {'role': 'user', 'content': 'held helper'},
      ],
    }),
  );
  await generationSignal(generation, plan.listening.future);
  return (generation: generation, plan: plan);
}

List<String> _modes(_PhaseHost host) => [
  for (final request in host.evaluations)
    if (request.kind == TavernSPresetEvaluationKind.toolRegistry && request.generationId == host.nativeGenerationId)
      ((request.arguments.single! as Map)['registryMode'] ?? 'sync') as String,
];
String _text(ScriptRequest request) => generationMessages(request).map((row) => row['content']).join('|');
bool _visible(ScriptRequest request) => _text(request).contains('CONDITIONALLY VISIBLE');
void _succeeded(List<TavernEvent> events) {
  final failures = events.whereType<TavernTurnFailed>().toList();
  expect(failures, isEmpty, reason: failures.map((failure) => '${failure.kind.name}: ${failure.detail}').join('\n'));
  expect(events.whereType<TavernTurnDone>(), hasLength(1));
}
