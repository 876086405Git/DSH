/// The phone owns one memory database. Network work stays outside transactions.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

import 'companion_api.dart';
import 'companion_memory_rules.dart';
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
      if (version > 2) {
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
      _transaction(() {
        _db.execute("UPDATE memory_requests SET state='released', terminal='not_sent' "
          "WHERE sent_at_ms IS NULL AND state='reserved'");
        _db.execute("UPDATE memory_requests SET state='interrupted', terminal='interrupted' "
          "WHERE sent_at_ms IS NOT NULL AND terminal IS NULL");
      });
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

  String get lightSessionId => archive['light_session_id'] as String;

  /// A fresh model conversation; previous messages remain available to view.
  String startLightConversation() => _transaction(() {
    final session = 'light:${_createId()}';
    _db.execute('UPDATE memory_archive SET light_session_id=? WHERE singleton=1', [session]);
    return session;
  });

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
  }) {
    _messageText(text);
    if (id.trim().isEmpty || sessionId.trim().isEmpty ||
        !const ['user', 'assistant'].contains(role) || !const ['real', 'story'].contains(scope) ||
        saidAtUtc < 0 || saidAtUtc > 8640000000000000) {
      throw const DshRemoteException('companion/invalid-request', 'Invalid companion source', {'status': 400});
    }
    return _transaction(() {
      final previous = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
      if (previous.isNotEmpty) {
        final row = previous.single;
        if (row['session_id'] != sessionId || row['text'] != text || row['role'] != role || row['scope'] != scope ||
            row['said_at_utc'] != saidAtUtc || row['offset_minutes'] != offsetMinutes) throw _conflict;
        return Map<String, Object?>.from(row);
      }
      final at = _checkedNow();
      final sequence = _sequence();
      _db.execute('''
        INSERT INTO memory_messages(id,session_id,first_seq,source_rev,event_seq,role,scope,text,
          said_at_utc,offset_minutes) VALUES(?,?,?,1,?,?,?,?,?,?)
      ''', [id, sessionId, sequence, sequence, role, scope, text, saidAtUtc, offsetMinutes]);
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
      _db.execute("UPDATE memory_events SET state='superseded', reason='edited' WHERE message_id=? AND source_rev=?",
        [id, expectedSourceRev]);
      _db.execute('UPDATE memory_messages SET text=?,source_rev=source_rev+1,event_seq=?,edited_at_utc=? WHERE id=?',
        [text, sequence, at, id]);
      _queueMessage(id, sequence, expectedSourceRev + 1, role: previous['role'] as String,
        scope: previous['scope'] as String, firstSeq: previous['first_seq'] as int, at: at);
      _advanceCursor();
      return Map<String, Object?>.from(_db.select('SELECT * FROM memory_messages WHERE id=?', [id]).single);
    });
  }

  List<MemoryRow> messages({String? sessionId, bool forModel = false, int? limit}) {
    if (limit != null && limit < 1) throw ArgumentError.value(limit, 'limit');
    final where = <String>[];
    final values = <Object?>[];
    if (sessionId != null) {
      where.add('m.session_id=?');
      values.add(sessionId);
    }
    if (forModel) {
      where.add("m.scope='real' AND m.first_seq>?");
      values.add(archive['history_after_seq']);
    }
    final rows = _db.select('''
      SELECT m.*, e.state AS extraction_state, e.reason AS extraction_reason, e.format_failures
      FROM memory_messages m JOIN memory_events e ON e.seq=m.event_seq
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY m.first_seq ${limit == null ? 'ASC' : 'DESC LIMIT ?'}
    ''', [...values, if (limit != null) limit]);
    return [for (final row in limit == null ? rows : rows.reversed) Map<String, Object?>.from(row)];
  }

  void _queueMessage(String id, int sequence, int revision, {
    required String role, required String scope, required int firstSeq, required int at,
  }) {
    final reason = role != 'user' || scope != 'real' ? 'not_real_user' :
        firstSeq <= (archive['history_after_seq'] as int) ? 'history_cutoff' : null;
    _db.execute('''
      INSERT INTO memory_events(seq,message_id,source_rev,state,reason,queued_at_ms) VALUES(?,?,?,?,?,?)
    ''', [sequence, id, revision, reason == null ? 'pending' : 'skipped', reason, at]);
  }

  /// Each support group is a complete proof. Removing one member withdraws the
  /// whole group before we ask whether another independent group still holds.
  void _removeSourceGroups(String messageId, int revision) {
    final affected = <String>{};
    for (final group in _db.select('''
      SELECT DISTINCT card_id,support_group FROM memory_card_sources WHERE message_id=? AND source_rev=?
    ''', [messageId, revision])) {
      affected.add(group['card_id'] as String);
      _db.execute('DELETE FROM memory_card_sources WHERE card_id=? AND support_group=?',
        [group['card_id'], group['support_group']]);
    }
    for (final id in affected) {
      final card = _db.select('SELECT * FROM memory_cards WHERE id=?', [id]).single;
      final sources = _db.select('''
        SELECT m.first_seq,m.text,COALESCE(m.edited_at_utc,m.said_at_utc) AS at FROM memory_card_sources s
        JOIN memory_messages m ON m.id=s.message_id AND m.source_rev=s.source_rev WHERE s.card_id=?
      ''', [id]);
      final manual = card['manual'] == 1;
      final supported = sources.isNotEmpty;
      final sourceAt = manual || !supported ? card['source_at_ms'] :
          sources.map((source) => source['at'] as int).reduce(math.max);
      final basis = manual ? card['current_basis_seq'] : supported ?
          sources.map((source) => source['first_seq'] as int).reduce(math.max) : null;
      final keywords = (jsonDecode(card['keywords'] as String) as List).cast<String>().where((keyword) => manual ||
          sources.any((source) => normalizeMemoryText(source['text'] as String).contains(normalizeMemoryText(keyword)))).toList();
      _db.execute('''
        UPDATE memory_cards SET row_rev=row_rev+1,eligible=?,status=?,keywords=?,
          current_basis_seq=?,source_at_ms=?,updated_at_ms=? WHERE id=?
      ''', [manual || supported ? card['eligible'] : 0, manual || supported ? card['status'] : 'withdrawn',
        jsonEncode(keywords), basis, sourceAt, _checkedNow(), id]);
    }
    if (affected.isNotEmpty) _bumpMemory();
  }

  MemoryBatch? nextBatch({bool forceTail = false, required int Function(String) estimateTokens}) => _transaction(() {
    final at = _checkedNow();
    for (final claim in _db.select('SELECT * FROM memory_batches')) {
      final restored = _restoreBatch(claim, at);
      if (restored != null) {
        _db.execute("UPDATE memory_batches SET state='claimed' WHERE id=?", [restored.id]);
        return restored;
      }
      _dropBatch(claim['id'] as String);
    }
    _db.execute('''
      UPDATE memory_events SET state='skipped',reason='history_cutoff',batch_id=NULL
      WHERE state='pending' AND message_id IN (SELECT id FROM memory_messages WHERE first_seq<=?)
    ''', [archive['history_after_seq']]);
    _advanceCursor();
    final pending = _db.select('''
      SELECT m.*,e.queued_at_ms,e.format_failures FROM memory_events e JOIN memory_messages m
        ON m.id=e.message_id AND m.source_rev=e.source_rev AND m.event_seq=e.seq
      WHERE e.state='pending' ORDER BY e.seq
    ''');
    if (pending.isEmpty) return null;
    final sourceTokens = pending.fold<int>(0, (sum, row) => sum + estimateTokens(row['text'] as String));
    final latest = pending.map((row) => row['queued_at_ms'] as int).reduce(math.max);
    if (!forceTail && pending.first['format_failures'] == 0 &&
        pending.length < 8 && sourceTokens < 1500 && at - latest < 120000) return null;
    final id = _createId();
    final control = archive['control_revision'] as int;
    final sources = <MemoryRow>[];
    final existing = <MemoryRow>[];
    int size(List<MemoryRow> input, List<MemoryRow> cards) => estimateTokens(
      '$companionMemoryExtractionPrompt\n${jsonEncode(extractionInput(
        MemoryBatch(id: id, controlRevision: control, sources: input, existing: cards), processedAtUtc: at))}',
    );
    for (final row in pending) {
      // An edited/stale batch can leave an old retry ahead of fresh events.
      // Its final permitted attempt must not consume a fresh event's retry.
      if (sources.length == memoryBatchMessageLimit || row['format_failures'] != pending.first['format_failures']) break;
      final source = Map<String, Object?>.from(row)..remove('queued_at_ms')..remove('format_failures');
      if (size([source], const []) > memoryBatchInputTokens) {
        _db.execute("UPDATE memory_events SET state='skipped',reason='input_too_long' WHERE seq=?", [source['event_seq']]);
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
    _db.execute('INSERT INTO memory_batches(id,control_revision,existing_revisions,state) VALUES(?,?,?,\'claimed\')',
      [id, control, jsonEncode({for (final card in existing) card['id'] as String: card['row_rev']})]);
    for (final source in sources) {
      _db.execute('UPDATE memory_events SET batch_id=? WHERE seq=?', [id, source['event_seq']]);
    }
    return MemoryBatch(id: id, controlRevision: control, sources: sources, existing: existing);
  });

  List<MemoryRow>? _currentBatchSources(String id) {
    final rows = _db.select('''
      SELECT m.*,e.state AS claim_state,e.source_rev AS claim_rev,e.seq AS claim_seq
      FROM memory_events e JOIN memory_messages m ON m.id=e.message_id WHERE e.batch_id=? ORDER BY e.seq
    ''', [id]);
    if (rows.isEmpty) return null;
    final cutoff = archive['history_after_seq'] as int;
    final sources = <MemoryRow>[];
    for (final row in rows) {
      if (row['claim_state'] != 'pending' || row['claim_rev'] != row['source_rev'] ||
          row['claim_seq'] != row['event_seq'] || row['role'] != 'user' || row['scope'] != 'real' ||
          (row['first_seq'] as int) <= cutoff) return null;
      sources.add(Map<String, Object?>.from(row)..remove('claim_state')..remove('claim_rev')..remove('claim_seq'));
    }
    return sources;
  }

  bool _currentCard(MemoryRow card, int at) => card['scope'] == 'real' && card['eligible'] == true &&
      card['status'] == 'current' && (card['expires_at_ms'] == null || (card['expires_at_ms'] as int) > at);

  MemoryBatch? _restoreBatch(Row claim, int at) {
    if (claim['control_revision'] != archive['control_revision']) return null;
    final sources = _currentBatchSources(claim['id'] as String);
    if (sources == null) return null;
    final revisions = jsonDecode(claim['existing_revisions'] as String) as Map<String, Object?>;
    final existing = <MemoryRow>[];
    for (final entry in revisions.entries) {
      final rows = _db.select('''
        SELECT c.*,t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id WHERE c.id=?
      ''', [entry.key]);
      if (rows.isEmpty || rows.single['row_rev'] != entry.value) return null;
      final card = _card(rows.single);
      if (!_currentCard(card, at)) return null;
      existing.add(card);
    }
    return MemoryBatch(id: claim['id'] as String, controlRevision: claim['control_revision'] as int,
      sources: sources, existing: existing);
  }

  bool isBatchCurrent(MemoryBatch batch) {
    final claims = _db.select("SELECT * FROM memory_batches WHERE id=? AND state='claimed'", [batch.id]);
    if (claims.isEmpty) return false;
    if (claims.single['control_revision'] != batch.controlRevision || archive['control_revision'] != batch.controlRevision) return false;
    final sources = _currentBatchSources(batch.id);
    if (sources == null || sources.length != batch.sources.length) return false;
    for (var i = 0; i < sources.length; i++) {
      final expected = batch.sources[i];
      final actual = sources[i];
      if (expected['id'] != actual['id'] || expected['source_rev'] != actual['source_rev'] ||
          expected['event_seq'] != actual['event_seq']) return false;
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
      if (rows.isEmpty || rows.single['row_rev'] != operation['expected_row_rev'] ||
          !_currentCard(_card(rows.single), at)) return false;
    }
    final skipped = <MemoryRow>[];
    var changed = false;
    for (var index = 0; index < operations.length; index++) {
      final operation = operations[index];
      final evidence = (operation['evidence'] as List<Object?>).cast<MemoryRow>();
      final referenced = [for (final reference in evidence) sources[reference['message_id']]!];
      final basis = referenced.map((source) => source['first_seq'] as int).reduce(math.max);
      final sourceAt = referenced.map((source) => (source['edited_at_utc'] ?? source['said_at_utc']) as int).reduce(math.max);
      final target = operation['op'] == 'replace'
          ? _db.select('SELECT * FROM memory_cards WHERE id=?', [operation['target_id']]).single : null;
      if (target != null && !canApplyMemoryCurrentValue(proposedBasisSeq: basis,
          currentBasisSeq: target['current_basis_seq'] as int?)) {
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
      final id = target?['id'] ?? _createId();
      final topic = target?['topic_id'] ?? _createId();
      if (target == null) _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
      _db.execute('''
        INSERT INTO memory_cards(id,row_rev,kind,text,keywords,pinned,scope,eligible,status,manual,
          topic_id,current_basis_seq,source_at_ms,event_time,followup,created_at_ms,updated_at_ms)
        VALUES(?,?,?,?,?,?,'real',1,?,0,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET row_rev=excluded.row_rev,kind=excluded.kind,text=excluded.text,
          keywords=excluded.keywords,eligible=1,status=excluded.status,manual=0,
          current_basis_seq=excluded.current_basis_seq,source_at_ms=excluded.source_at_ms,
          event_time=excluded.event_time,followup=excluded.followup,plan_state=NULL,
          updated_at_ms=excluded.updated_at_ms,expires_at_ms=NULL
      ''', [id, target == null ? 1 : (target['row_rev'] as int) + 1, operation['kind'], operation['text'],
        jsonEncode(operation['keywords']), target?['pinned'] ?? 0, 'current', topic,
        basis, sourceAt, operation['event_time'] == null ? null : jsonEncode(operation['event_time']),
        operation['followup'] == null ? null : jsonEncode(operation['followup']), target?['created_at_ms'] ?? at, at]);
      if (target != null) _db.execute('DELETE FROM memory_card_sources WHERE card_id=?', [id]);
      final group = _createId();
      for (final reference in evidence) {
        final source = sources[reference['message_id']]!;
        _db.execute('''
          INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)
          ON CONFLICT(card_id,support_group,message_id,source_rev,quote) DO NOTHING
        ''', [id, group, source['id'], source['source_rev'], reference['quote']]);
      }
      changed = true;
    }
    _db.execute("UPDATE memory_events SET state='done',reason=? WHERE batch_id=? AND state='pending'",
      [skipped.isEmpty ? null : jsonEncode({'skipped_operations': skipped}), batch.id]);
    _db.execute('DELETE FROM memory_batches WHERE id=?', [batch.id]);
    if (changed) _bumpMemory();
    _advanceCursor();
    return true;
  });

  /// This is a finite literal collision check, not a semantic topic proof.
  /// Only this operation's evidence is searched, not unrelated parts of a
  /// composite source message, and missing proposed keywords cannot bypass it.
  String? _possibleCurrentConflict(MemoryRow operation, int basis, int at) {
    final evidence = (operation['evidence'] as List<Object?>).cast<MemoryRow>();
    final text = normalizeMemoryText('${operation['text']}\n${evidence.map((e) => e['quote']).join('\n')}');
    for (final card in cards()) {
      if (!_currentCard(card, at) ||
          canApplyMemoryCurrentValue(proposedBasisSeq: basis, currentBasisSeq: card['current_basis_seq'] as int?)) continue;
      final support = card['manual'] == true ? [card['text'] as String] : [
        for (final source in _db.select('''
          SELECT m.text FROM memory_card_sources s JOIN memory_messages m
            ON m.id=s.message_id AND m.source_rev=s.source_rev WHERE s.card_id=?
        ''', [card['id']])) source['text'] as String,
      ];
      for (final word in (card['keywords'] as List<String>).map(normalizeMemoryText)) {
        if (_anchorWord(word) && support.any((source) => normalizeMemoryText(source).contains(word)) &&
            _containsAnchor(text, word)) return card['id'] as String;
      }
    }
    return null;
  }

  void recordInvalidProposal(MemoryBatch batch) => _transaction(() {
    if (!isBatchCurrent(batch)) return;
    _db.execute('''
      UPDATE memory_events SET format_failures=format_failures+1,
        state=CASE WHEN format_failures>=1 THEN 'skipped' ELSE 'pending' END,
        reason=CASE WHEN format_failures>=1 THEN 'invalid_proposal' ELSE 'retry_invalid_proposal' END
      WHERE batch_id=? AND state='pending'
    ''', [batch.id]);
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
    for (final event in _db.select('SELECT seq,state FROM memory_events WHERE seq>? ORDER BY seq', [cursor])) {
      if (event['state'] == 'pending') break;
      cursor = event['seq'] as int;
    }
    _db.execute('UPDATE memory_archive SET cursor_seq=? WHERE singleton=1', [cursor]);
  }

  String? reserveRequest({
    required String category,
    required String provider,
    required String model,
    required int inputTokens,
    required int outputTokens,
    String? batchId,
  }) {
    if (!const ['chat', 'extract', 'organize'].contains(category) || provider.isEmpty || model.isEmpty ||
        inputTokens < 0 || outputTokens < 0) throw ArgumentError('Invalid companion request reservation');
    return _transaction(() {
      final at = _checkedNow();
      final knownPrice = provider == 'deepseek' && model == 'deepseek-flash';
      final reservedCost = knownPrice ? _costUnits(inputTokens, 0, outputTokens) : null;
      if (category != 'chat') {
        final rows = _db.select("SELECT * FROM memory_requests WHERE category!='chat' AND state!='released'");
        final daily = rows.where((row) {
          final attemptedAt = row['sent_at_ms'] ?? row['uncertain_at_ms'];
          return attemptedAt == null ? row['state'] == 'reserved' : (attemptedAt as int) > at - 86400000;
        }).toList();
        final sameKind = daily.where((row) => row['category'] == category).length;
        if (sameKind >= (category == 'extract' ? 10 : 1)) return null;
        final input = daily.fold<int>(inputTokens, (sum, row) => sum + _heldInput(row));
        final output = daily.fold<int>(outputTokens, (sum, row) => sum + _heldOutput(row));
        if (input > 24000 || output > 3000) return null;
        if (reservedCost != null) {
          var monthly = reservedCost;
          for (final row in rows) {
            final time = row['sent_at_ms'] ?? row['uncertain_at_ms'] ?? row['reserved_at_ms'];
            if ((time as int) <= at - 30 * 86400000 || row['provider'] != 'deepseek' || row['model'] != 'deepseek-flash') continue;
            monthly += _heldCost(row);
          }
          if (monthly > 300000000) return null;
        }
      }
      final id = _createId();
      _db.execute('''
        INSERT INTO memory_requests(id,category,batch_id,provider,model,reserved_at_ms,reserved_input,
          reserved_output,reserved_cny,state) VALUES(?,?,?,?,?,?,?,?,?,'reserved')
      ''', [id, category, batchId, provider, model, at, inputTokens, outputTokens,
        reservedCost == null ? null : reservedCost / 100000000]);
      return id;
    });
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
    _db.execute("UPDATE memory_requests SET uncertain_at_ms=?,state='interrupted',terminal='dispatch_unknown' WHERE id=?",
      [_checkedNow(), id]);
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
      final value = usage[key];
      return value is int && value >= 0 ? value : null;
    }
    final input = count('input_uncached');
    final read = count('input_cache_read');
    final write = count('input_cache_write');
    final output = count('output_tokens');
    final cost = row['provider'] == 'deepseek' && row['model'] == 'deepseek-flash' &&
        input != null && read != null && write == 0 && output != null ? _costUnits(input, read, output) : null;
    _db.execute('''
      UPDATE memory_requests SET raw_usage=?,usage_semantics=?,input_uncached=?,input_cache_read=?,
        input_cache_write=?,output_tokens=?,estimated_cny=? WHERE id=?
    ''', [raw, usage['usage_semantics'], input, read, write, output,
      cost == null ? null : cost / 100000000, id]);
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
    _db.execute('UPDATE memory_requests SET state=?,terminal=? WHERE id=?',
      [row['sent_at_ms'] == null ? 'released' : 'finished', terminal, id]);
  });

  List<MemoryRow> requests() => [
    for (final row in _db.select('SELECT * FROM memory_requests ORDER BY reserved_at_ms,id')) {
      ...row,
      'raw_usage': row['raw_usage'] == null ? null : jsonDecode(row['raw_usage'] as String),
    },
  ];

  Row _request(String id) {
    final rows = _db.select('SELECT * FROM memory_requests WHERE id=?', [id]);
    if (rows.isEmpty) throw _conflict;
    return rows.single;
  }

  bool _allUsageKnown(Row row) => const ['input_uncached', 'input_cache_read', 'input_cache_write', 'output_tokens']
      .every((key) => row[key] != null);

  int _reportedInput(Row row) => (row['input_uncached'] as int? ?? 0) +
      (row['input_cache_read'] as int? ?? 0) + (row['input_cache_write'] as int? ?? 0);

  int _heldInput(Row row) => _allUsageKnown(row) ? _reportedInput(row) :
      math.max(row['reserved_input'] as int, _reportedInput(row));

  int _heldOutput(Row row) => _allUsageKnown(row) ? row['output_tokens'] as int :
      math.max(row['reserved_output'] as int, row['output_tokens'] as int? ?? 0);

  // Peak rates verified for this route: CNY 2 uncached input / .04 cache read /
  // 8 output per million. Integer 1e-8 CNY units avoid a floating boundary at 3.
  int _costUnits(int input, int read, int output) => input * 200 + read * 4 + output * 800;

  int _heldCost(Row row) {
    if (_allUsageKnown(row) && row['input_cache_write'] == 0) {
      return _costUnits(row['input_uncached'] as int, row['input_cache_read'] as int, row['output_tokens'] as int);
    }
    // A nonzero cache-write rate has not been verified. Keep the peak input
    // reservation and the known lower bound; estimated_cny remains unknown.
    return math.max(_costUnits(row['reserved_input'] as int, 0, row['reserved_output'] as int),
      _costUnits(row['input_uncached'] as int? ?? 0, row['input_cache_read'] as int? ?? 0, row['output_tokens'] as int? ?? 0));
  }

  int _checkedNow() {
    final at = _now();
    if (at < 0 || at > 8640000000000000) {
      throw const DshRemoteException('companion/unavailable', 'Companion clock is unavailable', {'status': 503});
    }
    return at;
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

bool _anchorWord(String word) => _wordCharacter.hasMatch(word) &&
    (!_hanCharacter.hasMatch(word) || word.runes.length >= 2);

bool _containsAnchor(String text, String word) {
  var start = 0;
  while (start <= text.length - word.length) {
    final at = text.indexOf(word, start);
    if (at < 0) return false;
    final end = at + word.length;
    if ((!_asciiWord.hasMatch(word[0]) || at == 0 || !_asciiWord.hasMatch(text[at - 1])) &&
        (!_asciiWord.hasMatch(word[word.length - 1]) || end == text.length || !_asciiWord.hasMatch(text[end]))) return true;
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
