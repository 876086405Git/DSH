import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'read_list_data.dart';
import 'read_list_identity.dart';

export 'read_list_data.dart';

enum ReadListKind { models, providers, plugins, sessions }

typedef ReadListKey = ({ReadListIdentity identity, ReadListKind kind, String workspace});

ReadListKey? readListKey(ReadListIdentity? identity, ReadListKind kind, [String workspace = 'profile-global']) =>
    identity == null || workspace.length > 256 ? null : (identity: identity, kind: kind, workspace: workspace);

/// Attached weakly to authoritative responses. The cache never owns the raw
/// response, client, credentials or a write revision through these stamps.
class ReadListOrigin {
  const ReadListOrigin(this.identity, this.client, this.at, this.revision, {this.confirmed = true, int? readRevision})
    : readRevision = readRevision ?? revision;
  final ReadListIdentity? identity;
  final Object client;
  final DateTime at;
  final int revision;
  final int readRevision;
  final bool confirmed;
}

class ReadListEntry {
  const ReadListEntry(this.data, this.at, this.revision, this.bytes, this.projection);
  final ReadListData data;
  final DateTime at;
  final int revision;
  final int bytes;
  final String? projection;
}

class ReadListRefresh {
  const ReadListRefresh(this.identity, this.revision, {this.pending = false, this.failed = false});
  final ReadListIdentity? identity;
  final int revision;
  final bool pending;
  final bool failed;
}

/// Bounded, process-local, display-only snapshots. Bounds refer to encoded
/// whitelist data, not total Dart heap; row/text limits additionally bound
/// object counts. No persistence and no automatic retry/write behavior.
class ReadListCache {
  ReadListCache({
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 32,
    this.maxEntryBytes = 256 * 1024,
    this.maxBytes = 2 * 1024 * 1024,
  }) : now = now ?? _monotonicClock();

  static DateTime Function() _monotonicClock() {
    final start = DateTime.now();
    final elapsed = Stopwatch()..start();
    return () => start.add(elapsed.elapsed);
  }

  final DateTime Function() now;
  final Duration ttl;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxBytes;
  final _entries = <ReadListKey, ReadListEntry>{};
  final _refreshes = <ReadListKind, ReadListRefresh>{};
  final _origins = Expando<ReadListOrigin>();
  final _changes = StreamController<void>.broadcast();
  Timer? _expiry;
  int _bytes = 0;
  int _revision = 0;
  bool _closed = false;

  Stream<void> get changes => _changes.stream;
  int get encodedBytes => _bytes;
  int get entryCount => _entries.length;
  ReadListOrigin? origin(Object? value) => value == null ? null : _origins[value];

  int beginRefresh(ReadListKind kind, ReadListIdentity? identity) {
    final revision = ++_revision;
    _refreshes[kind] = ReadListRefresh(identity, revision, pending: true);
    _notify();
    return revision;
  }

  void finishRefresh(ReadListKind kind, int revision, {bool failed = false}) {
    final refresh = _refreshes[kind];
    if (refresh == null || refresh.revision != revision) return;
    _refreshes[kind] = ReadListRefresh(refresh.identity, revision, failed: failed);
    _notify();
  }

  ReadListRefresh? refresh(ReadListKind kind, ReadListIdentity? identity, Object? value) {
    final refresh = _refreshes[kind];
    if (refresh == null || refresh.identity != identity || (origin(value)?.readRevision ?? 0) > refresh.revision) {
      return null;
    }
    return refresh;
  }

  T stamp<T extends Object>(T value, ReadListIdentity? identity, Object client) {
    _origins[value] = ReadListOrigin(identity, client, now(), ++_revision);
    return value;
  }

  /// Re-filtering the same successful session list keeps its age, but changes
  /// the projection revision. Optimistic writes are never cached as success.
  T derive<T extends Object>(T value, ReadListOrigin? source, {bool confirmed = true}) {
    if (source != null) {
      _origins[value] = ReadListOrigin(
        source.identity,
        source.client,
        source.at,
        ++_revision,
        confirmed: confirmed && source.confirmed,
        readRevision: source.readRevision,
      );
    }
    return value;
  }

