import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/stage1_engine_harness.dart';

void main() {
  test('concurrent imports claim a fixed name once and retain the losing marker and issue', () async {
    final h = await Stage1Harness.open(state: false, deepseek: false);
    final raw = {
      ...ChatPreset.stDefault().raw,
      'extensions': {
        'SPreset': {'FixedPresetName': 'Shared name'},
      },
    };
    final results = await Future.wait([
      h.engine.importPreset(jsonEncode(raw), fileName: 'first.json'),
      h.engine.importPreset(jsonEncode(raw), fileName: 'second.json'),
    ]);
    final winner = results.singleWhere((result) => result.preset.name == 'Shared name');
    final loser = results.singleWhere((result) => result.preset.id != winner.preset.id);
    expect(spresetFixedPresetName(winner.preset.raw), '');
    expect(spresetFixedPresetName(loser.preset.raw), 'Shared name');
    expect(loser.preset.name, isIn(['first', 'second']));
    expect(loser.issues.any((issue) => issue.code == 'spreset-fixed-name-conflict'), isTrue);
    expect((await h.engine.listPresets()).where((preset) => preset.name == 'Shared name'), hasLength(1));
    expect(spresetFixedPresetName((await h.engine.preset(loser.preset.id))!.raw), 'Shared name');
  });
}
