import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/io/preset_codec.dart';
import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:dsh_tavern/src/prompt/deepseek_processing.dart';
import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:dsh_tavern/src/regex/regex_engine.dart';
import 'package:test/test.dart';

const _codec = PresetCodec();
const _fixtureRoot = 'test/fixtures/w11_compat';
const _presetFiles = [
  'order-role-depth.json',
  'macro-order-nesting.json',
  'regex-scope-depth.json',
  'request-settings.json',
  'spreset-shadow.json',
  'helper-host-boundary.json',
  'markers-card-worldbook.json',
];

Map<String, Object?> _read(String name) =>
    (jsonDecode(File('$_fixtureRoot/$name').readAsStringSync()) as Map).cast<String, Object?>();

Map<String, Object?> _object(Object? value) => (value! as Map).cast<String, Object?>();

PromptAssembly _assemble(String name, {String type = 'normal', bool world = false}) {
  final context = _read('context.json');
  final history = (context['history']! as List).cast<Map<String, Object?>>();
  final fragments = _object(context['world_info_fragments']);
  return const PromptAssembler().assemble(
    PromptInput(
      preset: ChatPreset(_read(name)),
      card: _object(context['card']),
      history: [
        for (var i = 0; i < history.length; i++)
          PromptHistoryMessage(
            id: 'h$i',
            role: history[i]['role']! as String,
            content: history[i]['content']! as String,
          ),
      ],
      model: 'synthetic-model',
      userName: context['user_name']! as String,
      persona: context['persona']! as String,
      generationType: type,
      deepseek: false,
      worldBefore: [
        if (world) PromptFragment(fragments['before']! as String, const PromptSource('worldInfo', 'before')),
      ],
      worldAfter: [if (world) PromptFragment(fragments['after']! as String, const PromptSource('worldInfo', 'after'))],
    ),
  );
}

