import 'package:dsh_tavern/src/mvu/mvu.dart';
import 'package:test/test.dart';

void main() {
  test('initialization uses YAML, JSON5 syntax fallback, and repaired JSON', () async {
    final cases = <(String, MvuJson)>[
      ('counter: 1\nlabel: yaml', <String, Object?>{'counter': 1, 'label': 'yaml'}),
      (r"{ label: 'it\'s JSON5', counter: 0x10, }", <String, Object?>{'counter': 16, 'label': "it's JSON5"}),
      (
        r"""{
          label: 'it\'s token-aware',
          counter: /* 0x99 */ +0X10, // 0x80 stays in this comment
          negative: -0X10,
          '0x10': '0x10',
          tag0x10: "/* 0x20 */",
        }""",
        <String, Object?>{
          'label': "it's token-aware",
          'counter': 16,
          'negative': -16,
          '0x10': '0x10',
          'tag0x10': '/* 0x20 */',
        },
      ),
      (
        r"{label: 'it\'s partial', counter: 0x10oops, dotted: 0x10.5}",
        <String, Object?>{'label': "it's partial", 'counter': '0x10oops', 'dotted': '0x10.5'},
      ),
      (r'{"counter": 2 "label": "comma"}', <String, Object?>{'counter': 2, 'label': 'comma'}),
      (r'{"counter": 3, "label": "missing}', <String, Object?>{'counter': 3, 'label': 'missing'}),
      (
        r'{&quot;counter&quot;: 4 &quot;label&quot;: &quot;a &amp; b&quot;}',
        <String, Object?>{'counter': 4, 'label': 'a & b'},
      ),
      (r'{"label": "hel" + "lo", "counter": .5,}', <String, Object?>{'counter': 0.5, 'label': 'hello'}),
      (
        r'{"counter": 5 "nested": [1, 2, ...]}',
        <String, Object?>{
          'counter': 5,
          'nested': <Object?>[1, 2],
        },
      ),
    ];
    for (var index = 0; index < cases.length; index++) {
      final source = cases[index].$1;
      final result = await initializeMvu(<String, Object?>{}, <MvuBook>[_book('source-$index', source)]);
      expect(result.issues, isEmpty, reason: source);
      expect(result.data['stat_data'], cases[index].$2, reason: source);
      expect(result.data['initialized_lorebooks'], <String, Object?>{'source-$index': <Object?>[]});
    }
    final overflowHex = List<String>.filled(300, 'f').join();
    final invalid = await initializeMvu(
      <String, Object?>{'outside': true},
      <MvuBook>[
        _book('bad-unicode', r'{"label": "\u12ZZ"}'),
        _book('bad-key', '1: value'),
        _book('wrong-root', 'null'),
        _book('hex-overflow', "{label: 'it\\'s overflow', counter: 0x$overflowHex}"),
      ],
    );
    expect(invalid.issues.map((issue) => issue.code), <String>[
      'invalid_initvar',
      'invalid_initvar',
      'invalid_initvar',
      'invalid_initvar',
    ]);
    expect(invalid.data['initialized_lorebooks'], isEmpty);
    expect(invalid.data['stat_data'], isEmpty);
    expect(invalid.data['outside'], isTrue);
  });

  test('command literals and explicit real-number functions preserve partial success', () async {
    final initial = await initializeMvu(<String, Object?>{}, <MvuBook>[
      _book('values', '''
log: 0
exp: 0
inverse: 0
round: 0
unknown: old
object: {}
list: []
value: 0
'''),
    ]);
    final result = await updateMvu(r'''
_.set('log', Math.log(8));
_.set('exp', math.exp(1));
_.set('inverse', Math.acos(1));
_.set('round', Math.round(0.49999999999999994));
_.set('unknown', Math.ln(8));
_.set('object', {unquoted: 'it\'s JSON5', hex: -0X10, trailing: [1, 2,],});
_.set('list', [true, null, "x"]);
_.set('value', Infinity);
_.add('value', 2);
''', initial.data);
    final state = result.data['stat_data']! as MvuJson;
    expect(state['log'], closeTo(2.07944154168, 1e-11));
    expect(state['exp'], closeTo(2.71828182846, 1e-11));
    expect(state['inverse'], 0);
    expect(state['round'], 0);
    expect(state['unknown'], 'Math.ln(8)');
    expect(state['object'], <String, Object?>{
      'unquoted': "it's JSON5",
      'hex': -16,
      'trailing': <Object?>[1, 2],
    });
    expect(state['list'], <Object?>[true, null, 'x']);
    expect(state['value'], 2);
    expect(result.issues, hasLength(1));
    expect((initial.data['stat_data']! as MvuJson)['value'], 0);
  });

  test('invalid finite JSON at an actual input or hook boundary propagates', () async {
    final previous = <String, Object?>{'outside': double.infinity};
    await expectLater(initializeMvu(previous, <MvuBook>[_book('B', 'counter: 1')]), throwsFormatException);
    expect(previous['outside'], double.infinity);
    await expectLater(updateMvu("_.set('counter', 2);", previous), throwsFormatException);
    var called = 0;
    await expectLater(
      initializeMvu(
        <String, Object?>{},
        <MvuBook>[_book('B', 'counter: 1')],
        onPhase: (phase) async {
          called++;
          phase.data['outside'] = double.nan;
        },
      ),
      throwsFormatException,
    );
    expect(called, 1);
  });
}

MvuBook _book(String name, String content) => MvuBook(
  name: name,
  entries: <MvuInitEntry>[MvuInitEntry(comment: '[initvar]', content: content)],
);
