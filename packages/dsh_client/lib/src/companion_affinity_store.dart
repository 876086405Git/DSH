part of 'companion_memory_store.dart';

const _affinityEventColumns = <String, String>{
  'chat': 'chat_turns',
  'pet': 'pet_count',
  'snack': 'snack_count',
  'play': 'play_count',
  'confiding': 'confide_count',
  'answered_question': 'answer_count',
  'answered_followup': 'followup_count',
};
const _affinityFloors = [0, 30000, 100000, 300000, 600000, 900000];

int _affinityTier(int score) => _affinityFloors.lastIndexWhere((floor) => score >= floor);

String _memoryLocalDay(int atMs, int offsetMinutes) =>
    DateTime.fromMillisecondsSinceEpoch(atMs + offsetMinutes * 60000, isUtc: true).toIso8601String().split('T').first;

DateTime _memoryDayDate(String day) => DateTime.parse('${day}T00:00:00Z');

extension CompanionAffinityStore on CompanionMemoryStore {
  /// The caller reports one actually visible/resumed attachment interval using
  /// its original wall-clock anchor and monotonically measured elapsed time.
  /// Repeating a checkpoint adds only the newly observed part of the interval.
  void recordCompanionPresence({
    required String characterId,
    required String segmentId,
    required int startedAtMs,
    required int elapsedMs,
    required int offsetMinutes,
  }) {
    _checkAffinityFact(segmentId, startedAtMs, offsetMinutes);
    if (elapsedMs < 0 || elapsedMs > 8640000000000000 - startedAtMs) {
      throw ArgumentError.value(elapsedMs, 'elapsedMs');
    }
    _transaction(() {
      _checkMemoryCharacter(characterId);
      final rows = _db.select('SELECT * FROM memory_affinity_presence WHERE character_id=? AND segment_id=?', [
        characterId,
        segmentId,
      ]);
      var previous = 0;
      if (rows.isNotEmpty) {
        final row = rows.single;
        if (row['started_at_ms'] != startedAtMs || row['offset_minutes'] != offsetMinutes) throw _conflict;
        previous = row['elapsed_ms'] as int;
        if (elapsedMs <= previous) return;
      } else {
        _db.execute(
          '''
          INSERT INTO memory_affinity_presence(character_id,segment_id,started_at_ms,offset_minutes,elapsed_ms)
          VALUES(?,?,?,?,0)
        ''',
          [characterId, segmentId, startedAtMs, offsetMinutes],
        );
      }
      var cursor = startedAtMs + previous;
      final end = startedAtMs + elapsedMs;
      while (cursor < end) {
        final local = DateTime.fromMillisecondsSinceEpoch(cursor + offsetMinutes * 60000, isUtc: true);
        final boundary =
            DateTime.utc(local.year, local.month, local.day + 1).millisecondsSinceEpoch - offsetMinutes * 60000;
        final next = math.min(end, boundary);
        _addAffinityDay(characterId, cursor, offsetMinutes, 'companionship_ms', next - cursor);
        cursor = next;
      }
      _db.execute('UPDATE memory_affinity_presence SET elapsed_ms=? WHERE character_id=? AND segment_id=?', [
        elapsedMs,
        characterId,
        segmentId,
      ]);
    });
  }

  /// These are actual application events, not sentences from model context.
  /// Chat additionally deduplicates by the already committed original source.
  void recordCompanionInteraction({
    required String characterId,
    required String eventId,
    required String kind,
    required int atMs,
    required int offsetMinutes,
    String? sourceId,
    String? presentationId,
  }) => _transaction(
    () => _recordCompanionInteraction(
      characterId: characterId,
      eventId: eventId,
      kind: kind,
      atMs: atMs,
      offsetMinutes: offsetMinutes,
      sourceId: sourceId,
      presentationId: presentationId,
    ),
  );

