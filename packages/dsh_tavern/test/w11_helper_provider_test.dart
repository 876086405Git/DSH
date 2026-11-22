import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  final fixture = scriptMap(jsonDecode(File('test/fixtures/w11_helper_provider_extraction.json').readAsStringSync()));
  final rows = (fixture['rows']! as List<Object?>).map(scriptMap).toList();
  for (final source in ['openai', 'custom', 'deepseek', 'openrouter']) {
    for (final streaming in [false, true]) {
      test('Helper real response follows fixed provider extraction ($source, stream=$streaming)', () async {
        final h = await generationFixture();
        final context = await h.bridge.openContext(TavernScriptContextSpec(instanceId: 'provider-$source-$streaming'));
        for (final row in rows.where((row) => row['source'] == source && (streaming || row.containsKey('nonstream')))) {
          final input = scriptMap(row['input']);
          final plan = streaming
              ? h.stream()
              : generationJsonResponse(h, {
                  'choices': [
                    {'message': input, 'finish_reason': 'stop'},
                  ],
                });
          final generation = await h.bridge.generateRaw(
            context.id,
            TavernHelperRawRequest.fromJson({
              'user_input': 'Q',
              'ordered_prompts': ['user_input'],
              'should_stream': streaming,
              'should_return_reasoning': true,
              'custom_api': {'source': source, 'apiurl': 'https://provider.invalid/v1'},
            }),
          );
          if (streaming) {
            await generationSignal(generation, plan.listening.future);
            generationSse(
              plan,
              input.containsKey('choices')
                  ? input
                  : {
                      'choices': [
                        {'delta': input},
                      ],
                    },
            );
            plan.finish();
          }
          final result = await generation.result;
          final expected = streaming ? scriptMap(row['streaming']) : {'text': 'T', 'reasoning': row['nonstream']};
          expect(result.text, expected['text'], reason: '$source / ${row['name']}');
          expect(result.reasoning, expected['reasoning'], reason: '$source / ${row['name']}');
          expect(result.toHelperValue(), {
            'content': expected['text'],
            if (expected['reasoning'] != '') 'reasoning': expected['reasoning'],
          });
        }
      });
    }
  }

  test('Helper reuses the current OpenRouter connection for normal and raw generation', () async {
    final h = await generationFixture();
    h.config = TavernModelConfig(
      apiKey: h.config.apiKey,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: h.config.model,
      deepseek: false,
      thinking: false,
    );
    await h.reopen();
    final card = await h.card('Helper');
    final context = await h.context(await h.emptyChat(card), characterId: card);
    for (final raw in [false, true]) {
      h.reply('A');
      final generation = raw
          ? await h.bridge.generateRaw(
              context.id,
              TavernHelperRawRequest.fromJson({
                'user_input': 'Q',
                'ordered_prompts': ['user_input'],
              }),
            )
          : await h.bridge.generate(context.id, TavernHelperGenerateRequest.fromJson({'user_input': 'Q'}));
      expect((await generation.result).text, 'A');
      expect(h.requests.last.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
    }
    expect(h.keyReads, 2);
  });

  test('Helper nonstream string fallbacks use source precedence; structured content fails visibly', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'content-shape'));
    for (final raw in fixture['contentCases']! as List<Object?>) {
      final row = scriptMap(raw);
      generationJsonResponse(h, scriptMap(row['input']));
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          'ordered_prompts': ['user_input'],
        }),
      );
      if (row['resultType'] == 'array') {
        final failure = await generationFailure(generation);
        expect(failure.code, TavernScriptErrorCode.unsupportedCapability);
        expect(failure.fieldPath, 'response.content');
        expect(failure.modelFailure, isNull);
      } else {
        expect((await generation.result).text, row['result'], reason: row['name']! as String);
      }
    }
    expect(h.requests, hasLength(4));
  });

  test('Helper source projection preserves delivered partial text and reasoning when cancelled', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'projected-cancel'));
    final plan = h.stream();
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'generation_id': 'projected-cancel',
        'user_input': 'Q',
        'ordered_prompts': ['user_input'],
        'should_stream': true,
        'custom_api': {'source': 'openrouter', 'apiurl': 'https://provider.invalid/v1'},
      }),
    );
    final events = ScriptEvents(generation.events);
    await generationSignal(generation, plan.listening.future);
    generationSse(plan, {
      'choices': [
        {
          'message': {'content': 'partial', 'reasoning': 'chosen', 'reasoning_content': 'unused'},
        },
      ],
    });
    await events.until((event) => event.text == 'partial');
    expect(await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(generation.id), isTrue);
    plan.finish();
    expect((await generationFailure(generation)).code, TavernScriptErrorCode.cancelled);
    final terminal = await events.until((event) => event.status == TavernScriptGenerationStatus.cancelled);
    expect(terminal.text, 'partial');
    expect(terminal.reasoning, 'chosen');
    expect(h.requests, hasLength(1));
  });
}
