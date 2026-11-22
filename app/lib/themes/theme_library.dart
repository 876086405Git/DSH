// Local storage, atomic install/remove, export and dynamic font loader for
// user and Workshop theme packs (<app support>/themes/user-<id>/).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FileImage, PaintingBinding;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../pets/pet_pack_validator.dart' show PetArchive, PetValidationException, decodePetJson, petArchiveByteCap;
import '../workshop/workshop_export.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_receipt.dart';
import 'theme_pack.dart';
import 'theme_pack_validator.dart';

enum ThemeImportProblem {
  notAZip,
  noPack,
  badPack,
  missingAsset,
  badAsset,
  tooLarge,
  storage,
}

class ThemeImportException implements Exception {
  const ThemeImportException(this.problem, [this.detail, this.osErrorCode]);

  final ThemeImportProblem problem;
  final String? detail;
  final int? osErrorCode;

  @override
  String toString() => 'ThemeImportException(${problem.name}${detail == null ? '' : ': $detail'})';
}

final _plainThemeFolderId = RegExp(r'^user-[a-z0-9]+(?:-[a-z0-9]+)*$');
final _backupThemeName = RegExp(r'^\.old-(\d+)-(user-[a-z0-9-]+)$');

final themeLibraryProvider = Provider<ThemeLibrary>(
  (ref) => ThemeLibrary(
    () async => Directory('${(await getApplicationSupportDirectory()).path}/themes'),
  ),
);

final userThemesProvider = FutureProvider<List<ThemePack>>(
  (ref) => ref.watch(themeLibraryProvider).list(),
);

final themePackByIdProvider = FutureProvider.family<ThemePack?, String?>((ref, id) async {
  if (id == null || id.isEmpty) return null;
  final builtIn = ThemePack.builtInById(id);
  if (builtIn != null) return builtIn;
  if (!isUserThemeId(id)) return null;
  try {
    return await ref.watch(themeLibraryProvider).load(id);
  } on Object {
    return null;
  }
});

/// Dynamically loads bundled .ttf/.otf font files from a theme pack's folder.
class ThemeFonts {
  ThemeFonts._();

  static final ThemeFonts instance = ThemeFonts._();
  final Map<String, String> _loaded = {};

  void forget(String themeId) {
    final prefix = '$themeId::';
    _loaded.removeWhere((key, _) => key.startsWith(prefix));
  }

  Future<Map<String, String>> loadFor(ThemePack? pack) async {
    if (pack == null || pack.folderPath == null || pack.referencedFonts.isEmpty) {
      return const {};
    }
    final result = <String, String>{};
    for (final fileName in pack.referencedFonts) {
      final cacheKey = '${pack.id}::$fileName';
      if (_loaded[cacheKey] case final existing?) {
        result[fileName] = existing;
        continue;
      }
      try {
        final file = File('${pack.folderPath}/$fileName');
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (!isValidThemeFontBytes(bytes)) continue;
        final family = 'dsh-theme-${pack.id}-$fileName';
        final loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
        _loaded[cacheKey] = family;
        result[fileName] = family;
      } on Object {
        // Fallback to system/role font if platform rejects font bytes.
      }
    }
    return Map.unmodifiable(result);
  }
}

final themeLoadedFontsProvider = FutureProvider.family<Map<String, String>, String?>((ref, id) async {
  final pack = await ref.watch(themePackByIdProvider(id).future);
  return ThemeFonts.instance.loadFor(pack);
});

class ThemeLibrary {
  ThemeLibrary(this._root) : _readWorkshopReceipt = WorkshopReceipt.read;

  @visibleForTesting
  ThemeLibrary.withWorkshopReceiptReader(
    this._root, {
    required Future<WorkshopReceipt?> Function(Directory) readReceipt,
  }) : _readWorkshopReceipt = readReceipt;

  final Future<Directory> Function() _root;
  final Future<WorkshopReceipt?> Function(Directory) _readWorkshopReceipt;

