// Getting a chat artifact onto the phone and handing it to Android (open,
// share, save to Downloads).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import 'android_features.dart' show operatingSystemProvider;
import 'artifacts.dart';
import 'connection_state.dart';
import 'image_snapshots.dart';

/// Largest file fetched from a remote Host for open / share / save.
const maxRemoteArtifactBytes = 300 * 1024 * 1024;

/// Largest remote image fetched just to draw a thumbnail.
const maxThumbnailBytes = 8 * 1024 * 1024;

/// Why an artifact action could not run (beyond Host and platform errors).
class ArtifactError implements Exception {
  const ArtifactError(this.code);

  /// `missing`, `offline`, `unsupported`.
  final String code;

  @override
  String toString() => 'ArtifactError($code)';
}

/// A sentence for a failed artifact action.
String artifactErrorText(Object error) {
  final code = switch (error) {
    ImageSnapshotMissing() => 'missing',
    ImageSnapshotTooLarge() => 'workspace-file/too-large',
    ArtifactError(:final code) => code,
    PlatformException(:final code) => code,
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() || DshClosedException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'missing' || 'workspace-file/not-found' => appL10n.stateFileMissing,
    'no_app' => appL10n.stateFileNoApp,
    'permission' => appL10n.stateStoragePermission,
    'workspace-file/too-large' => appL10n.stateFileConnectionLimit,
    'unsupported' || 'workspace-file/unsupported' || 'workspace-file/not-allowed' => appL10n.stateFileReadUnsupported,
    'offline' => appL10n.commonEngineUnreachable,
    _ => appL10n.commonFailedTryAgain,
  };
}

/// Artifact files of the active connection.
///
/// The local engine's files are already on the phone (inside the Linux
/// environment, or in shared storage): Android gets them in place. A remote
/// Host's file is downloaded once into the app cache (`artifacts/`), keyed by
/// Host, session and path, and fetched again when the Host reports a new
/// version. HarmonyOS logical workspace files use the same Session-aware
/// byte service because their logical paths are not platform file paths.
class ArtifactFiles {
  ArtifactFiles({
    required this.connection,
    required this.channel,
    Future<void> Function(ShareParams params)? share,
    Future<Directory> Function()? cacheRoot,
    ImageSnapshots? snapshots,
    String? operatingSystem,
  }) : _share = share ?? _systemShare,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       snapshots = snapshots ?? ImageSnapshots(root: cacheRoot),
       _operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final HostConnection? connection;
  final FilesChannel channel;
  final ImageSnapshots snapshots;
  final Future<void> Function(ShareParams params) _share;
  final Future<Directory> Function() _cacheRoot;
  final String _operatingSystem;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  bool get isLocal => connection?.isLocal ?? false;

  /// Whether open / share / save can get at the file at all.
  bool get canFetch {
    final conn = connection;
    return conn != null && (conn.isLocal || conn.client.canReadFileBytes);
  }

  /// Whether the Host can turn Office files into PDFs for a preview.
  bool get canConvertOffice => connection?.client.supportsEndpoint('officeToPdf/render') ?? false;

