import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/prompt/prompt_manager_snapshot.dart';
import 'package:test/test.dart';

const _counter = EstimatedTokenCounter();

// ADD14 deliberately fixes these upstream edge cases. The fixed-source
// controls remain separate evidence; these are the requested wire contracts.
void main() {
  test('An empty tool result survives separate history while empty ordinary text does not', () async {
    final current = [
      _segment(
        'call-row',
        'assistant',
        '',
        fields: {
          'tool_calls': [
            {
              'id': 'call',
              'type': 'function',
              'function': {'name': 'look', 'arguments': '{}'},
            },
          ],
        },
      ),
      _segment('result-row', 'tool', '', fields: {'tool_call_id': 'call'}),
      _segment('empty-row', 'user', ''),
    ];
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('chatHistory', [
        for (final segment in current)
          PromptManagerMessage(segment, identifier: segment.message['tool_call_id'] as String? ?? segment.id),
      ]),
    ]);
    final output = await _squash(current, snapshot);
    expect(output, hasLength(2));
    expect(output.first.message['tool_calls'], current.first.message['tool_calls']);
    expect(output.last.message, {'role': 'tool', 'content': '', 'tool_call_id': 'call'});
  });

  test('Current one-to-many MessageInjections retain the complete exchange and real result id', () async {
    final original = _segment('main', 'system', 'MAIN');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('main', [PromptManagerMessage(original, identifier: 'main')]),
    ]);
    final config = SPresetConfig.fromPreset({
      'extensions': {
        'SPreset': {
          'MessageInjections': {
            'main': {
              'enabled': true,
              'reasoning': 'CURRENT REASONING',
              'signature': '',
              'toolCalls': [
                {'id': 'injected', 'name': 'look', 'arguments': '{}'},
              ],
              'toolResults': [
                {'toolCallId': 'injected', 'content': ''},
              ],
            },
          },
        },
      },
    });
    final current = spresetInjectSegments(
      [original],
      config,
      const SPresetProvider(source: 'custom', model: 'fixture'),
      _counter,
    );
    expect(current, hasLength(2));
    expect(current.map((segment) => segment.id).toSet(), {'main'});
    final output = await _squash(current, snapshot);
    expect(output.map((segment) => segment.message), current.map((segment) => segment.message));
    expect(output.last.message['tool_call_id'], 'injected');
  });

  test('Separate history uses the current image parts instead of its earlier marker', () async {
    final old = _segment('image-row', 'user', 'OLD PRIVATE IMAGE MARKER');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('chatHistory', [PromptManagerMessage(old, identifier: 'chatHistory-1')]),
    ]);
    final current = _segment('image-row', 'user', [
      {'type': 'text', 'text': 'CURRENT'},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AA=='},
      },
    ]);
    final output = await _squash([current], snapshot);
    expect(output.single.message, current.message);
    expect(old.message['content'], 'OLD PRIVATE IMAGE MARKER');
  });

  test('Current DeepSeek MessageInjections reasoning survives topology replay', () async {
    final original = _segment('main', 'system', 'MAIN');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('main', [PromptManagerMessage(original, identifier: 'main')]),
    ]);
    final config = SPresetConfig.fromPreset({
      'extensions': {
        'SPreset': {
          'MessageInjections': {
            'main': {
              'enabled': true,
              'reasoning': 'CURRENT DEEPSEEK REASONING',
              'signature': '',
              'toolCalls': [
                {'id': 'deep-call', 'name': 'look', 'arguments': '{}'},
              ],
              'toolResults': [
                {'toolCallId': 'deep-call', 'content': ''},
              ],
            },
          },
        },
      },
    });
    final current = spresetInjectSegments(
      [original],
      config,
      const SPresetProvider(source: 'deepseek', model: 'fixture'),
      _counter,
    );
    expect(current.first.message['reasoning_content'], 'CURRENT DEEPSEEK REASONING');
    final output = await _squash(current, snapshot);
    expect(output.map((segment) => segment.message), current.map((segment) => segment.message));
  });

  test('Current reasoning-only injection is structured payload rather than empty ordinary text', () async {
    final original = _segment('reasoning-only', 'system', '\u200b');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('reasoning-only', [PromptManagerMessage(original, identifier: 'reasoning-only')]),
    ]);
    final config = SPresetConfig.fromPreset({
      'extensions': {
        'SPreset': {
          'MessageInjections': {
            'reasoning-only': {
              'enabled': true,
              'reasoning': 'CURRENT REASONING ONLY',
              'signature': '',
              'toolCalls': <Object?>[],
              'toolResults': <Object?>[],
            },
          },
        },
      },
    });
    final current = spresetInjectSegments(
      [original],
      config,
      const SPresetProvider(source: 'deepseek', model: 'fixture'),
      _counter,
    );
    expect(current.single.message, {'role': 'assistant', 'content': '', 'reasoning_content': 'CURRENT REASONING ONLY'});
    final output = await _squash(current, snapshot);
    expect(output.map((segment) => segment.message), current.map((segment) => segment.message));
  });

  test('System flattening retains an injected sibling whose old system text had merged away', () async {
    final a = _segment('a', 'system', 'A');
    final b = _segment('b', 'system', 'B');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('a', [PromptManagerMessage(a, identifier: 'a')]),
      PromptManagerCollection('b', [PromptManagerMessage(b, identifier: 'b')]),
    ]).squashSystems();
    expect(snapshot.items, hasLength(1));
    final current = [
      a,
      _segment(
        'b',
        'assistant',
        'B',
        fields: {
          'tool_calls': [
            {
              'id': 'b-call',
              'type': 'function',
              'function': {'name': 'look', 'arguments': '{}'},
            },
          ],
        },
      ),
      _segment('b', 'tool', 'B RESULT', fields: {'tool_call_id': 'b-call'}),
    ];
    final output = await _squash(current, snapshot);
    expect(output.map((segment) => segment.message), current.map((segment) => segment.message));
  });

  test('The squash postprocessor receives current content with the conditional tag already removed', () async {
    final old = _segment('history-row', 'user', 'STALE [[GO]]');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('chatHistory', [PromptManagerMessage(old, identifier: 'chatHistory-1')]),
    ]);
    final seen = <Object?>[];
    final output = await _squash(
      [_segment('history-row', 'user', 'CURRENT [[GO]]')],
      snapshot,
      settings: {
        'conditional_enabled': true,
        'conditional_tag': '[[GO]]',
        'squashed_post_script_enable': true,
        'squashed_post_script': '(text) => text',
      },
      onScript: (value) {
        seen.add(value);
        return value;
      },
    );
    expect(seen, ['U[CURRENT ]']);
    expect(output.single.message['content'], 'U[CURRENT ]');
    expect(old.message['content'], 'STALE [[GO]]');
  });

  test('Flattened continuation keeps its tail membership without inventing a logical identifier', () async {
    final history = _segment('history-row', 'user', 'HISTORY');
    final tail = _segment('physical-continued', 'assistant', 'CONTINUED');
    final nudge = _segment('continueNudge', 'system', 'NUDGE');
    final snapshot = PromptManagerSnapshot([
      PromptManagerCollection('chatHistory', [PromptManagerMessage(history, identifier: 'chatHistory-1')]),
      PromptManagerCollection('continueNudge', [
        PromptManagerMessage(tail, identifier: null),
        PromptManagerMessage(nudge, identifier: 'continueNudge'),
      ]),
    ]).squashSystems();
    expect(snapshot.items.whereType<PromptManagerMessage>().elementAt(1).identifier, isNull);
    final output = await _squash([history, tail, nudge], snapshot);
    expect(output.map((segment) => segment.message), [
      {'role': 'assistant', 'content': 'U[HISTORY]'},
      {'role': 'assistant', 'content': 'CONTINUED'},
      {'role': 'system', 'content': 'NUDGE'},
    ]);
  });
}

PromptSegment _segment(String id, String role, Object? content, {Map<String, Object?> fields = const {}}) =>
    PromptSegment(
      id: id,
      message: {'role': role, 'content': content, ...fields},
      sources: [PromptSource('synthetic', id)],
      tokens: 1,
    );

Future<List<PromptSegment>> _squash(
  List<PromptSegment> input,
  PromptManagerSnapshot snapshot, {
  Map<String, Object?> settings = const {},
  Object? Function(Object? value)? onScript,
}) => spresetSquashSegments(
  input,
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
          ...settings,
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
      }) async {
        if (onScript == null) throw StateError('Unexpected script evaluation.');
        return TavernSPresetEvaluationResult(requestId: 'fixture', value: onScript(arguments.single));
      },
  diagnose: (stage, error) => throw StateError('Unexpected $stage: $error'),
  readPromptManager: () => snapshot,
);
