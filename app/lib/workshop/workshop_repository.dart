import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';

import '../companion/companion_pack.dart';
import '../pets/pet_library.dart';
import '../themes/theme_library.dart';
import '../update/downloader.dart';
import '../update/installer.dart';
import '../update/update_config.dart' show DownloadUrl;
import '../update/update_http.dart';
import 'workshop_client.dart';
import 'workshop_export.dart';
import 'workshop_http.dart';
import 'workshop_models.dart';
import 'workshop_preview.dart';
import 'workshop_receipt.dart';

export '../update/downloader.dart' show CancelToken, DownloadProgress;

/// A local row can have a per-package failure without hiding its neighbours.
sealed class WorkshopLocalEntry {
  const WorkshopLocalEntry({required this.localId, this.issue});
  final String localId;
  /// Stable local diagnostic, separate from catalog availability/withdrawal.
  final String? issue;
}

/// A valid receipt remains an uninstall target even when its pack is broken.
class WorkshopInstalled extends WorkshopLocalEntry {
  const WorkshopInstalled({required super.localId, required this.receipt, super.issue});
  final WorkshopReceipt receipt;
}

/// No trusted network identity: display the error, but do not authorize an
/// expected-receipt removal or match this row to a public catalog entry.
class WorkshopInstallationIssue extends WorkshopLocalEntry {
  const WorkshopInstallationIssue({required super.localId, required String issue}) : super(issue: issue);
}

class WorkshopItemState {
  const WorkshopItemState({required this.entry, this.installed, this.unavailable, this.updateAvailable = false, this.installedWithdrawn = false});
  final WorkshopEntry entry;
  final WorkshopInstalled? installed;
  final String? unavailable;
  final bool updateAvailable;
  final bool installedWithdrawn;
}

/// Installed resources remain visible when their public entry disappears.
/// A withdrawn release is still removable and is never silently reinstalled.
class WorkshopInstalledState {
  const WorkshopInstalledState({required this.installed, this.entry, this.unavailable,
    this.updateAvailable = false, this.installedWithdrawn = false});
  final WorkshopLocalEntry installed;
  final WorkshopEntry? entry;
  final String? unavailable;
  final bool updateAvailable;
  final bool installedWithdrawn;
}

/// The production implementation calls the existing package installers. This
/// seam lets orchestration tests prove that rejected downloads never install.
abstract interface class WorkshopPackages {
  Future<List<WorkshopLocalEntry>> installed();
  Future<int> copyOverhead(String kind);
  Future<WorkshopInstalled> install(File archive, WorkshopReceipt receipt, {required bool replaceExisting});
  Future<void> remove(WorkshopInstalled installed);
}

class LocalWorkshopPackages implements WorkshopPackages {
  const LocalWorkshopPackages({required this.pets, required this.companion, this.themes});
  final PetLibrary pets;
  final CompanionPackStore companion;
  final ThemeLibrary? themes;

  @override
  Future<List<WorkshopLocalEntry>> installed() async {
    final found = await pets.workshopReceipts();
    final result = <WorkshopLocalEntry>[
      for (final entry in found.entries)
        if (entry.value.receipt case final receipt?)
          WorkshopInstalled(localId: entry.key, receipt: receipt, issue: entry.value.issue)
        else
          WorkshopInstallationIssue(localId: entry.key, issue: entry.value.issue!),
    ];
    if (themes case final themeLib?) {
      final themeFound = await themeLib.workshopReceipts();
      for (final entry in themeFound.entries) {
        if (entry.value.receipt case final receipt?) {
          result.add(WorkshopInstalled(localId: entry.key, receipt: receipt, issue: entry.value.issue));
        } else {
          result.add(WorkshopInstallationIssue(localId: entry.key, issue: entry.value.issue!));
        }
      }
    }
    // Listing isolates expected failures from this slot, including recovery.
    // Errors not converted by the store still escape this boundary.
    try {
      final character = await companion.workshopReceipt();
      if (character != null) {
        if (character.kind != 'companion') {
          workshopInvalid('workshop_install_record');
        }
        result.add(WorkshopInstalled(localId: 'companion', receipt: character));
      }
    } on WorkshopException catch (error) {
      result.add(WorkshopInstallationIssue(localId: 'companion', issue: workshopLocalError(error).code));
    } on FileSystemException catch (error) {
      result.add(WorkshopInstallationIssue(localId: 'companion', issue: workshopLocalError(error).code));
    } on CompanionPackException catch (error) {
      result.add(WorkshopInstallationIssue(localId: 'companion', issue: workshopLocalError(error).code));
    }
    return result;
  }
  @override
  Future<int> copyOverhead(String kind) async => kind == 'companion' ? await companion.runtimeBytes() : 0;

