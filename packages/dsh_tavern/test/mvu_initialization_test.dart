import 'dart:convert';

import 'package:dsh_tavern/src/mvu/mvu.dart';
import 'package:test/test.dart';

void main() {
  test('greeting override and awaited phases precede incremental book defaults', () async {
    final previous = <String, Object?>{
      'outside': <String, Object?>{'keep': true},
    };
    final original = jsonEncode(previous);
    const greeting = '''
This is the first record.
<INITVAR>
```yaml
counter: 10
label: "{{label}}"
```
</INITVAR>
<initvar>
branch:
  left: 1
</initvar>
<UpdateVariable>
_.add('counter', 1);
</UpdateVariable>
''';
    final phases = <MvuPhaseKind>[];
    final initialized = await initializeMvu(
      previous,
      <MvuBook>[_book('B', 'counter: 1\nbook_only: true'), _book('B', 'counter: 999')],
      greeting: greeting,
      swipeId: 3,
      expand: (source) async => source.replaceAll('{{label}}', 'from-greeting'),
      onPhase: (phase) async {
        phases.add(phase.kind);
        if (phase.kind == MvuPhaseKind.initialized) {
          expect(phase.swipeId, 3);
          expect(_object(phase.data['stat_data'])['counter'], 10);
          await Future<void>.value();
          _object(phase.data['stat_data'])['counter'] = 20;
        } else if (phase.kind == MvuPhaseKind.started) {
          expect(_object(phase.data['stat_data'])['counter'], 20);
        } else if (phase.kind == MvuPhaseKind.parsed) {
          expect(phase.originalMessage, greeting);
        }
      },
    );
    expect(initialized.issues, isEmpty);
    expect(phases, <MvuPhaseKind>[
      MvuPhaseKind.initialized,
      MvuPhaseKind.started,
      MvuPhaseKind.parsed,
      MvuPhaseKind.ended,
    ]);
    expect(initialized.data['stat_data'], <String, Object?>{
      'counter': 21,
      'label': 'from-greeting',
      'branch': <String, Object?>{'left': 1},
    });
    expect(initialized.data['initialized_lorebooks'], <String, Object?>{'B': <Object?>[]});
    expect(initialized.data['outside'], previous['outside']);
    expect(jsonEncode(previous), original);
    final schema = _object(initialized.data['schema']);
    expect(_object(_object(schema['properties'])['counter'])['type'], 'number');
    expect(_object(schema['properties']).containsKey('book_only'), isFalse);

    final adopted = jsonEncode(initialized.data);
    final refreshed = await initializeMvu(initialized.data, <MvuBook>[
      _book('B', 'counter: 999\nbook_only: true'),
      _book('extra-a', '''
counter: 99
profile:
  visits: 1
  tags: [a, old-tail]
  branch: {x: 1}
'''),
      _book('extra-b', '''
profile:
  visits: 2
  tags: [b]
  branch: {y: 2}
'''),
    ]);
    expect(refreshed.issues, isEmpty);
    expect(refreshed.data['stat_data'], <String, Object?>{
      'counter': 21,
      'label': 'from-greeting',
      'branch': <String, Object?>{'left': 1},
      'profile': <String, Object?>{
        'visits': 2,
        'tags': <Object?>['b'],
        'branch': <String, Object?>{'x': 1, 'y': 2},
      },
    });
    expect(refreshed.data['initialized_lorebooks'], <String, Object?>{
      'B': <Object?>[],
      'extra-a': <Object?>[],
      'extra-b': <Object?>[],
    });
    expect(jsonEncode(initialized.data), adopted);
  });

  test('book failures remain retryable and malformed old carriers are preserved', () async {
    final previous = <String, Object?>{
      'stat_data': <String, Object?>{'kept': 7},
      'schema': <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
      'initialized_lorebooks': <Object?>['already'],
    };
    final original = jsonEncode(previous);
    final partial = await initializeMvu(previous, <MvuBook>[
      _book('already', 'bad: .nan'),
      const MvuBook(
        name: 'empty',
        entries: <MvuInitEntry>[
          MvuInitEntry(id: 'blank', comment: '[initvar]', content: ' \t\r\n'),
          MvuInitEntry(id: 'wrapped', comment: '[initvar]', content: '<initvar>\n```yaml\n\n```\n</initvar>'),
        ],
      ),
      const MvuBook(
        name: 'retry',
        entries: <MvuInitEntry>[
          MvuInitEntry(id: 'good', comment: '[INITVAR] good', content: 'partial: true'),
          MvuInitEntry(id: 'bad', comment: '[initvar] bad', content: 'bad: .nan'),
          MvuInitEntry(id: 'ordinary', comment: 'ordinary', content: 'ignored: .nan'),
        ],
      ),
    ]);
    expect(partial.issues, hasLength(1));
    expect(partial.issues.single.code, 'invalid_initvar');
    expect(partial.issues.single.source, 'book["retry"].entries["bad"]');
    expect(partial.data['initialized_lorebooks'], <String, Object?>{'already': <Object?>[], 'empty': <Object?>[]});
    expect(partial.data['stat_data'], <String, Object?>{'partial': true, 'kept': 7});
    expect(jsonEncode(previous), original);

    final retried = await initializeMvu(partial.data, <MvuBook>[_book('retry', 'partial: false\nrecovered: true')]);
    expect(retried.issues, isEmpty);
    expect(retried.data['stat_data'], <String, Object?>{'partial': true, 'recovered': true, 'kept': 7});
    expect(retried.data['initialized_lorebooks'], <String, Object?>{
      'already': <Object?>[],
      'empty': <Object?>[],
      'retry': <Object?>[],
    });

    final malformed = <String, Object?>{
      'stat_data': null,
      'schema': <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
      'initialized_lorebooks': 17,
    };
    final malformedBefore = jsonEncode(malformed);
    final preserved = await initializeMvu(malformed, <MvuBook>[_book('new', 'counter: 100')]);
    expect(preserved.issues.map((issue) => issue.code), <String>['invalid_initialized_lorebooks']);
    expect(preserved.data.containsKey('stat_data'), isTrue);
    expect(preserved.data['stat_data'], isNull);
    expect(preserved.data['schema'], malformed['schema']);
    expect(preserved.data['initialized_lorebooks'], 17);
    expect(jsonEncode(malformed), malformedBefore);
  });

  test('schema metadata and templates govern actual insert and remove commands', () async {
    final initialized = await initializeMvu(
      <String, Object?>{
        'schema': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'name': <String, Object?>{'type': 'string', 'required': false},
          },
          'extensible': false,
        },
      },
      <MvuBook>[
        _book('schema', r'''
$meta:
  extensible: true
  required: [name, locked]
  strictTemplate: true
  strictSet: true
  concatTemplateArray: false
name: optional
locked: keep
bag:
  $meta:
    extensible: true
    template:
      count: 0
      tags: [default, tail]
      nested: {left: 1}
  existing: {count: 1}
rows:
  - $arrayMeta: true
    $meta:
      extensible: true
      template: [0, 1]
  - $__META_EXTENSIBLE__$
  - null
  - {n: 1}
'''),
      ],
    );
    expect(initialized.issues, isEmpty);
    final state = _object(initialized.data['stat_data']);
    final schema = _object(initialized.data['schema']);
    final properties = _object(schema['properties']);
    expect(state.containsKey(r'$meta'), isFalse);
    expect(_object(state['bag']).containsKey(r'$meta'), isFalse);
    expect(state['rows'], <Object?>[
      null,
      <String, Object?>{'n': 1},
    ]);
    expect(_object(properties['rows'])['elementType'], <String, Object?>{'type': 'any'});
    expect(_object(properties['name'])['required'], isFalse);
    expect(_object(properties['locked'])['required'], isTrue);
    expect(schema['strictTemplate'], isTrue);
    expect(schema['strictSet'], isTrue);
    expect(schema['concatTemplateArray'], isFalse);

    final before = jsonEncode(initialized.data);
    final edited = await updateMvu('''
_.insert('bag', 'added', {'tags':['own'], 'nested':{'right':2}});
_.insert('rows', 7);
_.remove('locked');
''', initialized.data);
    expect(edited.issues, hasLength(1));
    final changed = _object(edited.data['stat_data']);
    expect(_object(changed['bag'])['added'], <String, Object?>{
      'count': 0,
      'tags': <Object?>['own', 'tail'],
      'nested': <String, Object?>{'left': 1, 'right': 2},
    });
    expect(changed['rows'], <Object?>[
      null,
      <String, Object?>{'n': 1},
      7,
    ]);
    expect(changed['locked'], 'keep');
    expect(jsonEncode(initialized.data), before);

    final previousSchema = jsonEncode(edited.data['schema']);
    final cleared = await updateMvu("_.set('', null);", edited.data);
    expect(cleared.issues, isEmpty);
    expect(cleared.data.containsKey('stat_data'), isTrue);
    expect(cleared.data['stat_data'], isNull);
    expect(jsonEncode(cleared.data['schema']), previousSchema);
  });
}

MvuBook _book(String name, String content) => MvuBook(
  name: name,
  entries: <MvuInitEntry>[MvuInitEntry(comment: '[initvar]', content: content)],
);

MvuJson _object(Object? value) => value as MvuJson;
