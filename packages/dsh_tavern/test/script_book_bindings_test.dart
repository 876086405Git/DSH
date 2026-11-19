import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('book bindings keep owned lists and drive native primary and chat scanning', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final card = await h.engine.importCard(_card());
    final global = await _book(h.engine, 'Global', 'BIND_GLOBAL');
    final inherited = await _book(h.engine, 'Inherited', 'BIND_INHERITED');
    final primary = await _book(h.engine, 'Primary', 'BIND_PRIMARY');
    final own = await _book(h.engine, 'Additional', 'BIND_ADDITIONAL');
    final original = await _book(h.engine, 'Original chat', 'BIND_MASKED');
    final chatBook = await _book(
      h.engine,
      'Display title is not the source name',
      'BIND_CHAT',
      sourceName: 'chat-runtime-name',
    );
    const missingId = '00000000000000000000000000000000';
    final missing = TavernScriptBookRef.standalone(bookId: missingId);

    // Start with an actual native JSONL export, retaining its real metadata
    // source and message format when importing the world-info mapping.
    final seed = await h.engine.createChat(card.id);
    final exported = (await h.engine.exportChat(seed)).single;
    final lines = const LineSplitter().convert(utf8.decode(exported.bytes));
    final header = _object(jsonDecode(lines.first));
    final metadata = _object(header['chat_metadata']);
    metadata['world_info'] = 'original-source';
    metadata['binding_note'] = 'retain this source field';
    final imported = await h.engine.importChats(
      card.id,
      [
        TavernChatFile(
          fileName: 'binding-source.jsonl',
          bytes: Uint8List.fromList(utf8.encode([jsonEncode(header), ...lines.skip(1), ''].join('\n'))),
        ),
      ],
      lorebookIds: {'original-source': original.bookId},
    );
    final chatId = imported.chatIds.single;
    await h.engine.bindLorebooks([inherited.bookId], source: WorldInfoSource.character);
    await h.engine.bindLorebooks([chatBook.bookId], source: WorldInfoSource.chat, chatId: chatId);
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(instanceId: 'owned-book-bindings', chatId: chatId, characterId: card.id),
    );

    const globalTarget = TavernScriptBookBindingsTarget(scope: TavernScriptBookBindingScope.global);
    final globalBefore = await bridge.readBookBindings(context.id, globalTarget);
    final globalAfter = await bridge.updateBookBindings(
      context.id,
      TavernScriptBookBindingsEdit(
        scope: TavernScriptBookBindingScope.global,
        primary: null,
        additional: [global, global],
      ),
      expectedVersion: globalBefore.version,
    );
    expect(globalAfter.primary, isNull);
    expect(globalAfter.additional, [
      global,
      global,
    ], reason: 'An owned binding list preserves its supplied duplicate entries.');

    final characterTarget = TavernScriptBookBindingsTarget(
      scope: TavernScriptBookBindingScope.character,
      targetId: card.id,
    );
    final characterBefore = await bridge.readBookBindings(context.id, characterTarget);
    expect(characterBefore.primary, isNull);
    expect(characterBefore.additional, isEmpty);
    expect(characterBefore.inherited, [inherited]);
    final characterAfter = await bridge.updateBookBindings(
      context.id,
      TavernScriptBookBindingsEdit(
        scope: TavernScriptBookBindingScope.character,
        targetId: card.id,
        primary: primary,
        additional: [own, own, missing],
      ),
      expectedVersion: characterBefore.version,
    );
    expect(characterAfter.primary, primary);
    expect(characterAfter.additional, [own, own, missing]);
    expect(characterAfter.inherited, [inherited]);
    expect(await h.engine.lorebook(missingId), isNull);
    final savedSettings = await h.engine.readSettings();
    expect(_object(savedSettings['characterLorebooks'])[card.id], [
      own.bookId,
      own.bookId,
      missingId,
    ], reason: 'Inherited generic bindings must not be copied into the owned list.');
    expect(_object(savedSettings['characterPrimaryLorebooks'])[card.id], primary.bookId);

    final chatTarget = TavernScriptBookBindingsTarget(scope: TavernScriptBookBindingScope.chat, targetId: chatId);
    final masked = await bridge.readBookBindings(context.id, chatTarget);
    final beforeBindingView = await bridge.snapshot(context.id);
    Map<String, Object?> chatBinding(TavernScriptSnapshot view) => (view.resourceRefs['bookBindings']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((row) => row['scope'] == 'chat');
    expect(chatBinding(beforeBindingView)['version'], masked.version);
    expect(chatBinding(await bridge.snapshot(context.id)), chatBinding(beforeBindingView));
    expect(masked.primary, isNull);
    expect(masked.additional, [chatBook]);
    expect(
      (await _metadata(h.engine, chatId))['world_info'],
      'original-source',
      reason: 'The explicit scan list masks the raw primary without rewriting its source.',
    );
    final chatAfter = await bridge.updateBookBindings(
      context.id,
      TavernScriptBookBindingsEdit(scope: TavernScriptBookBindingScope.chat, targetId: chatId, primary: chatBook),
      expectedVersion: masked.version,
    );
    expect(chatAfter.primary, chatBook);
    expect(chatAfter.additional, isEmpty);
    expect(chatBinding(await bridge.snapshot(context.id))['version'], chatAfter.version);
    expect(chatBinding(beforeBindingView)['version'], masked.version);
    final adoptedMetadata = await _metadata(h.engine, chatId);
    expect(adoptedMetadata['world_info'], 'chat-runtime-name');
    expect(adoptedMetadata['binding_note'], 'retain this source field');
    final effective = await h.engine.readSettings(chatId: chatId);
    expect(_object(effective['stLorebookIds']), {
      'original-source': original.bookId,
      'chat-runtime-name': chatBook.bookId,
    });
    expect(_object(effective['lorebooks'])['chat'], [chatBook.bookId]);
    await expectLater(
      bridge.updateBookBindings(
        context.id,
        TavernScriptBookBindingsEdit(scope: TavernScriptBookBindingScope.chat, targetId: chatId, primary: original),
        expectedVersion: masked.version,
      ),
      throwsA(
        isA<TavernScriptException>().having((error) => error.code, 'code', TavernScriptErrorCode.revisionConflict),
      ),
    );
    expect((await bridge.readBookBindings(context.id, chatTarget)).version, chatAfter.version);
    expect((await _metadata(h.engine, chatId))['world_info'], 'chat-runtime-name');

    final first = jsonEncode(await _complete(h, h.engine.send(chatId, 'Read the bound books.')));
    for (final content in ['BIND_GLOBAL', 'BIND_INHERITED', 'BIND_PRIMARY', 'BIND_ADDITIONAL', 'BIND_CHAT']) {
      expect(first, contains(content));
    }
    expect(first, isNot(contains('BIND_MASKED')));

    // A real embedded book wins over the stored standalone primary. Updating
    // the additional list does not remove that dormant standalone selection.
    final embeddedRef = TavernScriptBookRef.embedded(characterId: card.id);
    await bridge.replaceBook(context.id, embeddedRef, _embeddedBook());
    final embedded = await bridge.readBookBindings(context.id, characterTarget);
    expect(embedded.primary, embeddedRef);
    expect(embedded.additional, [own, own, missing]);
    await expectLater(
      bridge.updateBookBindings(
        context.id,
        TavernScriptBookBindingsEdit(
          scope: TavernScriptBookBindingScope.character,
          targetId: card.id,
          primary: primary,
          additional: [own],
        ),
        expectedVersion: embedded.version,
      ),
      throwsA(
        isA<TavernScriptException>().having((error) => error.code, 'code', TavernScriptErrorCode.unsupportedOption),
      ),
    );
    final narrowed = await bridge.updateBookBindings(
      context.id,
      TavernScriptBookBindingsEdit(
        scope: TavernScriptBookBindingScope.character,
        targetId: card.id,
        primary: embeddedRef,
        additional: [own],
      ),
      expectedVersion: embedded.version,
    );
    expect(narrowed.primary, embeddedRef);
    expect(narrowed.additional, [own]);
    expect(_object((await h.engine.readSettings())['characterPrimaryLorebooks'])[card.id], primary.bookId);
    final active = await bridge.getContextBooks(context.id);
    expect(active.map((binding) => binding.ref), contains(embeddedRef));
    expect(active.map((binding) => binding.ref), isNot(contains(primary)));
    final second = jsonEncode(await _complete(h, h.engine.send(chatId, 'Read the current books.')));
    for (final content in ['BIND_GLOBAL', 'BIND_INHERITED', 'BIND_ADDITIONAL', 'BIND_CHAT', 'BIND_EMBEDDED']) {
      expect(second, contains(content));
    }
    expect(second, isNot(contains('BIND_PRIMARY')));
    expect(second, isNot(contains('BIND_MASKED')));
    expect(h.model.generated, 2);
  });
}

