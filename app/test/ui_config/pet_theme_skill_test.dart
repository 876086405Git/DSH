// The pet-theme skill: the converter and its helpers ship flat in
// assets/skills/pet-theme/ and land under scripts/ in the skill folder, so the
// agent on the host can run them. The copies must stay identical to app/tool;
// the second test fails when one of them is edited without re-copying.

import 'dart:io';

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'skill_native_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundle: converter scripts sit under scripts/, SKILL.md last and managed', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, petThemeSkillName);
    expect(bundle.name, petThemeSkillName);
    expect(bundle.files.keys, containsAll([
      'SKILL.md',
      'scripts/pet_theme_convert.py',
      'scripts/pet_svg_frames.py',
      'scripts/make_pet_pack.py',
      'scripts/pet_pack_check.py',
    ]));
    expect(bundle.writeOrder.last.key, 'SKILL.md');
    expect(isManagedUiSkill(bundle.skillMd), isTrue);
    expect(bundle.skillMd, contains('name: pet-theme'));
    expect(bundle.skillMd, contains('pet_theme_convert.py'));
  });

  test('the shipped scripts are the app/tool originals, not forks', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, petThemeSkillName);
    for (final name in ['pet_theme_convert.py', 'pet_svg_frames.py', 'make_pet_pack.py']) {
      expect(
        bundle.files['scripts/' + name],
        File('tool/' + name).readAsStringSync(),
        reason: 'app/tool/' + name + ' changed: copy it to assets/skills/pet-theme/' + name,
      );
    }
  });

  test('installs into the engine home with its scripts', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, petThemeSkillName);
    final root = tempRootfs();
    addTearDown(() => root.deleteSync(recursive: true));
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.installed);
    final installed = Directory(root.path + '/root/.dsh/skills/' + petThemeSkillName);
    expect(File(installed.path + '/SKILL.md').existsSync(), isTrue);
    expect(File(installed.path + '/scripts/pet_theme_convert.py').existsSync(), isTrue);
    expect(File(installed.path + '/scripts/pet_pack_check.py').existsSync(), isTrue);
  });
}
