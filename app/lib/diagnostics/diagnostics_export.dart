// Hands the diagnostics bundle to Android — the share
// sheet or the phone's Downloads — the way artifacts and conversation logs
// go (`FilesChannel.saveToDownloads`, `SharePlus`).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../state/artifacts.dart' show FilesChannel, filesChannelProvider, savedInChosenPlace;
import '../l10n/l10n.dart';
import 'diagnostics_bundle.dart';

/// Where an export is; the UI says it in words.
enum DiagnosticsStep { collecting, packing, sharing, saving }

class DiagnosticsExporter {
  DiagnosticsExporter({
    required this.collect,
    required this.files,
    Future<ShareResultStatus> Function(ShareParams params)? share,
    Future<Directory> Function()? cacheRoot,
    DateTime Function()? clock,
  }) : _share = share ?? _systemShare,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _clock = clock ?? DateTime.now;

  final Future<DiagnosticsSnapshot> Function(DateTime at) collect;
  final FilesChannel files;
  final Future<ShareResultStatus> Function(ShareParams params) _share;
  final Future<Directory> Function() _cacheRoot;
  final DateTime Function() _clock;

  static Future<ShareResultStatus> _systemShare(ShareParams params) async =>
      (await SharePlus.instance.share(params)).status;

  /// Builds the bundle into the app cache (`diagnostics/`, older bundles
  /// replaced) and returns it.
  Future<File> build({void Function(DiagnosticsStep step)? onStep}) => _build(onStep: onStep);

  Future<File> _build({Directory? target, void Function(DiagnosticsStep step)? onStep}) async {
    final at = _clock();
    onStep?.call(DiagnosticsStep.collecting);
    final snapshot = await collect(at);
    onStep?.call(DiagnosticsStep.packing);
    final bytes = DiagnosticsBundle.build(snapshot);
    final dir = target ?? Directory('${(await _cacheRoot()).path}/diagnostics');
    await dir.create(recursive: true);
    if (target == null) {
      for (final old in dir.listSync().whereType<File>()) {
        if (old.path.endsWith('.zip')) old.deleteSync();
      }
    }
    final file = File('${dir.path}/${DiagnosticsBundle.fileName(at)}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// The system share sheet with a fresh bundle; true when it was sent
  /// somewhere.
  Future<bool> share({void Function(DiagnosticsStep step)? onStep}) async {
    final file = await build(onStep: onStep);
    onStep?.call(DiagnosticsStep.sharing);
    final name = file.uri.pathSegments.last;
    final status = await _share(
      ShareParams(
        files: [XFile(file.path, mimeType: DiagnosticsBundle.mime, name: name)],
        fileNameOverrides: [name],
        subject: appL10n.stateDiagnosticsSubject,
      ),
    );
    return status == ShareResultStatus.success;
  }

  /// A fresh bundle in the phone's Downloads; returns where
  /// (`Download/DSH-Go/dsh-go-diagnostics-….zip`).
  Future<String> saveToDownloads({void Function(DiagnosticsStep step)? onStep}) async {
    final dir = await Directory('${(await _cacheRoot()).path}/diagnostics').create(recursive: true);
    // Another widget may build a bundle while the native worker still reads ours.
    final operation = await dir.createTemp('save-');
    try {
      final file = await _build(target: operation, onStep: onStep);
      onStep?.call(DiagnosticsStep.saving);
      return await files.saveToDownloads(file.path, name: file.uri.pathSegments.last, mime: DiagnosticsBundle.mime);
    } finally {
      // The native reply follows the copy; cleanup cannot replace its outcome.
      try {
        await operation.delete(recursive: true);
      } catch (_) {
        // Failed cleanup leaves this operation in the temporary cache.
      }
    }
  }
}

/// What went wrong, in words.
String diagnosticsErrorText(Object error) => switch (error) {
  PlatformException(code: 'permission') => appL10n.stateStoragePermission,
  FileSystemException() => appL10n.stateDiagnosticsStorageFull,
  _ => appL10n.stateDiagnosticsExportFailed,
};

/// `已存到 下载/DSH-Go/…` for a saved bundle.
String diagnosticsSavedText(String where) => savedInChosenPlace(where)
    ? appL10n.harmonySaved
    : appL10n.stateDiagnosticsSaved(where.replaceFirst(RegExp(r'^Download/'), appL10n.stateDownloadsPrefix));

final diagnosticsExporterProvider = Provider<DiagnosticsExporter>(
  (ref) => DiagnosticsExporter(
    collect: (at) => collectDiagnostics(ref, at, includeSystemIme: true),
    files: ref.watch(filesChannelProvider),
  ),
);