  /// A PDF of an Office file, converted by the Host (as the official Web
  /// client previews them) and kept in the cache until the file changes.
  Future<File> officePdf(String sessionId, Artifact artifact) async {
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    if (!canConvertOffice) throw const ArtifactError('unsupported');
    final client = conn.client;
    final stat = await client.statFile(sessionId, artifact.path);
    final root = await _cacheRoot();
    final key = _fnv('pdf\n${conn.hostId ?? conn.label}\n$sessionId\n${artifact.path}');
    final dir = Directory('${root.path}/artifacts/$key');
    // 纪要.docx → 纪要.pdf: swapping the extension keeps a name the phone could
    // already store within its 255-byte limit (appending .pdf might not).
    final base = _safeName(artifact.name);
    final dot = base.lastIndexOf('.');
    final pdfName = '${dot > 0 ? base.substring(0, dot) : base}.pdf';
    final target = File('${dir.path}/$pdfName');
    final marker = File('${dir.path}/.version');
    if (target.existsSync() && marker.existsSync() && marker.readAsStringSync() == stat.version) {
      return target;
    }
    final rendered = await client.renderOfficePdf(sessionId, artifact.path);
    if (rendered.pdf.isEmpty) throw const ArtifactError('unsupported');
    await dir.create(recursive: true);
    final staging = await dir.createTemp('.part-');
    final part = File('${staging.path}/$pdfName');
    try {
      await part.writeAsBytes(rendered.pdf, flush: true);
      part.renameSync(target.path);
      marker.writeAsStringSync(stat.version);
      return target;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// An Android file holding [artifact]; [onProgress] gets 0–1 (null while
  /// the size is unknown) during a download.
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
  }) async {
    if (!artifact.snapshotImage || artifact.kind != ArtifactKind.image) {
      return _materializeCurrent(sessionId, artifact, onProgress: onProgress, maxBytes: maxBytes);
    }
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    final limit = maxBytes < 20 * 1024 * 1024 ? maxBytes : 20 * 1024 * 1024;
    return snapshots.get(
      host: imageSnapshotHost(conn),
      sessionId: sessionId,
      turn: artifact.turn,
      path: artifact.path,
      maxBytes: limit,
      load: () async {
        final bytes = BytesBuilder(copy: false);
        void append(List<int> chunk) {
          if (bytes.length + chunk.length > limit) throw const ImageSnapshotTooLarge();
          bytes.add(chunk);
        }

        final sessionCopy = conn.isLocal && _operatingSystem == 'ohos' && artifact.path.startsWith('/workspaces/');
        if (conn.isLocal && !sessionCopy) {
          final host = await channel.resolveGuest(artifact.path);
          if (host == null) throw const ArtifactError('missing');
          final file = File(host);
          if (await file.length() > limit) throw const ImageSnapshotTooLarge();
          await for (final chunk in file.openRead()) {
            append(chunk);
          }
        } else {
          if (!conn.client.canReadFileBytes) throw const ArtifactError('unsupported');
          // A new turn reads the Host, not the mutable per-path download cache.
          await conn.client.readFile(
            sessionId,
            artifact.path,
            maxBytes: limit,
            onChunk: (chunk) async => append(chunk),
            onProgress: onProgress == null
                ? null
                : (received, total) => onProgress(total == null || total == 0 ? null : received / total),
          );
        }
        return bytes.takeBytes();
      },
    );
  }

  Future<File> _materializeCurrent(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
  }) async {
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    // This prefix selects a transport, not authority. The existing Session
    // file service still resolves the path and checks its workspace grant.
    final sessionCopy = conn.isLocal && _operatingSystem == 'ohos' && artifact.path.startsWith('/workspaces/');
    if (conn.isLocal && !sessionCopy) {
      final host = await channel.resolveGuest(artifact.path);
      if (host == null) throw const ArtifactError('missing');
      return File(host);
    }
    final client = conn.client;
    if (!client.canReadFileBytes) throw const ArtifactError('unsupported');
    final stat = await client.statFile(sessionId, artifact.path);
    if (stat.bytes != null && stat.bytes! > maxBytes) throw const ArtifactError('workspace-file/too-large');
    final root = await _cacheRoot();
    final key = _fnv('${conn.hostId ?? conn.label}\n$sessionId\n${artifact.path}');
    final dir = Directory('${root.path}/artifacts/$key');
    final target = File('${dir.path}/${_safeName(artifact.name)}');
    final marker = File('${dir.path}/.version');
    if (target.existsSync() && marker.existsSync() && marker.readAsStringSync() == stat.version) {
      if (await target.length() > maxBytes) throw const ArtifactError('workspace-file/too-large');
      return target;
    }
    await dir.create(recursive: true);
    // A thumbnail and its preview can download together. Each owns its
    // temporary directory, including cleanup after a failed read.
    final staging = await dir.createTemp('.part-');
    final part = File('${staging.path}/${_safeName(artifact.name)}');
    var received = 0;
    try {
      final sink = await part.open(mode: FileMode.write);
      try {
        await client.readFile(
          sessionId,
          artifact.path,
          maxBytes: maxBytes,
          onChunk: (chunk) async {
            received += chunk.length;
            if (received > maxBytes) throw const ArtifactError('workspace-file/too-large');
            await sink.writeFrom(chunk);
          },
          onProgress: onProgress == null
              ? null
              : (received, total) => onProgress(total == null || total == 0 ? null : received / total),
        );
        if (sessionCopy) await sink.flush();
      } finally {
        await sink.close();
      }
      // Publish the file and its version without an await between them, so
      // another completed download cannot pair this version with its bytes.
      part.renameSync(target.path);
      marker.writeAsStringSync(stat.version);
      return target;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<T> _fileAction<T>(
    String sessionId,
    Artifact artifact,
    Future<T> Function(File) action, {
    void Function(double?)? onProgress,
  }) async {
    final source = await materialize(sessionId, artifact, onProgress: onProgress);
    if (_operatingSystem != 'ohos' || !artifact.snapshotImage || artifact.kind != ArtifactKind.image) {
      return action(source);
    }
    // Harmony admits cache/temp inputs, not the durable support-directory store.
    // Open/share make their own native copies; save reads before replying. Keep
    // this bridge copy until that Future settles, not for the external reader.
    final root = await _cacheRoot();
    await root.create(recursive: true);
    final directory = await root.createTemp('image-snapshot-export-');
    try {
      final file = await source.copy('${directory.path}/${_safeName(artifact.name)}');
      return await action(file);
    } finally {
      await directory.delete(recursive: true);
    }
  }

  /// Opens [artifact] in the app Android picks for its type ([chooser]: the
  /// person picks).
  Future<void> open(String sessionId, Artifact artifact, {bool chooser = false, void Function(double?)? onProgress}) =>
      _fileAction(
        sessionId,
        artifact,
        (file) => channel.open(file.path, name: artifact.name, mime: artifact.mimeType, chooser: chooser),
        onProgress: onProgress,
      );

  /// The system share sheet with the file.
  Future<void> share(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) => _fileAction(
    sessionId,
    artifact,
    (file) => _share(
      ShareParams(
        files: [XFile(file.path, mimeType: artifact.mimeType, name: artifact.name)],
        fileNameOverrides: [artifact.name],
      ),
    ),
    onProgress: onProgress,
  );

  /// Copies the file into the phone's public Downloads; returns where.
  Future<String> saveToDownloads(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) =>
      _fileAction(
        sessionId,
        artifact,
        (file) => channel.saveToDownloads(file.path, name: artifact.name, mime: artifact.mimeType),
        onProgress: onProgress,
      );

  /// A small image of [artifact] for its card; null when it is not an image
  /// Flutter can draw, or too big to fetch just for this.
  Future<ImageProvider?> thumbnail(String sessionId, String path, {int? turn}) async {
    final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: turn ?? 0, snapshotImage: turn != null);
    if (artifact.kind != ArtifactKind.image || path.toLowerCase().endsWith('.svg')) {
      return null;
    }
    final conn = connection;
    if (conn == null) return null;
    if (!conn.isLocal && turn == null) {
      final stat = await conn.client.statFile(sessionId, artifact.path);
      if ((stat.bytes ?? maxThumbnailBytes + 1) > maxThumbnailBytes) {
        return null;
      }
    }
    final file = await materialize(sessionId, artifact, maxBytes: maxThumbnailBytes);
    if (await file.length() > maxThumbnailBytes) return null;
    return FileImage(file);
  }
}

