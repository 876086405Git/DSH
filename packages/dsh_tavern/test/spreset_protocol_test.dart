import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

SPresetConfig config(Map<String, Object?> value) => SPresetConfig.fromPreset({
  'extensions': {'SPreset': value},
});
const counter = EstimatedTokenCounter();
const provider = SPresetProvider(source: 'custom', model: 'fixture');
PromptSegment segment(
  String id,
  String role,
  Object? content, {
  String? collection,
  Map<String, Object?> extra = const {},
}) => PromptSegment(
  id: id,
  message: {'role': role, 'content': content, ...extra},
  sources: [PromptSource('fixture', id)],
  collectionId: collection,
  tokens: 1,
);

class Evaluator {
  final calls = <Map<String, Object?>>[];
  final issues = <String>[];
  TavernSPresetEvaluationResult Function(String, List<Object?>)? handler;
  Future<TavernSPresetEvaluationResult> call(
    String stage,
    String source,
    List<Object?> arguments, {
    String? identifier,
    String? sessionId,
    bool reset = false,
    TavernSPresetEvaluationKind kind = TavernSPresetEvaluationKind.functionExpression,
  }) async {
    calls.add({
      'stage': stage,
      'source': source,
      'arguments': arguments,
      'sessionId': sessionId,
      'reset': reset,
      'kind': kind.name,
    });
    return handler?.call(stage, arguments) ??
        TavernSPresetEvaluationResult(requestId: 'fixture', value: arguments.firstOrNull);
  }

  void diagnose(String stage, Object error) {
    issues.add(stage);
  }
}

