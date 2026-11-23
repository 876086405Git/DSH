import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
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

  // Each directory's index as this process last read or wrote it. Every change
  // goes through a transaction below, so a directory is read from disk once.
  // Set by [_indexOf]; dropped by [_forget] when a change fails to be written,
  // so the next transaction reads what the disk has.
  static final _indexes = <String, _SnapshotIndex>{};
  // Directories whose access order moved (a hit) since their index was written.
  // Set by [_find]; cleared by [_write] or [_forget]. While a write keeps
  // failing it stays set: each run of transactions tries once more, and only
  // the eviction order waits for it.
  static final _touched = <String>{};
  // Transactions queued or running per directory: +1 as one joins the line,
  // −1 as it leaves, so the one that sees 1 is the last.
  static final _queued = <String, int>{};

  static Future<T> _exclusive<T>(String directory, Future<T> Function() action) {
    _queued[directory] = (_queued[directory] ?? 0) + 1;
    final result = (_tails[directory] ?? Future<void>.value()).then((_) async {
      try {
        return await action();
      } finally {
        // The last one in line writes what the hits before it moved: a run of
        // hits writes the index once, and once the line is empty the disk has
        // every move (unless that write failed, see [_writeTouches]).
        if (_queued[directory] == 1) await _writeTouches(directory);
      }
    });
    late final Future<void> tail;
    void release() {
      final left = _queued[directory]! - 1;
      if (left == 0) {
        _queued.remove(directory);
      } else {
        _queued[directory] = left;
      }
      if (identical(_tails[directory], tail)) _tails.remove(directory);
    }

    tail = result.then<void>((_) => release(), onError: (Object _, StackTrace _) => release());
    _tails[directory] = tail;
    return result;
  }

  /// Test seam: hold nothing, as a freshly started process does.
  @visibleForTesting
  static void forgetHeldIndexes() {
    _indexes.clear();
    _touched.clear();
  }

  /// [directory]'s index, read from disk only the first time.
  static Future<_SnapshotIndex> _indexOf(String directory) async =>
      _indexes[directory] ??= await _readIndex(Directory(directory));

  /// Drops what is held for [directory]: the next transaction reads the disk.
  static void _forget(String directory) {
    _indexes.remove(directory);
    _touched.remove(directory);
  }

  /// Writes the access order hits moved. A failure does not fail the image
  /// that was found: it is only the eviction order, still marked for the next
  /// transaction to write.
  static Future<void> _writeTouches(String directory) async {
    if (!_touched.contains(directory)) return;
    final index = _indexes[directory];
    if (index == null) {
      _touched.remove(directory);
      return;
    }
    try {
      await _write(directory, index);
    } catch (error) {
      debugPrint('Image snapshot access order not written: ${error.runtimeType}');
    }
  }

  /// Writes the whole of [index], the access order hits moved included.
  static Future<void> _write(String directory, _SnapshotIndex index) async {
    await _saveIndex(Directory(directory), index);
    _touched.remove(directory);
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
    final held = scopeKey.$1;
    final token = _SnapshotLoad(cancelPending);
    final cached = await _exclusive(held, () async {
      final file = await _find(held, directory, await _indexOf(held), scope, key, maxBytes);
      if (file == null) _loading.putIfAbsent(scopeKey, () => <_SnapshotLoad>{}).add(token);
      return file;
    });
    if (cached != null) return cached;
    try {
      final bytes = await load();
      final content = bytes.length > maxBytes || bytes.length > _maxBytes ? null : await _contentHash(bytes);
      return await _exclusive(held, () async {
        if (!token.valid) throw const ImageSnapshotMissing();
        // Another store may have fixed the same key while this load was out of
        // the transaction. Its first successful snapshot wins, even a tombstone.
        final index = await _indexOf(held);
        final file = await _find(held, directory, index, scope, key, maxBytes);
        if (file != null) return file;
        if (content == null) throw const ImageSnapshotTooLarge();
        final target = _contentFile(directory, content);
        if (!await target.exists()) await _writeAtomic(target, bytes);
        try {
          index.references.putIfAbsent(scope, () => <String, String?>{})[key] = content;
          _touch(index, content);
          await _commit(held, directory, index);
        } catch (_) {
          // Not written: the next transaction reads what the disk has.
          _forget(held);
          rethrow;
        }
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

  /// [key]'s file, its access moved to the front (written by the last
  /// transaction in line, see [_exclusive]); null when it was never read.
  static Future<File?> _find(
    String held,
    Directory directory,
    _SnapshotIndex index,
    String scope,
    String key,
    int maxBytes,
  ) async {
    final references = index.references[scope];
    if (references == null || !references.containsKey(key)) return null;
    // Null is a durable tombstone, not permission to reload today's source.
    final digest = references[key];
    if (digest == null) throw const ImageSnapshotMissing();
    final file = _contentFile(directory, digest);
    if (!await file.exists()) throw const ImageSnapshotMissing();
    if (await file.length() > maxBytes) throw const ImageSnapshotTooLarge();
    _touch(index, digest);
    _touched.add(held);
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
    final held = scopeKey.$1;
    await _exclusive(held, () async {
      final index = await _indexOf(held);
      final discarded = <File>[];
      try {
        index.references.remove(scope);
        final retained = <String>{
          for (final references in index.references.values)
            for (final digest in references.values) ?digest,
        };
        index.accessed.removeWhere((digest, _) => !retained.contains(digest));
        await for (final file in _contentDirectory(directory).list(followLinks: false)) {
          if (file is File && !retained.contains(file.uri.pathSegments.last)) discarded.add(file);
        }
        await _write(held, index);
      } catch (_) {
        _forget(held);
        rethrow;
      }
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

  Future<void> _commit(String held, Directory directory, _SnapshotIndex index) async {
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
    await _write(held, index);
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

/// A photo-sized hash costs several milliseconds; keep it off the UI isolate.
FutureOr<String> _contentHash(Uint8List bytes) =>
    bytes.length > 256 * 1024 ? Isolate.run(() => sha256.convert(bytes).toString()) : sha256.convert(bytes).toString();

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