  void _recordCompanionInteraction({
    required String characterId,
    required String eventId,
    required String kind,
    required int atMs,
    required int offsetMinutes,
    String? sourceId,
    String? presentationId,
  }) {
    _checkAffinityFact(eventId, atMs, offsetMinutes);
    final column = _affinityEventColumns[kind];
    final semantic = const {'confiding', 'answered_question', 'answered_followup'}.contains(kind);
    final answer = kind == 'answered_question' || kind == 'answered_followup';
    if (column == null || ((kind == 'chat' || semantic) && sourceId == null) || (answer && presentationId == null)) {
      throw ArgumentError.value(kind, 'kind');
    }
    _checkMemoryCharacter(characterId);
    if (sourceId != null) {
      final sources = _db.select('SELECT * FROM memory_messages WHERE id=?', [sourceId]);
      if (sources.isEmpty ||
          sources.single['character_id'] != characterId ||
          sources.single['role'] != 'user' ||
          sources.single['scope'] != 'real') {
        throw _conflict;
      }
      if ((kind == 'chat' || semantic) &&
          (sources.single['said_at_utc'] != atMs || sources.single['offset_minutes'] != offsetMinutes)) {
        throw _conflict;
      }
    }
    if (answer) {
      final tickets = _db.select('SELECT * FROM memory_affinity_presentations WHERE id=?', [presentationId]);
      if (tickets.isEmpty ||
          tickets.single['character_id'] != characterId ||
          tickets.single['kind'] != (kind == 'answered_question' ? 'question' : 'followup') ||
          (tickets.single['presented_at_ms'] as int) > atMs) {
        throw _conflict;
      }
    }
    if (semantic) {
      final settled = _db.select('SELECT settled_through_day FROM memory_affinity WHERE character_id=?', [characterId]);
      final through = settled.isEmpty ? null : settled.single['settled_through_day'] as String?;
      if (through != null && _memoryLocalDay(atMs, offsetMinutes).compareTo(through) <= 0) return;
      if (_db.select('SELECT 1 FROM memory_affinity_events WHERE character_id=? AND kind=? AND source_id=?', [
        characterId,
        kind,
        sourceId,
      ]).isNotEmpty) {
        return;
      }
    }
    final prior = _db.select(
      '''
      SELECT * FROM memory_affinity_events WHERE character_id=? AND kind=? AND event_id=?
    ''',
      [characterId, kind, eventId],
    );
    if (prior.isNotEmpty) {
      final row = prior.single;
      if (row['at_ms'] != atMs ||
          row['offset_minutes'] != offsetMinutes ||
          row['source_id'] != sourceId ||
          row['presentation_id'] != presentationId) {
        throw _conflict;
      }
      return;
    }
    if (kind == 'chat' &&
        _db
            .select(
              '''
      SELECT 1 FROM memory_affinity_events WHERE character_id=? AND kind='chat' AND source_id=?
    ''',
              [characterId, sourceId],
            )
            .isNotEmpty) {
      return;
    }
    _db.execute(
      '''
      INSERT INTO memory_affinity_events(character_id,kind,event_id,at_ms,offset_minutes,source_id,presentation_id)
      VALUES(?,?,?,?,?,?,?)
    ''',
      [characterId, kind, eventId, atMs, offsetMinutes, sourceId, presentationId],
    );
    _addAffinityDay(characterId, atMs, offsetMinutes, column, 1);
  }

