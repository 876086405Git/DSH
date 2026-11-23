import 'package:sqlite3/sqlite3.dart';

/// Reconstruct a real previous schema before exercising the production upgrade.
/// Changing only user_version would leave new columns and hide migration bugs.
void restoreOldMemorySchema(Database database, int version) {
  if (version < 17) {
    // Rebuild both CHECK constraints and keep the v16 card dependents/triggers intact.
    final triggers = database.select("SELECT sql FROM sqlite_schema WHERE type='trigger' AND tbl_name='memory_cards'");
    database.execute('PRAGMA foreign_keys=OFF');
    try {
      database.execute('BEGIN');
      database.execute('DROP TABLE memory_notice_sources');
      database.execute('DROP TABLE memory_notice_tombstones');
      database.execute('DROP TABLE memory_notice_spends');
      database.execute(_schema16Checks);
      for (final row in triggers) {
        database.execute(row['sql'] as String);
      }
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    } finally {
      database.execute('PRAGMA foreign_keys=ON');
    }
  }
  if (version < 16) {
    if (database.select('SELECT 1 FROM memory_characters LIMIT 1').isNotEmpty) {
      throw StateError('A pre-role fixture cannot contain character-scoped data');
    }
    database.execute(
      'CREATE TEMP TABLE fixture_turns15 AS SELECT id,source_message_id,source_rev,'
      'control_revision,shown_cards,changed_cards,closed FROM memory_agent_turns WHERE origin_kind=\'chat\'',
    );
    database.execute(
      'CREATE TEMP TABLE fixture_calls15 AS SELECT c.* FROM memory_agent_calls c '
      'JOIN fixture_turns15 t ON t.id=c.turn_id',
    );
    database.execute('DROP TABLE memory_agent_maintenance_requests');
    database.execute('DROP TABLE memory_agent_calls');
    database.execute('DROP TABLE memory_agent_turns');
    database.execute('DROP TABLE memory_agent_maintenance_claims');
    database.execute('''
CREATE TABLE memory_agent_turns (
  id TEXT PRIMARY KEY,
  source_message_id TEXT NOT NULL REFERENCES memory_messages(id) ON DELETE CASCADE,
  source_rev INTEGER NOT NULL, control_revision INTEGER NOT NULL,
  shown_cards TEXT NOT NULL, changed_cards TEXT NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0 CHECK(closed IN (0,1)),
  UNIQUE(source_message_id,source_rev)
);
CREATE TABLE memory_agent_calls (
  turn_id TEXT NOT NULL REFERENCES memory_agent_turns(id) ON DELETE CASCADE,
  call_id TEXT NOT NULL, tool_name TEXT NOT NULL, input_sha256 TEXT NOT NULL,
  item_no INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','applied','ignored','accepted')),
  code TEXT, target_id TEXT, changed_cards TEXT NOT NULL,
  before_control_revision INTEGER NOT NULL, after_control_revision INTEGER NOT NULL,
  task_id TEXT, task_rev INTEGER,
  PRIMARY KEY(turn_id,call_id)
);
    ''');
    database.execute('INSERT INTO memory_agent_turns SELECT * FROM fixture_turns15');
    database.execute('INSERT INTO memory_agent_calls SELECT * FROM fixture_calls15');
    database.execute('DROP TABLE fixture_calls15');
    database.execute('DROP TABLE fixture_turns15');
    database.execute('DROP TRIGGER memory_embeddings_revision');
    for (final table in [
      'memory_embeddings',
      'memory_person_aliases',
      'memory_card_references',
      'memory_affinity_events',
      'memory_affinity_presentations',
      'memory_affinity_presence',
      'memory_affinity_days',
      'memory_affinity_legacy_sources',
      'memory_affinity_legacy',
      'memory_affinity',
    ]) {
      database.execute('DROP TABLE $table');
    }
    for (final index in [
      'memory_cards_domain',
      'memory_messages_character',
      'memory_diary_day',
      'memory_impression_character',
    ]) {
      database.execute('DROP INDEX $index');
    }
    // Drop the columns carrying CHECKs before their referenced collection.
    for (final column in ['day_zone_id', 'local_day', 'character_id', 'collection']) {
      database.execute('ALTER TABLE memory_cards DROP COLUMN $column');
    }
    database.execute('ALTER TABLE memory_topics DROP COLUMN character_id');
    database.execute('ALTER TABLE memory_messages DROP COLUMN character_id');
    database.execute('DROP TABLE memory_characters');
  }
  if (version < 15) {
    database.execute('DROP TABLE memory_agent_calls');
    database.execute('DROP TABLE memory_agent_turns');
    database.execute('ALTER TABLE memory_followups DROP COLUMN agent_origin');
  }
  if (version < 14) {
    database.execute('DROP TABLE companion_map_scopes');
    database.execute('DROP TABLE companion_map_revisions');
  }
  if (version < 13) {
    database.execute('DROP TABLE companion_host_commands');
    database.execute('DROP TABLE companion_host_tasks');
  }
  if (version < 12) {
    database.execute('DROP TABLE companion_lookup_attempts');
    for (final column in [
      'lookup_place_name',
      'lookup_city',
      'lookup_question',
      'lookup_deadline_ms',
      'lookup_result_json',
      'lookup_result_fingerprint',
    ]) {
      database.execute('ALTER TABLE companion_task_revisions DROP COLUMN $column');
    }
  }
  if (version < 11) {
    database.execute('DROP TABLE companion_task_receipts');
    database.execute('DROP TABLE companion_task_revisions');
    database.execute('DROP TABLE companion_tasks');
    database.execute('ALTER TABLE memory_messages DROP COLUMN zone_id');
    database.execute('ALTER TABLE memory_messages DROP COLUMN offset_seconds');
  }
  if (version < 10) {
    database.execute('DROP TABLE memory_card_cleanup_sources');
    database.execute('ALTER TABLE memory_cards DROP COLUMN cleanup_history_complete');
  }
  if (version < 9) database.execute('ALTER TABLE memory_topics DROP COLUMN control_anchors');
  if (version < 8) {
    database.execute('DROP TABLE memory_merge_batches');
    database.execute('ALTER TABLE memory_cards DROP COLUMN maintenance_row_rev');
  }
  if (version < 7) {
    database.execute('''
      CREATE TABLE memory_requests_v6 (
        id TEXT PRIMARY KEY, category TEXT NOT NULL CHECK(category IN ('chat','extract','organize')),
        batch_id TEXT, provider TEXT NOT NULL, model TEXT NOT NULL, reserved_at_ms INTEGER NOT NULL,
        sent_at_ms INTEGER, reserved_input INTEGER NOT NULL, reserved_output INTEGER NOT NULL,
        reserved_cny REAL, raw_usage TEXT, usage_semantics TEXT, input_uncached INTEGER,
        input_cache_read INTEGER, input_cache_write INTEGER, output_tokens INTEGER,
        estimated_cny REAL, state TEXT NOT NULL, terminal TEXT, uncertain_at_ms INTEGER
      );
      INSERT INTO memory_requests_v6 SELECT * FROM memory_requests;
      DROP TABLE memory_requests;
      ALTER TABLE memory_requests_v6 RENAME TO memory_requests;
    ''');
  }
  if (version < 6) {
    for (final table in ['memory_initiative_spends', 'memory_followups', 'memory_initiative_state']) {
      database.execute('DROP TABLE $table');
    }
    database.execute('ALTER TABLE memory_archive DROP COLUMN followup_after_seq');
  }
  if (version < 5) {
    database.execute('ALTER TABLE memory_migrations DROP COLUMN source_fingerprint');
    database.execute('ALTER TABLE memory_migrations DROP COLUMN cleanup_read_revision');
  }
  if (version < 4) {
    database.execute('DROP TABLE memory_host_chat_delivery_receipts');
    database.execute('DROP TABLE memory_host_chat_receipts');
    database.execute('DROP TABLE memory_host_chat_deliveries');
  }
  if (version < 3) database.execute('DROP TABLE memory_deleted_messages');
  database.execute('PRAGMA user_version=$version');
}

