import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:dsh_client/dsh_client.dart' show DshProtocolException;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const oldStore = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const oldCard = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const otherCard = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Map<String, Object?> legacyCard({String id = oldCard, String text = '明天去听演出'}) => {
  'id': id,
  'kind': 'fact',
  'text': text,
  'keywords': <String>[],
  'pinned': true,
  'source': {'kind': 'manual'},
  'expiresAt': null,
  'createdAt': 1000,
  'updatedAt': 2000,
};

Map<String, Object?> legacy({int revision = 2, List<Map<String, Object?>>? rows}) => {
  'v': 1,
  'storeId': oldStore,
  'revision': revision,
  'memoryRevision': 2,
  'memories': rows ?? [legacyCard()],
};

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 10000;
  var nextId = 0;
  String createId() => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-memory-');
    database = sqlite3.openInMemory();
    now = 10000;
    nextId = 0;
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: createId);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('missing v1 probe does not create a file or directory', () async {
    final absent = Directory('${directory.path}/absent');
    final local = CompanionLocalStore(appDirectory: absent, nowMilliseconds: () => now);
    expect(await local.probeForMigration(), isNull);
    expect(await absent.exists(), isFalse);
  });

  test('legal empty v1 is distinct from missing and corrupt', () async {
    final local = CompanionLocalStore(appDirectory: directory, nowMilliseconds: () => now);
    await local.companionSnapshot();
    final empty = await local.probeForMigration();
    expect(empty, isNotNull);
    expect(empty!.memories, isEmpty);
    await File('${directory.path}/light-state.json').writeAsString('{');
    await expectLater(local.probeForMigration(), throwsA(isA<DshRemoteException>()));
  });

  test('bad or partial remote snapshot never becomes a smaller successful import', () {
    for (final broken in [
      {...legacy()}..remove('memories'),
      {...legacy()}..remove('memoryRevision'),
      legacy(
        rows: [
          legacyCard(),
          legacyCard(id: otherCard)..remove('createdAt'),
        ],
      ),
      legacy(rows: [legacyCard()..['createdAt'] = 9007199254740991]),
      legacy(
        rows: [
          legacyCard()..['source'] = {'kind': 'automatic'},
        ],
      ),
      legacy(
        rows: [
          legacyCard(),
          legacyCard(id: oldCard.toUpperCase()),
        ],
      ),
    ]) {
      expect(() => CompanionMigrationSnapshot.fromJson(broken), throwsA(isA<DshProtocolException>()));
      expect(store.cards(), isEmpty);
      expect(store.migrationCleanup(), isEmpty);
    }
  });

  test('migration is idempotent and does not manufacture a relative date or reality', () {
    final read = CompanionMigrationSnapshot.fromJson(legacy());
    final ids = store.importLegacy(read);
    expect(store.verifyLegacyImport(read, ids), isTrue);
    store.importLegacy(read);
    final row = store.cards().single;
    expect(row['text'], '明天去听演出');
    expect(row['eligible'], isFalse);
    expect(row['event_time'], isNull);
    expect(row['followup'], isNull);
    expect(row['current_basis_seq'], isNull);
    expect(row['evidence'], isEmpty);
    expect(store.migrationCleanup(), hasLength(1));
  });

  test('legacy UUID casing does not create a second identity', () {
    store.importLegacy(CompanionMigrationSnapshot.fromJson(legacy()));
    final upper = legacy(rows: [legacyCard(id: oldCard.toUpperCase())]);
    upper['storeId'] = oldStore.toUpperCase();
    store.importLegacy(CompanionMigrationSnapshot.fromJson(upper));
    expect(store.cards(), hasLength(1));
    expect(store.migrationCleanup(), hasLength(1));
  });

  test('one failed imported row rolls back all cards, topics and migration receipts', () {
    database.execute("""
      CREATE TRIGGER fail_import BEFORE INSERT ON memory_cards
      WHEN NEW.text = 'synthetic failure' BEGIN SELECT RAISE(ABORT, 'fixture'); END
    """);
    final read = CompanionMigrationSnapshot.fromJson(
      legacy(
        rows: [
          legacyCard(),
          legacyCard(id: otherCard, text: 'synthetic failure'),
        ],
      ),
    );
    expect(() => store.importLegacy(read), throwsA(isA<SqliteException>()));
    expect(store.cards(), isEmpty);
    expect(store.migrationCleanup(), isEmpty);
    expect(database.select('SELECT * FROM memory_topics'), isEmpty);
    expect(store.archive['memory_revision'], 0);
  });

  test('only proved reality is eligible and same-ID reconnection cannot overwrite a local edit', () {
    final read = CompanionMigrationSnapshot.fromJson(legacy());
    store.importLegacy(read, realityKnownIds: {oldCard});
    final row = store.cards().single;
    expect(row['eligible'], isTrue);
    store.saveManual(
      CompanionMemory(id: row['id']! as String, text: '演出已经取消'),
      expectedRowRev: 1,
      currentValueChange: true,
      realityKnown: true,
    );
    final changedRemote = CompanionMigrationSnapshot.fromJson(legacy(revision: 3, rows: [legacyCard(text: '另一份旧内容')]));
    expect(store.importLegacy(changedRemote), isEmpty);
    expect(store.cards().single['text'], '演出已经取消');
    expect(store.migrationCleanup().single['cleanup_state'], 'pending');
  });

  test('readback fails if an imported card is missing before source cleanup', () {
    final read = CompanionMigrationSnapshot.fromJson(legacy());
    final ids = store.importLegacy(read);
    database.execute('DELETE FROM memory_cards');
    expect(store.verifyLegacyImport(read, ids), isFalse);
  });

  test('conditional local migration removes only imported cards and preserves vitals', () async {
    final local = CompanionLocalStore(appDirectory: directory, nowMilliseconds: () => now);
    final initial = await local.companionSnapshot();
    final revision = await local.saveCompanionMemory(
      initial.storeId,
      initial.revision,
      const CompanionMemory(id: oldCard, text: '合成旧手记'),
    );
    await local.saveCompanionMemory(initial.storeId, revision, const CompanionMemory(id: otherCard, text: '留在旧库'));
    final read = (await local.probeForMigration())!;
    final file = File('${directory.path}/light-state.json');
    final before = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    store.importLegacy(read);
    expect(store.verifyLegacyImport(read, [oldCard]), isTrue);
    await local.removeMigratedMemories(read.storeId, read.revision, {oldCard});
    store.finishLegacyCleanup(read.storeId, [oldCard], expectedReadRevision: read.revision);
    final after = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(after['state'], before['state']);
    expect(after['storeId'], before['storeId']);
    expect((after['memories'] as List).single['id'], otherCard);
    expect(store.migrationCleanup().map((r) => r['legacy_card_id']), [otherCard]);
  });

  test('external r+1 stops local cleanup without erasing the new row', () async {
    final local = CompanionLocalStore(appDirectory: directory, nowMilliseconds: () => now);
    final initial = await local.companionSnapshot();
    await local.saveCompanionMemory(
      initial.storeId,
      initial.revision,
      const CompanionMemory(id: oldCard, text: '先前读到的内容'),
    );
    final read = (await local.probeForMigration())!;
    store.importLegacy(read);
    await local.saveCompanionMemory(read.storeId, read.revision, const CompanionMemory(id: oldCard, text: '刚刚修改的内容'));
    await expectLater(
      local.removeMigratedMemories(read.storeId, read.revision, {oldCard}),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/conflict')),
    );
    expect((await local.companionMemories()).memories.single.text, '刚刚修改的内容');
  });

  test('only exact conditional delete acknowledgements advance the host revision', () {
    final read = CompanionMigrationSnapshot.fromJson(
      legacy(
        rows: [
          legacyCard(),
          legacyCard(id: otherCard),
        ],
      ),
    );
    final receipt = {'v': 1, 'storeId': oldStore, 'revision': 3, 'memoryRevision': 3, 'deleted': true};
    final next = read.afterDeletion(oldCard, receipt);
    expect(next.revision, 3);
    expect(next.memories.single.id, otherCard);
    for (final bad in [
      {'revision': 3},
      {...receipt, 'storeId': otherCard},
      {...receipt, 'revision': 4},
      {...receipt, 'memoryRevision': 2},
      {...receipt}..remove('deleted'),
    ]) {
      expect(() => read.afterDeletion(oldCard, bad), throwsA(isA<DshProtocolException>()));
    }
  });

  test('manual current values use the archive sequence; pinning does not create a statement', () {
    store.saveManual(
      const CompanionMemory(id: oldCard, text: '我喝无糖咖啡'),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    final first = store.cards().single;
    now++;
    store.saveManual(
      const CompanionMemory(id: oldCard, text: '我喝无糖咖啡', pinned: true),
      expectedRowRev: 1,
      currentValueChange: false,
      realityKnown: true,
    );
    expect(store.cards().single['current_basis_seq'], first['current_basis_seq']);
    store.saveManual(
      const CompanionMemory(id: oldCard, text: '我喝半糖咖啡', pinned: true),
      expectedRowRev: 2,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(store.cards().single['current_basis_seq'], greaterThan(first['current_basis_seq']! as int));
    expect(
      () => store.saveManual(
        const CompanionMemory(id: oldCard, text: '旧编辑框'),
        expectedRowRev: 2,
        currentValueChange: true,
        realityKnown: true,
      ),
      throwsA(isA<DshRemoteException>()),
    );
  });

  test('manual writes reject malformed user text before changing the database', () {
    for (final memory in [
      const CompanionMemory(id: oldCard, text: 'bad\u0000text'),
      CompanionMemory(id: oldCard, text: String.fromCharCode(0xd800)),
      const CompanionMemory(id: 'not-an-id', text: '可见文字'),
      const CompanionMemory(id: oldCard, text: '   '),
    ]) {
      expect(
        () => store.saveManual(memory, expectedRowRev: null, currentValueChange: true, realityKnown: true),
        throwsA(isA<DshRemoteException>()),
      );
    }
    now = -1;
    expect(
      () => store.saveManual(
        const CompanionMemory(id: oldCard, text: '合成文字'),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      ),
      throwsA(isA<DshRemoteException>()),
    );
    expect(store.cards(), isEmpty);
    expect(store.archive['next_seq'], 1);
  });

  test('pinning a stored past or withdrawn automatic card does not revive or confirm it', () {
    store.saveManual(
      const CompanionMemory(id: oldCard, text: '以前喝半糖'),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    for (final status in ['past', 'withdrawn']) {
      database.execute('UPDATE memory_cards SET status=?, manual=0, eligible=0 WHERE id=?', [status, oldCard]);
      final row = store.cards(includeInactive: true).single;
      store.saveManual(
        const CompanionMemory(id: oldCard, text: '以前喝半糖', pinned: true),
        expectedRowRev: row['row_rev']! as int,
        currentValueChange: false,
        realityKnown: true,
      );
      final saved = store.cards(includeInactive: true).single;
      expect(saved['status'], status);
      expect(saved['manual'], isFalse);
      expect(saved['eligible'], isFalse);
      expect(saved['current_basis_seq'], row['current_basis_seq']);
    }
  });

  test('archive identity and migration receipts survive closing and reopening', () {
    store.close();
    final path = '${directory.path}/memory.sqlite';
    store = CompanionMemoryStore(sqlite3.open(path), nowMilliseconds: () => now, createId: createId);
    final identity = store.archive['id'];
    final read = CompanionMigrationSnapshot.fromJson(legacy());
    store.importLegacy(read);
    store.close();
    store = CompanionMemoryStore(sqlite3.open(path), nowMilliseconds: () => now, createId: createId);
    expect(store.archive['id'], identity);
    store.importLegacy(read);
    expect(store.cards(), hasLength(1));
    expect(store.migrationCleanup(), hasLength(1));
  });
}
