import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'spreset_protocol_test.dart' as support;

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/spreset/squash-boundaries.json').readAsStringSync()) as Map<String, Object?>;
  Object? value(String name) => switch (name) {
    'string' => 'U:NEW',
    'undefined' || 'null' => null,
    'false' => false,
    'zero' => 0,
    'number' => 3,
    'object' => {'x': 1},
    'emptyArray' => <Object?>[],
    'array' => <Object?>['A'],
    'Promise' => <String, Object?>{},
    _ => throw StateError(name),
  };
  for (final row in (fixture['squashed']! as List).cast<Map<String, Object?>>()) {
    test('fixed-source squash return=${row['returned']} re_split=${row['reSplit']}', () async {
      final e = support.Evaluator();
      e.handler = (_, args) => TavernSPresetEvaluationResult(
        requestId: 'fixture',
        isUndefined: row['returned'] == 'undefined',
        value: value(row['returned']! as String),
        arguments: args,
      );
      final operation = spresetSquashSegments(
        [support.segment('one', 'user', 'ORIGINAL')],
        support.config({
          'ChatSquash': {
            'enabled': true,
            'parse_clewd': false,
            're_split': row['reSplit'],
            'squashed_post_script_enable': true,
            'squashed_post_script': 'fixture',
            'user_prefix': 'U:',
            'char_prefix': 'A:',
            'prefix_system': 'S:',
          },
        }),
        support.counter,
        expand: (text) => text,
        evaluate: e.call,
        diagnose: e.diagnose,
      );
      if (row['outcome'] == 'throw') {
        await expectLater(operation, throwsA(isA<SPresetException>()));
      } else {
        expect((await operation).map((segment) => segment.message).toList(), jsonDecode(row['wireJson']! as String));
      }
      expect(e.issues.length, row['diagnostics']);
    });
  }
  for (final row in (fixture['stopping']! as List).cast<Map<String, Object?>>()) {
    test('fixed-source stop=${row['stopString']} existing=${row['shape']}', () {
      final cfg = support.config({
        'ChatSquash': {'enabled': true, 'enable_stop_string': true, 'stop_string': row['stopString']},
      });
      final data = <String, Object?>{
        if (row['shape'] == 'empty') 'stop': <Object?>[],
        if (row['shape'] == 'nonempty') 'stop': <Object?>['AB', 'A', 'old'],
      };
      if (row['outcome'] == 'throw') {
        expect(() => spresetApplyStops(cfg, data), throwsA(isA<SPresetException>()));
      } else {
        spresetApplyStops(cfg, data);
      }
      expect(data, row['data']);
    });
  }
  for (final row in (fixture['arrayMode']! as List).cast<Map<String, Object?>>()) {
    test('message-array script return=${row['returned']} tracks source behavior and typed message boundary', () async {
      final e = support.Evaluator();
      e.handler = (_, args) => TavernSPresetEvaluationResult(
        requestId: 'fixture',
        isUndefined: row['returned'] == 'undefined',
        value: value(row['returned']! as String),
        arguments: args,
      );
      final operation = spresetSquashSegments(
        [support.segment('one', 'user', 'ORIGINAL')],
        support.config({
          'ChatSquash': {'enabled': false, 'squashed_post_script_enable': true, 'squashed_post_script': 'fixture'},
        }),
        support.counter,
        expand: (text) => text,
        evaluate: e.call,
        diagnose: e.diagnose,
      );
      if (row['returned'] == 'array') {
        // runPostScript accepts ['A']; the native PromptSegment boundary is
        // typed to message objects. Do not claim this downstream difference
        // is the source's script diagnostic/backup behavior.
        await expectLater(operation, throwsA(isA<TypeError>()));
      } else {
        expect((await operation).map((segment) => segment.message).toList(), row['result']);
      }
      expect(e.issues.length, row['diagnostics']);
    });
  }
  test('array mutation followed by a script failure restores a detached backup', () async {
    final e = support.Evaluator();
    e.handler = (_, args) {
      ((args.single! as List).single as Map)['content'] = 'mutated';
      throw StateError('script failure');
    };
    final result = await spresetSquashSegments(
      [support.segment('one', 'user', 'ORIGINAL')],
      support.config({
        'ChatSquash': {'squashed_post_script_enable': true},
      }),
      support.counter,
      expand: (text) => text,
      evaluate: e.call,
      diagnose: e.diagnose,
    );
    expect(result.single.message['content'], 'ORIGINAL');
    expect(e.issues, ['ChatSquash']);
  });
  test('stop string spread follows Unicode code points and falsy existing values', () {
    final cfg = support.config({
      'ChatSquash': {'enabled': true, 'enable_stop_string': true, 'stop_string': '"😀B"'},
    });
    expect(spresetStops(cfg, []), ['😀', 'B']);
    for (final old in [null, false, 0, '']) {
      final data = <String, Object?>{'stop': old};
      spresetApplyStops(cfg, data);
      expect(data['stop'], '😀B');
    }
  });
  for (final split in [false, true]) {
    test('JS trim retains NEL in ${split ? 're_split' : 'clewd'} output', () async {
      final e = support.Evaluator();
      final result = await spresetSquashSegments(
        [support.segment('one', 'user', '\u0085X\u0085')],
        support.config({
          'ChatSquash': {
            'enabled': true,
            'parse_clewd': !split,
            're_split': split,
            'user_prefix': split ? 'U:' : '',
            'char_prefix': 'A:',
            'prefix_system': 'S:',
          },
        }),
        support.counter,
        expand: (text) => text,
        evaluate: e.call,
        diagnose: e.diagnose,
      );
      expect(result.single.message['content'], '\u0085X\u0085');
    });
  }
}
