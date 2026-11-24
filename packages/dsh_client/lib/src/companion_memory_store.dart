/// The phone owns one memory database. Network work stays outside transactions.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:sqlite3/sqlite3.dart';

import 'companion_api.dart';
import 'companion_memory_rules.dart';
import 'companion_usage_api.dart';
import 'errors.dart';
import 'json.dart' show uuidV4;

part 'companion_task_store.dart';
part 'companion_public_lookup_store.dart';
part 'companion_host_task_store.dart';
part 'companion_map_store.dart';
part 'companion_agent_memory_store.dart';
part 'companion_memory_scope_store.dart';
part 'companion_memory_maintenance_store.dart';
part 'companion_affinity_store.dart';
part 'companion_memory_embedding_store.dart';
part 'companion_notice_store.dart';

const _memoryEvidenceSelect = '''
  SELECT s.*, m.role, m.scope, m.first_seq, m.said_at_utc, m.offset_minutes, m.edited_at_utc
  FROM memory_card_sources s
  JOIN memory_messages m ON m.id = s.message_id AND m.source_rev = s.source_rev
''';

const _conflict = DshRemoteException('companion/conflict', 'Companion memory changed; read it again', {'status': 409});
const _cleanupUnknown = DshRemoteException(
  'companion/cleanup-source-unknown',
  'Original source cleanup cannot be fully verified',
  {'status': 409},
);

/// A complete read-only dependency decision. Callers validate the whole set
/// before entering a write phase; a rejected later item cannot commit a prefix.
class _MemoryRemovalPlan {
  _MemoryRemovalPlan(Set<String> cards, Set<String> rawSources)
    : cards = Set.unmodifiable(cards),
      rawSources = Set.unmodifiable(rawSources);

  final Set<String> cards;
  final Set<String> rawSources;
}

class _MemoryMergePlan {
  _MemoryMergePlan({
    required MemoryRow target,
    required MemoryRow from,
    required List<List<MemoryRow>> proofGroups,
    required List<String> keywords,
    required this.currentBasisSeq,
    required this.sourceAtMs,
    List<String>? controlAnchors,
  }) : target = Map.unmodifiable(target),
       from = Map.unmodifiable(from),
       proofGroups = List.unmodifiable([
         for (final group in proofGroups)
           List<MemoryRow>.unmodifiable([for (final proof in group) Map<String, Object?>.unmodifiable(proof)]),
       ]),
       keywords = List.unmodifiable(keywords),
       controlAnchors = controlAnchors == null ? null : List.unmodifiable(controlAnchors);

  final MemoryRow target, from;
  final List<List<MemoryRow>> proofGroups;
  final List<String> keywords;
  final int currentBasisSeq, sourceAtMs;
  final List<String>? controlAnchors;
}

class CompanionMemoryStore {
  /// Takes ownership of [database]. Use one connection on the owning isolate.
  CompanionMemoryStore(Database database, {required int Function() nowMilliseconds, String Function()? createId})
    : _db = database,
      _now = nowMilliseconds,
      _createId = createId ?? uuidV4 {
    try {
      _db.execute('PRAGMA foreign_keys = ON');
      _db.execute('PRAGMA busy_timeout = 1000');
      final version = _db.select('PRAGMA user_version').single['user_version'] as int;
      if (version > 17) {
        throw const DshRemoteException('companion/newer-store', 'This memory store needs a newer app', {'status': 409});
      }
      if (version == 0) {
        _transaction(() {
          _db.execute(_schema);
          _db.execute('INSERT INTO memory_archive(singleton, id) VALUES(1, ?)', [_createId()]);
          _db.execute('PRAGMA user_version = 1');
        });
      }
      if (version < 2) {
        _transaction(() {
          _db.execute('ALTER TABLE memory_events ADD COLUMN queued_at_ms INTEGER NOT NULL DEFAULT 0');
          _db.execute('CREATE INDEX memory_events_batch ON memory_events(batch_id,seq)');
          _db.execute('ALTER TABLE memory_requests ADD COLUMN uncertain_at_ms INTEGER');
          _db.execute('ALTER TABLE memory_archive ADD COLUMN light_session_id TEXT');
          _db.execute('UPDATE memory_archive SET light_session_id=? WHERE singleton=1', ['light:${_createId()}']);
          _db.execute('''
            CREATE TABLE memory_batches (
              id TEXT PRIMARY KEY, control_revision INTEGER NOT NULL,
              existing_revisions TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('claimed','ready'))
            )
          ''');
          _db.execute('PRAGMA user_version = 2');
        });
      }
      if (version < 3) {
        _transaction(() {
          _db.execute('''
            CREATE TABLE memory_deleted_messages (
              id TEXT PRIMARY KEY, first_seq INTEGER NOT NULL
            )
          ''');
          _db.execute('PRAGMA user_version = 3');
        });
      }
      if (version < 4) {
        _transaction(() {
          _db.execute('''
            CREATE TABLE memory_host_chat_deliveries (
              id TEXT PRIMARY KEY, host_key TEXT NOT NULL, instance_id TEXT NOT NULL,
              session_id TEXT NOT NULL, request_id TEXT NOT NULL, archive_id TEXT NOT NULL,
              control_revision INTEGER NOT NULL, history_after_seq INTEGER NOT NULL,
              observed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('pending','running','settled','unknown')),
              snapshot_revision INTEGER NOT NULL DEFAULT 0, snapshot_metadata TEXT,
              unknown_gaps TEXT, unknown_instance_id TEXT,
              UNIQUE(host_key,instance_id,session_id,request_id)
            );
            CREATE TABLE memory_host_chat_receipts (
              id TEXT PRIMARY KEY, host_key TEXT NOT NULL, instance_id TEXT NOT NULL,
              receipt_id TEXT NOT NULL, revision INTEGER NOT NULL,
              phase TEXT NOT NULL CHECK(phase IN ('active','finished')), receipt_json TEXT NOT NULL,
              first_observed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
              UNIQUE(host_key,instance_id,receipt_id)
            );
            CREATE TABLE memory_host_chat_delivery_receipts (
              delivery_id TEXT NOT NULL REFERENCES memory_host_chat_deliveries(id),
              receipt_id TEXT NOT NULL REFERENCES memory_host_chat_receipts(id),
              PRIMARY KEY(delivery_id,receipt_id)
            );
            CREATE INDEX memory_host_chat_receipts_delivery
              ON memory_host_chat_delivery_receipts(receipt_id,delivery_id);
          ''');
          _db.execute('PRAGMA user_version = 4');
        });
      }
      if (version < 5) {
        _transaction(() {
          _db.execute('ALTER TABLE memory_migrations ADD COLUMN source_fingerprint TEXT');
          _db.execute('ALTER TABLE memory_migrations ADD COLUMN cleanup_read_revision INTEGER NOT NULL DEFAULT 0');
          _db.execute('UPDATE memory_migrations SET cleanup_read_revision=read_revision');
          _db.execute('PRAGMA user_version = 5');
        });
      }
      if (version < 6) {
        _transaction(() {
          _db.execute('ALTER TABLE memory_archive ADD COLUMN followup_after_seq INTEGER NOT NULL DEFAULT 0');
          _db.execute('''
            CREATE TABLE memory_initiative_state (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1),
              last_greeting_at_ms INTEGER, declined_until_ms INTEGER NOT NULL, night_json TEXT
            );
            CREATE TABLE memory_followups (
              id TEXT PRIMARY KEY, row_rev INTEGER NOT NULL, time_key TEXT NOT NULL,
              card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
              card_rev INTEGER NOT NULL, control_revision INTEGER NOT NULL,
              message_id TEXT NOT NULL REFERENCES memory_messages(id) ON DELETE CASCADE,
              source_rev INTEGER NOT NULL, invitation TEXT NOT NULL,
              source_first_seq INTEGER NOT NULL, said_at_utc INTEGER NOT NULL, offset_minutes INTEGER NOT NULL,
              wait_subject TEXT, opens_at_ms INTEGER, expires_at_ms INTEGER, local_line TEXT,
              support_message_id TEXT REFERENCES memory_messages(id) ON DELETE CASCADE,
              support_source_rev INTEGER, support_quote TEXT,
              state TEXT NOT NULL CHECK(state IN ('waiting','pending','reserved','asked','closed','maybe_shown')),
              reason TEXT, presented_at_ms INTEGER
            );
            CREATE TABLE memory_initiative_spends (
              id TEXT PRIMARY KEY, opportunity_id TEXT,
              kind TEXT NOT NULL CHECK(kind IN ('invite','signal','followup')),
              reserved_at_ms INTEGER NOT NULL, presented_at_ms INTEGER,
              state TEXT NOT NULL CHECK(state IN ('reserved','shown','released','unknown')),
              CHECK((kind='followup')=(opportunity_id IS NOT NULL))
            );
            CREATE INDEX memory_initiative_time ON memory_initiative_spends(reserved_at_ms,state);
          ''');
          _db.execute('PRAGMA user_version = 6');
        });
      }
      if (version < 7) {
        _transaction(() {
          _db.execute('''
            CREATE TABLE memory_requests_v7 (
              id TEXT PRIMARY KEY, category TEXT NOT NULL CHECK(category IN ('chat','extract','organize','followup')),
              batch_id TEXT, provider TEXT NOT NULL, model TEXT NOT NULL, reserved_at_ms INTEGER NOT NULL,
              sent_at_ms INTEGER, reserved_input INTEGER NOT NULL, reserved_output INTEGER NOT NULL,
              reserved_cny REAL, raw_usage TEXT, usage_semantics TEXT, input_uncached INTEGER,
              input_cache_read INTEGER, input_cache_write INTEGER, output_tokens INTEGER,
              estimated_cny REAL, state TEXT NOT NULL, terminal TEXT, uncertain_at_ms INTEGER
            );
            INSERT INTO memory_requests_v7 SELECT * FROM memory_requests;
            DROP TABLE memory_requests;
            ALTER TABLE memory_requests_v7 RENAME TO memory_requests;
            UPDATE memory_followups SET local_line=NULL;
          ''');
          _db.execute('PRAGMA user_version = 7');
        });
      }
      if (version < 8) {
        _transaction(() {
          _db.execute('ALTER TABLE memory_cards ADD COLUMN maintenance_row_rev INTEGER NOT NULL DEFAULT 0');
          _db.execute('''
            CREATE TABLE memory_merge_batches (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), id TEXT NOT NULL UNIQUE,
              control_revision INTEGER NOT NULL, memory_revision INTEGER NOT NULL,
              card_revisions TEXT NOT NULL
            )
          ''');
          _db.execute('PRAGMA user_version = 8');
        });
      }
      if (version < 9) {
        _transaction(() {
          _db.execute("ALTER TABLE memory_topics ADD COLUMN control_anchors TEXT NOT NULL DEFAULT '[]'");
          // Old stores can only recover anchors still backed by valid facts.
          // An already-cleared keyword is not reconstructed from withdrawn text.
          for (final topic in _db.select("SELECT id FROM memory_topics WHERE mode IN ('less','never')")) {
            final id = topic['id'] as String;
            _db.execute('UPDATE memory_topics SET control_anchors=? WHERE id=?', [jsonEncode(_controlAnchors(id)), id]);
          }
          _db.execute('PRAGMA user_version = 9');
        });
      }
      if (version < 10) {
        _transaction(() {
          _db.execute('''
            ALTER TABLE memory_cards ADD COLUMN cleanup_history_complete INTEGER NOT NULL DEFAULT 0
              CHECK(cleanup_history_complete IN (0,1))
          ''');
          _db.execute('''
            CREATE TABLE memory_card_cleanup_sources (
              card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
              message_id TEXT NOT NULL REFERENCES memory_messages(id) ON DELETE CASCADE,
              proof_withdrawn INTEGER NOT NULL DEFAULT 0 CHECK(proof_withdrawn IN (0,1)),
              PRIMARY KEY(card_id,message_id)
            )
          ''');
          _db.execute('CREATE INDEX memory_cleanup_message ON memory_card_cleanup_sources(message_id)');
          // Only still-recorded identities can be recovered from older stores.
          _db.execute('''
            INSERT OR IGNORE INTO memory_card_cleanup_sources(card_id,message_id)
              SELECT card_id,message_id FROM memory_card_sources
          ''');
          // A legacy independent manual value has no phone-chat source to lose.
          // For automatic cards even a surviving OR proof cannot certify history.
          _db.execute('''
            UPDATE memory_cards SET cleanup_history_complete=1 WHERE manual=1
              AND NOT EXISTS(SELECT 1 FROM memory_card_sources s WHERE s.card_id=memory_cards.id)
          ''');
          _db.execute('PRAGMA user_version = 10');
        });
      }
      if (version < 11) {
        _transaction(() {
          _db.execute('ALTER TABLE memory_messages ADD COLUMN zone_id TEXT');
          _db.execute('ALTER TABLE memory_messages ADD COLUMN offset_seconds INTEGER');
          _db.execute(_taskSchema);
          _db.execute('PRAGMA user_version = 11');
        });
      }
      if (version < 12) {
        _transaction(() {
          _db.execute(_lookupSchema);
          _db.execute('PRAGMA user_version = 12');
        });
      }
      if (version < 13) {
        _transaction(() {
          _db.execute(_hostTaskSchema);
          _db.execute('PRAGMA user_version = 13');
        });
      }
      if (version < 14) {
        _transaction(() {
          _db.execute(_mapSchema);
          _db.execute('PRAGMA user_version = 14');
        });
      }
      if (version < 15) {
        _transaction(() {
          _db.execute(_agentMemorySchema);
          _db.execute('ALTER TABLE memory_followups ADD COLUMN agent_origin INTEGER NOT NULL DEFAULT 0');
          _db.execute('PRAGMA user_version = 15');
        });
      }
      if (version < 16) {
        _transaction(() {
          _db.execute(_memoryScopeSchema16);
          _db.execute(_companionAffinitySchema16);
          _db.execute(_memoryEmbeddingSchema16);
          _migrateAgentMemory16();
          _db.execute('PRAGMA user_version = 16');
        });
      }
      if (version < 17) _migrateNotices();
      _transaction(() {
        // A cold process can read old effects, but cannot retry an unknown
        // dispatched maintenance source under a new claim identity.
        _retireAgentMaintenanceOnOpen();
        _db.execute('UPDATE memory_agent_turns SET closed=1 WHERE closed=0');
        // A response captured by the previous process cannot own a new batch.
        // Its sent/uncertain request receipt keeps the existing budget hold.
        _db.execute('DELETE FROM memory_merge_batches');
        _db.execute(
          "UPDATE memory_requests SET state='released', terminal='not_sent' "
          "WHERE sent_at_ms IS NULL AND state='reserved'",
        );
        _db.execute(
          "UPDATE memory_requests SET state='interrupted', terminal='interrupted' "
          "WHERE sent_at_ms IS NOT NULL AND terminal IS NULL",
        );
        _db.execute(
          "UPDATE memory_followups SET state='maybe_shown',reason='presentation_unknown',row_rev=row_rev+1 "
          "WHERE state='reserved' AND id IN (SELECT opportunity_id FROM memory_initiative_spends WHERE state='reserved')",
        );
        _db.execute("UPDATE memory_initiative_spends SET state='unknown' WHERE state='reserved'");
      });
    } catch (_) {
      _db.close();
      rethrow;
    }
  }

  final Database _db;
  final int Function() _now;
  final String Function() _createId;

  _PendingRawErase? _pendingRawErase;

  void close() {
    invalidateRawErase();
    _db.close();
  }

  MemoryRow get archive => Map<String, Object?>.from(_db.select('SELECT * FROM memory_archive').single);

  String get lightSessionId => archive['light_session_id'] as String;

  /// A fresh model conversation; previous messages remain available to view.
  String startLightConversation() => _transaction(() {
    final session = 'light:${_createId()}';
    _db.execute('UPDATE memory_archive SET light_session_id=? WHERE singleton=1', [session]);
    return session;
  });

  List<MemoryRow> cards({bool includeInactive = false}) => [for (final row in _cardRows(includeInactive)) _card(row)];

  ResultSet _cardRows(bool includeInactive) => _db.select('''
      SELECT c.*, t.mode AS topic_mode FROM memory_cards c
      JOIN memory_topics t ON t.id = c.topic_id
      ${includeInactive ? '' : "WHERE c.status != 'withdrawn'"}
      ORDER BY c.id
    ''');

  /// The current `row_rev` of each of [ids] that is a card and not withdrawn.
  Map<String, int> cardRevisions(Iterable<String> ids) => {
    for (final row in _db.select(
      '''
      SELECT c.id, c.row_rev FROM memory_cards c JOIN memory_topics t ON t.id = c.topic_id
      WHERE c.status != 'withdrawn' AND c.id IN (SELECT value FROM json_each(?))
    ''',
      [jsonEncode(ids.toList())],
    ))
      row['id'] as String: row['row_rev'] as int,
  };

  MemoryRow _card(Row row, {bool includeEvidence = true}) => {
    ...row,
    'layer': _memoryLayer(row.containsKey('collection') ? row['collection'] as String : 'about_you'),
    if (row['collection'] == 'recent') 'source': _noticeSource(row['id'] as String),
    'keywords': (jsonDecode(row['keywords'] as String) as List).cast<String>(),
    'pinned': row['pinned'] == 1,
    'eligible': row['eligible'] == 1,
    'manual': row['manual'] == 1,
    'reality_unconfirmed':
        row['scope'] == 'real' &&
        row['status'] == 'current' &&
        row['eligible'] == 0 &&
        _db.select("SELECT 1 FROM memory_migrations WHERE local_card_id=? AND result='display_only'", [
          row['id'],
        ]).isNotEmpty,
    'event_time': row['event_time'] == null ? null : jsonDecode(row['event_time'] as String),
    'followup': row['followup'] == null ? null : jsonDecode(row['followup'] as String),
    'evidence': [
      if (includeEvidence)
        for (final source in _db.select(
          '''
        $_memoryEvidenceSelect
        WHERE s.card_id = ? ORDER BY s.support_group, m.first_seq
      ''',
          [row['id']],
        ))
          Map<String, Object?>.from(source),
    ],
  };