  @override
  Future<WorkshopInstalled> install(File archive, WorkshopReceipt receipt, {required bool replaceExisting}) async {
    switch (receipt.kind) {
      case 'pet':
        final result = await pets.install(archive, workshop: receipt, replaceExisting: replaceExisting);
        return WorkshopInstalled(localId: result.id, receipt: receipt);
      case 'companion':
        await companion.install(archive.path, workshop: receipt, replaceExisting: replaceExisting);
        return WorkshopInstalled(localId: 'companion', receipt: receipt);
      case 'theme':
        final themeLib = themes;
        if (themeLib == null) workshopInvalid('workshop_unsupported_kind');
        final result = await themeLib.install(archive, workshop: receipt, replaceExisting: replaceExisting);
        return WorkshopInstalled(localId: result.id, receipt: receipt);
      default: workshopInvalid('workshop_unsupported_kind');
    }
  }
  @override
  Future<void> remove(WorkshopInstalled installed) async {
    switch (installed.receipt.kind) {
      case 'pet': await pets.remove(installed.localId, expectedWorkshop: installed.receipt);
      case 'companion': await companion.remove(expectedWorkshop: installed.receipt);
      case 'theme':
        final themeLib = themes;
        if (themeLib == null) workshopInvalid('workshop_unsupported_kind');
        await themeLib.remove(installed.localId, expectedWorkshop: installed.receipt);
      default: workshopInvalid('workshop_unsupported_kind');
    }
  }
}

/// Public metadata before an archive has been exported and hashed. The actual
/// declaration of sharing rights is a separate explicit submit argument.
class WorkshopPublication {
  WorkshopPublication(Map<String, Object?> value) : _value = WorkshopMetadata.fromJson({
    ...value, 'sha256': '0' * 64, 'size': 1, 'rightsConfirmed': true,
  });
  final WorkshopMetadata _value;
  String get kind => _value.kind;
  String get id => _value.id;
  String get author => _value.author;
  String get license => _value.license;
  String get source => _value.source;
  String? get previewSource => _value.previewSource;
  WorkshopMetadata withArchive(String sha256, int size) => WorkshopMetadata.fromJson({..._value.toJson(), 'sha256': sha256, 'size': size});
}

class WorkshopPreparedUpload {
  const WorkshopPreparedUpload({required this.file, required this.metadata, required this.files});
  final File file;
  final WorkshopMetadata metadata;
  /// The UI can show exactly which archive members will be submitted.
  final List<String> files;
}

class WorkshopRepository {
  WorkshopRepository({required this.client, required this.packages, required this.downloadDirectory,
    required this.appVersion, Future<int?> Function()? freeBytes, this._hasher = sha256OfFile})
    : freeBytes = freeBytes ?? _nativeFreeBytes;
  final WorkshopClient client;
  final WorkshopPackages packages;
  final Directory downloadDirectory;
  final String appVersion;
  final Future<int?> Function() freeBytes;
  final Sha256Hasher _hasher;
  // A replacement provider may overlap a still-closing repository. The
  // downloader and cache pruning share a queue across instances of one root.
  static final _queues = <String, _WorkshopRepositoryQueue>{};
  _WorkshopRepositoryQueue get _queue => _queues.putIfAbsent(
    downloadDirectory.absolute.uri.normalizePath().toString(), _WorkshopRepositoryQueue.new);

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final queue = _queue;
    final run = queue.tail.then((_) async {
      try { return await body(); } on Object catch (error) { throw workshopLocalError(error); }
    });
    queue.tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<List<WorkshopLocalEntry>> installed() => _exclusive(packages.installed);

  Future<List<WorkshopItemState>> states(WorkshopCatalog catalog) => _exclusive(() async {
    final installed = await packages.installed();
    return [for (final entry in catalog.entries) _state(catalog, entry, installed)];
  });

