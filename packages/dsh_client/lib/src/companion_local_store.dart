/// App-owned companion state for lightweight mode. No engine, network or timer.
///
/// Give this store the App's private support directory, never an export/download
/// directory. One isolate owns a directory; instances in that isolate share a
/// queue. Other isolates/processes must route their requests to that owner.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'companion_api.dart';
import 'errors.dart';
import 'json.dart' show uuidV4;

const _types = ['visit', 'pet', 'snack', 'play', 'rest'];
const _maxBytes = 1024 * 1024;
const _maxMemories = 256;
const _maxSafe = 9007199254740991;
// DateTime (used by the shared models) has a smaller range than JS safe ints.
const _maxDateTime = 8640000000000000;
const _maxClock = _maxDateTime - 24 * 60 * 60 * 1000;
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
// ECMAScript trim whitespace, exactly as C303. Dart trim additionally removes
// U+0085, which is an allowed nonblank C303 string.
final _blankText = RegExp(r'^[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]*$');
final _queues = <String, Future<void>>{};

typedef _Json = Map<String, Object?>;

// Reuse the page's existing DshRemoteException conflict handling. These are
// local failures; their details carry a status but no file path or memory text.
const _invalid = DshRemoteException('companion/invalid-request', 'Invalid companion request', {'status': 400});
const _corrupt = DshRemoteException('companion/corrupt-store', 'Companion store requires recovery', {'status': 503});
const _ioError = DshRemoteException('companion/io-error', 'Companion storage operation failed', {'status': 500});

/// Bounded, unexpired pinned records, not keyword or semantic retrieval.
/// Rebuild on every submitted user turn; a revision alone does not track expiry.
class CompanionLocalContext {
  const CompanionLocalContext({
    required this.storeId,
    required this.revision,
    required this.memoryRevision,
    required this.memories,
    required this.truncated,
    required this.textCodePoints,
    this.nextExpiryAt,
  });
  final String storeId;
  final int revision;
  final int memoryRevision;
  final List<CompanionMemory> memories;
  final bool truncated;
  final int textCodePoints;
  final DateTime? nextExpiryAt;
}