  bool current(Object value, ReadListIdentity? identity, Object? client) {
    final source = origin(value);
    // Explicit provider overrides may supply their own authoritative value.
    // Untagged values remain live-only: put() below never admits them.
    return source == null || client != null && identical(source.client, client) && source.identity == identity;
  }

  T? get<T extends ReadListData>(ReadListKey? key) {
    if (key == null) return null;
    _prune();
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return entry.data is T ? entry.data as T : null;
  }

  void invalidate(ReadListKey? key) {
    if (key != null && _remove(key)) {
      _arm();
      _notify();
    }
  }

  /// Invalidate every workspace projection after a server-confirmed mutation.
  void invalidateKind(ReadListKind kind, ReadListIdentity? identity) {
    final keys = _entries.keys.where((key) => key.kind == kind && key.identity == identity).toList();
    for (final key in keys) {
      _remove(key);
    }
    if (keys.isNotEmpty) {
      _arm();
      _notify();
    }
  }

  /// Projection is evaluated only for a confirmed, correctly attributed
  /// result; repeated widget builds cannot refresh its age or extend TTL.
  bool put(ReadListKey? key, Object source, ReadListData Function() project, {String? projection}) {
    final stamp = origin(source);
    if (_closed ||
        key == null ||
        stamp == null ||
        !stamp.confirmed ||
        stamp.identity != key.identity ||
        !now().isBefore(stamp.at.add(ttl))) {
      return false;
    }
    final previous = _entries[key];
    if (previous?.revision == stamp.revision && previous?.projection == projection) return true;
    ReadListData data;
    int bytes;
    try {
      data = project();
      bytes = utf8.encode(jsonEncode(data.toJson())).length;
    } on FormatException {
      if (_remove(key)) _notify();
      return false;
    }
    if (bytes > maxEntryBytes || bytes > maxBytes) {
      if (_remove(key)) _notify();
      return false;
    }
    _prune();
    _remove(key);
    while (_entries.isNotEmpty && (_entries.length >= maxEntries || _bytes + bytes > maxBytes)) {
      _remove(_entries.keys.first);
    }
    if (maxEntries <= 0) return false;
    _entries[key] = ReadListEntry(data, stamp.at, stamp.revision, bytes, projection);
    _bytes += bytes;
    _arm();
    _notify();
    return true;
  }

  bool _remove(ReadListKey key) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.bytes;
    return old != null;
  }

  void _prune() {
    final expired = [
      for (final e in _entries.entries)
        if (!now().isBefore(e.value.at.add(ttl))) e.key,
    ];
    for (final key in expired) {
      _remove(key);
    }
  }

  void _arm() {
    _expiry?.cancel();
    if (_entries.isEmpty || _closed) return;
    final until = _entries.values.map((e) => e.at.add(ttl)).reduce((a, b) => a.isBefore(b) ? a : b);
    _expiry = Timer(until.difference(now()), () {
      _prune();
      _notify();
      _arm();
    });
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  void close() {
    _closed = true;
    _expiry?.cancel();
    unawaited(_changes.close());
  }
}

final readListCacheProvider = Provider((ref) {
  final cache = ReadListCache();
  ref.onDispose(cache.close);
  return cache;
});

/// A new value per change: two `AsyncData(null)` compare equal, so a `void`
/// stream would reach its watchers only once.
final readListCacheChangesProvider = StreamProvider<Object>(
  (ref) => ref.watch(readListCacheProvider).changes.map((_) => Object()),
);

enum ReadListStatus { current, updating, offline, failed }

class ReadListView<T> {
  const ReadListView({
    this.value,
    this.status = ReadListStatus.current,
    this.readOnly = false,
    this.authoritative = false,
  });
  final T? value;
  final ReadListStatus status;
  final bool readOnly;

  /// A same-source response can remain visible while it refreshes, even if
  /// too large to cache. This flag does not grant writes while [readOnly].
  final bool authoritative;
}