  CompanionMemories memories() {
    final meta = archive;
    return CompanionMemories(
      storeId: meta['id']! as String,
      revision: meta['memory_revision']! as int,
      memoryRevision: meta['memory_revision']! as int,
      memories: [
        for (final row in cards())
          CompanionMemory(
            id: row['id']! as String,
            text: row['text']! as String,
            kind: row['kind']! as String,
            keywords: row['keywords']! as List<String>,
            pinned: row['pinned']! as bool,
            createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at_ms']! as int, isUtc: true),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at_ms']! as int, isUtc: true),
            expiresAt: row['expires_at_ms'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row['expires_at_ms']! as int, isUtc: true),
          ),
      ],
    );
  }

  /// Returns IDs whose original source fingerprint matches this complete read.
  /// A newer source revision can re-prove unchanged cards after partial cleanup.
  /// Reality needs separate evidence; a legacy manual/pinned label is not it.
  List<String> importLegacy(CompanionMigrationSnapshot snapshot, {Set<String> realityKnownIds = const {}}) =>
      _transaction(() {
        final cleanup = <String>[];
        final realIds = realityKnownIds.map((id) => id.toLowerCase()).toSet();
        var changed = false;
        for (final memory in snapshot.memories) {
          final oldId = memory.id.toLowerCase();
          final fingerprint = _legacyFingerprint(snapshot.storeId, memory);
          final mapping = _db.select(
            '''
        SELECT * FROM memory_migrations WHERE legacy_store_id = ? AND legacy_card_id = ?
      ''',
            [snapshot.storeId, oldId],
          );
          if (mapping.isNotEmpty) {
            final read = mapping.single;
            if (snapshot.revision < (read['cleanup_read_revision'] as int)) continue;
            var original = read['source_fingerprint'] as String?;
            // Pre-v5 mappings did not retain the original source bytes. Only the
            // exact original source revision can supply that missing fingerprint.
            if (original == null && read['read_revision'] == snapshot.revision) original = fingerprint;
            // Even a mismatch is a newer observation: an old cleanup ACK must not
            // complete this pending identity after a different source was seen.
            _db.execute(
              '''
          UPDATE memory_migrations SET source_fingerprint=?, cleanup_read_revision=?, cleanup_state='pending'
          WHERE legacy_store_id=? AND legacy_card_id=?
        ''',
              [original, snapshot.revision, snapshot.storeId, oldId],
            );
            if (original == fingerprint) {
              cleanup.add(oldId);
            }
            continue;
          }
          final controlled = _bodyControlledTopics(memory.text, characterId: null);
          if (controlled.length > 1) {
            throw const DshRemoteException(
              'companion/invalid-request',
              'Legacy memory matches multiple controlled topics',
              {'status': 400, 'reason': 'ambiguous_controlled_topic'},
            );
          }
          final id = _createId();
          final topic = controlled.isEmpty ? _createId() : controlled.single;
          final real = realIds.contains(oldId);
          if (controlled.isEmpty) _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
          _db.execute(
            '''
        INSERT INTO memory_cards(id, row_rev, kind, text, keywords, pinned, eligible,
          manual, topic_id, source_at_ms, created_at_ms, updated_at_ms, expires_at_ms,cleanup_history_complete)
        VALUES(?, 1, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?,1)
      ''',
            [
              id,
              memory.kind,
              memory.text,
              jsonEncode(memory.keywords),
              memory.pinned ? 1 : 0,
              real ? 1 : 0,
              topic,
              memory.updatedAt!.millisecondsSinceEpoch,
              memory.createdAt!.millisecondsSinceEpoch,
              memory.updatedAt!.millisecondsSinceEpoch,
              memory.expiresAt?.millisecondsSinceEpoch,
            ],
          );
          _db.execute(
            '''
        INSERT INTO memory_migrations(legacy_store_id, legacy_card_id, read_revision,
          local_card_id, result, source_fingerprint, cleanup_read_revision) VALUES(?, ?, ?, ?, ?, ?, ?)
      ''',
            [
              snapshot.storeId,
              oldId,
              snapshot.revision,
              id,
              real ? 'imported' : 'display_only',
              fingerprint,
              snapshot.revision,
            ],
          );
          cleanup.add(oldId);
          changed = true;
        }
        if (changed) _bumpMemory();
        return cleanup;
      });

  /// Must be called after the import transaction committed and before source deletion.
  bool verifyLegacyImport(CompanionMigrationSnapshot snapshot, Iterable<String> ids) {
    final source = {for (final memory in snapshot.memories) memory.id.toLowerCase(): memory};
    for (final id in ids) {
      final memory = source[id.toLowerCase()];
      if (memory == null) return false;
      final rows = _db.select(
        '''
        SELECT m.result, c.id AS card_id FROM memory_migrations m
        LEFT JOIN memory_cards c ON c.id = m.local_card_id
        WHERE m.legacy_store_id = ? AND m.legacy_card_id = ? AND m.cleanup_read_revision = ?
          AND m.cleanup_state = 'pending' AND m.source_fingerprint = ?
      ''',
        [snapshot.storeId, id.toLowerCase(), snapshot.revision, _legacyFingerprint(snapshot.storeId, memory)],
      );
      if (rows.isEmpty || (rows.single['result'] != 'forgotten' && rows.single['card_id'] == null)) return false;
    }
    return true;
  }

  /// [expectedReadRevision] is the original full read for this proof batch. It
  /// stays fixed while this batch's own delete receipts advance the remote CAS.
  /// A later full read fences late acknowledgements from an older proof batch.
  void finishLegacyCleanup(String legacyStoreId, Iterable<String> ids, {required int expectedReadRevision}) =>
      _transaction(() {
        if (expectedReadRevision < 0 || expectedReadRevision > 9007199254740991) {
          throw ArgumentError.value(expectedReadRevision, 'expectedReadRevision');
        }
        for (final id in ids) {
          _db.execute(
            '''
        UPDATE memory_migrations SET cleanup_state = 'done'
        WHERE legacy_store_id = ? AND legacy_card_id = ? AND cleanup_read_revision = ?
          AND cleanup_state = 'pending' AND source_fingerprint IS NOT NULL
      ''',
            [legacyStoreId.toLowerCase(), id.toLowerCase(), expectedReadRevision],
          );
        }
      });

  /// A complete source read can prove absence even for a pre-v5 mapping without
  /// a fingerprint. An older read cannot erase a more recent pending observation.
  void finishMissingLegacyCleanup(CompanionMigrationSnapshot snapshot) => _transaction(() {
    final present = snapshot.memories.map((memory) => memory.id.toLowerCase()).toSet();
    final rows = _db.select(
      '''
      SELECT legacy_card_id FROM memory_migrations
      WHERE legacy_store_id=? AND cleanup_state='pending' AND cleanup_read_revision<=?
    ''',
      [snapshot.storeId, snapshot.revision],
    );
    for (final row in rows) {
      if (present.contains(row['legacy_card_id'])) continue;
      _db.execute(
        '''
        UPDATE memory_migrations SET cleanup_state='done', cleanup_read_revision=?
        WHERE legacy_store_id=? AND legacy_card_id=? AND cleanup_state='pending' AND cleanup_read_revision<=?
      ''',
        [snapshot.revision, snapshot.storeId, row['legacy_card_id'], snapshot.revision],
      );
    }
  });

  static String _legacyFingerprint(String storeId, CompanionMemory memory) {
    final encoded = jsonEncode([
      'companion-legacy-card-v1',
      storeId.toLowerCase(),
      memory.id.toLowerCase(),
      memory.kind,
      memory.text,
      memory.keywords,
      memory.pinned,
      [memory.source.kind, memory.source.sessionId, memory.source.messageId],
      memory.expiresAt?.millisecondsSinceEpoch,
      memory.createdAt!.millisecondsSinceEpoch,
      memory.updatedAt!.millisecondsSinceEpoch,
    ]);
    return 'sha256-v1:${sha256.convert(utf8.encode(encoded))}';
  }

  List<MemoryRow> migrationCleanup() => [
    for (final row in _db.select("SELECT * FROM memory_migrations WHERE cleanup_state = 'pending'"))
      Map<String, Object?>.from(row),
  ];

  /// The stable ID belongs to the original send, not to a merged display line.
  /// Repeating it is safe only when the original statement is unchanged.
  MemoryRow submitMessage({
    required String id,
    required String sessionId,
    required String text,
    String role = 'user',
    String scope = 'real',
    required int saidAtUtc,
    required int offsetMinutes,
    String? zoneId,
    int? offsetSeconds,
    String? characterId,
  }) {
    _messageText(text);
    if (id.trim().isEmpty ||
        sessionId.trim().isEmpty ||
        !const ['user', 'assistant'].contains(role) ||
        !const ['real', 'story'].contains(scope) ||
        (zoneId != null && (zoneId.isEmpty || zoneId.trim() != zoneId)) ||
        (offsetSeconds != null &&
            (offsetSeconds < -64800 || offsetSeconds > 64800 || offsetSeconds ~/ 60 != offsetMinutes)) ||
        saidAtUtc < 0 ||
        saidAtUtc > 8640000000000000) {
      throw const DshRemoteException('companion/invalid-request', 'Invalid companion source', {'status': 400});
    }
    return _transaction(() {
      _checkMemoryCharacter(characterId);
      if (_db.select('SELECT 1 FROM memory_deleted_messages WHERE id=?', [id]).isNotEmpty) {
        throw const DshRemoteException('companion/deleted-source', 'This original companion message was deleted', {
          'status': 410,
        });
      }
      final previous = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
      if (previous.isNotEmpty) {
        final row = previous.single;
        if (row['session_id'] != sessionId ||
            row['text'] != text ||
            row['role'] != role ||
            row['scope'] != scope ||
            row['said_at_utc'] != saidAtUtc ||
            row['offset_minutes'] != offsetMinutes ||
            row['zone_id'] != zoneId ||
            row['offset_seconds'] != offsetSeconds ||
            row['character_id'] != characterId) {
          throw _conflict;
        }
        return Map<String, Object?>.from(row);
      }
      final at = _checkedNow();
      final sequence = _sequence();
      _db.execute(
        '''
        INSERT INTO memory_messages(id,session_id,first_seq,source_rev,event_seq,role,scope,text,
          said_at_utc,offset_minutes,zone_id,offset_seconds,character_id) VALUES(?,?,?,1,?,?,?,?,?,?,?,?,?)
      ''',
        [
          id,
          sessionId,
          sequence,
          sequence,
          role,
          scope,
          text,
          saidAtUtc,
          offsetMinutes,
          zoneId,
          offsetSeconds,
          characterId,
        ],
      );
      _queueMessage(id, sequence, 1, role: role, scope: scope, firstSeq: sequence, at: at);
      _advanceCursor();
      return Map<String, Object?>.from(_db.select('SELECT * FROM memory_messages WHERE id=?', [id]).single);
    });
  }

  MemoryRow editMessage({required String id, required int expectedSourceRev, required String text}) {
    _messageText(text);
    return _transaction(() {
      final rows = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
      if (rows.isEmpty || rows.single['source_rev'] != expectedSourceRev) throw _conflict;
      final previous = rows.single;
      if (previous['text'] == text) return Map<String, Object?>.from(previous);
      final at = _checkedNow();
      final sequence = _sequence();
      _removeSourceGroups(id, expectedSourceRev);
      _db.execute("UPDATE memory_events SET state='superseded', reason='edited' WHERE message_id=? AND source_rev=?", [
        id,
        expectedSourceRev,
      ]);
      _db.execute('UPDATE memory_messages SET text=?,source_rev=source_rev+1,event_seq=?,edited_at_utc=? WHERE id=?', [
        text,
        sequence,
        at,
        id,
      ]);
      _queueMessage(
        id,
        sequence,
        expectedSourceRev + 1,
        role: previous['role'] as String,
        scope: previous['scope'] as String,
        firstSeq: previous['first_seq'] as int,
        at: at,
      );
      if (previous['scope'] == 'real') _bumpControl();
      _advanceCursor();
      return Map<String, Object?>.from(_db.select('SELECT * FROM memory_messages WHERE id=?', [id]).single);
    });
  }

  List<MemoryRow> messages({String? sessionId, bool forModel = false, int? limit}) =>
      _readMemoryMessages(sessionId: sessionId, forModel: forModel, limit: limit);

  /// Model history is scoped before LIMIT. A missing installed character does
  /// not turn legacy assistant speech into the new character's own history.
  List<MemoryRow> modelMessages({String? sessionId, required String? characterId, int? limit}) => _readMemoryMessages(
    sessionId: sessionId,
    forModel: true,
    limit: limit,
    filterCharacter: true,
    characterId: characterId,
  );

  List<MemoryRow> _readMemoryMessages({
    String? sessionId,
    bool forModel = false,
    int? limit,
    bool filterCharacter = false,
    String? characterId,
  }) {
    if (limit != null && limit < 1) throw ArgumentError.value(limit, 'limit');
    final where = <String>[];
    final values = <Object?>[];
    if (sessionId != null) {
      where.add('m.session_id=?');
      values.add(sessionId);
    }
    if (filterCharacter) {
      _checkMemoryCharacter(characterId);
      if (characterId == null) {
        where.add("m.character_id IS NULL AND m.role='user'");
      } else {
        where.add('m.character_id=?');
        values.add(characterId);
      }
    }
    if (forModel) {
      where.add("m.scope='real' AND m.first_seq>?");
      values.add(archive['history_after_seq']);
    }
    final rows = _db.select(
      '''
      SELECT m.*, e.state AS extraction_state, e.reason AS extraction_reason, e.format_failures
      FROM memory_messages m JOIN memory_events e ON e.seq=m.event_seq
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY m.first_seq ${limit == null ? 'ASC' : 'DESC LIMIT ?'}
    ''',
      [...values, ?limit],
    );
    return [for (final row in limit == null ? rows : rows.reversed) Map<String, Object?>.from(row)];
  }

  void _queueMessage(
    String id,
    int sequence,
    int revision, {
    required String role,
    required String scope,
    required int firstSeq,
    required int at,
  }) {
    final reason = role != 'user' || scope != 'real'
        ? 'not_real_user'
        : firstSeq <= (archive['history_after_seq'] as int)
        ? 'history_cutoff'
        : null;
    _db.execute(
      '''
      INSERT INTO memory_events(seq,message_id,source_rev,state,reason,queued_at_ms) VALUES(?,?,?,?,?,?)
    ''',
      [sequence, id, revision, reason == null ? 'pending' : 'skipped', reason, at],
    );
  }

  /// Each support group is a complete proof. Removing one member withdraws the
  /// whole group before we ask whether another independent group still holds.
  void _removeSourceGroups(String messageId, int revision, {bool eraseUnsupported = false}) {
    // A previous edit may already have withdrawn every proof. This separate
    // identity relation only finds cards to check; it cannot prove any fact.
    final affected = <String>{
      if (eraseUnsupported)
        for (final row in _db.select('SELECT card_id FROM memory_card_cleanup_sources WHERE message_id=?', [messageId]))
          row['card_id'] as String,
    };
    for (final group in _db.select(
      '''
      SELECT DISTINCT card_id,support_group FROM memory_card_sources WHERE message_id=? AND source_rev=?
    ''',
      [messageId, revision],
    )) {
      affected.add(group['card_id'] as String);
      _withdrawSourceGroup(group['card_id'] as String, group['support_group'] as String);
    }
    _refreshSources(affected, eraseUnsupported: eraseUnsupported);
  }

  void _withdrawSourceGroup(String cardId, String groupId) {
    // A different AND member may have changed. Every member loses its old
    // proof role, even when this message's own revision remains unchanged.
    _db.execute(
      '''
      INSERT INTO memory_card_cleanup_sources(card_id,message_id,proof_withdrawn)
        SELECT card_id,message_id,1 FROM memory_card_sources WHERE card_id=? AND support_group=?
        ON CONFLICT(card_id,message_id) DO UPDATE SET proof_withdrawn=1
    ''',
      [cardId, groupId],
    );
    _db.execute('DELETE FROM memory_card_sources WHERE card_id=? AND support_group=?', [cardId, groupId]);
  }

  ({int basis, int sourceAt}) _currentParentSourceValues(MemoryRow card) {
    var basis = 0, sourceAt = 0;
    for (final parent in _db.select(
      '''
      SELECT p.id,p.current_basis_seq,p.source_at_ms FROM memory_card_references r
      JOIN memory_cards p ON p.id=r.parent_card_id AND p.row_rev=r.parent_row_rev
      WHERE r.card_id=? AND (p.character_id IS NULL OR p.character_id IS ?)
    ''',
      [card['id'], card['character_id']],
    )) {
      if (!_memoryReferencesCurrent(parent['id'] as String)) continue;
      basis = math.max(basis, parent['current_basis_seq'] as int? ?? 0);
      sourceAt = math.max(sourceAt, parent['source_at_ms'] as int);
    }
    return (basis: basis, sourceAt: sourceAt);
  }

  MemoryRow? _sourceRefreshValues(
    MemoryRow card,
    Iterable<MemoryRow> sources, {
    bool eraseUnsupported = false,
  }) {
    final manual = card['manual'] == 1;
    final supported = sources.isNotEmpty;
    if (eraseUnsupported && !manual && !supported) return null;
    final parents = !manual && supported ? _currentParentSourceValues(card) : (basis: 0, sourceAt: 0);
    final sourceAt = manual || !supported
        ? card['source_at_ms']
        : math.max(parents.sourceAt, sources.map((source) => source['at'] as int).reduce(math.max));
    // Cancellation is an explicit later user control, not an inferred tense
    // or the timestamp of a remaining older proof.
    final basis = manual || const ['cancelled', 'postponed'].contains(card['plan_state'])
        ? card['current_basis_seq']
        : supported
        ? math.max(parents.basis, sources.map((source) => source['first_seq'] as int).reduce(math.max))
        : null;
    final keywords = (jsonDecode(card['keywords'] as String) as List)
        .cast<String>()
        .where(
          (keyword) =>
              manual ||
              sources.any(
                (source) => normalizeMemoryText(source['text'] as String).contains(normalizeMemoryText(keyword)),
              ),
        )
        .toList();
    return {
      'eligible': manual || supported ? card['eligible'] : 0,
      'status': manual || supported ? card['status'] : 'withdrawn',
      'keywords': jsonEncode(keywords),
      'current_basis_seq': basis,
      'source_at_ms': sourceAt,
    };
  }

  void _applySourceRefresh(String id, MemoryRow values) => _db.execute(
    '''UPDATE memory_cards SET row_rev=row_rev+1,eligible=?,status=?,keywords=?,
      current_basis_seq=?,source_at_ms=?,updated_at_ms=? WHERE id=?''',
    [
      values['eligible'], values['status'], values['keywords'], values['current_basis_seq'],
      values['source_at_ms'], _checkedNow(), id,
    ],
  );

  void _refreshSources(Set<String> affected, {bool eraseUnsupported = false}) {
    for (final id in affected) {
      final card = _db.select('SELECT * FROM memory_cards WHERE id=?', [id]).single;
      final sources = _db.select(
        '''
        SELECT m.first_seq,m.text,COALESCE(m.edited_at_utc,m.said_at_utc) AS at FROM memory_card_sources s
        JOIN memory_messages m ON m.id=s.message_id AND m.source_rev=s.source_rev WHERE s.card_id=?
      ''',
        [id],
      );
      final values = _sourceRefreshValues(card, sources, eraseUnsupported: eraseUnsupported);
      if (values == null) {
        _deleteCards([id]);
      } else {
        _applySourceRefresh(id, values);
      }
    }
    if (affected.isNotEmpty) _bumpMemory();
  }

  /// Controls are applied synchronously before another request can be sent.
  /// A supplied message is a current real user action, not a model proposal.
  void applyControl({
    required List<String> topicIds,
    required String kind,
    String? controlMessageId,
    List<String>? targetCardIds,
    bool deleteChat = false,
  }) {
    if (!const ['forget', 'never', 'less', 'normal', 'cancel', 'postpone'].contains(kind) ||
        topicIds.isEmpty ||
        topicIds.any((id) => id.isEmpty) ||
        (deleteChat && kind != 'forget') ||
        (targetCardIds != null &&
            (!const ['forget', 'cancel', 'postpone'].contains(kind) ||
                targetCardIds.isEmpty ||
                targetCardIds.any((id) => id.isEmpty)))) {
      throw ArgumentError('Invalid companion control');
    }
    _transaction(() {
      final topics = topicIds.toSet().toList()..sort();
      final requestedTargets = targetCardIds == null ? null : (targetCardIds.toSet().toList()..sort());
      final action = {'control': kind, 'topic_ids': topics, 'delete_chat': deleteChat};
      final message = _controlMessage(controlMessageId);
      if (_appliedControl(message, action, requestedTargets)) return;
      for (final topic in topics) {
        if (_db.select('SELECT 1 FROM memory_topics WHERE id=?', [topic]).isEmpty) throw _conflict;
      }
      List<String>? targets = requestedTargets;
      if (message != null) {
        final control = parseMemoryControl(
          message['text'] as String,
          cards(includeInactive: true),
          topicControls: topicControls(),
        );
        final resolved = control == null ? <String>[] : (control['topic_ids'] as List<Object?>).cast<String>();
        resolved.sort();
        if (control == null ||
            control['ambiguous'] != false ||
            control['kind'] != kind ||
            control['delete_chat'] != deleteChat ||
            jsonEncode(resolved) != jsonEncode(topics)) {
          throw const DshRemoteException('companion/invalid-request', 'Control needs an explicit source and target', {
            'status': 400,
          });
        }
        if (kind == 'forget' || kind == 'cancel' || kind == 'postpone') {
          final actual = (control['target_card_ids'] as List<Object?>).cast<String>()..sort();
          if (requestedTargets != null && jsonEncode(actual) != jsonEncode(requestedTargets)) throw _conflict;
          targets = actual;
        }
      }
      for (final target in targets ?? const <String>[]) {
        final row = _db.select('SELECT topic_id FROM memory_cards WHERE id=?', [target]);
        if (row.isEmpty || !topics.contains(row.single['topic_id'])) throw _conflict;
      }
      final reason = jsonEncode({...action, 'target_card_ids': ?targets});
      final at = _checkedNow();
      final sequence = message?['first_seq'] as int? ?? _sequence();
      if (kind == 'forget') {
        if (targets == null) {
          _forgetTopics(topics, deleteChat: deleteChat);
        } else {
          _removeFactRelations(targets.toSet(), deleteChat: deleteChat);
        }
      } else if (kind == 'cancel' || kind == 'postpone') {
        final selected =
            targets ??
            [
              for (final row in _db.select('SELECT id,topic_id FROM memory_cards'))
                if (topics.contains(row['topic_id'])) row['id'] as String,
            ];
        for (final target in selected) {
          _db.execute(
            '''
            UPDATE memory_cards SET plan_state=?,followup=NULL,event_time=CASE WHEN ? THEN NULL ELSE event_time END,current_basis_seq=?,
              row_rev=row_rev+1,updated_at_ms=? WHERE id=?
              AND (current_basis_seq IS NULL OR current_basis_seq<=?)
          ''',
            [kind == 'cancel' ? 'cancelled' : 'postponed', kind == 'postpone' ? 1 : 0, sequence, at, target, sequence],
          );
        }
      } else {
        for (final topic in topics) {
          if (kind == 'never' || kind == 'less' || kind == 'normal') {
            _db.execute(
              '''
              UPDATE memory_cards SET maintenance_row_rev=0 WHERE topic_id=?
                AND EXISTS(SELECT 1 FROM memory_topics WHERE id=? AND mode!=?)
            ''',
              [topic, topic, kind],
            );
            // A source edit can withdraw the fact without retracting this
            // separate explicit control. Reaffirming/toggling less and never
            // retains its already-proved vocabulary; normal releases it.
            final anchors = kind == 'normal' ? <String>[] : _controlAnchors(topic);
            _db.execute('UPDATE memory_topics SET mode=?,control_anchors=? WHERE id=?', [
              kind,
              jsonEncode(anchors),
              topic,
            ]);
          }
          if (kind == 'never' || kind == 'less') {
            _db.execute(
              '''
              UPDATE memory_cards SET followup=NULL,row_rev=row_rev+1,updated_at_ms=?
              WHERE topic_id=? AND followup IS NOT NULL
            ''',
              [at, topic],
            );
          }
        }
      }
      _finishControlMessage(message, reason);
      _bumpMemory();
      _bumpControl(historyAfterSeq: kind == 'forget' || kind == 'never' ? sequence : null);
    });
  }

  /// Deleting the whole original message also removes every complete proof
  /// group that used it. A separate surviving proof or manual basis remains.
  void deleteMessage({required String id, required int expectedSourceRev}) => _transaction(() {
    final rows = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['source_rev'] != expectedSourceRev) throw _conflict;
    _checkedNow();
    final sequence = _sequence();
    _eraseMessage(rows.single);
    _bumpMemory();
    // Later assistant history may quote the deleted statement. This minimum
    // archive boundary discards that model history, not independent cards.
    _bumpControl(historyAfterSeq: sequence);
  });

  /// An explicit card selects a fact, not every fact sharing its expression
  /// topic. Known dependent work is removed; raw chat is retained for its owner.
  void deleteCard({required String id, required int expectedRowRev}) => _transaction(() {
    final rows = _db.select('SELECT * FROM memory_cards WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['row_rev'] != expectedRowRev) throw _conflict;
    _checkedNow();
    final sequence = _sequence();
    _removeFactRelations(
      {id},
      retainTopics: {for (final topic in topicControls()) topic['topic_id'] as String},
      domainSnapshot: _memoryDomainCards(rows.single['character_id'] as String?)
          .where((card) => card['character_id'] == rows.single['character_id'])
          .toList(),
    );
    _bumpMemory();
    _bumpControl(historyAfterSeq: sequence);
  });

  /// An explicit reality confirmation changes eligibility only. Neither the
  /// original statement date nor a new current-value order can be inferred.
  void confirmReality({required String id, required int expectedRowRev}) => _transaction(() {
    final rows = _db.select('SELECT * FROM memory_cards WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['row_rev'] != expectedRowRev) throw _conflict;
    final card = rows.single;
    final legacy = _db.select("SELECT 1 FROM memory_migrations WHERE local_card_id=? AND result='display_only'", [id]);
    if (legacy.isEmpty || card['scope'] != 'real' || card['status'] != 'current' || card['eligible'] != 0) {
      throw const DshRemoteException('companion/invalid-request', 'This card is not awaiting a reality confirmation', {
        'status': 400,
      });
    }
    _db.execute('UPDATE memory_cards SET eligible=1,row_rev=row_rev+1,updated_at_ms=? WHERE id=?', [_checkedNow(), id]);
    _db.execute("UPDATE memory_migrations SET result='imported' WHERE local_card_id=? AND result='display_only'", [id]);
    _sequence();
    _bumpMemory();
    _bumpControl();
  });

  /// Pinning neither confirms reality nor restates the current value. Avoid
  /// the legacy text editor's 512-scalar limit for a longer automatic card.
  void setPinned({required String id, required int expectedRowRev, required bool pinned}) => _transaction(() {
    final rows = _db.select('SELECT pinned,row_rev FROM memory_cards WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['row_rev'] != expectedRowRev) throw _conflict;
    final value = pinned ? 1 : 0;
    if (rows.single['pinned'] == value) return;
    _db.execute('UPDATE memory_cards SET pinned=?,row_rev=row_rev+1 WHERE id=?', [value, id]);
    _bumpMemory();
  });

  /// A stale native callback must not acknowledge a newer pending clear.
  void acknowledgeWidgetClear({required int controlRevision}) => _transaction(() {
    _db.execute('UPDATE memory_archive SET widget_clear_pending=0 WHERE singleton=1 AND control_revision=?', [
      controlRevision,
    ]);
  });

  /// An unresolved command is not a new fact or a format failure. The caller
  /// asks for its scope without silently putting it back in extraction.
  void finishUnresolvedControl({required String messageId, required int expectedSourceRev}) => _transaction(() {
    final message = _controlMessage(messageId)!;
    if (message['source_rev'] != expectedSourceRev) throw _conflict;
    if (_alreadyControlled(message, 'ambiguous_control')) return;
    final control = parseMemoryControl(
      message['text'] as String,
      cards(includeInactive: true),
      topicControls: topicControls(),
    );
    if (control == null || control['ambiguous'] != true) {
      throw const DshRemoteException('companion/invalid-request', 'This source is not an unresolved control', {
        'status': 400,
      });
    }
    _checkedNow();
    _finishControlMessage(message, 'ambiguous_control');
    _bumpControl(followupAfterSeq: message['first_seq'] as int, followupCloseReason: 'unresolved_control');
  });

  void correctFromMessage({
    required String cardId,
    required int expectedRowRev,
    required String messageId,
    required int expectedSourceRev,
    required String text,
  }) {
    validateMemoryCardText(text);
    _transaction(() {
      final message = _controlMessage(messageId)!;
      if (message['source_rev'] != expectedSourceRev) throw _conflict;
      final reason = jsonEncode({'control': 'correct', 'target_card_id': cardId});
      if (_alreadyControlled(message, reason)) {
        final current = _db.select('SELECT text FROM memory_cards WHERE id=?', [cardId]);
        if (current.isEmpty || current.single['text'] != text) throw _conflict;
        return;
      }
      final rows = _db.select('SELECT * FROM memory_cards WHERE id=?', [cardId]);
      if (rows.isEmpty || rows.single['row_rev'] != expectedRowRev) throw _conflict;
      final previous = rows.single;
      final control = parseMemoryControl(message['text'] as String, cards());
      if (control == null ||
          control['kind'] != 'correct' ||
          control['ambiguous'] != false ||
          control['target_card_id'] != cardId ||
          control['replacement_text'] != text ||
          !(message['text'] as String).contains(text)) {
        throw const DshRemoteException(
          'companion/invalid-request',
          'Correction needs an explicit current source and target',
          {'status': 400},
        );
      }
      final basis = message['first_seq'] as int;
      if (!canApplyMemoryCurrentValue(
        proposedBasisSeq: basis,
        currentBasisSeq: previous['current_basis_seq'] as int?,
      )) {
        throw _conflict;
      }
      final at = _checkedNow();
      final keywords = (jsonDecode(previous['keywords'] as String) as List)
          .cast<String>()
          .where((word) => normalizeMemoryText(message['text'] as String).contains(normalizeMemoryText(word)))
          .toList();
      // Resolve dependence against the old value and old proof snapshot before
      // writing the correction. A shared expression topic is not dependence.
      _removeFactRelations({cardId}, retainTargetId: cardId);
      final changedText = previous['text'] != text;
      if (changedText) {
        _db.execute('DELETE FROM memory_card_sources WHERE card_id=?', [cardId]);
        _db.execute('DELETE FROM memory_card_cleanup_sources WHERE card_id=?', [cardId]);
      } else {
        for (final group in _db.select('SELECT DISTINCT support_group FROM memory_card_sources WHERE card_id=?', [
          cardId,
        ])) {
          _withdrawSourceGroup(cardId, group['support_group'] as String);
        }
      }
      _db.execute(
        '''
        UPDATE memory_cards SET text=?,keywords=?,row_rev=row_rev+1,scope='real',eligible=1,status='current',manual=0,
          current_basis_seq=?,source_at_ms=?,event_time=NULL,followup=NULL,plan_state=NULL,expires_at_ms=NULL,
          updated_at_ms=?,cleanup_history_complete=? WHERE id=?
      ''',
        [
          text,
          jsonEncode(keywords),
          basis,
          message['edited_at_utc'] ?? message['said_at_utc'],
          at,
          changedText ? 1 : previous['cleanup_history_complete'],
          cardId,
        ],
      );
      _db.execute(
        'INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)',
        [cardId, _createId(), messageId, expectedSourceRev, message['text']],
      );
      _db.execute('INSERT OR IGNORE INTO memory_card_cleanup_sources(card_id,message_id) VALUES(?,?)', [
        cardId,
        messageId,
      ]);
      _db.execute("UPDATE memory_migrations SET result='imported' WHERE local_card_id=? AND result='display_only'", [
        cardId,
      ]);
      _finishControlMessage(message, reason);
      _bumpMemory();
      _bumpControl();
    });
  }

  Row? _controlMessage(String? id) {
    if (id == null) return null;
    final rows = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['role'] != 'user' || rows.single['scope'] != 'real') throw _conflict;
    return rows.single;
  }

  bool _appliedControl(Row? message, Map<String, Object?> action, List<String>? requestedTargets) {
    if (message == null) return false;
    final event = _db.select('SELECT state,reason FROM memory_events WHERE seq=?', [message['event_seq']]).single;
    if (event['state'] == 'done' && event['reason'] is String) {
      Object? decoded;
      try {
        decoded = jsonDecode(event['reason'] as String);
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map<String, Object?> && decoded.containsKey('control')) {
        final applied = Map<String, Object?>.from(decoded);
        final targets = applied.remove('target_card_ids');
        if (jsonEncode(applied) == jsonEncode(action) &&
            (requestedTargets == null || jsonEncode(targets) == jsonEncode(requestedTargets))) {
          return true;
        }
        throw _conflict;
      }
    }
    if ((message['first_seq'] as int) <= (archive['history_after_seq'] as int)) throw _conflict;
    return false;
  }

  bool _alreadyControlled(Row? message, String reason) {
    if (message == null) return false;
    final event = _db.select('SELECT state,reason FROM memory_events WHERE seq=?', [message['event_seq']]).single;
    if (event['state'] == 'done' && event['reason'] == reason) return true;
    if ((message['first_seq'] as int) <= (archive['history_after_seq'] as int)) throw _conflict;
    return false;
  }

  void _finishControlMessage(Row? message, String reason) {
    if (message == null) return;
    _db.execute("UPDATE memory_events SET state='done',reason=? WHERE seq=?", [reason, message['event_seq']]);
  }

  void _deleteCards(Iterable<String> ids, {Set<String> retainTopics = const {}}) {
    for (final id in ids) {
      final rows = _db.select('SELECT topic_id FROM memory_cards WHERE id=?', [id]);
      if (rows.isEmpty) continue;
      _db.execute("UPDATE memory_migrations SET result='forgotten' WHERE local_card_id=?", [id]);
      _forgetNoticeCard(id);
      _db.execute('DELETE FROM memory_cards WHERE id=?', [id]);
      if (!retainTopics.contains(rows.single['topic_id'])) {
        _db.execute('DELETE FROM memory_topics WHERE id=? AND NOT EXISTS(SELECT 1 FROM memory_cards WHERE topic_id=?)', [
          rows.single['topic_id'],
          rows.single['topic_id'],
        ]);
      }
    }
  }

  void _eraseMessage(MemoryRow message) {
    _removeSourceGroups(message['id'] as String, message['source_rev'] as int, eraseUnsupported: true);
    _db.execute('INSERT INTO memory_deleted_messages(id,first_seq) VALUES(?,?)', [message['id'], message['first_seq']]);
    _db.execute('DELETE FROM memory_messages WHERE id=?', [message['id']]);
  }

  void _forgetTopics(List<String> topics, {required bool deleteChat}) {
    _removeFactRelations({
      for (final row in _db.select('SELECT id,topic_id FROM memory_cards'))
        if (topics.contains(row['topic_id'])) row['id'] as String,
    }, deleteChat: deleteChat);
  }

  Map<String, List<MemoryRow>> _supportGroups(MemoryRow card) {
    final groups = <String, List<MemoryRow>>{};
    for (final proof in (card['evidence'] as List<Object?>).cast<MemoryRow>()) {
      (groups[proof['support_group'] as String] ??= []).add(proof);
    }
    return groups;
  }

  bool _containsCardText(String text, MemoryRow card) {
    final original = normalizeMemoryText(card['text'] as String);
    return _anchorWord(original) && _containsAnchor(normalizeMemoryText(text), original);
  }

  Set<String> _removeFactRelations(
    Set<String> roots, {
    String? retainTargetId,
    Set<String> retainTopics = const {},
    bool deleteChat = false,
    void Function(Set<String> changedCardIds)? beforeWrite,
    List<MemoryRow>? domainSnapshot,
  }) {
    final plan = _planFactRelations(roots, deleteChat: deleteChat, domainSnapshot: domainSnapshot);
    beforeWrite?.call(plan.cards);
    _applyFactRemoval(plan, retainIds: {?retainTargetId}, retainTopics: retainTopics);
    return plan.cards;
  }

  _MemoryRemovalPlan _planFactRelations(Set<String> roots, {bool deleteChat = false, List<MemoryRow>? domainSnapshot}) {
    // Decide the complete deletion before any write, including cards that
    // lose their last proof through an explicitly selected raw-message deletion.
    final snapshot = domainSnapshot ?? cards(includeInactive: true);
    // Losing a proof may remove another fact, but does not authorize forgetting
    // that fact's independent originals. Keep semantic targets separate from
    // those source-removal effects, using the unchanged literal-only plan.
    final literalTargets = deleteChat ? _planFactRelations(roots, domainSnapshot: snapshot).cards : null;
    final groups = {for (final card in snapshot) card['id'] as String: _supportGroups(card)};
    final ending = RegExp(r'[。.!！?？]+$');
    final clauseBreak = RegExp(r'[，,。.;；\r\n]+');
    bool containsBody(MemoryRow card, MemoryRow old) {
      // Equal words do not join independent external events or a later fact
      // that the user supplied in their own chat. Notice references are not
      // allowed, so these roots have only their explicit source identity.
      if (card['collection'] == 'recent' || old['collection'] == 'recent') return false;
      final text = card['text'] as String;
      if (_containsCardText(text, old)) return true;
      final original = normalizeMemoryText(old['text'] as String);
      final clause = normalizeMemoryText(original.replaceFirst(ending, ''));
      return clause != original &&
          clause.isNotEmpty &&
          text.split(clauseBreak).any((part) => normalizeMemoryText(part) == clause);
    }

    final origins = <String, List<MemoryRow>>{};
    if (deleteChat) {
      for (final row in _db.select('SELECT card_id,message_id,proof_withdrawn FROM memory_card_cleanup_sources')) {
        (origins[row['card_id'] as String] ??= []).add(Map<String, Object?>.from(row));
      }
    }
    final rootCards = snapshot.where((card) => roots.contains(card['id'])).toList();
    // Root originals are authorized before any derived history is checked,
    // regardless of the cards' UUID order.
    final planningOrder = [...rootCards, ...snapshot.where((card) => !roots.contains(card['id']))];
    final deleting = {...roots};
    final planned = <String>{};
    final rawSources = <String>{};
    var expanded = true;
    while (expanded) {
      final before = deleting.length + rawSources.length;
      final known = snapshot.where((card) => (literalTargets ?? deleting).contains(card['id'])).toList();
      for (final card in snapshot) {
        if (card['scope'] != 'real' || deleting.contains(card['id'])) {
          continue;
        }
        // A shared quote may support independent facts. Only the card body
        // establishes this literal dependency; raw-source checks stay separate.
        if (known.any((old) => containsBody(card, old))) {
          deleting.add(card['id'] as String);
        }
      }
      for (final card in planningOrder) {
        final id = card['id'] as String;
        if (!deleting.contains(id) || !planned.add(id)) {
          continue;
        }
        if (deleteChat) {
          if (card['cleanup_history_complete'] != 1) {
            throw _cleanupUnknown;
          }
          final history = origins[id] ?? const <MemoryRow>[];
          if (roots.contains(id)) {
            rawSources.addAll(history.map((row) => row['message_id'] as String));
          } else {
            final currentSources = {
              for (final proof in (card['evidence'] as List<Object?>).cast<MemoryRow>()) proof['message_id'],
            };
            for (final origin in history) {
              if (rawSources.contains(origin['message_id'])) {
                continue;
              }
              // Read the pre-operation role. This operation's planned group
              // withdrawal must not make a fresh independent AND member unknown.
              final source = _db.select('SELECT text FROM memory_messages WHERE id=?', [origin['message_id']]).single;
              if (rootCards.any((root) => _containsCardText(source['text'] as String, root))) {
                rawSources.add(origin['message_id'] as String);
              } else if (origin['proof_withdrawn'] == 1 || !currentSources.contains(origin['message_id'])) {
                throw _cleanupUnknown;
              }
            }
          }
        }
        for (final group in groups[id]!.values) {
          if (!deleteChat) {
            continue;
          }
          final sameMessage = group.every((proof) => proof['message_id'] == group.first['message_id']);
          for (final proof in group) {
            // A derived multi-message AND card does not authorize deleting its
            // independent Y original merely because its X member is removed.
            if (roots.contains(id) ||
                sameMessage ||
                rootCards.any((root) => _containsCardText(proof['quote'] as String, root))) {
              rawSources.add(proof['message_id'] as String);
            }
          }
        }
      }
      for (final card in snapshot) {
        final id = card['id'] as String;
        if (deleting.contains(id)) {
          continue;
        }
        final current = groups[id]!;
        var removed = 0;
        for (final group in current.entries) {
          if (group.value.any((proof) => rawSources.contains(proof['message_id']))) {
            removed++;
          }
        }
        final touchedRaw = (origins[id] ?? const <MemoryRow>[]).any(
          (origin) => rawSources.contains(origin['message_id']),
        );
        if (card['manual'] != true && removed == current.length && (removed > 0 || touchedRaw)) {
          deleting.add(id);
        }
      }
      // Both sets only grow over the finite card/message snapshot. A surviving
      // non-manual card has a full group outside all planned removals.
      expanded = before != deleting.length + rawSources.length;
    }
    return _MemoryRemovalPlan(deleting, rawSources);
  }

  void _applyFactRemoval(
    _MemoryRemovalPlan plan, {
    Set<String> retainIds = const {},
    Set<String> retainTopics = const {},
  }) {
    _deleteCards(plan.cards.where((id) => !retainIds.contains(id)), retainTopics: retainTopics);
    for (final id in plan.rawSources) {
      final rows = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
      if (rows.isEmpty) {
        continue;
      }
      _eraseMessage(rows.single);
    }
  }

  void _bumpControl({int? historyAfterSeq, int? followupAfterSeq, String followupCloseReason = 'control_changed'}) {
    _db.execute(
      '''
      UPDATE memory_archive SET control_revision=control_revision+1,widget_clear_pending=1,
        history_after_seq=MAX(history_after_seq,?),followup_after_seq=MAX(followup_after_seq,?) WHERE singleton=1
    ''',
      [historyAfterSeq ?? 0, followupAfterSeq ?? 0],
    );
    for (final claim in _db.select('SELECT id FROM memory_batches')) {
      _dropBatch(claim['id'] as String);
    }
    _db.execute('DELETE FROM memory_merge_batches');
    if (historyAfterSeq != null) {
      _db.execute(
        '''
        UPDATE memory_events SET state='skipped',reason='history_cutoff',batch_id=NULL
        WHERE state='pending' AND message_id IN (SELECT id FROM memory_messages WHERE first_seq<=?)
      ''',
        [archive['history_after_seq']],
      );
    }
    _advanceCursor();
    // Every old presentation cache is fenced immediately. Independent pending
    // invitations may later be rebuilt from current sources under the new
    // control, but an unresolved command and consumed opportunities stay shut.
    _db.execute(
      '''
      UPDATE memory_followups SET row_rev=row_rev+1,invitation='',support_quote=NULL,wait_subject=NULL,local_line=NULL,
        state=CASE WHEN state IN ('waiting','pending','reserved') THEN 'closed' ELSE state END,
        reason=CASE WHEN reason IN ('unresolved_control','expired','already_presented') THEN reason ELSE ? END
      WHERE agent_origin=0
    ''',
      [followupCloseReason],
    );
    // Structured invitations keep their source/card identity. Old displayed
    // tickets are fenced, and eligibility is rechecked before another reserve.
    _db.execute('''
      UPDATE memory_followups SET control_revision=(SELECT control_revision FROM memory_archive),
        row_rev=row_rev+1,local_line=NULL WHERE agent_origin=1 AND state IN ('pending','reserved','asked')
    ''');
  }

  MemoryBatch? nextBatch({bool forceTail = false, required int Function(String) estimateTokens}) =>
      _nextBatch(forceTail: forceTail, estimateTokens: estimateTokens);

  MemoryBatch? _nextBatch({
    bool forceTail = false,
    required int Function(String) estimateTokens,
    int Function(List<MemoryRow> sources, List<MemoryRow> cards)? estimateInputTokens,
  }) => _transaction(() {
    final at = _checkedNow();
    for (final claim in _db.select('SELECT * FROM memory_batches')) {
      final restored = _restoreBatch(claim, at);
      if (restored != null &&
          (estimateInputTokens == null ||
              estimateInputTokens(restored.sources, restored.existing) <= memoryBatchInputTokens)) {
        _db.execute("UPDATE memory_batches SET state='claimed' WHERE id=?", [restored.id]);
        return restored;
      }
      _dropBatch(claim['id'] as String);
    }
    _db.execute(
      '''
      UPDATE memory_events SET state='skipped',reason='history_cutoff',batch_id=NULL
      WHERE state='pending' AND message_id IN (SELECT id FROM memory_messages WHERE first_seq<=?)
    ''',
      [archive['history_after_seq']],
    );
    _advanceCursor();
    final pending = _db.select('''
      SELECT m.*,e.queued_at_ms,e.format_failures FROM memory_events e JOIN memory_messages m
        ON m.id=e.message_id AND m.source_rev=e.source_rev AND m.event_seq=e.seq
      WHERE e.state='pending' ORDER BY e.seq
    ''');
    if (pending.isEmpty) return null;
    final sourceTokens = pending.fold<int>(0, (sum, row) => sum + estimateTokens(row['text'] as String));
    final latest = pending.map((row) => row['queued_at_ms'] as int).reduce(math.max);
    if (!forceTail &&
        pending.first['format_failures'] == 0 &&
        pending.length < 8 &&
        sourceTokens < 1500 &&
        at - latest < 120000) {
      return null;
    }
    final id = _createId();
    final control = archive['control_revision'] as int;
    final sources = <MemoryRow>[];
    final existing = <MemoryRow>[];
    int size(List<MemoryRow> input, List<MemoryRow> cards) =>
        estimateInputTokens?.call(input, cards) ??
        estimateTokens(
          '$companionMemoryExtractionPrompt\n${jsonEncode(extractionInput(
            MemoryBatch(id: id, controlRevision: control, sources: input, existing: cards),
            processedAtUtc: at,
          ))}',
        );
    for (final row in pending) {
      // An edited/stale batch can leave an old retry ahead of fresh events.
      // Its final permitted attempt must not consume a fresh event's retry.
      if (sources.length == memoryBatchMessageLimit || row['format_failures'] != pending.first['format_failures']) {
        break;
      }
      final source = Map<String, Object?>.from(row)
        ..remove('queued_at_ms')
        ..remove('format_failures');
      if (size([source], const []) > memoryBatchInputTokens) {
        _db.execute("UPDATE memory_events SET state='skipped',reason='input_too_long' WHERE seq=?", [
          source['event_seq'],
        ]);
        continue;
      }
      if (size([...sources, source], const []) > memoryBatchInputTokens) break;
      sources.add(source);
    }
    _advanceCursor();
    if (sources.isEmpty) return null;
    final candidates = cards().where((card) => _currentCard(card, at)).toList()
      ..sort((a, b) {
        final recent = (b['source_at_ms'] as int).compareTo(a['source_at_ms'] as int);
        return recent == 0 ? (a['id'] as String).compareTo(b['id'] as String) : recent;
      });
    for (final card in candidates) {
      if (size(sources, [...existing, card]) <= memoryBatchInputTokens) existing.add(card);
    }
    _db.execute('INSERT INTO memory_batches(id,control_revision,existing_revisions,state) VALUES(?,?,?,\'claimed\')', [
      id,
      control,
      jsonEncode({for (final card in existing) card['id'] as String: card['row_rev']}),
    ]);
    for (final source in sources) {
      _db.execute('UPDATE memory_events SET batch_id=? WHERE seq=?', [id, source['event_seq']]);
    }
    return MemoryBatch(id: id, controlRevision: control, sources: sources, existing: existing);
  });

  List<MemoryRow>? _currentBatchSources(String id) {
    final rows = _db.select(
      '''
      SELECT m.*,e.state AS claim_state,e.source_rev AS claim_rev,e.seq AS claim_seq
      FROM memory_events e JOIN memory_messages m ON m.id=e.message_id WHERE e.batch_id=? ORDER BY e.seq
    ''',
      [id],
    );
    if (rows.isEmpty) return null;
    final cutoff = archive['history_after_seq'] as int;
    final sources = <MemoryRow>[];
    for (final row in rows) {
      if (row['claim_state'] != 'pending' ||
          row['claim_rev'] != row['source_rev'] ||
          row['claim_seq'] != row['event_seq'] ||
          row['role'] != 'user' ||
          row['scope'] != 'real' ||
          (row['first_seq'] as int) <= cutoff) {
        return null;
      }
      sources.add(
        Map<String, Object?>.from(row)
          ..remove('claim_state')
          ..remove('claim_rev')
          ..remove('claim_seq'),
      );
    }
    return sources;
  }

  // A cancelled plan is retained only as a local ordering anchor. Its old
  // future wording is not a current item in 09s existing or model selection.
  bool _currentCard(MemoryRow card, int at) =>
      _currentAnchor(card, at) && !const ['cancelled', 'postponed'].contains(card['plan_state']);

  bool _currentAnchor(MemoryRow card, int at) =>
      card['collection'] != 'recent' &&
      card['scope'] == 'real' &&
      card['eligible'] == true &&
      card['status'] == 'current' &&
      (card['expires_at_ms'] == null || (card['expires_at_ms'] as int) > at);

  MemoryBatch? _restoreBatch(Row claim, int at) {
    if (claim['control_revision'] != archive['control_revision']) return null;
    final sources = _currentBatchSources(claim['id'] as String);
    if (sources == null) return null;
    final revisions = jsonDecode(claim['existing_revisions'] as String) as Map<String, Object?>;
    final existing = <MemoryRow>[];
    for (final entry in revisions.entries) {
      final rows = _db.select(
        '''
        SELECT c.*,t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id WHERE c.id=?
      ''',
        [entry.key],
      );
      if (rows.isEmpty || rows.single['row_rev'] != entry.value) return null;
      final card = _card(rows.single);
      if (!_currentCard(card, at)) return null;
      existing.add(card);
    }
    return MemoryBatch(
      id: claim['id'] as String,
      controlRevision: claim['control_revision'] as int,
      sources: sources,
      existing: existing,
    );
  }

  bool isBatchCurrent(MemoryBatch batch) {
    final claims = _db.select("SELECT * FROM memory_batches WHERE id=? AND state='claimed'", [batch.id]);
    if (claims.isEmpty) return false;
    if (claims.single['control_revision'] != batch.controlRevision ||
        archive['control_revision'] != batch.controlRevision) {
      return false;
    }
    final sources = _currentBatchSources(batch.id);
    if (sources == null || sources.length != batch.sources.length) return false;
    for (var i = 0; i < sources.length; i++) {
      final expected = batch.sources[i];
      final actual = sources[i];
      if (expected['id'] != actual['id'] ||
          expected['source_rev'] != actual['source_rev'] ||
          expected['event_seq'] != actual['event_seq']) {
        return false;
      }
    }
    return true;
  }

  /// The proposal has already passed parseExtractionProposal. This transaction
  /// checks the mutable identities and order, then commits the whole coverage.
  bool commitExtraction(MemoryBatch batch, MemoryRow proposal) => _transaction(() {
    if (!isBatchCurrent(batch)) return false;
    final at = _checkedNow();
    final sources = {for (final source in batch.sources) source['id'] as String: source};
    final operations = (proposal['operations'] as List<Object?>).cast<MemoryRow>();
    for (final operation in operations.where((op) => op['op'] == 'replace')) {
      final rows = _db.select('SELECT * FROM memory_cards WHERE id=?', [operation['target_id']]);
      if (rows.isEmpty ||
          rows.single['row_rev'] != operation['expected_row_rev'] ||
          !_currentCard(_card(rows.single), at)) {
        return false;
      }
    }
    final skipped = <MemoryRow>[];
    var changed = false;
    for (var index = 0; index < operations.length; index++) {
      final operation = operations[index];
      final evidence = (operation['evidence'] as List<Object?>).cast<MemoryRow>();
      final referenced = [for (final reference in evidence) sources[reference['message_id']]!];
      final basis = referenced.map((source) => source['first_seq'] as int).reduce(math.max);
      final sourceAt = referenced
          .map((source) => (source['edited_at_utc'] ?? source['said_at_utc']) as int)
          .reduce(math.max);
      final target = operation['op'] == 'replace'
          ? _db.select('SELECT * FROM memory_cards WHERE id=?', [operation['target_id']]).single
          : null;
      if (target != null &&
          !canApplyMemoryCurrentValue(proposedBasisSeq: basis, currentBasisSeq: target['current_basis_seq'] as int?)) {
        skipped.add({'operation': index, 'reason': 'older_than_current', 'card_id': target['id']});
        continue;
      }
      if (target == null) {
        final collision = _possibleCurrentConflict(operation, basis, at);
        if (collision != null) {
          skipped.add({'operation': index, 'reason': 'possible_current_conflict', 'card_id': collision});
          continue;
        }
      }
      final controlledTopics = target == null ? _controlledTopics(operation) : const <String>[];
      if (controlledTopics.length > 1) {
        skipped.add({'operation': index, 'reason': 'ambiguous_controlled_topic'});
        continue;
      }
      final id = target?['id'] ?? _createId();
      final topic = target?['topic_id'] ?? (controlledTopics.isEmpty ? _createId() : controlledTopics.single);
      if (target == null && controlledTopics.isEmpty) _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
      final mode = _db.select('SELECT mode FROM memory_topics WHERE id=?', [topic]).single['mode'];
      _db.execute(
        '''
        INSERT INTO memory_cards(id,row_rev,kind,text,keywords,pinned,scope,eligible,status,manual,
          topic_id,current_basis_seq,source_at_ms,event_time,followup,created_at_ms,updated_at_ms,cleanup_history_complete)
        VALUES(?,?,?,?,?,?,'real',1,?,0,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET row_rev=excluded.row_rev,kind=excluded.kind,text=excluded.text,
          keywords=excluded.keywords,eligible=1,status=excluded.status,manual=0,
          current_basis_seq=excluded.current_basis_seq,source_at_ms=excluded.source_at_ms,
          event_time=excluded.event_time,followup=excluded.followup,plan_state=NULL,
          updated_at_ms=excluded.updated_at_ms,expires_at_ms=NULL,cleanup_history_complete=excluded.cleanup_history_complete
      ''',
        [
          id,
          target == null ? 1 : (target['row_rev'] as int) + 1,
          operation['kind'],
          operation['text'],
          jsonEncode(operation['keywords']),
          target?['pinned'] ?? 0,
          'current',
          topic,
          basis,
          sourceAt,
          operation['event_time'] == null ? null : jsonEncode(operation['event_time']),
          operation['followup'] == null || mode != 'normal' ? null : jsonEncode(operation['followup']),
          target?['created_at_ms'] ?? at,
          at,
          target != null && target['text'] == operation['text'] ? target['cleanup_history_complete'] : 1,
        ],
      );
      if (target != null) {
        if (target['text'] != operation['text']) {
          _db.execute('DELETE FROM memory_card_sources WHERE card_id=?', [id]);
          _db.execute('DELETE FROM memory_card_cleanup_sources WHERE card_id=?', [id]);
        } else {
          for (final group in _db.select('SELECT DISTINCT support_group FROM memory_card_sources WHERE card_id=?', [
            id,
          ])) {
            _withdrawSourceGroup(id as String, group['support_group'] as String);
          }
        }
      }
      final group = _createId();
      for (final reference in evidence) {
        final source = sources[reference['message_id']]!;
        _db.execute(
          '''
          INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)
          ON CONFLICT(card_id,support_group,message_id,source_rev,quote) DO NOTHING
        ''',
          [id, group, source['id'], source['source_rev'], reference['quote']],
        );
        _db.execute('INSERT OR IGNORE INTO memory_card_cleanup_sources(card_id,message_id) VALUES(?,?)', [
          id,
          source['id'],
        ]);
      }
      changed = true;
    }
    _db.execute("UPDATE memory_events SET state='done',reason=? WHERE batch_id=? AND state='pending'", [
      skipped.isEmpty ? null : jsonEncode({'skipped_operations': skipped}),
      batch.id,
    ]);
    _db.execute('DELETE FROM memory_batches WHERE id=?', [batch.id]);
    if (changed) _bumpMemory();
    _advanceCursor();
    return true;
  });

  /// This is a finite literal collision check, not a semantic topic proof.
  /// Only this operation's evidence is searched, not unrelated parts of a
  /// composite source message, and missing proposed keywords cannot bypass it.
  String? _possibleCurrentConflict(MemoryRow operation, int basis, int at) {
    final text = _operationText(operation);
    for (final card in cards()) {
      if (!_currentAnchor(card, at) ||
          canApplyMemoryCurrentValue(proposedBasisSeq: basis, currentBasisSeq: card['current_basis_seq'] as int?)) {
        continue;
      }
      if (_supportedWords(card).any((word) => _containsAnchor(text, word))) return card['id'] as String;
    }
    return null;
  }

  String _operationText(MemoryRow operation) {
    final evidence = (operation['evidence'] as List<Object?>).cast<MemoryRow>();
    return normalizeMemoryText('${operation['text']}\n${evidence.map((e) => e['quote']).join('\n')}');
  }

  List<String> _supportedWords(MemoryRow card) {
    final support = card['manual'] == true
        ? [card['text'] as String]
        : [
            for (final source in _db.select(
              '''
        SELECT m.text FROM memory_card_sources s JOIN memory_messages m
          ON m.id=s.message_id AND m.source_rev=s.source_rev WHERE s.card_id=?
      ''',
              [card['id']],
            ))
              source['text'] as String,
          ];
    return (card['keywords'] as List<String>)
        .map(normalizeMemoryText)
        .where((word) => _anchorWord(word) && support.any((source) => normalizeMemoryText(source).contains(word)))
        .toSet()
        .toList();
  }

  List<String> _controlAnchors(String topic) {
    final saved = _db.select('SELECT control_anchors FROM memory_topics WHERE id=?', [topic]).single;
    return {
      ...(jsonDecode(saved['control_anchors'] as String) as List<Object?>).cast<String>(),
      for (final card in cards())
        if (card['topic_id'] == topic && card['scope'] == 'real' && card['eligible'] == true) ..._supportedWords(card),
    }.toList()..sort();
  }

  /// Only for explicit topic controls; these rows are not memory facts.
  List<MemoryRow> topicControls() => [
    for (final row in _db.select(
      "SELECT id,mode,control_anchors FROM memory_topics WHERE mode IN ('less','never') ORDER BY id",
    ))
      {
        'topic_id': row['id'],
        'mode': row['mode'],
        'anchors': (jsonDecode(row['control_anchors'] as String) as List<Object?>).cast<String>(),
      },
  ];

  /// A new card cannot turn one uniquely matched controlled topic back to
  /// normal. These are the literal anchors of an explicit control, not proof
  /// that a withdrawn fact is still true. Only this operation's own evidence
  /// is searched; this is not a general subject/topic classifier.
  List<String> _controlledTopics(MemoryRow operation, {Iterable<MemoryRow>? controls}) {
    final text = _operationText(operation);
    return {
      for (final topic in controls ?? topicControls())
        if ((topic['anchors'] as List<String>).any((word) => _containsAnchor(text, word))) topic['topic_id'] as String,
    }.toList()..sort();
  }

  // Match the final card body, not other source clauses or another role's controls.
  List<String> _bodyControlledTopics(String text, {required String? characterId}) => _controlledTopics(
    {'text': text, 'evidence': const <MemoryRow>[]},
    controls: [
      for (final row in _db.select(
        "SELECT id,control_anchors FROM memory_topics WHERE character_id IS ? AND mode IN ('less','never')",
        [characterId],
      ))
        {
          'topic_id': row['id'],
          'anchors': (jsonDecode(row['control_anchors'] as String) as List<Object?>).cast<String>(),
        },
    ],
  );

  void recordInvalidProposal(MemoryBatch batch) => _transaction(() {
    if (!isBatchCurrent(batch)) return;
    _db.execute(
      '''
      UPDATE memory_events SET format_failures=format_failures+1,
        state=CASE WHEN format_failures>=1 THEN 'skipped' ELSE 'pending' END,
        reason=CASE WHEN format_failures>=1 THEN 'invalid_proposal' ELSE 'retry_invalid_proposal' END
      WHERE batch_id=? AND state='pending'
    ''',
      [batch.id],
    );
    if (_db.select("SELECT 1 FROM memory_events WHERE batch_id=? AND state='pending' LIMIT 1", [batch.id]).isEmpty) {
      _db.execute('DELETE FROM memory_batches WHERE id=?', [batch.id]);
    } else {
      _db.execute("UPDATE memory_batches SET state='ready' WHERE id=?", [batch.id]);
    }
    _advanceCursor();
  });

  void releaseBatch(MemoryBatch batch, {required String reason}) => _transaction(() {
    final claims = _db.select('SELECT state FROM memory_batches WHERE id=?', [batch.id]);
    if (claims.isEmpty || claims.single['state'] == 'ready') return;
    if (!isBatchCurrent(batch)) {
      _dropBatch(batch.id);
      return;
    }
    _db.execute("UPDATE memory_events SET reason=? WHERE batch_id=? AND state='pending'", [reason, batch.id]);
    _db.execute("UPDATE memory_batches SET state='ready' WHERE id=?", [batch.id]);
  });

  void _dropBatch(String id) {
    _db.execute('UPDATE memory_events SET batch_id=NULL WHERE batch_id=?', [id]);
    _db.execute('DELETE FROM memory_batches WHERE id=?', [id]);
  }

  void _advanceCursor() {
    var cursor = archive['cursor_seq'] as int;
    final statement = _db.prepare('SELECT seq,state FROM memory_events WHERE seq>? ORDER BY seq');
    try {
      final events = statement.selectCursor([cursor]);
      while (events.moveNext()) {
        final event = events.current;
        if (event['state'] == 'pending') break;
        cursor = event['seq'] as int;
      }
    } finally {
      statement.close();
    }
    _db.execute('UPDATE memory_archive SET cursor_seq=? WHERE singleton=1', [cursor]);
  }

  /// Only cards that share all five exact-merge fields with another card can
  /// pair, so evidence is loaded once, for those alone. Notice summaries
  /// (`recent`) never merge, so they are not materialized at all.
  List<MemoryRow> _exactMergeCards() {
    Record key(MemoryRow card) =>
        (card['collection'], card['character_id'], card['local_day'], card['day_zone_id'], card['text']);
    final cards = [
      for (final row in _cardRows(false))
        if (row['collection'] != 'recent') _card(row, includeEvidence: false),
    ];
    final counts = <Record, int>{};
    for (final card in cards) {
      counts.update(key(card), (n) => n + 1, ifAbsent: () => 1);
    }
    final paired = [
      for (final card in cards)
        if (counts[key(card)]! > 1) card,
    ];
    _loadRetrievalEvidence(paired);
    return paired;
  }

  /// One actual opportunity can merge one locally certain pair without a
  /// model/key or a model claim. It never rewrites a captured live scope.
  int mergeAgentExactDuplicates() => _transaction(() {
    if (_db.select("SELECT * FROM memory_agent_maintenance_claims WHERE state='claimed'").any(_agentParentCurrent)) {
      return 0;
    }
    final at = _checkedNow();
    final rows = [
      for (final row in _mergeRows(at, _exactMergeCards()))
        if (_memoryReferencesCurrent(row['id'] as String)) row,
    ];
    final proofs = {for (final row in rows) row['id']: _supportGroups(row).values.map(_mergeProofKey).toSet()};
    for (var i = 0; i < rows.length; i++) {
      final target = rows[i];
      for (var j = i + 1; j < rows.length; j++) {
        final from = rows[j];
        if (target['collection'] != from['collection'] ||
            target['character_id'] != from['character_id'] ||
            target['local_day'] != from['local_day'] ||
            target['day_zone_id'] != from['day_zone_id'] ||
            target['text'] != from['text'] ||
            !sameMemoryMergeConditions(target, from) ||
            !proofs[target['id']]!.any(proofs[from['id']]!.contains)) {
          continue;
        }
        final targetId = target['id'] as String;
        final fromId = from['id'] as String;
        // Advancing either referenced revision would affect another entry.
        // That larger plan belongs to the explicit model merge, not this pair.
        if (_db.select('SELECT 1 FROM memory_card_references WHERE parent_card_id IN (?,?) LIMIT 1', [
          targetId,
          fromId,
        ]).isNotEmpty) {
          continue;
        }
        Map<String, int> references(String id) => {
          for (final row in _db.select(
            'SELECT parent_card_id,parent_row_rev FROM memory_card_references WHERE card_id=?',
            [id],
          ))
            row['parent_card_id'] as String: row['parent_row_rev'] as int,
        };
        if (_canonicalJson(references(targetId)) != _canonicalJson(references(fromId))) continue;
        if (target['topic_mode'] == 'less') {
          List<String> anchors(Object? topic) => (jsonDecode(
            _db.select('SELECT control_anchors FROM memory_topics WHERE id=?', [topic]).single['control_anchors']
                as String,
          ) as List).cast<String>()..sort();
          if (jsonEncode(anchors(target['topic_id'])) != jsonEncode(anchors(from['topic_id']))) continue;
        }
        final aliases = _db.select('SELECT alias,normalized_alias FROM memory_person_aliases WHERE card_id=?', [
          fromId,
        ]);
        final plan = _planMergeCards(targetId, fromId, preserveKeywords: true);
        // The old writer unions complete proof groups, cleanup provenance,
        // migrations and consumed followups. Scope/refs were checked above.
        _applyMergeCards(plan, at);
        for (final alias in aliases) {
          _db.execute('INSERT OR IGNORE INTO memory_person_aliases(card_id,alias,normalized_alias) VALUES(?,?,?)', [
            targetId,
            alias['alias'],
            alias['normalized_alias'],
          ]);
        }
        _db.execute('UPDATE memory_cards SET maintenance_row_rev=row_rev WHERE id=?', [targetId]);
        _bumpMemory();
        return 1;
      }
    }
    return 0;
  });

  /// Local exact duplicates need no model or budget. Cloud candidates are
  /// complete connected groups; an oversized group stays wholly unchecked.
  MemoryMergeBatch? nextMergeBatch({required int Function(String) estimateTokens}) => _transaction(() {
    final at = _checkedNow();
    for (final claim in _db.select('SELECT * FROM memory_merge_batches')) {
      final restored = _restoreMergeBatch(claim, at);
      if (restored != null) return restored;
      _db.execute('DELETE FROM memory_merge_batches WHERE id=?', [claim['id']]);
    }
    if (archive['maintenance_revision'] == archive['memory_revision']) return null;
    var rows = _mergeRows(at);
    final proofs = {for (final row in rows) row['id']: _supportGroups(row).values.map(_mergeProofKey).toSet()};
    final removed = <Object?>{};
    for (var i = 0; i < rows.length; i++) {
      final target = rows[i];
      if (removed.contains(target['id'])) continue;
      for (var j = i + 1; j < rows.length; j++) {
        final from = rows[j];
        if (removed.contains(from['id']) ||
            target['text'] != from['text'] ||
            !sameMemoryMergeConditions(target, from) ||
            !proofs[target['id']]!.any(proofs[from['id']]!.contains)) {
          continue;
        }
        _mergeCards(target['id'] as String, from['id'] as String, at);
        proofs[target['id']]!.addAll(proofs[from['id']]!);
        removed.add(from['id']);
      }
    }
    if (removed.isNotEmpty) {
      _bumpMemory();
      rows = _mergeRows(at);
    }
    final groups = memoryMergeGroups(rows)
        .where((group) => group.any((row) => row['maintenance_row_rev'] != row['row_rev']))
        .toList();
    if (groups.isEmpty) {
      _db.execute('UPDATE memory_archive SET maintenance_revision=memory_revision WHERE singleton=1');
      return null;
    }
    final id = _createId();
    final meta = archive;
    final selected = <MemoryRow>[];
    MemoryMergeBatch batch(List<MemoryRow> input) => MemoryMergeBatch(
      id: id,
      controlRevision: meta['control_revision'] as int,
      memoryRevision: meta['memory_revision'] as int,
      rows: input,
    );
    for (final group in groups) {
      final candidate = [...selected, ...group];
      if (estimateTokens('$companionMemoryConsolidationPrompt\n${jsonEncode(consolidationInput(batch(candidate)))}') <=
          memoryBatchInputTokens) {
        selected.addAll(group);
      }
    }
    if (selected.isEmpty) return null;
    _db.execute(
      '''
      INSERT INTO memory_merge_batches(singleton,id,control_revision,memory_revision,card_revisions)
      VALUES(1,?,?,?,?)
    ''',
      [
        id,
        meta['control_revision'],
        meta['memory_revision'],
        jsonEncode({for (final row in selected) row['id'] as String: row['row_rev']}),
      ],
    );
    return batch(selected);
  });

  List<MemoryRow> _mergeRows(int at, [List<MemoryRow>? source]) {
    final cutoff = archive['history_after_seq'] as int;
    final rows = <MemoryRow>[];
    for (final card in source ?? cards()) {
      if (card['collection'] == 'recent' ||
          card['scope'] != 'real' ||
          card['eligible'] != true ||
          card['topic_mode'] == 'never' ||
          const ['cancelled', 'postponed'].contains(card['plan_state']) ||
          (card['expires_at_ms'] != null && (card['expires_at_ms'] as int) <= at)) {
        continue;
      }
      final evidence = <MemoryRow>[
        for (final group in _supportGroups(card).values)
          if (group.every(
            (proof) => proof['role'] == 'user' && proof['scope'] == 'real' && (proof['first_seq'] as int) > cutoff,
          ))
            ...group,
      ];
      if (evidence.isNotEmpty) rows.add({...card, 'evidence': evidence});
    }
    return rows..sort((a, b) {
      final recent = (b['source_at_ms'] as int).compareTo(a['source_at_ms'] as int);
      return recent == 0 ? (a['id'] as String).compareTo(b['id'] as String) : recent;
    });
  }

  MemoryMergeBatch? _restoreMergeBatch(Row claim, int at) {
    if (claim['control_revision'] != archive['control_revision']) return null;
    final current = {for (final row in _mergeRows(at)) row['id']: row};
    final revisions = jsonDecode(claim['card_revisions'] as String) as Map<String, Object?>;
    final rows = <MemoryRow>[];
    for (final entry in revisions.entries) {
      final row = current[entry.key];
      if (row == null || row['row_rev'] != entry.value) return null;
      rows.add(row);
    }
    return MemoryMergeBatch(
      id: claim['id'] as String,
      controlRevision: claim['control_revision'] as int,
      memoryRevision: claim['memory_revision'] as int,
      rows: rows,
    );
  }

  bool isMergeBatchCurrent(MemoryMergeBatch batch) {
    final claims = _db.select('SELECT * FROM memory_merge_batches WHERE id=?', [batch.id]);
    if (claims.isEmpty) return false;
    final claim = claims.single;
    return claim['control_revision'] == batch.controlRevision &&
        claim['memory_revision'] == batch.memoryRevision &&
        claim['card_revisions'] == jsonEncode({for (final row in batch.rows) row['id'] as String: row['row_rev']}) &&
        _restoreMergeBatch(claim, _checkedNow()) != null;
  }

  /// JSON has passed parseMergeProposal. Even an empty result must still own
  /// the entire current input. Model citations do not replace stored proofs.
  bool commitMerge(MemoryMergeBatch batch, MemoryRow proposal) => _transaction(() {
    if (!isMergeBatchCurrent(batch)) return false;
    final operations = (proposal['operations'] as List<Object?>).cast<MemoryRow>();
    final at = _checkedNow();
    for (final operation in operations) {
      final from = (operation['from'] as List<Object?>).single as MemoryRow;
      _mergeCards(operation['target_id'] as String, from['id'] as String, at);
    }
    if (operations.isNotEmpty) _bumpMemory();
    for (final row in batch.rows) {
      _db.execute('UPDATE memory_cards SET maintenance_row_rev=row_rev WHERE id=?', [row['id']]);
    }
    _db.execute('DELETE FROM memory_merge_batches WHERE id=?', [batch.id]);
    return true;
  });

  void releaseMergeBatch(MemoryMergeBatch batch, {bool examined = false}) => _transaction(() {
    if (examined && isMergeBatchCurrent(batch)) {
      for (final row in batch.rows) {
        _db.execute('UPDATE memory_cards SET maintenance_row_rev=row_rev WHERE id=?', [row['id']]);
      }
    }
    _db.execute('DELETE FROM memory_merge_batches WHERE id=?', [batch.id]);
  });

  String _mergeProofKey(List<MemoryRow> group) => jsonEncode(
    [
      for (final proof in group) jsonEncode([proof['message_id'], proof['source_rev'], proof['quote']]),
    ]..sort(),
  );

  void _mergeCards(String targetId, String fromId, int at) {
    _applyMergeCards(_planMergeCards(targetId, fromId), at);
  }

  _MemoryMergePlan _planMergeCards(String targetId, String fromId, {bool preserveKeywords = false}) {
    final pair = {
      for (final row in _db.select(
        '''
      SELECT c.*,t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id
      WHERE c.id IN (?,?)
    ''',
        [targetId, fromId],
      ))
        row['id']: _card(row),
    };
    final target = pair[targetId]!;
    final from = pair[fromId]!;
    final keys = _supportGroups(target).values.map(_mergeProofKey).toSet();
    final proofGroups = <List<MemoryRow>>[];
    for (final group in _supportGroups(from).values) {
      if (!keys.add(_mergeProofKey(group))) continue;
      proofGroups.add(group);
    }
    final words = <String>[];
    final seen = <String>{};
    for (final card in [target, from]) {
      final supported = _supportedWords(card).toSet();
      for (final word in card['keywords'] as List<String>) {
        final normalized = normalizeMemoryText(word);
        if (words.length < 8 && supported.contains(normalized) && seen.add(normalized)) words.add(word);
      }
    }
    final proofs = [
      ...(target['evidence'] as List<Object?>).cast<MemoryRow>(),
      ...(from['evidence'] as List<Object?>).cast<MemoryRow>(),
    ];
    List<String>? anchors;
    if (target['topic_mode'] == 'less') {
      anchors = {
        for (final topic in _db.select('SELECT control_anchors FROM memory_topics WHERE id IN (?,?)', [
          target['topic_id'],
          from['topic_id'],
        ]))
          ...(jsonDecode(topic['control_anchors'] as String) as List<Object?>).cast<String>(),
      }.toList()..sort();
    }
    return _MemoryMergePlan(
      target: target,
      from: from,
      proofGroups: proofGroups,
      keywords: preserveKeywords
          ? {...(target['keywords'] as List<String>), ...(from['keywords'] as List<String>)}.toList()
          : words,
      currentBasisSeq: proofs.map((proof) => proof['first_seq'] as int).reduce(math.max),
      sourceAtMs: proofs.map((proof) => (proof['edited_at_utc'] ?? proof['said_at_utc']) as int).reduce(math.max),
      controlAnchors: anchors,
    );
  }

  void _applyMergeCards(_MemoryMergePlan plan, int at) {
    final target = plan.target;
    final from = plan.from;
    final targetId = target['id']! as String;
    final fromId = from['id']! as String;
    for (final group in plan.proofGroups) {
      final id = _createId();
      for (final proof in group) {
        _db.execute(
          '''
          INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)
        ''',
          [targetId, id, proof['message_id'], proof['source_rev'], proof['quote']],
        );
      }
    }
    final revision = (target['row_rev'] as int) + 1;
    _db.execute(
      '''
      UPDATE memory_cards SET row_rev=?,pinned=?,keywords=?,current_basis_seq=?,source_at_ms=?,updated_at_ms=?,
        cleanup_history_complete=? WHERE id=?
    ''',
      [
        revision,
        target['pinned'] == true || from['pinned'] == true ? 1 : 0,
        jsonEncode(plan.keywords),
        plan.currentBasisSeq,
        plan.sourceAtMs,
        at,
        target['cleanup_history_complete'] == 1 && from['cleanup_history_complete'] == 1 ? 1 : 0,
        targetId,
      ],
    );
    _db.execute('UPDATE memory_migrations SET local_card_id=? WHERE local_card_id=?', [targetId, fromId]);
    // Rebind before the card FK cascades. Consumption, invitation identity,
    // original clocks, completion support and shared spends are unchanged.
    _db.execute('UPDATE memory_followups SET card_id=?,card_rev=?,row_rev=row_rev+1 WHERE card_id IN (?,?)', [
      targetId,
      revision,
      targetId,
      fromId,
    ]);
    _db.execute(
      '''
      INSERT INTO memory_card_cleanup_sources(card_id,message_id,proof_withdrawn)
        SELECT ?,message_id,proof_withdrawn FROM memory_card_cleanup_sources WHERE card_id=?
        ON CONFLICT(card_id,message_id) DO UPDATE SET
          proof_withdrawn=MAX(memory_card_cleanup_sources.proof_withdrawn,excluded.proof_withdrawn)
    ''',
      [targetId, fromId],
    );
    final anchors = plan.controlAnchors;
    if (anchors != null) {
      _db.execute('UPDATE memory_topics SET control_anchors=? WHERE id=?', [jsonEncode(anchors), target['topic_id']]);
    }
    _db.execute('DELETE FROM memory_cards WHERE id=?', [fromId]);
    _db.execute('DELETE FROM memory_topics WHERE id=? AND NOT EXISTS(SELECT 1 FROM memory_cards WHERE topic_id=?)', [
      from['topic_id'],
      from['topic_id'],
    ]);
  }

  String? reserveRequest({
    required String category,
    required String provider,
    required String model,
    required int inputTokens,
    required int outputTokens,
    String? batchId,
  }) => _transaction(
    () => _reserveMemoryRequest(
      category: category,
      provider: provider,
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      batchId: batchId,
    ),
  );

  String? _reserveMemoryRequest({
    required String category,
    required String provider,
    required String model,
    required int inputTokens,
    required int outputTokens,
    String? batchId,
    String? maintenanceClaimId,
  }) {
    if (!const ['chat', 'extract', 'organize', 'followup', 'notice'].contains(category) ||
        provider.isEmpty ||
        model.isEmpty ||
        _usageCount(inputTokens) == null ||
        _usageCount(outputTokens) == null) {
      throw ArgumentError('Invalid companion request reservation');
    }
    final at = _checkedNow();
    final knownPrice = provider == 'deepseek' && model == 'deepseek-flash';
    final reservedCost = knownPrice ? _costUnits(inputTokens, 0, outputTokens) : null;
    if (category != 'chat') {
      // Only rows one of the two windows below can count. Settled rows are
      // kept forever, so reading them all grew with every request ever made.
      final rows = _db.select(
        '''
        SELECT * FROM memory_requests WHERE category!='chat' AND state!='released'
          AND (COALESCE(sent_at_ms,uncertain_at_ms,reserved_at_ms)>?
            OR (sent_at_ms IS NULL AND uncertain_at_ms IS NULL AND state='reserved'))
      ''',
        [at - 30 * 86400000],
      );
      final daily = rows.where((row) {
        final attemptedAt = row['sent_at_ms'] ?? row['uncertain_at_ms'];
        return attemptedAt == null ? row['state'] == 'reserved' : (attemptedAt as int) > at - 86400000;
      }).toList();
      final sameKind = daily.where((row) {
        if (row['category'] != category) return false;
        // Only a Store-validated live organize parent may make another
        // physical HTTP call in the same logical daily opportunity. Its
        // tokens and cost remain in every aggregate below.
        if (category == 'organize' &&
            maintenanceClaimId != null &&
            _db.select('SELECT 1 FROM memory_agent_maintenance_requests WHERE request_id=? AND claim_id=?', [
              row['id'],
              maintenanceClaimId,
            ]).isNotEmpty) {
          return false;
        }
        return true;
      }).length;
      if ((category == 'extract' && sameKind >= 10) || (category == 'organize' && sameKind >= 1)) {
        return null;
      }
      final input = daily.fold<int>(inputTokens, (sum, row) => sum + _heldInput(row));
      final output = daily.fold<int>(outputTokens, (sum, row) => sum + _heldOutput(row));
      if (input > 24000 || output > 3000) return null;
      if (reservedCost != null) {
        var monthly = reservedCost;
        for (final row in rows) {
          final time = row['sent_at_ms'] ?? row['uncertain_at_ms'] ?? row['reserved_at_ms'];
          if ((time as int) <= at - 30 * 86400000 ||
              row['provider'] != 'deepseek' ||
              row['model'] != 'deepseek-flash') {
            continue;
          }
          monthly += _heldCost(row);
          // Stop before another large but valid integer observation could
          // overflow the running 64-bit sum.
          if (monthly > 300000000) return null;
        }
        if (monthly > 300000000) return null;
      }
    }
    final id = _createId();
    _db.execute(
      '''
        INSERT INTO memory_requests(id,category,batch_id,provider,model,reserved_at_ms,reserved_input,
          reserved_output,reserved_cny,state) VALUES(?,?,?,?,?,?,?,?,?,'reserved')
      ''',
      [
        id,
        category,
        batchId,
        provider,
        model,
        at,
        inputTokens,
        outputTokens,
        reservedCost == null ? null : reservedCost / 100000000,
      ],
    );
    return id;
  }

  void markRequestSent(String id) => _transaction(() {
    final row = _request(id);
    if (row['sent_at_ms'] != null) return;
    if (row['state'] != 'reserved' && row['terminal'] != 'dispatch_unknown') throw _conflict;
    _db.execute("UPDATE memory_requests SET sent_at_ms=?,state='sent',terminal=NULL WHERE id=?", [_checkedNow(), id]);
  });

  /// Before the full-mode owner HTTP call: acceptance/dispatch can become
  /// unknowable if this process dies. This is not an observed provider send.
  void markRequestUncertain(String id) => _transaction(() {
    final row = _request(id);
    if (row['state'] == 'released') throw _conflict;
    if (row['sent_at_ms'] != null || row['uncertain_at_ms'] != null) return;
    if (row['state'] != 'reserved') throw _conflict;
    _db.execute(
      "UPDATE memory_requests SET uncertain_at_ms=?,state='interrupted',terminal='dispatch_unknown' WHERE id=?",
      [_checkedNow(), id],
    );
  });

  void recordUsage(String id, Map<String, Object?> usage) => _transaction(() {
    final row = _request(id);
    if (row['state'] == 'released' || (row['sent_at_ms'] == null && row['uncertain_at_ms'] == null)) throw _conflict;
    final raw = jsonEncode(usage);
    if (row['raw_usage'] != null) {
      if (row['raw_usage'] != raw) throw _conflict;
      return;
    }
    int? count(String key) {
      return _usageCount(usage[key]);
    }

    final input = count('input_uncached');
    final read = count('input_cache_read');
    final write = count('input_cache_write');
    final output = count('output_tokens');
    final cost =
        row['provider'] == 'deepseek' &&
            row['model'] == 'deepseek-flash' &&
            input != null &&
            read != null &&
            write == 0 &&
            output != null
        ? _costUnits(input, read, output)
        : null;
    _db.execute(
      '''
      UPDATE memory_requests SET raw_usage=?,usage_semantics=?,input_uncached=?,input_cache_read=?,
        input_cache_write=?,output_tokens=?,estimated_cny=? WHERE id=?
    ''',
      [raw, usage['usage_semantics'], input, read, write, output, cost == null ? null : cost / 100000000, id],
    );
  });

  void finishRequest(String id, {required String terminal}) => _transaction(() {
    final row = _request(id);
    if (row['sent_at_ms'] != null && terminal == 'not_sent') throw _conflict;
    if (row['sent_at_ms'] == null && terminal == 'not_sent') {
      _db.execute("UPDATE memory_requests SET state='released',terminal='not_sent' WHERE id=?", [id]);
      return;
    }
    if (row['sent_at_ms'] == null && row['uncertain_at_ms'] != null) return;
    if (row['terminal'] != null) return;
    _db.execute('UPDATE memory_requests SET state=?,terminal=? WHERE id=?', [
      row['sent_at_ms'] == null ? 'released' : 'finished',
      terminal,
      id,
    ]);
  });

  /// Persist the immutable owner binding before delivering a full-mode prompt.
  /// A delivery is not evidence of a physical request or of zero usage.
  MemoryRow rememberHostChatDelivery({
    required String hostKey,
    required String instanceId,
    required String sessionId,
    required String requestId,
    required String archiveId,
    required int controlRevision,
    required int historyAfterSeq,
    required int observedAt,
  }) {
    for (final value in [hostKey, instanceId, sessionId, requestId, archiveId]) {
      validateMemoryCardText(value);
      if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) throw ArgumentError('Invalid host chat identity');
    }
    if (_usageCount(controlRevision) == null ||
        _usageCount(historyAfterSeq) == null ||
        observedAt < 0 ||
        observedAt > 8640000000000000) {
      throw ArgumentError('Invalid host chat binding');
    }
    return _transaction(() {
      if (archive['id'] != archiveId) throw _conflict;
      final previous = _db.select(
        '''
        SELECT * FROM memory_host_chat_deliveries
        WHERE host_key=? AND instance_id=? AND session_id=? AND request_id=?
      ''',
        [hostKey, instanceId, sessionId, requestId],
      );
      if (previous.isNotEmpty) {
        final row = previous.single;
        if (row['archive_id'] != archiveId ||
            row['control_revision'] != controlRevision ||
            row['history_after_seq'] != historyAfterSeq) {
          throw _conflict;
        }
        return _hostDelivery(row);
      }
      final id = _createId();
      _db.execute(
        '''
        INSERT INTO memory_host_chat_deliveries(id,host_key,instance_id,session_id,request_id,
          archive_id,control_revision,history_after_seq,observed_at_ms,updated_at_ms,state)
        VALUES(?,?,?,?,?,?,?,?,?,?,'pending')
      ''',
        [
          id,
          hostKey,
          instanceId,
          sessionId,
          requestId,
          archiveId,
          controlRevision,
          historyAfterSeq,
          observedAt,
          _checkedNow(),
        ],
      );
      return _hostDelivery(_hostDeliveryRow(id));
    });
  }

  /// Only read opportunities: neither this list nor an import resends a model
  /// prompt. Settled immutable receipts remain in requests(), including their
  /// unknown fees; pending/running/unknown coverage can be queried again.
  List<MemoryRow> pendingHostChatDeliveries(String hostKey) => [
    for (final row in _db.select(
      '''
      SELECT * FROM memory_host_chat_deliveries WHERE host_key=? AND state!='settled'
      ORDER BY observed_at_ms,id
    ''',
      [hostKey],
    ))
      _hostDelivery(row),
  ];

  /// Coverage metadata is separate from physical receipts. In particular, a
  /// settled root with a gap and no retained receipts is not evidence of free
  /// usage and must remain visible even though it is no longer polled.
  List<MemoryRow> hostChatDeliveries() => [
    for (final row in _db.select('SELECT * FROM memory_host_chat_deliveries ORDER BY observed_at_ms,id'))
      _hostDelivery(row),
  ];

  /// Import one root snapshot atomically. Root coverage and receipt revisions
  /// have different lifetimes: unknown revision zero preserves old evidence.
  bool importHostChatUsage({required String deliveryId, required Map<String, Object?> snapshot}) {
    final incoming = CompanionChatUsageSnapshot.fromJson(snapshot);
    return _transaction(() {
      final delivery = _hostDeliveryRow(deliveryId);
      if (incoming.sessionId != delivery['session_id'] ||
          incoming.requestId != delivery['request_id'] ||
          (incoming.instanceId != delivery['instance_id'] &&
              (incoming.state != 'unknown' || !incoming.gaps.contains('instance-changed')))) {
        throw _conflict;
      }
      if (incoming.state == 'unknown') {
        final gaps = _canonicalJson(incoming.gaps);
        if (delivery['state'] == 'unknown' &&
            delivery['unknown_gaps'] == gaps &&
            delivery['unknown_instance_id'] == incoming.instanceId) {
          return false;
        }
        _db.execute(
          '''
          UPDATE memory_host_chat_deliveries SET state='unknown',unknown_gaps=?,unknown_instance_id=?,updated_at_ms=?
          WHERE id=?
        ''',
          [gaps, incoming.instanceId, _checkedNow(), deliveryId],
        );
        return true;
      }
      final binding = incoming.binding!;
      if (binding.archiveId != delivery['archive_id'] ||
          binding.controlRevision != delivery['control_revision'] ||
          binding.historyAfterSeq != delivery['history_after_seq']) {
        throw _conflict;
      }
      final metadata = _canonicalJson({
        'v': 1,
        'instanceId': incoming.instanceId,
        'sessionId': incoming.sessionId,
        'requestId': incoming.requestId,
        'binding': {
          'archiveId': binding.archiveId,
          'controlRevision': binding.controlRevision,
          'historyAfterSeq': binding.historyAfterSeq,
        },
        'state': incoming.state,
        'complete': incoming.complete,
        'revision': incoming.revision,
        'gaps': incoming.gaps,
        'observedAdapterCalls': incoming.observedAdapterCalls,
        'activeCalls': incoming.activeCalls,
        'physicalRequests': incoming.physicalRequests,
        'receipts': [
          for (final receipt in incoming.receipts) {'receiptId': receipt.receiptId, 'revision': receipt.revision},
        ],
      });
      final oldRevision = delivery['snapshot_revision'] as int;
      if (incoming.revision == oldRevision && delivery['snapshot_metadata'] != metadata) throw _conflict;
      var changed = false;
      final at = _checkedNow();
      for (final receipt in incoming.receipts) {
        final record = _hostReceiptData(receipt);
        final encoded = _canonicalJson(record);
        final previous = _db.select(
          '''
          SELECT * FROM memory_host_chat_receipts WHERE host_key=? AND instance_id=? AND receipt_id=?
        ''',
          [delivery['host_key'], delivery['instance_id'], receipt.receiptId],
        );
        final String localId;
        if (previous.isEmpty) {
          localId = _createId();
          _db.execute(
            '''
            INSERT INTO memory_host_chat_receipts(id,host_key,instance_id,receipt_id,revision,phase,
              receipt_json,first_observed_at_ms,updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?)
          ''',
            [
              localId,
              delivery['host_key'],
              delivery['instance_id'],
              receipt.receiptId,
              receipt.revision,
              receipt.phase,
              encoded,
              at,
              at,
            ],
          );
          changed = true;
        } else {
          final old = previous.single;
          localId = old['id'] as String;
          final oldRecord = jsonDecode(old['receipt_json'] as String) as Map<String, Object?>;
          for (final key in const [
            'receiptId',
            'callId',
            'requestIds',
            'provider',
            'model',
            'observation',
            'dispatched',
            'dispatchAtMs',
            'handoffAtMs',
            'physicalRequests',
          ]) {
            if (_canonicalJson(oldRecord[key]) != _canonicalJson(record[key])) throw _conflict;
          }
          if (_db
              .select(
                '''
            SELECT 1 FROM memory_host_chat_delivery_receipts link JOIN memory_host_chat_deliveries d ON d.id=link.delivery_id
            WHERE link.receipt_id=? AND d.session_id!=?
          ''',
                [localId, delivery['session_id']],
              )
              .isNotEmpty) {
            throw _conflict;
          }
          final previousRevision = old['revision'] as int;
          if (receipt.revision == previousRevision) {
            if (encoded != old['receipt_json']) throw _conflict;
          } else if (receipt.revision > previousRevision) {
            if (old['phase'] == 'finished') throw _conflict;
            _db.execute(
              '''
              UPDATE memory_host_chat_receipts SET revision=?,phase=?,receipt_json=?,updated_at_ms=? WHERE id=?
            ''',
              [receipt.revision, receipt.phase, encoded, at, localId],
            );
            changed = true;
          }
        }
        if (_db.select('SELECT 1 FROM memory_host_chat_delivery_receipts WHERE delivery_id=? AND receipt_id=?', [
          deliveryId,
          localId,
        ]).isEmpty) {
          _db.execute('INSERT INTO memory_host_chat_delivery_receipts(delivery_id,receipt_id) VALUES(?,?)', [
            deliveryId,
            localId,
          ]);
          changed = true;
        }
      }
      if (incoming.revision > oldRevision) {
        _db.execute(
          '''
          UPDATE memory_host_chat_deliveries SET state=?,snapshot_revision=?,snapshot_metadata=?,
            unknown_gaps=NULL,unknown_instance_id=NULL,updated_at_ms=? WHERE id=?
        ''',
          [incoming.state, incoming.revision, metadata, at, deliveryId],
        );
        changed = true;
      }
      return changed;
    });
  }

  Row _hostDeliveryRow(String id) {
    final rows = _db.select('SELECT * FROM memory_host_chat_deliveries WHERE id=?', [id]);
    if (rows.isEmpty) throw _conflict;
    return rows.single;
  }

  MemoryRow _hostDelivery(Row row) => {
    ...row,
    'snapshot_metadata': row['snapshot_metadata'] == null ? null : jsonDecode(row['snapshot_metadata'] as String),
    'unknown_gaps': row['unknown_gaps'] == null ? null : jsonDecode(row['unknown_gaps'] as String),
    'receipt_ids': [
      for (final link in _db.select(
        '''
      SELECT r.receipt_id FROM memory_host_chat_delivery_receipts link
      JOIN memory_host_chat_receipts r ON r.id=link.receipt_id WHERE link.delivery_id=? ORDER BY r.receipt_id
    ''',
        [row['id']],
      ))
        link['receipt_id'],
    ],
  };

  MemoryRow _hostReceiptData(CompanionChatUsageReceipt receipt) => {
    'receiptId': receipt.receiptId,
    'callId': receipt.callId,
    'revision': receipt.revision,
    'requestIds': receipt.requestIds,
    'provider': receipt.provider,
    'model': receipt.model,
    'phase': receipt.phase,
    'observation': receipt.observation,
    'dispatched': receipt.dispatched,
    'dispatchAtMs': receipt.dispatchAtMs,
    'handoffAtMs': receipt.handoffAtMs,
    'physicalRequests': receipt.physicalRequests,
    'terminal': receipt.terminal,
    'complete': receipt.complete,
    'httpStatus': receipt.httpStatus,
    'errorCode': receipt.errorCode,
    'usage': {
      for (final key in const [
        'provider',
        'model',
        'start_usage',
        'final_usage',
        'start_event',
        'final_event',
        'usage_semantics',
        'input_uncached',
        'input_cache_read',
        'input_cache_write',
        'output_tokens',
        'stop_reason',
        'terminal',
        'complete',
        'http_status',
        'runtime_normalized_usage',
        'runtime_normalized_usage_semantics',
        'host_adapter_handoff_at_ms',
        'runtime_finish_kind',
        'host_dispatch_at_ms',
      ])
        if (receipt.usage.containsKey(key)) key: receipt.usage[key],
    },
  };

  /// The local physical request's existing cost fields, without projecting history.
  MemoryRow? localRequestCost(String id) {
    final rows = _db.select(
      'SELECT sent_at_ms,uncertain_at_ms,state,reserved_at_ms,estimated_cny,reserved_cny FROM memory_requests WHERE id=?',
      [id],
    );
    return rows.isEmpty ? null : rows.single;
  }

  List<MemoryRow> requests() {
    final rows = <MemoryRow>[
      for (final row in _db.select('SELECT * FROM memory_requests'))
        {
          ...row,
          'origin': 'local',
          'raw_usage': row['raw_usage'] == null ? null : jsonDecode(row['raw_usage'] as String),
        },
      for (final row in _db.select('SELECT * FROM memory_host_chat_receipts')) _hostRequest(row),
    ];
    rows.sort((a, b) {
      final at = (a['observed_at_ms'] ?? a['reserved_at_ms']) as int;
      final bt = (b['observed_at_ms'] ?? b['reserved_at_ms']) as int;
      return at != bt ? at.compareTo(bt) : (a['id'] as String).compareTo(b['id'] as String);
    });
    return rows;
  }

  MemoryRow _hostRequest(Row row) {
    final receipt = jsonDecode(row['receipt_json'] as String) as Map<String, Object?>;
    final usage = receipt['usage'] as Map<String, Object?>;
    final input = _usageCount(usage['input_uncached']), read = _usageCount(usage['input_cache_read']);
    final write = _usageCount(usage['input_cache_write']), output = _usageCount(usage['output_tokens']);
    final cost =
        receipt['provider'] == 'deepseek' &&
            receipt['model'] == 'deepseek-flash' &&
            input != null &&
            read != null &&
            write == 0 &&
            output != null
        ? _costUnits(input, read, output)
        : null;
    return {
      'id': row['id'],
      'origin': 'host-chat',
      'category': 'chat',
      'batch_id': null,
      'provider': receipt['provider'],
      'model': receipt['model'],
      'host_key': row['host_key'],
      'instance_id': row['instance_id'],
      'receipt_id': row['receipt_id'],
      'call_id': receipt['callId'],
      'revision': row['revision'],
      'phase': row['phase'],
      'request_ids': receipt['requestIds'],
      'delivery_ids': [
        for (final link in _db.select(
          'SELECT delivery_id FROM memory_host_chat_delivery_receipts WHERE receipt_id=? ORDER BY delivery_id',
          [row['id']],
        ))
          link['delivery_id'],
      ],
      'observed_at_ms': row['first_observed_at_ms'],
      'updated_at_ms': row['updated_at_ms'],
      'reserved_at_ms': null,
      'reserved_input': null,
      'reserved_output': null,
      'reserved_cny': null,
      'sent_at_ms': null,
      'uncertain_at_ms': null,
      'host_dispatch_at_ms': receipt['dispatchAtMs'],
      'observation': receipt['observation'],
      'dispatched': receipt['dispatched'],
      'physical_requests': receipt['physicalRequests'],
      'raw_usage': usage,
      'usage_semantics': usage['usage_semantics'],
      'input_uncached': input,
      'input_cache_read': read,
      'input_cache_write': write,
      'output_tokens': output,
      'estimated_cny': cost == null ? null : cost / 100000000,
      'state': row['phase'] == 'active'
          ? 'active'
          : receipt['dispatched'] == false
          ? 'not_sent'
          : 'finished',
      'terminal': receipt['terminal'],
      'complete': receipt['complete'],
    };
  }

  Row _request(String id) {
    final rows = _db.select('SELECT * FROM memory_requests WHERE id=?', [id]);
    if (rows.isEmpty) throw _conflict;
    return rows.single;
  }

  bool _allUsageKnown(Row row) => const [
    'input_uncached',
    'input_cache_read',
    'input_cache_write',
    'output_tokens',
  ].every((key) => _usageCount(row[key]) != null);

  int? _usageCount(Object? value) => value is int && value >= 0 && value <= 9007199254740991 ? value : null;

  /// Runtime-normalized events are not provider raw usage. Each safe counter
  /// is at most a lower bound here; absent/default zero never closes a raw
  /// unknown, and event totals are never added together.
  int? _normalizedBound(Row row, List<String> keys) {
    if (row['raw_usage'] == null) return null;
    final usage = jsonDecode(row['raw_usage'] as String) as Map<String, Object?>;
    final events = usage['runtime_normalized_usage'];
    if (events is! List<Object?>) return null;
    int? bound;
    for (final event in events) {
      if (event is! Map<String, Object?>) continue;
      for (final key in keys) {
        final count = _usageCount(event[key]);
        if (count != null) bound = bound == null ? count : math.max(bound, count);
      }
    }
    return bound;
  }

  int _normalizedInput(Row row) =>
      _normalizedBound(row, const ['inputTokens', 'cacheReadTokens', 'cacheWriteTokens']) ?? 0;

  int _normalizedOutput(Row row) => _normalizedBound(row, const ['outputTokens']) ?? 0;

  int _reportedInput(Row row) =>
      (_usageCount(row['input_uncached']) ?? 0) +
      (_usageCount(row['input_cache_read']) ?? 0) +
      (_usageCount(row['input_cache_write']) ?? 0);

  int _heldInput(Row row) => math.max(
    _normalizedInput(row),
    _allUsageKnown(row) ? _reportedInput(row) : math.max(row['reserved_input'] as int, _reportedInput(row)),
  );

  int _heldOutput(Row row) => math.max(
    _normalizedOutput(row),
    _allUsageKnown(row)
        ? row['output_tokens'] as int
        : math.max(row['reserved_output'] as int, _usageCount(row['output_tokens']) ?? 0),
  );

  // Peak rates verified for this route: CNY 2 uncached input / .04 cache read /
  // 8 output per million. Integer 1e-8 CNY units avoid a floating boundary at 3.
  int _costUnits(int input, int read, int output) => input * 200 + read * 4 + output * 800;

  int _heldCost(Row row) {
    // On the verified route only, reserve a peak-rate estimate for the seen
    // normalized lower bound. It is not a provider charge or a known cache
    // split; estimated_cny remains null when raw final fields are unknown.
    final normalized = _costUnits(_normalizedInput(row), 0, _normalizedOutput(row));
    if (_allUsageKnown(row) && row['input_cache_write'] == 0) {
      return math.max(
        normalized,
        _costUnits(row['input_uncached'] as int, row['input_cache_read'] as int, row['output_tokens'] as int),
      );
    }
    // A nonzero cache-write rate has not been verified. Keep the peak input
    // reservation and the known lower bound; estimated_cny remains unknown.
    return math.max(
      normalized,
      math.max(
        _costUnits(row['reserved_input'] as int, 0, row['reserved_output'] as int),
        _costUnits(
          _usageCount(row['input_uncached']) ?? 0,
          _usageCount(row['input_cache_read']) ?? 0,
          _usageCount(row['output_tokens']) ?? 0,
        ),
      ),
    );
  }

  int _checkedNow() {
    final at = _now();
    if (at < 0 || at > 8640000000000000) {
      throw const DshRemoteException('companion/unavailable', 'Companion clock is unavailable', {'status': 503});
    }
    return at;
  }

  /// The App's existing strict v1/v2 reader owns legacy validation. A missing
  /// SQLite singleton is uninitialized, not permission to discard a bad key.
  MemoryRow? initiativeRecord() {
    final rows = _db.select('SELECT * FROM memory_initiative_state WHERE singleton=1');
    if (rows.isEmpty) return null;
    final state = rows.single;
    final at = _checkedNow();
    final spends = _db.select(
      '''
      SELECT kind,COALESCE(presented_at_ms,reserved_at_ms) AS at FROM memory_initiative_spends
      WHERE state!='released' AND COALESCE(presented_at_ms,reserved_at_ms)>? ORDER BY at,id
    ''',
      [at - 86400000],
    );
    return {
      'v': 2,
      'lastGreetingAtMs': state['last_greeting_at_ms'],
      'inviteAtMs': [
        for (final spend in spends)
          if (spend['kind'] == 'invite') spend['at'],
      ],
      'signalAtMs': [
        for (final spend in spends)
          if (spend['kind'] != 'invite') spend['at'],
      ],
      'declinedUntilMs': state['declined_until_ms'],
      'night': state['night_json'] == null ? null : jsonDecode(state['night_json'] as String),
    };
  }

  MemoryRow initializeInitiative(MemoryRow validatedV2) => _transaction(() {
    final existing = initiativeRecord();
    if (existing != null) return existing;
    _db.execute(
      '''
      INSERT INTO memory_initiative_state(singleton,last_greeting_at_ms,declined_until_ms,night_json) VALUES(1,?,?,?)
    ''',
      [
        validatedV2['lastGreetingAtMs'],
        validatedV2['declinedUntilMs'],
        validatedV2['night'] == null ? null : jsonEncode(validatedV2['night']),
      ],
    );
    for (final entry in const {'invite': 'inviteAtMs', 'signal': 'signalAtMs'}.entries) {
      for (final at in (validatedV2[entry.value] as List<Object?>).cast<int>()) {
        _db.execute(
          '''
          INSERT INTO memory_initiative_spends(id,kind,reserved_at_ms,presented_at_ms,state) VALUES(?,?,?,?,'shown')
        ''',
          ['legacy:${entry.key}:$at', entry.key, at, at],
        );
      }
    }
    return initiativeRecord()!;
  });

  /// Never overwrite the shared spend history with a possibly older RAM
  /// controller snapshot. Only its greeting/decline/timezone metadata is saved.
  void writeInitiativeMetadata(MemoryRow validatedV2) {
    _db.execute(
      '''
      UPDATE memory_initiative_state SET last_greeting_at_ms=?,declined_until_ms=?,night_json=? WHERE singleton=1
    ''',
      [
        validatedV2['lastGreetingAtMs'],
        validatedV2['declinedUntilMs'],
        validatedV2['night'] == null ? null : jsonEncode(validatedV2['night']),
      ],
    );
    if (_db.select('SELECT changes() AS n').single['n'] != 1) throw _conflict;
  }

  String? reserveInitiative({
    required String kind,
    required int nowMs,
    required int maxPerDay,
    required int gapMs,
    String? followupId,
    String? noticeEventId,
    String? noticePersonId,
  }) {
    if (noticeEventId != null) {
      _noticeIdentity(noticeEventId);
      if (noticePersonId != null) _noticeIdentity(noticePersonId);
      if (kind != 'signal' || followupId != null) throw ArgumentError('A notice must be a signal');
    } else if (noticePersonId != null) {
      throw ArgumentError('Missing notice event');
    }
    if (nowMs < 0 || nowMs > 8640000000000000) throw ArgumentError('Invalid initiative clock');
    return _transaction(() {
      final states = _db.select('SELECT * FROM memory_initiative_state WHERE singleton=1');
      if (states.isEmpty) throw _conflict;
      final metadata = states.single;
      if (nowMs < (metadata['declined_until_ms'] as int) ||
          (metadata['last_greeting_at_ms'] != null && (metadata['last_greeting_at_ms'] as int) > nowMs)) {
        return null;
      }
      final spent = _db.select(
        '''
        SELECT *,COALESCE(presented_at_ms,reserved_at_ms) AS at FROM memory_initiative_spends
        WHERE state!='released' AND COALESCE(presented_at_ms,reserved_at_ms)>? ORDER BY at,id
      ''',
        [nowMs - 86400000],
      );
      if (spent.length >= maxPerDay || (spent.isNotEmpty && nowMs - (spent.last['at'] as int) < gapMs)) return null;
      if (noticeEventId != null && !_noticeMaySpeak(eventId: noticeEventId, personId: noticePersonId, nowMs: nowMs)) {
        return null;
      }
      if (kind == 'followup') {
        if (spent.any((row) => row['kind'] == 'followup')) return null;
        final rows = _db.select('SELECT * FROM memory_followups WHERE id=?', [followupId]);
        if (rows.isEmpty || rows.single['state'] != 'pending' || !isFollowupCurrent(rows.single, nowMs: nowMs)) {
          return null;
        }
        _db.execute("UPDATE memory_followups SET state='reserved' WHERE id=?", [followupId]);
      }
      final id = _createId();
      _db.execute(
        '''
        INSERT INTO memory_initiative_spends(id,opportunity_id,kind,reserved_at_ms,state) VALUES(?,?,?,?,'reserved')
      ''',
        [id, followupId, kind, nowMs],
      );
      if (noticeEventId != null) {
        _db.execute('INSERT INTO memory_notice_spends(spend_id,person_id) VALUES(?,?)', [id, noticePersonId]);
      }
      return id;
    });
  }

  /// Rendering is outside the transaction. Only a real successful callback
  /// supplies shown; a throwing/unknown callback keeps its conservative debit.
  void settleInitiative(String id, {required String outcome}) => _transaction(() {
    if (!const ['shown', 'released', 'unknown'].contains(outcome)) throw ArgumentError('Invalid initiative outcome');
    final rows = _db.select('SELECT * FROM memory_initiative_spends WHERE id=?', [id]);
    if (rows.isEmpty) throw _conflict;
    final spend = rows.single;
    if (spend['state'] == outcome) return;
    if (spend['state'] != 'reserved') throw _conflict;
    final at = outcome == 'shown' ? _checkedNow() : null;
    _db.execute('UPDATE memory_initiative_spends SET state=?,presented_at_ms=? WHERE id=?', [outcome, at, id]);
    if (spend['opportunity_id'] != null) {
      final state = outcome == 'shown'
          ? 'asked'
          : outcome == 'unknown'
          ? 'maybe_shown'
          : 'pending';
      _db.execute(
        '''
        UPDATE memory_followups SET state=?,presented_at_ms=?,reason=?,row_rev=row_rev+?
        WHERE id=? AND (state='reserved' OR ?)
      ''',
        [
          state,
          at,
          outcome == 'unknown' ? 'presentation_unknown' : null,
          outcome == 'shown' ? 0 : 1,
          spend['opportunity_id'],
          outcome == 'released' ? 0 : 1,
        ],
      );
    }
  });

  List<MemoryRow> followups() => [
    for (final row in _db.select('SELECT * FROM memory_followups ORDER BY opens_at_ms,id')) {...row},
  ];

  MemoryRow? nextFollowup({required int nowMs}) => _transaction(() {
    _refreshFollowups(nowMs);
    for (final row in _db.select("SELECT * FROM memory_followups WHERE state='pending' ORDER BY opens_at_ms,id")) {
      if (isFollowupCurrent(row, nowMs: nowMs)) return Map<String, Object?>.from(row);
    }
    return null;
  });

  /// Currentness protects an existing display as well as a pending ticket.
  /// Asked may remain visible for its original eight seconds; only pending
  /// can reserve, so this is never permission to show the question twice.
  bool isFollowupCurrent(MemoryRow captured, {required int nowMs}) {
    final rows = _db.select(
      '''
    SELECT f.* FROM memory_followups f JOIN memory_cards c ON c.id=f.card_id
    JOIN memory_topics t ON t.id=c.topic_id JOIN memory_messages m ON m.id=f.message_id
    JOIN memory_archive a ON a.singleton=1 LEFT JOIN memory_messages support ON support.id=f.support_message_id
    WHERE f.id=? AND f.row_rev=? AND f.card_id=? AND f.card_rev=? AND f.control_revision=?
      AND f.message_id=? AND f.source_rev=? AND f.support_message_id IS ? AND f.support_source_rev IS ?
      AND f.state IN ('pending','reserved','asked') AND f.invitation!=''
      AND f.opens_at_ms<=? AND f.expires_at_ms>? AND f.control_revision=a.control_revision
      AND c.row_rev=f.card_rev AND c.scope='real' AND c.eligible=1 AND c.status='current'
      AND (c.plan_state IS NULL OR c.plan_state NOT IN ('cancelled','postponed'))
      AND (c.expires_at_ms IS NULL OR c.expires_at_ms>?) AND t.mode='normal'
      AND m.source_rev=f.source_rev AND m.role='user' AND m.scope='real'
      AND (f.agent_origin=1 OR m.first_seq>MAX(a.history_after_seq,a.followup_after_seq))
      AND (f.wait_subject IS NULL OR (support.source_rev=f.support_source_rev AND support.role='user'
        AND support.scope='real' AND support.first_seq>m.first_seq))
  ''',
      [
        captured['id'],
        captured['row_rev'],
        captured['card_id'],
        captured['card_rev'],
        captured['control_revision'],
        captured['message_id'],
        captured['source_rev'],
        captured['support_message_id'],
        captured['support_source_rev'],
        nowMs,
        nowMs,
        nowMs,
      ],
    );
    if (rows.isEmpty) return false;
    final current = rows.single;
    if (current['agent_origin'] == 1 || current['state'] == 'asked' || current['wait_subject'] == null) return true;
    // An unshown legacy completion still needs one unambiguous card.
    // Read the current candidates without altering the presentation debit.
    final candidateCards = _legacyFollowupCandidates(nowMs).choices
        .where((row) => row['wait_subject'] == current['wait_subject'])
        .map((row) => row['card_id'])
        .toSet();
    return candidateCards.length == 1 && candidateCards.contains(current['card_id']);
  }

  ({Map<String, MemoryRow> sources, List<MemoryRow> choices}) _legacyFollowupCandidates(int at) {
    final meta = archive;
    // Runs on every idle observation: only the cards that carry a follow-up
    // are worth their evidence queries, and without one no message is needed.
    final followups = [
      for (final row in _db.select('''
        SELECT c.*, t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id = c.topic_id
        WHERE c.status != 'withdrawn' AND c.followup IS NOT NULL ORDER BY c.id
      '''))
        _card(row),
    ];
    final sources = <String, MemoryRow>{
      if (followups.isNotEmpty)
        for (final row in _db.select(
          "SELECT * FROM memory_messages WHERE role='user' AND scope='real' AND first_seq>? ORDER BY first_seq",
          [math.max(meta['history_after_seq'] as int, meta['followup_after_seq'] as int)],
        ))
          row['id'] as String: Map<String, Object?>.from(row),
    };
    final candidates = <String, List<MemoryRow>>{};
    for (final card in followups) {
      if (!_currentCard(card, at) || card['topic_mode'] != 'normal' || card['followup'] == null) continue;
      final wording = (card['followup'] as MemoryRow)['wording'] as String;
      final origins = <String>{
        for (final proof in (card['evidence'] as List<Object?>).cast<MemoryRow>())
          if ((proof['quote'] as String).contains(wording)) proof['message_id'] as String,
      };
      for (final origin in origins) {
        final source = sources[origin];
        if (source == null) continue;
        final plan = qualifyMemoryFollowup(card, source);
        if (plan == null) continue;
        // One logical invitation at this window keeps its identity through
        // source edits, pin changes, card revalidation and process restarts.
        final id = sha256.convert(utf8.encode(jsonEncode([origin, plan['time_key']]))).toString();
        (candidates[id] ??= []).add({
          'id': id,
          ...plan,
          'card_id': card['id'],
          'card_rev': card['row_rev'],
          'control_revision': meta['control_revision'],
          'message_id': origin,
          'source_rev': source['source_rev'],
          'invitation': source['text'],
          'source_first_seq': source['first_seq'],
          'said_at_utc': source['said_at_utc'],
          'offset_minutes': source['offset_minutes'],
          'support_message_id': null,
          'support_source_rev': null,
          'support_quote': null,
        });
      }
    }
    return (
      sources: sources,
      choices: [
        for (final group in candidates.values)
          if (group.length == 1) group.single,
      ],
    );
  }

  void _refreshFollowups(int at) {
    _refreshAgentFollowups(at);
    final candidates = _legacyFollowupCandidates(at);
    final sources = candidates.sources;
    final choices = candidates.choices;
    final chosenIds = choices.map((row) => row['id']).toSet();
    final existing = {
      for (final row in _db.select('SELECT * FROM memory_followups WHERE agent_origin=0')) row['id'] as String: row,
    };
    for (final old in existing.values) {
      if (const ['waiting', 'pending'].contains(old['state']) && !chosenIds.contains(old['id'])) {
        _db.execute(
          "UPDATE memory_followups SET state='closed',reason='no_current_invitation',invitation='',local_line=NULL,"
          "support_quote=NULL,row_rev=row_rev+1 WHERE id=?",
          [old['id']],
        );
      }
    }
    for (final candidate in choices) {
      final old = existing[candidate['id']];
      if (old != null &&
          (const ['asked', 'maybe_shown'].contains(old['state']) ||
              const ['unresolved_control', 'expired', 'already_presented'].contains(old['reason']))) {
        continue;
      }
      final spent = _db.select(
        "SELECT state FROM memory_initiative_spends WHERE opportunity_id=? AND state!='released'",
        [candidate['id']],
      );
      if (spent.any((row) => row['state'] == 'reserved')) continue;
      final subject = candidate['wait_subject'] as String?;
      if (subject != null &&
          choices.where((other) => other['wait_subject'] == subject).map((other) => other['card_id']).toSet().length ==
              1) {
        for (final support in sources.values) {
          if ((support['first_seq'] as int) <= (candidate['source_first_seq'] as int) ||
              (support['said_at_utc'] as int) < (candidate['said_at_utc'] as int) ||
              !isMemoryFollowupCompletion(subject, support['text'] as String)) {
            continue;
          }
          candidate.addAll({
            'support_message_id': support['id'],
            'support_source_rev': support['source_rev'],
            'support_quote': support['text'],
            'opens_at_ms': support['said_at_utc'],
            'expires_at_ms': (support['said_at_utc'] as int) + memoryFollowupWindowMs,
            'time_key': 'completed:${support['said_at_utc']}',
            'reason': null,
          });
          break;
        }
      }
      final alreadyAsked =
          spent.isNotEmpty ||
          existing.values.any(
            (row) =>
                row['card_id'] == candidate['card_id'] &&
                row['time_key'] == candidate['time_key'] &&
                const ['asked', 'maybe_shown'].contains(row['state']),
          );
      final expires = candidate['expires_at_ms'] as int?;
      candidate['state'] = alreadyAsked || expires != null && expires <= at
          ? 'closed'
          : candidate['opens_at_ms'] == null
          ? 'waiting'
          : 'pending';
      if (alreadyAsked) {
        candidate['reason'] = 'already_presented';
      } else if (expires != null && expires <= at) {
        candidate['reason'] = 'expired';
      }
      // Polling an unchanged opportunity must not invalidate its captured ticket.
      if (old != null && candidate.entries.every((entry) => old[entry.key] == entry.value)) continue;
      _db.execute(
        '''
        INSERT INTO memory_followups(id,row_rev,time_key,card_id,card_rev,control_revision,message_id,source_rev,
          invitation,source_first_seq,said_at_utc,offset_minutes,wait_subject,opens_at_ms,expires_at_ms,local_line,
          support_message_id,support_source_rev,support_quote,state,reason)
        VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET row_rev=row_rev+1,time_key=excluded.time_key,card_id=excluded.card_id,
          card_rev=excluded.card_rev,control_revision=excluded.control_revision,message_id=excluded.message_id,
          source_rev=excluded.source_rev,invitation=excluded.invitation,source_first_seq=excluded.source_first_seq,
          said_at_utc=excluded.said_at_utc,offset_minutes=excluded.offset_minutes,wait_subject=excluded.wait_subject,
          opens_at_ms=excluded.opens_at_ms,expires_at_ms=excluded.expires_at_ms,local_line=excluded.local_line,
          support_message_id=excluded.support_message_id,support_source_rev=excluded.support_source_rev,
          support_quote=excluded.support_quote,state=excluded.state,reason=excluded.reason
      ''',
        [
          for (final key in const [
            'id',
            'time_key',
            'card_id',
            'card_rev',
            'control_revision',
            'message_id',
            'source_rev',
            'invitation',
            'source_first_seq',
            'said_at_utc',
            'offset_minutes',
            'wait_subject',
            'opens_at_ms',
            'expires_at_ms',
            'local_line',
            'support_message_id',
            'support_source_rev',
            'support_quote',
            'state',
            'reason',
          ])
            candidate[key],
        ],
      );
    }
  }

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
      if (previous?['collection'] == 'recent') {
        throw const DshRemoteException(
          'companion/notice-readonly',
          'Notice summaries can be forgotten; chat confirmation creates a separate memory',
          {'status': 400},
        );
      }
      if ((previous == null && expectedRowRev != null) || (previous != null && previous['row_rev'] != expectedRowRev)) {
        throw _conflict;
      }
      final at = _now();
      if (at < 0 || at > 8640000000000000) {
        throw const DshRemoteException('companion/unavailable', 'Companion clock is unavailable', {'status': 503});
      }
      final changedText = previous == null || previous['text'] != memory.text;
      final controlled = changedText
          ? _bodyControlledTopics(memory.text, characterId: previous?['character_id'] as String?)
          : const <String>[];
      if (controlled.length > 1) {
        throw const DshRemoteException(
          'companion/invalid-request',
          'Manual memory matches multiple controlled topics',
          {'status': 400, 'reason': 'ambiguous_controlled_topic'},
        );
      }
      final topic = controlled.isEmpty ? (previous?['topic_id'] as String?) ?? _createId() : controlled.single;
      final changedContext =
          previous == null ||
          changedText ||
          previous['kind'] != memory.kind ||
          previous['keywords'] != jsonEncode(memory.keywords) ||
          previous['expires_at_ms'] != memory.expiresAt?.millisecondsSinceEpoch;
      final basis = changedText && currentValueChange && realityKnown ? _sequence() : previous?['current_basis_seq'];
      final status = previous == null || (changedText && currentValueChange && realityKnown)
          ? 'current'
          : previous['status'];
      if (previous != null && changedText && currentValueChange && realityKnown) {
        _removeFactRelations(
          {id},
          retainTargetId: id,
          retainTopics: controlled.toSet(),
          domainSnapshot: _memoryDomainCards(previous['character_id'] as String?)
              .where((card) => card['character_id'] == previous['character_id'])
              .toList(),
        );
      }
      if (previous == null && controlled.isEmpty) _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
      final revision = previous == null ? 1 : (previous['row_rev'] as int) + 1;
      _db.execute(
        '''
        INSERT INTO memory_cards(id, row_rev, kind, text, keywords, pinned, eligible, manual,
          topic_id, current_basis_seq, source_at_ms, created_at_ms, updated_at_ms, expires_at_ms, status,
          cleanup_history_complete)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET row_rev=excluded.row_rev, kind=excluded.kind, topic_id=excluded.topic_id,
          text=excluded.text, keywords=excluded.keywords, pinned=excluded.pinned,
          eligible=excluded.eligible, manual=excluded.manual, current_basis_seq=excluded.current_basis_seq,
          source_at_ms=excluded.source_at_ms, updated_at_ms=excluded.updated_at_ms,
          expires_at_ms=excluded.expires_at_ms, status=excluded.status,
          cleanup_history_complete=excluded.cleanup_history_complete
      ''',
        [
          id,
          revision,
          memory.kind,
          memory.text,
          jsonEncode(memory.keywords),
          memory.pinned ? 1 : 0,
          changedText ? (realityKnown ? 1 : 0) : previous['eligible'],
          changedText ? 1 : previous['manual'],
          topic,
          basis,
          changedText ? at : previous['source_at_ms'],
          previous?['created_at_ms'] ?? at,
          at,
          memory.expiresAt?.millisecondsSinceEpoch,
          status,
          changedText ? 1 : previous['cleanup_history_complete'],
        ],
      );
      // An edit is its own manual basis; old quotes no longer prove the new wording.
      if (changedText) {
        _db.execute('DELETE FROM memory_card_sources WHERE card_id = ?', [id]);
        _db.execute('DELETE FROM memory_card_cleanup_sources WHERE card_id=?', [id]);
        _db.execute('DELETE FROM memory_card_references WHERE card_id=?', [id]);
        _db.execute('DELETE FROM memory_person_aliases WHERE card_id=?', [id]);
        _db.execute(
          'UPDATE memory_cards SET event_time=NULL,followup=NULL,plan_state=CASE WHEN ? THEN NULL ELSE plan_state END WHERE id=?',
          [currentValueChange && realityKnown ? 1 : 0, id],
        );
      }
      _bumpMemory();
      if (changedContext) _bumpControl();
      return revision;
    });
  }

  int _sequence() {
    final sequence = archive['next_seq']! as int;
    _db.execute('UPDATE memory_archive SET next_seq = next_seq + 1 WHERE singleton = 1');
    return sequence;
  }

  void _bumpMemory() =>
      _db.execute('UPDATE memory_archive SET memory_revision = memory_revision + 1 WHERE singleton = 1');

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

