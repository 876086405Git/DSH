import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('Helper raw control slots ignore case while other built-in names remain exact', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': ''}));
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'slot-case'));
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'user_input': 'Q',
        'ordered_prompts': [
          'USER_INPUT',
          'CHAT_HISTORY',
          'DIALOGUE_EXAMPLES',
          'SCENARIO',
          {'role': 'system', 'content': 'TAIL'},
        ],
        'overrides': {
          'scenario': 'UNREAD-UPPERCASE-SOURCE',
          'dialogue_examples': '<START>\nUser: EXAMPLE',
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              {'role': 'assistant', 'content': 'HISTORY'},
            ],
          },
        },
      }),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    final messages = generationMessages(wire);
    expect(messages.first['content'], 'Q');
    expect(messages[1]['content'], 'HISTORY');
    expect(messages.any((message) => (message['content']! as String).contains('EXAMPLE')), isTrue);
    expect(messages.last['content'], 'TAIL');
    expect(messages.any((message) => message['content'] == 'UNREAD-UPPERCASE-SOURCE'), isFalse);
  });

  test('Helper override history ignores max zero and bypasses stored history regex', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'new_chat_prompt': ''}));
    await h.engine.setSettings({
      'globalRegexScripts': [_regex('tail', 'TAIL', 'FILTERED', 2, promptOnly: true, maxDepth: 0)],
    });
    final card = await h.card('Helper');
    final context = await h.context(await h.emptyChat(card), characterId: card);
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'max_chat_history': 0,
        'ordered_prompts': ['chat_history'],
        'overrides': {
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              {'role': 'user', 'content': 'A'},
              {'role': 'assistant', 'content': 'TAIL'},
            ],
          },
        },
      }),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire).map((message) => message['content']), ['A', 'TAIL']);
  });

  test('Helper input skips writeback and stored history keeps full pre-truncation regex depths', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'new_chat_prompt': ''}));
    await h.engine.setSettings({
      'globalRegexScripts': [
        _regex('writeback', 'X', 'WRONG', 1),
        _regex('tail', 'TAIL', 'LAST', 2, promptOnly: true, maxDepth: 0),
      ],
    });
    final card = await h.card('Helper');
    final context = await h.context(await h.emptyChat(card), characterId: card);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'OLD'),
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'TAIL'),
    ]);
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'user_input': 'X',
        'max_chat_history': 1,
        'ordered_prompts': ['chat_history', 'user_input'],
        'overrides': {
          'chat_history': {'with_depth_entries': false},
        },
      }),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire).map((message) => message['content']), ['LAST', 'X']);
  });

  test('Helper raw appends omitted input and consumes current sampling and empty input replacement', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'send_if_empty': '  FALLBACK  '}));
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'unscoped-helper'));
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': [
          {'role': 'system', 'content': '{{incglobalvar::literal}}'},
        ],
      }),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire), [
      {'role': 'system', 'content': '{{incglobalvar::literal}}'},
      {'role': 'user', 'content': 'FALLBACK'},
    ]);
    expect(wire.body['temperature'], 0.4);
    expect(wire.body['max_tokens'], 73);
    expect(h.engine.globalVariables.containsKey('literal'), isFalse);
  });

  test('Helper stop registry spans contexts, includes silent, and does not cancel native generation', () async {
    final h = await generationFixture();
    final a = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'page-a'));
    final b = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'page-b'));
    final control = h.bridge as TavernHelperGenerationControl;
    final states = <TavernHelperGenerationControlState>[];
    final subscription = control.watchHelperGenerations().listen(states.add);
    addTearDown(subscription.cancel);
    final nativePlan = h.stream();
    final native = await h.bridge.generateRaw(
      a.id,
      TavernScriptRawRequest(
        generationId: 'native',
        stream: true,
        orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'native')],
      ),
    );
    await generationSignal(native, nativePlan.listening.future);
    final normalPlan = h.stream();
    final normal = await h.bridge.generateRaw(a.id, _raw('normal'));
    await generationSignal(normal, normalPlan.listening.future);
    final silentPlan = h.stream();
    final silent = await h.bridge.generateRaw(b.id, _raw('silent', silent: true));
    await generationSignal(silent, silentPlan.listening.future);
    expect(control.helperGenerationState.activeIds, ['normal', 'silent']);
    expect(control.helperGenerationState.blocksMainGeneration, isTrue);
    expect(await control.stopHelperGenerationById('native'), isFalse);
    expect(await control.stopNonSilentHelperGenerations(), 1);
    expect((await generationFailure(normal)).code, TavernScriptErrorCode.cancelled);
    expect(control.helperGenerationState.activeIds, ['silent']);
    expect(control.helperGenerationState.blocksMainGeneration, isFalse);
    expect(await control.stopAllHelperGenerations(), isTrue);
    expect((await generationFailure(silent)).code, TavernScriptErrorCode.cancelled);
    expect(await control.stopAllHelperGenerations(), isTrue);
    nativePlan.delta('native survived');
    nativePlan.finish();
    expect((await native.result).text, 'native survived');
    await Future<void>.delayed(Duration.zero);
    expect(states.any((state) => state.nonSilentIds.contains('normal')), isTrue);
    expect(states.last.activeIds, isEmpty);
  });

  test('Helper named preset resolves its name, prepares prompts before input, and keeps current regex', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': ''}));
    await h.engine.setSettings({
      'globalRegexScripts': [_regex('current', 'X', 'CURRENT', 1, promptOnly: true)],
    });
    final imported = await h.engine.importPreset(
      jsonEncode({
        'openai_max_context': 2000,
        'openai_max_tokens': 11,
        'temperature': 3,
        'frequency_penalty': -7,
        'presence_penalty': 7,
        'top_p': 4,
        'top_k': 200,
        'prompts': [
          {'identifier': 'named', 'system_prompt': false, 'role': 'system', 'content': 'N{{incglobalvar::phase}}'},
          {
            'identifier': 'depth',
            'system_prompt': false,
            'role': 'system',
            'content': 'D{{incglobalvar::phase}}',
            'injection_position': 1,
            'injection_depth': 0,
            'injection_order': 50,
          },
          {'identifier': 'chatHistory', 'system_prompt': true, 'marker': true, 'role': 'system'},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'named', 'enabled': true},
              {'identifier': 'depth', 'enabled': true},
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
        ],
        'extensions': {
          'regex_scripts': [_regex('wrong-preset', 'X', 'WRONG', 1, promptOnly: true)],
        },
      }),
      fileName: 'Named Demo.json',
    );
    expect(imported.preset.name, 'Named Demo');
    expect(imported.preset.id, isNot(imported.preset.name));
    final card = await h.card('Helper');
    final context = await h.context(await h.emptyChat(card), characterId: card);
    final response = h.reply('done');
    final generation = await h.bridge.generate(
      context.id,
      TavernHelperGenerateRequest.fromJson({
        'preset_name': 'Named Demo',
        'user_input': 'X{{getglobalvar::phase}}',
        'custom_api': {'temperature': 0.15, 'max_tokens': 999},
        'overrides': {
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              {'role': 'user', 'content': 'H'},
            ],
          },
        },
      }),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire).map((message) => message['content']), ['N1', 'H', 'CURRENT2', 'D2']);
    expect(wire.body['temperature'], 2);
    expect(wire.body['max_tokens'], 11);
    expect(wire.body['frequency_penalty'], -2);
    expect(wire.body['presence_penalty'], 2);
    expect(
      wire.body.containsKey('top_p'),
      isFalse,
      reason: 'The named value clamps to Helper default 1, which is removed.',
    );
    expect(wire.body['top_k'], 100);
    expect(h.engine.globalVariables['phase'], 2);
    final currentResponse = h.reply('current');
    final current = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': [
          {'role': 'user', 'content': 'Q'},
        ],
      }),
    );
    final currentWire = await generationRequest(current, currentResponse);
    await current.result;
    expect(currentWire.body['temperature'], 0.4);
    expect(currentWire.body['max_tokens'], 73);
  });

  test('Helper raw budget charges a whole collection after independent affordability checks', () async {
    final h = await generationFixture();
    await h.engine.setPreset(
      ChatPreset({
        ...scriptPreset().raw,
        'openai_max_context': 14,
        'openai_max_tokens': 1,
        'new_chat_prompt': '',
        'send_if_empty': '',
      }),
    );
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'budget-helper'));
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': ['chat_history'],
        'overrides': {
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              {'role': 'assistant', 'content': 'X'},
              {'role': 'assistant', 'content': 'Y'},
            ],
          },
        },
      }),
    );
    const counter = EstimatedTokenCounter();
    expect(counter.countMessage({'role': 'assistant', 'content': 'X'}), 6);
    final failure = await generationFailure(generation);
    expect(failure.modelFailure, TavernFailure.contextTooLong);
    expect(
      h.requests,
      isEmpty,
      reason: 'Each 6-token row fits the same 10-token remainder, but their 12-token collection fails.',
    );
  });

  test('Helper raw budget stops on the first unaffordable old row and does not skip to newer rows', () async {
    final h = await generationFixture();
    await h.engine.setPreset(
      ChatPreset({
        ...scriptPreset().raw,
        'openai_max_context': 14,
        'openai_max_tokens': 1,
        'new_chat_prompt': 'N',
        'send_if_empty': '',
      }),
    );
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'budget-break-helper'));
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'ordered_prompts': ['chat_history'],
        'overrides': {
          'chat_history': {
            'with_depth_entries': false,
            'prompts': [
              {'role': 'assistant', 'content': 'An old message that does not fit the remaining five tokens.'},
              {'role': 'user', 'content': 'a'},
            ],
          },
        },
      }),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire).map((message) => message['content']), ['N']);
  });

  test(
    'Helper retains automatic_trigger and unknown configuration while consuming only the fixed projection',
    () async {
      final h = await generationFixture();
      await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': ''}));
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'unread-options-helper'));
      final request = TavernHelperRawRequest.fromJson({
        'automatic_trigger': true,
        'future_option': {'nested': 1},
        'user_input': 'Q',
        'ordered_prompts': ['unrecognized-but-unread', 'chat_history', 'user_input'],
        'overrides': {
          'unrecognized_override': {'not': 'a string'},
          'chat_history': {
            'with_depth_entries': false,
            'unrecognized_history_option': 42,
            'prompts': [
              {'role': 'assistant', 'content': 'A', 'unrecognized_prompt_option': true},
            ],
          },
        },
        'injects': [
          {
            'role': 'system',
            'content': 'D',
            'depth': 0,
            'position': 'unread-on-raw',
            'should_scan': 'unread-on-raw',
            'filter': {'unread': true},
          },
        ],
        'custom_api': {
          'future_sampling_option': {'opaque': true},
        },
      });
      expect(request.toHelperJson()['automatic_trigger'], isTrue);
      expect(request.toHelperJson()['future_option'], {'nested': 1});
      final response = h.reply('done');
      final generation = await h.bridge.generateRaw(context.id, request);
      final wire = await generationRequest(generation, response);
      await generation.result;
      expect(generationMessages(wire).map((message) => message['content']), ['A', 'D', 'Q']);
      expect(wire.body.containsKey('automatic_trigger'), isFalse);
      expect(wire.body.containsKey('future_sampling_option'), isFalse);

      final card = await h.card('Helper actor');
      final chat = await h.emptyChat(card);
      final ordinaryContext = await h.context(chat, characterId: card, instanceId: 'unread-options-normal');
      final normalResponse = h.reply('normal done');
      final normal = await h.bridge.generate(
        ordinaryContext.id,
        TavernHelperGenerateRequest.fromJson({
          'user_input': 'normal input',
          'automatic_trigger': true,
          'future_option': {'nested': 2},
          'overrides': {
            'future_field': {'opaque': true},
          },
        }),
      );
      final normalWire = await generationRequest(normal, normalResponse);
      expect((await normal.result).text, 'normal done');
      expect(generationMessages(normalWire).any((message) => message['content'] == 'normal input'), isTrue);
      expect(normalWire.body.containsKey('automatic_trigger'), isFalse);
    },
  );
}

TavernHelperRawRequest _raw(String id, {bool silent = false}) => TavernHelperRawRequest.fromJson({
  'generation_id': id,
  'should_stream': true,
  'should_silence': silent,
  'ordered_prompts': [
    {'role': 'user', 'content': 'Q'},
  ],
});

ScriptJson _regex(String id, String find, String replace, int placement, {bool promptOnly = false, int? maxDepth}) => {
  'id': id,
  'scriptName': id,
  'findRegex': find,
  'replaceString': replace,
  'placement': [placement],
  'markdownOnly': false,
  'promptOnly': promptOnly,
  'disabled': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'trimStrings': <Object?>[],
  'maxDepth': ?maxDepth,
};
