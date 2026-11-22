import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost;

void main() {
  final repaired = <String, Object?>{'role': 'user', 'content': List.filled(10000, 'Q').join()};
  final cost = const EstimatedTokenCounter().countMessage(repaired);

  for (final fits in [false, true]) {
    test('native raw counts Final-repaired mixed messages at the captured budget (fits=$fits)', () async {
      final h = await generationFixture(allowModel: fits);
      final host = _RepairHost(repaired);
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'repaired-raw-budget'));
      final preset = await h.engine.importPreset(jsonEncode(_preset(cost - (fits ? 0 : 1)).raw));
      final response = fits ? h.reply('accepted') : null;
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernScriptRawRequest(
          presetId: preset.preset.id,
          orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
        ),
      );
      if (response == null) {
        expect((await generationFailure(generation)).modelFailure, TavernFailure.contextTooLong);
        expect(host.requests, isEmpty, reason: 'An over-budget repair must not reach request observation.');
        h.expectNoGeneration();
      } else {
        final request = await generationRequest(generation, response);
        expect((await generation.result).text, 'accepted');
        expect(request.body['messages'], [repaired]);
        expect(host.requests, hasLength(1));
      }
      expect(host.postCalls, 1);
      expect(host.finalCalls, 1);
      expect(host.finalInput, ['transient', null]);
    });
  }

  test('unrepaired native raw mixed messages retain the real provider error', () async {
    final h = await generationFixture();
    final host = _RepairHost(null);
    h.bridge.attachHost(host);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'unrepaired-raw-budget'));
    final preset = await h.engine.importPreset(jsonEncode(_preset(cost).raw));
    final response = generationJsonResponse(h, {
      'error': {'message': 'provider requires message objects'},
    }, status: 400);
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        presetId: preset.preset.id,
        orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
      ),
    );
    final request = await generationRequest(generation, response);
    final failure = await generationFailure(generation);
    expect(request.body['messages'], ['transient', null]);
    expect(failure.modelFailure, TavernFailure.invalidParameters);
    expect(failure.message, contains('provider requires message objects'));
    expect(host.postCalls, 1);
    expect(host.finalCalls, 1);
  });

  test('Helper raw retains its source behavior without the native repaired-array budget rule', () async {
    final h = await generationFixture();
    final host = _RepairHost(repaired);
    h.bridge.attachHost(host);
    await h.engine.setPreset(_preset(cost - 1));
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'helper-array-budget'));
    final response = h.reply('accepted');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': [
          {'role': 'user', 'content': 'Q'},
        ],
      }),
    );
    final request = await generationRequest(generation, response);
    expect((await generation.result).text, 'accepted');
    expect(request.body['messages'], [repaired]);
    expect(host.postCalls, 1);
    expect(host.finalCalls, 1);
  });
}

ChatPreset _preset(int budget) => ChatPreset({
  ...scriptPreset().raw,
  'openai_max_context': budget + 1,
  'openai_max_tokens': 1,
  'custom_prompt_post_processing': '',
  'new_chat_prompt': '',
  'send_if_empty': '',
  'extensions': {
    'SPreset': {
      'ChatSquash': {
        'enabled': false,
        'squashed_post_script_enable': true,
        'squashed_post_script': 'synthetic-mixed-array',
      },
      'FinalRequestProcessing': {'enabled': true, 'script': 'synthetic-array-repair'},
    },
  },
});

class _RepairHost extends SPresetHost {
  _RepairHost(Map<String, Object?>? repaired) {
    handler = (request) async {
      final arguments = request.arguments;
      if (request.stage == 'ChatSquash') {
        postCalls++;
        return TavernSPresetEvaluationResult(requestId: request.requestId, value: const ['transient', null]);
      }
      if (request.stage == 'FinalRequestProcessing') {
        finalCalls++;
        final body = (arguments.single! as Map<String, Object?>)['request']! as Map<String, Object?>;
        finalInput = body['messages'];
        if (repaired != null) body['messages'] = [repaired];
        return TavernSPresetEvaluationResult(requestId: request.requestId, isUndefined: true, arguments: arguments);
      }
      return defaultEvaluate(request);
    };
  }

  int postCalls = 0, finalCalls = 0;
  Object? finalInput;
}
