import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/st-postprocessing.json').readAsStringSync()) as Map<String, Object?>;
  final names = fixture['names']! as Map<String, Object?>;
  const counter = EstimatedTokenCounter();
  test('owner correction preserves later nonempty assistant tool calls in tools modes', () {
    Map<String, Object?> call(String id) => {
      'id': id,
      'type': 'function',
      'function': {'name': 'fixture', 'arguments': '{}'},
      'thought_signature': 'signature-$id',
    };
    final input = [
      {'role': 'assistant', 'content': 'before'},
      {
        'role': 'assistant',
        'content': 'call one',
        'tool_calls': [call('one')],
      },
      {
        'role': 'assistant',
        'content': 'call two',
        'tool_calls': [call('two')],
      },
      {'role': 'tool', 'tool_call_id': 'one', 'content': 'result one'},
      {'role': 'tool', 'tool_call_id': 'two', 'content': 'result two'},
    ];
    final before = jsonEncode(input);
    for (final mode in ['merge_tools', 'semi_tools', 'strict_tools']) {
      final result = postProcessPrompt(
        [
          for (var i = 0; i < input.length; i++)
            PromptSegment(id: '$i', message: input[i], sources: const [], tokens: 0),
        ],
        mode,
        userName: 'User',
        characterName: 'Character',
        counter: counter,
      );
      final calls = [for (final segment in result) ...((segment.message['tool_calls'] as List?) ?? [])];
      expect(calls, [call('one'), call('two')], reason: mode);
      expect(
        result.where((segment) => segment.message['role'] == 'tool').map((segment) => segment.message).toList(),
        input.sublist(3),
      );
    }
    expect(jsonEncode(input), before);
  });

  test('owner correction restores a media token inside a retained name prefix', () {
    const media = {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,AA=='},
    };
    for (final row in [
      (role: 'assistant', name: 'Alice', prefix: 'Alice: '),
      (role: 'system', name: 'example_assistant', prefix: 'Character: '),
    ]) {
      final input = {
        'role': row.role,
        'name': row.name,
        'content': [media],
      };
      final result = postProcessPrompt(
        [PromptSegment(id: 'image', message: input, sources: const [], tokens: 0)],
        'merge',
        userName: 'User',
        characterName: 'Character',
        counter: counter,
      );
      expect(result.single.message['content'], [
        {'type': 'text', 'text': row.prefix},
        media,
      ]);
      expect(input['content'], [media]);
    }
  });

  test('all recorded ST 1.19.0 conversion modes match real source output', () {
    for (final item in (fixture['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
      final messages = (item['messages']! as List<Object?>).cast<Map<String, Object?>>();
      final before = jsonEncode(messages);
      final segments = [
        for (var i = 0; i < messages.length; i++)
          PromptSegment(
            id: '$i',
            message: messages[i],
            sources: [PromptSource('test', '$i')],
            collectionId: 'chatHistory',
            tokens: counter.countMessage(messages[i]),
          ),
      ];
      List<PromptSegment> convert() => postProcessPrompt(
        segments,
        item['mode']! as String,
        userName: names['userName']! as String,
        characterName: names['charName']! as String,
        groupNames: (names['groupNames']! as List<Object?>).cast<String>(),
        counter: counter,
      );
      if (item.containsKey('expectedError')) {
        expect(item['expectedError'], 'TypeError');
        expect(convert, throwsA(isA<TypeError>()), reason: item['id']! as String);
        continue;
      }
      final actual = convert();
      expect(actual.map((item) => item.message).toList(), item['expected'], reason: item['id']! as String);
      expect(jsonEncode(messages), before, reason: 'converter must not mutate prompt snapshots');
    }
  });

  test('DeepSeek preserves injected reasoning and supports multimodal conversion', () {
    final result = postProcessDeepSeek(
      [
        PromptSegment(
          id: 'tool',
          message: const {
            'role': 'assistant',
            'content': '',
            'reasoning_content': 'injected',
            'tool_calls': [
              {
                'id': 'call',
                'type': 'function',
                'function': {'name': 'f', 'arguments': '{}'},
              },
            ],
          },
          sources: const [],
          tokens: 0,
          collectionId: 'chatHistory',
        ),
        PromptSegment(
          id: 'result',
          message: const {'role': 'tool', 'content': 'ok', 'tool_call_id': 'call'},
          sources: const [],
          tokens: 0,
        ),
        PromptSegment(
          id: 'image',
          message: const {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'synthetic'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,AA=='},
              },
            ],
          },
          sources: const [],
          tokens: 0,
        ),
      ],
      userName: 'User',
      characterName: 'Character',
      counter: counter,
    );
    expect(result.first.message['reasoning_content'], 'injected');
    expect(result.first.collectionId, 'chatHistory');
    expect((result.last.message['content']! as List<Object?>).last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,AA=='},
    });
  });

  test('async reprocessing preserves admission and never replays macro or stop effects', () {
    var calls = 0;
    final input = PromptInput(
      preset: ChatPreset({
        'prompts': [
          {'identifier': 'custom', 'role': 'system', 'content': 'TICK', 'system_prompt': false},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'custom', 'enabled': true},
            ],
          },
        ],
        'custom_prompt_post_processing': 'strict',
      }),
      card: const {'name': 'Character'},
      history: const [],
      model: 'test',
      deepseek: false,
      stops: const ['TICK'],
      expansion: (text, _) => text == 'TICK' ? 'value${++calls}' : text,
    );
    final before = const PromptAssembler().assemble(input);
    final effects = calls;
    final after = reprocessPromptAssembly(before, before.beforePostProcessing, input);
    expect(calls, effects);
    expect(after.body, before.body);
    expect(after.remainingBudget, before.remainingBudget);
    expect(after.excluded.map((item) => item.toJson()).toList(), before.excluded.map((item) => item.toJson()).toList());
  });

  test('generic conversion keeps an enhanced reasoning tail separate before DeepSeek conversion', () {
    final result = const PromptAssembler().assemble(
      PromptInput(
        preset: ChatPreset({
          'prompts': [
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'chatHistory', 'enabled': true},
              ],
            },
          ],
          'custom_prompt_post_processing': 'merge_tools',
          'show_thoughts': true,
          'assistant_prefill': 'NEW',
          'new_chat_prompt': '',
          'extensions': {
            'dshgo': {
              'prefill': {'enabled': true, 'target': 'reasoning'},
            },
          },
        }),
        card: const {'name': 'Character'},
        history: const [PromptHistoryMessage(id: 'previous', role: 'assistant', content: 'OLD')],
        model: 'deepseek-test',
      ),
    );
    expect(result.afterPostProcessing.map((item) => item.message).toList(), [
      {'role': 'assistant', 'content': 'OLD'},
      {'role': 'assistant', 'content': '', 'reasoning_content': 'NEW', 'prefix': true},
    ]);
  });

  test('reasoning projection follows the active provider without selecting saved connection fields', () {
    Map<String, Object?> body(String source, String model, Object? effort, {bool show = true}) =>
        const PromptAssembler()
            .assemble(
              PromptInput(
                preset: ChatPreset({
                  'reasoning_effort': effort,
                  'show_thoughts': show,
                  'chat_completion_source': 'deepseek',
                }),
                card: const {},
                history: const [],
                model: model,
                deepseek: false,
                chatCompletionSource: source,
              ),
            )
            .body;
    expect(body('openai', 'gpt-5', 'min')['reasoning_effort'], 'minimal');
    expect(body('openai', 'gpt-5.4', 'min')['reasoning_effort'], 'none');
    expect(body('openai', 'gpt-5.6', 'max')['reasoning_effort'], 'xhigh');
    expect(body('custom', 'koboldcpp/local', 'max')['reasoning_effort'], 'xhigh');
    expect(body('openai', 'unlisted', 'high').containsKey('reasoning_effort'), isFalse);
    expect(body('openrouter', 'model', 'min', show: false)['reasoning'], {'exclude': true, 'effort': 'none'});
    expect(body('openrouter', 'model', 'auto')['reasoning'], {'exclude': false});
    expect(body('openai', 'gpt-5', 'auto').containsKey('reasoning_effort'), isFalse);
    expect(body('azure_openai', 'gpt-5.3-chat-latest', 'auto')['reasoning_effort'], 'medium');
    expect(body('openai', 'gpt-5.3-chat-latest', 'auto').containsKey('reasoning_effort'), isFalse);
    expect(body('azure_openai', 'gpt-5', 'auto').containsKey('reasoning_effort'), isFalse);
    expect(body('azure_openai', 'gpt-5', null).containsKey('reasoning_effort'), isTrue);
    expect(body('azure_openai', 'gpt-5', '')['reasoning_effort'], '');
    expect(body('azure_openai', 'gpt-5', false)['reasoning_effort'], isFalse);
    expect(body('azure_openai', 'unlisted', 'high').containsKey('reasoning_effort'), isFalse);
  });

  test('SPreset nested macros run in order and structured empty prompts survive conversion', () {
    final context = MacroContext(localVariables: {'inner': 'nested'});
    final input = PromptInput(
      preset: ChatPreset({
        'prompts': [
          {
            'identifier': 'set',
            'role': 'system',
            'system_prompt': false,
            'content': '{{setvar::outer::{{getvar::inner}}}}',
          },
          {'identifier': 'get', 'role': 'system', 'system_prompt': false, 'content': '{{getvar::outer}}'},
          {'identifier': 'structured', 'role': 'system', 'system_prompt': false, 'content': ''},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              for (final id in ['set', 'get', 'structured']) {'identifier': id, 'enabled': true},
            ],
          },
        ],
        'squash_system_messages': true,
        'extensions': {
          'SPreset': {
            'MacroNest': true,
            'MessageInjections': {
              'structured': {
                'enabled': true,
                'reasoning': 'injected',
                'signature': '',
                'toolCalls': [],
                'toolResults': [],
              },
            },
          },
        },
      }),
      card: const {},
      history: const [],
      model: 'test',
      expansion: (text, _) => const MacroEngine().expand(text, context),
    );
    final result = const PromptAssembler().assemble(input);
    expect(result.beforePostProcessing.map((item) => item.message).toList(), [
      {'role': 'system', 'content': 'nested'},
      {'role': 'assistant', 'content': '', 'reasoning_content': 'injected'},
    ]);
    expect(result.afterPostProcessing.last.message['reasoning_content'], 'injected');
    expect(result.excluded.where((item) => item.id.startsWith('SPreset.')), isEmpty);
  });

  test('MacroNest constructor discovery has exactly one extra expansion per runtime', () {
    final runtime = SPresetMacroNestRuntime();
    final context = MacroContext(localVariables: {'x': 0});
    String run(bool enabled, String text) {
      final result = const PromptAssembler().assemble(
        PromptInput(
          preset: ChatPreset({
            'prompts': [
              {'identifier': 'custom', 'role': 'system', 'system_prompt': false, 'content': text},
            ],
            'prompt_order': [
              {
                'character_id': 100001,
                'order': [
                  {'identifier': 'custom', 'enabled': true},
                ],
              },
            ],
            'extensions': {
              'SPreset': {'MacroNest': enabled},
            },
          }),
          card: const {},
          history: const [],
          model: 'test',
          deepseek: false,
          macroNestRuntime: runtime,
          expansion: (value, _) => const MacroEngine().expand(value, context),
        ),
      );
      return result.beforePostProcessing.single.message['content']! as String;
    }

    expect(run(true, '{{incvar::x}}'), '2');
    expect(run(true, '{{incvar::x}}'), '3');
    expect(run(false, '{{incvar::x}}'), '4');
    expect(run(true, '{{incvar::x}}'), '5');
  });
}
