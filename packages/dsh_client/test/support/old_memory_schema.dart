import 'package:sqlite3/sqlite3.dart';

/// Reconstruct a real previous schema before exercising the production upgrade.
/// Changing only user_version would leave new columns and hide migration bugs.
void restoreOldMemorySchema(Database database, int version) {
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
