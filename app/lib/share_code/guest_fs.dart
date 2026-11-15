// The on-device engine's Linux files, read and written from the app for what
// DSH has no remote method for (user skills and the user's AGENTS.md in a
// profile share). The guest root is the rootfs under the app's files dir
// (RuntimeInstaller.kt: `filesDir/runtime/rootfs`); DSH home is `/root/.dsh`.
// The files are small; IO is synchronous.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../runtime/local_paths.dart';
import 'share_models.dart';

/// The app-managed global AGENTS.md starts with this (GuestSetup.kt); such a
/// file is the app's, not the person's.
const managedAgentsMarker = '<!-- dsh-app:managed';

/// One user skill found on disk.
class LocalSkill {
  const LocalSkill({required this.skill, this.description});

  final SharedSkill skill;

  /// `description` from the front matter.
  final String? description;

  String get name => skill.name;
}

class GuestFs {
  GuestFs(this.root);

  /// The rootfs directory (guest `/`).
  final Directory root;

  /// Guest DSH home.
  static const dshHome = '/root/.dsh';

  /// Guest shared agents home (`$DSH_AGENTS_HOME` default).
  static const agentsHome = '/root/.agents';

  /// Where imported skills go.
  static const skillsRoot = '$dshHome/skills';

  /// Where an imported AGENTS.md goes: the shared agents root, loaded after
  /// DSH home's (app-managed) one.
  static const importedAgentsMd = '$agentsHome/AGENTS.md';

  /// The on-device rootfs; null when the runtime isn't installed.
  static Future<GuestFs?> local() async {
    try {
      final dir = Directory(LocalPaths.root ?? '${(await getApplicationSupportDirectory()).path}/runtime/rootfs');
      return dir.existsSync() ? GuestFs(dir) : null;
    } catch (_) {
      return null;
    }
  }

  File file(String guestPath) => File('${root.path}/${guestPath.replaceFirst(RegExp(r'^/+'), '')}');

  Directory dir(String guestPath) => Directory('${root.path}/${guestPath.replaceFirst(RegExp(r'^/+'), '')}');

  /// The person's own AGENTS.md text: DSH home's unless the app manages it,
  /// else the shared agents root's. Null when there is none.
  Future<String?> readUserAgentsMd() async {
    for (final path in ['$dshHome/AGENTS.md', importedAgentsMd]) {
      final f = file(path);
      try {
        if (!f.existsSync() || f.lengthSync() > ProfileShare.maxAgentsMdChars * 4) continue;
        final text = f.readAsStringSync();
        if (text.trimLeft().startsWith(managedAgentsMarker) || text.trim().isEmpty) continue;
        return text.length <= ProfileShare.maxAgentsMdChars ? text : null;
      } catch (_) {}
    }
    return null;
  }

  /// The text an import would replace (null: the file doesn't exist).
  Future<String?> readImportedAgentsMd() async {
    final f = file(importedAgentsMd);
    try {
      return f.existsSync() ? f.readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  /// User skills from DSH home and the shared agents root (`<name>/SKILL.md`
  /// folders with their small text files, or flat `<name>.md`). The first
  /// root wins a name, as in DSH's own rank order.
  Future<List<LocalSkill>> readUserSkills() async {
    final out = <String, LocalSkill>{};
    for (final rootPath in [skillsRoot, '$agentsHome/skills']) {
      final d = dir(rootPath);
      if (!d.existsSync()) continue;
      final entries = d.listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        final base = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (base.startsWith('.')) continue;
        try {
          if (entry is Directory) {
            final skillMd = File('${entry.path}/SKILL.md');
            if (!skillMd.existsSync()) continue;
            final files = _readFolder(entry);
            if (files == null || !files.containsKey('SKILL.md')) continue;
            final name = _frontMatter(files['SKILL.md']!)['name'] ?? base;
            if (!_validName(base) || out.containsKey(base)) continue;
            out[base] = LocalSkill(
              skill: SharedSkill(name: base, files: files),
              description: _frontMatter(files['SKILL.md']!)['description'] ?? (name == base ? null : name),
            );
          } else if (entry is File && base.endsWith('.md')) {
            final name = base.substring(0, base.length - 3);
            if (!_validName(name) || out.containsKey(name) || entry.lengthSync() > SharedSkill.maxFileChars) continue;
            final text = entry.readAsStringSync();
            out[name] = LocalSkill(
              skill: SharedSkill(name: name, files: {'SKILL.md': text}),
              description: _frontMatter(text)['description'],
            );
          }
        } catch (_) {
          // Unreadable or binary: not offered.
        }
      }
    }
    return out.values.toList();
  }

  static bool _validName(String name) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(name);

  /// Text files of a skill folder (≤ 12, ≤ 64 KB each, three levels deep);
  /// null when it holds something that can't travel (binaries, too large).
  static Map<String, String>? _readFolder(Directory folder) {
    final files = <String, String>{};
    final prefix = folder.path.endsWith('/') ? folder.path : '${folder.path}/';
    for (final entity in folder.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(prefix.length);
      if (!SharedSkill.isSafePath(rel)) {
        if (rel.split('/').any((s) => s.startsWith('.'))) continue;
        return null;
      }
      if (files.length >= SharedSkill.maxFiles || entity.lengthSync() > SharedSkill.maxFileChars) return null;
      try {
        files[rel] = utf8.decode(entity.readAsBytesSync());
      } on FormatException {
        return null;
      }
    }
    return files;
  }

  /// `name` / `description` of a YAML front matter (single-line values).
  static Map<String, String> _frontMatter(String text) {
    final match = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---').firstMatch(text);
    if (match == null) return const {};
    final out = <String, String>{};
    for (final line in match.group(1)!.split('\n')) {
      final m = RegExp(r'^(name|description):\s*(.+?)\s*$').firstMatch(line);
      if (m == null) continue;
      var value = m.group(2)!;
      if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'")) && value.endsWith(value[0])) {
        value = value.substring(1, value.length - 1);
      }
      out[m.group(1)!] = value;
    }
    return out;
  }