class CompanionLocalStore {
  CompanionLocalStore({required Directory appDirectory, int Function()? nowMilliseconds})
    : _file = File.fromUri(appDirectory.absolute.uri.resolve('light-state.json').normalizePath()),
      _now = nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch);

  final File _file;
  final int Function() _now;

  Future<CompanionSnapshot> companionSnapshot() => _transaction((doc, at) => _snapshot(doc, at));

  /// Stale versions fail before cooldown is considered. A cooldown no-op returns
  /// the same revision; the caller still gives immediate local touch feedback.
  Future<CompanionSnapshot> companionEvent(String storeId, int expectedRevision, String type) {
    _versionInput(storeId, expectedRevision);
    if (!_types.contains(type)) throw _invalid;
    return _transaction((doc, at) async {
      _checkVersion(doc, storeId, expectedRevision);
      final state = _advance(doc['state']! as _Json, at);
      final logicalAt = state['anchorAt']! as int;
      final events = state['lastEvents']! as _Json;
      final previous = events[type];
      if (previous == null || logicalAt - _integer(previous)! >= 30000) {
        events[type] = logicalAt;
        state[type == 'visit' ? 'lastVisitAt' : 'lastInteractionAt'] = logicalAt;
        var valence = (state['valence']! as num).toDouble();
        var energy = (state['energy']! as num).toDouble();
        if (type == 'visit') valence += 0.04;
        if (type == 'pet') valence += 0.06;
        if (type == 'snack') {
          valence += 0.05;
          energy += 0.03;
          state['activity'] = 'snack';
          state['activityUntil'] = logicalAt + 45000;
        }
        if (type == 'play') {
          valence += 0.08;
          energy -= 0.04;
          state['activity'] = 'play';
          state['activityUntil'] = logicalAt + 90000;
        }
        if (type == 'rest') {
          state['activity'] = 'rest';
          state['activityUntil'] = logicalAt + 15 * 60000;
        }
        final lastGain = state['lastGainAt'];
        if (type != 'rest' && (lastGain == null || logicalAt - _integer(lastGain)! >= 6 * 3600000)) {
          state['closeness'] = ((state['closeness']! as num) + 0.01).clamp(0.0, 1.0);
          state['lastGainAt'] = logicalAt;
        }
        state['valence'] = valence.clamp(0.0, 1.0);
        state['energy'] = energy.clamp(0.0, 1.0);
        doc['state'] = state;
        await _commit(doc);
      }
      return _snapshot(doc, at);
    });
  }

  Future<CompanionMemories> companionMemories() => _transaction(
    (doc, _) => CompanionMemories(
      storeId: doc['storeId']! as String,
      revision: _integer(doc['revision'])!,
      memoryRevision: _integer(doc['memoryRevision'])!,
      memories: List.unmodifiable(_records(doc).map(_memory)),
    ),
  );

  /// A missing old store stays missing. Never initialize it merely to migrate.
  Future<CompanionMigrationSnapshot?> probeForMigration() => _enqueue(() async {
    final doc = await _readExisting();
    return doc == null
        ? null
        : CompanionMigrationSnapshot.fromJson({
            'v': doc['v'],
            'storeId': doc['storeId'],
            'revision': doc['revision'],
            'memoryRevision': doc['memoryRevision'],
            'memories': doc['memories'],
          });
  });

  /// Only a snapshot already committed and read back on the phone may call this.
  Future<int> removeMigratedMemories(String storeId, int revision, Set<String> ids) {
    _versionInput(storeId, revision);
    if (!ids.every(_uuid)) throw _invalid;
    final normalized = ids.map((id) => id.toLowerCase()).toSet();
    return _enqueue(() async {
      final doc = await _readExisting();
      if (doc == null) throw _corrupt;
      _checkVersion(doc, storeId, revision);
      final rows = _records(doc);
      final length = rows.length;
      rows.removeWhere((row) => normalized.contains((row['id']! as String).toLowerCase()));
      if (rows.length != length) {
        doc['memories'] = rows;
        await _commit(doc, memoryChanged: true);
      }
      return _integer(doc['revision'])!;
    });
  }

  /// Call only after the user has reviewed and confirmed the exact record.
  /// A model's text or a source.kind value is not evidence of confirmation.
  Future<int> saveCompanionMemory(String storeId, int revision, CompanionMemory memory) {
    _versionInput(storeId, revision);
    final input = memory.toWrite();
    if (!_validMemory(input, stored: false)) throw _invalid;
    // Detach before queueing: a caller may change its keywords while awaiting.
    final detached = _clone(input)..['id'] = memory.id.toLowerCase();
    return _transaction((doc, at) async {
      _checkVersion(doc, storeId, revision);
      final records = _records(doc);
      final index = records.indexWhere((m) => (m['id']! as String).toLowerCase() == detached['id']);
      if (index < 0 && records.length >= _maxMemories) {
        throw const DshRemoteException('companion/limit-reached', 'Companion memory limit reached', {'status': 409});
      }
      final previous = index < 0 ? null : records[index];
      if (previous != null && _sameMemory(previous, detached)) return _integer(doc['revision'])!;
      detached['createdAt'] = previous?['createdAt'] ?? at;
      detached['updatedAt'] = math.max(at, _integer(previous?['updatedAt']) ?? 0);
      if (index < 0) {
        records.add(detached);
      } else {
        records[index] = detached;
      }
      doc['memories'] = records;
      await _commit(doc, memoryChanged: true);
      return _integer(doc['revision'])!;
    });
  }

  Future<int> deleteCompanionMemory(String storeId, int revision, String id) {
    _versionInput(storeId, revision);
    if (!_uuid(id)) throw _invalid;
    return _transaction((doc, _) async {
      _checkVersion(doc, storeId, revision);
      final records = _records(doc);
      final index = records.indexWhere((m) => (m['id']! as String).toLowerCase() == id.toLowerCase());
      if (index >= 0) {
        records.removeAt(index);
        doc['memories'] = records;
        await _commit(doc, memoryChanged: true);
      }
      return _integer(doc['revision'])!;
    });
  }

  /// Keeps identity, vitals, activity and event cooldowns. Clearing an empty
  /// list is a no-op, exactly as the host's memories/clear endpoint.
  Future<int> clearCompanionMemories(String storeId, int revision) {
    _versionInput(storeId, revision);
    return _transaction((doc, _) async {
      _checkVersion(doc, storeId, revision);
      if (_records(doc).isNotEmpty) {
        doc['memories'] = <_Json>[];
        await _commit(doc, memoryChanged: true);
      }
      return _integer(doc['revision'])!;
    });
  }

  /// Local-only explicit reset: atomically replace state AND memories with a
  /// new store identity. Does not touch chat history, exports, keys or the host.
  /// A corrupt store still refuses this operation; it needs explicit recovery.
  Future<CompanionSnapshot> resetCompanion(String storeId, int revision) {
    _versionInput(storeId, revision);
    return _transaction((doc, at) async {
      _checkVersion(doc, storeId, revision);
      final fresh = _initial(at);
      await _write(fresh);
      return _snapshot(fresh, at);
    });
  }

  Future<Map<String, Object?>> exportCompanion() => _transaction(
    (doc, at) => {
      'schema': 'dsh-go/companion-export',
      ..._snapshotJson(doc, at),
      'exportedAt': at,
      'memories': _records(doc).map(_clone).toList(),
    },
  );

  /// The empty-query pinned subset of C303, with a smaller default text budget.
  /// No injection happens here. At most two pinned records are eligible before
  /// applying [limit]/[textCodePointBudget], and records are never cut mid-text.
  Future<CompanionLocalContext> pinnedCompanionContext({int limit = 2, int textCodePointBudget = 512}) {
    if (limit < 1 || limit > 12 || textCodePointBudget < 1 || textCodePointBudget > 2048) throw _invalid;
    return _transaction((doc, at) {
      final eligible = _records(doc).where((m) => m['expiresAt'] == null || _integer(m['expiresAt'])! > at).toList();
      final pinned = eligible.where((m) => m['pinned'] == true).toList()
        ..sort((a, b) {
          final byTime = _integer(b['updatedAt'])!.compareTo(_integer(a['updatedAt'])!);
          return byTime != 0
              ? byTime
              : (a['id']! as String).toLowerCase().compareTo((b['id']! as String).toLowerCase());
        });
      final selected = <CompanionMemory>[];
      var count = 0;
      var truncated = false;
      for (final record in pinned.take(2)) {
        final length = (record['text']! as String).runes.length;
        if (selected.length >= limit || count + length > textCodePointBudget) {
          truncated = true;
          continue;
        }
        selected.add(_memory(record));
        count += length;
      }
      final expiries = eligible.map((m) => _integer(m['expiresAt'])).whereType<int>().toList();
      return CompanionLocalContext(
        storeId: doc['storeId']! as String,
        revision: _integer(doc['revision'])!,
        memoryRevision: _integer(doc['memoryRevision'])!,
        memories: List.unmodifiable(selected),
        truncated: truncated,
        textCodePoints: count,
        nextExpiryAt: expiries.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(expiries.reduce(math.min)),
      );
    });
  }

  Future<T> _transaction<T>(FutureOr<T> Function(_Json, int) operation) {
    return _enqueue(() async {
      final at = _now();
      if (at < 0 || at > _maxClock) {
        throw const DshRemoteException('companion/unavailable', 'Companion clock is unavailable', {'status': 503});
      }
      final doc = await _read(at);
      return operation(doc, at);
    });
  }

  Future<T> _enqueue<T>(FutureOr<T> Function() operation) {
    final key = _file.path;
    final result = (_queues[key] ?? Future<void>.value()).then((_) => operation());
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _queues[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return result;
  }

  Future<_Json> _read(int at) async {
    final existing = await _readExisting();
    if (existing != null) return existing;
    final doc = _initial(at);
    await _write(doc);
    return doc;
  }

  Future<_Json?> _readExisting() async {
    RandomAccessFile? handle;
    try {
      handle = await _file.open();
      if (await handle.length() > _maxBytes) throw _corrupt;
      final bytes = <int>[];
      while (bytes.length <= _maxBytes) {
        final chunk = await handle.read(math.min(65536, _maxBytes + 1 - bytes.length));
        if (chunk.isEmpty) break;
        bytes.addAll(chunk);
      }
      if (bytes.length > _maxBytes) throw _corrupt;
      Object? value;
      try {
        value = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw _corrupt;
      }
      if (value is! _Json || !_validDocument(value)) throw _corrupt;
      return value;
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2 || (Platform.isWindows && error.osError?.errorCode == 3)) {
        return null;
      }
      throw _ioError;
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on FileSystemException {
          /* Best effort close. */
        }
      }
    }
  }

  Future<void> _write(_Json doc) async {
    if (!_validDocument(doc)) throw _corrupt;
    final bytes = utf8.encode(jsonEncode(doc));
    if (bytes.length > _maxBytes) {
      throw const DshRemoteException('companion/too-large', 'Companion store size limit reached', {'status': 413});
    }
    final temporary = File.fromUri(_file.parent.uri.resolve('.light-state-${uuidV4()}.tmp'));
    var created = false;
    try {
      await _file.parent.create(recursive: true);
      await temporary.create(exclusive: true);
      created = true;
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(_file.path);
    } on FileSystemException {
      throw _ioError;
    } finally {
      try {
        if (created) await temporary.delete();
      } on FileSystemException {
        /* Missing after rename, or best effort cleanup. */
      }
    }
  }

  Future<void> _commit(_Json doc, {bool memoryChanged = false}) async {
    final revision = _integer(doc['revision'])!;
    final memoryRevision = _integer(doc['memoryRevision'])!;
    if (revision == _maxSafe || (memoryChanged && memoryRevision == _maxSafe)) {
      throw const DshRemoteException('companion/unavailable', 'Companion revision limit reached', {'status': 503});
    }
    doc['revision'] = revision + 1;
    if (memoryChanged) doc['memoryRevision'] = memoryRevision + 1;
    await _write(doc);
  }
}