Future<TavernScriptStandaloneBookRef> _book(
  TavernEngine engine,
  String name,
  String content, {
  String? sourceName,
}) async {
  await engine.importLorebook(
    jsonEncode({
      'name': name,
      'entries': {
        '1': {
          'uid': 1,
          'key': <String>[],
          'keysecondary': <String>[],
          'comment': name,
          'content': content,
          'constant': true,
          'disable': false,
          'position': 0,
          'order': 100,
        },
      },
    }),
    fileName: '${sourceName ?? name}.json',
  );
  final id = (await engine.listLorebooks()).singleWhere((book) => book.name == name).id;
  return TavernScriptStandaloneBookRef(bookId: id);
}

Future<Map<String, Object?>> _metadata(TavernEngine engine, String chatId) async {
  final exported = (await engine.exportChat(chatId)).first;
  final header = _object(jsonDecode(const LineSplitter().convert(utf8.decode(exported.bytes)).first));
  return _object(header['chat_metadata']);
}

Future<Map<String, Object?>> _complete(T24Harness h, Stream<TavernEvent> stream) async {
  final call = h.model.prepare();
  final events = T24Events(stream);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure(
        'The native turn ended before the controlled model was reached: '
        '${events.values.whereType<TavernTurnFailed>().toList()}',
      );
    }),
  ]);
  call.add(const ModelText('The books were read.'));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  expect(events.values.whereType<TavernTurnDone>(), hasLength(1));
  return call.body!;
}

Map<String, Object?> _object(Object? value) => value! as Map<String, Object?>;

Map<String, Object?> _embeddedBook() => {
  'name': 'Embedded',
  'entries': [
    {
      'id': 1,
      'keys': <String>[],
      'enabled': true,
      'constant': true,
      'content': 'BIND_EMBEDDED',
      'insertion_order': 0,
      'position': 'before_char',
      'extensions': <String, Object?>{},
    },
  ],
};

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Book binding reader',
        'description': 'Read the selected world books.',
        'personality': '',
        'scenario': '',
        'first_mes': 'Ready to read.',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
      },
    }),
  ),
);
