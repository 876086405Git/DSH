import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;
import 'support/stage1_engine_harness.dart';

// The engine, SQLite and HTTP encoder/decoder are real. This controlled host
// models the page adapter's session-keyed opaque state and delayed bridge RPC;
// the companion Node test exercises the actual shipped adapter separately.
class _SessionHost extends SPresetHost {
  _SessionHost({this.holdFirstOutput = false, this.holdFirstOutputRelease = false});

  final bool holdFirstOutput;
  final bool holdFirstOutputRelease;
  final state = <String, int>{};
  final retainedTools = <String>{};
  final firstOutput = Completer<TavernSPresetEvaluationRequest>();
  final releaseFirstOutput = Completer<void>();
  final firstOutputRelease = Completer<void>();
  final releaseFirstCleanup = Completer<void>();
  final releasedSignals = <String, Completer<void>>{};
  String? firstOutputSession;

  Future<void> releasedSession(String id) => releasedSignals.putIfAbsent(id, Completer<void>.new).future;

  void unblock() {
    if (!releaseFirstOutput.isCompleted) releaseFirstOutput.complete();
    if (!releaseFirstCleanup.isCompleted) releaseFirstCleanup.complete();
  }

  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    evaluations.add(request);
    if (request.kind == TavernSPresetEvaluationKind.toolRegistry) {
      final result = await defaultEvaluate(request);
      final registry = result.value! as Map<String, Object?>;
      for (final tool in (registry['tools']! as List<Object?>).cast<Map<String, Object?>>()) {
        final scope = request.toJson()['sessionScope'] ?? request.generationId;
        retainedTools.add('$scope:${tool['sessionId']}');
        (tool['definition']! as Map<String, Object?>)['hasFormatMessage'] = true;
      }
      return TavernSPresetEvaluationResult(requestId: request.requestId, value: registry, arguments: request.arguments);
    }
    if (request.kind == TavernSPresetEvaluationKind.toolAction ||
        request.kind == TavernSPresetEvaluationKind.toolFormatMessage) {
      if (!retainedTools.contains(request.sessionId)) {
        throw StateError('The tool callback did not use its registry session scope.');
      }
      return defaultEvaluate(request);
    }
    if (request.stage != 'OutputPreprocessing') return defaultEvaluate(request);
    final input = request.arguments.single! as Map<String, Object?>;
    final chunk = input['chunk']! as String;
    if (request.reset) state.remove(request.sessionId);
    var output = '';
    if (chunk.isNotEmpty) {
      final count = (state[request.sessionId] ?? 0) + 1;
      state[request.sessionId] = count;
      output = '$count';
      if (!firstOutput.isCompleted) {
        firstOutputSession = request.sessionId;
        firstOutput.complete(request);
        if (holdFirstOutput) await releaseFirstOutput.future;
      }
    }
    return TavernSPresetEvaluationResult(
      requestId: request.requestId,
      value: {'output': output, 'hold': ''},
      arguments: request.arguments,
    );
  }

  @override
  Future<void> releaseSPresetSession(String sessionId) async {
    if (sessionId == firstOutputSession && !firstOutputRelease.isCompleted) {
      firstOutputRelease.complete();
      if (holdFirstOutputRelease) await releaseFirstCleanup.future;
    }
    state.remove(sessionId);
    retainedTools.remove(sessionId);
    released.add(sessionId);
    final signal = releasedSignals.putIfAbsent(sessionId, Completer<void>.new);
    if (!signal.isCompleted) signal.complete();
  }
}

Future<({ScriptFixture h, String contextId, String presetId})> _fixture(_SessionHost host) async {
  final h = await generationFixture();
  addTearDown(host.unblock);
  h.bridge.attachHost(host);
  final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'session-scope'));
  final selected = preset(
    toolExtension(
      extra: {
        'OutputPreprocessing': {'enabled': true, 'script': 'synthetic-session-counter'},
      },
    ),
  );
  final presetId = (await h.engine.importPreset(jsonEncode(selected.raw))).preset.id;
  return (h: h, contextId: context.id, presetId: presetId);
}

Future<({TavernScriptGeneration generation, ScriptResponsePlan plan})> _start(
  ({ScriptFixture h, String contextId, String presetId}) fixture,
) async {
  final plan = fixture.h.stream();
  final generation = await fixture.h.bridge.generateRaw(
    fixture.contextId,
    TavernScriptRawRequest(
      generationId: 'public-id-reused',
      presetId: fixture.presetId,
      stream: true,
      orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
    ),
  );
  await generationRequest(generation, plan);
  await generationSignal(generation, plan.listening.future);
  return (generation: generation, plan: plan);
}