  Future<List<WorkshopInstalledState>> installedStates(WorkshopCatalog catalog) => _exclusive(() async {
    final installed = await packages.installed();
    return installed.map((item) {
      if (item is! WorkshopInstalled) return WorkshopInstalledState(installed: item, unavailable: item.issue);
      final receipt = item.receipt;
      if (receipt.origin != client.origin) return WorkshopInstalledState(installed: item, unavailable: 'workshop_other_origin');
      final entry = catalog.find(receipt.kind, receipt.id);
      final withdrawn = catalog.blocked(receipt.kind, receipt.id, receipt.version);
      if (receipt.kind == 'companion' && !catalog.features.companion) {
        return WorkshopInstalledState(installed: item, entry: entry, installedWithdrawn: withdrawn,
          unavailable: 'workshop_companion_disabled');
      }
      if (entry == null) {
        return WorkshopInstalledState(installed: item, installedWithdrawn: withdrawn,
          unavailable: withdrawn ? 'workshop_version_withdrawn' : 'workshop_not_found');
      }
      final state = _state(catalog, entry, [item]);
      return WorkshopInstalledState(installed: item, entry: entry, unavailable: state.unavailable,
        updateAvailable: state.updateAvailable, installedWithdrawn: state.installedWithdrawn);
    }).toList();
  });

  WorkshopItemState _state(WorkshopCatalog catalog, WorkshopEntry entry, List<WorkshopLocalEntry> installed) {
    final meta = entry.metadata;
    final old = installed.whereType<WorkshopInstalled>().where((item) => item.receipt.origin == client.origin && item.receipt.identity == meta.identity).firstOrNull;
    var unavailable = catalog.unavailable(entry, appVersion);
    var update = false;
    if (old != null) {
      final comparison = WorkshopVersion.tryParse(meta.version)!.compareTo(WorkshopVersion.tryParse(old.receipt.version)!);
      if (comparison == 0 && meta.sha256 != old.receipt.sha256) unavailable = 'workshop_version_rewritten';
      update = comparison > 0 && unavailable == null;
    }
    return WorkshopItemState(entry: entry, installed: old, unavailable: unavailable, updateAvailable: update,
      installedWithdrawn: old != null && catalog.blocked(old.receipt.kind, old.receipt.id, old.receipt.version));
  }

  Future<WorkshopEntry> _current(WorkshopEntry requested) async {
    final catalog = (await client.catalog(requireFresh: true)).catalog;
    final m = requested.metadata;
    if (!m.supported) workshopInvalid('workshop_unsupported_kind');
    if (m.kind == 'companion' && !catalog.features.companion) workshopInvalid('workshop_companion_disabled');
    if (catalog.blocked(m.kind, m.id, m.version)) workshopInvalid('workshop_version_withdrawn');
    final now = catalog.find(m.kind, m.id);
    if (now == null) workshopInvalid('workshop_not_found');
    final reason = catalog.unavailable(now, appVersion);
    if (reason != null) workshopInvalid(reason);
    if (now.metadata.version != m.version || now.metadata.sha256 != m.sha256 || now.metadata.size != m.size) workshopInvalid('workshop_catalog_changed');
    return now;
  }

  Future<void> _space(int required) async {
    final available = await freeBytes();
    if (available != null && available < required) workshopInvalid('workshop_no_space');
  }