const _schema16Checks = '''
CREATE TABLE memory_cards_v16 (
  id TEXT PRIMARY KEY, row_rev INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('fact','preference','episode')), text TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]', pinned INTEGER NOT NULL DEFAULT 0,
  scope TEXT NOT NULL DEFAULT 'real' CHECK(scope IN ('real','story')), eligible INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'current' CHECK(status IN ('current','past','withdrawn')),
  manual INTEGER NOT NULL, topic_id TEXT NOT NULL REFERENCES memory_topics(id), current_basis_seq INTEGER,
  source_at_ms INTEGER NOT NULL, event_time TEXT, followup TEXT, plan_state TEXT,
  created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, expires_at_ms INTEGER,
  maintenance_row_rev INTEGER NOT NULL DEFAULT 0, cleanup_history_complete INTEGER NOT NULL DEFAULT 0,
  collection TEXT NOT NULL DEFAULT 'about_you'
    CHECK(collection IN ('about_you','person','our_story','diary','impression')),
  character_id TEXT REFERENCES memory_characters(id)
    CHECK((collection IN ('about_you','person','diary') AND character_id IS NULL)
       OR (collection IN ('our_story','impression') AND character_id IS NOT NULL)),
  local_day TEXT CHECK(collection!='diary' OR local_day IS NOT NULL),
  day_zone_id TEXT CHECK(collection!='diary' OR day_zone_id IS NOT NULL)
);
INSERT INTO memory_cards_v16 SELECT * FROM memory_cards;
DROP TABLE memory_cards;
ALTER TABLE memory_cards_v16 RENAME TO memory_cards;
CREATE INDEX memory_cards_domain ON memory_cards(character_id,collection,status);
CREATE UNIQUE INDEX memory_diary_day ON memory_cards(local_day) WHERE collection='diary';
CREATE UNIQUE INDEX memory_impression_character ON memory_cards(character_id) WHERE collection='impression';
CREATE TABLE memory_requests_v16 (
  id TEXT PRIMARY KEY, category TEXT NOT NULL CHECK(category IN ('chat','extract','organize','followup')),
  batch_id TEXT, provider TEXT NOT NULL, model TEXT NOT NULL, reserved_at_ms INTEGER NOT NULL,
  sent_at_ms INTEGER, reserved_input INTEGER NOT NULL, reserved_output INTEGER NOT NULL,
  reserved_cny REAL, raw_usage TEXT, usage_semantics TEXT, input_uncached INTEGER,
  input_cache_read INTEGER, input_cache_write INTEGER, output_tokens INTEGER,
  estimated_cny REAL, state TEXT NOT NULL, terminal TEXT, uncertain_at_ms INTEGER
);
INSERT INTO memory_requests_v16 SELECT * FROM memory_requests;
DROP TABLE memory_requests;
ALTER TABLE memory_requests_v16 RENAME TO memory_requests;
''';