  MemoryRow? companionAffinity({required String characterId}) {
    _checkMemoryCharacter(characterId);
    final rows = _db.select('SELECT * FROM memory_affinity WHERE character_id=?', [characterId]);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  /// Called only after an actual presentation. A question uses its saved
  /// assistant source; a followup uses the already shown opportunity receipt.
  void recordCompanionPresentation({
    required String characterId,
    required String presentationId,
    required String kind,
    required int presentedAtMs,
    String? assistantSourceId,
    String? opportunityId,
  }) => _transaction(() {
    _checkMemoryCharacter(characterId);
    _checkAffinityFact(presentationId, presentedAtMs, 0);
    if (kind == 'question' || kind == 'assistant') {
      if (assistantSourceId == null || opportunityId != null) throw ArgumentError('Invalid assistant presentation');
      final source = _db.select('SELECT * FROM memory_messages WHERE id=?', [assistantSourceId]);
      if (source.isEmpty ||
          source.single['character_id'] != characterId ||
          source.single['role'] != 'assistant' ||
          source.single['scope'] != 'real' ||
          (source.single['said_at_utc'] as int) > presentedAtMs) {
        throw _conflict;
      }
    } else if (kind == 'followup') {
      if (opportunityId == null || assistantSourceId != null) throw ArgumentError('Invalid followup presentation');
      if (_db
          .select(
            '''
        SELECT 1 FROM memory_followups f JOIN memory_initiative_spends s ON s.opportunity_id=f.id
          JOIN memory_cards c ON c.id=f.card_id JOIN memory_messages m ON m.id=f.message_id
        WHERE f.id=? AND f.state='asked' AND s.state='shown' AND s.presented_at_ms<=?
          AND (c.character_id IS NULL OR c.character_id=?)
          AND (m.character_id IS NULL OR m.character_id=?)
      ''',
            [opportunityId, presentedAtMs, characterId, characterId],
          )
          .isEmpty) {
        throw _conflict;
      }
    } else {
      throw ArgumentError.value(kind, 'kind');
    }
    final existing = _db.select('SELECT * FROM memory_affinity_presentations WHERE id=?', [presentationId]);
    if (existing.isNotEmpty) {
      final row = existing.single;
      if (row['character_id'] != characterId ||
          (row['kind'] != kind && !(kind == 'assistant' && row['kind'] == 'question')) ||
          row['assistant_source_id'] != assistantSourceId ||
          row['opportunity_id'] != opportunityId ||
          row['presented_at_ms'] != presentedAtMs) {
        throw _conflict;
      }
      return;
    }
    _db.execute(
      '''
      INSERT INTO memory_affinity_presentations(id,character_id,kind,assistant_source_id,opportunity_id,presented_at_ms)
      VALUES(?,?,?,?,?,?)
    ''',
      [presentationId, characterId, kind, assistantSourceId, opportunityId, presentedAtMs],
    );
  });

  /// Installation-wide legacy binding: phone once plus one chosen Host store.
  /// The old sources contribute a maximum baseline, never a sum or old visits.
  bool importCompanionAffinity({
    required String characterId,
    required String sourceKind,
    required String sourceId,
    required double closeness,
    required int observedAtMs,
    required int offsetMinutes,
  }) {
    _checkAffinityFact(sourceId, observedAtMs, offsetMinutes);
    if (!const {'phone', 'host'}.contains(sourceKind) || !closeness.isFinite) {
      throw ArgumentError('Invalid legacy companion affinity');
    }
    return _transaction(() {
      _checkMemoryCharacter(characterId);
      final binding = _db.select('SELECT * FROM memory_affinity_legacy');
      if (binding.isNotEmpty && binding.single['character_id'] != characterId) return false;
      final prior = _db.select('SELECT * FROM memory_affinity_legacy_sources WHERE source_kind=?', [sourceKind]);
      if (prior.isNotEmpty) return prior.single['source_id'] == sourceId;
      final oldSeed = binding.isEmpty ? 0 : binding.single['legacy_seed_milli'] as int;
      final seed = (closeness.clamp(0.0, 1.0) * 1000000).floor();
      final newSeed = math.max(oldSeed, seed);
      final day = _memoryLocalDay(observedAtMs, offsetMinutes);
      _db.execute(
        '''
        INSERT INTO memory_affinity(character_id,policy_started_day) VALUES(?,?)
        ON CONFLICT(character_id) DO NOTHING
      ''',
        [characterId, day],
      );
      final current = _db.select('SELECT * FROM memory_affinity WHERE character_id=?', [characterId]).single;
      final delta = newSeed - oldSeed;
      final score0 = math.min(1000000, (current['score_milli'] as int) + delta);
      final peak = math.min(1000000, math.max((current['peak_milli'] as int) + delta, math.max(score0, newSeed)));
      final tier = math.max(current['tier'] as int, _affinityTier(peak));
      final score = math.max(score0, _affinityFloors[tier]);
      if (binding.isEmpty) {
        _db.execute('INSERT INTO memory_affinity_legacy(singleton,character_id,legacy_seed_milli) VALUES(1,?,?)', [
          characterId,
          newSeed,
        ]);
      } else {
        _db.execute('UPDATE memory_affinity_legacy SET legacy_seed_milli=? WHERE singleton=1', [newSeed]);
      }
      _db.execute(
        '''
        INSERT INTO memory_affinity_legacy_sources(source_kind,source_id,old_value,seed_milli,
          old_seed_milli,new_seed_milli,observed_at_ms,offset_minutes)
        VALUES(?,?,?,?,?,?,?,?)
      ''',
        [sourceKind, sourceId, closeness, seed, oldSeed, newSeed, observedAtMs, offsetMinutes],
      );
      _db.execute(
        '''
        UPDATE memory_affinity SET score_milli=?,peak_milli=?,tier=?,floor_milli=?,row_rev=row_rev+1
        WHERE character_id=?
      ''',
        [score, peak, tier, _affinityFloors[tier], characterId],
      );
      return true;
    });
  }

  /// Deterministic v2.0 settlement. Today stays open. Delayed work visits each
  /// completed day in order; an already settled date is never reopened.
  List<MemoryRow> settleCompanionAffinity({required int nowMs, required int offsetMinutes}) {
    _checkAffinityFact('settlement', nowMs, offsetMinutes);
    final today = _memoryDayDate(_memoryLocalDay(nowMs, offsetMinutes));
    final through = today.subtract(const Duration(days: 1));
    return _transaction(() {
      final result = <MemoryRow>[];
      for (final original in _db.select('SELECT * FROM memory_affinity ORDER BY character_id')) {
        final characterId = original['character_id'] as String;
        final settled = original['settled_through_day'] as String?;
        final first = settled == null
            ? _memoryDayDate(original['policy_started_day'] as String)
            : _memoryDayDate(settled).add(const Duration(days: 1));
        if (first.isAfter(through)) continue;
        final days = {
          for (final day in _db.select('SELECT * FROM memory_affinity_days WHERE character_id=?', [characterId]))
            day['local_day'] as String: day,
        };
        var score = original['score_milli'] as int;
        var peak = original['peak_milli'] as int;
        var tier = original['tier'] as int;
        final firstMet = original['first_met_ms'] as int?;
        for (var day = first; !day.isAfter(through); day = day.add(const Duration(days: 1))) {
          final key = day.toIso8601String().split('T').first;
          final facts = days[key];
          if (facts != null) {
            final dailyOffset = facts['offset_minutes'] as int;
            final endMs = day.add(const Duration(days: 1)).millisecondsSinceEpoch - dailyOffset * 60000;
            final knownDays = firstMet == null ? 0 : 1 + math.max(0, (endMs - 1 - firstMet) ~/ 86400000);
            var activeDays = 0;
            for (var previous = 0; previous < 14; previous++) {
              if (days.containsKey(day.subtract(Duration(days: previous)).toIso8601String().split('T').first)) {
                activeDays++;
              }
            }
            final base =
                math.min(1000, knownDays * 1000 ~/ 30) +
                math.min(3000, (facts['companionship_ms'] as int) * 3000 ~/ 3600000) +
                math.min(8, facts['chat_turns'] as int) * 375 +
                activeDays * 2000 ~/ 14;
            final bonus = math.min(
              1000,
              (math.min(2, facts['pet_count'] as int) +
                          math.min(2, facts['snack_count'] as int) +
                          math.min(2, facts['play_count'] as int)) *
                      100 +
                  ((facts['confide_count'] as int) > 0 ? 200 : 0) +
                  ((facts['answer_count'] as int) > 0 ? 200 : 0) +
                  ((facts['followup_count'] as int) > 0 ? 200 : 0),
            );
            final recovering = base + math.min(base, math.max(0, peak - score) ~/ 2);
            score = math.min(1000000, score + math.min(10000, (recovering + bonus).toInt()));
            peak = math.max(peak, score);
            tier = math.max(tier, _affinityTier(score));
          } else {
            var last = _memoryDayDate(original['policy_started_day'] as String).subtract(const Duration(days: 1));
            for (final active in days.keys) {
              final actual = _memoryDayDate(active);
              if (actual.isBefore(day) && actual.isAfter(last)) last = actual;
            }
            if (day.difference(last).inDays >= 4) score = math.max(_affinityFloors[tier], score - 2000);
          }
        }
        _db.execute(
          '''
          UPDATE memory_affinity SET score_milli=?,peak_milli=?,tier=?,floor_milli=?,
            settled_through_day=?,row_rev=row_rev+1 WHERE character_id=?
        ''',
          [score, peak, tier, _affinityFloors[tier], through.toIso8601String().split('T').first, characterId],
        );
        result.add({
          ..._db.select('SELECT * FROM memory_affinity WHERE character_id=?', [characterId]).single,
          'previous_tier': original['tier'],
        });
      }
      return result;
    });
  }

  void _checkAffinityFact(String eventId, int atMs, int offsetMinutes) {
    if (eventId.isEmpty ||
        eventId.trim() != eventId ||
        eventId.length > 1024 ||
        atMs < 0 ||
        atMs > 8640000000000000 - 64800000 ||
        offsetMinutes < -1080 ||
        offsetMinutes > 1080) {
      throw ArgumentError('Invalid companion affinity event');
    }
  }

  void _addAffinityDay(String characterId, int atMs, int offsetMinutes, String column, int amount) {
    if (amount <= 0) return;
    final day = _memoryLocalDay(atMs, offsetMinutes);
    final lastAtMs = column == 'companionship_ms' ? atMs + amount - 1 : atMs;
    _db.execute(
      '''
      INSERT INTO memory_affinity(character_id,policy_started_day,first_met_ms,first_active_day,last_active_day,last_active_at_ms)
        VALUES(?,?,?,?,?,?) ON CONFLICT(character_id) DO UPDATE SET
          first_met_ms=MIN(COALESCE(first_met_ms,excluded.first_met_ms),excluded.first_met_ms),
          first_active_day=MIN(COALESCE(first_active_day,excluded.first_active_day),excluded.first_active_day),
          last_active_day=MAX(COALESCE(last_active_day,excluded.last_active_day),excluded.last_active_day),
          last_active_at_ms=MAX(COALESCE(last_active_at_ms,excluded.last_active_at_ms),excluded.last_active_at_ms)
    ''',
      [characterId, day, atMs, day, day, lastAtMs],
    );
    // column is chosen only from the closed internal map or presence constant.
    _db.execute(
      '''
      INSERT INTO memory_affinity_days(character_id,local_day,offset_minutes,first_at_ms,last_at_ms,$column)
        VALUES(?,?,?,?,?,?) ON CONFLICT(character_id,local_day) DO UPDATE SET
          first_at_ms=MIN(first_at_ms,excluded.first_at_ms),
          last_at_ms=MAX(last_at_ms,excluded.last_at_ms),
          $column=$column+excluded.$column
    ''',
      [characterId, day, offsetMinutes, atMs, lastAtMs, amount],
    );
  }
}

const _companionAffinitySchema16 = '''
CREATE TABLE memory_affinity (
  character_id TEXT PRIMARY KEY REFERENCES memory_characters(id),
  row_rev INTEGER NOT NULL DEFAULT 1,
  score_milli INTEGER NOT NULL DEFAULT 0, tier INTEGER NOT NULL DEFAULT 0,
  floor_milli INTEGER NOT NULL DEFAULT 0, peak_milli INTEGER NOT NULL DEFAULT 0,
  policy_started_day TEXT NOT NULL, first_met_ms INTEGER,
  first_active_day TEXT, last_active_day TEXT, last_active_at_ms INTEGER,
  settled_through_day TEXT
);
CREATE TABLE memory_affinity_days (
  character_id TEXT NOT NULL REFERENCES memory_characters(id), local_day TEXT NOT NULL,
  offset_minutes INTEGER NOT NULL,
  first_at_ms INTEGER NOT NULL, last_at_ms INTEGER NOT NULL,
  companionship_ms INTEGER NOT NULL DEFAULT 0, chat_turns INTEGER NOT NULL DEFAULT 0,
  pet_count INTEGER NOT NULL DEFAULT 0, snack_count INTEGER NOT NULL DEFAULT 0,
  play_count INTEGER NOT NULL DEFAULT 0, confide_count INTEGER NOT NULL DEFAULT 0,
  answer_count INTEGER NOT NULL DEFAULT 0, followup_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(character_id,local_day)
);
CREATE TABLE memory_affinity_presence (
  character_id TEXT NOT NULL REFERENCES memory_characters(id), segment_id TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL, offset_minutes INTEGER NOT NULL, elapsed_ms INTEGER NOT NULL,
  PRIMARY KEY(character_id,segment_id)
);
CREATE TABLE memory_affinity_events (
  character_id TEXT NOT NULL REFERENCES memory_characters(id), kind TEXT NOT NULL,
  event_id TEXT NOT NULL, at_ms INTEGER NOT NULL, offset_minutes INTEGER NOT NULL,
  source_id TEXT REFERENCES memory_messages(id) ON DELETE SET NULL,
  presentation_id TEXT REFERENCES memory_affinity_presentations(id),
  PRIMARY KEY(character_id,kind,event_id)
);
CREATE UNIQUE INDEX memory_affinity_chat_source ON memory_affinity_events(character_id,source_id)
  WHERE kind='chat' AND source_id IS NOT NULL;
CREATE UNIQUE INDEX memory_affinity_semantic_source ON memory_affinity_events(character_id,kind,source_id)
  WHERE kind IN ('confiding','answered_question','answered_followup') AND source_id IS NOT NULL;
CREATE TABLE memory_affinity_presentations (
  id TEXT PRIMARY KEY, character_id TEXT NOT NULL REFERENCES memory_characters(id),
  kind TEXT NOT NULL CHECK(kind IN ('assistant','question','followup')),
  assistant_source_id TEXT REFERENCES memory_messages(id) ON DELETE SET NULL,
  opportunity_id TEXT, presented_at_ms INTEGER NOT NULL
);
CREATE UNIQUE INDEX memory_affinity_question_source ON memory_affinity_presentations(assistant_source_id)
  WHERE kind IN ('assistant','question');
CREATE UNIQUE INDEX memory_affinity_followup_ticket ON memory_affinity_presentations(opportunity_id)
  WHERE kind='followup';
CREATE TABLE memory_affinity_legacy (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  character_id TEXT NOT NULL REFERENCES memory_characters(id), legacy_seed_milli INTEGER NOT NULL
);
CREATE TABLE memory_affinity_legacy_sources (
  source_kind TEXT PRIMARY KEY CHECK(source_kind IN ('phone','host')),
  source_id TEXT NOT NULL, old_value REAL NOT NULL, seed_milli INTEGER NOT NULL,
  old_seed_milli INTEGER NOT NULL, new_seed_milli INTEGER NOT NULL,
  observed_at_ms INTEGER NOT NULL, offset_minutes INTEGER NOT NULL
);
''';
