import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('structured tool aliases and falsy IDs follow fixed-source validation and normalization', () {
    final fixture = jsonDecode(File('test/fixtures/spreset/message-injection-aliases.json').readAsStringSync()) as Map;
    for (final value in fixture['vectors'] as List) {
      final entry = value as Map<String, Object?>;
      final provider = entry['provider']! as Map<String, Object?>;
      List<Map<String, Object?>> apply() => spresetInjectMessage(
        entry['base']! as Map<String, Object?>,
        entry['binding']! as Map<String, Object?>,
        SPresetProvider(source: (provider['source'] ?? provider['adapter'])! as String, model: 'fixture'),
      );
      if (entry['valid'] == true) {
        expect(apply(), entry['expected'], reason: entry['name']! as String);
      } else {
        expect(apply, throwsA(isA<SPresetException>()), reason: entry['name']! as String);
      }
    }
  });
}
