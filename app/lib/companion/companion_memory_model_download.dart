import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../voice/voice_model_download.dart';

/// The user's explicit local-model download. Only these fixed public asset
/// URLs are requested; memory text and queries are never inputs to this class.
class CompanionMemoryModelDownload {
  CompanionMemoryModelDownload({required this.directory, required this.channel, required this.onProgress});

  final Directory directory;
  final MethodChannel channel;
  final void Function(double progress) onProgress;
  VoiceDownloadTask? _weights;
  HttpClient? _metadataClient;
  bool _cancelled = false;
  bool _committing = false;

  bool get canCancel => !_cancelled && !_committing;

  static const revision = '18e2da99700c49ed48c0a0e3683da39348fbbb36';
  static const _base = 'https://huggingface.co/onnx-community/bge-small-zh-v1.5-ONNX/resolve/$revision';
  static const _assets = [
    (
      name: 'model_quantized.onnx',
      bytes: 168002,
      sha: '99a6e522710c00220c89f8c52e0cc5aa09d4cbb1c34c0e932eab3a9dfdc65df3',
    ),
    (
      name: 'model_quantized.onnx_data',
      bytes: 23774208,
      sha: '952623481ca8beea884e3d3c9ecaf8a3c7bf1d0c21de29e970cd31af9d37a90b',
    ),
  ];

  bool cancel() {
    // Once promotion begins, complete or roll back the directory transaction.
    // A late Cancel must not report that an installed model was cancelled.
    if (_committing) return false;
    _cancelled = true;
    _weights?.cancel();
    _metadataClient?.close(force: true);
    return true;
  }

  void _current() {
    if (_cancelled) throw const VoiceDownloadException(VoiceDownloadError.cancelled);
  }

  Future<void> run() async {
    _current();
    final staging = Directory('${directory.path}.download');
    await staging.create(recursive: true);
    _current();
    final task = await VoiceDownloadTask.start([
      for (final asset in _assets)
        VoiceDownloadJob(
          urls: [Uri.parse('$_base/onnx/${asset.name}')],
          path: '${staging.path}/${asset.name}',
          bytes: asset.bytes,
          sha256: asset.sha,
        ),
    ]);
    _weights = task;
    if (_cancelled) task.cancel();
    // Weight files account for almost all bytes; reserve the final portion for
    // bounded tokenizer metadata, validation, and atomic promotion.
    final progress = task.progress.listen((bytes) => onProgress((bytes / 23942210 * 0.95).clamp(0.0, 0.95).toDouble()));
    try {
      await task.done;
    } finally {
      await progress.cancel();
      _weights = null;
    }
    _current();
    final tokenizer = await _tokenizer();
    _current();
    await File('${staging.path}/tokenizer.json').writeAsBytes(tokenizer, flush: true);
    // The publisher exposes LFS hashes for weights; tokenizer.json is normal
    // Git metadata at the fixed revision. Record its first downloaded digest
    // for local corruption checks; do not call it a published checksum.
    await File('${staging.path}/SOURCE.json').writeAsString(
      jsonEncode({
        'revision': revision,
        'tokenizer_url': '$_base/tokenizer.json',
        'tokenizer_sha256': sha256.convert(tokenizer).toString(),
        'weights': [
          for (final asset in _assets) {'name': asset.name, 'bytes': asset.bytes, 'sha256': asset.sha},
        ],
      }),
      flush: true,
    );
    _current();
    try {
      await channel.invokeMethod<Object?>('validate', {'directory': staging.path});
    } on PlatformException catch (error) {
      // The existing downloader skips completed files of the expected length.
      // Remove only the exact bad staging asset identified by native hashing,
      // so a later explicit retry can recover without deleting a live model.
      final details = error.details;
      if (error.code == 'embedding_asset_corrupt' && details is Map) {
        final name = details['asset'];
        if (_assets.any((asset) => asset.name == name)) {
          final bad = File('${staging.path}/$name');
          if (await bad.exists()) await bad.delete();
        }
      }
      rethrow;
    }
    _current();
    await channel.invokeMethod<void>('unload');
    _current();
    // This synchronous commit point precedes every recovery/promotion await.
    // Before it cancellation is honored; after it the transaction settles.
    _committing = true;
    onProgress(0.98);
    final previous = Directory('${directory.path}.previous');
    if (await previous.exists()) {
      if (!await directory.exists()) {
        await previous.rename(directory.path);
      } else {
        await previous.delete(recursive: true);
      }
    }
    var movedOld = false;
    try {
      if (await directory.exists()) {
        await directory.rename(previous.path);
        movedOld = true;
      }
      await staging.rename(directory.path);
    } catch (_) {
      if (movedOld && !await directory.exists() && await previous.exists()) {
        await previous.rename(directory.path);
      }
      rethrow;
    }
    if (await previous.exists()) await previous.delete(recursive: true);
    onProgress(1);
  }

  Future<Uint8List> _tokenizer() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _metadataClient = client;
    try {
      _current();
      final request = await client.getUrl(Uri.parse('$_base/tokenizer.json')).timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok || response.contentLength > 524288) {
        await response.listen(null).cancel();
        throw const FormatException('Invalid tokenizer metadata response');
      }
      final data = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        _current();
        if (data.length + chunk.length > 524288) throw const FormatException('Tokenizer metadata too large');
        data.add(chunk);
      }
      _current();
      final bytes = data.takeBytes();
      if (bytes.isEmpty || jsonDecode(utf8.decode(bytes)) is! Map) {
        throw const FormatException('Invalid tokenizer metadata');
      }
      return bytes;
    } finally {
      _metadataClient = null;
      client.close(force: true);
    }
  }
}
