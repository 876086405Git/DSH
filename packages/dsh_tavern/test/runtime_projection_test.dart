import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('compiled preset settings are reusable while public copies stay independent', () {
    final preset = ChatPreset({
      'temperature': 0.6,
      'extensions': {
        'regex_scripts': [
          {'id': 'fixture', 'replaceString': 'original'},
        ],
      },
    });
    final compiled = preset.executionSettings;
    expect(identical(compiled, preset.executionSettings), isTrue);
    final settings = preset.settings;
    final scripts = (settings['extensions']! as Map<String, Object?>)['regex_scripts']! as List<Object?>;
    (scripts.single! as Map<String, Object?>)['replaceString'] = 'changed copy';
    settings['temperature'] = 1;
    final originalScripts = (compiled['extensions']! as Map<String, Object?>)['regex_scripts']! as List<Object?>;
    expect((originalScripts.single! as Map<String, Object?>)['replaceString'], 'original');
    expect(preset.settings['temperature'], 0.6);
    expect(
      () => (originalScripts.single! as Map<String, Object?>)['replaceString'] = 'mutation',
      throwsUnsupportedError,
    );
    preset.raw['temperature'] = 2;
    expect(preset.raw['temperature'], 0.6);
  });

  test('shared world-info projections do not expose their cached source through inspection', () {
    final raw = <String, Object?>{
      'name': 'Fixture',
      'entries': {
        '0': {'uid': 0, 'key': <String>[], 'constant': true, 'content': 'original'},
      },
    };
    final book = WorldInfoBook.cached(id: 'fixture', source: WorldInfoSource.global, json: raw);
    final entry = book.entries.single;
    final hash = entry.stHash;
    entry.raw['content'] = 'entry copy';
    final rows = book.raw['entries']! as Map<String, Object?>;
    (rows['0']! as Map<String, Object?>)['content'] = 'book copy';
    (raw['entries']! as Map<String, Object?>)['0'] = {'uid': 0, 'content': 'new version'};
    expect(entry.content, 'original');
    expect(entry.stHash, hash);
    final next = WorldInfoBook.cached(id: 'fixture', source: WorldInfoSource.global, json: raw);
    expect(next.entries.single.content, 'new version');
    expect(next.entries.single.stHash, isNot(hash));
  });
}
