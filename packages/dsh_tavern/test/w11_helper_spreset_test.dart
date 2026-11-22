import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;

const _tool = <String, Object?>{
  'type': 'function',
  'function': {
    'name': 'explicit_tool',
    'parameters': {'type': 'object'},
  },
};

void main() {
  test('Helper raw carries a mixed ChatSquash array to Final before the actual HTTP request', () async {
    final h = await generationFixture();
    final host = SPresetHost();
    final finalArrays = <Object?>[];
    host.handler = (request) async {
      if (request.stage == 'ChatSquash') {
        return TavernSPresetEvaluationResult(
          requestId: request.requestId,
          value: [
            {'role': 'system', 'content': 'object'},
            null,
            false,
            'A',
          ],
        );
      }
      if (request.stage == 'FinalRequestProcessing') {
        final args = request.arguments;
        final body = scriptMap(scriptMap(args.single)['request']);
        finalArrays.add(body['messages']);
        body['messages'] = [
          {'role': 'user', 'content': 'repaired A'},
        ];
        return TavernSPresetEvaluationResult(requestId: request.requestId, isUndefined: true, arguments: args);
      }
      return host.defaultEvaluate(request);
    };
    h.bridge.attachHost(host);
    final rawPreset = scriptPreset().raw;
    rawPreset['custom_prompt_post_processing'] = 'unknown-no-op';
    rawPreset['extensions'] = {
      'SPreset': {
        'ChatSquash': {
          'enabled': false,
          'squashed_post_script_enable': true,
          'squashed_post_script': 'synthetic-array',
        },
        'FinalRequestProcessing': {'enabled': true, 'script': 'synthetic-repair'},
      },
    };
    await h.engine.setPreset(ChatPreset(rawPreset));
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'helper-array'));
    final plan = h.reply('A');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': [
          {'role': 'user', 'content': 'RAW {{incglobalvar::mustNotRun}}'},
        ],
      }),
    );
    final wire = await generationRequest(generation, plan);
    expect((await generation.result).text, 'A');
    expect(finalArrays, [
      [
        {'role': 'system', 'content': 'object'},
        null,
        false,
        'A',
      ],
    ]);
    expect(wire.body['messages'], [
      {'role': 'user', 'content': 'repaired A'},
    ]);
    expect(wire.body['temperature'], 0.4);
    expect(wire.body['max_tokens'], 73);
    expect(h.engine.globalVariables.containsKey('mustNotRun'), isFalse);
    expect(host.evaluations.where((request) => request.stage == 'ChatSquash'), hasLength(1));
    expect(h.requests, hasLength(1));
  });

  test('Helper normal maps SP messages with the page provider and keeps custom transport routing', () async {
    final h = await generationFixture();
    h.config = TavernModelConfig(
      apiKey: h.config.apiKey,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'google/gemini-source',
      deepseek: false,
      thinking: false,
    );
    await h.reopen();
    final rawPreset = scriptPreset(main: 'MAIN').raw;
    rawPreset['extensions'] = {
      'SPreset': {
        'MessageInjections': {
          'main': {
            'enabled': true,
            'reasoning': 'page reasoning',
            'signature': 'page signature',
            'toolCalls': <Object?>[],
            'toolResults': <Object?>[],
          },
        },
      },
    };
    rawPreset['custom_prompt_post_processing'] = 'none';
    await h.engine.setPreset(ChatPreset(rawPreset));
    final actor = await h.card('Provider actor');
    final context = await h.context(await h.emptyChat(actor), characterId: actor);
    final plan = h.reply('A');
    final generation = await h.bridge.generate(
      context.id,
      TavernHelperGenerateRequest.fromJson({
        'user_input': 'Q',
        'custom_api': {'source': 'openai', 'apiurl': 'https://custom-target.invalid/v1', 'model': 'custom-target'},
      }),
    );
    final wire = await generationRequest(generation, plan);
    await generation.result;
    expect(wire.url.toString(), 'https://custom-target.invalid/v1/chat/completions');
    expect(wire.body['model'], 'custom-target');
    final main = generationMessages(wire).singleWhere((message) => message['content'] == 'MAIN');
    expect(main['role'], 'assistant');
    expect(main['signature'], 'page signature');
    expect(
      main.containsKey('reasoning'),
      isFalse,
      reason: 'The actual OpenAI transport keeps its existing reasoning-field normalization.',
    );
    expect(main.containsKey('reasoning_content'), isFalse);
  });

  test(
    'Helper normal enters MacroNest and MessageInjections while raw leaves both prompt-manager hooks unused',
    () async {
      final h = await generationFixture();
      final rawPreset = scriptPreset(main: '{{incglobalvar::nestedReads}}').raw;
      rawPreset['extensions'] = {
        'SPreset': {
          'MacroNest': true,
          'MessageInjections': {
            'main': {
              'enabled': true,
              'reasoning': '',
              'signature': '',
              'toolCalls': [
                {'id': 'injected_call', 'name': 'look', 'arguments': '{}'},
              ],
              'toolResults': [
                {'toolCallId': 'injected_call', 'content': 'injected-result'},
              ],
            },
          },
        },
      };
      rawPreset['custom_prompt_post_processing'] = 'none';
      await h.engine.setPreset(ChatPreset(rawPreset));
      final actor = await h.card('Hook actor');
      final context = await h.context(await h.emptyChat(actor), characterId: actor);
      final firstReply = h.reply('raw');
      final first = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': '{{incglobalvar::nestedReads}}',
          'ordered_prompts': ['user_input'],
        }),
      );
      final firstWire = await generationRequest(first, firstReply);
      await first.result;
      expect(h.engine.globalVariables['nestedReads'], 1);
      expect(generationMessages(firstWire), [
        {'role': 'user', 'content': '1'},
      ]);
      final normalReply = h.reply('normal');
      final normal = await h.bridge.generate(context.id, TavernHelperGenerateRequest.fromJson({'user_input': 'Q'}));
      final normalWire = await generationRequest(normal, normalReply);
      await normal.result;
      expect(
        h.engine.globalVariables['nestedReads'],
        3,
        reason: 'The first normal preparePrompt primes MacroNest, then performs its actual macro pass.',
      );
      expect(generationMessages(normalWire).any((message) => message.containsKey('tool_calls')), isTrue);
      expect(
        generationMessages(
          normalWire,
        ).any((message) => message['role'] == 'tool' && message['content'] == 'injected-result'),
        isTrue,
      );
    },
  );

  test(
    'Helper custom transport keeps SP provider global while Final sees the actual request source and model',
    () async {
      final h = await generationFixture();
      final host = SPresetHost();
      host.handler = (request) async {
        if (request.stage == 'FinalRequestProcessing' || request.stage == 'ToolCallFormatter') {
          if (request.stage == 'FinalRequestProcessing') {
            return TavernSPresetEvaluationResult(
              requestId: request.requestId,
              isUndefined: true,
              arguments: request.arguments,
            );
          }
          return TavernSPresetEvaluationResult(requestId: request.requestId, value: 'tool text');
        }
        return host.defaultEvaluate(request);
      };
      h.bridge.attachHost(host);
      await h.engine.setPreset(
        preset({
          'FinalRequestProcessing': {'enabled': true, 'script': 'inspect-provider'},
          'OutputPreprocessing': {
            'enabled': true,
            'script': 'validate-only',
            'consumeToolCalls': true,
            'toolCallFormatter': {'enabled': true, 'script': 'inspect-provider'},
          },
        }, stream: false),
      );
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'helper-provider'));
      final response = generationJsonResponse(h, {
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'call_one',
                  'type': 'function',
                  'function': {'name': 'explicit_tool', 'arguments': '{}'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
          'tools': [_tool],
          'custom_api': {
            'apiurl': 'https://router.invalid/v1',
            'source': 'openrouter',
            'model': 'custom-model',
            'key': 'synthetic',
          },
        }),
      );
      final wire = await generationRequest(generation, response);
      expect(wire.body['model'], 'custom-model');
      expect(
        wire.body.containsKey('chat_completion_source'),
        isFalse,
        reason: 'ST bridge metadata is not an extra provider API field.',
      );
      expect((await generation.result).text, 'tool text');
      final finalInput = scriptMap(
        host.evaluations.singleWhere((request) => request.stage == 'FinalRequestProcessing').arguments.single,
      );
      final formatterInput = scriptMap(
        host.evaluations.singleWhere((request) => request.stage == 'ToolCallFormatter').arguments.single,
      );
      expect(finalInput['source'], 'openrouter');
      expect(finalInput['model'], 'custom-model');
      expect(finalInput['provider'], {'adapter': 'openai', 'source': 'custom', 'model': 'p2-script-model'});
      expect(formatterInput['provider'], finalInput['provider']);
    },
  );

  for (final row in [
    (stream: true, consume: false, fail: false),
    (stream: true, consume: true, fail: false),
    (stream: false, consume: false, fail: false),
    (stream: false, consume: true, fail: false),
    (stream: false, consume: true, fail: true),
  ]) {
    test('Helper private response bypasses SP body processor; fetch tool consumption $row', () async {
      final h = await generationFixture();
      final host = SPresetHost();
      host.handler = (request) async {
        if (request.stage == 'ToolCallFormatter') {
          if (row.fail) throw StateError('Synthetic formatter failure');
          final input = scriptMap(request.arguments.single);
          expect(input['channel'], 'choice:0');
          expect(input['stream'], isFalse);
          expect(scriptMap((input['calls']! as List<Object?>).single)['signature'], 'generic-signature');
          return TavernSPresetEvaluationResult(
            requestId: request.requestId,
            value: 'formatted',
            arguments: request.arguments,
          );
        }
        return host.defaultEvaluate(request);
      };
      h.bridge.attachHost(host);
      await h.engine.setPreset(
        preset({
          'FinalRequestProcessing': {'enabled': true, 'script': 'fixture-final'},
          'OutputPreprocessing': {
            'enabled': true,
            'script': 'would-uppercase-body',
            'consumeToolCalls': row.consume,
            'toolCallFormatter': {'enabled': true, 'script': 'fixture-formatter'},
          },
        }, stream: row.stream),
      );
      await h.engine.setSettings({
        'power_user': {'trim_spaces': true, 'auto_fix_generated_markdown': false},
      });
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'helper-sp-output'));
      final message = <String, Object?>{
        'role': 'assistant',
        'content': '  raw  ',
        'reasoning_content': 'reason',
        'tool_calls': [
          {
            'id': 'call_one',
            'type': 'function',
            'signature': 'generic-signature',
            'thoughtSignature': 'camel-signature',
            'function': {'name': 'explicit_tool', 'arguments': '{"text":"argument"}'},
          },
        ],
      };
      final plan = row.stream
          ? h.stream()
          : generationJsonResponse(h, {
              'choices': [
                {'index': 0, 'message': message, 'finish_reason': 'tool_calls'},
              ],
            });
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'should_stream': row.stream,
          'should_return_reasoning': true,
          'tools': [_tool],
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
        }),
      );
      final wire = await generationRequest(generation, plan);
      expect(wire.body['model'], 'final-model');
      if (row.stream) {
        await generationSignal(generation, plan.listening.future);
        generationSse(plan, {
          'choices': [
            {
              'index': 0,
              'delta': {
                ...message,
                'tool_calls': [
                  {...scriptMap((message['tool_calls']! as List<Object?>).single), 'index': 0},
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        });
        plan.finish();
      }
      final result = await generation.result;
      await Future<void>.delayed(Duration.zero);
      final consumed = !row.stream && row.consume && !row.fail;
      expect(result.text, consumed ? '  raw  \nformatted' : '  raw  ');
      expect(result.reasoning, 'reason');
      expect(result.helperMetadata!.toolCalls, consumed ? isEmpty : hasLength(1));
      expect(
        host.evaluations.where((request) => request.stage == 'OutputPreprocessing'),
        isEmpty,
        reason: 'Helper does not use ST global streamingProcessor or MESSAGE_RECEIVED.',
      );
      expect(
        host.evaluations.where((request) => request.stage == 'ToolCallFormatter'),
        !row.stream && row.consume ? hasLength(1) : isEmpty,
      );
      expect(
        host.evaluations.where((request) => request.stage == 'OutputPreprocessing/validate'),
        !row.stream && row.consume ? hasLength(1) : isEmpty,
      );
      if (row.fail) expect(result.hookIssues.any((issue) => issue.stage == 'ToolCallFormatter'), isTrue);
      expect(
        host.deliveries.singleWhere((request) => request.name == 'GENERATION_ENDED').args.first,
        row.stream ? 'raw' : result.text,
      );
      expect(host.actions, 0);
    });
  }

  for (final raw in [false, true]) {
    test('Helper empty tools offers current SP tools, explicit tools replace them (raw=$raw)', () async {
      final h = await generationFixture();
      final host = SPresetHost();
      h.bridge.attachHost(host);
      await h.engine.setPreset(preset(toolExtension(), stream: false, calling: true));
      final character = await h.card('Helper SP actor');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character);
      for (final explicit in [false, true]) {
        final response = generationJsonResponse(h, {
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': 'raw return',
                'tool_calls': [
                  {
                    'id': 'call_one',
                    'type': 'function',
                    'function': {'name': explicit ? 'explicit_tool' : 'fixture_tool', 'arguments': '{}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        });
        final options = <String, Object?>{
          'user_input': 'Q',
          'tools': explicit ? [_tool] : <Object?>[],
          'custom_api': {
            'source': 'custom',
            'custom_include_body': {
              'tools': [_tool],
              'tool_choice': 'none',
            },
          },
          if (raw) 'ordered_prompts': ['user_input'],
        };
        final generation = raw
            ? await h.bridge.generateRaw(context.id, TavernHelperRawRequest.fromJson(options))
            : await h.bridge.generate(context.id, TavernHelperGenerateRequest.fromJson(options));
        final wire = await generationRequest(generation, response);
        final names = (wire.body['tools']! as List<Object?>).map(
          (tool) => scriptMap(scriptMap(tool)['function'])['name'],
        );
        expect(names, [explicit ? 'explicit_tool' : 'fixture_tool']);
        expect(wire.body['tool_choice'], 'auto');
        final result = await generation.result;
        expect(result.helperMetadata!.toolCalls, explicit ? hasLength(1) : isEmpty);
        if (!explicit) expect(result.toHelperValue(), 'raw return');
      }
      expect(host.actions, 0, reason: 'Helper returns calls; it never starts an SP tool action loop.');
    });
  }
}
