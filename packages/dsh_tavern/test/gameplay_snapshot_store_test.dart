import 'dart:io';

import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('gameplay snapshot owns only its read transaction and remains readable during onCommitted', () async {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    final chat = store.createChat(characterId: 'snapshot-character', title: 'before');
    var publications = 0;
    final changedChats = <String>[];
    var presetChanges = 0;
    store.committedObserver = (_, _) => publications++;
    final changes = store.changes.listen(changedChats.add);
    final presets = store.presetChanges.listen((_) => presetChanges++);
    addTearDown(changes.cancel);
    addTearDown(presets.cancel);

    final initialChanges = _totalChanges(db);
    final initialStamp = store.readGameplayBindingStamp();
    expect(initialStamp, isNotNull);
    expect(db.autocommit, isTrue);
    final own = store.readGameplaySnapshot(chatId: chat, packRefs: []);
    expect(own.domainId, store.authoringDomainId);
    expect(own.chat!.title, 'before');
    final ownBindings = store.readGameplayBindingFacts(chatId: chat);
    expect(ownBindings.domainId, own.domainId);
    expect(ownBindings.hostCharacterId, own.chat!.characterId);
    expect(ownBindings.groupCharacterIds, isNull);
    expect(ownBindings.scopeSnapshots, hasLength(3));
    expect(ownBindings.resolvedScopes.every((scope) => scope.bindings.isEmpty), isTrue);
    expect(ownBindings.versions, isEmpty);
    expect(db.autocommit, isTrue);
    expect(_totalChanges(db), initialChanges);
    expect(store.readGameplayBindingStamp(), initialStamp);
    await Future<void>.delayed(Duration.zero);
    expect(publications, 0);
    expect(changedChats, isEmpty);
    expect(presetChanges, 0);

    // A transaction opened on the real connection is also borrowed, even
    // though ChatStore's managed nesting depth is zero.
    db.execute('BEGIN');
    try {
      db.execute('UPDATE chats SET title = ? WHERE id = ?', ['uncommitted', chat]);
      expect(store.readGameplayBindingStamp(), isNull);
      final beforeRead = _totalChanges(db);
      final borrowed = store.readGameplaySnapshot(chatId: chat, packRefs: []);
      expect(borrowed.chat!.title, 'uncommitted');
      expect(store.readGameplayBindingFacts(chatId: chat).hostCharacterId, borrowed.chat!.characterId);
      expect(db.autocommit, isFalse);
      expect(_totalChanges(db), beforeRead);
      expect(publications, 0);
    } finally {
      if (!db.autocommit) {
        db.execute('ROLLBACK');
      }
    }
    expect(store.chat(chat).title, 'before');
    expect(store.readGameplayBindingStamp(), isNot(initialStamp));

    StoredGameplaySnapshot? committed;
    store.transaction(
      () {
        store.updateChat(chat, title: 'committed');
        expect(store.readGameplayBindingStamp(), isNull);
      },
      onCommitted: () {
        // The real COMMIT has run; the store has not yet reset its managed
        // transaction depth. This read must use SQLite's actual ownership.
        expect(db.autocommit, isTrue);
        expect(store.readGameplayBindingStamp(), isNull);
        expect(publications, 0);
        final beforeRead = _totalChanges(db);
        committed = store.readGameplaySnapshot(chatId: chat, packRefs: []);
        expect(committed!.chat!.title, 'committed');
        expect(store.readGameplayBindingFacts(chatId: chat).hostCharacterId, committed!.chat!.characterId);
        expect(db.autocommit, isTrue);
        expect(_totalChanges(db), beforeRead);
        expect(publications, 0);
      },
    );
    expect(committed, isNotNull);
    expect(db.autocommit, isTrue);
    expect(store.chat(chat).title, 'committed');
    expect(store.readGameplayBindingStamp(), isNotNull);
    expect(publications, 1);
    await Future<void>.delayed(Duration.zero);
    expect(changedChats, [chat]);
    expect(presetChanges, 0);
  });

  test('display binding stamps observe local and external domain changes including ABA', () async {
    final root = await Directory.systemTemp.createTemp('tavern-gameplay-stamp-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/tavern.sqlite3';
    final store = ChatStore.open(path);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    final external = sqlite3.open(path);
    addTearDown(external.close);

    final initial = store.readGameplayBindingStamp();
    store.rotateAuthoringDomain();
    final local = store.readGameplayBindingStamp();
    final domain = store.readGameplayBindingFacts().domainId;
    expect(local, isNot(initial));
    expect(store.readGameplayBindingStamp(), local);

    external.execute('UPDATE authoring_domain SET domain_id = ? WHERE singleton = 1', ['external-domain']);
    final changed = store.readGameplayBindingStamp();
    expect(changed, isNot(local));
    expect(store.readGameplayBindingFacts().domainId, 'external-domain');
    external.execute('UPDATE authoring_domain SET domain_id = ? WHERE singleton = 1', [domain]);
    final restored = store.readGameplayBindingStamp();
    expect(restored, isNot(changed));
    expect(restored, isNot(local));
    expect(store.readGameplayBindingFacts().domainId, domain);
    expect(store.readGameplayBindingStamp(), restored);
  });

  test('a snapshot decode error leaves the borrowed transaction for its original owner to finish', () async {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    final chat = store.createChat(characterId: 'snapshot-character', title: 'before');
    var publications = 0;
    final changedChats = <String>[];
    store.committedObserver = (_, _) => publications++;
    final changes = store.changes.listen(changedChats.add);
    addTearDown(changes.cancel);
    var committed = false;

    store.transaction(
      () {
        db.execute('UPDATE chats SET title = ?, metadata = ? WHERE id = ?', ['borrowed', '{', chat]);
        final beforeRead = _totalChanges(db);
        expect(
          () => store.readGameplaySnapshot(chatId: chat, packRefs: []),
          throwsA(isA<FormatException>().having((error) => error.source, 'source', '{')),
        );
        // Resource currentness reads the live host and bindings, not unused
        // chat metadata. The full reader keeps its existing decode failure.
        expect(store.readGameplayBindingFacts(chatId: chat).hostCharacterId, 'snapshot-character');
        expect(
          () => store.readGameplayBindingFacts(chatId: 'absent'),
          throwsA(isA<StateError>().having((error) => error.message, 'message', 'Chat not found: absent')),
        );
        expect(db.autocommit, isFalse);
        expect(_totalChanges(db), beforeRead);
        expect(db.select('SELECT title, metadata FROM chats WHERE id = ?', [chat]).single, {
          'title': 'borrowed',
          'metadata': '{',
        });
        expect(publications, 0);
        // The caller catches an ordinary decode failure, repairs its own write,
        // and can still use the existing nested writer and finish the outer SQL.
        store.updateChat(chat, title: 'repaired', metadata: {'recovered': true});
        final repairedChanges = _totalChanges(db);
        final repaired = store.readGameplaySnapshot(chatId: chat, packRefs: []);
        expect(repaired.chat!.metadata, {'recovered': true});
        expect(db.autocommit, isFalse);
        expect(_totalChanges(db), repairedChanges);
        expect(publications, 0);
      },
      onCommitted: () {
        committed = true;
        expect(db.autocommit, isTrue);
      },
    );
    expect(committed, isTrue);
    expect(db.autocommit, isTrue);
    expect(store.chat(chat).title, 'repaired');
    expect(store.chat(chat).metadata, {'recovered': true});
    expect(publications, 1);
    await Future<void>.delayed(Duration.zero);
    expect(changedChats, [chat]);

    final afterCommit = _totalChanges(db);
    expect(store.readGameplaySnapshot(chatId: chat, packRefs: []).chat!.metadata, {'recovered': true});
    expect(_totalChanges(db), afterCommit);
    expect(publications, 1);
  });
}

int _totalChanges(Database db) => db.select('SELECT total_changes() AS count').single['count']! as int;
