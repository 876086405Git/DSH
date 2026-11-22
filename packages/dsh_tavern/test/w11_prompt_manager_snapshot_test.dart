import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/prompt/prompt_manager_snapshot.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart' show scriptPreset;

const _counter = EstimatedTokenCounter();

void main() {
  test('An admission exception publishes only the existing partial history, without reserved header and controls', () {
    PromptManagerSnapshot? captured;
    final input = _input(
      history: const [
        PromptHistoryMessage(id: 'physical-old', role: 'user', content: 'FAIL'),
        PromptHistoryMessage(id: 'physical-new', role: 'assistant', content: 'ADMITTED'),
      ],
      quiet: 'RESERVED QUIET',
      expand: (text, _) {
        if (text == 'FAIL') throw StateError('synthetic history expansion failure');
        return text;
      },
    );
    expect(() => PromptAssembler(onPromptManager: (snapshot) => captured = snapshot).assemble(input), throwsStateError);
    final items = captured!.items.whereType<PromptManagerCollection>().toList();
    expect(items.any((item) => item.identifier == 'controlPrompts'), isFalse);
    final history = items.singleWhere((item) => item.identifier == 'chatHistory');
    expect(history.messages.map((message) => message.identifier), ['chatHistory-2']);
    expect(history.messages.map((message) => message.segment.message['content']), ['ADMITTED']);
    expect(history.messages.single.segment.sources.single.id, 'physical-new');
  });

  test('Prepare failure publishes initialized empty root and callback does not replay token or macro work', () {
    PromptManagerSnapshot? empty;
    expect(
      () => PromptAssembler(onPromptManager: (snapshot) => empty = snapshot).assemble(
        _input(
          expand: (text, _) {
            if (text == 'MAIN') throw StateError('synthetic prepare failure');
            return text;
          },
        ),
      ),
      throwsStateError,
    );
    expect(empty!.items, isEmpty);
    final traces = <List<String>>[];
    for (final capture in [false, true]) {
      final calls = <String>[];
      final counter = CallbackTokenCounter(
        name: 'recording pure fixture',
        exact: true,
        text: (text) {
          calls.add('text:$text');
          return text.length;
        },
        message: (message) {
          calls.add('message:$message');
          return _counter.countMessage(message);
        },
      );
      PromptAssembler(counter: counter, onPromptManager: capture ? (_) {} : null).assemble(
        _input(
          systemSquash: true,
          expand: (text, _) {
            calls.add('expand:$text');
            return text;
          },
        ),
      );
      traces.add(calls);
    }
    expect(traces.last, traces.first);
  });

  test('The stored snapshot is detached from subsequent wire mutation and preserves logical IDs', () {
    final message = <String, Object?>{
      'role': 'user',
      'content': 'ORIGINAL',
      'tool_calls': <Object?>[
        {'id': 'call'},
      ],
    };
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('chatHistory', [
        PromptManagerMessage(
          PromptSegment(
            id: 'physical-node',
            message: message,
            sources: const [PromptSource('history', 'physical-node')],
            tokens: 7,
          ),
          identifier: 'chatHistory-7',
        ),
      ]),
    ]);
    message['content'] = 'MUTATED';
    (message['tool_calls']! as List<Object?>).clear();
    final stored = (snapshot.items.single as PromptManagerCollection).messages.single;
    expect(stored.segment.message['content'], 'ORIGINAL');
    expect(stored.segment.message['tool_calls'], [
      {'id': 'call'},
    ]);
    expect(stored.identifier, 'chatHistory-7');
    expect(stored.segment.id, 'physical-node');
    final wire = stored.serialize(_counter, direct: false);
    (wire.message['tool_calls']! as List<Object?>).clear();
    expect(stored.segment.message['tool_calls'], [
      {'id': 'call'},
    ]);
  });

  test('Collection and flattened direct serialization keep the fixed signature truthiness difference', () async {
    final metadata = _message('main', 'system', 'BODY', fields: {'signature': '', 'reasoning': ''});
    final collection = PromptManagerSnapshot([
      PromptManagerCollection('main', [metadata]),
    ]);
    final before = await _squash(collection);
    final after = await _squash(collection.squashSystems());
    expect(before.single.message, {'role': 'system', 'content': 'BODY'});
    expect(after.single.message, {'role': 'system', 'content': 'BODY', 'signature': '', 'reasoning': ''});
    final tool = PromptManagerSnapshot([
      PromptManagerCollection('tools', [_message('tool-call-id', 'tool', 'RESULT')]),
    ]);
    expect((await _squash(tool)).single.message['tool_call_id'], 'tool-call-id');
  });

  for (final systemSquash in [false, true]) {
    test(
      'The fixed source topology distinguishes history, protected headers, continuation and controls: $systemSquash',
      () async {
        var snapshot = PromptManagerSnapshot([
          PromptManagerCollection('main', [_message('main', 'system', 'MAIN')]),
          PromptManagerCollection('dialogueExamples', [_message('newChat', 'system', 'EXAMPLE HEADER')]),
          PromptManagerCollection('chatHistory', [
            _message('newMainChat', 'system', 'CHAT HEADER'),
            _message('chatHistory-1', 'user', 'H1'),
            _message('chatHistory-2', 'system', 'DEPTH'),
            _message('chatHistory-3', 'assistant', 'H2'),
            _message('groupNudge', 'system', 'GROUP NUDGE'),
          ]),
          PromptManagerCollection('continueNudge', [
            _message('continued-explicit', 'assistant', 'CONTINUED'),
            _message('continueNudge', 'system', 'NUDGE'),
          ]),
          PromptManagerCollection('controlPrompts', [_message('quietPrompt', 'system', 'QUIET')]),
        ]);
        if (systemSquash) snapshot = snapshot.squashSystems();
        final output = await _squash(snapshot);
        expect(
          output.map((message) => message.message['content']),
          systemSquash
              ? [
                  'MAIN',
                  'EXAMPLE HEADER',
                  'CHAT HEADER',
                  'U[H1]S[DEPTH]A[H2]',
                  'GROUP NUDGE',
                  'CONTINUED',
                  'NUDGE\nQUIET',
                ]
              : [
                  'MAIN',
                  'EXAMPLE HEADER',
                  'S[CHAT HEADER]U[H1]S[DEPTH]A[H2]S[GROUP NUDGE]',
                  'CONTINUED',
                  'NUDGE',
                  'QUIET',
                ],
        );
      },
    );
  }
}

