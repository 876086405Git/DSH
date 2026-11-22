import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('large opaque strings retain value while all mutable containers are detached', () {
    final payload = 'opaque' * 100000;
    final child = <String, Object?>{
      'script': payload,
      'list': [1, '😀', -0.0],
    };
    final raw = <String, Object?>{
      'extensions': {'a': child, 'b': child},
    };
    final preset = ChatPreset(raw);
    child['script'] = 'external edit';
    final first = preset.raw;
    final extensions = first['extensions']! as Map<String, Object?>;
    (extensions['a']! as Map<String, Object?>)['script'] = 'first edit';
    ((extensions['b']! as Map<String, Object?>)['list']! as List<Object?>).add('changed');
    final next = preset.raw['extensions']! as Map<String, Object?>;
    expect((next['a']! as Map<String, Object?>)['script'], payload);
    expect((next['b']! as Map<String, Object?>)['script'], payload);
    expect((next['b']! as Map<String, Object?>)['list'], [1, '😀', -0.0]);
    expect(() => (preset.executionSettings['extensions']! as Map<String, Object?>)['a'] = null, throwsUnsupportedError);
  });

  test('preset copying preserves the existing JSON input boundary', () {
    final decoded = const PresetCodec().validate({'foreign': _JsonValue()});
    expect(decoded.raw['foreign'], {
      'value': [1, true, null],
    });
    for (final invalid in [double.nan, double.infinity, Object()]) {
      expect(() => const PresetCodec().validate({'foreign': invalid}), throwsA(isA<TavernPresetImportError>()));
    }
    final cycle = <String, Object?>{};
    cycle['self'] = cycle;
    expect(() => ChatPreset(cycle), throwsA(isA<JsonCyclicError>()));
    expect(() => const PresetCodec().validate(cycle), throwsA(isA<TavernPresetImportError>()));
  });
}

class _JsonValue {
  Map<String, Object?> toJson() => {
    'value': [1, true, null],
  };
}
