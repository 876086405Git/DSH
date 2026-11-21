import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:dsh_client/dsh_client.dart' show DshClient, DshConnection, DshCookie, DshProtocolException;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

const _oldStore = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _oldCard = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _otherCard = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _originalText = '合成记录：周末听演出 🎼';

Map<String, Object?> _card({String id = _oldCard, String text = _originalText}) => {
  'id': id,
  'kind': 'fact',
  'text': text,
  'keywords': ['旧源', '演出'],
  'pinned': true,
  'source': {'kind': 'manual'},
  'expiresAt': null,
  'createdAt': 1000,
  'updatedAt': 2000,
};

Map<String, Object?> _wire({int revision = 2, int memoryRevision = 2, List<Map<String, Object?>>? cards}) => {
  'v': 1,
  'storeId': _oldStore,
  'revision': revision,
  'memoryRevision': memoryRevision,
  'memories': cards ?? [_card()],
};

CompanionMigrationSnapshot _read({int revision = 2, List<Map<String, Object?>>? cards}) =>
    CompanionMigrationSnapshot.fromJson(_wire(revision: revision, cards: cards));

Map<String, Object?> _ack(int revision, int memoryRevision) => {
  'v': 1,
  'storeId': _oldStore,
  'revision': revision,
  'memoryRevision': memoryRevision,
  'deleted': true,
};

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var nextId = 0;
  var now = 10000;
  String createId() => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: createId);
  }

  void reopen() {
    store.close();
    open();
  }

  Map<String, Object?> mapping([String id = _oldCard]) => Map<String, Object?>.from(
    database.select('SELECT * FROM memory_migrations WHERE legacy_store_id=? AND legacy_card_id=?', [
      _oldStore,
      id,
    ]).single,
  );

  void reopenFromV4() {
    restoreOldMemorySchema(database, 4);
    reopen();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-migration-recovery-');
    nextId = 0;
    now = 10000;
    open();
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('strict snapshot freezes each keyword list as well as the outer list', () {
    final input = _wire();
    final snapshot = CompanionMigrationSnapshot.fromJson(input);
    expect(() => snapshot.memories.clear(), throwsUnsupportedError);
    expect(() => snapshot.memories.single.keywords[0] = '改写', throwsUnsupportedError);
    final rows = input['memories']! as List<Map<String, Object?>>;
    (rows.single['keywords']! as List<String>)[0] = '原 JSON 后续变更';
    expect(snapshot.memories.single.keywords, ['旧源', '演出']);
  });

  test('fingerprint uses a fixed complete-source Unicode vector without storing the text', () {
    store.importLegacy(_read());
    final receipt = mapping();
    // Independently computed using Python hashlib.sha256 over the documented
    // UTF-8 JSON tuple; this expected value does not call the Dart hash helper.
    expect(receipt['source_fingerprint'], 'sha256-v1:298541073299e45ff7571324f61cdc0d0ec20b90a8e66c5b452938c13daf9142');
    expect(jsonEncode(receipt), isNot(contains(_originalText)));
    expect(receipt['read_revision'], 2);
    expect(receipt['cleanup_read_revision'], 2);
  });

  test('same proof revision remains valid for both deletes in an r -> r+1 -> r+2 receipt chain', () {
    final source = _read(
      cards: [
        _card(),
        _card(id: _otherCard),
      ],
    );
    final ids = store.importLegacy(source);
    expect(store.verifyLegacyImport(source, ids), isTrue);
    final afterA = source.afterDeletion(_oldCard, _ack(3, 3));
    store.finishLegacyCleanup(source.storeId, [_oldCard], expectedReadRevision: source.revision);
    final afterB = afterA.afterDeletion(_otherCard, _ack(4, 4));
    store.finishLegacyCleanup(source.storeId, [_otherCard], expectedReadRevision: source.revision);
    expect(afterB.revision, 4);
    expect(afterB.memories, isEmpty);
    expect(store.migrationCleanup(), isEmpty);
    expect(mapping(_otherCard)['cleanup_read_revision'], 2);
  });

  test('a later unchanged full read re-proves remaining source after close and reopen', () {
    final source = _read(
      cards: [
        _card(),
        _card(id: _otherCard),
      ],
    );
    store.importLegacy(source);
    final originalIds = store.cards().map((card) => card['id']).toList();
    final revision = store.archive['memory_revision'];
    final afterA = source.afterDeletion(_oldCard, _ack(3, 3));
    store.finishLegacyCleanup(source.storeId, [_oldCard], expectedReadRevision: 2);
    reopen();

    // A new complete read can have a higher revision without changing B.
    final fresh = CompanionMigrationSnapshot.fromJson(
      _wire(
        revision: afterA.revision,
        memoryRevision: afterA.memoryRevision,
        cards: [_card(id: _otherCard)],
      ),
    );
    final ids = store.importLegacy(fresh);
    store.finishMissingLegacyCleanup(fresh);
    expect(ids, [_otherCard]);
    expect(store.verifyLegacyImport(fresh, ids), isTrue);
    expect(store.cards().map((card) => card['id']), originalIds);
    expect(store.archive['memory_revision'], revision);
    expect(mapping(_otherCard)['read_revision'], 2);
    expect(mapping(_otherCard)['cleanup_read_revision'], 3);
    final afterB = fresh.afterDeletion(_otherCard, _ack(4, 4));
    store.finishLegacyCleanup(fresh.storeId, ids, expectedReadRevision: fresh.revision);
    expect(afterB.memories, isEmpty);
    reopen();
    expect(store.migrationCleanup(), isEmpty);
    expect(store.cards(), hasLength(2));
  });

  test('source deletion with lost local ACK is completed only from a fresh full absence read', () {
    final source = _read();
    store.importLegacy(source);
    // The source accepted our delete; process termination lost the local finish.
    final after = source.afterDeletion(_oldCard, _ack(3, 3));
    reopen();
    expect(store.migrationCleanup(), hasLength(1));
    store.finishMissingLegacyCleanup(after);
    expect(store.migrationCleanup(), isEmpty);
    expect(mapping()['cleanup_read_revision'], 3);
    expect(store.cards(), hasLength(1));
  });

  test('a late ACK and an old empty list cannot clear a newer changed-source observation', () {
    final original = _read();
    store.importLegacy(original);
    final fingerprint = mapping()['source_fingerprint'];
    final changed = _read(revision: 4, cards: [_card(text: '旧源另有新内容')]);
    expect(store.importLegacy(changed), isEmpty);
    store.finishLegacyCleanup(_oldStore, [_oldCard], expectedReadRevision: 2);
    store.finishMissingLegacyCleanup(_read(revision: 3, cards: []));
    expect(store.migrationCleanup(), hasLength(1));
    expect(mapping()['cleanup_read_revision'], 4);
    expect(mapping()['source_fingerprint'], fingerprint);
    expect(store.verifyLegacyImport(original, [_oldCard]), isFalse);
    expect(store.verifyLegacyImport(changed, [_oldCard]), isFalse);
    store.finishMissingLegacyCleanup(_read(revision: 5, cards: []));
    expect(store.migrationCleanup(), isEmpty);
  });

  test('late old presence cannot reopen a cleanup proved complete at a newer revision', () {
    final source = _read();
    store.importLegacy(source);
    store.finishMissingLegacyCleanup(_read(revision: 5, cards: []));
    expect(store.importLegacy(source), isEmpty);
    expect(store.verifyLegacyImport(source, [_oldCard]), isFalse);
    expect(mapping()['cleanup_read_revision'], 5);
    expect(store.migrationCleanup(), isEmpty);
  });

  test('a newer unchanged read fences a late previous proof without losing the new proof', () {
    final first = _read();
    store.importLegacy(first);
    final fresh = _read(revision: 3);
    expect(store.importLegacy(fresh), [_oldCard]);
    store.finishLegacyCleanup(_oldStore, [_oldCard], expectedReadRevision: 2);
    expect(store.migrationCleanup(), hasLength(1));
    expect(store.verifyLegacyImport(fresh, [_oldCard]), isTrue);
    store.finishLegacyCleanup(_oldStore, [_oldCard], expectedReadRevision: 3);
    expect(store.migrationCleanup(), isEmpty);
  });

  test('UUID casing does not change the fingerprint or duplicate a local card', () {
    store.importLegacy(_read());
    final fingerprint = mapping()['source_fingerprint'];
    final json = _wire(revision: 3, cards: [_card(id: _oldCard.toUpperCase())]);
    json['storeId'] = _oldStore.toUpperCase();
    final fresh = CompanionMigrationSnapshot.fromJson(json);
    expect(store.importLegacy(fresh), [_oldCard]);
    expect(store.verifyLegacyImport(fresh, [_oldCard.toUpperCase()]), isTrue);
    expect(mapping()['source_fingerprint'], fingerprint);
    expect(store.cards(), hasLength(1));
  });

  final changedFields = <String, void Function(Map<String, Object?>)>{
    'text': (row) => row['text'] = '同 ID 新文字',
    'text whitespace': (row) => row['text'] = ' $_originalText',
    'kind': (row) => row['kind'] = 'preference',
    'keyword content': (row) => row['keywords'] = ['旧源', '剧院'],
    'keyword order': (row) => row['keywords'] = ['演出', '旧源'],
    'pinned': (row) => row['pinned'] = false,
    'source kind': (row) => row['source'] = {'kind': 'user-confirmed'},
    'source session': (row) => row['source'] = {'kind': 'manual', 'sessionId': 'old-room'},
    'source message': (row) => row['source'] = {'kind': 'manual', 'messageId': 'old-message'},
    'expiresAt': (row) => row['expiresAt'] = 3000,
    'createdAt': (row) => row['createdAt'] = 999,
    'updatedAt': (row) => row['updatedAt'] = 2001,
  };
  for (final change in changedFields.entries) {
    test('same-ID source ${change.key} change cannot be cleaned from the original import', () {
      store.importLegacy(_read());
      final before = store.cards().single;
      final fingerprint = mapping()['source_fingerprint'];
      final changed = _card();
      change.value(changed);
      final fresh = _read(revision: 3, cards: [changed]);
      expect(store.importLegacy(fresh), isEmpty);
      expect(store.verifyLegacyImport(fresh, [_oldCard]), isFalse);
      expect(mapping()['source_fingerprint'], fingerprint);
      expect(mapping()['cleanup_read_revision'], 3);
      expect(mapping()['cleanup_state'], 'pending');
      expect(store.cards().single, before);
    });
  }

  test('a same-ID mismatch does not stop an independent new source card being imported', () {
    store.importLegacy(_read());
    final fresh = _read(
      revision: 3,
      cards: [
        _card(text: '旧源改动'),
        _card(id: _otherCard),
      ],
    );
    expect(store.importLegacy(fresh), [_otherCard]);
    expect(store.verifyLegacyImport(fresh, [_otherCard]), isTrue);
    expect(store.verifyLegacyImport(fresh, [_oldCard]), isFalse);
    expect(store.cards(), hasLength(2));
  });

  test('a local edit is preserved while unchanged original source becomes cleanable', () {
    store.importLegacy(_read(), realityKnownIds: {_oldCard});
    final card = store.cards().single;
    store.saveManual(
      CompanionMemory(id: card['id']! as String, text: '手机上已经取消演出'),
      expectedRowRev: 1,
      currentValueChange: true,
      realityKnown: true,
    );
    final edited = store.cards().single;
    final fresh = _read(revision: 3);
    expect(store.importLegacy(fresh), [_oldCard]);
    expect(store.verifyLegacyImport(fresh, [_oldCard]), isTrue);
    expect(store.cards().single, edited);
    // Matching the edited phone text is not evidence about the original source.
    final remoteCopiedEdit = _read(revision: 4, cards: [_card(text: '手机上已经取消演出')]);
    expect(store.importLegacy(remoteCopiedEdit), isEmpty);
    expect(store.verifyLegacyImport(remoteCopiedEdit, [_oldCard]), isFalse);
    expect(store.cards().single, edited);
  });

  test('forgotten mappings clear unchanged old source without recreating a local card', () {
    store.importLegacy(_read());
    final card = store.cards().single;
    store.deleteCard(id: card['id']! as String, expectedRowRev: 1);
    reopen();
    final fresh = _read(revision: 3);
    expect(store.importLegacy(fresh), [_oldCard]);
    expect(store.verifyLegacyImport(fresh, [_oldCard]), isTrue);
    expect(store.cards(includeInactive: true), isEmpty);
    expect(mapping()['result'], 'forgotten');
    store.finishLegacyCleanup(_oldStore, [_oldCard], expectedReadRevision: fresh.revision);
    expect(store.migrationCleanup(), isEmpty);
    final changed = _read(revision: 4, cards: [_card(text: '同 ID 新旧源')]);
    expect(store.importLegacy(changed), isEmpty);
    expect(store.verifyLegacyImport(changed, [_oldCard]), isFalse);
    expect(store.cards(includeInactive: true), isEmpty);
    expect(mapping()['result'], 'forgotten');
    expect(store.migrationCleanup(), hasLength(1));
  });

  test('completed identity reappearing with its original source can be cleaned again', () {
    final source = _read();
    store.importLegacy(source);
    store.finishLegacyCleanup(_oldStore, [_oldCard], expectedReadRevision: 2);
    final card = store.cards().single;
    final fresh = _read(revision: 4);
    expect(store.importLegacy(fresh), [_oldCard]);
    expect(store.verifyLegacyImport(fresh, [_oldCard]), isTrue);
    expect(store.cards().single, card);
  });

  test('v4 mapping gets no invented fingerprint and can backfill only its original source revision', () {
    final source = _read();
    store.importLegacy(source);
    final archive = store.archive;
    final card = store.cards().single;
    reopenFromV4();
    expect(database.select('PRAGMA user_version').single['user_version'], 14);
    expect(store.archive, archive);
    expect(mapping()['source_fingerprint'], isNull);
    expect(mapping()['cleanup_read_revision'], 2);
    store.finishLegacyCleanup(_oldStore, [_oldCard], expectedReadRevision: 2);
    expect(store.migrationCleanup(), hasLength(1));
    expect(store.importLegacy(source), [_oldCard]);
    expect(store.verifyLegacyImport(source, [_oldCard]), isTrue);
    expect(mapping()['source_fingerprint'], startsWith('sha256-v1:'));
    expect(store.cards().single, card);
    expect(
      database.select("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'memory_host_chat_%'"),
      hasLength(3),
    );
  });

  for (final forgotten in [false, true]) {
    test('v4 mapping at a different source revision stays unknown (forgotten=$forgotten)', () {
      store.importLegacy(_read());
      final card = store.cards().single;
      if (forgotten) {
        store.deleteCard(id: card['id']! as String, expectedRowRev: 1);
      } else {
        store.saveManual(
          CompanionMemory(id: card['id']! as String, text: '手机修改后的文字'),
          expectedRowRev: 1,
          currentValueChange: true,
          realityKnown: true,
        );
      }
      reopenFromV4();
      final fresh = _read(revision: 3);
      expect(store.importLegacy(fresh), isEmpty);
      expect(store.verifyLegacyImport(fresh, [_oldCard]), isFalse);
      expect(mapping()['source_fingerprint'], isNull);
      expect(mapping()['read_revision'], 2);
      expect(mapping()['cleanup_read_revision'], 3);
      expect(store.cards(includeInactive: true), hasLength(forgotten ? 0 : 1));
      // No rollback to an older full read is allowed to manufacture a proof.
      expect(store.importLegacy(_read()), isEmpty);
      expect(mapping()['source_fingerprint'], isNull);
      store.finishMissingLegacyCleanup(_read(revision: 4, cards: []));
      expect(store.migrationCleanup(), isEmpty);
    });
  }

  test('readback rejects missing source identity and a missing non-forgotten phone card', () {
    final source = _read();
    store.importLegacy(source);
    expect(store.verifyLegacyImport(_read(cards: []), [_oldCard]), isFalse);
    expect(store.verifyLegacyImport(source, [_otherCard]), isFalse);
    database.execute('DELETE FROM memory_cards');
    expect(store.verifyLegacyImport(source, [_oldCard]), isFalse);
  });

  test('an import failure rolls back both refreshed proof generation and new source cards', () {
    store.importLegacy(_read());
    final before = mapping();
    final archive = store.archive;
    database.execute("""
      CREATE TRIGGER fail_new_card BEFORE INSERT ON memory_cards
      WHEN NEW.text = 'synthetic failure' BEGIN SELECT RAISE(ABORT, 'fixture'); END
    """);
    final fresh = _read(
      revision: 3,
      cards: [
        _card(),
        _card(id: _otherCard, text: 'synthetic failure'),
      ],
    );
    expect(() => store.importLegacy(fresh), throwsA(isA<SqliteException>()));
    expect(mapping(), before);
    expect(store.archive, archive);
    expect(store.cards(), hasLength(1));
    expect(store.verifyLegacyImport(_read(), [_oldCard]), isTrue);
  });

  test('local vitals-only r+1 conflicts first, then unchanged source recovers without changing vitals', () async {
    final oldDirectory = Directory('${directory.path}/legacy');
    final local = CompanionLocalStore(appDirectory: oldDirectory, nowMilliseconds: () => now);
    final initial = await local.companionSnapshot();
    await local.saveCompanionMemory(
      initial.storeId,
      initial.revision,
      const CompanionMemory(id: _oldCard, text: _originalText),
    );
    final source = (await local.probeForMigration())!;
    store.importLegacy(source);
    await local.companionEvent(source.storeId, source.revision, 'pet');
    await expectLater(
      local.removeMigratedMemories(source.storeId, source.revision, {_oldCard}),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/conflict')),
    );
    reopen();
    final fresh = (await local.probeForMigration())!;
    expect(fresh.revision, source.revision + 1);
    expect(fresh.memoryRevision, source.memoryRevision);
    final ids = store.importLegacy(fresh);
    expect(ids, [_oldCard]);
    expect(store.verifyLegacyImport(fresh, ids), isTrue);
    final file = File('${oldDirectory.path}/light-state.json');
    final before = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    await local.removeMigratedMemories(fresh.storeId, fresh.revision, ids.toSet());
    store.finishLegacyCleanup(fresh.storeId, ids, expectedReadRevision: fresh.revision);
    final after = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(after['state'], before['state']);
    expect(after['storeId'], before['storeId']);
    expect(after['memories'], isEmpty);
    expect(store.migrationCleanup(), isEmpty);
    expect(store.cards(), hasLength(1));
  });

  test('actual SDK HTTP migration resumes after one strict delete and SQLite reopen', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = DshClient(
      DshConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        cookie: DshCookie(name: 'dsh-auth-fixture', value: 'synthetic', authority: '127.0.0.1:${server.port}'),
      ),
    );
    final sent = <Map<String, Object?>>[];
    var step = 0;
    // Synthetic full v1 responses exercise the production HTTP client and
    // strict acknowledgement parser. This is not a live Node-host test.
    server.listen((request) async {
      expect(request.headers.value('cookie'), 'dsh-auth-fixture=synthetic');
      Object body;
      if (step == 0) {
        expect(request.method, 'GET');
        expect(request.uri.path, '$dshGoCompanionPath/memories');
        body = _wire(
          cards: [
            _card(),
            _card(id: _otherCard),
          ],
        );
      } else if (step == 2) {
        expect(request.method, 'GET');
        expect(request.uri.path, '$dshGoCompanionPath/memories');
        body = _wire(revision: 3, memoryRevision: 3, cards: [_card(id: _otherCard)]);
      } else {
        expect(request.method, 'POST');
        expect(request.uri.path, '$dshGoCompanionPath/memories/delete');
        sent.add(
          Map<String, Object?>.from(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>),
        );
        body = step == 1 ? _ack(3, 3) : _ack(4, 4);
      }
      step++;
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
    try {
      final source = await client.companionMemoriesForMigration();
      final firstIds = store.importLegacy(source);
      expect(store.verifyLegacyImport(source, firstIds), isTrue);
      await client.deleteMigratedCompanionMemory(source, _oldCard);
      store.finishLegacyCleanup(source.storeId, [_oldCard], expectedReadRevision: source.revision);
      reopen();
      final fresh = await client.companionMemoriesForMigration();
      final secondIds = store.importLegacy(fresh);
      store.finishMissingLegacyCleanup(fresh);
      expect(secondIds, [_otherCard]);
      expect(store.verifyLegacyImport(fresh, secondIds), isTrue);
      final empty = await client.deleteMigratedCompanionMemory(fresh, _otherCard);
      store.finishLegacyCleanup(fresh.storeId, secondIds, expectedReadRevision: fresh.revision);
      expect(empty.memories, isEmpty);
      expect(sent, [
        {'storeId': _oldStore, 'expectedRevision': 2, 'id': _oldCard},
        {'storeId': _oldStore, 'expectedRevision': 3, 'id': _otherCard},
      ]);
      expect(step, 4);
      expect(store.cards(), hasLength(2));
      expect(store.migrationCleanup(), isEmpty);
    } finally {
      await client.close();
      await server.close(force: true);
    }
  });

  test('malformed full source remains rejected before any new cleanup proof', () {
    store.importLegacy(_read());
    final before = mapping();
    final broken = _wire(
      revision: 3,
      cards: [
        _card(),
        _card(id: _otherCard)..remove('updatedAt'),
      ],
    );
    expect(() => CompanionMigrationSnapshot.fromJson(broken), throwsA(isA<DshProtocolException>()));
    expect(mapping(), before);
    expect(store.cards(), hasLength(1));
  });
}
