/// The phone owns one memory database. Network work stays outside transactions.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'companion_api.dart';
import 'errors.dart';
import 'json.dart' show uuidV4;

typedef _Row = Map<String, Object?>;

const _conflict = DshRemoteException(
  'companion/conflict', 'Companion memory changed; read it again', {'status': 409},
);

class CompanionMemoryStore {
  /// Takes ownership of [database]. Use one connection on the owning isolate.
  CompanionMemoryStore(
    Database database, {
    required int Function() nowMilliseconds,
    String Function()? createId,
  }) : _db = database, _now = nowMilliseconds, _createId = createId ?? uuidV4 {
    try {
      _db.execute('PRAGMA foreign_keys = ON');
      final version = _db.select('PRAGMA user_version').single['user_version'] as int;
      if (version > 1) {
        throw const DshRemoteException(
          'companion/newer-store', 'This memory store needs a newer app', {'status': 409},
        );
      }
      if (version == 0) {
        _transaction(() {
          _db.execute(_schema);
          _db.execute('INSERT INTO memory_archive(singleton, id) VALUES(1, ?)', [_createId()]);
          _db.execute('PRAGMA user_version = 1');
        });
      }
    } catch (_) {
      _db.close();
      rethrow;
    }
  }

  final Database _db;
  final int Function() _now;
  final String Function() _createId;

  void close() => _db.close();

  _Row get archive => Map<String, Object?>.from(_db.select('SELECT * FROM memory_archive').single);

  List<_Row> cards({bool includeInactive = false}) => [
    for (final row in _db.select('''
      SELECT c.*, t.mode AS topic_mode FROM memory_cards c
      JOIN memory_topics t ON t.id = c.topic_id
      ${includeInactive ? '' : "WHERE c.status != 'withdrawn'"}
      ORDER BY c.id
    ''')) _card(row),
  ];

  _Row _card(Row row) => {
    ...row,
    'keywords': (jsonDecode(row['keywords'] as String) as List).cast<String>(),
    'pinned': row['pinned'] == 1,
    'eligible': row['eligible'] == 1,
    'manual': row['manual'] == 1,
    'event_time': row['event_time'] == null ? null : jsonDecode(row['event_time'] as String),
    'followup': row['followup'] == null ? null : jsonDecode(row['followup'] as String),
    'evidence': [
      for (final source in _db.select('''
        SELECT s.*, m.role, m.scope, m.first_seq, m.said_at_utc, m.offset_minutes,
          m.edited_at_utc FROM memory_card_sources s
        JOIN memory_messages m ON m.id = s.message_id AND m.source_rev = s.source_rev
        WHERE s.card_id = ? ORDER BY s.support_group, m.first_seq
      ''', [row['id']])) Map<String, Object?>.from(source),
    ],
  };

