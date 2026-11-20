import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

final imageSnapshotsProvider = Provider<ImageSnapshots>((ref) => ImageSnapshots());

class ImageSnapshotMissing implements Exception {
  const ImageSnapshotMissing();

  @override
  String toString() => 'ImageSnapshotMissing';
}

class ImageSnapshotTooLarge implements Exception {
  const ImageSnapshotTooLarge();

  @override
  String toString() => 'ImageSnapshotTooLarge';
}

/// First successful read of a host/session/turn/path, not a live file cache.
/// By default, a durable support-directory index prevents reloading lost history.
/// Contents have a self-managed budget and may disappear after this call.
class ImageSnapshots {
  ImageSnapshots({Future<Directory> Function()? root, int maxBytes = 128 * 1024 * 1024})
    : _root = root ?? getApplicationSupportDirectory,
      _maxBytes = maxBytes {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  }

  final Future<Directory> Function() _root;
  final int _maxBytes;
  final _pending = <String, Future<File>>{};

  // Serialize only transactions on the same physical directory. Unrelated roots
  // must not inherit a pending transaction (or its caller zone). Empty queues
  // are removed when their last transaction completes.
  static final _tails = <String, Future<void>>{};
  // A miss registers a token; its finally removes it and empty groups. Session
  // removal invalidates and drops the group, so late loads cannot restore it.
  static final _loading = <(String, String), Set<_SnapshotLoad>>{};
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

  static Future<T> _exclusive<T>(String directory, Future<T> Function() action) {
    final result = (_tails[directory] ?? Future<void>.value()).then((_) => action());
    late final Future<void> tail;
    void release() {
      if (identical(_tails[directory], tail)) _tails.remove(directory);
    }

    tail = result.then<void>((_) => release(), onError: (Object _, StackTrace _) => release());
    _tails[directory] = tail;
    return result;
  }

  Future<File> get({
    required String host,
    required String sessionId,
    required int turn,
    required String path,
    required Future<Uint8List> Function() load,
    int maxBytes = 20 * 1024 * 1024,
  }) {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final scope = _identity([host, sessionId]);
    final key = _identity([turn, path]);
    final pendingKey = '$scope/$key/$maxBytes';
    final pending = _pending[pendingKey];
    if (pending != null) return pending;
    late final Future<File> result;
    void forget() {
      if (identical(_pending[pendingKey], result)) _pending.remove(pendingKey);
    }

    result = _get(scope, key, load, maxBytes, forget);
    _pending[pendingKey] = result;
    result.then<void>((_) => forget(), onError: (Object _, StackTrace _) => forget());
    return result;
  }

  Future<File> _get(
    String scope,
    String key,
    Future<Uint8List> Function() load,
    int maxBytes,
    void Function() cancelPending,
  ) async {
    final directory = await _directory();
    final scopeKey = (await directory.resolveSymbolicLinks(), scope);
    final token = _SnapshotLoad(cancelPending);
    final cached = await _exclusive(scopeKey.$1, () async {
      final index = await _readIndex(directory);
      final file = await _find(directory, index, scope, key, maxBytes);
      if (file == null) _loading.putIfAbsent(scopeKey, () => <_SnapshotLoad>{}).add(token);
      return file;
    });
    if (cached != null) return cached;
    try {
      final bytes = await load();
      final content = bytes.length > maxBytes || bytes.length > _maxBytes ? null : sha256.convert(bytes).toString();
      return await _exclusive(scopeKey.$1, () async {
        if (!token.valid) throw const ImageSnapshotMissing();
        // Another store may have fixed the same key while this load was out of
        // the transaction. Its first successful snapshot wins, even a tombstone.
        final index = await _readIndex(directory);
        final file = await _find(directory, index, scope, key, maxBytes);
        if (file != null) return file;
        if (content == null) throw const ImageSnapshotTooLarge();
        final target = _contentFile(directory, content);
        if (!await target.exists()) await _writeAtomic(target, bytes);
        index.references.putIfAbsent(scope, () => <String, String?>{})[key] = content;
        _touch(index, content);
        await _commit(directory, index);
        return target;
      });
    } finally {
      await _exclusive(scopeKey.$1, () async {
        final loading = _loading[scopeKey];
        loading?.remove(token);
        if (loading != null && loading.isEmpty) _loading.remove(scopeKey);
      });
    }
  }

  static Future<File?> _find(Directory directory, _SnapshotIndex index, String scope, String key, int maxBytes) async {
    final references = index.references[scope];
    if (references == null || !references.containsKey(key)) return null;
    // Null is a durable tombstone, not permission to reload today's source.
    final digest = references[key];
    if (digest == null) throw const ImageSnapshotMissing();
    final file = _contentFile(directory, digest);
    if (!await file.exists()) throw const ImageSnapshotMissing();
    if (await file.length() > maxBytes) throw const ImageSnapshotTooLarge();
    _touch(index, digest);
    await _saveIndex(directory, index);
    return file;
  }