_Json _initial(int at) => {
  'v': 1,
  'storeId': uuidV4(),
  'companionId': 'whale-girl',
  'revision': 0,
  'memoryRevision': 0,
  'state': {
    'valence': 0.25,
    'energy': 0.75,
    'closeness': 0.0,
    'activity': 'idle',
    'activityUntil': null,
    'lastVisitAt': null,
    'lastInteractionAt': null,
    'anchorAt': at,
    'lastGainAt': null,
    'lastEvents': <String, Object?>{for (final type in _types) type: null},
  },
  'memories': <_Json>[],
};

_Json _advance(_Json state, int now) {
  final at = math.max(now, _integer(state['anchorAt'])!);
  final elapsed = at - _integer(state['anchorAt'])!;
  double relax(String key, double target, int halfLife) =>
      target + ((state[key]! as num).toDouble() - target) * math.pow(2, -elapsed / halfLife);
  final current = <String, Object?>{
    ...state,
    'valence': relax('valence', 0.25, 40 * 60000),
    'energy': relax('energy', 0.75, 2 * 3600000),
    'anchorAt': at,
    'lastEvents': {...state['lastEvents']! as _Json},
  };
  if (state['activityUntil'] != null && at >= _integer(state['activityUntil'])!) {
    current['activity'] = 'idle';
    current['activityUntil'] = null;
  }
  return current;
}