  Future<void> _queue = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Directory> folder(String id) async => Directory('${(await _root()).path}/$id');

  Future<List<ThemePack>> list() => _exclusive(() async {
    final Directory root;
    try {
      root = await _root();
    } on Object catch (error) {
      if (error is FileSystemException || error is WorkshopException) rethrow;
      return const <ThemePack>[];
    }
    await _tidy(root);
    if (!await root.exists()) return const <ThemePack>[];
    final found = <(DateTime, ThemePack)>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _nameOf(entity);
      if (!_plainThemeFolderId.hasMatch(id)) continue;
      try {
        final jsonFile = File('${entity.path}/theme.json');
        found.add((await jsonFile.lastModified(), await _load(root, id)));
      } on Object {
        // Skip broken or incomplete folders.
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, pack) in found) pack];
  });

  Future<ThemePack> load(String id) => _exclusive(() async {
    final builtIn = ThemePack.builtInById(id);
    if (builtIn != null) return builtIn;
    final root = await _root();
    await _tidy(root);
    return _load(root, id);
  });

  Future<({String id, bool replaced})> install(
    File zip, {
    WorkshopReceipt? workshop,
    bool replaceExisting = false,
  }) => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    final (:id, :backup) = await compute(
      _installThemeArchive,
      (
        zip.path,
        root.path,
        DateTime.now().microsecondsSinceEpoch,
        workshop == null ? null : jsonEncode(workshop.toJson()),
        replaceExisting,
      ),
    );
    ThemeFonts.instance.forget(id);
    await _evictFolderImages(Directory('${root.path}/$id'));
    if (backup != null) await _discard(Directory(backup));
    return (id: id, replaced: backup != null);
  });

  /// Saves a user-created or edited theme pack directly into the local library.
  /// [pack.id] must be the public theme ID (unless [editingLocalId] is given).
  /// When [allowOverwrite] is false, an existing folder with the same ID is
  /// rejected with `theme_exists` instead of silently replacing it.
  Future<ThemePack> saveCustom(
    ThemePack pack, {
    Map<String, Uint8List> assets = const {},
    bool allowOverwrite = true,
    String? editingLocalId,
  }) => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    await root.create(recursive: true);
    final publicId = editingLocalId != null ? publicThemeIdFor(editingLocalId) : pack.id;
    if (!isValidThemeId(publicId)) {
      throw const ThemeImportException(ThemeImportProblem.badPack, 'id');
    }
    final localId = userThemeIdFor(publicId);
    final live = Directory('${root.path}/$localId');
    if (!allowOverwrite && await live.exists()) {
      throw const ThemeImportException(ThemeImportProblem.badPack, 'theme_exists');
    }
    final mergedAssets = <String, Uint8List>{...assets};
    final sourceFolders = <String>[
      if (pack.folderPath != null) pack.folderPath!,
      if (allowOverwrite) '${root.path}/$localId',
    ];
    for (final name in <String>{...pack.referencedImages, ...pack.referencedFonts}) {
      if (mergedAssets.containsKey(name)) continue;
      for (final folder in sourceFolders) {
        final existing = File('$folder/$name');
        if (await existing.exists()) {
          mergedAssets[name] = await existing.readAsBytes();
          break;
        }
      }
    }
    final normalizedInput = pack.copyWith(id: publicId).toJson();
    final ValidatedThemePack validated;
    try {
      validated = ThemePackValidator.validateParts(normalizedInput, mergedAssets);
    } on ThemeValidationException catch (error) {
      throw _mapValidationProblem(error);
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final staging = Directory('${root.path}/.staging-$stamp');
    try {
      await staging.create(recursive: true);
      for (final entry in validated.assets.entries) {
        await File('${staging.path}/${entry.key}').writeAsBytes(entry.value, flush: true);
      }
      await File('${staging.path}/theme.json').writeAsString(jsonEncode(validated.json), flush: true);
      final old = Directory('${root.path}/.old-$stamp-$localId');
      final replaced = await live.exists();
      if (replaced) await live.rename(old.path);
      try {
        await staging.rename(live.path);
      } on FileSystemException {
        if (replaced) await old.rename(live.path);
        rethrow;
      }
      if (replaced) await _discard(old);
      ThemeFonts.instance.forget(localId);
      await _evictFolderImages(live);
      return await _load(root, localId);
    } finally {
      if (await staging.exists()) await _discard(staging);
    }
  });

  Future<WorkshopReceipt?> workshopReceipt(String id) => _exclusive(() async {
    if (!isUserThemeId(id) || !_plainThemeFolderId.hasMatch(id)) {
      workshopInvalid('workshop_install_record');
    }
    final root = await _root();
    await _tidy(root);
    final receipt = await WorkshopReceipt.read(Directory('${root.path}/$id'));
    if (receipt != null && (receipt.kind != 'theme' || userThemeIdFor(receipt.id) != id)) {
      workshopInvalid('workshop_install_record');
    }
    return receipt;
  });

  Future<Map<String, ({WorkshopReceipt? receipt, String? issue})>> workshopReceipts() =>
      _exclusive(() async {
        final Directory root;
        try {
          root = await _root();
        } on Object catch (error) {
          if (error is FileSystemException || error is WorkshopException) rethrow;
          return const {};
        }
        await _tidy(root);
        if (!await root.exists()) return const {};
        final found = <String, ({WorkshopReceipt? receipt, String? issue})>{};
        await for (final dir in root.list(followLinks: false)) {
          if (dir is! Directory) continue;
          final id = _nameOf(dir);
          if (!isUserThemeId(id) || !_plainThemeFolderId.hasMatch(id)) continue;
          WorkshopReceipt? receipt;
          try {
            receipt = await _readWorkshopReceipt(dir);
            if (receipt == null) continue;
            if (receipt.kind != 'theme' || userThemeIdFor(receipt.id) != id) {
              workshopInvalid('workshop_install_record');
            }
          } on FileSystemException {
            found[id] = (receipt: null, issue: 'workshop_storage');
            continue;
          } on WorkshopException {
            found[id] = (receipt: null, issue: 'workshop_install_record');
            continue;
          }
          try {
            await _load(root, id);
            found[id] = (receipt: receipt, issue: null);
          } on FileSystemException {
            found[id] = (receipt: receipt, issue: 'workshop_storage');
          } on FormatException {
            found[id] = (receipt: receipt, issue: 'workshop_theme_bad_pack');
          } on ThemeImportException {
            found[id] = (receipt: receipt, issue: 'workshop_theme_bad_pack');
          }
        }
        return found;
      });

  Future<File> exportZip(
    String id,
    File destination, {
    String? publicId,
    String? author,
    String? license,
    String? source,
  }) => _exclusive(() async {
    final builtIn = ThemePack.builtInById(id);
    final root = await _root();
    await _tidy(root);
    final target = await workshopExportTarget(destination);
    final output = target.path;
    final home = await root.exists()
        ? await root.resolveSymbolicLinks()
        : root.absolute.uri.normalizePath().toFilePath();
    final prefix = home.endsWith(Platform.pathSeparator) ? home : '$home${Platform.pathSeparator}';
    if (output == home || output.startsWith(prefix)) {
      throw const ThemeImportException(ThemeImportProblem.storage);
    }
    if (builtIn != null) {
      await workshopCommitExport(target, (staging) async {
        final json = {
          ...builtIn.toJson(),
          'id': publicId ?? builtIn.publicId,
          'author': ?author,
          'license': ?license,
          'source': ?source,
        };
        final checked = ThemePackValidator.validateParts(json, const {});
        final archive = Archive()
          ..add(ArchiveFile.bytes('theme.json', utf8.encode(jsonEncode(checked.json))));
        final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
        ThemePackValidator.validateArchive(bytes);
        await staging.writeAsBytes(bytes, flush: true);
      });
      return destination;
    }
    if (!isUserThemeId(id) || !_plainThemeFolderId.hasMatch(id)) {
      throw const ThemeImportException(ThemeImportProblem.noPack);
    }
    await workshopCommitExport(
      target,
      (staging) => compute(
        _exportThemePack,
        (
          '${root.path}/$id',
          staging.path,
          <String, String>{
            'id': publicId ?? publicThemeIdFor(id),
            'author': ?author,
            'license': ?license,
            'source': ?source,
          },
        ),
      ),
    );
    return destination;
  });

  Future<void> remove(String id, {WorkshopReceipt? expectedWorkshop}) async {
    if (!isUserThemeId(id) || !_plainThemeFolderId.hasMatch(id)) return;
    await _exclusive(() async {
      final root = await _root();
      if (!await root.exists()) return;
      if (expectedWorkshop != null) {
        await workshopCheckRemoval(Directory('${root.path}/$id'), expectedWorkshop);
      }
      final going = await root
          .list(followLinks: false)
          .where((e) => e is Directory && _backupThemeName.firstMatch(_nameOf(e))?[2] == id)
          .cast<Directory>()
          .toList();
      final dir = Directory('${root.path}/$id');
      if (await dir.exists()) going.add(dir);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final trash = <Directory>[];
      try {
        for (final dir in going) {
          trash.add(await dir.rename('${root.path}/.trash-$stamp-${trash.length}-$id'));
        }
        ThemeFonts.instance.forget(id);
      } finally {
        for (final dir in trash) {
          await _discard(dir);
        }
      }
    });
  }

  Future<ThemePack> _load(Directory root, String id) async {
    final dir = '${root.path}/$id';
    final jsonFile = File('$dir/theme.json');
    final rawText = await jsonFile.readAsString();
    final json = jsonDecode(rawText);
    if (json is! Map<String, Object?>) throw const FormatException('theme.json');
    final publicId = publicThemeIdFor(id);
    final normalized = {...json, 'id': publicId};
    final revision = (await jsonFile.lastModified()).microsecondsSinceEpoch;
    final pack = ThemePack.parse(normalized, folderPath: dir).copyWith(
      id: id,
      assetRevision: revision,
    );
    for (final asset in <String>{...pack.referencedImages, ...pack.referencedFonts}) {
      if (!await File('$dir/$asset').exists()) {
        throw const FormatException('theme.json: missing asset');
      }
    }
    return pack;
  }

  Future<void> _tidy(Directory root) async {
    if (!await root.exists()) return;
    final backups = <String, List<(int, Directory)>>{};
    final junk = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _nameOf(entity);
      if (_backupThemeName.firstMatch(name) case final m?) {
        (backups[m[2]!] ??= []).add((int.parse(m[1]!), entity));
      } else if (name.startsWith('.staging-') || name.startsWith('.trash-')) {
        junk.add(entity);
      }
    }
    for (final MapEntry(key: id, value: found) in backups.entries) {
      found.sort((a, b) => b.$1.compareTo(a.$1));
      var restored = false;
      if (!await Directory('${root.path}/$id').exists()) {
        try {
          await found.first.$2.rename('${root.path}/$id');
          restored = true;
        } on FileSystemException {
          continue;
        }
      }
      junk.addAll([for (final (_, dir) in found.skip(restored ? 1 : 0)) dir]);
    }
    for (final dir in junk) {
      await _discard(dir);
    }
  }
}