Future<void> _chunk(
  ({TavernScriptGeneration generation, ScriptResponsePlan plan}) active,
  String text,
  String expected,
) async {
  final next = active.generation.events.firstWhere((event) => !event.isSnapshot && event.text.isNotEmpty);
  active.plan.delta(text);
  expect((await generationSignal(active.generation, next)).text, expected);
}

void _expectScopes(_SessionHost host, int count) {
  final scopes = host.evaluations.map((request) => request.toJson()['sessionScope']).toSet();
  expect(scopes, hasLength(count));
  expect(scopes, isNot(contains(null)));
  expect(host.evaluations.map((request) => request.generationId).toSet(), {'public-id-reused'});
  expect(host.evaluations.map((request) => request.requestId).toSet(), hasLength(host.evaluations.length));
  for (final request in host.evaluations) {
    final scope = request.toJson()['sessionScope'];
    expect(request.sessionId, startsWith('$scope:'));
    expect(request.requestId, startsWith('$scope:eval:'));
  }
}

void main() {
  test('cancelled public ID reuse survives old host settlement and late session release', () async {
    final host = _SessionHost(holdFirstOutput: true);
    final fixture = await _fixture(host);
    final old = await _start(fixture);
    old.plan.delta('old');
    final oldCall = await generationSignal(old.generation, host.firstOutput.future);
    expect(fixture.h.bridge.stopGenerationById(old.generation.id), isTrue);
    expect((await generationFailure(old.generation)).code, TavernScriptErrorCode.cancelled);
    old.plan.finish();

    final next = await _start(fixture);
    expect(next.generation.id, old.generation.id);
    await _chunk(next, 'first', '1');
    expect(host.released, isNot(contains(oldCall.sessionId)));
    host.releaseFirstOutput.complete();
    await host.releasedSession(oldCall.sessionId);
    await _chunk(next, 'second', '12');
    next.plan.finish();
    expect((await next.generation.result).text, '12');
    expect(fixture.h.requests, hasLength(2));
    _expectScopes(host, 2);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('successful public ID reuse survives an earlier delayed release call', () async {
    final host = _SessionHost(holdFirstOutputRelease: true);
    final fixture = await _fixture(host);
    final old = await _start(fixture);
    await _chunk(old, 'old', '1');
    old.plan.finish();
    expect((await old.generation.result).text, '1');
    await host.firstOutputRelease.future;

    final next = await _start(fixture);
    await _chunk(next, 'first', '1');
    host.releaseFirstCleanup.complete();
    await host.releasedSession(host.firstOutputSession!);
    await _chunk(next, 'second', '12');
    next.plan.finish();
    expect((await next.generation.result).text, '12');
    _expectScopes(host, 2);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('separate engines sharing one page isolate the same public generation ID', () async {
    final host = _SessionHost();
    final firstFixture = await _fixture(host);
    final secondFixture = await _fixture(host);
    final first = await _start(firstFixture);
    await _chunk(first, 'first engine', '1');
    final firstSession = (await host.firstOutput.future).sessionId;
    final second = await _start(secondFixture);
    await _chunk(second, 'second engine', '1');
    first.plan.finish();
    expect((await first.generation.result).text, '1');
    await host.releasedSession(firstSession);
    await _chunk(second, 'still second', '12');
    second.plan.finish();
    expect((await second.generation.result).text, '12');
    _expectScopes(host, 2);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('ordinary registry, formatter and action use the same private session scope', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final host = _SessionHost();
    h.engine.scripts.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), calling: true));
    final active = await h.start();
    final followup = h.model.prepare();
    await stage1Finish(active.call, reason: 'tool_calls', tools: [Stage1Call(0, 'scope-call', 'fixture_tool', {})]);
    await Stage1Harness.listening(followup, active.events);
    await stage1Finish(followup, content: 'done');
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(host.actions, 1);
    final registries = host.evaluations
        .where((request) => request.kind == TavernSPresetEvaluationKind.toolRegistry)
        .toList();
    expect(
      [for (final registry in registries) (registry.arguments.single! as Map)['registryMode'] ?? 'sync'],
      ['sync', 'read', 'read', 'refresh', 'refresh'],
    );
    final registry = registries.first;
    final scope = registry.toJson()['sessionScope'];
    expect(scope, isNotNull);
    for (final item in registries) {
      expect(item.toJson()['sessionScope'], scope);
      expect(item.generationId, registry.generationId);
    }
    final callbacks = host.evaluations
        .where(
          (request) =>
              request.kind == TavernSPresetEvaluationKind.toolAction ||
              request.kind == TavernSPresetEvaluationKind.toolFormatMessage,
        )
        .toList();
    expect(callbacks, hasLength(2));
    for (final callback in callbacks) {
      expect(callback.sessionId, '$scope:tool:fixture_tool');
      expect(callback.toJson()['sessionScope'], scope);
      expect(callback.generationId, registry.generationId);
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}