_Json _snapshotJson(_Json doc, int at) {
  final current = _advance(doc['state']! as _Json, at);
  final activity = current['activity'];
  final thought = switch (activity) {
    'snack' => 'enjoy-snack',
    'play' => 'enjoy-play',
    'rest' => 'rest',
    _ => (current['energy']! as num) < 0.4 ? 'take-it-easy' : 'enjoy-company',
  };
  return {
    'v': 1,
    'storeId': doc['storeId'],
    'companionId': doc['companionId'],
    'revision': doc['revision'],
    'memoryRevision': doc['memoryRevision'],
    'capabilities': {
      'persistence': 'app-local',
      'memories': true,
      'context': false,
      'export': true,
      'automaticRecall': false,
      'automaticExtraction': false,
    },
    'asOf': current['anchorAt'],
    'state': {
      for (final key in [
        'valence',
        'energy',
        'closeness',
        'activity',
        'activityUntil',
        'lastVisitAt',
        'lastInteractionAt',
      ])
        key: current[key],
      'thought': thought,
    },
  };
}

CompanionSnapshot _snapshot(_Json doc, int at) => CompanionSnapshot.fromJson(_snapshotJson(doc, at))!;
CompanionMemory _memory(_Json record) => CompanionMemory.fromJson(record)!;
List<_Json> _records(_Json doc) => (doc['memories']! as List).cast<_Json>().toList();
_Json _clone(_Json value) => jsonDecode(jsonEncode(value)) as _Json;

void _versionInput(String storeId, int revision) {
  if (!_uuid(storeId) || revision < 0 || revision > _maxSafe) throw _invalid;
}

void _checkVersion(_Json doc, String storeId, int revision) {
  if ((doc['storeId']! as String).toLowerCase() != storeId.toLowerCase()) {
    throw const DshRemoteException('companion/store-changed', 'Companion store changed; reload before writing', {
      'status': 409,
    });
  }
  if (_integer(doc['revision']) != revision) {
    throw const DshRemoteException('companion/conflict', 'Companion revision changed; reload before writing', {
      'status': 409,
    });
  }
}

bool _sameMemory(_Json a, _Json b) =>
    ['kind', 'text', 'pinned', 'expiresAt'].every((key) => a[key] == b[key]) &&
    jsonEncode(a['keywords']) == jsonEncode(b['keywords']) &&
    ['kind', 'sessionId', 'messageId'].every((key) => (a['source']! as _Json)[key] == (b['source']! as _Json)[key]);

