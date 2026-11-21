import 'package:sqlite3/sqlite3.dart';

/// Reconstruct a real previous schema before exercising the production upgrade.
/// Changing only user_version would leave new columns and hide migration bugs.
void restoreOldMemorySchema(Database database, int version) {
  for (final table in ['memory_initiative_spends', 'memory_followups', 'memory_initiative_state']) {
    database.execute('DROP TABLE $table');
  }
  database.execute('ALTER TABLE memory_archive DROP COLUMN followup_after_seq');
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