String _nameOf(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

Future<void> _discard(Directory dir) async {
  try {
    await dir.delete(recursive: true);
  } on FileSystemException {
    // Cleaned up on a subsequent tidy.
  }
}

Future<void> _evictFolderImages(Directory dir) async {
  try {
    if (!await dir.exists()) return;
    final cache = PaintingBinding.instance.imageCache;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.png')) {
        cache.evict(FileImage(entity));
      }
    }
  } on Object {
    // Pure Dart tests without PaintingBinding initialized.
  }
}

Future<Uint8List> _readArchiveBytes(File file) async {
  final input = await file.open();
  try {
    if (await input.length() > petArchiveByteCap) {
      throw const ThemeValidationException('archive-size');
    }
    final output = BytesBuilder(copy: false);
    var total = 0;
    while (total <= petArchiveByteCap) {
      final remaining = petArchiveByteCap + 1 - total;
      final chunk = await input.read(remaining < 65536 ? remaining : 65536);
      if (chunk.isEmpty) break;
      output.add(chunk);
      total += chunk.length;
    }
    if (total > petArchiveByteCap) {
      throw const ThemeValidationException('archive-size');
    }
    return output.takeBytes();
  } finally {
    await input.close();
  }
}

ThemeImportException _mapValidationProblem(ThemeValidationException error) {
  final code = error.code;
  final detail = error.detail ?? code;
  if (const {
    'archive-size',
    'archive-entries',
    'archive-expanded-size',
    'archive-member-size',
    'theme-size',
    'theme-asset-too-large',
    'theme-asset-total-size',
  }.contains(code)) {
    return ThemeImportException(ThemeImportProblem.tooLarge, detail);
  }
  if (code == 'theme-asset-missing' || code == 'archive-member-missing') {
    return ThemeImportException(ThemeImportProblem.missingAsset, detail);
  }
  if (code == 'archive-path' ||
      code == 'theme-asset-alias' ||
      code.startsWith('theme-png-') ||
      code.startsWith('theme-font-') ||
      code.startsWith('png-')) {
    return ThemeImportException(ThemeImportProblem.badAsset, detail);
  }
  if (code == 'archive-theme-count') {
    return ThemeImportException(ThemeImportProblem.noPack, detail);
  }
  if (code.startsWith('json-') || code.startsWith('theme-')) {
    return ThemeImportException(ThemeImportProblem.badPack, detail);
  }
  return ThemeImportException(ThemeImportProblem.notAZip, detail);
}