  /// One resumable archive slot. Only this module's digest filenames are
  /// pruned; unrelated files and directories are never recursively removed.
  Future<void> _keepDownload(String sha256) async {
    if (!await downloadDirectory.exists()) return;
    await for (final entity in downloadDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!RegExp(r'^[a-f0-9]{64}\.zip(?:\.part)?$').hasMatch(name)) continue;
      if (name == '$sha256.zip' || name == '$sha256.zip.part') continue;
      await entity.delete();
    }
  }

  Future<WorkshopInstalled> install(WorkshopEntry requested, {bool replaceExisting = false, CancelToken? cancel,
    void Function(DownloadProgress)? onProgress, void Function()? onVerifying}) => _exclusive(() async {
    void cancelled() { if (cancel?.isCancelled ?? false) workshopInvalid('workshop_cancelled'); }
    cancelled();
    final entry = await _current(requested), meta = entry.metadata;
    await _keepDownload(meta.sha256);
    final overhead = await packages.copyOverhead(meta.kind);
    // Existing bytes already consume disk; this deliberately reserves a full
    // new ZIP, a full staging tree and a little metadata/journal headroom.
    final installSpace = workshopExpandedBytes + overhead + 4 * 1024 * 1024;
    await _space(meta.size + installSpace);
    cancelled();
    final transport = _WorkshopDownloadHttp(client.http, client.origin.resolve(meta.archivePath), meta.size);
    final downloader = ApkDownloader(http: transport, directory: downloadDirectory, hasher: _hasher);
    final outcome = await downloader.download(fileName: '${meta.sha256}.zip', sha256: meta.sha256,
      urls: [DownloadUrl(client.origin.resolve(meta.archivePath), mirrorId: null, label: 'Workshop')], expectedSize: meta.size,
      cancel: cancel, onProgress: onProgress, onVerifying: onVerifying);
    cancelled();
    switch (outcome) {
      case DownloadCancelled(): workshopInvalid('workshop_cancelled');
      case DownloadFailed(:final failure):
        if (transport.failure case final error?) throw error;
        if (failure == DownloadFailure.storage) await _space(installSpace);
        workshopInvalid(switch (failure) {
          DownloadFailure.network => 'workshop_network', DownloadFailure.unavailable => 'workshop_download_unavailable',
          DownloadFailure.checksum => 'workshop_sha_mismatch', DownloadFailure.storage => 'workshop_storage',
        });
      case DownloadDone(:final file):
        if (await file.length() != meta.size) workshopInvalid('workshop_size_mismatch');
        await _space(installSpace);
        // Revalidate after the space query, immediately before installer
        // handoff. Later withdrawals do not revoke an installation in flight.
        await _current(entry);
        cancelled();
        return packages.install(file, WorkshopReceipt(kind: meta.kind, id: meta.id, version: meta.version, sha256: meta.sha256, origin: client.origin), replaceExisting: replaceExisting);
    }
  });

  Future<void> uninstall(WorkshopLocalEntry installed) => _exclusive(() {
    if (installed is! WorkshopInstalled) workshopInvalid('workshop_install_record');
    return packages.remove(installed);
  });

  /// Exporting is explicit; no account settings or personal state are read.
  Future<WorkshopPreparedUpload> preparePet(PetLibrary library, String localId, File destination, WorkshopPublication publication,
    {bool petIdleDownscale = false}) => _exclusive(() async {
    if (publication.kind != 'pet') workshopInvalid('workshop_unsupported_kind');
    final file = await library.exportZip(localId, destination, publicId: publication.id,
      author: publication.author, license: publication.license, source: publication.source);
    return _prepared(file, publication, petIdleDownscale: petIdleDownscale);
  });

  Future<WorkshopPreparedUpload> prepareTheme(
    ThemeLibrary library,
    String localId,
    File destination,
    WorkshopPublication publication, {
    WorkshopPreviewInput? preview,
  }) => _exclusive(() async {
    if (publication.kind != 'theme') workshopInvalid('workshop_unsupported_kind');
    if (publication.previewSource != null && preview == null) workshopInvalid('workshop_preview_missing');
    if (preview?.source != publication.previewSource) workshopInvalid('workshop_bad_metadata');
    if (preview == null) {
      final file = await library.exportZip(
        localId,
        destination,
        publicId: publication.id,
        author: publication.author,
        license: publication.license,
        source: publication.source,
      );
      return _prepared(file, publication);
    }
    final target = await workshopExportTarget(destination);
    Directory? owned;
    try {
      await target.parent.create(recursive: true);
      final directory = await target.parent.createTemp('.workshop-theme-preview-');
      owned = directory;
      final exported = await library.exportZip(
        localId,
        File('${directory.path}/theme.zip'),
        publicId: publication.id,
        author: publication.author,
        license: publication.license,
        source: publication.source,
      );
      final bytes = await compute(workshopThemePreviewZip, (await exported.readAsBytes(), preview));
      await workshopCommitExport(target, (staging) async {
        await staging.writeAsBytes(bytes, flush: true);
      });
      return await _prepared(target, publication);
    } finally {
      final directory = owned;
      try {
        if (directory != null && await directory.exists()) await directory.delete(recursive: true);
      } on FileSystemException {
        // Ignored.
      }
    }
  });

  Future<WorkshopPreparedUpload> prepareCompanion(CompanionPackStore store, File destination, WorkshopPublication publication,
    {String? name, String? persona, WorkshopPreviewInput? preview}) => _exclusive(() async {
    if (publication.kind != 'companion') workshopInvalid('workshop_unsupported_kind');
    if (publication.previewSource != null && preview == null) workshopInvalid('workshop_preview_missing');
    if (preview?.source != publication.previewSource) workshopInvalid('workshop_bad_metadata');
    if (preview == null) {
      final file = await store.exportZip(destination, name: name, persona: persona,
        author: publication.author, license: publication.license, source: publication.source);
      return _prepared(file, publication);
    }
    final target = await workshopExportTarget(destination);
    // Preserve exportZip's source-directory boundary before creating either
    // the intermediate snapshot or the final ZIP. No live model is rewritten.
    final home = await store.root.exists() ? await store.root.resolveSymbolicLinks()
        : store.root.absolute.uri.normalizePath().toFilePath();
    final prefix = home.endsWith(Platform.pathSeparator) ? home : '$home${Platform.pathSeparator}';
    if (target.path == home || target.path.startsWith(prefix)) {
      throw const CompanionPackException(CompanionPackProblem.storage);
    }
    Directory? owned;
    try {
      await target.parent.create(recursive: true);
      final directory = await target.parent.createTemp('.workshop-preview-');
      owned = directory;
      final exported = await store.exportZip(File('${directory.path}/model.zip'), name: name, persona: persona,
        author: publication.author, license: publication.license, source: publication.source);
      final bytes = await compute(workshopCompanionPreviewZip, (await exported.readAsBytes(), preview));
      // Export has already released its queue. This writer only writes its
      // staging file; nesting store.exportZip here would wait on the same queue.
      await workshopCommitExport(target, (staging) async {
        await staging.writeAsBytes(bytes, flush: true);
      });
      return await _prepared(target, publication);
    } finally {
      final directory = owned;
      try { if (directory != null && await directory.exists()) await directory.delete(recursive: true); }
      on FileSystemException { /* Preserve the preparation result; only our private snapshot may remain. */ }
    }
  });

  Future<WorkshopPreparedUpload> _prepared(File file, WorkshopPublication publication, {bool petIdleDownscale = false}) async {
    final size = await file.length();
    if (size < 1 || size > workshopArchiveBytes) workshopInvalid('workshop_body_too_large');
    final metadata = publication.withArchive(await _hasher(file), size);
    final bytes = await workshopArchiveSnapshot(file, metadata);
    final archive = ZipDecoder().decodeBytes(bytes);
    if (publication.previewSource == 'pet-idle') {
      workshopCheckPetPreview(archive, petIdleDownscale: petIdleDownscale);
    }
    return WorkshopPreparedUpload(file: file, metadata: metadata,
      files: List.unmodifiable(archive.files.where((f) => f.isFile).map((f) => f.name).toList()..sort()));
  }
}

