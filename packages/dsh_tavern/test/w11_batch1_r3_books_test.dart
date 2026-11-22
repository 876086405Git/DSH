import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _bad = 'bad-entries';
const _good = 'working-book';
const _badRaw = <String, Object?>{'name': 'Unreadable entries', 'entries': 'not an object or array'};

void main() {
  final bindings = [
    for (final source in WorldInfoSource.values) (name: 'source-${source.name}', source: source),
    (name: 'chat-override', source: WorldInfoSource.global),
    (name: 'character-additional', source: WorldInfoSource.character),
    (name: 'persona-additional', source: WorldInfoSource.persona),
    (name: 'explicit-character-primary', source: WorldInfoSource.character),
  ];
  for (final binding in bindings) {
    test('unreadable standalone entries are missing for ${binding.name}', () async {
      final h = await generationFixture();
      final character = await h.card('Unreadable binding');
      final chat = await h.engine.createChat(character);
      await h.engine.putLorebook(_good, _book('WORKING CONTENT'));
      await h.engine.bindLorebooks([_good]);
      await _writeBad(h, _bad, jsonEncode(_badRaw));
      final context = await h.context(chat, characterId: character);
      final directory = await h.bridge.getBookDirectory(context.id);
      expect(directory.books.singleWhere((book) => book.handle == 'standalone:$_bad').readable, isFalse);
      switch (binding.name) {
        case 'chat-override':
          await h.engine.bindLorebooks([_good, _bad], chatId: chat);
        case 'character-additional':
          await h.engine.bindLorebooks([_bad], source: binding.source, characterId: character);
        case 'persona-additional':
          final persona = await h.engine.createPersona(name: 'Bound persona');
          await h.engine.bindPersona(chat, persona.id);
          await h.engine.bindLorebooks([_bad], source: binding.source, personaId: persona.id);
        case 'explicit-character-primary':
          await h.engine.setSettings({
            'characterPrimaryLorebooks': {character: _bad},
          });
        default:
          await h.engine.bindLorebooks([
            if (binding.source == WorldInfoSource.global) _good,
            _bad,
          ], source: binding.source);
      }
      await _expectMissingAndHttp(h, chat, [
        {'bookId': _bad, 'source': binding.source.name, 'reason': 'missing'},
      ]);
      expect(jsonEncode(h.requests.single.body), contains('WORKING CONTENT'));
      expect(await h.engine.lorebook(_bad), _badRaw, reason: 'Raw editing/export reads retain the authoritative data.');
    });
  }

  test('a cold explicit primary validates entries without first enumerating the directory', () async {
    final h = await generationFixture();
    final character = await h.card('Cold primary');
    final chat = await h.engine.createChat(character);
    await _writeBad(h, _bad, jsonEncode(_badRaw));
    await h.engine.setSettings({
      'characterPrimaryLorebooks': {character: _bad},
    });
    await _expectMissingAndHttp(h, chat, [
      {'bookId': _bad, 'source': 'character', 'reason': 'missing'},
    ]);
  });

  test('known unreadable JSON and root shape use the same missing diagnostic', () async {
    final h = await generationFixture();
    final character = await h.card('Unreadable documents');
    final chat = await h.engine.createChat(character);
    await _writeBad(h, 'invalid-json', '{broken');
    await _writeBad(h, 'invalid-root', '[]');
    final context = await h.context(chat, characterId: character);
    final directory = await h.bridge.getBookDirectory(context.id);
    expect(directory.books.where((book) => !book.readable), hasLength(2));
    await h.engine.bindLorebooks(['invalid-json', 'invalid-root']);
    await _expectMissingAndHttp(h, chat, [
      {'bookId': 'invalid-json', 'source': 'global', 'reason': 'missing'},
      {'bookId': 'invalid-root', 'source': 'global', 'reason': 'missing'},
    ]);
  });

  test('a repaired standalone becomes readable without deleting its existing binding', () async {
    final h = await generationFixture();
    final character = await h.card('Repair book');
    final chat = await h.engine.createChat(character);
    await _writeBad(h, _bad, jsonEncode(_badRaw));
    final context = await h.context(chat, characterId: character);
    await h.bridge.getBookDirectory(context.id);
    await h.engine.bindLorebooks([_bad]);
    await _expectMissingAndHttp(h, chat, [
      {'bookId': _bad, 'source': 'global', 'reason': 'missing'},
    ]);
    expect(await h.engine.lorebook(_bad), _badRaw);
    await h.engine.putLorebook(_bad, _book('REPAIRED CONTENT'));
    final repaired = await h.bridge.getBookDirectory(context.id);
    expect(repaired.books.singleWhere((book) => book.handle == 'standalone:$_bad').readable, isTrue);
    h.reply('MODEL');
    final events = await h.engine.send(chat, 'again').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    expect(jsonEncode(h.requests.last.body), contains('REPAIRED CONTENT'));
    expect((await h.engine.inspectTurn(chat))!.worldInfo.containsKey('missing'), isFalse);
    expect(scriptMap((await h.engine.readSettings())['lorebooks'])['global'], [_bad]);
  });
}

Future<void> _writeBad(ScriptFixture h, String id, String json) async {
  final file = File('${h.root.path}/lorebooks/$id.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(json, flush: true);
}

Future<void> _expectMissingAndHttp(ScriptFixture h, String chat, List<ScriptJson> missing) async {
  h.reply('MODEL');
  final events = await h.engine.send(chat, 'read the available books').toList();
  final failures = events.whereType<TavernTurnFailed>().toList();
  expect(failures, isEmpty, reason: failures.map((failure) => '${failure.kind.name}: ${failure.detail}').join('\n'));
  final done = events.whereType<TavernTurnDone>().single;
  expect(done.message.text, 'MODEL');
  final inspection = (await h.engine.inspectTurn(chat, nodeId: done.message.nodeId))!;
  expect(inspection.worldInfo['missing'], missing);
}

ScriptJson _book(String content) => {
  'name': 'Readable',
  'entries': {
    '1': {'uid': 1, 'key': <String>[], 'content': content, 'constant': true, 'disable': false, 'position': 0},
  },
};