void main() {
  test('empty legacy settings and regex bindings are defaults while nonempty malformed JSON still fails', () {
    final raw = <String, Object?>{
      'prompts': [
        {'identifier': 'SPresetSettings', 'content': ''},
        {'identifier': 'regexes-bindings', 'content': ''},
      ],
    };
    final legacy = SPresetConfig.fromPreset(raw);
    expect(legacy.present, isTrue);
    expect(legacy.presetRegexes(raw), isEmpty);
    expect(legacy.macroNest, isFalse);
    expect(
      () => SPresetConfig.fromPreset({
        'prompts': [
          {'identifier': 'SPresetSettings', 'content': ' '},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => legacy.presetRegexes({
        'prompts': [
          {'identifier': 'regexes-bindings', 'content': ' '},
        ],
      }),
      throwsFormatException,
    );
  });

  test('runtime identity is the complete public loader, including parent-page insertion', () {
    final source = File('test/fixtures/spreset/bootstrap.js').readAsStringSync();
    expect(isSPresetBootstrap(source), isTrue);
    expect(isSPresetBootstrap(source.replaceAll("'", '"').replaceAll('\n', '\r\n')), isTrue);
    expect(isSPresetBootstrap(source.replaceAll('jnai2d9kgnbs6xzx5c.com', 'starowo.github.io')), isTrue);
    expect(isSPresetBootstrap(source.replaceAll('jnai2d9kgnbs6xzx5c.com', 'unrelated.example')), isFalse);
    expect(isSPresetBootstrap('const url="https://jnai2d9kgnbs6xzx5c.com/regex_bind/inject.js";'), isFalse);
    expect(isSPresetBootstrap('const cited = ${jsonEncode(source)};'), isFalse);
    expect(isSPresetBootstrap('$source\nrunOtherApplication();'), isFalse);
    expect(spresetScriptSkipReason(source), contains('native'));
    expect(spresetScriptSkipReason(source, runtimeMode: 'external'), isNull);
  });

  test('MacroNest is innermost-leftmost and protects produced braces', () {
    final order = <String>[];
    final result = spresetExpandNested('{{getvar::{{name}}}} {{made}}', (value) {
      order.add(value);
      return switch (value) {
        '{{name}}' => 'slot',
        '{{getvar::slot}}' => 'V',
        '{{made}}' => '{{notReplayed}}',
        _ => value,
      };
    });
    expect(order, ['{{name}}', '{{getvar::slot}}', '{{made}}']);
    expect(result, 'V {{notReplayed}}');
  });

  test('MacroNest native runtime primes once, even on plain text, and keeps side effects', () {
    final runtime = SPresetMacroNestRuntime();
    var count = 0;
    String expand(String value) {
      count++;
      return value.replaceAll('{{n}}', '$count');
    }

    expect(runtime.expand('plain', expand), 'plain');
    expect(count, 1);
    expect(runtime.expand('{{n}}', expand), '2');
    expect(runtime.expand('{{n}}', expand), '3');
    final second = SPresetMacroNestRuntime();
    expect(second.expand('{{n}}', expand), '5');
    expect(count, 5);
  });

  test('MacroNest rescans closing braces formed by a replacement and matches the source step boundary', () {
    final calls = <String>[];
    expect(
      spresetExpandNested('{{x}{{empty}}}', (text) {
        calls.add(text);
        return switch (text) {
          '{{empty}}' => '',
          '{{x}}' => 'V',
          _ => text,
        };
      }),
      'V',
    );
    expect(calls, ['{{empty}}', '{{x}}']);
    final atLimit = 'x' * 1000000;
    expect(spresetExpandNested(atLimit, (text) => text), atLimit);
    expect(() => spresetExpandNested('${atLimit}x', (text) => text), throwsA(isA<SPresetException>()));
  });

  test('binding precedence and scope order preserve no-extension behavior', () {
    final raw = {
      'extensions': {
        'SPreset': {
          'RegexBinding': {
            'regexes': [
              {'id': 'bound'},
            ],
          },
        },
        'regex_scripts': [
          {'id': 'native'},
        ],
      },
    };
    final binding = SPresetConfig.fromPreset(raw);
    expect(binding.presetRegexes(raw).single['id'], 'native');
    expect(spresetRegexOrder(binding, {}), [2, 0, 1]);
    expect(
      spresetRegexOrder(binding, {
        'SPreset': {
          'RegexBinding': {
            'activationOrder': [0.0, 2, 1],
          },
        },
      }),
      [0, 2, 1],
    );
    expect(
      spresetRegexOrder(binding, {
        'SPreset': {
          'RegexBinding': {
            'activationOrder': [1, 2, 0],
          },
        },
      }),
      [1, 2, 0],
    );
    expect(spresetRegexOrder(SPresetConfig.fromPreset({}), {}), [0, 2, 1]);
    expect(SPresetConfig.fromPreset({...raw, 'dsh_spreset_runtime': 'external'}).present, isFalse);
    final legacy = {
      'extensions': {'SPreset': <String, Object?>{}},
      'prompts': [
        {'identifier': 'regexes-bindings', 'content': '[{"id":"legacy"}]'},
      ],
      'prompt_order': [
        <String, Object?>{},
        {
          'xiaobai_ext': {
            'regexBindings': {
              'scripts': [
                {'id': 'legacy'},
                {'id': 'xiaobai'},
              ],
            },
          },
        },
      ],
    };
    expect(SPresetConfig.fromPreset(legacy).presetRegexes(legacy).map((item) => item['id']), ['legacy', 'xiaobai']);
    final globals = [
      {'id': 'ordinary'},
      {'id': 'preset_old'},
      {'id': 'named', 'scriptName': '[s] duplicate'},
      {'id': 'flagged', 'preset-regex': true},
    ];
    expect(spresetGlobalRegexes(globals, binding).map((item) => item['id']), ['ordinary']);
    expect(spresetGlobalRegexes(globals, SPresetConfig.fromPreset({})), globals);
    expect(
      config({
        'ForcedPostProcessing': {'enabled': true, 'mode': 'claude'},
      }).forcedPostProcessing,
      'merge',
    );
    expect(
      config({
        'ForcedPostProcessing': {'enabled': true, 'mode': 'unknown'},
      }).forcedPostProcessing,
      isNull,
    );
  });

  test('MacroNest empty content does not prime and a recursive failure keeps the successful constructor probe', () {
    final runtime = SPresetMacroNestRuntime();
    final calls = <String>[];
    String normal(String value) {
      calls.add(value);
      return value;
    }

    expect(runtime.expand('', normal), '');
    expect(runtime.expand('plain', normal), 'plain');
    expect(calls, ['', 'plain']);
    final failed = SPresetMacroNestRuntime();
    var count = 0;
    String sometimes(String value) {
      if (++count == 2) throw StateError('recursive pass');
      return value;
    }

    expect(() => failed.expand('{{x}}', sometimes), throwsStateError);
    expect(failed.expand('{{x}}', sometimes), '{{x}}');
    expect(count, 3);
  });

  test(
    'ChatSquash Promise-valued array postprocessor uses synchronous evaluation and restores original data',
    () async {
      final e = Evaluator();
      e.handler = (_, args) => TavernSPresetEvaluationResult(
        requestId: 'fixture',
        value: <String, Object?>{},
        arguments: [
          [
            {'role': 'user', 'content': 'mutation before Promise resolution'},
          ],
        ],
      );
      final result = await spresetSquashSegments(
        [segment('one', 'user', 'original')],
        config({
          'ChatSquash': {
            'enabled': false,
            'squashed_post_script_enable': true,
            'squashed_post_script': 'async messages => messages',
          },
        }),
        counter,
        expand: (text) => text,
        evaluate: e.call,
        diagnose: e.diagnose,
      );
      expect(result.single.message['content'], 'original');
      expect(e.calls.single['kind'], 'syncFunctionExpression');
      expect(e.issues, ['ChatSquash']);
    },
  );

  test('structured messages preserve empty placeholders, tool results, reasoning and provider shapes', () {
    final binding = {
      'enabled': true,
      'reasoning': 'thought',
      'signature': 'sig',
      'toolCalls': [
        {'id': 't', 'name': 'look', 'arguments': '{"q":"x"}'},
      ],
      'toolResults': [
        {
          'toolCallId': 't',
          'content': {'ok': true},
          'isError': true,
        },
      ],
    };
    final original = {'role': 'system', 'content': '\u200b'};
    final deep = spresetInjectMessage(original, binding, const SPresetProvider(source: 'deepseek', model: 'd'));
    expect(deep.first['role'], 'assistant');
    expect(deep.first['reasoning_content'], 'thought');
    expect(deep.first.containsKey('signature'), isFalse);
    expect(deep.last, {'role': 'tool', 'tool_call_id': 't', 'content': '{"ok":true}'});
    final open = spresetInjectMessage(original, binding, provider);
    expect(open.first.containsKey('reasoning'), isFalse);
    final claude = spresetInjectMessage(original, binding, const SPresetProvider(source: 'claude', model: 'c'));
    expect((claude.first['content']! as List).first, {'type': 'thinking', 'thinking': 'thought', 'signature': 'sig'});
    expect(claude.last['role'], 'user');
    final onlyResult = spresetInjectMessage(original, {
      ...binding,
      'reasoning': '',
      'signature': '',
      'toolCalls': [],
    }, provider);
    expect(onlyResult, [open.last]);
    final source = [segment('p', 'system', '\u200b', collection: 'chatHistory')];
    final converted = spresetInjectSegments(
      source,
      config({
        'MessageInjections': {'p': binding},
      }),
      provider,
      counter,
    );
    expect(converted.every((item) => item.collectionId == 'chatHistory'), isTrue);
  });

  test('ChatSquash only history retains media and tool boundaries and collection provenance', () async {
    final e = Evaluator();
    final input = [
      segment('outside', 'system', 'keep', collection: 'main'),
      segment('h1', 'user', 'one', collection: 'chatHistory'),
      segment('h2', 'assistant', 'two', collection: 'chatHistory'),
      segment('media', 'user', [
        {
          'type': 'image_url',
          'image_url': {'url': 'data:x'},
        },
      ], collection: 'chatHistory'),
      segment('h3', 'assistant', 'three', collection: 'chatHistory'),
    ];
    final output = await spresetSquashSegments(
      input,
      config({
        'ChatSquash': {
          'enabled': true,
          'parse_clewd': false,
          'separate_chat_history': true,
          'user_prefix': 'U:',
          'char_prefix': 'A:',
          'role': 'user',
        },
      }),
      counter,
      expand: (text) => text,
      evaluate: e.call,
      diagnose: e.diagnose,
    );
    expect(output.map((item) => item.message['content']), [
      'keep',
      'U:oneA:two',
      input[3].message['content'],
      'A:three',
    ]);
    expect(output[1].collectionId, 'chatHistory');
    expect(output[2].message, input[3].message);
    expect(e.calls, isEmpty);
  });

  test('disabled squash still runs array post-script, undefined mutation and failure fallback', () async {
    final e = Evaluator();
    e.handler = (_, arguments) {
      final rows = arguments.single! as List<Object?>;
      (rows.single! as Map<String, Object?>)['content'] = 'changed';
      return TavernSPresetEvaluationResult(requestId: 'fixture', isUndefined: true, arguments: arguments);
    };
    final cfg = config({
      'ChatSquash': {'squashed_post_script_enable': true, 'squashed_post_script': 'fn'},
    });
    final output = await spresetSquashSegments(
      [segment('p', 'user', 'before')],
      cfg,
      counter,
      expand: (text) => text,
      evaluate: e.call,
      diagnose: e.diagnose,
    );
    expect(output.single.message['content'], 'changed');
    expect(e.calls.single['reset'], isTrue);
    e.handler = (_, _) => throw StateError('fixture');
    final fallback = await spresetSquashSegments(
      [segment('p', 'user', 'before')],
      cfg,
      counter,
      expand: (text) => text,
      evaluate: e.call,
      diagnose: e.diagnose,
    );
    expect(fallback.single.message['content'], 'before');
    expect(e.issues, ['ChatSquash']);
  });

  test('conditional squash only consumes tags in content and stop strings append after dedup', () async {
    final e = Evaluator();
    final cfg = config({
      'ChatSquash': {
        'enabled': true,
        'conditional_enabled': true,
        'conditional_tag': '<yes>',
        'parse_clewd': false,
        'enable_stop_string': true,
        'stop_string': '["END","STOP"]',
      },
    });
    final plain = [segment('x', 'user', 'no')];
    expect(
      await spresetSquashSegments(plain, cfg, counter, expand: (s) => s, evaluate: e.call, diagnose: e.diagnose),
      same(plain),
    );
    final out = await spresetSquashSegments(
      [segment('x', 'user', '<yes>ok')],
      cfg,
      counter,
      expand: (s) => s,
      evaluate: e.call,
      diagnose: e.diagnose,
    );
    expect(out.single.message['content'], '\n\nUser:ok');
    expect(spresetStops(cfg, ['END', 'A']), ['A', 'END', 'STOP']);
  });

  test('output sessions preserve hold/state, flush EOF and reset on cumulative revision', () async {
    final e = Evaluator();
    e.handler = (_, arguments) {
      final arg = arguments.single! as Map<String, Object?>;
      final buffer = arg['buffer']! as String;
      final split = buffer.endsWith('\\') && arg['final'] != true;
      return TavernSPresetEvaluationResult(
        requestId: 'fixture',
        value: {
          'output': split ? buffer.substring(0, buffer.length - 1) : buffer,
          'hold': split ? '\\' : '',
          'state': {'n': e.calls.length},
        },
      );
    };
    final session = SPresetOutputSession(
      script: 'fn',
      evaluate: e.call,
      diagnose: e.diagnose,
      stream: true,
      sessionId: 's',
    );
    expect(await session.updateCumulative('a\\'), 'a');
    expect(await session.updateCumulative('a\\b'), 'a\\b');
    expect((e.calls[1]['arguments']! as List).single['state'], {'n': 1});
    expect(await session.updateCumulative('new'), 'new');
    expect(e.calls.last['reset'], isTrue);
    expect(await session.finish(), 'new');
    e.handler = (_, _) => throw StateError('fixture');
    expect(await session.updateCumulative('new!'), 'new!');
    expect(session.failed, isTrue);
    final count = e.calls.length;
    expect(await session.updateCumulative('new!?'), 'new!?');
    expect(e.calls.length, count);
  });

  test('final request supports mutation and forbids stream/source changes', () async {
    final e = Evaluator();
    e.handler = (_, arguments) {
      final input = arguments.single! as Map<String, Object?>;
      (input['request']! as Map<String, Object?>)['model'] = 'changed';
      return TavernSPresetEvaluationResult(requestId: 'fixture', isUndefined: true, arguments: arguments);
    };
    final cfg = config({
      'FinalRequestProcessing': {'enabled': true, 'script': 'fn'},
    });
    final body = {'model': 'original', 'stream': true, 'messages': <Object?>[]};
    expect((await spresetFinalRequest(cfg, body, provider, e.call))['model'], 'changed');
    expect(body['model'], 'original');
    e.handler = (_, arguments) =>
        TavernSPresetEvaluationResult(requestId: 'fixture', value: {...body, 'stream': false});
    expect(() => spresetFinalRequest(cfg, body, provider, e.call), throwsA(isA<SPresetException>()));
  });

  test('fixed name fallback and ST filename normalization', () {
    final raw = {
      'extensions': {
        'SPreset': {'FixedPresetName': ''},
      },
      'prompts': [
        {'identifier': 'SPresetSettings', 'content': '{"FixedPresetName":"café:name"}'},
        {'identifier': 'SPresetSettings', 'content': '{"FixedPresetName":"shadow","keep":1}'},
      ],
    };
    expect(spresetFixedPresetName(raw), 'café:name');
    expect(spresetSanitizedPresetName(spresetFixedPresetName(raw)), 'caféname');
    expect(spresetSanitizedPresetName('CON.txt'), '');
    expect(utf8.encode(spresetSanitizedPresetName('汉' * 100)).length, 255);
    clearSPresetFixedPresetName(raw);
    expect(spresetFixedPresetName(raw), '');
    expect(((raw['prompts']! as List).last as Map)['content'], '{"FixedPresetName":"shadow","keep":1}');
  });

  test('logging is bounded, redacted, preset-specific and upload requires opt-in', () async {
    final logs = SPresetLogBuffer();
    for (var i = 0; i < 22; i++) {
      logs.add({'id': '$i', 'startedAt': '$i', 'presetName': i.isEven ? 'a' : 'b', 'api_key': 'secret'});
    }
    expect(logs.records, hasLength(20));
    expect(logs.records.first['id'], '2');
    expect(logs.report(presetName: 'a', at: DateTime.utc(2026))['records'], hasLength(10));
    expect(logs.records.every((record) => record['api_key'] == '[REDACTED]'), isTrue);
    var sends = 0;
    final client = MockClient((request) async {
      sends++;
      return http.Response('{"id":"ok"}', 200);
    });
    await expectLater(
      uploadSPresetLogReport(Uri.parse('https://fixture.invalid/upload'), {}, enabled: false, client: client),
      throwsA(isA<SPresetException>()),
    );
    expect(sends, 0);
    expect(
      await uploadSPresetLogReport(
        Uri.parse('https://fixture.invalid/upload'),
        {'records': []},
        enabled: true,
        client: client,
      ),
      {'id': 'ok', 'count': 0},
    );
    expect(sends, 1);
    client.close();
  });
}
