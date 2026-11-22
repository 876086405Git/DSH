import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _tool = <String, Object?>{
  'type': 'function',
  'function': {
    'name': 'lookup',
    'parameters': {'type': 'object'},
  },
};

void main() {
  test('Helper streaming keeps equal tool indices in different choices separate', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'choice-buckets'));
    final plan = h.stream();
    final generation = await h.bridge.generateRaw(context.id, _streamRequest());
    await generationSignal(generation, plan.listening.future);
    generationSse(plan, {
      'choices': [
        _choice(0, 'A', [_call('call_pick', 'look', '{"x":')]),
        _choice(1, 'WRONG', [_call('call_other', 'search', '{}')]),
      ],
    });
    generationSse(plan, {
      'choices': [
        _choice(0, 'B', [_call(null, 'up', '1}')]),
        _choice(1, 'WRONG-TAIL', [_call(null, '_other', '')]),
      ],
    });
    plan.finish();
    final result = await generation.result;
    expect(result.text, 'AB');
    expect(result.helperMetadata!.toolCalls.map((call) => (call.id, call.name, call.arguments)), [
      ('call_pick', 'lookup', '{"x":1}'),
    ]);
  });

  test('Helper keeps the first body choice through reordered and other-only stream frames', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'choice-reorder'));
    final plan = h.stream();
    final generation = await h.bridge.generateRaw(context.id, _streamRequest());
    await generationSignal(generation, plan.listening.future);
    generationSse(plan, {
      'choices': [
        _choice(1, 'A', [_call('call_pick', 'look', '{"x":')]),
        _choice(0, 'WRONG', const []),
      ],
    });
    generationSse(plan, {
      'choices': [
        _choice(0, 'WRONG-REORDER', const []),
        _choice(1, 'B', [_call(null, 'up', '1}')]),
      ],
    });
    generationSse(plan, {
      'choices': [_choice(0, 'WRONG-ONLY', const [])],
    });
    plan.finish();
    final result = await generation.result;
    expect(result.text, 'AB');
    expect(result.helperMetadata!.toolCalls.map((call) => (call.id, call.name, call.arguments)), [
      ('call_pick', 'lookup', '{"x":1}'),
    ], reason: 'The native index-zero snapshot has no calls; that is not Helper streaming consumption.');
  });

  for (final raw in [false, true]) {
    for (final selection in ['zero', 'one', 'override']) {
      test('Helper ${raw ? 'raw' : 'normal'} WI uses $selection history and the independent physical clock', () async {
        final h = await generationFixture();
        final actor = await h.card('Helper WI');
        final chat = await h.emptyChat(actor);
        final context = await h.context(chat, characterId: actor);
        await h.bridge.createChatMessages(context.id, [
          TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'OLDKEY'),
          TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'neutral-a'),
          TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'neutral-u'),
          TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'SCAN_RAW'),
          TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'OLDKEY', hidden: true),
          TavernScriptMessageDraft(role: TavernScriptRole.system, message: 'SYSTEMKEY'),
        ]);
        await h.engine.setSettings({
          'globalRegexScripts': [
            {
              'id': 'wi-prepared-history',
              'scriptName': 'wi-prepared-history',
              'findRegex': 'SCAN_RAW',
              'replaceString': 'REGEXKEY',
              'placement': [2],
              'markdownOnly': false,
              'promptOnly': true,
              'disabled': false,
              'runOnEdit': false,
              'substituteRegex': 0,
              'trimStrings': <Object?>[],
              'maxDepth': 0,
            },
          ],
        });
        await h.engine.putLorebook('helper-history-wi', _book());
        await h.engine.bindLorebooks(['helper-history-wi']);
        final config = <String, Object?>{
          'user_input': 'INPUTKEY',
          'max_chat_history': selection == 'one' ? 1 : 0,
          'overrides': {
            'chat_history': {
              'with_depth_entries': false,
              if (selection == 'override')
                'prompts': [
                  {'role': 'user', 'content': 'OVERRIDEKEY'},
                  {'role': 'system', 'content': 'SYSTEMKEY'},
                ],
            },
          },
        };
        final response = h.reply('done');
        final generation = raw
            ? await h.bridge.generateRaw(
                context.id,
                TavernHelperRawRequest.fromJson({
                  ...config,
                  // The WI scan still uses selected history when the output
                  // does not request a chat_history slot.
                  'ordered_prompts': ['world_info_before', 'user_input'],
                }),
              )
            : await h.bridge.generate(context.id, TavernHelperGenerateRequest.fromJson(config));
        final wire = await generationRequest(generation, response);
        await generation.result;
        final text = generationMessages(wire).map((message) => message['content']).join('\n');
        expect(text, contains('WI_INPUT'));
        expect(text, isNot(contains('WI_OLD')));
        expect(text, isNot(contains('WI_SYSTEM')));
        expect(text.contains('WI_REGEX'), selection == 'one');
        expect(text.contains('WI_OVERRIDE'), selection == 'override');
        final file = (await h.engine.exportChat(chat)).first;
        final metadata = scriptMap(StChatDocument.decode(file.fileName, file.bytes).header['chat_metadata']);
        final sticky = scriptMap(scriptMap(metadata['timedWorldInfo'])['sticky']);
        expect(sticky, hasLength(1));
        expect(scriptMap(sticky.values.single)['start'], 4);
        expect(scriptMap(sticky.values.single)['end'], 6);
        expect(generationNodes(h, chat), hasLength(6));
      });
    }
  }
}

TavernHelperRawRequest _streamRequest() => TavernHelperRawRequest.fromJson({
  'should_stream': true,
  'ordered_prompts': [
    {'role': 'user', 'content': 'Q'},
  ],
  'tools': [_tool],
});

ScriptJson _choice(int index, String text, List<ScriptJson> calls) => {
  'index': index,
  'delta': {'role': 'assistant', 'content': text, if (calls.isNotEmpty) 'tool_calls': calls},
};

ScriptJson _call(String? id, String name, String arguments) => {
  'index': 0,
  'id': ?id,
  'type': 'function',
  'function': {'name': name, 'arguments': arguments},
};

ScriptJson _book() => {
  'name': 'Helper selected-history WI',
  'entries': {
    for (final (index, pair) in [
      ('OLDKEY', 'WI_OLD'),
      ('REGEXKEY', 'WI_REGEX'),
      ('OVERRIDEKEY', 'WI_OVERRIDE'),
      ('SYSTEMKEY', 'WI_SYSTEM'),
      ('INPUTKEY', 'WI_INPUT'),
    ].indexed)
      '$index': {
        'uid': index,
        'key': [pair.$1],
        'content': pair.$2,
        'constant': false,
        'disable': false,
        'position': 0,
        'order': 100,
        'useProbability': false,
        if (pair.$1 == 'INPUTKEY') 'sticky': 2,
      },
  },
};
