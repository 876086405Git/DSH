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

    // Create all three facts before quieting them. The private control has the
    // same literal word as one imported fact, but imports belong to shared/null.
    final character = store.ensureCompanionCharacter(sourceKey: 'local:legacy-controls')['id']! as String;
    final source = store.submitMessage(
      id: 'legacy-controls',
      sessionId: 'light:legacy-controls',
      text: '我们周五复诊，我喝咖啡不加糖，也在烧陶杯。',
      saidAtUtc: now,
      offsetMinutes: 0,
      characterId: character,
    );
    final turn = store.beginAgentTurn(
      messageId: source['id']! as String,
      expectedSourceRev: source['source_rev']! as int,
      shownCardRevisions: const {},
    )['id']! as String;
    final private = store.applyAgentMemoryTool(turnId: turn, callId: 'private', toolName: 'remember', input: {
      'collection': 'our_story',
      'text': '我们周五复诊。',
      'keywords': ['复诊'],
    });
    final coffee = store.applyAgentMemoryTool(turnId: turn, callId: 'coffee', toolName: 'remember', input: {
      'text': '我喝咖啡不加糖。',
      'keywords': ['咖啡'],
    });
    final pottery = store.applyAgentMemoryTool(turnId: turn, callId: 'pottery', toolName: 'remember', input: {
      'text': '我在烧陶杯。',
      'keywords': ['陶杯'],
    });
    expect(private.applied, isTrue);
    expect(coffee.applied, isTrue);
    expect(pottery.applied, isTrue);
    expect(store.applyAgentMemoryTool(turnId: turn, callId: 'quiet-private', toolName: 'quiet', input: {
      'card': private.targetId,
      'mode': 'never',
    }).applied, isTrue);
    expect(store.applyAgentMemoryTool(turnId: turn, callId: 'quiet-coffee', toolName: 'quiet', input: {
      'card': coffee.targetId,
      'mode': 'never',
    }).applied, isTrue);
    expect(store.applyAgentMemoryTool(turnId: turn, callId: 'quiet-pottery', toolName: 'quiet', input: {
      'card': pottery.targetId,
      'mode': 'less',
    }).applied, isTrue);
    store.closeAgentTurn(turn);
    final beforeCards = {for (final card in store.cards(includeInactive: true)) card['id']: card};
    final beforeControls = store.topicControls();
    final privateTopic = beforeCards[private.targetId]!['topic_id'];
    final coffeeTopic = beforeCards[coffee.targetId]!['topic_id'];
    final potteryTopic = beforeCards[pottery.targetId]!['topic_id'];
    final stampId = createId(), coffeeId = createId(), potteryId = createId(), clinicId = createId();
    final inheritedRead = CompanionMigrationSnapshot.fromJson(legacy(revision: 3, rows: [
      legacyCard(),
      legacyCard(id: stampId, text: '我收集邮票。'),
      legacyCard(id: coffeeId, text: '我早上喝咖啡。'),
      legacyCard(id: potteryId, text: '我周末烧陶杯。'),
      legacyCard(id: clinicId, text: '我下周复诊。'),
    ]));
    final realityIds = {stampId, coffeeId, potteryId, clinicId};
    final inheritedIds = store.importLegacy(inheritedRead, realityKnownIds: realityIds);
    expect(inheritedIds, unorderedEquals([oldCard, stampId, coffeeId, potteryId, clinicId]));
    expect(store.verifyLegacyImport(inheritedRead, inheritedIds), isTrue);
    final mappings = {for (final mapping in store.migrationCleanup()) mapping['legacy_card_id']: mapping};
    final importedCards = {for (final card in store.cards(includeInactive: true)) card['id']: card};
    final stamp = importedCards[mappings[stampId]!['local_card_id']]!;
    final importedCoffee = importedCards[mappings[coffeeId]!['local_card_id']]!;
    final importedPottery = importedCards[mappings[potteryId]!['local_card_id']]!;
    final clinic = importedCards[mappings[clinicId]!['local_card_id']]!;
    expect(stamp['topic_mode'], 'normal');
    expect(importedCoffee['topic_id'], coffeeTopic);
    expect(importedCoffee['topic_mode'], 'never');
    expect(importedPottery['topic_id'], potteryTopic);
    expect(importedPottery['topic_mode'], 'less');
    expect(clinic['topic_mode'], 'normal');
    expect(clinic['topic_id'], isNot(privateTopic));
    expect(clinic['topic_id'], isNot(stamp['topic_id']));
    final imported = [stamp, importedCoffee, importedPottery, clinic];
    expect(imported.map((card) => card['collection']), everyElement('about_you'));
    expect(imported.map((card) => card['character_id']), everyElement(isNull));
    expect(imported.map((card) => card['eligible']), everyElement(isTrue));
    expect(imported.map((card) => card['manual']), everyElement(isTrue));
    expect(imported.map((card) => card['pinned']), everyElement(isTrue));
    expect(imported.map((card) => card['event_time']), everyElement(isNull));
    expect(imported.map((card) => card['followup']), everyElement(isNull));
    expect(imported.map((card) => card['current_basis_seq']), everyElement(isNull));
    expect(imported.map((card) => card['evidence']), everyElement(isEmpty));
    expect(store.topicControls(), beforeControls);
    expect({for (final id in beforeCards.keys) id: importedCards[id]}, beforeCards);
    final afterImport = store.cards(includeInactive: true);
    final afterMappings = store.migrationCleanup();
    final afterArchive = store.archive;
    expect(store.importLegacy(inheritedRead, realityKnownIds: realityIds), inheritedIds);
    expect(store.cards(includeInactive: true), afterImport);
    expect(store.migrationCleanup(), afterMappings);
    expect(store.archive, afterArchive);
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

    // The original trigger remains, but these real controls reject the later
    // batch through the public migration error, not through its synthetic text.
    final source = store.submitMessage(
      id: 'legacy-conflict-controls',
      sessionId: 'light:legacy-controls',
      text: '修琴周六完成，陶杯周日烧好。',
      saidAtUtc: now,
      offsetMinutes: 0,
    );
    final turn = store.beginAgentTurn(
      messageId: source['id']! as String,
      expectedSourceRev: source['source_rev']! as int,
      shownCardRevisions: const {},
    )['id']! as String;
    final music = store.applyAgentMemoryTool(turnId: turn, callId: 'music', toolName: 'remember', input: {
      'text': '修琴周六完成。',
      'keywords': ['修琴'],
    });
    final pottery = store.applyAgentMemoryTool(turnId: turn, callId: 'pottery', toolName: 'remember', input: {
      'text': '陶杯周日烧好。',
      'keywords': ['陶杯'],
    });
    expect(music.applied, isTrue);
    expect(pottery.applied, isTrue);
    expect(store.applyAgentMemoryTool(turnId: turn, callId: 'quiet-music', toolName: 'quiet', input: {
      'card': music.targetId,
      'mode': 'never',
    }).applied, isTrue);
    expect(store.applyAgentMemoryTool(turnId: turn, callId: 'quiet-pottery', toolName: 'quiet', input: {
      'card': pottery.targetId,
      'mode': 'less',
    }).applied, isTrue);
    store.closeAgentTurn(turn);
    final mappedRead = CompanionMigrationSnapshot.fromJson(legacy(rows: [legacyCard(text: '旧书架旁有台灯。')]));
    final mappedIds = store.importLegacy(mappedRead, realityKnownIds: {oldCard});
    final mapping = store.migrationCleanup().single;
    final mappedCard = store.cards().singleWhere((card) => card['id'] == mapping['local_card_id']);
    final newId = createId(), conflictId = createId();
    final conflictedRead = CompanionMigrationSnapshot.fromJson(legacy(revision: 3, rows: [
      legacyCard(text: '旧书架旁有台灯。'),
      legacyCard(id: newId, text: '我收集邮票。'),
      legacyCard(id: conflictId, text: '修琴和陶杯都安排在周末。'),
    ]));
    final realityIds = {oldCard, newId, conflictId};
    final beforeCards = store.cards(includeInactive: true);
    final beforeControls = store.topicControls();
    final beforeArchive = store.archive;
    final beforeCleanup = store.migrationCleanup();
    expect(() => store.importLegacy(conflictedRead, realityKnownIds: realityIds), throwsA(
      isA<DshRemoteException>()
          .having((error) => error.code, 'code', 'companion/invalid-request')
          .having((error) => error.details['status'], 'status', 400)
          .having((error) => error.details['reason'], 'reason', 'ambiguous_controlled_topic'),
    ));
    expect(store.cards(includeInactive: true), beforeCards);
    expect(store.topicControls(), beforeControls);
    expect(store.archive, beforeArchive);
    expect(store.migrationCleanup(), beforeCleanup);
    expect(store.migrationCleanup().single['cleanup_read_revision'], mappedRead.revision);

    // Restore one real control through a new source and current card grant.
    // Retrying the exact same snapshot must keep the original legacy identity.
    final allowed = store.submitMessage(
      id: 'legacy-pottery-allowed',
      sessionId: 'light:legacy-controls',
      text: '以后可以聊陶杯了。',
      saidAtUtc: now,
      offsetMinutes: 0,
    );
    final currentPottery = store.cards().singleWhere((card) => card['id'] == pottery.targetId);
    final restoring = store.beginAgentTurn(
      messageId: allowed['id']! as String,
      expectedSourceRev: allowed['source_rev']! as int,
      shownCardRevisions: {pottery.targetId!: currentPottery['row_rev']! as int},
    )['id']! as String;
    final restored = store.applyAgentMemoryTool(turnId: restoring, callId: 'normal-pottery', toolName: 'quiet', input: {
      'card': pottery.targetId,
      'mode': 'normal',
    });
    expect(restored.applied, isTrue);
    expect(restored.targetId, currentPottery['topic_id']);
    expect(restored.changedCardIds, [pottery.targetId]);
    store.closeAgentTurn(restoring);
    final remainingControls = store.topicControls();
    final retriedIds = store.importLegacy(conflictedRead, realityKnownIds: realityIds);
    expect(retriedIds, unorderedEquals([oldCard, newId, conflictId]));
    expect(store.verifyLegacyImport(conflictedRead, retriedIds), isTrue);
    final retriedMappings = {for (final row in store.migrationCleanup()) row['legacy_card_id']: row};
    expect(retriedMappings[oldCard]!['local_card_id'], mapping['local_card_id']);
    expect(retriedMappings[oldCard]!['source_fingerprint'], mapping['source_fingerprint']);
    expect(retriedMappings[oldCard]!['read_revision'], mappedRead.revision);
    expect(retriedMappings.values.map((row) => row['cleanup_read_revision']), everyElement(conflictedRead.revision));
    final retriedCards = {for (final card in store.cards(includeInactive: true)) card['id']: card};
    expect(retriedCards[mapping['local_card_id']], mappedCard);
    expect(retriedCards[retriedMappings[newId]!['local_card_id']]!['topic_mode'], 'normal');
    expect(retriedCards[retriedMappings[conflictId]!['local_card_id']]!['topic_id'], retriedCards[music.targetId]!['topic_id']);
    expect(retriedCards[retriedMappings[conflictId]!['local_card_id']]!['topic_mode'], 'never');
    expect(store.topicControls(), remainingControls);
    final afterRetryCards = store.cards(includeInactive: true);
    final afterRetryCleanup = store.migrationCleanup();
    final afterRetryArchive = store.archive;
    expect(store.importLegacy(conflictedRead, realityKnownIds: realityIds), retriedIds);
    expect(store.cards(includeInactive: true), afterRetryCards);
    expect(store.migrationCleanup(), afterRetryCleanup);
    expect(store.archive, afterRetryArchive);
    store.finishLegacyCleanup(oldStore, mappedIds, expectedReadRevision: mappedRead.revision);
    expect(store.migrationCleanup(), afterRetryCleanup);
    store.finishLegacyCleanup(oldStore, retriedIds, expectedReadRevision: conflictedRead.revision);
    expect(store.migrationCleanup(), isEmpty);
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
