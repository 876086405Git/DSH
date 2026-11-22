import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'companion_memory_model_download.dart';

enum CompanionMemoryModelStatus { unavailable, notDownloaded, downloading, ready, failed }

/// Retired work is different from an unavailable optional model. Callers must
/// stop the old turn instead of falling back with its captured memory text.
class CompanionMemoryRetrievalCancelled implements Exception {
  const CompanionMemoryRetrievalCancelled();
}

/// One instance belongs to the process MemoryOwner, shared by both room modes.
/// Construction never downloads a model or sends text to a remote service.
class CompanionMemoryEmbeddings extends ChangeNotifier {
  CompanionMemoryEmbeddings({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('dsh/companion_embeddings'),
      _supported = supported ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _supported;
  bool _disposed = false;
  bool _checked = false;
  bool _downloading = false;
  bool _downloadCancelled = false;
  bool _failed = false;
  int _generation = 0;
  String? _modelKey;

  /// The last query's vector: each tool round trip of a turn ranks again with
  /// the same text, which encodes to the same vector under the same model.
  ({String modelKey, String text, List<double> vector})? _lastQuery;
  Future<bool>? _loading;
  Future<void>? _downloadFuture;
  CompanionMemoryModelDownload? _installer;
  double _progress = 0;

  bool get supported => _supported;
  double get progress => _progress;
  bool get canCancelDownload => _downloading && !_downloadCancelled && (_installer?.canCancel ?? true);
  CompanionMemoryModelStatus get status => !_supported
      ? CompanionMemoryModelStatus.unavailable
      : _downloading
      ? CompanionMemoryModelStatus.downloading
      : _modelKey != null
      ? CompanionMemoryModelStatus.ready
      : _failed
      ? CompanionMemoryModelStatus.failed
      : CompanionMemoryModelStatus.notDownloaded;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> ensureReady() async {
    if (_disposed || !_supported || _downloading) return false;
    if (_modelKey != null) return true;
    if (_loading != null) return _loading!;
    if (_checked) return false;
    final loading = _load();
    _loading = loading;
    try {
      return await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  Future<bool> _load() async {
    final generation = _generation;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('load');
      if (_disposed || generation != _generation) return false;
      _checked = true;
      if (raw == null) {
        _modelKey = null;
        _changed();
        return false;
      }
      if (raw['modelKey'] is! String || raw['dimensions'] != 512) {
        throw const FormatException('Unsupported local embedding model');
      }
      _modelKey = raw['modelKey']! as String;
      _failed = false;
      _changed();
      return true;
    } on MissingPluginException {
      if (!_disposed && generation == _generation) _checked = true;
      return false;
    } on PlatformException {
      if (!_disposed && generation == _generation) {
        _checked = true;
        _failed = true;
        _changed();
      }
      return false;
    } on FormatException {
      if (!_disposed && generation == _generation) {
        _checked = true;
        _failed = true;
        _changed();
      }
      return false;
    }
  }

  /// Called only by the user's on-demand download action, never by [rank].
  Future<void> download() {
    if (_downloadFuture != null) return _downloadFuture!;
    if (_disposed || !_supported) return Future.error(StateError('Local embeddings unavailable'));
    final future = _download();
    _downloadFuture = future;
    return future;
  }

  Future<void> _download() async {
    _generation++;
    _modelKey = null;
    _downloading = true;
    _downloadCancelled = false;
    _failed = false;
    _progress = 0;
    _changed();
    try {
      final path = await _channel.invokeMethod<String>('directory');
      if (_disposed || _downloadCancelled) throw const CompanionMemoryRetrievalCancelled();
      if (path == null) throw StateError('Local embedding directory unavailable');
      final installer = CompanionMemoryModelDownload(
        directory: Directory(path),
        channel: _channel,
        onProgress: (value) {
          _progress = value;
          _changed();
        },
      );
      _installer = installer;
      await installer.run();
      if (_disposed || _downloadCancelled) throw const CompanionMemoryRetrievalCancelled();
      _checked = false;
      if (!await _load()) throw StateError('Local embedding model unavailable');
      _progress = 1;
    } catch (_) {
      _failed = !_downloadCancelled;
      rethrow;
    } finally {
      _installer = null;
      _downloading = false;
      _checked = false;
      _downloadFuture = null;
      _changed();
    }
  }

  void cancelDownload() {
    if (!canCancelDownload) return;
    if (_installer == null || _installer!.cancel()) {
      _downloadCancelled = true;
      _changed();
    }
  }

  /// Null means the optional encoder is unavailable. An empty list is a real
  /// empty candidate/result set. Neither result is a model reference grant.
  Future<List<MemoryRow>?> rank({
    required CompanionMemoryStore store,
    required String? characterId,
    required String query,
    required bool Function() isCurrent,
    int limit = 6,
  }) async {
    if (limit < 1 || limit > 20) throw ArgumentError.value(limit, 'limit');
    final generation = _generation;
    void current() {
      if (_disposed || generation != _generation || !isCurrent()) {
        throw const CompanionMemoryRetrievalCancelled();
      }
    }

    current();
    final candidates = store.memoryRetrievalCandidates(characterId: characterId, input: query);
    if (candidates.isEmpty) return const [];
    if (!await ensureReady()) {
      current();
      return null;
    }
    current();
    final modelKey = _modelKey!;
    void sameModel() {
      current();
      if (_modelKey != modelKey) throw const CompanionMemoryRetrievalCancelled();
    }

    try {
      final cached = store.memoryEmbeddings(
        characterId: characterId,
        candidates: candidates,
        modelKey: modelKey,
        dimensions: 512,
      );
      final last = _lastQuery;
      final queryVector = last != null && last.modelKey == modelKey && last.text == query
          ? last.vector
          : (await _vectors([query], query: true, modelKey: modelKey)).single;
      _lastQuery = (modelKey: modelKey, text: query, vector: queryVector);
      sameModel();
      final missing = [
        for (final card in candidates)
          if (!cached.containsKey(card['id'])) card,
      ];
      // Encode only already scoped cards. Each await allows a new user turn,
      // role switch or control revision to retire this work before more input.
      for (var start = 0; start < missing.length; start += 4) {
        sameModel();
        final batch = missing.skip(start).take(4).toList();
        final vectors = await _vectors(
          [for (final card in batch) card['text']! as String],
          query: false,
          modelKey: modelKey,
        );
        sameModel();
        for (var i = 0; i < batch.length; i++) {
          final card = batch[i];
          store.saveMemoryEmbedding(
            characterId: characterId,
            cardId: card['id']! as String,
            rowRevision: card['row_rev']! as int,
            modelKey: modelKey,
            vector: vectors[i],
          );
        }
      }
      sameModel();
      // Re-read all eligibility and reference rules after inference, then use
      // the same float32 cache representation for old and newly encoded rows.
      final revisions = {for (final card in candidates) card['id']: card['row_rev']};
      final fresh = [
        for (final card in store.memoryRetrievalCandidates(characterId: characterId, input: query))
          if (revisions[card['id']] == card['row_rev']) card,
      ];
      final vectors = store.memoryEmbeddings(
        characterId: characterId,
        candidates: fresh,
        modelKey: modelKey,
        dimensions: 512,
      );
      final ranked = <({MemoryRow card, double score})>[];
      for (final card in fresh) {
        final vector = vectors[card['id']];
        if (vector == null) continue;
        var score = 0.0;
        for (var i = 0; i < 512; i++) {
          score += queryVector[i] * vector[i];
        }
        ranked.add((card: card, score: score));
      }
      ranked.sort((a, b) {
        final order = b.score.compareTo(a.score);
        return order != 0 ? order : (a.card['id']! as String).compareTo(b.card['id']! as String);
      });
      sameModel();
      return [for (final row in ranked.take(limit)) row.card];
    } on PlatformException {
      sameModel();
      return null;
    } on MissingPluginException {
      sameModel();
      return null;
    } on FormatException {
      sameModel();
      return null;
    }
  }

  Future<List<List<double>>> _vectors(List<String> texts, {required bool query, required String modelKey}) async {
    final raw = await _channel.invokeListMethod<Object?>('embed', {
      'texts': texts,
      'query': query,
      'modelKey': modelKey,
    });
    if (raw == null || raw.length != texts.length) throw const FormatException('Invalid embedding batch');
    return [for (final item in raw) _vector(item)];
  }

  List<double> _vector(Object? raw) {
    if (raw is! List || raw.length != 512 || raw.any((value) => value is! num)) {
      throw const FormatException('Invalid embedding shape');
    }
    final vector = [for (final value in raw) (value as num).toDouble()];
    var squared = 0.0;
    for (final value in vector) {
      squared += value * value;
    }
    if (!squared.isFinite || (squared - 1).abs() > 0.001) {
      throw const FormatException('Invalid embedding norm');
    }
    return vector;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _installer?.cancel();
    _modelKey = null;
    if (_supported) unawaited(_channel.invokeMethod<void>('unload').catchError((Object _) {}));
    super.dispose();
  }
}
