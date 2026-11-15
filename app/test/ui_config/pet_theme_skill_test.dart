// The pet-theme skill: the converter and its helpers ship flat in
// assets/skills/pet-theme/ and land under scripts/ in the skill folder, so the
// agent on the host can run them. The copies must stay identical to app/tool;
// the second test fails when one of them is edited without re-copying.

import 'dart:io';

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';


import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundle: converter scripts sit under scripts/, SKILL.md last and managed', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, petThemeSkillName);
    expect(bundle.name, petThemeSkillName);
    expect(bundle.files.keys, containsAll([
      'SKILL.md',
      ['scripts', 'pet_theme_convert.py'].join('/'),
      ['scripts', 'pet_svg_frames.py'].join('/'),
      ['scripts', 'make_pet_pack.py'].join('/'),
      ['scripts', 'pet_pack_check.py'].join('/'),
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
        bundle.files[['scripts', name].join('/')],
        File(['tool', name].join('/')).readAsStringSync(),
        reason: 'app/tool/$name changed: copy it to assets/skills/pet-theme/$name',
      );
    }
  });

  test('installs into the engine home with its scripts', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, petThemeSkillName);
    final root = tempRootfs();
    addTearDown(() => root.deleteSync(recursive: true));
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.installed);
    final installed = Directory([root.path, 'root', '.dsh', 'skills', petThemeSkillName].join('/'));
    expect(File([installed.path, 'SKILL.md'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'scripts', 'pet_theme_convert.py'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'scripts', 'pet_pack_check.py'].join('/')).existsSync(), isTrue);
  });
}
