import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('resolve separates group host definitions from actor regex and retains muted roster books', () async {
    final h = await ScriptFixture.open();
    final hostExtension = scriptStateExtension(initial: 7);
    hostExtension['regex_scripts'] = [_regex('host-rule')];
    final actorExtension = scriptStateExtension(initial: 99);
    actorExtension['regex_scripts'] = [_regex('actor-rule')];
    actorExtension['world'] = 'Actor world';
    final host = await h.card('Outside host', extensions: hostExtension);
    final actor = await h.card('Selected actor', extensions: actorExtension);
    final muted = await h.card(
      'Muted member',
      extensions: {
        'regex_scripts': [_regex('muted-rule')],
      },
    );
    for (final id in ['host-wi', 'actor-wi', 'muted-wi']) {
      await h.engine.putLorebook(id, _book(id));
    }
    await h.engine.putLorebook('actor-auto', {..._book('automatic actor world'), 'name': 'Actor world'});
    await h.engine.bindLorebooks(['host-wi'], source: WorldInfoSource.character, characterId: host);
    await h.engine.bindLorebooks(['actor-wi'], source: WorldInfoSource.character, characterId: actor);
    await h.engine.bindLorebooks(['muted-wi'], source: WorldInfoSource.character, characterId: muted);
    final chat = await h.engine.createGroupChat([actor, muted], hostCharacterId: host, addGreetings: false);
    await h.engine.updateGroupMember(chat, muted, muted: true);
    final group = (await h.engine.groupChat(chat))!;
    expect(group.hostCharacterId, host);
    expect(group.members.map((member) => member.characterId), [actor, muted]);
    expect(group.members.last.muted, isTrue);
    expect(await h.engine.path(chat), isEmpty);

    // createGroupChat has already adopted the host's initial state. Only the
    // subsequent resolve is expected to be read-only.
    final before = _rows(h);
    final paths = [
      'settings.json',
      for (final id in [host, actor, muted]) ...['characters/$id/card.json', 'characters/$id/library.json'],
      for (final id in ['host-wi', 'actor-wi', 'muted-wi']) 'lorebooks/$id.json',
      'lorebooks/actor-auto.json',
    ];
    final files = await _files(h, paths);
    var randomReads = 0;
    h.onRandom = () => randomReads++;
    final result = await h.engine.resolveGameplayConfig(
      TavernGameplayContext(characterId: actor, chatId: chat),
      validateCurrentState: true,
    );
    expect(result.context.characterId, actor);
    expect(result.context.chatId, chat);
    expect(result.hostCharacterId, host);
    expect(result.rawPresent, isTrue);
    expect(result.raw, hostExtension['dshgo']);
    expect(_map(_map(result.effective)['state'])['init'], {'count': 7});
    expect(result.definitions.singleWhere((item) => item['path'] == '/state')['executable'], isTrue);
    final current = result.currentState!;
    expect(current.source, {'kind': 'state', 'chatId': chat, 'nodeId': null});
    expect(current.valueExists, isTrue);
    expect(current.value, {'count': 7});
    expect(current.validated, isTrue);
    expect(current.issues, isEmpty);
    final books = result.resources.where((item) => item['kind'] == 'lorebook').toList();
    expect(books.map((item) => _map(item['resource'])['bookId']), ['actor-auto', 'actor-wi', 'muted-wi']);
    expect(books.map((item) => item['bucket']), everyElement('character'));
    expect(books.map((item) => _map(item['resource'])['phase']), everyElement('linked'));
    expect(books.map((item) => _map(item['source'])['characterId']), [actor, actor, muted]);
    final regex = result.resources.singleWhere((item) => item['kind'] == 'regex' && item['bucket'] == 'character');
    expect(regex['source'], {'kind': 'card', 'characterId': actor});
    expect(_map(regex['resource'])['pointer'], '/extensions/regex_scripts');
    expect((regex['entries']! as List<Object?>).map((entry) => _map(entry)['stId']), ['actor-rule']);
    expect(result.conflicts, isEmpty);
    final hostView = await h.engine.resolveGameplayConfig(TavernGameplayContext(characterId: host, chatId: chat));
    final mutedView = await h.engine.resolveGameplayConfig(TavernGameplayContext(characterId: muted, chatId: chat));
    expect(hostView.effectiveConfigId, result.effectiveConfigId);
    expect(mutedView.effectiveConfigId, result.effectiveConfigId);
    expect(
      mutedView.resources.singleWhere((item) => item['kind'] == 'regex' && item['bucket'] == 'character')['source'],
      {'kind': 'card', 'characterId': muted},
    );
    expect(_rows(h), before);
    expect(await _files(h, paths), files);
    expect(randomReads, 0);
    h.expectNoGeneration();
  });

  test('resolve reads the selected physical missing or null value without initialization or derive', () async {
    final h = await ScriptFixture.open();
    final definition = <String, Object?>{
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'properties': {
            'n': {
              'type': 'number',
              'default': 0,
              'x-dsh-derive': {
                '/': [1, 0],
              },
            },
          },
        },
        'init': <String, Object?>{},
        'summary': '{{setglobalvar::resolve-must-not-run::yes}}',
      },
    };
    final character = await h.card('Saved values', extensions: {'dshgo': definition});
    final withoutValueRequest = await h.engine.resolveGameplayConfig(TavernGameplayContext(characterId: character));
    final unavailableValue = await h.engine.resolveGameplayConfig(
      TavernGameplayContext(characterId: character),
      validateCurrentState: true,
    );
    expect(unavailableValue.effectiveConfigId, withoutValueRequest.effectiveConfigId);
    expect(unavailableValue.currentState, isNull);
    expect(unavailableValue.conflicts.map((issue) => issue['code']), contains('not_available'));
    expect(withoutValueRequest.conflicts.map((issue) => issue['code']), isNot(contains('not_available')));
    final variables = <Json>[
      {'dshgo': null, 'foreign': 'null-node'},
      {'foreign': 'missing-node'},
      {
        'dshgo': {'n': 5},
        'foreign': 'value-node',
      },
    ];
    final chat = await _importSavedValues(h, character, variables);
    final path = await h.engine.path(chat);
    expect(path, hasLength(3));
    final paths = ['settings.json', 'characters/$character/card.json', 'characters/$character/library.json'];
    final files = await _files(h, paths);
    var randomReads = 0;
    h.onRandom = () => randomReads++;
    for (var index = 0; index < variables.length; index++) {
      final nodeId = path[index].nodeId;
      await h.engine.selectNode(chat, nodeId);
      final saved = variables[index];
      expect(_messageVariables(h, nodeId), saved);
      // Selection itself restores metadata; the observation baseline follows it.
      final before = _rows(h);
      final result = await h.engine.resolveGameplayConfig(
        TavernGameplayContext(characterId: character, chatId: chat),
        validateCurrentState: true,
      );
      final current = result.currentState!;
      final valueExists = saved.containsKey('dshgo');
      final value = saved['dshgo'];
      expect(current.source, {'kind': 'state', 'chatId': chat, 'nodeId': nodeId});
      expect(current.valueExists, valueExists);
      expect(current.value, value);
      final expected = validateDshgoStateValue(definition, valueExists: valueExists, value: value);
      expect(current.validated, expected.validated);
      expect(
        current.issues.map((issue) => issue['diagnostic']),
        expected.issues.map((issue) => Map<String, Object?>.from(issue)..remove('sourcePath')),
      );
      for (final issue in current.issues) {
        expect(issue['source'], current.source);
      }
      if (index == 2) {
        expect(current.issues, isEmpty);
      }
      expect(_rows(h), before);
      expect(_messageVariables(h, nodeId), saved);
      expect(await _files(h, paths), files);
    }
    expect(randomReads, 0);
    h.expectNoGeneration();
  });
}

