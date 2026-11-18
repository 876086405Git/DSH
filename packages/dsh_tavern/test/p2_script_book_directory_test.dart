import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('book directory, identity and deletion follow authoritative resources', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('目录台');
    final chat = await h.engine.createChat(character);
    await h.engine.putLorebook('existing', {'name': 'Shared', 'entries': <String, Object?>{}});
    final folder = Directory('${h.root.path}/lorebooks');
    final bad = File('${folder.path}/bad.json');
    final shape = File('${folder.path}/shape.json');
    final badUtf8 = File('${folder.path}/bad-utf8.json');
    await bad.writeAsString('{broken');
    await shape.writeAsString('[]');
    await badUtf8.writeAsBytes([0xff, 0xfe, 0x61]);
    final context = await h.context(chat, characterId: character);
    final first = await h.bridge.getBookDirectory(context.id);
    expect(first.books.map((book) => book.handle).toSet(), {
      'standalone:existing',
      'standalone:bad',
      'standalone:shape',
      'standalone:bad-utf8',
    });
    expect(first.books.where((book) => !book.readable).length, 3);
    expect(first.issues.map((issue) => issue.code).toSet(), {'invalidJson', 'shapeMismatch'});
    expect(
      await h.bridge.resolveBook(context.id, 'standalone:existing'),
      TavernScriptBookRef.standalone(bookId: 'existing'),
    );
    expect(await h.bridge.resolveBook(context.id, 'Shared'), TavernScriptBookRef.standalone(bookId: 'existing'));

    // A cached snapshot reads no book directory/files on message-only refresh.
    final away = await folder.rename('${h.root.path}/lorebooks-away');
    final blocker = File(folder.path);
    await blocker.writeAsString('directory read would fail');
    try {
      final cached = await h.bridge.snapshot(context.id);
      expect(scriptMap(cached.resourceRefs['bookDirectory'])['version'], first.version);
      expect((await h.bridge.getBookDirectory(context.id)).version, first.version);
    } finally {
      await blocker.delete();
      await away.rename(folder.path);
    }

    final created = await h.bridge.createBook(context.id, 'source-A', {
      'name': 'Shared',
      'foreign_book': {
        'keep': [false, null],
      },
      'entries': {
        '7': {
          'uid': 7,
          'key': ['unused'],
          'content': 'raw body',
          'disable': true,
          'foreign_entry': ['opaque', null],
        },
      },
    });
    final ref = created.ref as TavernScriptStandaloneBookRef;
    final physical = File('${folder.path}/${ref.bookId}.json');
    final envelope = scriptMap(jsonDecode(await physical.readAsString()));
    expect(envelope['stWorldName'], 'source-A');
    expect(envelope['book'], created.book);
    final withCreated = await h.bridge.getBookDirectory(context.id);
    expect(withCreated.version, isNot(first.version));
    final row = withCreated.books.singleWhere((book) => book.ref == ref);
    expect(row.name, 'Shared');
    expect(row.stWorldName, 'source-A');
    expect(await h.bridge.resolveBook(context.id, row.handle), ref);
    expect(await h.bridge.resolveBook(context.id, 'source-A'), ref);
    await expectLater(
      () => h.bridge.resolveBook(context.id, 'Shared'),
      throwsA(scriptError(TavernScriptErrorCode.ambiguousName)),
    );

    final changedBody = created.book
      ..['foreign_book'] = {
        'keep': [true, null],
      };
    final changed = await h.bridge.replaceBook(context.id, ref, changedBody, expectedVersion: created.version);
    expect(changed.version, isNot(created.version));
    expect((await h.bridge.getBookDirectory(context.id)).version, withCreated.version);
    await expectLater(
      () => h.bridge.deleteBook(context.id, ref, expectedVersion: created.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    expect(await physical.exists(), isTrue);
    final renamed = await h.bridge.replaceBook(
      context.id,
      ref,
      changed.book..['name'] = 'Renamed',
      expectedVersion: changed.version,
    );
    final withRenamed = await h.bridge.getBookDirectory(context.id);
    expect(withRenamed.version, isNot(withCreated.version));
    expect(await h.bridge.resolveBook(context.id, 'Shared'), TavernScriptBookRef.standalone(bookId: 'existing'));
    expect(await h.bridge.resolveBook(context.id, 'Renamed'), ref);
    expect(await h.bridge.resolveBook(context.id, 'source-A'), ref);

    final embeddedRef = TavernScriptBookRef.embedded(characterId: character);
    final embedded = await h.bridge.replaceBook(context.id, embeddedRef, {
      'name': 'Inside',
      'entries': <Object?>[],
      'foreign_book': {'keep': 1},
    });
    final withEmbedded = await h.bridge.getBookDirectory(context.id);
    expect(withEmbedded.books.any((book) => book.ref == embeddedRef), isTrue);
    expect(await h.bridge.resolveBook(context.id, 'Inside'), embeddedRef);
    final beforeCard = scriptMap((await h.bridge.snapshot(context.id)).resourceRefs['characterData']);
    final dataBeforeDelete = scriptMap(beforeCard['data']);
    await h.bridge.deleteBook(context.id, embeddedRef, expectedVersion: embedded.version);
    final afterCard = scriptMap((await h.bridge.snapshot(context.id)).resourceRefs['characterData']);
    expect(afterCard['data'], dataBeforeDelete..remove('character_book'));
    expect((await h.bridge.getBookDirectory(context.id)).books.any((book) => book.ref == embeddedRef), isFalse);
    await expectLater(
      () => h.bridge.readBook(context.id, embeddedRef),
      throwsA(scriptError(TavernScriptErrorCode.notFound)),
    );

    // Deletion preserves existing dangling bindings rather than claiming a
    // cross-file transaction that the underlying store does not provide.
    await h.engine.bindLorebooks([ref.bookId]);
    await h.bridge.deleteBook(context.id, ref, expectedVersion: renamed.version);
    expect(await physical.exists(), isFalse);
    expect(await h.engine.lorebook(ref.bookId), isNull);
    expect((await h.bridge.getContextBooks(context.id)).any((link) => link.ref == ref), isTrue);
    expect(scriptMap(scriptMap((await h.settingsDocument())['settings'])['lorebooks'])['global'], [ref.bookId]);
    final afterDelete = await h.bridge.getBookDirectory(context.id);
    expect(afterDelete.books.any((book) => book.ref == ref), isFalse);
    await expectLater(
      () => h.bridge.resolveBook(context.id, row.handle),
      throwsA(scriptError(TavernScriptErrorCode.notFound)),
    );
    h.expectNoGeneration();

    await bad.delete();
    await badUtf8.delete();
    await shape.delete();
    await h.reopen();
    final reopened = await h.context(chat, characterId: character);
    final finalDirectory = await h.bridge.getBookDirectory(reopened.id);
    expect(finalDirectory.books.map((book) => book.handle), ['standalone:existing']);
    expect(finalDirectory.issues, isEmpty);
    expect(
      (await h.bridge.snapshot(reopened.id)).resourceRefs['bookDirectory'],
      containsPair('version', finalDirectory.version),
    );
    h.expectNoGeneration();
  });
}
