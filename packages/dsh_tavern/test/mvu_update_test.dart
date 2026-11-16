import 'dart:convert';

import 'package:dsh_tavern/src/mvu/mvu.dart';
import 'package:test/test.dart';

MvuJson _state(MvuResult result) => result.data['stat_data'] as MvuJson;

MvuJson _objectSchema(MvuJson properties, {bool extensible = true}) => <String, Object?>{
  'type': 'object',
  'extensible': extensible,
  'properties': properties,
};

void main() {
  test('closed update and patch blocks preserve literal paths and partial success', () async {
    final previous = <String, Object?>{
      'stat_data': <String, Object?>{
        'counter': 0,
        'label': 'before',
        'a.b': <String, Object?>{
          'x/y': <String, Object?>{'~z': 1},
        },
        '': 0,
      },
      'other': <String, Object?>{'preserved': true},
    };
    final original = jsonEncode(previous);
    const message = r'''🧭 don't run _.add('counter', 100);
<thinking><analysis>_.add('counter', 1000);</analysis></thinking>
<UpdateVariable>
_.add('counter', 1);
<JSONPatch>
[
  {"op":"replace","path":"/label","value":"</UpdateVariable> _.add('counter', 900);"},
  {"op":"delta","path":"/a.b/x~1y/~0z","value":2},
  {"op":"replace","path":"/","value":7}
]
</JSONPatch>
_.add('missing', 1);
_.add('counter', 1);
</UpdateVariable>''';
    List<MvuCommand>? parsed;
    final result = await updateMvu(
      message,
      previous,
      blocksOnly: true,
      onPhase: (phase) async {
        if (phase.kind == MvuPhaseKind.parsed) {
          parsed = phase.commands;
          expect(phase.originalMessage, message);
        }
      },
    );
    expect(_state(result), {
      'counter': 2,
      'label': "</UpdateVariable> _.add('counter', 900);",
      'a.b': {
        'x/y': {'~z': 3},
      },
      '': 7,
    });
    expect(result.data['other'], previous['other']);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.code, 'command_path_missing');
    expect(result.issues.single.offset, message.indexOf("_.add('missing'"));
    expect(parsed, hasLength(6));
    expect(parsed!.where((command) => command.reason == 'json_patch'), hasLength(3));
    expect(jsonEncode(previous), original);

    final bare = await updateMvu("_.add('counter', 3);", result.data);
    expect(_state(bare)['counter'], 5);
    final automatic = await updateMvu("_.add('counter', 3);", result.data, blocksOnly: true);
    expect(_state(automatic)['counter'], 2);
    final truncated = await updateMvu("<update>_.add('counter', 9);", result.data, blocksOnly: true);
    expect(_state(truncated)['counter'], 2);
    expect(truncated.issues.single.code, 'unclosed_update');
  });

  test('patch structure errors discard one block while valid commands continue', () async {
    final data = <String, Object?>{
      'stat_data': <String, Object?>{'counter': 11, 'label': 'old'},
    };
    const message = r'''<VariableUpdate>
<JSONPatch>
<think>internal reasoning is excluded</think>
[{"op":"replace","path":"/counter","value":12}]
</JSONPatch>
_.add('missing', 1);
<JSONPatch>
[{"op":"replace","path":"/counter","value":99},{"op":42,"path":"/label"}]
</JSONPatch>
<JSON_Patch>
[{"op":"copy","path":"/label","from":"/counter"}]
</JSON_Patch>
_.add('counter', 100)
_.add('counter', 1);
</VariableUpdate>
<JSONPatch>
- op: replace
  path: /label
  value: |
    literal </JSONPatch> and <think> tags
</JSONPatch>''';
    final result = await updateMvu(message, data, blocksOnly: true);
    expect(_state(result)['counter'], 13);
    expect((_state(result)['label'] as String).trimRight(), 'literal </JSONPatch> and <think> tags');
    expect(
      result.issues.map((issue) => issue.code),
      unorderedEquals(['command_path_missing', 'invalid_patch', 'unsupported_patch_operation', 'invalid_command']),
    );
    final ignoredTail = await updateMvu("<think>_.add('counter', 500);", result.data);
    expect(_state(ignoredTail)['counter'], 13);
  });

  test('values, optional old set, arithmetic, VWD and ISO dates use real argument values', () async {
    final previous = <String, Object?>{
      'stat_data': <String, Object?>{
        'counter': 1,
        'score': <Object?>[5, 'description'],
        'nullable': 1,
        'text': '',
        'flag': false,
        'day': '2024-01-01',
        'invalidDay': '2024-99-99',
        'group': <String, Object?>{
          '项': <Object?>[1],
        },
      },
    };
    const message = r'''_.set('counter', 999, Math.pow(2, 3) + 1);
_.set('score', -100, '6');
_.add('score', 0.25);
_.set('nullable', null);
_.set('text', 'comma, and ); stay text');
_.set('group.项[0]', 7);
_.add('day', 86400000);
_.add('invalidDay', 86400000);
_.add('flag', 1);
_.set('counter', 'not a number');''';
    final result = await updateMvu(message, previous);
    expect(_state(result), {
      'counter': 9,
      'score': [6.25, 'description'],
      'nullable': null,
      'text': 'comma, and ); stay text',
      'flag': false,
      'day': '2024-01-02T00:00:00.000Z',
      'invalidDay': '2024-99-99',
      'group': {
        '项': [7],
      },
    });
    expect(result.issues.map((issue) => issue.code), ['command_type', 'command_type', 'command_value']);
    expect((result.data['delta_data'] as MvuJson)['score'], '6->6.25 ');
    expect((previous['stat_data'] as MvuJson)['counter'], 1);
  });

  test('collection edits preserve required gates, index merge and the array splice shortcut', () async {
    final previous = <String, Object?>{
      'stat_data': <String, Object?>{
        'items': <Object?>[1, 2, 3],
        'box': <String, Object?>{
          '10': 'ten',
          '2': 'two',
          'a': 0,
          'nested': <String, Object?>{
            'keep': 1,
            'list': <Object?>[1, 2, 3],
          },
        },
        'locked': 4,
      },
      'schema': _objectSchema(<String, Object?>{
        'items': <String, Object?>{
          'type': 'array',
          'extensible': false,
          'elementType': <String, Object?>{'type': 'number'},
        },
        'box': _objectSchema(<String, Object?>{}),
        'locked': <String, Object?>{'type': 'number', 'required': true},
      }),
    };
    const message = r'''_.insert('items', 4);
_.remove('items[1]');
_.remove('items', 0);
_.insert('box', {nested:{list:[9]}});
_.assign('box', 'a.b', {value:2});
_.delete('box', 0);
_.unset('locked');
_.insert('absent', 'x', 1);''';
    final result = await updateMvu(message, previous);
    expect(_state(result)['items'], [1, 3]);
    expect(_state(result)['locked'], 4);
    expect(_state(result)['box'], {
      '10': 'ten',
      'a': 0,
      'nested': {
        'keep': 1,
        'list': [9, 2, 3],
      },
      'a.b': {'value': 2},
    });
    expect(result.issues.map((issue) => issue.code), [
      'command_schema',
      'command_schema',
      'command_schema',
      'command_target',
    ]);
    expect((result.data['display_data'] as MvuJson)['items'], [1, 2, 3]);
    expect((result.data['delta_data'] as MvuJson).containsKey('items'), isFalse);
  });

  test('awaited feedback reconnects derived data and schema but keeps captured strict flags', () async {
    final previous = <String, Object?>{
      'stat_data': <String, Object?>{
        'bag': <String, Object?>{},
        'score': <Object?>[1, 'description'],
        'counter': 0,
      },
      'schema': <String, Object?>{
        ..._objectSchema(<String, Object?>{'bag': _objectSchema(<String, Object?>{}, extensible: false)}),
        'strictSet': true,
      },
    };
    final original = jsonEncode(previous);
    final phases = <MvuPhaseKind>[];
    var expanded = false;
    var endedDisplay = <String, Object?>{};
    final result = await updateMvu(
      "_.set('counter', {{amount}});",
      previous,
      expand: (source) async {
        await Future<void>.value();
        expanded = true;
        return source.replaceAll('{{amount}}', '1');
      },
      onPhase: (phase) async {
        expect(expanded, isTrue);
        phases.add(phase.kind);
        await Future<void>.value();
        final state = phase.data['stat_data'] as MvuJson;
        if (phase.kind == MvuPhaseKind.started) {
          final channel = state[r'$internal'] as MvuJson;
          (channel['display_data'] as MvuJson)['fromHook'] = 'retained';
          channel.remove('delta_data');
        } else if (phase.kind == MvuPhaseKind.parsed) {
          expect(phase.originalMessage, "_.set('counter', {{amount}});");
          expect(((state[r'$internal'] as MvuJson)['display_data'] as MvuJson)['fromHook'], 'retained');
          phase.data['schema'] = <String, Object?>{
            ..._objectSchema(<String, Object?>{'bag': _objectSchema(<String, Object?>{})}),
            'strictSet': false,
          };
          phase.commands = [
            MvuCommand(
              type: 'insert',
              fullMatch: 'listener insert',
              args: [
                'bag',
                'item',
                <String, Object?>{'n': 2},
              ],
            ),
            MvuCommand(type: 'set', fullMatch: 'listener set', args: ['score', 9]),
            MvuCommand(type: 'add', fullMatch: 'listener add', args: ['counter', 2]),
          ];
        } else if (phase.kind == MvuPhaseKind.ended) {
          endedDisplay = phase.data['display_data'] as MvuJson;
          expect(phase.data.containsKey('delta_data'), isFalse);
          // Deleting the finished derived field must not be reversed by cleanup.
          phase.data.remove('display_data');
          // The mutable comparison candidate can suppress reconciliation.
          final comparison = jsonDecode(jsonEncode(state)) as MvuJson;
          comparison.remove(r'$internal');
          phase.beforeData!['stat_data'] = comparison;
        }
      },
    );
    expect(phases, [MvuPhaseKind.started, MvuPhaseKind.parsed, MvuPhaseKind.ended]);
    expect(_state(result), {
      'bag': {
        'item': {'n': 2},
      },
      'score': 9,
      'counter': 2,
    });
    expect(endedDisplay['fromHook'], 'retained');
    expect(result.data.containsKey('display_data'), isFalse);
    expect(result.data.containsKey('delta_data'), isFalse);
    expect(_state(result).containsKey(r'$internal'), isFalse);
    expect((result.data['schema'] as MvuJson)['strictSet'], isFalse);
    expect(jsonEncode(previous), original);

    final unchanged = await updateMvu(
      "_.add('counter', 8);",
      result.data,
      onPhase: (phase) async {
        if (phase.kind == MvuPhaseKind.parsed) {
          phase.commands = [];
        }
      },
    );
    expect(_state(unchanged)['counter'], 2);
    final failure = StateError('listener rejected');
    await expectLater(
      updateMvu(
        "_.add('counter', 8);",
        result.data,
        onPhase: (phase) async {
          if (phase.kind == MvuPhaseKind.parsed) {
            throw failure;
          }
        },
      ),
      throwsA(same(failure)),
    );
    await expectLater(
      updateMvu(
        '',
        result.data,
        onPhase: (phase) async {
          if (phase.kind == MvuPhaseKind.parsed) {
            phase.commands = [
              MvuCommand(type: 'set', fullMatch: 'bad feedback', args: [42, 1]),
            ];
          }
        },
      ),
      throwsFormatException,
    );
  });

  test('nonobject roots retain their values and old schema without hidden initialization', () async {
    final oldSchema = _objectSchema(<String, Object?>{
      'counter': <String, Object?>{'type': 'number'},
    });
    final previous = <String, Object?>{
      'stat_data': <String, Object?>{'counter': 1},
      'schema': oldSchema,
    };
    for (final value in <Object?>[
      null,
      <Object?>[1, 2],
      42,
      false,
      'literal',
    ]) {
      final result = await updateMvu("_.set('', ${jsonEncode(value)}); _.add('missing', 1);", previous);
      expect(result.data.containsKey('stat_data'), isTrue);
      expect(result.data['stat_data'], value);
      expect(result.data['schema'], oldSchema);
      expect(result.issues.single.code, 'command_path_missing');
    }
    final numericRoot = await updateMvu("_.set('', '4');", <String, Object?>{'stat_data': 3, 'schema': oldSchema});
    expect(numericRoot.data['stat_data'], 3);
    final describedRoot = await updateMvu("_.set('', 9);", <String, Object?>{
      'stat_data': <Object?>[2, 'memo'],
      'schema': oldSchema,
    });
    expect(describedRoot.data['stat_data'], [2, 'memo']);
    final missing = await updateMvu('', <String, Object?>{});
    expect(missing.data.containsKey('stat_data'), isFalse);
    expect(missing.data.containsKey('display_data'), isFalse);
    await expectLater(updateMvu('', <String, Object?>{'stat_data': double.infinity}), throwsFormatException);
    expect(previous['stat_data'], {'counter': 1});
  });
}
