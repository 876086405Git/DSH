/// Reading a file the Session's filesystem can see (deliverables, generated
/// images), wherever the Host runs.
///
/// * `workspaceFiles/stat` (JSON) names the file and its size on every
///   carrier.
/// * Bytes: `workspaceFiles/readBytes` byte windows on every carrier (over
///   HTTP the result is multipart, see binary_response.dart; the remote
///   tunnel delivers it as base64). Should a Host's HTTP answer not decode,
///   the HTTP carrier falls back to the authenticated
///   `GET /api/file?path=<absolute>` route (whole file, capped by the Host's
///   image byte limit, 20 MiB by default).
/// * `officeToPdf/render`: the official Web client's Office preview (the Host
///   converts DOC/DOCX/XLS/XLSX/PPT/PPTX with LibreOffice).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'carrier.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

/// One regular file as the Host sees it (`workspaceFiles/stat`).
class DshFileStat {
  const DshFileStat({required this.absolutePath, required this.version, this.bytes});

  factory DshFileStat.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DshFileStat(
      absolutePath: asString(map['absolutePath']) ?? '',
      version: asString(map['version']) ?? '',
      bytes: asInt(map['bytes']),
    );
  }

  /// Symlinks resolved, in the Host's execution world.
  final String absolutePath;

  /// Opaque freshness token.
  final String version;

  /// Size, when the backend reports it.
  final int? bytes;
}

/// Byte window size for paged reads (the Host caps one window at 2 MiB).
const int fileWindowBytes = 1024 * 1024;

extension DshFilesApi on DshClient {
  /// `workspaceFiles/stat`: [path] absolute or relative to the Session's
  /// working directory; files outside the workspace are allowed.
  Future<DshFileStat> statFile(String sessionId, String path) async {
    final value = await rpc.call('workspaceFiles/stat', {'workspaceFileScopeId': sessionId, 'path': path});
    return DshFileStat.fromJson(value);
  }

  /// Whether [url] is served by this client's own engine, over HTTP.
  bool isEngineUrl(String url) {
    final carrier = this.carrier;
    return carrier is DshHttpCarrier && carrier.connection.ownUri(url) != null;
  }