Future<({String id, String? backup})> _installThemeArchive(
  (String, String, int, String?, bool) args,
) async {
  final (zipPath, rootPath, stamp, receiptJson, replaceExisting) = args;
  final staging = Directory('$rootPath/.staging-$stamp');
  try {
    final bytes = await _readArchiveBytes(File(zipPath));
    final archive = PetArchive.read(bytes);
    if (archive.manifestPaths('theme.json').isEmpty) {
      throw const ThemeImportException(ThemeImportProblem.noPack);
    }
    final validated = ThemePackValidator.validateThemeArchive(archive);
    final pack = validated.pack;
    if (receiptJson != null) {
      final receipt = WorkshopReceipt.fromJson(jsonDecode(receiptJson));
      if (receipt.kind != 'theme' || receipt.id != pack.id) {
        throw const ThemeImportException(ThemeImportProblem.badPack, 'workshop_identity');
      }
    }
    final id = userThemeIdFor(pack.id);
    await staging.create(recursive: true);
    for (final entry in validated.assets.entries) {
      await File('${staging.path}/${entry.key}').writeAsBytes(entry.value, flush: true);
    }
    await File('${staging.path}/theme.json').writeAsString(jsonEncode(validated.json), flush: true);
    if (receiptJson != null) {
      await File('${staging.path}/$workshopReceiptName').writeAsString(receiptJson, flush: true);
    }
    final live = Directory('$rootPath/$id');
    if (receiptJson != null) {
      await workshopCheckReplacement(
        live,
        WorkshopReceipt.fromJson(jsonDecode(receiptJson)),
        replaceExisting: replaceExisting,
      );
    }
    final old = Directory('$rootPath/.old-$stamp-$id');
    final replaced = await live.exists();
    if (replaced) await live.rename(old.path);
    try {
      await staging.rename(live.path);
    } on FileSystemException {
      if (replaced) await old.rename(live.path);
      rethrow;
    }
    return (id: id, backup: replaced ? old.path : null);
  } on ThemeValidationException catch (error) {
    throw _mapValidationProblem(error);
  } on ThemeImportException {
    rethrow;
  } on PetValidationException catch (error) {
    throw _mapValidationProblem(ThemeValidationException(error.code, error.path));
  } on FileSystemException catch (error) {
    throw ThemeImportException(
      ThemeImportProblem.storage,
      error.osError?.message,
      error.osError?.errorCode,
    );
  } finally {
    if (await staging.exists()) await _discard(staging);
  }
}