Json _map(Object? value) => value! as Json;

Json _regex(String id) => {
  'id': id,
  'scriptName': id,
  'findRegex': '/TOKEN/g',
  'replaceString': id,
  'placement': [2],
};

Json _book(String content) => {
  'entries': {
    '0': {'uid': 0, 'key': <String>[], 'content': content, 'constant': true, 'order': 100, 'disable': false},
  },
};

Json _rows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

Future<Map<String, List<int>>> _files(ScriptFixture h, List<String> paths) async => {
  for (final path in paths) path: await File('${h.root.path}/$path').readAsBytes(),
};

Json _messageVariables(ScriptFixture h, String nodeId) => h.inspect((db) {
  final row = db.select('SELECT extra FROM nodes WHERE id = ?', [nodeId]).single;
  final extra = _map(jsonDecode(row['extra']! as String));
  return _map(_map(_map(extra['dshgo'])['tavernState'])['messageVariables']);
});

Future<String> _importSavedValues(ScriptFixture h, String characterId, List<Json> values) async {
  final document = StChatDocument(
    fileName: 'resolve-saved-values.jsonl',
    header: {
      'user_name': 'User',
      'character_name': 'Saved values',
      'chat_metadata': {
        'variables': {'local': 'kept'},
      },
    },
    messages: [
      for (var index = 0; index < values.length; index++)
        {
          'name': 'Saved values',
          'is_user': false,
          'is_system': false,
          'mes': 'saved-$index',
          'send_date': DateTime.utc(2026, 11, 12, 5, index).toIso8601String(),
          'variables': [values[index]],
          'extra': {
            'dshgo': {
              'tavernState': {
                'variables': {'local': 'kept'},
                'timedWorldInfo': <String, Object?>{},
                'decoratorState': <String, Object?>{},
                'messageVariables': values[index],
              },
            },
          },
        },
    ],
  );
  return (await h.engine.importChats(characterId, [
    TavernChatFile(fileName: document.fileName, bytes: document.encode()),
  ])).chatIds.single;
}
