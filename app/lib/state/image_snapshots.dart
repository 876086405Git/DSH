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

  // Also coordinate replacement stores using the same on-disk directory. No
  // cached index can overwrite another instance's references. Load is included
  // so removeSession cannot race a late read into recreating deleted references.
  static Future<void> _tail = Future<void>.value();
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
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
    var result = _pending[pendingKey];
    if (result == null) {
      result = _exclusive(() => _get(scope, key, load, maxBytes));
      _pending[pendingKey] = result;
      result.then<void>(
        (_) {
          _pending.remove(pendingKey);
        },
        onError: (Object _, StackTrace _) {
          _pending.remove(pendingKey);
        },
      );
    }
    return result;
  }

  Future<File> _get(String scope, String key, Future<Uint8List> Function() load, int maxBytes) async {
    final directory = await _directory();
    final index = await _readIndex(directory);
    final references = index.references.putIfAbsent(scope, () => <String, String?>{});
    final known = references.containsKey(key);
    final digest = references[key];
    late File file;
    late int size;
    late String content;
    if (known) {
      // Null is a persistent tombstone. Even identical bytes saved by a later
      // turn must not resurrect a reference whose history was reclaimed.
      if (digest == null) throw const ImageSnapshotMissing();
      file = _contentFile(directory, digest);
      if (!await file.exists()) throw const ImageSnapshotMissing();
      size = await file.length();
      if (size > maxBytes) throw const ImageSnapshotTooLarge();
      content = digest;
    } else {
      final bytes = await load();
      size = bytes.length;
      // An image that cannot fit the whole-store budget cannot be retained.
      if (size > maxBytes || size > _maxBytes) throw const ImageSnapshotTooLarge();
      content = sha256.convert(bytes).toString();
      file = _contentFile(directory, content);
      if (!await file.exists()) await _writeAtomic(file, bytes);
      references[key] = content;
    }
    var clock = 0;
    for (final tick in index.accessed.values) {
      if (tick > clock) clock = tick;
    }
    index.accessed[content] = clock + 1;
    if (known) {
      await _saveIndex(directory, index);
    } else {
      await _commit(directory, index);
    }
    return file;
  }

  Future<void> removeSession(String host, String sessionId) => _exclusive(() async {
    final directory = await _directory();
    final index = await _readIndex(directory);
    index.references.remove(_identity([host, sessionId]));
    final retained = <String>{
      for (final references in index.references.values)
        for (final digest in references.values)
          if (digest != null) digest,
    };
    index.accessed.removeWhere((digest, _) => !retained.contains(digest));
    final discarded = <File>[];
    await for (final file in _contentDirectory(directory).list(followLinks: false)) {
      if (file is File && !retained.contains(file.uri.pathSegments.last)) discarded.add(file);
    }
    await _saveIndex(directory, index);
    for (final file in discarded) {
      await file.delete();
    }
  });

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

class _SnapshotIndex {
  _SnapshotIndex(this.references, this.accessed);

  final Map<String, Map<String, String?>> references;
  final Map<String, int> accessed;
}