Future<Uint8List> _themeExportRead(File file, int cap) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
    throw const ThemeImportException(ThemeImportProblem.missingAsset);
  }
  final input = await file.open();
  try {
    if (await input.length() > cap) {
      throw const ThemeImportException(ThemeImportProblem.tooLarge);
    }
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= cap) {
      final remaining = cap + 1 - bytes.length;
      final chunk = await input.read(remaining < 65536 ? remaining : 65536);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    if (bytes.length > cap) {
      throw const ThemeImportException(ThemeImportProblem.tooLarge);
    }
    return bytes.takeBytes();
  } finally {
    await input.close();
  }
}

Future<void> _exportThemePack((String, String, Map<String, String>) args) async {
  final (folder, destination, attribution) = args;
  final temporary = File('$destination.part-${DateTime.now().microsecondsSinceEpoch}');
  try {
    if (await FileSystemEntity.type(folder, followLinks: false) != FileSystemEntityType.directory) {
      throw const ThemeImportException(ThemeImportProblem.noPack);
    }
    final decoded = decodePetJson(await _themeExportRead(File('$folder/theme.json'), themeJsonCap));
    if (decoded is! Map<String, Object?>) {
      throw const ThemeImportException(ThemeImportProblem.badPack);
    }
    final mergedJson = <String, Object?>{
      ...decoded,
      'id': attribution['id'] ?? decoded['id'],
      if (attribution['author'] != null) 'author': attribution['author'],
      if (attribution['license'] != null) 'license': attribution['license'],
      if (attribution['source'] != null) 'source': attribution['source'],
    };
    final pack = ThemePack.parse(mergedJson);
    final assets = <String, Uint8List>{};
    var total = 0;
    for (final name in <String>{...pack.referencedImages, ...pack.referencedFonts}) {
      final isImage = pack.referencedImages.contains(name);
      final singleCap = isImage ? themeImageByteCap : themeFontByteCap;
      final remaining = themeTotalAssetByteCap - total;
      final bytes = await _themeExportRead(
        File('$folder/$name'),
        remaining < singleCap ? remaining : singleCap,
      );
      total += bytes.length;
      assets[name] = bytes;
    }
    final checked = ThemePackValidator.validateParts(mergedJson, assets);
    final archive = Archive()
      ..add(ArchiveFile.bytes('theme.json', utf8.encode(jsonEncode(checked.json))));
    for (final entry in checked.assets.entries) {
      archive.add(ArchiveFile.bytes(entry.key, entry.value));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    ThemePackValidator.validateArchive(bytes);
    final target = File(destination);
    if (await target.exists()) {
      throw const ThemeImportException(ThemeImportProblem.storage, 'export_exists');
    }
    await target.parent.create(recursive: true);
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination);
  } on ThemeValidationException catch (error) {
    throw _mapValidationProblem(error);
  } on FormatException {
    throw const ThemeImportException(ThemeImportProblem.badPack);
  } on FileSystemException catch (error) {
    throw ThemeImportException(ThemeImportProblem.storage, null, error.osError?.errorCode);
  } finally {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on FileSystemException {
      // Ignored.
    }
  }
}
