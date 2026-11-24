// The companion's downloaded assets (docs/design/companion.md): a zip with the
// Live2D runtime (`runtime/`) and one character (`character/`). Neither is in
// the repository; a build may carry one inside (companionBundledPack below).
//
// What's checked on the way in, because the page runs this content in a WebView:
//  - `runtime/` is code, so it must match the digest pinned below, whoever made
//    the zip. That's what lets a character come from anywhere.
//  - `character/` is data only: an extension allow-list, no scripts or HTML.
//  - every path stays inside its folder; size and count are capped.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../pets/pet_name_alias.dart';
import '../pets/pet_pack_validator.dart' show decodePetJson, PetValidationException, pngSize;
import '../workshop/workshop_export.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_receipt.dart';
import 'companion_adapt_contract.dart'
    show companionAdaptParams, companionAdaptEmotions, companionAdaptActions, companionAdaptZones;
import 'companion_lines.dart';

part 'companion_pack_integrity.dart';
part 'companion_pack_export.dart';

/// `runtime digest` printed by tooling/companion/build-pack.mjs.
const companionRuntimeDigest = '20e4e35ce1de09bd9017197363a96afdb4d9fc045d574fb669ebf21b4bc92e81';

/// Where the pack downloads from. Null until one is published: import works
/// without it. (url, bytes, sha256)
const CompanionPackSource? companionPackSource = null;

/// A pack that comes inside the app, unpacked the first time the room opens.
/// It isn't in the repository (its model's terms aren't settled for that):
/// builds made with the zip in place carry it, the others simply have none.
const companionBundledPack = 'assets/companion/whale-girl.zip';
const companionBundledCharacterKey = 'builtin:companion/whale-girl';
const _characterIdentityName = '.companion-character.json';

/// When a pack went onto the shelf, for the roster's order.
const _shelvedAtName = '.companion-shelved';

/// Written before the active pack goes onto the shelf: the shelf folder that
/// recovery activates if a swap is cut short with nothing active.
const _fallbackName = 'pack.fallback';

/// Whether this build carries the pack, without reading it.
Future<bool> hasBundledCompanionPack([AssetBundle? bundle]) async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle ?? rootBundle);
    return manifest.listAssets().contains(companionBundledPack);
  } on Object {
    return false;
  }
}

