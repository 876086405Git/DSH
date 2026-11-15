// Getting a chat artifact onto the phone and handing it to Android (open,
// share, save to Downloads).

import 'dart:async';
import 'dart:io';

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
    String? operatingSystem,
  }) : _share = share ?? _systemShare,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final HostConnection? connection;
  final FilesChannel channel;
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

  /// Opens [artifact] in the app Android picks for its type ([chooser]: the
  /// person picks).
  Future<void> open(
    String sessionId,
    Artifact artifact, {
    bool chooser = false,
    void Function(double?)? onProgress,
  }) async {
    final file = await materialize(sessionId, artifact, onProgress: onProgress);
    await channel.open(file.path, name: artifact.name, mime: artifact.mimeType, chooser: chooser);
  }

  /// The system share sheet with the file.
  Future<void> share(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final file = await materialize(sessionId, artifact, onProgress: onProgress);
    await _share(
      ShareParams(
        files: [XFile(file.path, mimeType: artifact.mimeType, name: artifact.name)],
        fileNameOverrides: [artifact.name],
      ),
    );
  }

  /// Copies the file into the phone's public Downloads; returns where.
  Future<String> saveToDownloads(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final file = await materialize(sessionId, artifact, onProgress: onProgress);
    return channel.saveToDownloads(file.path, name: artifact.name, mime: artifact.mimeType);
  }

  /// A small image of [artifact] for its card; null when it is not an image
  /// Flutter can draw, or too big to fetch just for this.
  Future<ImageProvider?> thumbnail(String sessionId, String path) async {
    final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0);
    if (artifact.kind != ArtifactKind.image || path.toLowerCase().endsWith('.svg')) {
      return null;
    }
    final conn = connection;
    if (conn == null) return null;
    if (!conn.isLocal) {
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
  return cleaned.isEmpty ? 'file' : cleaned;
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

final artifactFilesProvider = Provider<ArtifactFiles>(
  (ref) => ArtifactFiles(
    connection: ref.watch(activeConnectionProvider).value,
    channel: ref.watch(filesChannelProvider),
    operatingSystem: ref.watch(operatingSystemProvider),
  ),
);

/// [ArtifactFiles.thumbnail], cached per (session, path) while shown.
final artifactThumbnailProvider = FutureProvider.autoDispose.family<ImageProvider?, (String, String)>((ref, key) async {
  final (sessionId, path) = key;
  try {
    return await ref.watch(artifactFilesProvider).thumbnail(sessionId, path);
  } catch (_) {
    return null;
  }
});
