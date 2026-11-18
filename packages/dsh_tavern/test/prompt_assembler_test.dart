import 'dart:convert';

import 'package:dsh_tavern/src/prompt/deepseek_processing.dart';
import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

const _counter = _MessageCounter();

ChatPreset _preset([Map<String, Object?> changes = const {}]) =>
    ChatPreset({...ChatPreset.stDefault().raw, 'openai_max_context': 10000, 'openai_max_tokens': 100, ...changes});
PromptAssembly _assemble({
  ChatPreset? preset,
  Map<String, Object?> card = const {'name': 'Whale'},
  List<PromptHistoryMessage> history = const [],
  List<PromptInjection> injections = const [],
  String type = 'normal',
  bool deepseek = true,
  bool pinExamples = false,
  String examplesBefore = '',
  String examplesAfter = '',
  String persona = '',
  List<PromptExample> worldExamples = const [],
  PromptExpansion? expansion,
  PromptExpansion? cardExpansion,
  List<String> groupNames = const [],
}) => const PromptAssembler(counter: _counter).assemble(
  PromptInput(
    preset: preset ?? _preset(),
    card: card,
    history: history,
    model: 'configured-model',
    userName: 'User',
    characterId: 'card-1',
    generationType: type,
    deepseek: deepseek,
    injections: injections,
    pinExamples: pinExamples,
    expansion: expansion,
    groupNames: groupNames,
    examplesBefore: examplesBefore,
    examplesAfter: examplesAfter,
    worldExamples: worldExamples,
    cardExpansion: cardExpansion,
    persona: persona,
  ),
);
List<String> _contents(PromptAssembly result) =>
    result.beforePostProcessing.map((s) => s.message['content'] as String).toList();