int? _integer(Object? value) =>
    value is num && value.isFinite && value >= 0 && value <= _maxSafe && value == value.truncateToDouble()
    ? value.toInt()
    : null;
bool _time(Object? value) => _integer(value) != null && _integer(value)! <= _maxDateTime;
bool _nullableTime(Object? value) => value == null || _time(value);
bool _uuid(Object? value) => value is String && _uuidPattern.hasMatch(value);
bool _fields(Object? value, List<String> required, [List<String> optional = const []]) =>
    value is _Json &&
    required.every(value.containsKey) &&
    value.keys.every((k) => required.contains(k) || optional.contains(k));

bool _text(Object? value, int maximum, {bool multiline = false}) {
  if (value is! String || _blankText.hasMatch(value) || value.runes.length > maximum) return false;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0x20 && !(multiline && (unit == 9 || unit == 10 || unit == 13)) || unit == 0x7f) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length || value.codeUnitAt(i) < 0xdc00 || value.codeUnitAt(i) > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

bool _validMemory(Object? value, {required bool stored}) {
  final keys = [
    'id',
    'kind',
    'text',
    'keywords',
    'pinned',
    'source',
    'expiresAt',
    if (stored) ...['createdAt', 'updatedAt'],
  ];
  if (!_fields(value, keys)) return false;
  final m = value! as _Json;
  if (!_uuid(m['id']) ||
      !['fact', 'preference', 'episode'].contains(m['kind']) ||
      !_text(m['text'], 512, multiline: true) ||
      m['pinned'] is! bool ||
      !_nullableTime(m['expiresAt'])) {
    return false;
  }
  final keywords = m['keywords'];
  if (keywords is! List || keywords.length > 8 || !keywords.every((k) => _text(k, 24))) return false;
  if (!_fields(m['source'], ['kind'], ['sessionId', 'messageId'])) return false;
  final source = m['source']! as _Json;
  if (!['manual', 'user-confirmed'].contains(source['kind'])) return false;
  for (final key in ['sessionId', 'messageId']) {
    if (source.containsKey(key) &&
        (source[key] is! String || (source[key]! as String).length > 128 || !_text(source[key], 128))) {
      return false;
    }
  }
  return !stored ||
      _time(m['createdAt']) && _time(m['updatedAt']) && _integer(m['createdAt'])! <= _integer(m['updatedAt'])!;
}

bool _validDocument(_Json doc) {
  if (!_fields(doc, ['v', 'storeId', 'companionId', 'revision', 'memoryRevision', 'state', 'memories']) ||
      doc['v'] != 1 ||
      doc['companionId'] != 'whale-girl' ||
      !_uuid(doc['storeId']) ||
      _integer(doc['revision']) == null ||
      _integer(doc['memoryRevision']) == null ||
      _integer(doc['memoryRevision'])! > _integer(doc['revision'])!) {
    return false;
  }
  final memories = doc['memories'];
  if (memories is! List || memories.length > _maxMemories || !memories.every((m) => _validMemory(m, stored: true))) {
    return false;
  }
  if (memories.map((m) => ((m as _Json)['id']! as String).toLowerCase()).toSet().length != memories.length) {
    return false;
  }
  final state = doc['state'];
  if (!_fields(state, [
    'valence',
    'energy',
    'closeness',
    'activity',
    'activityUntil',
    'lastVisitAt',
    'lastInteractionAt',
    'anchorAt',
    'lastGainAt',
    'lastEvents',
  ])) {
    return false;
  }
  final s = state! as _Json;
  if (![
    'valence',
    'energy',
    'closeness',
  ].every((k) => s[k] is num && (s[k]! as num).isFinite && (s[k]! as num) >= 0 && (s[k]! as num) <= 1)) {
    return false;
  }
  if (!['idle', 'snack', 'play', 'rest'].contains(s['activity']) ||
      !_nullableTime(s['activityUntil']) ||
      (s['activity'] == 'idle') != (s['activityUntil'] == null) ||
      !_time(s['anchorAt']) ||
      _integer(s['anchorAt'])! > _maxClock) {
    return false;
  }
  if (![
    'lastVisitAt',
    'lastInteractionAt',
    'lastGainAt',
  ].every((k) => _nullableTime(s[k]) && (s[k] == null || _integer(s[k])! <= _integer(s['anchorAt'])!))) {
    return false;
  }
  if (!_fields(s['lastEvents'], _types)) return false;
  final events = s['lastEvents']! as _Json;
  return _types.every(
    (k) => _nullableTime(events[k]) && (events[k] == null || _integer(events[k])! <= _integer(s['anchorAt'])!),
  );
}