void _messageText(String text) {
  if (text.trim().isEmpty || text.contains('\u0000')) {
    throw const DshRemoteException('companion/invalid-request', 'Invalid companion source text', {'status': 400});
  }
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= text.length || text.codeUnitAt(i) < 0xdc00 || text.codeUnitAt(i) > 0xdfff) {
        throw const DshRemoteException('companion/invalid-request', 'Invalid companion source text', {'status': 400});
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const DshRemoteException('companion/invalid-request', 'Invalid companion source text', {'status': 400});
    }
  }
}

final _wordCharacter = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _hanCharacter = RegExp(r'\p{Script=Han}', unicode: true);
final _asciiWord = RegExp(r'[a-z0-9_]');

bool _anchorWord(String word) =>
    _wordCharacter.hasMatch(word) && (!_hanCharacter.hasMatch(word) || word.runes.length >= 2);

bool _containsAnchor(String text, String word) {
  var start = 0;
  while (start <= text.length - word.length) {
    final at = text.indexOf(word, start);
    if (at < 0) return false;
    final end = at + word.length;
    if ((!_asciiWord.hasMatch(word[0]) || at == 0 || !_asciiWord.hasMatch(text[at - 1])) &&
        (!_asciiWord.hasMatch(word[word.length - 1]) || end == text.length || !_asciiWord.hasMatch(text[end]))) {
      return true;
    }
    start = at + 1;
  }
  return false;
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

String _canonicalJson(Object? value) => jsonEncode(_orderedJson(value));

Object? _orderedJson(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _orderedJson(value[key])};
  }
  if (value is List<Object?>) return [for (final item in value) _orderedJson(item)];
  return value;
}