PromptInput _input({
  List<PromptHistoryMessage> history = const [PromptHistoryMessage(id: 'node', role: 'user', content: 'INPUT')],
  String quiet = '',
  PromptExpansion? expand,
  bool systemSquash = false,
}) => PromptInput(
  preset: ChatPreset({
    ...scriptPreset(main: 'MAIN').raw,
    'new_chat_prompt': 'HEADER',
    'squash_system_messages': systemSquash,
  }),
  card: const {'name': 'Character'},
  history: history,
  model: 'fixture',
  deepseek: false,
  quietPrompt: quiet,
  expansion: expand,
);

PromptManagerMessage _message(String id, String role, String content, {Map<String, Object?> fields = const {}}) =>
    PromptManagerMessage(
      PromptSegment(
        id: id,
        message: {'role': role, 'content': content, ...fields},
        sources: [PromptSource('synthetic', id)],
        tokens: 1,
      ),
      identifier: id,
    );

Future<List<PromptSegment>> _squash(PromptManagerSnapshot snapshot) => spresetSquashSegments(
  [
    for (final item in snapshot.items)
      if (item is PromptManagerMessage)
        item.serialize(_counter, direct: true, collectionId: item.collectionIdentifier)
      else if (item is PromptManagerCollection)
        for (final message in item.messages) message.serialize(_counter, direct: false, collectionId: item.identifier),
  ],
  SPresetConfig.fromPreset({
    'extensions': {
      'SPreset': {
        'ChatSquash': {
          'enabled': true,
          'separate_chat_history': true,
          'role': 'assistant',
          'user_prefix': 'U[',
          'user_suffix': ']',
          'char_prefix': 'A[',
          'char_suffix': ']',
          'prefix_system': 'S[',
          'suffix_system': ']',
        },
      },
    },
  }),
  _counter,
  expand: (text) => text,
  evaluate:
      (
        stage,
        source,
        arguments, {
        identifier,
        sessionId,
        reset = false,
        kind = TavernSPresetEvaluationKind.functionExpression,
      }) => throw StateError('No script evaluation expected.'),
  diagnose: (stage, error) => throw StateError('Unexpected $stage: $error'),
  readPromptManager: () => snapshot,
);
