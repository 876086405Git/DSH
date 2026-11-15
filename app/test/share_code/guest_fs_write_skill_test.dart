// Replacing an installed skill from a share: the new files are written aside
// first, so a write that fails leaves the old skill where the engine reads it.
import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

const _skill = '${GuestFs.skillsRoot}/outline';

void main() {
  late GuestFs fs;
  setUp(() => fs = tempGuest());
  tearDown(() => fs.root.parent.deleteSync(recursive: true));

  void install(String guestPath, String text) {
    final target = fs.file(guestPath);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(text);
  }

  String read(String guestPath) => fs.file(guestPath).readAsStringSync();

  test('a write that fails keeps the installed skill in place', () {
    install('$_skill/SKILL.md', 'old');
    // Something in the way of the staging folder: the write fails there.
    install('${GuestFs.skillsRoot}.dsh-app-tmp', 'in the way');
    expect(
      () => fs.writeSkill(const SharedSkill(name: 'outline', files: {'SKILL.md': 'new'})),
      throwsA(isA<FileSystemException>()),
    );
    expect(read('$_skill/SKILL.md'), 'old');
  });

  test('a folder skill is replaced whole, nothing left staged', () {
    install('$_skill/SKILL.md', 'old');
    install('$_skill/extra.md', 'gone');
    fs.writeSkill(const SharedSkill(name: 'outline', files: {'SKILL.md': 'new', 'ref/a.md': 'a'}));
    expect(read('$_skill/SKILL.md'), 'new');
    expect(read('$_skill/ref/a.md'), 'a');
    expect(fs.file('$_skill/extra.md').existsSync(), isFalse);
    expect(fs.dir('${GuestFs.skillsRoot}.dsh-app-tmp/outline').existsSync(), isFalse);
  });

  test('a flat skill becomes a folder', () {
    install('${GuestFs.skillsRoot}/outline.md', 'old');
    fs.writeSkill(const SharedSkill(name: 'outline', files: {'SKILL.md': 'new'}));
    expect(fs.file('${GuestFs.skillsRoot}/outline.md').existsSync(), isFalse);
    expect(read('$_skill/SKILL.md'), 'new');
  });

  test('a leftover from an earlier failed write does not get in the way', () {
    install('${GuestFs.skillsRoot}.dsh-app-tmp/outline/stale.md', 'stale');
    fs.writeSkill(const SharedSkill(name: 'outline', files: {'SKILL.md': 'new'}));
    expect(read('$_skill/SKILL.md'), 'new');
    expect(fs.file('$_skill/stale.md').existsSync(), isFalse);
  });
}