void main() {
  test('synthetic observed schemas round-trip without dropping opaque fields', () {
    for (final name in _presetFiles) {
      final raw = _read(name);
      final decoded = _codec.decode(jsonEncode(raw), fileName: name);
      expect(decoded.raw, raw, reason: name);
      expect(jsonDecode(_codec.encode(decoded.raw)), raw, reason: name);
    }
  });

  test('selected order keeps roles, override guard, depths and generation trigger', () {
    final result = _assemble('order-role-depth.json');
    final segments = result.beforePostProcessing;
    final contents = segments.map((row) => row.message['content']).toList();
    expect(contents, containsAll(['HEADER', 'USER_HINT', 'ASSISTANT_HINT', 'NEAR', 'FAR']));
    expect(contents, isNot(contains('OFF')));
    expect(contents, isNot(contains('CARD_OVERRIDE')));
    expect(segments.firstWhere((row) => row.message['content'] == 'USER_HINT').message['role'], 'user');
    expect(segments.firstWhere((row) => row.message['content'] == 'ASSISTANT_HINT').message['role'], 'assistant');
    expect(contents.indexOf('FAR'), lessThan(contents.indexOf('HISTORY_ASSISTANT')));
    expect(contents.indexOf('NEAR'), greaterThan(contents.indexOf('HISTORY_ASSISTANT')));
    final quiet = _assemble('order-role-depth.json', type: 'quiet');
    expect(quiet.beforePostProcessing.map((row) => row.message['content']), isNot(contains('NEAR')));
  });

  test('macro definitions share variables in order and preserve unprovided extension macros', () {
    final raw = _read('macro-order-nesting.json');
    final definitions = (raw['prompts']! as List).cast<Map<String, Object?>>();
    final context = MacroContext(
      localVariables: {},
      random: () => 0,
      history: const [MacroMessage(text: 'LATEST_USER', isUser: true)],
      messageVariables: _object(_read('context.json')['message_variables']),
      messageVariablesExists: true,
    );
    final values = [
      for (final definition in definitions) const MacroEngine().expand(definition['content']! as String, context),
    ];
    expect(values, ['', 'VALUE=1;NEST=1;PICK=A;LAST=LATEST_USER', 'ab', '7', '{{nemolore}}/{{long_term_memory}}']);
    expect(context.localVariables['counter'], '2');
  });

  test('regex preset respects phase, placement, depth, disabled and capture trim', () {
    final extension = _object(_read('regex-scope-depth.json')['extensions']);
    final regex = RegexEngine(presetScripts: RegexEngine.readScripts(extension['regex_scripts']));
    expect(regex.apply('token', placement: 2, phase: RegexPhase.prompt, depth: 1), '[token]');
    expect(regex.apply('token', placement: 2, phase: RegexPhase.display, depth: 1), '[token]');
    expect(regex.apply('token', placement: 2, phase: RegexPhase.prompt, depth: 0), 'token');
    expect(regex.apply('token', placement: 2, phase: RegexPhase.prompt, depth: 3), 'token');
    expect(regex.apply('token', placement: 2), 'token');
    expect(regex.apply('token', placement: 6, phase: RegexPhase.prompt, depth: 1), 'token');
    expect(regex.apply('hidden', placement: 6, phase: RegexPhase.display), 'visible');
    expect(regex.apply('abXYZcd', placement: 2, phase: RegexPhase.prompt), '<abcd>');
    expect(
      regex.apply(
        'User',
        placement: 1,
        phase: RegexPhase.prompt,
        expand: (text, {characterOverride, postProcess}) => text.replaceAll('{{user}}', 'User'),
      ),
      'MATCH',
    );
  });

  test('known request reasoning settings execute while opaque settings remain lossless', () {
    final preset = ChatPreset(_read('request-settings.json'));
    final body = deepSeekRequestBody(
      messages: const [],
      settings: preset.executionSettings,
      model: 'synthetic-model',
      generationType: 'normal',
    );
    expect(body['thinking'], {'type': 'enabled'});
    expect(body['reasoning_effort'], 'max');
    expect(preset.raw['function_calling'], isTrue);
    expect(preset.raw['tool_call_recurse_limit'], 5);
    expect(preset.raw['custom_prompt_post_processing'], 'strict');
    // Raw retention is deliberately not an assertion that these fields execute.
  });

  test('SPreset shadow regex and active preset regex remain separate source collections', () {
    final raw = _codec.decode(jsonEncode(_read('spreset-shadow.json'))).raw;
    final extension = _object(raw['extensions']);
    final spreset = _object(extension['SPreset']);
    final binding = _object(spreset['RegexBinding']);
    final active = RegexEngine(presetScripts: RegexEngine.readScripts(extension['regex_scripts']));
    final shadow = RegexEngine(presetScripts: RegexEngine.readScripts(binding['regexes']));
    expect(active.apply('token', placement: 2, phase: RegexPhase.display), 'ACTIVE');
    expect(shadow.apply('token', placement: 2, phase: RegexPhase.display), 'token');
    expect(_object(spreset['ChatSquash'])['enabled'], isFalse);
    expect(spreset['MacroNest'], isFalse);
    // Binding selection is a separate SPreset runtime test, not inferred here.
  });

  test('eight markers expand card, persona, history and supplied world-info fragments', () {
    final result = _assemble('markers-card-worldbook.json', world: true);
    final joined = result.beforePostProcessing.map((row) => row.message['content']).join('\n');
    for (final text in [
      'WORLD_BEFORE',
      'WORLD_AFTER',
      'CARD_DESCRIPTION',
      'CARD_PERSONALITY',
      'CARD_SCENARIO',
      'PERSONA',
      'EXAMPLE_USER',
      'EXAMPLE_ASSISTANT',
      'HISTORY_USER',
      'HISTORY_ASSISTANT',
      'CARD_OVERRIDE',
      'CARD_TAIL',
    ]) {
      expect(joined, contains(text));
    }
    expect(joined.indexOf('WORLD_BEFORE'), lessThan(joined.indexOf('CARD_OVERRIDE')));
    expect(joined.indexOf('WORLD_AFTER'), greaterThan(joined.indexOf('CARD_OVERRIDE')));
    // World-book binding/activation and MVU scripts are outside this assembler fixture.
  });
}