  static void _touch(_SnapshotIndex index, String content) {
    var clock = 0;
    for (final tick in index.accessed.values) {
      if (tick > clock) clock = tick;
    }
    index.accessed[content] = clock + 1;
  }

  Future<void> removeSession(String host, String sessionId) async {
    final directory = await _directory();
    final scope = _identity([host, sessionId]);
    final scopeKey = (await directory.resolveSymbolicLinks(), scope);
    await _exclusive(scopeKey.$1, () async {
      final index = await _readIndex(directory);
      index.references.remove(scope);
      final retained = <String>{
        for (final references in index.references.values)
          for (final digest in references.values) ?digest,
      };
      index.accessed.removeWhere((digest, _) => !retained.contains(digest));
      final discarded = <File>[];
      await for (final file in _contentDirectory(directory).list(followLinks: false)) {
        if (file is File && !retained.contains(file.uri.pathSegments.last)) discarded.add(file);
      }
      await _saveIndex(directory, index);
      final loading = _loading.remove(scopeKey);
      if (loading != null) {
        for (final token in loading) {
          token.valid = false;
          token.cancelPending();
        }
      }
      for (final file in discarded) {
        await file.delete();
      }
    });
  }

  Future<Directory> _directory() async {
    final directory = Directory('${(await _root()).path}/image-snapshots');
    await _contentDirectory(directory).create(recursive: true);
    return directory;
  }

  static String _identity(List<Object> parts) => sha256.convert(utf8.encode(jsonEncode(parts))).toString();
  static Directory _contentDirectory(Directory directory) => Directory('${directory.path}/contents');
  static File _contentFile(Directory directory, String digest) => File('${directory.path}/contents/$digest');

  static Future<_SnapshotIndex> _readIndex(Directory directory) async {
    final file = File('${directory.path}/index.json');
    if (!await file.exists()) return _SnapshotIndex({}, {});
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['version'] != 1) throw const FormatException('Unknown image snapshot index');
    final references = (data['references'] as Map<String, dynamic>).map(
      (scope, entries) => MapEntry(
        scope,
        (entries as Map<String, dynamic>).map((key, digest) {
          if (digest != null && (digest is! String || !_digestPattern.hasMatch(digest))) {
            throw const FormatException('Invalid image snapshot digest');
          }
          return MapEntry(key, digest as String?);
        }),
      ),
    );
    final accessed = (data['accessed'] as Map<String, dynamic>).map((digest, tick) => MapEntry(digest, tick as int));
    return _SnapshotIndex(references, accessed);
  }

  static Future<void> _saveIndex(Directory directory, _SnapshotIndex index) => _writeAtomic(
    File('${directory.path}/index.json'),
    utf8.encode(jsonEncode({'version': 1, 'references': index.references, 'accessed': index.accessed})),
  );

  Future<void> _commit(Directory directory, _SnapshotIndex index) async {
    final contents = <({File file, String digest, int bytes})>[];
    var total = 0;
    await for (final entry in _contentDirectory(directory).list(followLinks: false)) {
      if (entry is! File) continue;
      final digest = entry.uri.pathSegments.last;
      if (!_digestPattern.hasMatch(digest)) continue;
      final bytes = await entry.length();
      total += bytes;
      contents.add((file: entry, digest: digest, bytes: bytes));
    }
    contents.sort((a, b) => (index.accessed[a.digest] ?? 0).compareTo(index.accessed[b.digest] ?? 0));
    final discarded = <File>[];
    for (final entry in contents) {
      if (total <= _maxBytes) break;
      total -= entry.bytes;
      discarded.add(entry.file);
      index.accessed.remove(entry.digest);
      for (final references in index.references.values) {
        for (final key in references.keys) {
          if (references[key] == entry.digest) references[key] = null;
        }
      }
    }
    // Persist tombstones before deleting bytes: an interrupted eviction may
    // leave an orphan, but never a key that can reload today's source file.
    await _saveIndex(directory, index);
    for (final file in discarded) {
      await file.delete();
    }
  }

  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final staging = File('${file.path}.tmp');
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(file.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }
}

class _SnapshotLoad {
  _SnapshotLoad(this.cancelPending);

  final void Function() cancelPending;
  bool valid = true;
}

class _SnapshotIndex {
  _SnapshotIndex(this.references, this.accessed);

  final Map<String, Map<String, String?>> references;
  final Map<String, int> accessed;
}