  CompanionMemories memories() {
    final meta = archive;
    return CompanionMemories(
      storeId: meta['id']! as String,
      revision: meta['memory_revision']! as int,
      memoryRevision: meta['memory_revision']! as int,
      memories: [
        for (final row in cards()) CompanionMemory(
          id: row['id']! as String,
          text: row['text']! as String,
          kind: row['kind']! as String,
          keywords: row['keywords']! as List<String>,
          pinned: row['pinned']! as bool,
          createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at_ms']! as int, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at_ms']! as int, isUtc: true),
          expiresAt: row['expires_at_ms'] == null ? null :
              DateTime.fromMillisecondsSinceEpoch(row['expires_at_ms']! as int, isUtc: true),
        ),
      ],
    );
  }

  /// Returns only IDs proved imported from this exact snapshot revision.
  /// Reality needs separate evidence; a legacy manual/pinned label is not it.
  List<String> importLegacy(
    CompanionMigrationSnapshot snapshot, {
    Set<String> realityKnownIds = const {},
  }) => _transaction(() {
    final cleanup = <String>[];
    final realIds = realityKnownIds.map((id) => id.toLowerCase()).toSet();
    var changed = false;
    for (final memory in snapshot.memories) {
      final oldId = memory.id.toLowerCase();
      final mapping = _db.select('''
        SELECT * FROM memory_migrations WHERE legacy_store_id = ? AND legacy_card_id = ?
      ''', [snapshot.storeId, oldId]);
      if (mapping.isNotEmpty) {
        final read = mapping.single;
        if (read['read_revision'] == snapshot.revision && read['cleanup_state'] == 'pending') {
          cleanup.add(oldId);
        }
        continue;
      }
      final id = _createId();
      final topic = _createId();
      final real = realIds.contains(oldId);
      _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
      _db.execute('''
        INSERT INTO memory_cards(id, row_rev, kind, text, keywords, pinned, eligible,
          manual, topic_id, source_at_ms, created_at_ms, updated_at_ms, expires_at_ms)
        VALUES(?, 1, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
      ''', [id, memory.kind, memory.text, jsonEncode(memory.keywords), memory.pinned ? 1 : 0,
        real ? 1 : 0, topic, memory.updatedAt!.millisecondsSinceEpoch,
        memory.createdAt!.millisecondsSinceEpoch, memory.updatedAt!.millisecondsSinceEpoch,
        memory.expiresAt?.millisecondsSinceEpoch]);
      _db.execute('''
        INSERT INTO memory_migrations(legacy_store_id, legacy_card_id, read_revision,
          local_card_id, result) VALUES(?, ?, ?, ?, ?)
      ''', [snapshot.storeId, oldId, snapshot.revision, id, real ? 'imported' : 'display_only']);
      cleanup.add(oldId);
      changed = true;
    }
    if (changed) _bumpMemory();
    return cleanup;
  });

  /// Must be called after the import transaction committed and before source deletion.
  bool verifyLegacyImport(CompanionMigrationSnapshot snapshot, Iterable<String> ids) {
    for (final id in ids) {
      final rows = _db.select('''
        SELECT m.result, c.id AS card_id FROM memory_migrations m
        LEFT JOIN memory_cards c ON c.id = m.local_card_id
        WHERE m.legacy_store_id = ? AND m.legacy_card_id = ? AND m.read_revision = ?
      ''', [snapshot.storeId, id.toLowerCase(), snapshot.revision]);
      if (rows.isEmpty || (rows.single['result'] != 'forgotten' && rows.single['card_id'] == null)) return false;
    }
    return true;
  }

  void finishLegacyCleanup(String legacyStoreId, Iterable<String> ids) => _transaction(() {
    for (final id in ids) {
      _db.execute('''
        UPDATE memory_migrations SET cleanup_state = 'done'
        WHERE legacy_store_id = ? AND legacy_card_id = ?
      ''', [legacyStoreId, id.toLowerCase()]);
    }
  });

  List<_Row> migrationCleanup() => [
    for (final row in _db.select("SELECT * FROM memory_migrations WHERE cleanup_state = 'pending'"))
      Map<String, Object?>.from(row),
  ];

  /// No network is allowed between the version read and this synchronous write.
  int saveManual(
    CompanionMemory memory, {
    required int? expectedRowRev,
    required bool currentValueChange,
    required bool realityKnown,
  }) {
    memory.validateWrite();
    return _transaction(() {
      final id = memory.id.toLowerCase();
      final rows = _db.select('SELECT * FROM memory_cards WHERE id = ?', [id]);
      final previous = rows.isEmpty ? null : rows.single;
      if ((previous == null && expectedRowRev != null) ||
          (previous != null && previous['row_rev'] != expectedRowRev)) throw _conflict;
      final at = _now();
      if (at < 0 || at > 8640000000000000) {
        throw const DshRemoteException('companion/unavailable', 'Companion clock is unavailable', {'status': 503});
      }
      final topic = previous?['topic_id'] ?? _createId();
      final changedText = previous == null || previous['text'] != memory.text;
      final basis = changedText && currentValueChange && realityKnown ? _sequence() : previous?['current_basis_seq'];
      final status = previous == null || (changedText && currentValueChange && realityKnown)
          ? 'current' : previous['status'];
      if (previous == null) _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
      final revision = previous == null ? 1 : (previous['row_rev'] as int) + 1;
      _db.execute('''
        INSERT INTO memory_cards(id, row_rev, kind, text, keywords, pinned, eligible, manual,
          topic_id, current_basis_seq, source_at_ms, created_at_ms, updated_at_ms, expires_at_ms, status)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET row_rev=excluded.row_rev, kind=excluded.kind,
          text=excluded.text, keywords=excluded.keywords, pinned=excluded.pinned,
          eligible=excluded.eligible, manual=excluded.manual, current_basis_seq=excluded.current_basis_seq,
          source_at_ms=excluded.source_at_ms, updated_at_ms=excluded.updated_at_ms,
          expires_at_ms=excluded.expires_at_ms, status=excluded.status
      ''', [id, revision, memory.kind, memory.text, jsonEncode(memory.keywords),
        memory.pinned ? 1 : 0, changedText ? (realityKnown ? 1 : 0) : previous!['eligible'],
        changedText ? 1 : previous!['manual'], topic, basis,
        changedText ? at : previous!['source_at_ms'], previous?['created_at_ms'] ?? at,
        at, memory.expiresAt?.millisecondsSinceEpoch, status]);
      // An edit is its own manual basis; old quotes no longer prove the new wording.
      if (changedText) _db.execute('DELETE FROM memory_card_sources WHERE card_id = ?', [id]);
      _bumpMemory();
      return revision;
    });
  }

  int _sequence() {
    final sequence = archive['next_seq']! as int;
    _db.execute('UPDATE memory_archive SET next_seq = next_seq + 1 WHERE singleton = 1');
    return sequence;
  }

  void _bumpMemory() => _db.execute(
    'UPDATE memory_archive SET memory_revision = memory_revision + 1 WHERE singleton = 1',
  );

  T _transaction<T>(T Function() operation) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = operation();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
  }
}