void main() {
  test('preset raw roundtrip preserves unknowns and connection removal is explicit', () {
    final raw = <String, Object?>{
      'unknown': {
        'zero': 0,
        'null': null,
        'array': [false, '🐋'],
      },
      'reverse_proxy': 'https://example.test',
      'main_prompt': 'legacy',
      'extensions': {
        'foreign': {'api_key': 'opaque-owned-value'},
      },
    };
    final preset = ChatPreset(raw);
    final normalized = preset.settings;
    expect(
      (normalized['prompts'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
        (p) => p['identifier'] == 'main',
      )['content'],
      'legacy',
    );
    expect(jsonDecode(preset.encode()), raw);
    final exported = jsonDecode(preset.encode(includeConnection: false)) as Map<String, Object?>;
    expect(exported.containsKey('reverse_proxy'), isFalse);
    expect(exported['extensions'], raw['extensions']);
    expect(preset.raw, raw);
  });

  test('100001 accepts string id; a legacy 100000 group falls back to default', () {
    final legacy = _preset({
      'prompt_order': [
        {
          'character_id': 100000,
          'order': [
            {'identifier': 'chatHistory', 'enabled': true},
          ],
        },
      ],
    });
    expect(_assemble(preset: legacy).beforePostProcessing.first.id, 'main');
    final raw = _preset().raw;
    final groups = (raw['prompt_order'] as List<Object?>).whereType<Map<String, Object?>>();
    groups.firstWhere((g) => g['character_id'] == 100001)['character_id'] = '100001';
    expect(_assemble(preset: ChatPreset(raw)).beforePostProcessing.first.id, 'main');
  });

  test('card overrides retain original and provenance, nickname supplies char', () {
    final result = _assemble(
      card: {
        'name': 'Stored',
        'nickname': 'Whale',
        'description': 'Blue',
        'system_prompt': 'OVERRIDE[{{original}}]',
        'post_history_instructions': 'TAIL {{char}}',
      },
    );
    expect(_contents(result).first, "OVERRIDE[Write Whale's next reply in a fictional chat between Whale and User.]");
    expect(_contents(result), contains('Blue'));
    expect(_contents(result).last, 'TAIL Whale');
    expect(result.beforePostProcessing.first.sources.map((s) => s.kind), ['card', 'preset']);
    expect(result.body['model'], 'configured-model');
    expect(result.afterPostProcessing.first.sources.length, greaterThan(1));
  });

  test('disabled main stays an extension anchor and cannot be card-overridden', () {
    final raw = _preset().raw;
    final groups = (raw['prompt_order'] as List<Object?>).whereType<Map<String, Object?>>();
    final order = groups.firstWhere((g) => g['character_id'] == 100001)['order'] as List<Object?>;
    order.whereType<Map<String, Object?>>().firstWhere((p) => p['identifier'] == 'main')['enabled'] = false;
    final result = _assemble(
      preset: ChatPreset(raw),
      card: {'name': 'Whale', 'system_prompt': 'MUST NOT APPEAR'},
      injections: [
        const PromptInjection(
          fragment: PromptFragment('NOTE', PromptSource('note', 'n')),
          placement: PromptPlacement.beforeMain,
        ),
      ],
    );
    expect(_contents(result).first, 'NOTE');
    expect(_contents(result).join(), isNot(contains('MUST NOT APPEAR')));
  });

  test('budget keeps the newest contiguous history and stops at the first miss', () {
    final result = _assemble(
      preset: _preset({'openai_max_context': 6, 'openai_max_tokens': 0}),
      history: const [
        PromptHistoryMessage(id: '1', role: 'user', content: 'old'),
        PromptHistoryMessage(id: '2', role: 'assistant', content: 'middle'),
        PromptHistoryMessage(id: '3', role: 'user', content: 'new'),
      ],
    );
    expect(_contents(result), [
      "Write Whale's next reply in a fictional chat between Whale and User.",
      '[Start a new Chat]',
      'new',
    ]);
    expect(result.excluded.where((item) => item.reason == 'history-budget').map((item) => item.id), ['2', '1']);
    expect(result.remainingBudget, 0);
  });

  test('history evaluates newest first while retaining all chronological segments and group controls', () {
    final raw = _preset({
      'names_behavior': 1,
      'openai_max_context': 20,
      'openai_max_tokens': 0,
      'send_if_empty': 'EMPTY 等待🌊',
      'new_chat_prompt': 'SOLO must not appear',
      'new_group_chat_prompt': 'NEW 群聊🐋',
      'group_nudge_prompt': 'GROUP 接续🧭',
      'squash_system_messages': false,
    }).raw;
    (raw['prompts'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
      (prompt) => prompt['identifier'] == 'main',
    )['content'] = 'MAIN';
    final visits = <String>[];
    var ticks = 0;
    final result = _assemble(
      preset: ChatPreset(raw),
      deepseek: false,
      groupNames: ['Whale', 'Other'],
      history: const [
        PromptHistoryMessage(id: 'h1', role: 'user', name: 'User one', content: '一{{visit::h1}}🐋'),
        PromptHistoryMessage(id: 'h2', role: 'assistant', name: 'Whale-2', content: '二{{visit::h2}}🌊'),
        PromptHistoryMessage(id: 'h3', role: 'user', name: 'User_3', content: '三{{visit::h3}}🧭'),
        PromptHistoryMessage(id: 'h4', role: 'assistant', name: 'Other.4', content: '四{{visit::h4}}🐋'),
        PromptHistoryMessage(id: 'h5', role: 'user', name: 'User five', content: '五{{visit::h5}}🌊'),
        PromptHistoryMessage(id: 'h6', role: 'assistant', name: 'Whale six', content: '六{{visit::h6}}🧭'),
      ],
      expansion: (text, _) => text.replaceAllMapped(RegExp(r'\{\{visit::(h[1-6])\}\}'), (match) {
        visits.add(match[1]!);
        return '${++ticks}';
      }),
    );
    expect(visits, ['h6', 'h5', 'h4', 'h3', 'h2', 'h1']);
    expect(ticks, 6);

    Map<String, Object?> segment(
      String id,
      String role,
      String content,
      String kind,
      String sourceId, {
      String name = '',
      String label = '',
    }) => {
      'id': id,
      'message': {'role': role, 'content': content, if (name.isNotEmpty) 'name': name},
      'sources': [
        {'kind': kind, 'id': sourceId, 'label': label, 'details': <String, Object?>{}},
      ],
      'tokens': 1,
    };
    // Explicit chronological expectations: do not derive these from reversed
    // history or replay the expansion callback to construct the oracle.
    final expected = [
      segment('main', 'system', 'MAIN', 'preset', 'main', label: 'Main Prompt'),
      segment('newMainChat', 'system', 'NEW 群聊🐋', 'control', 'new_group_chat_prompt'),
      segment('h1', 'user', '一6🐋', 'history', 'h1', name: 'User_one', label: 'User one'),
      segment('h2', 'assistant', '二5🌊', 'history', 'h2', name: 'Whale_2', label: 'Whale-2'),
      segment('h3', 'user', '三4🧭', 'history', 'h3', name: 'User_3', label: 'User_3'),
      segment('h4', 'assistant', '四3🐋', 'history', 'h4', name: 'Other_4', label: 'Other.4'),
      segment('h5', 'user', '五2🌊', 'history', 'h5', name: 'User_five', label: 'User five'),
      segment('h6', 'assistant', '六1🧭', 'history', 'h6', name: 'Whale_six', label: 'Whale six'),
      segment('emptyUserMessageReplacement', 'user', 'EMPTY 等待🌊', 'control', 'send_if_empty'),
      segment('groupNudge', 'system', 'GROUP 接续🧭', 'control', 'group_nudge_prompt'),
    ];
    expect(result.beforePostProcessing.map((item) => item.toJson()).toList(), expected);
    expect(result.afterPostProcessing.map((item) => item.toJson()).toList(), expected);
    expect(result.body['messages'], expected.map((item) => item['message']).toList());
    expect(result.excluded.map((item) => item.toJson()).toList(), [
      {
        'id': 'enhanceDefinitions',
        'reason': 'disabled',
        'sources': [
          {
            'kind': 'preset',
            'id': 'enhanceDefinitions',
            'label': 'Enhance Definitions',
            'details': <String, Object?>{},
          },
        ],
      },
    ]);
    expect(result.budget, 20);
    // Ten nonempty messages plus the existing three-token assembly overhead.
    expect(result.remainingBudget, 7);
    expect(result.exactTokenCounts, isFalse);
    expect(result.counterName, 'synthetic one token per message');
  });

  test('examples are atomic; pinning gives their whole block priority', () {
    final preset = _preset({'openai_max_context': 8, 'openai_max_tokens': 0, 'cacheFriendlyTrimming': false});
    const card = {'name': 'Whale', 'mes_example': '<START>\nUser: example U\nWhale: example A'};
    const history = [
      PromptHistoryMessage(id: '1', role: 'user', content: 'one'),
      PromptHistoryMessage(id: '2', role: 'assistant', content: 'two'),
      PromptHistoryMessage(id: '3', role: 'user', content: 'three'),
      PromptHistoryMessage(id: '4', role: 'assistant', content: 'four'),
    ];
    final unpinned = _assemble(preset: preset, card: card, history: history);
    expect(_contents(unpinned), containsAllInOrder(['two', 'three', 'four']));
    expect(_contents(unpinned), isNot(contains('example U')));
    final pinned = _assemble(preset: preset, card: card, history: history, pinExamples: true);
    expect(_contents(pinned), containsAllInOrder(['[Example Chat]', 'example U', 'example A', '[Start a new Chat]']));
    expect(_contents(pinned), isNot(contains('four')));
  });

  test('mandatory overflow is a typed error, never silent truncation', () {
    expect(
      () => _assemble(preset: _preset({'openai_max_context': 3, 'openai_max_tokens': 0})),
      throwsA(isA<PromptBudgetExceeded>().having((e) => e.identifier, 'identifier', 'main')),
    );
  });

  test('depth order and role grouping match reverse-history insertion', () {
    final raw = _preset().raw;
    final prompts = raw['prompts'] as List<Object?>;
    final orders =
        (raw['prompt_order'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
              (group) => group['character_id'] == 100001,
            )['order']
            as List<Object?>;
    for (final item in [
      ('high', 'system', 200),
      ('system', 'system', 100),
      ('user', 'user', 100),
      ('assistant', 'assistant', 100),
      ('low', 'user', 50),
    ]) {
      prompts.add({
        'identifier': item.$1,
        'role': item.$2,
        'content': item.$1,
        'system_prompt': false,
        'injection_position': 1,
        'injection_depth': 1,
        'injection_order': item.$3,
      });
      orders.add({'identifier': item.$1, 'enabled': true});
    }
    final result = _assemble(
      preset: ChatPreset(raw),
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'OLD'),
        PromptHistoryMessage(id: 'new', role: 'assistant', content: 'NEW'),
      ],
      injections: [const PromptInjection(depth: 1, fragment: PromptFragment('EXT', PromptSource('world', 'entry')))],
    );
    expect(_contents(result), containsAllInOrder(['OLD', 'low', 'assistant', 'user', 'system\nEXT', 'high', 'NEW']));
    final combined = result.beforePostProcessing.singleWhere((s) => s.message['content'] == 'system\nEXT');
    expect(combined.sources.map((s) => s.id), ['system', 'entry']);
  });

  test('continue prefill keeps raw text and postfix is not sent to the model', () {
    final result = _assemble(
      type: 'continue',
      preset: _preset({'continue_prefill': true, 'continue_postfix': 'POSTFIX'}),
      history: const [PromptHistoryMessage(id: 'a', role: 'assistant', content: 'partial\n')],
    );
    expect(result.beforePostProcessing.last.message, {'role': 'assistant', 'content': 'partial\n'});
    expect(result.afterPostProcessing.last.message['prefix'], isTrue);
    expect(jsonEncode(result.body), isNot(contains('POSTFIX')));
  });

  test('continue without prefill displaces the reply before its nudge at the end', () {
    final result = _assemble(
      type: 'continue',
      history: const [
        PromptHistoryMessage(id: 'u', role: 'user', content: 'question'),
        PromptHistoryMessage(id: 'a', role: 'assistant', content: 'partial'),
      ],
      card: {'name': 'Whale', 'post_history_instructions': 'PHI'},
    );
    expect(
      _contents(result),
      containsAllInOrder([
        'question',
        'PHI',
        'partial',
        '[Continue your last message without repeating its original content.]',
      ]),
    );
    expect(result.body.toString(), isNot(contains('prefix: true')));
  });

  test('hidden/system are excluded, narrator retained, completion names sanitized', () {
    final result = _assemble(
      preset: _preset({'names_behavior': 1}),
      deepseek: false,
      history: const [
        PromptHistoryMessage(id: 'hidden', role: 'user', content: 'hidden', hidden: true),
        PromptHistoryMessage(id: 'sys', role: 'system', content: 'system', isSystem: true),
        PromptHistoryMessage(id: 'n', role: 'narrator', content: 'scene\r\nline'),
        PromptHistoryMessage(id: 'a', role: 'assistant', name: '鲸 鱼', content: 'reply'),
      ],
    );
    expect(result.beforePostProcessing.last.message['name'], '___');
    expect(_contents(result), contains('scene\nline'));
    expect(result.excluded.map((item) => item.id), containsAll(['hidden', 'sys']));
  });

  test('impersonation control is last and Claude-only settings do not leak', () {
    final result = _assemble(
      type: 'impersonate',
      preset: _preset({'assistant_prefill': 'CLAUDE_PREFILL', 'assistant_impersonation': 'CLAUDE_IMPERSONATE'}),
      groupNames: ['Whale', 'Other'],
    );
    expect(result.beforePostProcessing.last.id, 'impersonate');
    expect(result.beforePostProcessing.map((s) => s.id), isNot(contains('groupNudge')));
    expect(jsonEncode(result.body), isNot(contains('CLAUDE_')));
  });

  test('example parser keeps repeated speaker lines and removes only first prefix', () {
    final blocks = parseDialogueExamples(
      'User: first\nUser: second\nWhale: answer\n<START>\nWhale: next',
      userName: 'User',
      characterName: 'Whale',
    );
    expect(blocks, [
      [
        {'role': 'system', 'content': 'first\nUser: second', 'name': 'example_user'},
        {'role': 'system', 'content': 'answer', 'name': 'example_assistant'},
      ],
      [
        {'role': 'system', 'content': 'next', 'name': 'example_assistant'},
      ],
    ]);
  });

  test('DeepSeek semi_tools merges twice, handles example names and retains sources', () {
    PromptSegment part(String id, String role, String content, {String? name}) => PromptSegment(
      id: id,
      message: {'role': role, 'content': content, 'name': ?name},
      sources: [PromptSource('test', id)],
      tokens: 1,
    );
    final result = postProcessDeepSeek(
      [
        part('s', 'system', 'start'),
        part('u', 'user', 'User: hello', name: 'User'),
        part('e', 'system', 'example', name: 'example_assistant'),
        part('a', 'assistant', 'end'),
      ],
      userName: 'User',
      characterName: 'Whale',
      counter: _counter,
    );
    expect(result.map((s) => s.message).toList(), [
      {'role': 'system', 'content': 'start'},
      {'role': 'user', 'content': 'User: hello\n\nWhale: example'},
      {'role': 'assistant', 'content': 'end', 'prefix': true},
    ]);
    expect(result[1].sources.map((s) => s.id), ['u', 'e']);
  });

  test('historical tool result prevents prefix even with no configured tools', () {
    final result = postProcessDeepSeek(
      [
        const PromptSegment(
          id: 't',
          message: {'role': 'tool', 'content': 'done', 'tool_call_id': 'call'},
          sources: [],
          tokens: 1,
        ),
        const PromptSegment(id: 'a', message: {'role': 'assistant', 'content': 'answer'}, sources: [], tokens: 1),
      ],
      userName: 'User',
      characterName: 'Whale',
      counter: _counter,
    );
    expect(result.first.message['role'], 'tool');
    expect(result.first.message['tool_call_id'], 'call');
    expect(result.last.message.containsKey('prefix'), isFalse);
  });

  test('DeepSeek sends top_p epsilon and mapped effort but not seed or logit_bias', () {
    final result = _assemble(
      preset: _preset({
        'top_p': 0,
        'show_thoughts': true,
        'reasoning_effort': 'medium',
        'seed': 42,
        'logit_bias': {'1': 100},
        'top_k': 7,
      }),
    );
    expect(result.body['top_p'], 2.220446049250313e-16);
    expect(result.body['thinking'], {'type': 'enabled'});
    expect(result.body['reasoning_effort'], 'high');
    expect(result.body.keys, isNot(contains('seed')));
    expect(result.body.keys, isNot(contains('logit_bias')));
    expect(result.body.keys, isNot(contains('top_k')));
    final quiet = _assemble(type: 'quiet', preset: _preset({'stream_openai': true, 'show_thoughts': false}));
    expect(quiet.body['stream'], isFalse);
    expect(quiet.body.containsKey('reasoning_effort'), isFalse);
  });

  test('card normalization trims then expands and removes CR; whitespace override is empty', () {
    final result = _assemble(
      card: {'name': 'Whale', 'description': '  D\r\nE  ', 'scenario': ' \r\n ', 'system_prompt': ' \r\n '},
    );
    expect(_contents(result).first, "Write Whale's next reply in a fictional chat between Whale and User.");
    expect(_contents(result), contains('D\nE'));
    expect(_contents(result).join(), isNot(contains('\r')));
  });

  test('world examples and card examples do not create an extra empty block', () {
    final result = _assemble(
      examplesBefore: '<START>\nUser: WB',
      card: {'name': 'Whale', 'mes_example': '<START>\nWhale: CARD'},
    );
    expect(_contents(result).where((text) => text == '[Example Chat]'), hasLength(2));
    expect(_contents(result), containsAllInOrder(['WB', 'CARD']));
  });

  test('depth extensions sort keys, trim each value, then expand the joined text once', () {
    final calls = <String>[];
    final result = _assemble(
      injections: const [
        PromptInjection(depth: 0, fragment: PromptFragment(' Z ', PromptSource('extension', 'z'))),
        PromptInjection(depth: 0, fragment: PromptFragment(' A ', PromptSource('extension', 'a'))),
      ],
      expansion: (text, _) {
        calls.add(text);
        return text;
      },
    );
    expect(_contents(result).last, 'A\nZ');
    expect(calls, isNot(contains(' Z ')));
    expect(calls, isNot(contains(' A ')));
    // One extension-registry expansion, then one history prepare expansion.
    expect(calls.where((text) => text == 'A\nZ'), hasLength(2));
  });

  test('an affordable empty named history message does not spend budget', () {
    final counter = CallbackTokenCounter(
      name: 'budget probe',
      exact: false,
      text: (text) => text.length,
      message: (message) => message['content'] == '' ? (message.containsKey('name') ? 6 : 0) : 1,
    );
    final result = PromptAssembler(counter: counter).assemble(
      PromptInput(
        preset: _preset({'names_behavior': 1, 'openai_max_context': 11, 'openai_max_tokens': 0}),
        card: const {'name': 'Whale'},
        model: 'test',
        history: const [
          PromptHistoryMessage(id: 'old', role: 'user', content: 'OLD', name: 'U'),
          PromptHistoryMessage(id: 'empty', role: 'user', content: '', name: 'U'),
        ],
      ),
    );
    expect(_contents(result), contains('OLD'));
    expect(result.remainingBudget, 5);
  });

  test('fractional priority stays distinct; fractional and over-limit depths do not inject', () {
    final raw = _preset().raw;
    final prompts = raw['prompts'] as List<Object?>;
    final orders =
        (raw['prompt_order'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
              (group) => group['character_id'] == 100001,
            )['order']
            as List<Object?>;
    for (final item in [('F', 0, 100.5), ('I', 0, 100), ('fractional', 4.5, 100), ('too-deep', 10001, 100)]) {
      prompts.add({
        'identifier': item.$1,
        'role': 'user',
        'content': item.$1,
        'system_prompt': false,
        'injection_position': 1,
        'injection_depth': item.$2,
        'injection_order': item.$3,
      });
      orders.add({'identifier': item.$1, 'enabled': true});
    }
    final result = _assemble(
      preset: ChatPreset(raw),
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
    );
    expect(_contents(result), containsAllInOrder(['H', 'I', 'F']));
    expect(_contents(result), isNot(contains('fractional')));
    expect(_contents(result), isNot(contains('too-deep')));
  });

  test('default counter visibly estimates CJK and non-CJK text', () {
    const counter = EstimatedTokenCounter();
    expect(counter.countText('你好'), 2);
    expect(counter.countText('abcdefg'), 2);
    final result = const PromptAssembler().assemble(
      PromptInput(preset: _preset(), card: const {'name': 'Whale'}, history: const [], model: 'configured'),
    );
    expect(result.exactTokenCounts, isFalse);
    expect(result.counterName, contains('estimate'));
  });

  test('fresh full macro environments receive only temporary overrides', () {
    var x = 0;
    String base(String text, Map<String, String> _) => text.replaceAllMapped(RegExp(r'\{\{inc\}\}'), (_) => '${++x}');
    final calls = <Map<String, String>>[];
    final result = _assemble(
      card: {'name': 'Whale', 'personality': '{{inc}}', 'system_prompt': '{{original}}'},
      cardExpansion: base,
      expansion: (text, overrides) {
        calls.add({...overrides});
        return text
            .replaceAll('{{personality}}', text.contains('{{personality}}') ? base('{{inc}}', {}) : '')
            .replaceAll('{{original}}', overrides['original'] ?? '{{original}}');
      },
    );
    expect(x, 2); // eager field 1, fresh ordinary macro environment 2.
    expect(_contents(result), contains('2'));
    expect(calls.any((values) => values.containsKey('original')), isTrue);
    expect(calls.expand((values) => values.keys).toSet(), {'original'});
  });

  test('fallback group and description aliases follow the single-character environment', () {
    final raw = _preset().raw;
    (raw['prompts'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
      (prompt) => prompt['identifier'] == 'main',
    )['content'] = 'G={{group}};D={{description}}';
    final result = _assemble(preset: ChatPreset(raw), card: {'name': 'Whale', 'description': 'Blue'});
    expect(_contents(result).first, 'G=Whale;D=Blue');
  });

  test('world examples expand separately in mixed order and retain each book origin', () {
    final calls = <String>[];
    final result = _assemble(
      card: {'name': 'Whale', 'mes_example': '<START>\nWhale: CARD'},
      worldExamples: const [
        PromptExample(before: true, fragment: PromptFragment('<START>\n{{user}}: A', PromptSource('world', 'book:1'))),
        PromptExample(before: false, fragment: PromptFragment('<START>\n{{char}}: B', PromptSource('world', 'book:2'))),
        PromptExample(before: true, fragment: PromptFragment('<START>\n{{user}}: C', PromptSource('world', 'book:3'))),
      ],
      cardExpansion: (text, _) {
        calls.add(text);
        return text.replaceAll('{{user}}', 'User').replaceAll('{{char}}', 'Whale');
      },
    );
    expect(calls, containsAllInOrder(['<START>\n{{user}}: A', '<START>\n{{char}}: B', '<START>\n{{user}}: C']));
    expect(_contents(result), containsAllInOrder(['C', 'A', 'CARD', 'B']));
    expect(result.beforePostProcessing.singleWhere((s) => s.message['content'] == 'B').sources.single.id, 'book:2');
  });

  test('duplicate order identifiers keep the first collection position without duplicate output', () {
    final raw = _preset().raw;
    final order =
        (raw['prompt_order'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
              (group) => group['character_id'] == 100001,
            )['order']
            as List<Object?>;
    order.insert(1, {'identifier': 'main', 'enabled': false});
    final result = _assemble(preset: ChatPreset(raw));
    expect(result.beforePostProcessing.where((segment) => segment.id == 'main'), hasLength(1));
    expect(_contents(result).first, "Write Whale's next reply in a fictional chat between Whale and User.");
  });

  test('persona marker uses raw whitespace and expands again after its eager snapshot', () {
    final raw = _assemble(persona: '  P\r\nQ  ');
    expect(raw.beforePostProcessing.singleWhere((s) => s.id == 'personaDescription').message['content'], '  P\r\nQ  ');
    var x = 0;
    String expand(String text, Map<String, String> _) =>
        text.replaceAllMapped(RegExp(r'\{\{incvar::x\}\}'), (_) => '${++x}');
    final result = _assemble(persona: '{{incvar::x}}', expansion: expand, cardExpansion: expand);
    expect(result.beforePostProcessing.singleWhere((s) => s.id == 'personaDescription').message['content'], '2');
    expect(x, 2);
  });

  test('known relative extensions prepare before persona, unknown ones after, with no replay', () {
    var x = 'old';
    var writes = 0;
    String expand(String text, Map<String, String> _) {
      text = text.replaceAllMapped(RegExp(r'\{\{setvar::x::([^}]+)\}\}'), (m) {
        x = m[1]!;
        writes++;
        return '';
      });
      return text.replaceAll('{{getvar::x}}', x);
    }

    final result = _assemble(
      persona: '{{getvar::x}}',
      expansion: expand,
      cardExpansion: expand,
      injections: const [
        PromptInjection(
          placement: PromptPlacement.beforeMain,
          fragment: PromptFragment('{{setvar::x::late}}LATE', PromptSource('extension', 'custom')),
        ),
        PromptInjection(
          placement: PromptPlacement.beforeMain,
          fragment: PromptFragment('{{setvar::x::new}}NOTE', PromptSource('note', '2_floating_prompt')),
        ),
      ],
    );
    expect(result.beforePostProcessing.singleWhere((s) => s.id == 'personaDescription').message['content'], 'new');
    expect(x, 'late');
    expect(writes, 2);
    expect(_contents(result), containsAllInOrder(['LATE', 'NOTE']));
  });

  test('known in-chat extension also has its early preparation pass', () {
    var x = 0;
    String expand(String text, Map<String, String> _) =>
        text.replaceAllMapped(RegExp(r'\{\{incvar::x\}\}'), (_) => '${++x}');
    final result = _assemble(
      expansion: expand,
      injections: const [
        PromptInjection(
          depth: 0,
          fragment: PromptFragment('{{incvar::x}}NOTE', PromptSource('note', '2_floating_prompt')),
        ),
      ],
    );
    expect(x, 2);
    expect(_contents(result).last, '2NOTE');
  });

  test('continue nudge captures variables before the continued message expands', () {
    var x = 0;
    String expand(String text, Map<String, String> _) {
      text = text.replaceAllMapped(RegExp(r'\{\{incvar::x\}\}'), (_) => '${++x}');
      return text.replaceAll('{{getvar::x}}', '$x');
    }

    final result = _assemble(
      type: 'continue',
      expansion: expand,
      preset: _preset({'continue_prefill': false, 'continue_nudge_prompt': 'N={{getvar::x}}'}),
      history: const [PromptHistoryMessage(id: 'a', role: 'assistant', content: '{{incvar::x}}')],
    );
    expect(_contents(result).sublist(_contents(result).length - 2), ['1', 'N=0']);
    expect(x, 1);
  });

  test('lastChatMessage keeps raw CR and ignores history name formatting but includes local postfix', () {
    final result = _assemble(
      type: 'continue',
      preset: _preset({
        'continue_prefill': false,
        'names_behavior': 2,
        'continue_postfix': 'END',
        'continue_nudge_prompt': 'LAST={{lastChatMessage}}',
      }),
      history: const [PromptHistoryMessage(id: 'a', role: 'assistant', name: 'A', content: 'P\r\nQ')],
    );
    expect(result.beforePostProcessing.last.message['content'], 'LAST=P\r\nQEND');
    expect(_contents(result), contains('A: P\nQ'));
    for (final pair in [('P ', 'LAST=P'), ('P\t', 'LAST=P\tEND')]) {
      final guard = _assemble(
        type: 'continue',
        preset: _preset({'continue_postfix': 'END', 'continue_nudge_prompt': 'LAST={{lastChatMessage}}'}),
        history: [PromptHistoryMessage(id: 'a', role: 'assistant', content: pair.$1)],
      );
      expect(guard.beforePostProcessing.last.message['content'], pair.$2);
    }
  });

  test('group new-chat control reports the template actually used', () {
    final result = _assemble(groupNames: ['Whale', 'Other']);
    expect(
      result.beforePostProcessing.singleWhere((s) => s.id == 'newMainChat').sources.single.id,
      'new_group_chat_prompt',
    );
  });

  test('normalized extension identifiers use final collection replacements', () {
    final result = _assemble(
      injections: const [
        PromptInjection(
          placement: PromptPlacement.beforeMain,
          fragment: PromptFragment('FIRST', PromptSource('extension', 'custom-x')),
        ),
        PromptInjection(
          placement: PromptPlacement.beforeMain,
          fragment: PromptFragment('SECOND', PromptSource('extension', 'custom_x')),
        ),
      ],
    );
    expect(_contents(result).first, 'SECOND');
    expect(_contents(result).where((value) => value == 'SECOND'), hasLength(1));
    expect(_contents(result), isNot(contains('FIRST')));
    final known = _assemble(
      injections: const [
        PromptInjection(
          placement: PromptPlacement.beforeMain,
          fragment: PromptFragment('NOTE', PromptSource('note', '2_floating_prompt')),
        ),
        PromptInjection(
          placement: PromptPlacement.beforeMain,
          fragment: PromptFragment('REPLACED', PromptSource('extension', 'authorsNote')),
        ),
      ],
    );
    // The final replacement participates in ST's known loop and extension loop.
    expect(_contents(known).take(2), ['REPLACED', 'REPLACED']);
    expect(_contents(known), isNot(contains('NOTE')));
  });
}

final class _MessageCounter implements PromptTokenCounter {
  const _MessageCounter();
  @override
  String get name => 'synthetic one token per message';
  @override
  bool get exact => false;
  @override
  int countMessage(Map<String, Object?> message) => message['content'] == '' ? 0 : 1;
  @override
  int countText(String text) => text.isEmpty ? 0 : 1;
}
