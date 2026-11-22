import 'dart:io';

import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('real schema17 populated audit/memory fixture upgrades losslessly and keeps FK cascade', () async {
    final directory = await Directory.systemTemp.createTemp('spreset-schema18-');
    final file = await File('test/fixtures/spreset/schema17.sqlite3').copy('${directory.path}/chat.sqlite3');
    final db = sqlite3.open(file.path);
    expect(db.select('PRAGMA user_version').single['user_version'], 17);
    expect(
      db.select("SELECT sql FROM sqlite_master WHERE name='tool_requests'").single['sql'],
      contains('BETWEEN 1 AND 4'),
    );
    final tables = ['tool_turns', 'tool_requests', 'tool_receipts', 'memory_proposals', 'memory_decisions', 'memories'];
    final before = {
      for (final table in tables)
        table: [for (final row in db.select('SELECT * FROM $table')) Map<String, Object?>.from(row)],
    };
    expect(before.values.every((rows) => rows.length == 1), isTrue);
    final store = ChatStore.fromDatabase(db);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    expect(db.select('PRAGMA user_version').single['user_version'], 18);
    expect(db.select('PRAGMA foreign_keys').single['foreign_keys'], 1);
    expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    for (final table in tables) {
      final after = [for (final row in db.select('SELECT * FROM $table')) Map<String, Object?>.from(row)];
      if (table == 'tool_turns') {
        expect(after.single.remove('request_budget'), 4);
      }
      expect(after, before[table], reason: '$table must survive byte-for-byte fields');
    }
    // The expanded CHECK is exercised on the migrated table, not only a fresh
    // database. The unique turn/index identity and audit columns remain real.
    final fifth = {...before['tool_requests']!.single, 'id': 'fixture-request-5', 'request_index': 5};
    final keys = fifth.keys.toList();
    db.execute(
      'INSERT INTO tool_requests (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})',
      fifth.values.toList(),
    );
    expect(
      db.select('SELECT request_index FROM tool_requests ORDER BY request_index').map((row) => row['request_index']),
      [1, 5],
    );
    expect(
      () => db.execute(
        'INSERT INTO tool_requests (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})',
        {...fifth, 'id': 'duplicate-index'}.values.toList(),
      ),
      throwsA(isA<SqliteException>()),
    );
    store.deleteChat('legacy-chat');
    for (final table in tables) {
      expect(db.select('SELECT * FROM $table'), isEmpty);
    }
    expect(db.select('PRAGMA foreign_key_check'), isEmpty);
  });
}
