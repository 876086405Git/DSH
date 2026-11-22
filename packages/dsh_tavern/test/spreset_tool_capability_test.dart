import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  final oracle = jsonDecode(File('test/fixtures/spreset/tool-capability.json').readAsStringSync()) as Map;
  for (final value in oracle['cases'] as List) {
    final row = (value as Map).cast<String, Object?>();
    final lookup = (row['lookup']! as Map).cast<String, Object?>();
    final expected = (row['expected']! as Map).cast<String, Object?>();
    test('fixed ST catalog: ${row['id']}', () {
      final fact = lookup['kind'] == 'noMatch'
          ? const TavernSPresetToolModelLookup.noMatch()
          : TavernSPresetToolModelLookup.matched((lookup['row']! as Map).cast<String, Object?>());
      bool evaluate() => spresetToolModelSupportsTools(row['source']! as String, fact);
      if (expected.containsKey('error')) {
        expect(evaluate, throwsA(isA<SPresetException>()));
      } else {
        expect(evaluate(), expected['supported']);
      }
      if (lookup['kind'] == 'noMatch') {
        expect(
          spresetToolModelSupportsTools(row['source']! as String, const TavernSPresetToolModelLookup.notSupplied()),
          expected['supported'],
          reason: 'An unavailable native catalog uses the source empty-catalog branch; it is not a capability claim.',
        );
      }
    });
  }

  test('lookup status and detached raw metadata remain distinct', () {
    const absent = TavernSPresetToolModelLookup.notSupplied(reason: 'id-only host');
    const missing = TavernSPresetToolModelLookup.noMatch();
    final empty = TavernSPresetToolModelLookup.matched({'id': 'model'});
    expect(absent.kind, TavernSPresetToolModelLookupKind.notSupplied);
    expect(absent.reason, 'id-only host');
    expect(missing.kind, TavernSPresetToolModelLookupKind.noMatch);
    expect(empty.kind, TavernSPresetToolModelLookupKind.matched);
    expect(spresetToolModelSupportsTools('openrouter', absent), isTrue);
    expect(spresetToolModelSupportsTools('openrouter', missing), isTrue);
    expect(spresetToolModelSupportsTools('openrouter', empty), isFalse);
    final row = <String, Object?>{
      'id': 'model',
      'supported_parameters': <Object?>['tools'],
    };
    final fact = TavernSPresetToolModelLookup.matched(row);
    (row['supported_parameters']! as List).clear();
    (fact.row!['supported_parameters']! as List).clear();
    expect(spresetToolModelSupportsTools('openrouter', fact), isTrue);
  });
}