class _WorkshopRepositoryQueue {
  Future<void> tail = Future.value();
}

Future<int?> _nativeFreeBytes() async {
  try { return (await const ChannelUpdateInstaller().installedApp()).freeBytes; }
  on MissingPluginException { return null; }
  on PlatformException { return null; }
}

/// Known package format, content, path, size and compatibility diagnostics.
///
/// Use with an explicitly local diagnostic, not to infer its origin from the
/// string. Membership does not prove corruption or authorize removal. The
/// installed listing does not fully validate model or image contents; a valid
/// receipt with a local issue still keeps its ordinary removal fence.
///
/// Receipt, storage, missing-runtime, export-target, preview and catalog
/// availability codes keep their separate handling. This classifies the mapped
/// code, not the source exception's enum. Unlisted/future codes retain the
/// caller's fallback; an equal string from another source proves no provenance.
const Set<String> workshopPackageValidationCodes = {
  'workshop_pet_not_a_zip',
  'workshop_pet_no_pack',
  'workshop_pet_bad_pack',
  'workshop_pet_missing_sheet',
  'workshop_pet_bad_sheet',
  'workshop_pet_too_large',
  'workshop_theme_not_a_zip',
  'workshop_theme_no_pack',
  'workshop_theme_bad_pack',
  'workshop_theme_missing_asset',
  'workshop_theme_bad_asset',
  'workshop_theme_too_large',
  'workshop_companion_bad_index',
  'workshop_companion_bad_json',
  'workshop_companion_bad_metadata',
  'workshop_companion_bad_moc',
  'workshop_companion_bad_model',
  'workshop_companion_bad_png',
  'workshop_companion_bad_reference',
  'workshop_companion_changed',
  'workshop_companion_empty_file',
  'workshop_companion_forbidden_file',
  'workshop_companion_legacy_model',
  'workshop_companion_missing_file',
  'workshop_companion_missing_index',
  'workshop_companion_missing_model',
  'workshop_companion_missing_reference',
  'workshop_companion_missing_texture',
  'workshop_companion_moc_version',
  'workshop_companion_no_model',
  'workshop_companion_not_a_pack',
  'workshop_companion_runtime_incomplete',
  'workshop_companion_runtime_mismatch',
  'workshop_companion_too_large',
  'workshop_companion_unsafe_path',
};

