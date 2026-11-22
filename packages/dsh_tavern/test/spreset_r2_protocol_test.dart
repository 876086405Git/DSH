import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_protocol_test.dart' as fixture;
import 'support/t24_engine_harness.dart' show t24Preset;

Map<String, Object?> _legacyPreset() {
  final raw = t24Preset().raw;
  raw['stream_openai'] = false;
  raw.remove('extensions');
  (raw['prompts']! as List<Object?>).add({
    'identifier': 'regexes-bindings',
    'content': jsonEncode([
      {
        'id': 'legacy',
        'scriptName': 'Legacy only',
        'findRegex': '/LEGACY/g',
        'replaceString': 'BOUND',
        'placement': [1],
        'promptOnly': true,
        'markdownOnly': false,
        'disabled': false,
      },
    ]),
  });
  return raw;
}

void main() {
  test('legacy-only regex rules preserve native priority, explicit external bypass and absent-module semantics', () {
    final raw = _legacyPreset();
    final config = SPresetConfig.fromPreset(raw);
    expect(config.present, isFalse);
    expect(config.presetRegexes(raw).map((rule) => rule['id']), ['legacy']);
    expect(spresetRegexOrder(config, {}), [0, 2, 1]);
    expect(config.macroNest, isFalse);
    final external = SPresetConfig.fromPreset({...raw, 'dsh_spreset_runtime': 'external'});
    // Runtime selection belongs to the configuration, even when the caller's
    // retained raw preset has no synthetic dsh_spreset_runtime field.
    expect(external.presetRegexes(raw), isEmpty);
    final native = {
      ...raw,
      'extensions': {
        'regex_scripts': [
          {'id': 'native'},
        ],
      },
    };
    expect(SPresetConfig.fromPreset(native).presetRegexes(native), [
      {'id': 'native'},
    ]);
    expect(external.presetRegexes(native), [
      {'id': 'native'},
    ]);
    final malformed = {
      'prompts': [
        {'identifier': 'regexes-bindings', 'content': 'bad json'},
      ],
    };
    expect(() => SPresetConfig.fromPreset(malformed).presetRegexes(malformed), throwsFormatException);
  });

  for (final external in [false, true]) {
    test('legacy-only regex reaches actual prompt HTTP with external=$external', () async {
      final h = await generationFixture();
      final card = await h.card('Legacy regex');
      final chat = await h.engine.createChat(card);
      await h.engine.setPreset(ChatPreset(_legacyPreset()));
      if (external) await h.engine.setSettings({'spresetRuntimeMode': 'external'});
      h.reply('done');
      final events = await h.engine.send(chat, 'LEGACY').toList();
      expect(events.whereType<TavernTurnFailed>(), isEmpty);
      final messages = generationMessages(h.requests.single);
      expect(messages.where((message) => message['role'] == 'user').last['content'], external ? 'LEGACY' : 'BOUND');
    });
  }

  for (final firstRole in ['tool', 'user', 'assistant', 'system']) {
    test('follow preserves tool results and a valid target when the initial role is $firstRole', () async {
      final e = fixture.Evaluator();
      final tool = fixture.segment(
        'result',
        'tool',
        '<|no-trans|>SEPtool result',
        collection: 'chatHistory',
        extra: {
          'tool_call_id': 'call-1',
          'provider_extension': {'signature': 'keep'},
        },
      );
      final input = <PromptSegment>[
        if (firstRole != 'tool') fixture.segment('before', firstRole, 'before', collection: 'chatHistory'),
        tool,
        fixture.segment('after', 'user', 'after', collection: 'chatHistory'),
      ];
      final result = await spresetSquashSegments(
        input,
        fixture.config({
          'ChatSquash': {
            'enabled': true,
            'role': 'follow',
            'parse_clewd': true,
            'enable_squashed_separator': true,
            'squashed_separator_string': 'SEP',
            'user_prefix': 'U:',
            'char_prefix': 'A:',
            'prefix_system': 'S:',
          },
        }),
        fixture.counter,
        expand: (text) => text,
        evaluate: e.call,
        diagnose: e.diagnose,
      );
      final retained = result.singleWhere((part) => part.id == 'result');
      expect(retained.message, tool.message);
      expect(retained.collectionId, 'chatHistory');
      expect(retained.sources, tool.sources);
      expect(result.last.message, {'role': firstRole == 'tool' ? 'user' : firstRole, 'content': '\n\nU:after'});
      expect(result.where((part) => part.message['role'] == 'tool'), hasLength(1));
      expect(e.calls, isEmpty);
      expect(e.issues, isEmpty);
    });
  }

  test('follow still updates after a native assistant call boundary', () async {
    final e = fixture.Evaluator();
    final input = [
      fixture.segment('before', 'system', 'before'),
      fixture.segment(
        'assistant-call',
        'assistant',
        '',
        extra: {
          'tool_calls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {'name': 'f', 'arguments': '{}'},
            },
          ],
        },
      ),
      fixture.segment('tool', 'tool', 'value', extra: {'tool_call_id': 'call-1'}),
      fixture.segment('after', 'user', 'after'),
    ];
    final result = await spresetSquashSegments(
      input,
      fixture.config({
        'ChatSquash': {'enabled': true, 'role': 'follow', 'parse_clewd': false, 'user_prefix': 'U:'},
      }),
      fixture.counter,
      expand: (text) => text,
      evaluate: e.call,
      diagnose: e.diagnose,
    );
    expect(result.last.message, {'role': 'assistant', 'content': 'U:after'});
    expect(result[1].message, input[1].message);
    expect(result[2].message, input[2].message);
  });
}
