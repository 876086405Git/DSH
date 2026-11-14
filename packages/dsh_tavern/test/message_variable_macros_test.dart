import 'dart:convert';

import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('message reads keep captured values and work through both script adapters', () {
    final values = <String, Object?>{
      'stat_data': <String, Object?>{
        'title': '  quiet  ',
        'count': 2.0,
        'rows': [
          <String, Object?>{'value': 'first', r'$private': true},
          <String, Object?>{'value': null},
        ],
        '中文': <String, Object?>{'名字': '日常'},
        r'$internal': <String, Object?>{'kept': 1},
      },
      'schema': <String, Object?>{'type': 'object'},
    };
    final before = jsonEncode(values);
    for (final entry in _expanders.entries) {
      final context = _context(values);
      expect(
        entry.value(
          '{{get_message_variable::stat_data.title}}|'
          '{{get_message_variable::stat_data.count}}|'
          '{{get_message_variable::stat_data.rows.0.value}}|'
          '{{get_message_variable::stat_data.rows[1].value}}|'
          '{{get_message_variable::stat_data.中文.名字}}',
          context,
        ),
        '  quiet  |2|first|null|日常',
        reason: entry.key,
      );
      final encoded = entry.value('{{get_message_variable::stat_data}}', context);
      expect(jsonDecode(encoded), values['stat_data'], reason: entry.key);
      expect(encoded, contains(r'"$internal":{"kept":1}'), reason: entry.key);
      expect(entry.value('{{get_message_variable::schema.type}}', context), 'object', reason: entry.key);
    }
    expect(jsonEncode(values), before);
  });

  test('format uses block YAML, omits only metadata keys and leaves input intact', () {
    final selected = <String, Object?>{
      'title': 'plain',
      'values': [
        2,
        null,
        true,
        <String, Object?>{r'$hidden': 'omit'},
      ],
      'nested': <String, Object?>{
        'word': 'false',
        'empty': <Object?>[],
        r'$meta': <String, Object?>{'notShown': true},
      },
      r'$internal': <String, Object?>{'display_data': 'private'},
    };
    final values = <String, Object?>{'stat_data': selected, 'line': 'first\nsecond', 'nothing': null};
    final before = jsonEncode(values);
    const expected =
        'title: plain\n'
        'values:\n'
        '  - 2\n'
        '  - null\n'
        '  - true\n'
        '  - {}\n'
        'nested:\n'
        '  word: "false"\n'
        '  empty: []';
    for (final entry in _expanders.entries) {
      final context = _context(values);
      final formatted = entry.value('{{format_message_variable::stat_data}}', context);
      expect(formatted, expected, reason: entry.key);
      expect(loadYaml(formatted), {
        'title': 'plain',
        'values': [2, null, true, <String, Object?>{}],
        'nested': {'word': 'false', 'empty': <Object?>[]},
      }, reason: entry.key);
      expect(formatted.endsWith('\n'), isFalse, reason: entry.key);
      expect(loadYaml(entry.value('{{format_message_variable::line}}', context)), values['line'], reason: entry.key);
      expect(entry.value('{{format_message_variable::nothing}}', context), 'null', reason: entry.key);
      // Filtering is specific to the format macro, not the JSON getter.
      expect(jsonDecode(entry.value('{{get_message_variable::stat_data}}', context)), selected, reason: entry.key);
    }
    expect(jsonEncode(values), before);
  });

  test('missing or unsupported paths stay literal without resolved callbacks', () {
    final values = <String, Object?>{
      'stat_data': <String, Object?>{
        'rows': [
          <String, Object?>{'value': null},
        ],
        'count': 2,
      },
      'missing::0': 'not a second argument',
    };
    const invalid = [
      '{{get_message_variable::missing}}',
      '{{get_message_variable::stat_data.rows[2]}}',
      '{{get_message_variable::stat_data.rows[-1]}}',
      '{{get_message_variable::stat_data["count"]}}',
      '{{get_message_variable::stat_data..count}}',
      '{{get_message_variable::stat_data.rows[0].value.child}}',
      '{{get_message_variable::/stat_data/count}}',
      '{{get_message_variable::missing::0}}',
      '{{get_message_variable::}}',
      '{{format_message_variable::missing}}',
    ];
    final source = invalid.join('|');
    for (final entry in _expanders.entries) {
      expect(entry.value(source, _context(values)), source, reason: entry.key);
      const macro = '{{get_message_variable::stat_data.count}}';
      expect(entry.value(macro, _context(values, exists: false)), macro, reason: entry.key);
      expect(entry.value(macro, _context(null)), macro, reason: entry.key);
      expect(entry.value(macro, _context(<Object?>[values])), macro, reason: entry.key);
    }

    const mixed =
        '{{get_message_variable::missing}}|'
        '{{get_message_variable::stat_data.rows[0].value}}';
    for (final legacy in [false, true]) {
      final seen = <Object?>[];
      Object? postProcess(Object? value) {
        seen.add(value);
        return '[$value]';
      }

      final context = _context(values);
      final result = legacy
          ? const LegacyMacroEngine().expand(mixed, context, postProcess: postProcess)
          : const MacroEngine().expand(mixed, context, postProcess: postProcess);
      expect(result, '{{get_message_variable::missing}}|[null]');
      expect(seen, ['null']);
    }
    // Existing legacy passes retain null post-process result coercion.
    expect(const LegacyMacroEngine().expand('{{getvar::absent}}', _context(values), postProcess: (_) => null), 'null');
  });
}

MacroContext _context(Object? value, {bool exists = true}) => MacroContext(
  messageVariables: value,
  messageVariablesExists: exists,
  now: DateTime.utc(2026, 11, 14),
  random: () => 0,
);

final _bindings = ScriptMacroBindings(
  pipe: '',
  variable: (_, _) => ScriptCoercion.undefined,
  argument: (_) => ScriptCoercion.undefined,
  custom: (_) => ScriptCoercion.undefined,
  isCallable: (_) => false,
);

final _expanders = <String, String Function(String, MacroContext)>{
  'new': (text, context) => const MacroEngine().expand(text, context),
  'legacy': (text, context) => const LegacyMacroEngine().expand(text, context),
  'script/new': (text, context) => const ScriptMacroAdapter().expand(text, context, bindings: _bindings) as String,
  'script/legacy': (text, context) =>
      const ScriptMacroAdapter().expand(text, context, bindings: _bindings, legacy: true) as String,
};