  /// The bytes at [url], which [isEngineUrl] accepted, read with the session's
  /// credentials: no redirects, at most [maxBytes].
  Future<Uint8List> readEngineUrl(String url, {required int maxBytes}) async {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) throw ArgumentError.value(url, 'url', 'not this engine');
    final response = await carrier.connection.getBoundedOwn(url, maxBytes: maxBytes, autoUncompress: true);
    if (response.statusCode == 200) return response.body;
    throw DshHttpException(response.statusCode, 'GET ${Uri.parse(url).path}: HTTP ${response.statusCode}');
  }

  /// Whether this client can read raw file bytes at all.
  bool get canReadFileBytes => carrier is DshHttpCarrier || supportsEndpoint('workspaceFiles/readBytes');

  /// Streams a file's bytes to [onChunk], in order; returns the byte count.
  /// Each chunk is consumed before reporting progress or requesting the next
  /// window. An asynchronous [onChunk] is awaited; its failure stops the read.
  ///
  /// [maxBytes] refuses larger files up front (`workspace-file/too-large`)
  /// when the size is known. [onProgress] gets (received, total?).
  /// Failures are [DshRemoteException]s with `workspace-file/*` codes
  /// (`not-found`, `not-allowed`, `too-large`, `unsupported`), or the
  /// carrier's transport errors. A changed non-empty window version fails locally
  /// with `workspace-file/changed` before delivering that window. Missing versions
  /// remain compatible; this check does not provide an atomic file snapshot.
  Future<int> readFile(
    String sessionId,
    String path, {
    required FutureOr<void> Function(Uint8List chunk) onChunk,
    void Function(int received, int? total)? onProgress,
    int? maxBytes,
  }) async {
    final stat = await statFile(sessionId, path);
    final total = stat.bytes;
    if (maxBytes != null && total != null && total > maxBytes) {
      throw DshRemoteException('workspace-file/too-large', '"$path" is $total bytes (limit $maxBytes)', {
        'path': path,
        'limit': maxBytes,
      });
    }
    onProgress?.call(0, total);
    if (!supportsEndpoint('workspaceFiles/readBytes')) {
      throw DshRemoteException('workspace-file/unsupported', 'this connection cannot read file bytes', {'path': path});
    }
    var delivered = 0;
    Future<void> sink(Uint8List chunk) async {
      delivered += chunk.length;
      await onChunk(chunk);
    }

    try {
      return await _readWindows(
        sessionId,
        path,
        sink,
        onProgress,
        maxBytes,
        total,
        stat.version.isEmpty ? null : stat.version,
      );
    } on DshProtocolException {
      // An HTTP answer this client cannot decode: the plain file route, if
      // nothing has been handed out yet.
      final carrier = this.carrier;
      if (carrier is! DshHttpCarrier || delivered > 0) rethrow;
      final bytes = await _readWhole(carrier, stat.absolutePath.isEmpty ? path : stat.absolutePath, path, maxBytes);
      await onChunk(bytes);
      onProgress?.call(bytes.length, total ?? bytes.length);
      return bytes.length;
    }
  }

  /// `GET /api/file?path=<absolute>` (HTTP carrier only).
  Future<Uint8List> _readWhole(DshHttpCarrier carrier, String absolute, String path, int? maxBytes) async {
    final response = maxBytes == null
        ? await carrier.connection.get('/api/file', query: {'path': absolute}, timeout: const Duration(minutes: 5))
        : await carrier.connection.getBounded(
            '/api/file',
            query: {'path': absolute},
            maxBytes: maxBytes,
            timeout: const Duration(minutes: 5),
          );
    if (response.statusCode == 200) return response.body;
    throw DshRemoteException(
      switch (response.statusCode) {
        404 => 'workspace-file/not-found',
        403 => 'workspace-file/not-allowed',
        413 => 'workspace-file/too-large',
        _ => 'workspace-file/http-${response.statusCode}',
      },
      '/api/file: HTTP ${response.statusCode} ${response.text}'.trim(),
      {'path': path},
    );
  }

  Future<int> _readWindows(
    String sessionId,
    String path,
    FutureOr<void> Function(Uint8List chunk) onChunk,
    void Function(int received, int? total)? onProgress,
    int? maxBytes,
    int? total,
    String? expectedVersion,
  ) async {
    var offset = 0;
    while (true) {
      final value = asMapOrEmpty(
        await rpc.call('workspaceFiles/readBytes', {
          'workspaceFileScopeId': sessionId,
          'path': path,
          'options': {
            'range': {'offset': offset, 'length': fileWindowBytes},
          },
        }),
      );
      final version = asString(value['version']);
      if (version != null && version.isNotEmpty) {
        if (expectedVersion != null && version != expectedVersion) {
          throw DshRemoteException('workspace-file/changed', '"$path" changed while reading', {'path': path});
        }
        expectedVersion ??= version;
      }
      final raw = value['data'];
      final data = raw is String && raw.length > 256 * 1024 ? await _decodeLargeFileWindow(raw) : _bytesOf(raw);
      offset += data.length;
      if (maxBytes != null && offset > maxBytes) {
        throw DshRemoteException('workspace-file/too-large', '"$path" exceeds $maxBytes bytes', {
          'path': path,
          'limit': maxBytes,
        });
      }
      if (data.isNotEmpty) await onChunk(data);
      onProgress?.call(offset, asInt(value['bytes']) ?? total);
      if (value['eof'] == true || data.isEmpty) return offset;
    }
  }

  /// `officeToPdf/render`: the Host converts an Office file
  /// (DOC/DOCX/XLS/XLSX/PPT/PPTX) to PDF for a foreground preview; returns
  /// the PDF and the fonts the document wanted but the Host lacks.
  Future<({Uint8List pdf, List<String> missingFonts})> renderOfficePdf(String sessionId, String path) async {
    if (!supportsEndpoint('officeToPdf/render')) {
      throw DshRemoteException('workspace-file/unsupported', 'this connection cannot convert Office files', {
        'path': path,
      });
    }
    final value = asMapOrEmpty(
      await rpc.call('officeToPdf/render', {
        'workspaceFileScopeId': sessionId,
        'path': path,
        'priority': 'foreground',
      }, const Duration(minutes: 3)),
    );
    return (
      pdf: _bytesOf(value['data']),
      missingFonts: [for (final font in asListOrEmpty(value['missingFonts'])) ?asString(font)],
    );
  }

  /// The whole file in memory (small files: thumbnails, previews).
  Future<Uint8List> readFileBytes(String sessionId, String path, {int? maxBytes}) async {
    final builder = BytesBuilder(copy: false);
    await readFile(sessionId, path, onChunk: builder.add, maxBytes: maxBytes);
    return builder.takeBytes();
  }
}

/// Binary `data`: bytes over HTTP (multipart), base64 over the remote
/// tunnel, a JSON byte array from a test double.
Uint8List _bytesOf(Object? data) {
  if (data is Uint8List) return data;
  if (data is String) return base64Decode(data);
  if (data is List) return Uint8List.fromList([for (final b in data) asInt(b) ?? 0]);
  return Uint8List(0);
}

Future<Uint8List> _decodeLargeFileWindow(String data) => Isolate.run(() => base64Decode(data));
