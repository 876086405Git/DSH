import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

const _assembler = PromptAssembler(counter: _ContentCounter());

ChatPreset _preset({int capacity = 40, Map<String, Object?> settings = const {}}) => ChatPreset({
  'openai_max_context': capacity + 3,
  'openai_max_tokens': 0,
  'new_chat_prompt': '',
  'new_group_chat_prompt': '',
  'new_example_chat_prompt': '',
  'group_nudge_prompt': '',
  'continue_nudge_prompt': '',
  'continue_postfix': '',
  'continue_prefill': false,
  'send_if_empty': '',
  'scenario_format': '',
  'personality_format': '',
  'wi_format': '',
  'names_behavior': 1,
  'squash_system_messages': false,
  'prompts': [
    for (final id in ['main', 'dialogueExamples', 'chatHistory'])
      {'identifier': id, 'name': id, 'role': 'system', 'content': '', 'system_prompt': true},
  ],
  'prompt_order': [
    {
      'character_id': 100001,
      'order': [
        for (final id in ['main', 'dialogueExamples', 'chatHistory']) {'identifier': id, 'enabled': true},
      ],
    },
  ],
  ...settings,
});

List<PromptHistoryMessage> _history(int count, {String content = 'HHHH', bool macros = false}) => [
  for (var i = 1; i <= count; i++) PromptHistoryMessage(id: 'h$i', role: 'user', content: macros ? '{{h$i}}' : content),
];

PromptAssembly _assemble({
  required List<PromptHistoryMessage> history,
  ChatPreset? preset,
  PromptHistoryWindow? window,
  bool? enabled,
  Map<String, Object?> card = const {'name': 'Guide'},
  List<PromptFragment> before = const [],
  List<PromptInjection> injections = const [],
  List<String> groupNames = const [],
  String type = 'normal',
  bool pinExamples = false,
  PromptExpansion? expansion,
}) => _assembler.assemble(
  PromptInput(
    preset: preset ?? _preset(),
    card: card,
    characterId: 'card',
    history: history,
    model: 'test',
    deepseek: false,
    cacheFriendlyTrimming: enabled,
    historyWindow: window,
    worldBefore: before,
    injections: injections,
    groupNames: groupNames,
    generationType: type,
    pinExamples: pinExamples,
    expansion: expansion,
  ),
);

List<String> _historyIds(PromptAssembly assembly) => [
  for (final segment in assembly.beforePostProcessing)
    for (final source in segment.sources)
      if (source.kind == 'history') source.id,
];

List<String> _texts(PromptAssembly assembly) => [
  for (final segment in assembly.beforePostProcessing) segment.message['content']! as String,
];