  /// Text of skill [name] in DSH home, by relative path; null when absent.
  Map<String, String>? readSkill(String name) {
    final folder = dir('$skillsRoot/$name');
    if (folder.existsSync()) return _readFolder(folder);
    final flat = file('$skillsRoot/$name.md');
    if (flat.existsSync()) {
      try {
        return {'SKILL.md': flat.readAsStringSync()};
      } catch (_) {}
    }
    return null;
  }

  /// Complete, bounded bytes for a destructive import. Unlike [readSkill],
  /// this never silently drops files that cannot travel in a share code.
  /// Null means absent; an unsafe or unreadable existing skill throws.
  Map<String, List<int>>? readSkillForImport(String name) {
    if (!_validName(name)) throw const FormatException('invalid skill name');
    final root = dir(skillsRoot);
    final List<FileSystemEntity> entries;
    try {
      entries = root.listSync(followLinks: false);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null; // Missing skills root.
      rethrow;
    }
    final folderPath = '${root.path}/$name';
    final flatPath = '${root.path}/$name.md';
    final matches = entries.where((entry) => entry.path == folderPath || entry.path == flatPath).toList();
    if (matches.isEmpty) return null;
    if (matches.length != 1) throw const FormatException('ambiguous skill files');
    final files = <String, List<int>>{};
    var entriesRead = 0;
    void read(File source, String relative) {
      if (FileSystemEntity.typeSync(source.path, followLinks: false) != FileSystemEntityType.file) {
        throw const FormatException('unsupported skill entry');
      }
      if (!SharedSkill.isSafePath(relative) || files.length >= SharedSkill.maxFiles) {
        throw const FormatException('skill cannot be backed up completely');
      }
      final input = source.openSync();
      try {
        final bytes = input.readSync(SharedSkill.maxFileChars + 1);
        if (bytes.length > SharedSkill.maxFileChars) throw const FormatException('skill file too large');
        utf8.decode(bytes); // Validate text, but preserve the original bytes (including BOM).
        files[relative] = bytes;
      } finally {
        input.closeSync();
      }
    }

    void walk(Directory directory, String prefix) {
      for (final entry in directory.listSync(followLinks: false)) {
        if (++entriesRead > SharedSkill.maxFiles * 4) throw const FormatException('too many skill entries');
        final relative = '$prefix${entry.path.substring(directory.path.length + 1)}';
        if (!SharedSkill.isSafePath(relative)) throw const FormatException('unsupported skill entry');
        if (entry is File) {
          read(entry, relative);
        } else if (entry is Directory &&
            FileSystemEntity.typeSync(entry.path, followLinks: false) == FileSystemEntityType.directory &&
            relative.split('/').length < 4) {
          walk(entry, '$relative/');
        } else {
          throw const FormatException('unsupported skill entry');
        }
      }
    }

    final entry = matches.single;
    if (entry is Directory &&
        entry.path == folderPath &&
        FileSystemEntity.typeSync(entry.path, followLinks: false) == FileSystemEntityType.directory) {
      walk(entry, '');
    } else if (entry is File && entry.path == flatPath) {
      read(entry, 'SKILL.md');
    } else {
      throw const FormatException('unsupported skill entry');
    }
    return files;
  }

  /// Writes [skill] as `skills/<name>/…`, replacing what was there. The new
  /// files are written beside the skills folder first, so a write that fails
  /// (a full disk) leaves the installed skill as it was.
  void writeSkill(SharedSkill skill) {
    final folder = dir('$skillsRoot/${skill.name}');
    final flat = file('$skillsRoot/${skill.name}.md');
    final staging = dir('$skillsRoot.dsh-app-tmp/${skill.name}');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    for (final MapEntry(key: rel, value: text) in skill.files.entries) {
      if (!SharedSkill.isSafePath(rel)) continue;
      final target = File('${staging.path}/$rel');
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(text, flush: true);
    }
    if (flat.existsSync()) flat.deleteSync();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    folder.parent.createSync(recursive: true);
    staging.renameSync(folder.path);
  }

  Future<void> deleteImportedAgentsMd() async {
    final f = file(importedAgentsMd);
    if (f.existsSync()) f.deleteSync();
  }

  Future<void> writeImportedAgentsMd(String text) async {
    final f = file(importedAgentsMd);
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.dsh-app-tmp');
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  }
}

/// The on-device rootfs (null before the runtime is installed). Tests
/// override it with a temp directory.
final guestFsProvider = FutureProvider<GuestFs?>((ref) => GuestFs.local());