const _schema = '''
CREATE TABLE memory_archive (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), id TEXT NOT NULL,
  next_seq INTEGER NOT NULL DEFAULT 1, cursor_seq INTEGER NOT NULL DEFAULT 0,
  control_revision INTEGER NOT NULL DEFAULT 0, history_after_seq INTEGER NOT NULL DEFAULT 0,
  memory_revision INTEGER NOT NULL DEFAULT 0, maintenance_revision INTEGER NOT NULL DEFAULT 0,
  widget_clear_pending INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE memory_messages (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, first_seq INTEGER NOT NULL UNIQUE,
  source_rev INTEGER NOT NULL, event_seq INTEGER NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('user','assistant')),
  scope TEXT NOT NULL CHECK(scope IN ('real','story')), text TEXT NOT NULL,
  said_at_utc INTEGER NOT NULL, offset_minutes INTEGER NOT NULL, edited_at_utc INTEGER
);
CREATE TABLE memory_events (
  seq INTEGER PRIMARY KEY, message_id TEXT NOT NULL REFERENCES memory_messages(id) ON DELETE CASCADE,
  source_rev INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','done','skipped','superseded')),
  reason TEXT, batch_id TEXT, format_failures INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX memory_events_pending ON memory_events(state,seq);
CREATE TABLE memory_topics (
  id TEXT PRIMARY KEY, mode TEXT NOT NULL DEFAULT 'normal' CHECK(mode IN ('normal','less','never'))
);
CREATE TABLE memory_cards (
  id TEXT PRIMARY KEY, row_rev INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('fact','preference','episode')), text TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]', pinned INTEGER NOT NULL DEFAULT 0,
  scope TEXT NOT NULL DEFAULT 'real' CHECK(scope IN ('real','story')), eligible INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'current' CHECK(status IN ('current','past','withdrawn')),
  manual INTEGER NOT NULL, topic_id TEXT NOT NULL REFERENCES memory_topics(id), current_basis_seq INTEGER,
  source_at_ms INTEGER NOT NULL, event_time TEXT, followup TEXT, plan_state TEXT,
  created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, expires_at_ms INTEGER
);
CREATE TABLE memory_card_sources (
  card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE, support_group TEXT NOT NULL,
  message_id TEXT NOT NULL REFERENCES memory_messages(id) ON DELETE CASCADE, source_rev INTEGER NOT NULL,
  quote TEXT NOT NULL, PRIMARY KEY(card_id,support_group,message_id,source_rev,quote)
);
CREATE INDEX memory_sources_message ON memory_card_sources(message_id,source_rev);
CREATE TABLE memory_migrations (
  legacy_store_id TEXT NOT NULL, legacy_card_id TEXT NOT NULL, read_revision INTEGER NOT NULL,
  local_card_id TEXT NOT NULL, result TEXT NOT NULL CHECK(result IN ('imported','display_only','forgotten')),
  cleanup_state TEXT NOT NULL DEFAULT 'pending' CHECK(cleanup_state IN ('pending','done')),
  PRIMARY KEY(legacy_store_id,legacy_card_id)
);
CREATE TABLE memory_requests (
  id TEXT PRIMARY KEY, category TEXT NOT NULL CHECK(category IN ('chat','extract','organize')),
  batch_id TEXT, provider TEXT NOT NULL, model TEXT NOT NULL, reserved_at_ms INTEGER NOT NULL,
  sent_at_ms INTEGER, reserved_input INTEGER NOT NULL, reserved_output INTEGER NOT NULL,
  reserved_cny REAL, raw_usage TEXT, usage_semantics TEXT, input_uncached INTEGER,
  input_cache_read INTEGER, input_cache_write INTEGER, output_tokens INTEGER,
  estimated_cny REAL, state TEXT NOT NULL, terminal TEXT
);
''';