/// The bundled pack's bytes, or null when this build has none.
Future<Uint8List?> loadBundledCompanionPack([AssetBundle? bundle]) async {
  final assets = bundle ?? rootBundle;
  try {
    if (!await hasBundledCompanionPack(assets)) return null;
    final data = await assets.load(companionBundledPack);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on Object {
    return null;
  }
}

@immutable
class CompanionPackSource {
  const CompanionPackSource({required this.urls, required this.bytes, required this.sha256});
  final List<String> urls;
  final int bytes;
  final String sha256;
}

enum CompanionPackProblem {
  notAPack,
  unsafePath,
  tooLarge,
  forbiddenFile,
  runtimeMismatch,
  noRuntime,
  noModel,

  /// A Cubism 2 model (`.moc` and `model.json`): the runtime only reads moc3.
  legacyModel,
  storage,
}

class CompanionPackException implements Exception {
  const CompanionPackException(this.problem, [this.detail, this.osErrorCode]);
  final CompanionPackProblem problem;
  final String? detail;
  final int? osErrorCode;

  @override
  String toString() => 'CompanionPackException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// What the page shows about the installed character.
@immutable
class CompanionCharacter {
  const CompanionCharacter({this.name, this.author, this.license, this.source, this.lines});

  factory CompanionCharacter.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    String? text(String key) =>
        map[key] is String && (map[key] as String).trim().isNotEmpty ? map[key] as String : null;
    return CompanionCharacter(
      name: text('name'),
      author: text('author'),
      license: text('license'),
      source: text('source'),
      lines: switch (CompanionLines.parse(map['lines'])) {
        final lines when lines.isEmpty => null,
        final lines => lines,
      },
    );
  }

  final String? name;
  final String? author;
  final String? license;
  final String? source;

  /// Her own words for touches and her things, when the pack brings them.
  final CompanionLines? lines;
}

/// One installed character: the active one or one on the shelf.
@immutable
class CompanionRosterEntry {
  const CompanionRosterEntry({
    required this.key,
    required this.character,
    required this.workshop,
    required this.active,
    required this.cover,
  });

  /// The same key [CompanionPackStore.characterKey] gives once she's active.
  final String key;
  final CompanionCharacter character;
  final WorkshopReceipt? workshop;
  final bool active;

  /// `character/preview.png`, which a Workshop upload carries as its cover.
  final File? cover;
}

const _maxBytes = 400 * 1024 * 1024;
const _maxFiles = 4000;
const _dataExtensions = {'.json', '.moc3', '.png', '.jpg', '.jpeg', '.webp', '.wav', '.mp3', '.txt', '.md'};

/// The recipe in build-pack.mjs: over sorted `name\0sha256hex\n`.
String runtimeDigest(Map<String, String> sha256ByName) {
  final names = sha256ByName.keys.toList()..sort();
  return sha256.convert(utf8.encode([for (final n in names) '$n\u0000${sha256ByName[n]}\n'].join())).toString();
}

/// Whether [path] is a plain relative path with no way out of its folder.
bool isSafePackPath(String path) {
  if (path.isEmpty || path.contains('\\') || path.startsWith('/') || path.contains('\u0000')) return false;
  return path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');
}

class CompanionPackStore {
  CompanionPackStore(this.root, {this.expectedRuntime = companionRuntimeDigest, this.shelve = true})
    : _openOutput = null;

  /// Runs the same install transaction in this isolate with one replaceable
  /// output boundary. Production construction keeps the compute isolate.
  @visibleForTesting
  CompanionPackStore.withOutputForTesting(
    this.root, {
    this.expectedRuntime = companionRuntimeDigest,
    this.shelve = true,
    required OutputFileStream Function(String path) this._openOutput,
  });

  /// The app's private folder for this; the active pack lands in
  /// `<root>/pack`, the others in `<root>/shelf/<folder>`.
  final Directory root;
  final String expectedRuntime;

  /// Whether installing a different character keeps the active one on the
  /// shelf. Off, an install replaces it, as a single-model store wants.
  final bool shelve;
  final OutputFileStream Function(String path)? _openOutput;

  Directory get _shelf => Directory('${root.path}/shelf');
  Directory _shelved(String key) => Directory('${_shelf.path}/${_shelfName(key)}');

  static final _roots = <String, _CompanionRootState>{};
  _CompanionRootState get _state =>
      _roots.putIfAbsent(root.absolute.uri.normalizePath().toString(), _CompanionRootState.new);

  /// Shared across all stores for this root. Subscribe before an asynchronous
  /// availability check, and discard its result if this number changed.
  int get revision => _state.revision;
  Stream<int> get revisions => _state.changes.stream;

  /// The owner closes its WebView and then its server here. A failed hook
  /// aborts the change before any live directory moves. Do not await another
  /// operation on this store from a hook: it already holds the store queue.
  void Function() beforeChanges(Future<void> Function() stopReaders) {
    final state = _state;
    state.before.add(stopReaders);
    return () => state.before.remove(stopReaders);
  }

  Future<T> _exclusive<T>(Future<T> Function() body, {bool recover = true}) {
    final state = _state;
    final run = state.queue.then((_) async {
      if (recover) await _recover();
      return body();
    });
    state.queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// [stopReaders] is false for changes that leave `pack/` alone.
  Future<T> _change<T>(Future<T> Function() body, {bool stopReaders = true}) async {
    final state = _state;
    state.changes.add(++state.revision);
    try {
      for (final hook in [if (stopReaders) ...state.before]) {
        try {
          await hook();
        } on Object {
          throw const CompanionPackException(CompanionPackProblem.storage, 'companion_readers_busy');
        }
      }
      return await body();
    } finally {
      state.changes.add(++state.revision);
    }
  }

  Future<void> _recover() async {
    final previous = Directory('${root.path}/pack.previous');
    if (await previous.exists()) {
      if (!await pack.exists()) {
        await _change(() => previous.rename(pack.path));
      } else {
        await _forget(previous);
      }
    }
    // After pack.previous, which may already have brought one back: a swap
    // cut short once the active pack was on the shelf ends with the folder
    // the note names active, so one pack is active again and none is lost.
    final fallback = File('${root.path}/$_fallbackName');
    if (await fallback.exists()) {
      if (!await pack.exists()) {
        final named = Directory('${_shelf.path}/${await fallback.readAsString()}');
        if (await named.exists()) await _change(() => named.rename(pack.path));
      }
      await fallback.delete();
    }
    await _forget(Directory('${root.path}/pack.staging'));
    await _forget(Directory('${root.path}/pack.trash'));
  }

  Directory get pack => Directory('${root.path}/pack');

  Future<bool> installed() => _exclusive(
    () async =>
        await File('${pack.path}/runtime/live2dcubismcore.min.js').exists() &&
        await File('${pack.path}/character/index.json').exists(),
  );

  /// A file-integrity gate for offering the floating renderer. The pinned
  /// runtime, index and all model references must be complete. This cannot
  /// prove that a device's WebGL/Core will render the model successfully.
  Future<String?> unavailableReason() => _unavailableReason(recover: true);

  /// A cover is optional and must never modify the pack being submitted.
  Future<String?> coverUnavailableReason() => _unavailableReason(recover: false);

  Future<String?> _unavailableReason({required bool recover}) async {
    try {
      return await _exclusive(() => compute(_packUnavailable, (pack.path, expectedRuntime)), recover: recover);
    } on CompanionPackException catch (error) {
      return error.detail == 'companion_readers_busy' ? error.detail : 'companion_storage';
    } on FileSystemException {
      return 'companion_storage';
    }
  }

  Future<WorkshopReceipt?> workshopReceipt() => _exclusive(() => WorkshopReceipt.read(pack));

  /// A source key for the phone database's opaque character ID. Package
  /// metadata and display names cannot supply a local installation identity.
  Future<String?> characterKey() => _exclusive(() => _characterKeyOf(pack));

  /// Name and source belong to the same installed pack, even if another
  /// window installs a different character while the caller is awaiting.
  Future<({CompanionCharacter character, String? key})> characterIdentity() =>
      _exclusive(() async => (character: await _characterOf(pack), key: await _characterKeyOf(pack)));

  /// The active character's key, to keep her on the shelf when another one
  /// comes. A pack that can't be named is replaced instead, as before.
  Future<String?> _keepableKey() async {
    try {
      return await _characterKeyOf(pack);
    } on CompanionPackException {
      return null;
    } on WorkshopException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The active character first, then the shelf, most recently shelved
  /// first. A folder that can't be read is left out, not fatal. Read without
  /// the store's queue, and without naming anyone: it only shows who is here,
  /// and must not hold up her stage or an install. A change under way can
  /// leave it a step behind until the next read.
  Future<List<CompanionRosterEntry>> roster() async {
    final active = await _rosterEntry(pack, active: true);
    final shelved = <(CompanionRosterEntry, int)>[];
    if (await _shelf.exists()) {
      await for (final folder in _shelf.list(followLinks: false)) {
        if (folder is! Directory) continue;
        if (await _rosterEntry(folder, active: false) case final entry?) shelved.add(entry);
      }
    }
    shelved.sort((a, b) => b.$2.compareTo(a.$2));
    return [if (active != null) active.$1, for (final (entry, _) in shelved) entry];
  }

  Future<(CompanionRosterEntry, int)?> _rosterEntry(Directory folder, {required bool active}) async {
    try {
      final key = await _characterKeyOf(folder, assign: false);
      if (key == null) return null;
      final cover = File('${folder.path}/character/preview.png');
      final stamp = File('${folder.path}/$_shelvedAtName');
      return (
        CompanionRosterEntry(
          key: key,
          character: await _characterOf(folder),
          workshop: await WorkshopReceipt.read(folder),
          active: active,
          cover: await cover.exists() ? cover : null,
        ),
        await stamp.exists() ? int.tryParse(await stamp.readAsString()) ?? 0 : 0,
      );
    } on Exception {
      return null;
    }
  }

  /// The shelved character with [key] becomes active and the active one goes
  /// onto the shelf. Once the active pack is shelved, pack.fallback names the
  /// chosen one, so recovery from a crash in between activates it.
  Future<void> activate(String key) => _exclusive(
    () => _change(() async {
      final chosen = _shelved(key);
      if (!await chosen.exists()) {
        throw const CompanionPackException(CompanionPackProblem.storage, 'companion_not_shelved');
      }
      final previous = Directory('${root.path}/pack.previous');
      final current = await _keepableKey();
      final outgoing = current == null ? null : _shelved(current);
      if (outgoing != null) {
        await _shelve(root.path, outgoing, _shelfName(key));
      } else if (await pack.exists()) {
        await _forget(previous);
        await pack.rename(previous.path);
      }
      try {
        await chosen.rename(pack.path);
      } on FileSystemException {
        if (outgoing != null) {
          await outgoing.rename(pack.path);
          await _clearFallback(root.path);
        } else if (await previous.exists()) {
          await previous.rename(pack.path);
        }
        rethrow;
      }
      await _forget(previous);
      await _clearFallback(root.path);
    }),
  );

  /// Deletes the shelved character with [key]; the active one stays as is.
  Future<void> removeShelved(String key) => _exclusive(
    () => _change(stopReaders: false, () async {
      final shelved = _shelved(key);
      if (!await shelved.exists()) return;
      final trash = Directory('${root.path}/pack.trash');
      if (await trash.exists()) await trash.delete(recursive: true);
      await shelved.rename(trash.path);
      await _forget(trash);
    }),
  );

  /// Exports model data only. User preferences are never read. Names/persona
  /// must be supplied explicitly for this export; otherwise a neutral name
  /// and no persona are written. Audio, runtime and local receipts stay out.
  Future<File> exportZip(
    File destination, {
    String? name,
    String? persona,
    String? author,
    String? license,
    String? source,
  }) => _exclusive(() async {
    final target = await workshopExportTarget(destination);
    final output = target.path;
    final home = await root.exists()
        ? await root.resolveSymbolicLinks()
        : root.absolute.uri.normalizePath().toFilePath();
    final prefix = home.endsWith(Platform.pathSeparator) ? home : '$home${Platform.pathSeparator}';
    if (output == home || output.startsWith(prefix)) throw const CompanionPackException(CompanionPackProblem.storage);
    await workshopCommitExport(
      target,
      (staging) => compute(_exportCompanion, (
        pack.path,
        staging.path,
        <String, String>{'name': ?name, 'persona': ?persona, 'author': ?author, 'license': ?license, 'source': ?source},
      )),
    );
    return destination;
  });

  /// The extra disk space a character-only install needs to copy its runtime.
  Future<int> runtimeBytes() => _exclusive(() async {
    final runtime = Directory('${pack.path}/runtime');
    if (!await runtime.exists()) return 0;
    var count = 0;
    await for (final file in runtime.list(recursive: true, followLinks: false)) {
      if (file is File) count += await file.length();
    }
    return count;
  });

  Future<CompanionCharacter> character() => _exclusive(() => _characterOf(pack));

  /// Unpacks [zip] next to the current pack and swaps it in. If the swap fails,
  /// attempts to restore the old pack; a failed restoration leaves it in
  /// `pack.previous`. A zip with only `character/` keeps the installed runtime.
  /// The same character (same key) is replaced, wherever she was; a different
  /// active one goes onto the shelf (see [shelve]).
  Future<void> install(String zip, {WorkshopReceipt? workshop, bool replaceExisting = false}) =>
      _installPackage(zip, workshop: workshop, replaceExisting: replaceExisting);

  /// Only the app's actual bundled-asset entry calls this. An imported ZIP
  /// cannot opt into the built-in character's phone memories.
  Future<void> installBundled(String zip) => _installPackage(zip, bundled: true);

  Future<void> _installPackage(
    String zip, {
    WorkshopReceipt? workshop,
    bool replaceExisting = false,
    bool bundled = false,
  }) => _exclusive(
    () => _change(() async {
      if (workshop != null && workshop.kind != 'companion') workshopInvalid('workshop_install_record');
      final key = workshop == null ? (bundled ? companionBundledCharacterKey : _newCharacterKey()) : null;
      final incoming = key ?? _workshopKey(workshop!);
      final current = shelve ? await _keepableKey() : null;
      if (workshop != null) {
        // Only an active pack this install replaces needs the Workshop's
        // rules or the person's say; a different one just goes on the shelf.
        if (current == null || current == incoming) {
          await workshopCheckReplacement(pack, workshop, replaceExisting: replaceExisting);
        }
        // A shelved copy of the same item is replaced too, under the same rules.
        await workshopCheckReplacement(_shelved(incoming), workshop, replaceExisting: true);
      }
      final _InstallArgs args = (
        zip,
        root.path,
        expectedRuntime,
        workshop == null ? null : jsonEncode(workshop.toJson()),
        key,
        _shelfName(incoming),
        current == null || current == incoming ? null : _shelfName(current),
      );
      final openOutput = _openOutput;
      if (openOutput == null) {
        await compute(_install, args);
      } else {
        await _installWithOutput(args, openOutput);
      }
    }),
  );

  Future<void> remove({WorkshopReceipt? expectedWorkshop}) => _exclusive(
    () => _change(() async {
      if (expectedWorkshop != null) await workshopCheckRemoval(pack, expectedWorkshop);
      final trash = Directory('${root.path}/pack.trash');
      if (await trash.exists()) await trash.delete(recursive: true);
      // A leftover backup or swap note must never resurrect an intentional
      // removal. The shelf stays; nothing is activated in her place.
      final previous = Directory('${root.path}/pack.previous');
      if (await previous.exists()) await previous.delete(recursive: true);
      await _clearFallback(root.path);
      if (await pack.exists()) await pack.rename(trash.path);
      await _forget(trash);
    }),
  );
}

class _CompanionRootState {
  Future<void> queue = Future.value();
  int revision = 0;
  final changes = StreamController<int>.broadcast(sync: true);
  final before = <Future<void> Function()>[];
}

/// (zip, root, expected runtime, receipt JSON, identity key to write, the
/// newcomer's shelf folder, the active pack's shelf folder or null to
/// replace it).
typedef _InstallArgs = (String, String, String, String?, String?, String, String?);

Future<void> _install(_InstallArgs args) => _installWithOutput(args, (path) => OutputFileStream(path));

Future<void> _installWithOutput(_InstallArgs args, OutputFileStream Function(String path) openOutput) async {
  final (zipPath, rootPath, expected, receiptJson, characterKey, incomingFolder, outgoingFolder) = args;
  final staging = Directory('$rootPath/pack.staging');
  final previous = Directory('$rootPath/pack.previous');
  final live = Directory('$rootPath/pack');
  InputFileStream? input;
  var succeeded = false;
  try {
    input = InputFileStream(zipPath);
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      throw const CompanionPackException(CompanionPackProblem.notAPack);
    }

    // What an archiver adds on its own (macOS's resource forks, Finder's notes).
    bool junk(String name) => name.startsWith('__MACOSX/') || name.split('/').last == '.DS_Store';
    final files = archive.files.where((f) => f.isFile && !junk(f.name)).toList();
    if (files.isEmpty) throw const CompanionPackException(CompanionPackProblem.notAPack);
    if (files.length > _maxFiles) throw const CompanionPackException(CompanionPackProblem.tooLarge);

    // A pack (runtime/ and character/), or a model as it comes: its folder
    // zipped, model3.json and all, which goes under character/ beside the
    // installed runtime. What the stage can't use in a bare model (the
    // editor's .cmo3, a .psd) is left behind rather than refused.
    final pack = files.any((f) => f.name.startsWith('runtime/') || f.name.startsWith('character/'));
    final targets = <(ArchiveFile, String)>[];
    if (pack) {
      for (final file in files) {
        targets.add((file, file.name));
      }
    } else {
      if (!files.any((f) => f.name.toLowerCase().endsWith('.model3.json'))) {
        final legacy = files.any((f) => f.name.toLowerCase().endsWith('.moc'));
        throw CompanionPackException(legacy ? CompanionPackProblem.legacyModel : CompanionPackProblem.noModel);
      }
      final tops = {for (final f in files) f.name.split('/').first};
      final strip = tops.length == 1 && files.every((f) => f.name.contains('/')) ? '${tops.single}/' : '';
      for (final file in files) {
        final name = file.name.substring(strip.length);
        if (!_dataExtensions.contains(_extension(name))) continue;
        targets.add((file, 'character/$name'));
      }
    }

    var declared = 0;
    final aliases = <String>{};
    // Generated root files must not create aliases of an imported filename.
    // Exact canonical inputs keep their existing preserve/rebuild behavior.
    final generatedNames = {
      for (final name in ['character/character.json', 'character/index.json']) petNameAlias(name): name,
    };
    for (final (file, name) in targets) {
      if (!isSafePackPath(name) || (!name.startsWith('runtime/') && !name.startsWith('character/'))) {
        throw CompanionPackException(CompanionPackProblem.unsafePath, file.name);
      }
      if (file.isSymbolicLink) throw CompanionPackException(CompanionPackProblem.forbiddenFile, file.name);
      final alias = petNameAlias(name);
      final generatedName = generatedNames[alias];
      if ((generatedName != null && name != generatedName) || !aliases.add(alias)) {
        throw const CompanionPackException(CompanionPackProblem.unsafePath);
      }
      if (name.startsWith('character/') && !_dataExtensions.contains(_extension(name))) {
        throw CompanionPackException(CompanionPackProblem.forbiddenFile, file.name);
      }
      declared += file.size;
      if (declared > _maxBytes) throw const CompanionPackException(CompanionPackProblem.tooLarge);
    }

    final runtimeHashes = <String, String>{};
    final characterFiles = <String>[];
    var written = 0;
    for (final (file, name) in targets) {
      final target = File('${staging.path}/$name');
      await target.parent.create(recursive: true);
      final output = openOutput(target.path);
      try {
        file.writeContent(output);
      } on Object catch (error, stack) {
        try {
          await output.close();
        } on Object {
          // Cleanup must not replace the primary extraction failure.
        }
        if (error is FileSystemException) rethrow;
        Error.throwWithStackTrace(CompanionPackException(CompanionPackProblem.notAPack, file.name), stack);
      }
      await output.close();
      // A header can lie about the size; what landed on disk can't.
      written += await target.length();
      if (written > _maxBytes) throw const CompanionPackException(CompanionPackProblem.tooLarge);
      if (name.startsWith('runtime/')) {
        runtimeHashes[name] = (await sha256.bind(target.openRead()).first).toString();
      } else {
        characterFiles.add(name.substring('character/'.length));
      }
    }

    if (runtimeHashes.isNotEmpty) {
      if (runtimeDigest(runtimeHashes) != expected) {
        throw const CompanionPackException(CompanionPackProblem.runtimeMismatch);
      }
    } else {
      final current = Directory('${live.path}/runtime');
      if (!await current.exists()) throw const CompanionPackException(CompanionPackProblem.noRuntime);
      await _copy(current, Directory('${staging.path}/runtime'));
    }
    if (!characterFiles.any((f) => f.toLowerCase().endsWith('.model3.json'))) {
      throw const CompanionPackException(CompanionPackProblem.noModel);
    }
    // A bare model has no character.json: its model3.json (the shallowest)
    // and a name from it; the rest the person sets in the app.
    if (!characterFiles.contains('character.json')) {
      final model = characterFiles.where((f) => f.toLowerCase().endsWith('.model3.json')).toList()
        ..sort((a, b) => '/'.allMatches(a).length.compareTo('/'.allMatches(b).length));
      final name = model.first.split('/').last.replaceFirst(RegExp(r'\.model3\.json$', caseSensitive: false), '');
      await File('${staging.path}/character/character.json')
          .writeAsString(jsonEncode({'schema': 1, 'name': name, 'model': model.first}));
      characterFiles.add('character.json');
    }
    await File('${staging.path}/character/index.json').writeAsString(jsonEncode(characterFiles));

    if (receiptJson != null) {
      // Workshop character-only payloads may not smuggle a runtime, a stale
      // generated index or the local receipt into the published archive.
      if (targets.any((item) => !item.$2.startsWith('character/') || item.$2 == 'character/index.json')) {
        throw const CompanionPackException(CompanionPackProblem.forbiddenFile);
      }
      final reason = await _packUnavailable((staging.path, expected));
      if (reason != null) throw CompanionPackException(CompanionPackProblem.notAPack, reason);
      await File('${staging.path}/$workshopReceiptName').writeAsString(receiptJson, flush: true);
    }
    if (characterKey != null) await _writeCharacterKey(staging, characterKey);

    // The same character's old pack, active or shelved, waits in
    // pack.previous and is discarded only after the new one is live. If
    // promotion fails, restore it; if that also fails, keep pack.previous for
    // recovery. A different active character goes onto the shelf first, so
    // pack.previous can never hold her.
    await _forget(previous);
    final shelved = Directory('$rootPath/shelf/$incomingFolder');
    final outgoing = outgoingFolder != null && await live.exists() ? outgoingFolder : null;
    final Directory? replaced;
    if (outgoing != null) {
      await _shelve(rootPath, Directory('$rootPath/shelf/$outgoing'), outgoing);
      replaced = await shelved.exists() ? shelved : null;
    } else {
      replaced = await live.exists() ? live : (await shelved.exists() ? shelved : null);
    }
    if (replaced != null) await replaced.rename(previous.path);
    try {
      await staging.rename(live.path);
    } on FileSystemException {
      if (replaced != null) await previous.rename(replaced.path);
      if (outgoing != null) {
        await Directory('$rootPath/shelf/$outgoing').rename(live.path);
        await _clearFallback(rootPath);
      }
      rethrow;
    }
    await _forget(previous);
    // Still there only if an active pack that couldn't be named was replaced.
    await _forget(shelved);
    if (outgoing != null) await _clearFallback(rootPath);
    succeeded = true;
  } on CompanionPackException {
    await _forget(staging);
    rethrow;
  } on FileSystemException catch (error, stack) {
    await _forget(staging);
    Error.throwWithStackTrace(
      CompanionPackException(CompanionPackProblem.storage, error.osError?.message, error.osError?.errorCode),
      stack,
    );
  } finally {
    try {
      await input?.close();
    } on Object {
      // Preserve the primary install error if input cleanup also fails.
      if (succeeded) rethrow;
    }
  }
}

String _newCharacterKey() {
  final random = math.Random.secure();
  return 'local:${base64Url.encode(List<int>.generate(18, (_) => random.nextInt(256)))}';
}

String _workshopKey(WorkshopReceipt workshop) =>
    'workshop:${jsonEncode([workshop.origin.toString(), workshop.kind, workshop.id])}';

/// A key holds `:`, `/` and a whole origin; its hash is a folder name.
String _shelfName(String key) => sha256.convert(utf8.encode(key)).toString().substring(0, 32);

/// [assign]: a pre-v2 pack without an identity gets one now (otherwise null).
Future<String?> _characterKeyOf(Directory pack, {bool assign = true}) async {
  if (!await File('${pack.path}/runtime/live2dcubismcore.min.js').exists() ||
      !await File('${pack.path}/character/index.json').exists()) {
    return null;
  }
  final workshop = await WorkshopReceipt.read(pack);
  if (workshop != null) return _workshopKey(workshop);
  final identity = File('${pack.path}/$_characterIdentityName');
  if (await identity.exists()) {
    if (await identity.length() > 256) {
      throw const CompanionPackException(CompanionPackProblem.storage, 'companion_character_identity');
    }
    final value = jsonDecode(await identity.readAsString());
    final key = value is Map && value['schema'] == 1 ? value['key'] : null;
    if (key is! String ||
        (key != companionBundledCharacterKey && !RegExp(r'^local:[A-Za-z0-9_-]{24}$').hasMatch(key))) {
      throw const CompanionPackException(CompanionPackProblem.storage, 'companion_character_identity');
    }
    return key;
  }
  // A pre-v2 local installation has no trustworthy role identity. Assign
  // one to this actual pack; do not infer it from its name or runtime.
  if (!assign) return null;
  final key = _newCharacterKey();
  await _writeCharacterKey(pack, key);
  return key;
}

Future<CompanionCharacter> _characterOf(Directory pack) async {
  try {
    return CompanionCharacter.fromJson(jsonDecode(await File('${pack.path}/character/character.json').readAsString()));
  } catch (_) {
    return const CompanionCharacter();
  }
}

/// Moves the active pack to [target] on the shelf. The note goes down first:
/// if nothing is active after a crash, recovery activates shelf/[fallback].
Future<void> _shelve(String rootPath, Directory target, String fallback) async {
  final live = Directory('$rootPath/pack');
  await File('${live.path}/$_shelvedAtName').writeAsString('${DateTime.now().microsecondsSinceEpoch}', flush: true);
  await File('$rootPath/$_fallbackName').writeAsString(fallback, flush: true);
  // A crash between promoting a character and dropping her older shelved
  // copy is the only way one can already be there.
  await _forget(target);
  await target.parent.create(recursive: true);
  await live.rename(target.path);
}

Future<void> _clearFallback(String rootPath) async {
  final note = File('$rootPath/$_fallbackName');
  if (await note.exists()) await note.delete();
}

Future<void> _writeCharacterKey(Directory directory, String key) async {
  final destination = '${directory.path}/$_characterIdentityName';
  final temporary = File('$destination.tmp');
  await temporary.writeAsString(jsonEncode({'schema': 1, 'key': key}), flush: true);
  await temporary.rename(destination);
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

Future<void> _copy(Directory from, Directory to) async {
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final target = File('${to.path}/${entity.path.substring(from.path.length + 1)}');
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
}

Future<void> _forget(Directory staging) async {
  try {
    if (await staging.exists()) await staging.delete(recursive: true);
  } on FileSystemException {
    // The next install starts by clearing it again.
  }
}