WorkshopException workshopLocalError(Object error) {
  if (error is WorkshopException) return error;
  final int? errno;
  if (error is PetImportException) {
    errno = error.osErrorCode;
    if (error.problem != PetImportProblem.storage) return WorkshopException('workshop_pet_${_problemName(error.problem.name)}');
  } else if (error is ThemeImportException) {
    errno = error.osErrorCode;
    if (error.problem != ThemeImportProblem.storage) {
      return WorkshopException('workshop_theme_${_problemName(error.problem.name)}');
    }
  } else if (error is CompanionPackException) {
    errno = error.osErrorCode;
    if (error.detail == 'companion_readers_busy') return const WorkshopException('workshop_readers_busy');
    if (error.problem == CompanionPackProblem.noRuntime) return const WorkshopException('workshop_runtime_missing');
    if (error.detail != null && RegExp(r'^companion_[a-z_]+$').hasMatch(error.detail!)) return WorkshopException('workshop_${error.detail}');
    if (error.problem != CompanionPackProblem.storage) return WorkshopException('workshop_companion_${_problemName(error.problem.name)}');
  } else if (error is FileSystemException) {
    errno = error.osError?.errorCode;
  } else { return workshopTransportError(error); }
  return WorkshopException(const {28, 122}.contains(errno) ? 'workshop_no_space' : 'workshop_storage');
}

String _problemName(String name) => name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

class _WorkshopDownloadHttp implements UpdateHttp {
  _WorkshopDownloadHttp(this.inner, this.url, this.size);
  final WorkshopHttp inner;
  final Uri url;
  final int size;
  WorkshopException? failure;

  Never _fail(String code) {
    failure = WorkshopException(code);
    throw failure!;
  }

  @override
  Future<UpdateHttpResponse> get(Uri requested, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 15)}) async {
    if (requested != url) _fail('workshop_untrusted_origin');
    final response = await inner.get(requested, headers: headers, timeout: timeout);
    if (response.status != 200 && response.status != 206 && response.status != 416) {
      failure = await workshopResponseError(response);
      throw failure!;
    }
    if (response.status == 416) return response;
    var expected = size;
    var valid = response.headers['content-encoding'] == null || response.headers['content-encoding'] == 'identity';
    if (response.status == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(response.headers['content-range'] ?? '');
      final offset = int.tryParse(RegExp(r'^bytes=(\d+)-$').firstMatch(headers['range'] ?? '')?[1] ?? '0');
      final start = int.tryParse(range?[1] ?? ''), end = int.tryParse(range?[2] ?? ''), total = int.tryParse(range?[3] ?? '');
      valid = valid && start == offset && start != null && start >= 0 && start < size && end == size - 1 && total == size;
      if (start != null) expected = size - start;
    }
    if (!valid || response.contentLength != null && response.contentLength != expected) {
      await response.discard();
      _fail('workshop_download_range');
    }
    var seen = 0;
    // Cancellation must reach the HTTP subscription while it is waiting for
    // another chunk; an async generator can remain suspended at that await.
    final bounded = response.body.map((chunk) {
      if (chunk.length > expected - seen) _fail('workshop_size_mismatch');
      seen += chunk.length;
      return chunk;
    });
    return UpdateHttpResponse(status: response.status, headers: response.headers, contentLength: response.contentLength, body: bounded);
  }
}
