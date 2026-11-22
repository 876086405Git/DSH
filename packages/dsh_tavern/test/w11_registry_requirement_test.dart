@TestOn('vm')
library;

import 'dart:mirrors' as mirrors;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;

// This is an attached App host with no evaluator in its page, not an absent
// Dart interface. The real owner host reports missing page/runtime via this
// same exception surface; HTTP encoding and SQLite remain production paths.
class _MissingRuntimeHost extends ScriptHost implements TavernSPresetScriptHost {
  final evaluations = <TavernSPresetEvaluationRequest>[];

  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    evaluations.add(request);
    throw TavernScriptException(
      code: TavernScriptErrorCode.hookFailure,
      operation: 'evaluateSPreset',
      message: 'DshSPresetPageRuntime is unavailable in this page.',
    );
  }

  @override
  Future<void> releaseSPresetSession(String sessionId) async {}
}

void main() {
  for (final (name, bindings) in <(String, Map<String, Object?>?)>[
    ('absent', null),
    ('empty', {}),
    (
      'disabled',
      {
        'fixture-slot': {'enabled': false, 'valid': true, 'code': 'must not evaluate'},
      },
    ),
    (
      'invalid',
      {
        'fixture-slot': {'enabled': true, 'valid': false, 'code': 'must not evaluate'},
      },
    ),
  ]) {
    for (final calling in [false, true]) {
      test('Data-only $name bindings, function calling=$calling require no page registry', () async {
        final h = await generationFixture();
        final host = _MissingRuntimeHost();
        h.bridge.attachHost(host);
        await h.engine.setPreset(
          preset(
            {
              'ForcedPostProcessing': {'enabled': true, 'mode': 'merge_tools'},
              'ToolBindings': ?bindings,
            },
            stream: false,
            calling: calling,
          ),
        );
        final actor = await h.card('Data-only actor');
        final chat = await h.emptyChat(actor);
        h.reply('completed');
        final done = _succeeded(await h.engine.send(chat, 'native input').toList());
        expect(done.message.text, 'completed');
        expect(host.evaluations, isEmpty);
        expect(done.hookIssues, isEmpty);
        expect(h.requests, hasLength(1));
        expect(h.requests.single.body['tools'] ?? const [], isEmpty);
      });
    }
  }

  test('Needed bindings with an attached missing runtime fail visibly before HTTP', () async {
    final h = await generationFixture();
    final host = _MissingRuntimeHost();
    h.bridge.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), stream: false, calling: true));
    final actor = await h.card('Required runtime actor');
    final chat = await h.emptyChat(actor);
    final events = await h.engine.send(chat, 'native input').toList();
    expect(
      events.whereType<TavernTurnFailed>().single.hookIssues.any((issue) => issue.stage == 'ToolBindings'),
      isTrue,
    );
    expect(host.evaluations.map((request) => request.kind), [TavernSPresetEvaluationKind.toolRegistry]);
    h.expectNoGeneration();
  });

  test('Disabled calling retains sync diagnostic without requiring an unavailable refresh', () async {
    final h = await generationFixture();
    final host = _MissingRuntimeHost();
    h.bridge.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), stream: false));
    final actor = await h.card('Disabled calling actor');
    final chat = await h.emptyChat(actor);
    h.reply('completed');
    final done = _succeeded(await h.engine.send(chat, 'native input').toList());
    expect(done.hookIssues.where((issue) => issue.stage == 'ToolBindings'), isNotEmpty);
    expect(host.evaluations.map((request) => request.kind), [TavernSPresetEvaluationKind.toolRegistry]);
    expect(h.requests, hasLength(1));
    expect(h.requests.single.body['tools'] ?? const [], isEmpty);
  });

  test('Disabled calling still performs sync and refresh when the runtime supports them', () async {
    final h = await generationFixture();
    final host = SPresetHost();
    h.bridge.attachHost(host);
    await h.engine.setPreset(preset(toolExtension(), stream: false));
    final actor = await h.card('Available runtime actor');
    final chat = await h.emptyChat(actor);
    h.reply('completed');
    _succeeded(await h.engine.send(chat, 'native input').toList());
    expect(_registryModes(host.evaluations), ['sync', 'refresh']);
    expect(h.requests.single.body['tools'] ?? const [], isEmpty);
  });

  test('Order-filtered empty bindings still synchronize an existing runtime', () async {
    final h = await generationFixture();
    final host = SPresetHost();
    h.bridge.attachHost(host);
    final raw = preset(toolExtension(), stream: false, calling: true).raw;
    final order =
        (raw['prompt_order']! as List).cast<Map<String, Object?>>().singleWhere(
              (entry) => entry['character_id'] == 100001,
            )['order']!
            as List;
    order.cast<Map<String, Object?>>().singleWhere((entry) => entry['identifier'] == 'fixture-slot')['enabled'] = false;
    await h.engine.setPreset(ChatPreset(raw));
    final actor = await h.card('Filtered runtime actor');
    final chat = await h.emptyChat(actor);
    h.reply('completed');
    _succeeded(await h.engine.send(chat, 'native input').toList());
    expect(_registryModes(host.evaluations), ['sync', 'read', 'read', 'refresh']);
    expect((host.evaluations.first.arguments.single! as Map)['bindings'], isEmpty);
    expect(h.requests.single.body['tools'] ?? const [], isEmpty);
  });

  for (final stage in ['FinalRequestProcessing', 'OutputPreprocessing', 'EntryCondition']) {
    test('An enabled $stage still reports its missing JavaScript runtime', () async {
      final h = await generationFixture();
      final host = _MissingRuntimeHost();
      h.bridge.attachHost(host);
      final raw = preset({
        if (stage != 'EntryCondition') stage: {'enabled': true, 'script': 'required fixture'},
      }, stream: false).raw;
      if (stage == 'EntryCondition') {
        (raw['prompts']! as List)
            .cast<Map<String, Object?>>()
            .singleWhere((entry) => entry['identifier'] == 'fixture-slot')
            .addAll({'spreset_condition_enabled': true, 'spreset_condition_script': 'required condition'});
      }
      await h.engine.setPreset(ChatPreset(raw));
      final actor = await h.card('Required hook actor');
      final chat = await h.emptyChat(actor);
      if (stage != 'FinalRequestProcessing') h.reply('completed');
      final events = await h.engine.send(chat, 'native input').toList();
      final issues = stage == 'FinalRequestProcessing'
          ? events.whereType<TavernTurnFailed>().single.hookIssues
          : _succeeded(events).hookIssues;
      expect(issues.where((issue) => issue.stage == stage), isNotEmpty);
      expect(host.evaluations.any((request) => request.kind == TavernSPresetEvaluationKind.toolRegistry), isFalse);
      expect(host.evaluations.any((request) => request.stage.startsWith(stage)), isTrue);
      expect(h.requests, hasLength(stage == 'FinalRequestProcessing' ? 0 : 1));
    });
  }

  for (final spresetData in [false, true]) {
    test(
      'Page reset during pure prompt preparation skips publication and preserves native HTTP ($spresetData)',
      () async {
        final h = await generationFixture();
        final host = SPresetHost();
        h.bridge.attachHost(host);
        final raw = scriptPreset(main: 'PREPARED {{random::left::right}}').raw;
        if (spresetData) {
          raw['extensions'] = {
            'SPreset': {
              'ForcedPostProcessing': {'enabled': true, 'mode': 'merge_tools'},
            },
          };
        }
        await h.engine.setPreset(ChatPreset(raw));
        final actor = await h.card('Reset actor');
        final chat = await h.emptyChat(actor);
        var resets = 0;
        h.onRandom = () {
          if (resets++ == 0) (h.engine as TavernSPresetPageLifecycle).resetSPresetPage(chat);
        };
        h.reply('native completed');
        final done = _succeeded(await h.engine.send(chat, 'native input').toList());
        expect(resets, greaterThan(0));
        expect(done.message.text, 'native completed');
        expect(generationMessages(h.requests.single).map((row) => row['content']).join('|'), contains('PREPARED left'));
        expect(host.requests, isEmpty, reason: 'A stale page observer must not receive the prepared request.');
        final engineMirror = mirrors.reflect(h.engine);
        final library = engineMirror.type.owner! as mirrors.LibraryMirror;
        final snapshots =
            engineMirror.getField(mirrors.MirrorSystem.getSymbol('_spresetPromptManagers', library)).reflectee as Map;
        expect(
          snapshots.containsKey(chat),
          isFalse,
          reason: 'The cleared page must not be repopulated by a stale publisher.',
        );
      },
    );
  }
}

List<String> _registryModes(List<TavernSPresetEvaluationRequest> requests) => [
  for (final request in requests)
    if (request.kind == TavernSPresetEvaluationKind.toolRegistry)
      ((request.arguments.single! as Map)['registryMode'] ?? 'sync') as String,
];

TavernTurnDone _succeeded(List<TavernEvent> events) {
  final failures = events.whereType<TavernTurnFailed>().toList();
  expect(failures, isEmpty, reason: failures.map((failure) => '${failure.kind.name}: ${failure.detail}').join('\n'));
  return events.whereType<TavernTurnDone>().single;
}