String _safeName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\x00-\x1f/\\:*?"<>|]'), '_').trim();
  // Keep downloaded content separate from the cache's version marker.
  if (cleaned == '.version') return 'file.version';
  return cleaned.isEmpty ? 'file' : _fitName(cleaned);
}

/// Android's file systems take 255 bytes for a name, a Windows Host 255 characters: a
/// longer name (CJK is 3 bytes a character) is cut to fit, its extension kept. Each
/// artifact has its own cache directory, so a cut name can't meet another.
String _fitName(String name) {
  const max = 200;
  if (utf8.encode(name).length <= max) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
  var room = max - utf8.encode(ext).length;
  final stem = StringBuffer();
  for (final rune in (ext.isEmpty ? name : name.substring(0, dot)).runes) {
    room -= utf8.encode(String.fromCharCode(rune)).length;
    if (room < 0) break;
    stem.writeCharCode(rune);
  }
  return '$stem$ext';
}

/// FNV-1a, hex: a stable cache directory name.
String _fnv(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Host names are editable; only the selected transport and stable id own history.
String imageSnapshotHost(HostConnection connection) => '${connection.kind.name}:${connection.hostId ?? ''}';

final artifactFilesProvider = Provider<ArtifactFiles>(
  (ref) => ArtifactFiles(
    connection: ref.watch(activeConnectionProvider).value,
    channel: ref.watch(filesChannelProvider),
    snapshots: ref.watch(imageSnapshotsProvider),
    operatingSystem: ref.watch(operatingSystemProvider),
  ),
);

/// Chat thumbnails share the same immutable file as the turn's inline image.
final turnArtifactThumbnailProvider = FutureProvider.autoDispose.family<ImageProvider?, (String, String, int)>((
  ref,
  key,
) async {
  final (sessionId, path, turn) = key;
  try {
    return await ref.watch(artifactFilesProvider).thumbnail(sessionId, path, turn: turn);
  } catch (_) {
    return null;
  }
});

/// [ArtifactFiles.thumbnail], cached per (session, path) while shown.
final artifactThumbnailProvider = FutureProvider.autoDispose.family<ImageProvider?, (String, String)>((ref, key) async {
  final (sessionId, path) = key;
  try {
    return await ref.watch(artifactFilesProvider).thumbnail(sessionId, path);
  } catch (_) {
    return null;
  }
});