void main() {
  test('only overflow opens a window; three appends hold its prefix until the next overflow', () {
    final exactFit = _assemble(history: _history(10));
    expect(exactFit.remainingBudget, 0);
    expect(exactFit.historyWindow, isNull);

    var result = _assemble(history: _history(12));
    expect(_historyIds(result), ['h6', 'h7', 'h8', 'h9', 'h10', 'h11', 'h12']);
    expect(result.historyWindow!.firstNodeId, 'h6');
    expect(result.remainingBudget, 12);

    for (final count in [13, 14, 15]) {
      result = _assemble(history: _history(count), window: result.historyWindow);
      expect(result.historyWindow!.firstNodeId, 'h6');
      expect(_historyIds(result).first, 'h6');
      expect(_historyIds(result).last, 'h$count');
    }
    expect(result.remainingBudget, 0);
    result = _assemble(history: _history(16), window: result.historyWindow);
    expect(_historyIds(result), ['h10', 'h11', 'h12', 'h13', 'h14', 'h15', 'h16']);
    expect(result.historyWindow!.firstNodeId, 'h10');
    expect(result.remainingBudget, 12);
  });

  test('explicit false restores ST admission and macro order, overriding the preset and prior window', () {
    final window = _assemble(history: _history(12)).historyWindow;
    final visits = <String>[];
    final legacy = _assemble(
      history: _history(12, macros: true),
      preset: _preset(settings: {'cacheFriendlyTrimming': true}),
      window: window,
      enabled: false,
      expansion: (text, _) {
        if (!RegExp(r'^\{\{h\d+\}\}$').hasMatch(text)) return text;
        visits.add(text);
        return 'HHHH';
      },
    );
    expect(_historyIds(legacy), ['h3', 'h4', 'h5', 'h6', 'h7', 'h8', 'h9', 'h10', 'h11', 'h12']);
    expect(legacy.historyWindow, isNull);
    expect(legacy.remainingBudget, 0);
    expect(visits, [for (var i = 12; i >= 2; i--) '{{h$i}}']);
    final disabledPreset = _preset(settings: {'cacheFriendlyTrimming': false});
    final presetResult = _assemble(history: _history(12), preset: disabledPreset);
    expect(_historyIds(presetResult), _historyIds(legacy));
    expect(presetResult.historyWindow, isNull);
    expect(_assemble(history: _history(12), preset: disabledPreset, enabled: true).historyWindow!.firstNodeId, 'h6');
  });

  test('an overflowing depth piece opens a window when its stopped tail excludes eligible history', () {
    const injections = [PromptInjection(depth: 10, fragment: PromptFragment('D', PromptSource('note', 'depth')))];
    var result = _assemble(history: _history(12), injections: injections);
    expect(_historyIds(result), ['h6', 'h7', 'h8', 'h9', 'h10', 'h11', 'h12']);
    expect(result.historyWindow!.firstNodeId, 'h6');
    expect(result.remainingBudget, 12);
    final prefix = result.beforePostProcessing.map((segment) => segment.message).toList();
    expect(result.historyWindow!.excludedInjections, hasLength(1));
    for (final count in [13, 14, 15]) {
      result = _assemble(history: _history(count), injections: injections, window: result.historyWindow);
      expect(result.historyWindow!.firstNodeId, 'h6');
      expect(_historyIds(result).first, 'h6');
      expect(_historyIds(result).last, 'h$count');
      expect(result.beforePostProcessing.take(prefix.length).map((segment) => segment.message), prefix);
      expect(_texts(result), isNot(contains('D')));
    }
    // Excluding an already excluded injection or old-window history does not
    // move the boundary early at an exact fit.
    expect(result.remainingBudget, 0);
    result = _assemble(history: _history(16), injections: injections, window: result.historyWindow);
    expect(result.historyWindow!.firstNodeId, 'h10');
    expect(_historyIds(result), ['h10', 'h11', 'h12', 'h13', 'h14', 'h15', 'h16']);
    expect(_texts(result), isNot(contains('D')));

    const retainedInjection = [PromptInjection(depth: 0, fragment: PromptFragment('D', PromptSource('note', 'depth')))];
    final retained = _assemble(history: _history(12), injections: retainedInjection);
    expect(retained.historyWindow!.excludedInjections, isEmpty);
    final retainedNext = _assemble(
      history: _history(13),
      injections: retainedInjection,
      window: retained.historyWindow,
    );
    expect(retainedNext.historyWindow!.firstNodeId, retained.historyWindow!.firstNodeId);
    expect(_texts(retainedNext).where((text) => text == 'D'), hasLength(1));
  });

  test('excluded depth pieces keep their source position when an earlier source activates', () {
    var reveal = false;
    String expand(String text, Map<String, String> _) => text == '{{maybe}}' ? (reveal ? 'C' : '') : text;
    const split = PromptInjection(
      depth: 9,
      fragment: PromptFragment('', PromptSource('note', 'b-group')),
      fragments: [
        PromptFragment('{{maybe}}', PromptSource('note', 'b')),
        PromptFragment('BBBB', PromptSource('note', 'b'), expandMacros: false),
        PromptFragment('B', PromptSource('note', 'b'), expandMacros: false),
      ],
    );
    final first = _assemble(history: _history(12), injections: const [split], expansion: expand);
    expect(first.historyWindow!.firstNodeId, 'h6');
    expect(first.historyWindow!.excludedInjections, hasLength(1));
    expect(_texts(first), isNot(contains('BBBB')));
    expect(_texts(first).where((text) => text == 'B'), hasLength(1));

    reveal = true;
    final next = _assemble(
      history: _history(13),
      window: first.historyWindow,
      expansion: expand,
      injections: const [
        PromptInjection(depth: 9, fragment: PromptFragment('A', PromptSource('note', 'a'), expandMacros: false)),
        split,
      ],
    );
    expect(next.historyWindow!.firstNodeId, 'h6');
    expect(_texts(next).where((text) => text == 'A'), hasLength(1));
    expect(_texts(next).where((text) => text == 'B'), hasLength(1));
    expect(_texts(next).where((text) => text == 'C'), hasLength(1));
    expect(_texts(next), isNot(contains('BBBB')));
    expect(
      next.excluded.where(
        (entry) => entry.reason == 'cache-friendly-window' && entry.sources.any((source) => source.id == 'b'),
      ),
      hasLength(1),
    );
  });

  test('extra trimming reuses expanded messages and old-window macros are never visited', () {
    final visits = <String>[];
    String expand(String text, Map<String, String> _) {
      if (!RegExp(r'^\{\{h\d+\}\}$').hasMatch(text)) return text;
      visits.add(text);
      return 'HHHH';
    }

    final first = _assemble(history: _history(12, macros: true), expansion: expand);
    expect(first.historyWindow!.firstNodeId, 'h6');
    expect(visits, [for (var i = 12; i >= 2; i--) '{{h$i}}']);
    visits.clear();
    final next = _assemble(history: _history(14, macros: true), window: first.historyWindow, expansion: expand);
    expect(visits, [for (var i = 14; i >= 6; i--) '{{h$i}}']);
    expect(next.historyWindow!.firstNodeId, 'h6');

    final windowed = assemblePromptWindow(
      _assembler,
      PromptInput(
        preset: _preset(),
        card: const {'name': 'Guide'},
        history: _history(14).skip(2).toList(),
        model: 'test',
        deepseek: false,
        historyWindow: first.historyWindow,
      ),
      prefix: const [
        PromptHistoryMessage(id: 'h1', role: 'user', content: ''),
        PromptHistoryMessage(id: 'h2', role: 'user', content: ''),
      ],
    );
    expect(_historyIds(windowed), _historyIds(next));
    expect(windowed.historyWindow!.firstNodeId, 'h6');
    expect(windowed.excluded.where((entry) => entry.id == 'h1' || entry.id == 'h2'), hasLength(2));
  });

  test('extra space admits no new examples and does not revive optional WI in the retained window', () {
    const card = {'name': 'Guide', 'mes_example': '<START>\nGuide: EEEE\n<START>\nGuide: NN'};
    const before = [PromptFragment('WWWW', PromptSource('world', 'optional'), trimOnOverflow: true)];
    final preset = _preset(capacity: 45);
    final history = _history(7, content: 'HHHHHHHHHH');
    final first = _assemble(history: history, preset: preset, card: card, before: before);
    expect(_texts(first), ['EEEE', 'HHHHHHHHHH', 'HHHHHHHHHH', 'HHHHHHHHHH']);
    expect(first.historyWindow!.firstNodeId, 'h5');
    expect(first.remainingBudget, 11);
    expect(first.historyWindow!.admittedExamples, {(kind: 'card', id: 'card:mes_example', block: 0)});
    expect(first.historyWindow!.excludedOptionalSources, {(kind: 'world', id: 'optional')});

    final next = _assemble(
      history: [
        ...history,
        const PromptHistoryMessage(id: 'h8', role: 'user', content: 'HH'),
      ],
      preset: preset,
      card: card,
      before: before,
      window: first.historyWindow,
    );
    expect(_texts(next), ['EEEE', 'HHHHHHHHHH', 'HHHHHHHHHH', 'HHHHHHHHHH', 'HH']);
    expect(next.historyWindow!.firstNodeId, 'h5');
    expect(next.remainingBudget, 9);
    expect(next.excluded.where((entry) => entry.reason == 'v3-ignore-on-max-context').map((entry) => entry.id), [
      'optional',
    ]);

    final pinned = _assemble(history: history, preset: preset, card: card, before: before, pinExamples: true);
    expect(_texts(pinned).take(2), ['EEEE', 'NN']);
    expect(pinned.historyWindow!.admittedExamples, {
      (kind: 'card', id: 'card:mes_example', block: 0),
      (kind: 'card', id: 'card:mes_example', block: 1),
    });
  });

  test('extra trimming keeps depth pieces, group/send controls and the continuation tail', () {
    final result = _assemble(
      preset: _preset(
        settings: {
          'new_group_chat_prompt': 'GG',
          'group_nudge_prompt': 'GN',
          'continue_nudge_prompt': 'CN',
          'send_if_empty': 'E',
        },
      ),
      history: [
        ..._history(11),
        const PromptHistoryMessage(id: 'h12', role: 'assistant', content: 'HHHH'),
      ],
      type: 'continue',
      groupNames: ['Guide', 'Other'],
      injections: const [
        PromptInjection(depth: 0, role: 'assistant', fragment: PromptFragment('D', PromptSource('note', 'depth'))),
      ],
    );
    expect(_historyIds(result), ['h7', 'h8', 'h9', 'h10', 'h11', 'h12']);
    expect(_texts(result), ['GG', 'HHHH', 'HHHH', 'HHHH', 'HHHH', 'HHHH', 'D', 'E', 'GN', 'HHHH', 'CN']);
    expect(result.historyWindow!.firstNodeId, 'h7');
    expect(result.remainingBudget, 8);
  });

  test('tool exchanges and the latest actual user stop best-effort extra trimming', () {
    final history = _history(12);
    history[2] = const PromptHistoryMessage(
      id: 'h3',
      role: 'assistant',
      content: 'TTTT',
      toolCalls: [
        {
          'id': 'call',
          'type': 'function',
          'function': {'name': 'test', 'arguments': '{}'},
        },
      ],
    );
    history[3] = const PromptHistoryMessage(id: 'h4', role: 'tool', content: 'RRRR', toolCallId: 'call');
    final toolResult = _assemble(history: history);
    expect(_historyIds(toolResult), ['h3', 'h4', 'h5', 'h6', 'h7', 'h8', 'h9', 'h10', 'h11', 'h12']);
    expect(toolResult.historyWindow!.firstNodeId, 'h3');
    expect(toolResult.remainingBudget, 0);
    expect(toolResult.beforePostProcessing.first.message['tool_calls'], history[2].toolCalls);

    final userResult = _assemble(
      history: [
        const PromptHistoryMessage(id: 'old', role: 'assistant', content: 'OLD'),
        PromptHistoryMessage(id: 'user', role: 'user', content: List.filled(35, 'U').join()),
        const PromptHistoryMessage(id: 'answer', role: 'assistant', content: 'AAAA'),
      ],
    );
    expect(_historyIds(userResult), ['user', 'answer']);
    expect(userResult.historyWindow!.firstNodeId, 'user');
    expect(userResult.remainingBudget, 1);
  });
}

final class _ContentCounter implements PromptTokenCounter {
  const _ContentCounter();
  @override
  String get name => 'synthetic content length';
  @override
  bool get exact => false;
  @override
  int countMessage(Map<String, Object?> message) => (message['content']! as String).length;
  @override
  int countText(String text) => text.length;
}
