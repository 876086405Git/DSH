import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;

void main() {
  test('Public Helper normal/raw/named paths never freshly evaluate SP EntryConditions', () async {
    final h = await generationFixture();
    final host = _EntryHost();
    h.bridge.attachHost(host);
    await h.engine.setPreset(_conditionalPreset());
    final actor = await h.card('Entry actor');
    final context = await h.context(await h.emptyChat(actor), characterId: actor);
    await h.engine.importPreset(jsonEncode(_conditionalPreset().raw), fileName: 'Named Entry.json');
    for (final path in ['normal', 'raw', 'named']) {
      final wire = await _request(h, context.id, path);
      expect(_visible(wire), isTrue, reason: path);
      expect(wire.body['tools'], hasLength(1), reason: path);
    }
    expect(host.conditions, 0);
  });

  test(
    'Public Helper reads active native decisions, keeps them after private end, and clears them on global stop',
    () async {
      final h = await generationFixture();
      final host = _EntryHost();
      h.bridge.attachHost(host);
      await h.engine.setPreset(_conditionalPreset());
      final actor = await h.card('Concurrent entry actor');
      final chat = await h.emptyChat(actor);
      final context = await h.context(chat, characterId: actor);
      await h.engine.importPreset(jsonEncode(_conditionalPreset().raw), fileName: 'Named Entry.json');
      final nativePlan = h.stream();
      final native = ScriptEvents(h.engine.send(chat, 'native remains active'));
      await Future.any([
        nativePlan.listening.future,
        native.done.future.then((_) => throw TestFailure('Native ended before the active-map test boundary.')),
      ]);
      expect(host.conditions, 1);
      for (final path in ['normal', 'raw', 'named', 'normal']) {
        final wire = await _request(h, context.id, path);
        expect(
          _visible(wire),
          path != 'normal',
          reason: 'Raw and named raw prompts do not consume prompt-order decisions.',
        );
        expect(
          wire.body['tools'] ?? <Object?>[],
          isEmpty,
          reason: 'Both Helper paths still consult active tool decisions.',
        );
        expect(host.conditions, 1, reason: 'Private Helper end does not clear or evaluate the native map.');
      }
      final stopPlan = h.stream();
      final stopping = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'generation_id': 'entry-stop',
          'should_stream': true,
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
        }),
      );
      await generationSignal(stopping, stopPlan.listening.future);
      expect(await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(stopping.id), isTrue);
      stopPlan.finish();
      expect((await generationFailure(stopping)).code, TavernScriptErrorCode.cancelled);
      final stoppedEvent = host.deliveries.singleWhere((event) => event.name == 'GENERATION_STOPPED');
      expect(stoppedEvent.namespace, 'tavern');
      expect(stoppedEvent.args, ['entry-stop']);
      expect(
        host.deliveries
            .where((event) => event.name == 'GENERATION_ENDED')
            .every((event) => event.namespace == 'iframe'),
        isTrue,
      );
      final afterStop = await _request(h, context.id, 'normal');
      expect(_visible(afterStop), isTrue);
      expect(afterStop.body['tools'], hasLength(1));
      expect(host.conditions, 1);
      nativePlan.delta('native survived');
      nativePlan.finish();
      await native.done.future;
      expect(native.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(native.values.whereType<TavernTurnDone>().single.message.text, 'native survived');
      final afterEnd = await _request(h, context.id, 'normal');
      expect(_visible(afterEnd), isTrue);
      expect(afterEnd.body['tools'], hasLength(1));
      expect(host.conditions, 1);
    },
  );
}

Future<ScriptRequest> _request(ScriptFixture h, String contextId, String path) async {
  final plan = h.reply('helper completed');
  final generation = path == 'raw'
      ? await h.bridge.generateRaw(
          contextId,
          TavernHelperRawRequest.fromJson({
            'ordered_prompts': [
              {'role': 'system', 'content': 'conditionally-visible'},
            ],
          }),
        )
      : await h.bridge.generate(
          contextId,
          TavernHelperGenerateRequest.fromJson({'user_input': 'Q', if (path == 'named') 'preset_name': 'Named Entry'}),
        );
  final request = await generationRequest(generation, plan);
  await generation.result;
  return request;
}

bool _visible(ScriptRequest request) => generationMessages(
  request,
).any((message) => (message['content'] as String? ?? '').contains('conditionally-visible'));

ChatPreset _conditionalPreset() {
  final raw = preset(toolExtension(), calling: true).raw;
  raw.addAll({'temperature': 0.4, 'frequency_penalty': 0, 'presence_penalty': 0, 'top_p': 1, 'top_k': 0});
  final entry = (raw['prompts']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
    (entry) => entry['identifier'] == 'fixture-slot',
  );
  entry.addAll({
    'content': 'conditionally-visible',
    'system_prompt': false,
    'spreset_condition_enabled': true,
    'spreset_condition_script': 'synthetic-false',
  });
  return ChatPreset(raw);
}

class _EntryHost extends SPresetHost {
  int conditions = 0;
  @override
  Future<TavernSPresetEvaluationResult> evaluateSPreset(
    TavernSPresetEvaluationRequest request,
    TavernScriptCancellation cancellation,
  ) async {
    if (request.stage != 'EntryCondition') return super.evaluateSPreset(request, cancellation);
    evaluations.add(request);
    conditions++;
    return TavernSPresetEvaluationResult(requestId: request.requestId, value: false);
  }
}
