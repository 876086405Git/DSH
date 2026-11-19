import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database database;
  late ChatStore store;
  var serial = 0;
  var milliseconds = 1000;

  setUp(() {
    serial = 0;
    milliseconds = 1000;
    database = sqlite3.openInMemory();
    store = ChatStore.fromDatabase(
      database,
      clock: () => DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
      createId: () => 'generated-${serial++}',
    );
  });

  tearDown(() async {
    await store.close();
  });

  TavernMessage append(String chat, String text, {String? parent, Map<String, Object?>? state}) {
    return store.append(chat, parentId: parent, role: TavernRole.character, speaker: '鲸鱼', text: text, state: state);
  }

  List<String> pathText(String chat) => store.path(chat, limit: 100).map((message) => message.text).toList();

  test('chat documents round-trip without aliasing returned JSON', () {
    final id = store.createChat(
      characterId: 'card',
      title: '世界 🌊',
      metadata: {
        'unknown': {'line': '第一行\r\n第二行', 'null': null},
      },
      variables: {'level': 3},
      settings: {
        'lorebooks': ['海港'],
        'enhanced': false,
      },
    );
    expect(store.path(id), isEmpty);
    final chat = store.chat(id);
    expect(chat.currentLeafId, isNull);
    expect(chat.selectedRootId, isNull);
    expect(chat.metadata, {
      'unknown': {'line': '第一行\r\n第二行', 'null': null},
    });
    expect(chat.variables, {'level': 3});
    expect(chat.settings, {
      'lorebooks': ['海港'],
      'enhanced': false,
    });
    chat.variables['level'] = 99;
    expect(store.chat(id).variables['level'], 3);
    store.updateChat(id, title: '改名', personaId: 'persona', presetId: 'preset', variables: {'level': 4});
    store.updateChat(id, clearPersona: true, clearPreset: true);
    expect(store.chat(id).title, '改名');
    expect(store.chat(id).variables['level'], 4);
    expect(store.chat(id).personaId, isNull);
    expect(store.chat(id).presetId, isNull);
    expect(store.chat(id).metadata, chat.metadata);
  });

  test('script reads keep variable shapes and swipe evidence without private payloads', () {
    final chat = store.createChat(characterId: 'card');
    final extra = <String, Object?>{
      'foreign': {
        'items': [null, '\ufeffkept'],
      },
      'scriptExtra': ['ordinary user key'],
      'dshgo': {
        'inspection': {'private': 'prompt evidence'},
        'branchName': 'private label',
        'tavernState': {
          'messageVariables': null,
          'other': [1, false],
        },
      },
    };
    final original = <String, Object?>{
      'mes': 'imported body',
      'swipes': ['imported body', 'other body'],
      'extra': {'duplicate': true},
      'swipe_id': 1,
      'swipe_info': [
        null,
        {
          'unknown': [false, 'kept'],
          'send_date': null,
          'gen_started': false,
        },
      ],
      'send_date': null,
      'gen_finished': [1, 'opaque'],
      'vendor': {'keep': true},
    };
    final saved = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: '\ufeffSpeaker',
      text: '\ufeffcurrent body',
      extra: extra,
      original: original,
      state: {
        'messageVariables': {'physical': true},
      },
    );
    final expectedOriginal = Map<String, Object?>.of(original)
      ..remove('mes')
      ..remove('swipes')
      ..remove('extra');
    final projected =
        jsonDecode(
              database.select('SELECT display_context FROM nodes WHERE id = ?', [
                    saved.nodeId,
                  ]).single['display_context']
                  as String,
            )
            as Map<String, Object?>;
    expect(projected, {
      'dshgo': {
        'tavernState': {
          'messageVariables': null,
          'other': [1, false],
        },
        'chatJsonl': null,
      },
      'scriptExtra': {'foreign': extra['foreign'], 'scriptExtra': extra['scriptExtra']},
    });
    for (final node in [store.scriptHistoryTo(chat, saved.nodeId).single, store.scriptChildren(chat, null).single]) {
      expect([node.message.speaker, node.message.text], ['\ufeffSpeaker', '\ufeffcurrent body']);
      expect(node.extra, {
        'foreign': extra['foreign'],
        'scriptExtra': extra['scriptExtra'],
        'dshgo': {
          'tavernState': {
            'messageVariables': null,
            'other': [1, false],
          },
        },
      });
      expect(node.original, expectedOriginal);
      (node.extra['foreign']! as Map<String, Object?>)['items'] = 'caller mutation';
      (node.original['vendor']! as Map<String, Object?>)['keep'] = false;
    }
    expect(store.node(chat, saved.nodeId).extra, extra);
    expect(store.node(chat, saved.nodeId).original, original);
    expect(store.nodeState(chat, saved.nodeId), {
      'messageVariables': {'physical': true},
    });
    store.beginStreamingWrites();
    try {
      store.writeStreamingBody(chat, saved.nodeId, text: '\ufeffdraft', reasoning: null);
      expect(store.scriptHistoryTo(chat, saved.nodeId).single.message.text, '\ufeffdraft');
      expect(store.scriptChildren(chat, null).single.message.text, '\ufeffdraft');
      expect(store.rawNodeExtra(chat, saved.nodeId), extra);
    } finally {
      store.endStreamingWrites();
    }
  });

  test('script extra projection supports legacy rows and rolls back with its raw carrier', () {
    final chat = store.createChat(characterId: 'card');
    final saved = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Speaker',
      text: 'Body',
      extra: {
        'foreign': [null, '\ufeffold'],
        'dshgo': {
          'inspection': {'private': true},
        },
      },
    );
    Map<String, Object?> scriptExtra() => store.scriptHistoryTo(chat, saved.nodeId).single.extra;
    Map<String, Object?> rawRow() => Map<String, Object?>.from(
      database.select('SELECT extra, display_context FROM nodes WHERE id = ?', [saved.nodeId]).single,
    );
    final before = rawRow();
    database.execute("UPDATE nodes SET display_context = json_remove(display_context, '\$.scriptExtra') WHERE id = ?", [
      saved.nodeId,
    ]);
    expect(scriptExtra(), {
      'foreign': [null, '\ufeffold'],
    });
    // An explicitly present empty projection is complete, not an absent cache.
    database.execute(
      "UPDATE nodes SET display_context = json_set(display_context, '\$.scriptExtra', json('{}')) WHERE id = ?",
      [saved.nodeId],
    );
    expect(scriptExtra(), isEmpty);
    database.execute('UPDATE nodes SET display_context = ? WHERE id = ?', [before['display_context'], saved.nodeId]);
    expect(
      () => store.transaction<void>(() {
        store.updateMessage(
          chat,
          saved.nodeId,
          extra: {
            'replacement': {'n': 2},
          },
        );
        expect(scriptExtra(), {
          'replacement': {'n': 2},
        });
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(rawRow(), before);
    store.updateMessage(chat, saved.nodeId, extra: {'replacement': null});
    expect(scriptExtra(), {'replacement': null});
    expect(store.scriptChildren(chat, null).single.extra, {'replacement': null});
    expect(store.rawNodeExtra(chat, saved.nodeId), {'replacement': null});
  });

  test('script state reads preserve complete portable priority and fresh physical state', () async {
    final chat = store.createChat(characterId: 'card');
    final other = store.createChat(characterId: 'other');
    final saved = append(
      chat,
      'Body',
      state: {
        'messageVariables': {'n': 1},
        'other': [null, false],
      },
    );
    final physical = store.scriptNodeState(chat, saved.nodeId);
    expect(physical, {
      'messageVariables': {'n': 1},
      'other': [null, false],
    });
    (physical['messageVariables']! as Map<String, Object?>)['n'] = 'caller mutation';
    expect(store.scriptNodeState(chat, saved.nodeId)['messageVariables'], {'n': 1});
    for (final override in <Object?>[
      null,
      ['invalid'],
      'invalid',
    ]) {
      store.updateMessage(
        chat,
        saved.nodeId,
        extra: {
          'dshgo': {'tavernState': override},
        },
      );
      expect(store.scriptNodeState(chat, saved.nodeId), store.nodeState(chat, saved.nodeId));
    }
    store.updateMessage(
      chat,
      saved.nodeId,
      extra: {
        'dshgo': {'tavernState': <String, Object?>{}},
      },
    );
    expect(store.scriptNodeState(chat, saved.nodeId), isEmpty);
    final portable = <String, Object?>{
      'messageVariables': null,
      'unknown': [1, false],
    };
    store.updateMessage(
      chat,
      saved.nodeId,
      extra: {
        'dshgo': {'tavernState': portable},
      },
    );
    store.writeNodeState(chat, saved.nodeId, {
      'messageVariables': {'n': 2},
    });
    expect(store.scriptNodeState(chat, saved.nodeId), portable);
    (store.scriptNodeState(chat, saved.nodeId)['unknown']! as List<Object?>).clear();
    expect(store.scriptNodeState(chat, saved.nodeId), portable);
    store.updateMessage(chat, saved.nodeId, extra: {});
    expect(store.scriptNodeState(chat, saved.nodeId), {
      'messageVariables': {'n': 2},
    });
    expect(
      () => store.transaction<void>(() {
        store.writeNodeState(chat, saved.nodeId, {
          'messageVariables': ['raw-array'],
        });
        expect(store.scriptNodeState(chat, saved.nodeId), {
          'messageVariables': ['raw-array'],
        });
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(store.scriptNodeState(chat, saved.nodeId), {
      'messageVariables': {'n': 2},
    });
    expect(() => store.scriptNodeState(other, saved.nodeId), throwsStateError);
    final token = store.softDeleteFrom(chat, saved.nodeId);
    expect(() => store.scriptNodeState(chat, saved.nodeId), throwsStateError);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(store.scriptNodeState(chat, saved.nodeId), {
      'messageVariables': {'n': 2},
    });
    await store.close();
    expect(() => store.scriptNodeState(chat, saved.nodeId), throwsStateError);
  });

  test('read tokens and scalar identities observe state commits and isolate rollbacks', () {
    final chat = store.createChat(characterId: 'host', variables: {'n': 1});
    final other = store.createChat(characterId: 'other');
    final root = append(
      chat,
      'root',
      state: {
        'messageVariables': {'n': 1},
      },
    );
    final before = store.displayVersion(chat);
    final otherBefore = store.displayVersion(other);
    final revision = store.treeRevision(chat);
    store.chatVariables(chat)['n'] = 'detached';
    expect(store.chatVariables(chat), {'n': 1});
    Object? temporary;
    expect(
      () => store.transaction<void>(() {
        store.writeNodeState(chat, root.nodeId, {
          'messageVariables': {'n': 2},
        });
        store.updateChat(chat, variables: {'n': 2});
        final child = append(chat, 'temporary', parent: root.nodeId);
        temporary = store.displayVersion(chat);
        expect(identical(temporary, before), isFalse);
        expect(store.chatCharacterId(chat), 'host');
        expect(store.chatCurrentLeafId(chat), child.nodeId);
        expect(store.chatVariables(chat), {'n': 2});
        expect(store.contextAnchor(chat).selectedLeaf?.nodeId, child.nodeId);
        expect(store.treeRevision(chat), greaterThan(revision));
        expect(store.nodeState(chat, root.nodeId), {
          'messageVariables': {'n': 2},
        });
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(identical(store.displayVersion(chat), before), isTrue);
    expect(identical(store.displayVersion(chat), temporary), isFalse);
    expect(store.chatCurrentLeafId(chat), root.nodeId);
    expect(store.chatVariables(chat), {'n': 1});
    expect(store.treeRevision(chat), revision);
    expect(store.nodeState(chat, root.nodeId), {
      'messageVariables': {'n': 1},
    });
    store.writeNodeState(chat, root.nodeId, {
      'messageVariables': {'n': 3},
    });
    expect(identical(store.displayVersion(chat), before), isFalse);
    expect(identical(store.displayVersion(other), otherBefore), isTrue);
    expect(store.nodeState(chat, root.nodeId), {
      'messageVariables': {'n': 3},
    });
    for (final read in <void Function()>[
      () => store.chatCharacterId('missing'),
      () => store.chatCurrentLeafId('missing'),
      () => store.chatVariables('missing'),
      () => store.treeRevision('missing'),
      () => store.contextAnchor('missing'),
      () => store.scriptHistoryTo('missing', null),
    ]) {
      expect(read, throwsA(isA<StateError>().having((error) => error.message, 'message', 'Chat not found: missing')));
    }
  });

  test('summaries count the selected path and sort by last change', () {
    final first = store.createChat(characterId: 'card', title: 'one');
    final root = append(first, 'opening');
    append(first, 'reply A', parent: root.nodeId);
    append(first, 'reply B', parent: root.nodeId);
    milliseconds = 2000;
    final second = store.createChat(characterId: 'other', title: 'two');
    expect(store.listChats().map((chat) => chat.id), [second, first]);
    expect(store.listChats(characterId: 'card').single.messageCount, 2);
    expect(store.listChats(characterId: 'card').single.lastText, 'reply B');
    milliseconds = 3000;
    store.edit(first, root.nodeId, 'edited');
    expect(store.listChats().first.id, first);
  });

  test('siblings remember their descendants and selecting one repairs ancestors', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'greeting');
    final a = append(chat, 'A', parent: root.nodeId);
    append(chat, 'A child', parent: a.nodeId);
    final b = append(chat, 'B', parent: root.nodeId);
    final bChild = append(chat, 'B child', parent: b.nodeId);
    expect(pathText(chat), ['greeting', 'B', 'B child']);
    expect(store.message(chat, a.nodeId).siblingIndex, 0);
    expect(store.message(chat, b.nodeId).siblingIndex, 1);
    expect(store.message(chat, a.nodeId).siblingCount, 2);
    store.selectSibling(chat, b.nodeId, 0);
    expect(pathText(chat), ['greeting', 'A', 'A child']);
    store.selectNode(chat, bChild.nodeId);
    expect(pathText(chat), ['greeting', 'B', 'B child']);
    expect(store.node(chat, root.nodeId).selectedChildId, b.nodeId);
    store.selectNode(chat, b.nodeId, restoreDescendants: false);
    expect(pathText(chat), ['greeting', 'B']);
    expect(store.children(chat, b.nodeId).single.message.nodeId, bChild.nodeId);
  });

  test('explicit null parent creates a root alternative with a separate remembered path', () {
    final chat = store.createChat(characterId: 'card');
    final a = append(chat, 'opening A');
    final aChild = append(chat, 'A child', parent: a.nodeId);
    final b = append(chat, 'opening B');
    expect(store.message(chat, b.nodeId).parentId, isNull);
    expect(store.children(chat, null).length, 2);
    store.selectSibling(chat, b.nodeId, 0);
    expect(store.chat(chat).currentLeafId, aChild.nodeId);
    expect(store.chat(chat).selectedRootId, a.nodeId);
    store.selectSibling(chat, a.nodeId, 1);
    expect(pathText(chat), ['opening B']);
  });

  test('unselected imports do not move the selected path', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'root');
    final current = append(chat, 'selected', parent: root.nodeId);
    final imported = store.append(
      chat,
      parentId: root.nodeId,
      role: TavernRole.character,
      speaker: '鲸鱼',
      text: 'imported',
      makeCurrent: false,
    );
    expect(store.chat(chat).currentLeafId, current.nodeId);
    expect(store.node(chat, root.nodeId).selectedChildId, current.nodeId);
    store.selectNode(chat, imported.nodeId);
    expect(pathText(chat), ['root', 'imported']);
  });

  test('paging is exclusive, oldest first, and rejects a cursor from another branch', () {
    final chat = store.createChat(characterId: 'card');
    final nodes = <TavernMessage>[];
    for (var i = 0; i < 8; i++) {
      nodes.add(append(chat, '$i', parent: nodes.isEmpty ? null : nodes.last.nodeId));
    }
    expect(store.path(chat, limit: 3).map((message) => message.text), ['5', '6', '7']);
    expect(store.path(chat, limit: 3, beforeNodeId: nodes[5].nodeId).map((message) => message.text), ['2', '3', '4']);
    expect(store.path(chat, limit: 3, beforeNodeId: nodes.first.nodeId), isEmpty);
    expect(store.path(chat, limit: 0), isEmpty);
    expect(() => store.path(chat, limit: -1), throwsArgumentError);
    final alternate = append(chat, 'alternate', parent: nodes[5].nodeId);
    expect(() => store.path(chat, beforeNodeId: nodes[7].nodeId), throwsStateError);
    expect(store.path(chat, beforeNodeId: alternate.nodeId).last.nodeId, nodes[5].nodeId);
  });

  test('deleting the current subtree chooses an adjacent sibling and restores its children', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'root');
    final a = append(chat, 'A', parent: root.nodeId);
    append(chat, 'A child', parent: a.nodeId);
    final b = append(chat, 'B', parent: root.nodeId);
    final bChild = append(chat, 'B child', parent: b.nodeId);
    final c = append(chat, 'C', parent: root.nodeId);
    append(chat, 'C child', parent: c.nodeId);
    store.selectNode(chat, b.nodeId);
    store.deleteFrom(chat, b.nodeId);
    expect(pathText(chat), ['root', 'C', 'C child']);
    expect(() => store.message(chat, bChild.nodeId), throwsStateError);
    expect(() => store.nodeState(chat, bChild.nodeId), throwsStateError);
    expect(store.message(chat, c.nodeId).siblingIndex, 1);
    expect(store.message(chat, c.nodeId).siblingCount, 2);
    store.deleteFrom(chat, c.nodeId);
    expect(pathText(chat), ['root', 'A', 'A child']);
  });

  test('deleting an inactive remembered branch does not change the active leaf', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'root');
    final a = append(chat, 'A', parent: root.nodeId);
    final aFirst = append(chat, 'A first', parent: a.nodeId);
    final aSecond = append(chat, 'A second', parent: a.nodeId);
    final b = append(chat, 'B', parent: root.nodeId);
    final bChild = append(chat, 'B child', parent: b.nodeId);
    store.deleteFrom(chat, aSecond.nodeId);
    expect(store.chat(chat).currentLeafId, bChild.nodeId);
    expect(store.node(chat, a.nodeId).selectedChildId, aFirst.nodeId);
    expect(pathText(chat), ['root', 'B', 'B child']);
    store.selectNode(chat, a.nodeId);
    expect(pathText(chat), ['root', 'A', 'A first']);
  });

  test('deleting the only child returns to its parent; deleting the last root leaves an empty chat', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'root');
    final child = append(chat, 'child', parent: root.nodeId);
    append(chat, 'grandchild', parent: child.nodeId);
    store.deleteFrom(chat, child.nodeId);
    expect(pathText(chat), ['root']);
    expect(store.node(chat, root.nodeId).selectedChildId, isNull);
    store.deleteFrom(chat, root.nodeId);
    expect(store.path(chat), isEmpty);
    expect(store.allNodes(chat), isEmpty);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(store.chat(chat).selectedRootId, isNull);
    expect(store.listChats().single.messageCount, 0);
  });

  test('cross-chat node references fail before any write', () {
    final a = store.createChat(characterId: 'card');
    final b = store.createChat(characterId: 'card');
    final node = append(a, 'A');
    final other = append(b, 'B');
    expect(() => append(b, 'wrong', parent: node.nodeId), throwsStateError);
    expect(() => store.edit(b, node.nodeId, 'wrong'), throwsStateError);
    expect(() => store.setHidden(b, node.nodeId, true), throwsStateError);
    expect(() => store.selectSibling(b, node.nodeId, 0), throwsStateError);
    expect(() => store.selectNode(b, node.nodeId), throwsStateError);
    expect(() => store.deleteFrom(b, node.nodeId), throwsStateError);
    expect(() => store.path(b, beforeNodeId: node.nodeId), throwsStateError);
    expect(() => store.nodeState(b, node.nodeId), throwsStateError);
    expect(store.message(a, node.nodeId).text, 'A');
    expect(store.chat(b).currentLeafId, other.nodeId);
    expect(store.allNodes(b).length, 1);
    expect(() => store.selectSibling(b, other.nodeId, -1), throwsRangeError);
    expect(() => store.selectSibling(b, other.nodeId, 1), throwsRangeError);
  });

  test('import batches preserve id and clock order, revision counts and the last timestamp', () async {
    await store.close();
    final events = <String>[];
    const times = [1000, 3000, 4000, 2000];
    var clockIndex = 0;
    var idIndex = 0;
    store = ChatStore.inMemory(
      clock: () {
        final value = times[clockIndex++];
        events.add('clock:$value');
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      },
      createId: () {
        final id = 'batch-${idIndex++}';
        events.add('id:$id');
        return id;
      },
    );
    final chat = store.createChat(characterId: 'card');
    final ids = store.appendImportedNodes(chat, [
      for (var index = 0; index < 3; index++)
        StoredChatImportNode(
          key: 'key-$index',
          parentKey: index == 0 ? null : 'key-${index - 1}',
          role: TavernRole.character,
          speaker: '鲸鱼',
          text: 'entry $index',
          at: DateTime.utc(2026),
          hidden: false,
          state: {'slot': index},
          extra: const {},
          original: const {},
        ),
    ]);
    expect(ids, {'key-0': 'batch-1', 'key-1': 'batch-2', 'key-2': 'batch-3'});
    expect(store.treeRevision(chat), 3);
    expect(store.chat(chat).createdAt.millisecondsSinceEpoch, 1000);
    expect(store.chat(chat).updatedAt.millisecondsSinceEpoch, 2000);
    expect(store.appendImportedNodes(chat, const []), isEmpty);
    expect(store.treeRevision(chat), 3);
    expect(store.chat(chat).updatedAt.millisecondsSinceEpoch, 2000);
    expect(events, [
      'id:batch-0',
      'clock:1000',
      'id:batch-1',
      'clock:3000',
      'id:batch-2',
      'clock:4000',
      'id:batch-3',
      'clock:2000',
    ]);
  });

  test('a failed batch rolls back nodes, selected path, search index and notifications', () async {
    final chat = store.createChat(characterId: 'card');
    final events = <String>[];
    final subscription = store.changes.listen(events.add);
    expect(
      () => store.transaction<void>(() {
        final first = append(chat, 'mustrollback');
        store.append(
          chat,
          parentId: first.nodeId,
          role: TavernRole.user,
          speaker: '我',
          text: 'duplicate',
          id: first.nodeId,
        );
      }),
      throwsA(isA<SqliteException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(store.path(chat), isEmpty);
    expect(store.allNodes(chat), isEmpty);
    expect(store.search('mustrollback'), isEmpty);
    final committed = append(chat, 'committed');
    expect(store.nodeState(chat, committed.nodeId), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(events, [chat]);
    await subscription.cancel();
  });

  test('caught nested failures roll back to a savepoint; successful batch emits once', () async {
    final chat = store.createChat(characterId: 'card');
    final events = <String>[];
    final subscription = store.changes.listen(events.add);
    store.transaction<void>(() {
      final root = append(chat, 'root');
      try {
        store.transaction<void>(() {
          append(chat, 'discarded', parent: root.nodeId);
          throw StateError('abort nested import');
        });
      } on StateError {
        // The outer batch can continue; both the data and pending event roll back.
      }
      append(chat, 'kept', parent: root.nodeId);
    });
    expect(events, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(events, [chat]);
    expect(pathText(chat), ['root', 'kept']);
    expect(store.allNodes(chat).length, 2);
    await subscription.cancel();
  });

  for (final operation in ['create', 'update']) {
    test('SQLite automatic rollback during $operation preserves the error and permits recovery', () async {
      await store.close();
      final database = sqlite3.openInMemory();
      store = ChatStore.fromDatabase(database);
      final chat = store.createChat(characterId: 'card', title: 'before');
      final events = <String>[];
      final subscription = store.changes.listen(events.add);
      final pages = database.select('PRAGMA page_count').first['page_count'] as int;
      final previousLimit = database.select('PRAGMA max_page_count').first['max_page_count'] as int;
      database.execute('PRAGMA max_page_count = $pages');
      final large = {'large': List<String>.filled(1000000, 'x').join()};

      expect(() {
        if (operation == 'create') {
          store.createChat(characterId: 'card', id: 'failed', metadata: large);
        } else {
          store.updateChat(chat, title: 'must roll back', metadata: large);
        }
      }, throwsA(isA<SqliteException>().having((error) => error.resultCode, 'SQLITE_FULL', 13)));
      expect(database.autocommit, isTrue);
      expect(store.listChats().map((item) => item.id), [chat]);
      expect(store.chat(chat).title, 'before');
      expect(store.chat(chat).metadata, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      database.execute('PRAGMA max_page_count = $previousLimit');
      store.updateChat(chat, title: 'recovered');
      expect(store.chat(chat).title, 'recovered');
      await Future<void>.delayed(Duration.zero);
      expect(events, [chat]);
      await subscription.cancel();
      await store.close();
    });
  }

  test('a caught automatic rollback poisons the enclosing batch and blocks further writes', () async {
    await store.close();
    final database = sqlite3.openInMemory();
    store = ChatStore.fromDatabase(database);
    final chat = store.createChat(characterId: 'card', title: 'before');
    final root = append(chat, 'original');
    final events = <String>[];
    final subscription = store.changes.listen(events.add);
    final pages = database.select('PRAGMA page_count').first['page_count'] as int;
    final previousLimit = database.select('PRAGMA max_page_count').first['max_page_count'] as int;
    database.execute('PRAGMA max_page_count = $pages');
    SqliteException? originalError;
    Object? outerError;
    try {
      store.transaction<void>(() {
        store.updateChat(chat, title: 'pending');
        try {
          store.updateChat(chat, metadata: {'large': List<String>.filled(1000000, 'x').join()});
        } on SqliteException catch (error) {
          originalError = error;
        }
        expect(originalError?.resultCode, 13);
        expect(database.autocommit, isTrue);
        // Releasing the fault must not turn the remainder of this batch into a
        // new independent transaction after SQLite discarded the earlier edit.
        database.execute('PRAGMA max_page_count = $previousLimit');
        var entered = false;
        expect(
          () => store.transaction<void>(() {
            entered = true;
            append(chat, 'mustnotpersist', parent: root.nodeId);
          }),
          throwsA(same(originalError)),
        );
        expect(entered, isFalse);
      });
    } catch (error) {
      outerError = error;
    }
    expect(originalError, isNotNull);
    expect(outerError, same(originalError));
    expect(store.chat(chat).title, 'before');
    expect(store.chat(chat).metadata, isEmpty);
    expect(pathText(chat), ['original']);
    expect(store.search('mustnotpersist'), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    store.updateChat(chat, title: 'recovered');
    await Future<void>.delayed(Duration.zero);
    expect(events, [chat]);
    await subscription.cancel();
    await store.close();
  });

  test('async transaction callbacks are rejected before their body starts', () async {
    final chat = store.createChat(characterId: 'card', title: 'before');
    final root = append(chat, 'original');
    final events = <String>[];
    final subscription = store.changes.listen(events.add);
    var entered = false;
    Future<void> operation() async {
      entered = true;
      await Future<void>.value();
      store.updateChat(chat, title: 'late');
      append(chat, 'latewrite', parent: root.nodeId);
    }

    expect(() => store.transaction<Future<void>>(operation), throwsArgumentError);
    await Future<void>.delayed(Duration.zero);
    expect(entered, isFalse);
    expect(store.chat(chat).title, 'before');
    expect(pathText(chat), ['original']);
    expect(store.search('latewrite'), isEmpty);
    expect(events, isEmpty);
    await subscription.cancel();
  });

  test('a Future hidden behind an Object return type is rejected and its error is observed', () async {
    Object operation() => Future<void>.error(StateError('unsupported asynchronous result'));
    expect(() => store.transaction<Object>(operation), throwsArgumentError);
    await Future<void>.delayed(Duration.zero);
    final chat = store.createChat(characterId: 'card');
    expect(store.chat(chat).characterId, 'card');
  });

  test('stream updates, edits and hidden flags preserve reasoning, usage and unknown fields', () {
    final chat = store.createChat(characterId: 'card');
    final node = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: '鲸鱼',
      text: '',
      extra: {
        'model_extension': ['keep', 1],
      },
      original: {'send_date': 'original date', 'future_field': null},
    );
    store.updateMessage(chat, node.nodeId, text: '半', reasoning: '思考');
    store.updateMessage(
      chat,
      node.nodeId,
      text: '半句话 🌊',
      usage: const TavernUsage(promptTokens: 300, cacheHitTokens: 200, completionTokens: 10, model: 'fake-model'),
    );
    store.edit(chat, node.nodeId, '编辑过的句子');
    store.setHidden(chat, node.nodeId, true);
    final saved = store.message(chat, node.nodeId);
    expect(saved.text, '编辑过的句子');
    expect(saved.reasoning, '思考');
    expect(saved.usage!.cacheHitTokens, 200);
    expect(saved.usage!.model, 'fake-model');
    expect(saved.hidden, isTrue);
    expect(store.path(chat).single.hidden, isTrue);
    expect(store.node(chat, node.nodeId).extra, {
      'model_extension': ['keep', 1],
    });
    expect(store.node(chat, node.nodeId).original, {'send_date': 'original date', 'future_field': null});
    store.updateMessage(chat, node.nodeId, clearReasoning: true, clearUsage: true);
    expect(store.message(chat, node.nodeId).reasoning, isNull);
    expect(store.message(chat, node.nodeId).usage, isNull);
  });

  test('FTS follows edits and subtree/chat deletion without stale hits', () {
    final a = store.createChat(characterId: 'card');
    final b = store.createChat(characterId: 'other');
    final node = append(a, 'seaside beacon');
    append(b, 'seaside second');
    expect(store.search('seaside').length, 2);
    expect(store.search('seaside', chatId: a).single.nodeId, node.nodeId);
    store.edit(a, node.nodeId, 'forest beacon');
    expect(store.search('seaside', chatId: a), isEmpty);
    expect(store.search('forest').single.nodeId, node.nodeId);
    store.deleteFrom(a, node.nodeId);
    expect(store.search('forest'), isEmpty);
    store.deleteCharacterChats('other');
    expect(store.search('seaside'), isEmpty);
    expect(store.listChats().single.id, a);
    store.deleteChat(a);
    expect(store.listChats(), isEmpty);
  });

  test('state snapshots are branch-local and preserve JSON Pointer keys', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(
      chat,
      'root',
      state: {
        'a/b': {
          '~k': [1, '海'],
        },
        'remove': true,
      },
    );
    final a = append(
      chat,
      'A',
      parent: root.nodeId,
      state: {
        'a/b': {
          '~k': [2, '海'],
        },
        '~new': null,
      },
    );
    final b = append(
      chat,
      'B',
      parent: root.nodeId,
      state: {
        'a/b': {
          '~k': [3],
        },
        'onlyB': 7,
      },
    );
    final inherited = append(chat, 'inherited', parent: b.nodeId);
    store.selectSibling(chat, b.nodeId, 0);
    expect(store.nodeState(chat, store.chat(chat).currentLeafId!), {
      'a/b': {
        '~k': [2, '海'],
      },
      '~new': null,
    });
    expect(store.nodeState(chat, root.nodeId), {
      'a/b': {
        '~k': [1, '海'],
      },
      'remove': true,
    });
    store.selectSibling(chat, a.nodeId, 1);
    expect(store.chat(chat).currentLeafId, inherited.nodeId);
    expect(store.nodeState(chat, inherited.nodeId), {
      'a/b': {
        '~k': [3],
      },
      'onlyB': 7,
    });
    final detached = store.nodeState(chat, inherited.nodeId);
    detached['onlyB'] = 999;
    expect(store.nodeState(chat, inherited.nodeId)['onlyB'], 7);
  });

  test('reopening preserves remembered branches and checkpoints use path depth, not insertion count', () async {
    await store.close();
    final directory = Directory.systemTemp.createTempSync('tavern-store-');
    final path = '${directory.path}/nested/tavern.db';
    try {
      store = ChatStore.open(path);
      final chat = store.createChat(
        characterId: 'card',
        metadata: {
          'timedWorldInfo': {
            'keep': [1, 2],
          },
        },
      );
      final nodes = <TavernMessage>[];
      for (var depth = 1; depth <= 43; depth++) {
        nodes.add(
          append(
            chat,
            'depth $depth',
            parent: nodes.isEmpty ? null : nodes.last.nodeId,
            state: {
              'depth': depth,
              'nested': {'名字': '鲸鱼 🌊'},
            },
          ),
        );
      }
      final alternate = append(chat, 'alternate at 20', parent: nodes[18].nodeId, state: {'branch': 'alternative'});
      store.selectNode(chat, nodes.last.nodeId);
      await store.close();
      final inspect = sqlite3.open(path);
      try {
        expect(inspect.select('PRAGMA user_version').first['user_version'], ChatStore.schemaVersion);
        expect(inspect.select('PRAGMA foreign_key_check'), isEmpty);
        final checkpoints = inspect.select('''SELECT n.depth FROM nodes n JOIN node_states s ON s.node_id = n.id
          WHERE s.full_json IS NOT NULL ORDER BY n.seq''');
        expect(checkpoints.map((row) => row['depth']), [1, 20, 40, 20]);
        final tables = inspect
            .select("SELECT name FROM sqlite_master WHERE type = 'table'")
            .map((row) => row['name'])
            .toSet();
        expect(
          tables,
          containsAll(['chats', 'nodes', 'node_states', 'summaries', 'memories', 'agent_runs', 'nodes_fts']),
        );
      } finally {
        inspect.close();
      }
      store = ChatStore.open(path);
      expect(store.chat(chat).currentLeafId, nodes.last.nodeId);
      expect(store.nodeState(chat, nodes.last.nodeId), {
        'depth': 43,
        'nested': {'名字': '鲸鱼 🌊'},
      });
      store.selectSibling(chat, nodes[19].nodeId, 1);
      expect(store.chat(chat).currentLeafId, alternate.nodeId);
      expect(store.nodeState(chat, alternate.nodeId), {'branch': 'alternative'});
      store.selectSibling(chat, alternate.nodeId, 0);
      expect(store.chat(chat).currentLeafId, nodes.last.nodeId);
      expect(store.chat(chat).metadata, {
        'timedWorldInfo': {
          'keep': [1, 2],
        },
      });
    } finally {
      await store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('deleting more than 1000 levels does not hit recursive FK cascade depth', () {
    final chat = store.createChat(characterId: 'card');
    String? parent;
    late String root;
    store.transaction<void>(() {
      for (var index = 0; index < 1205; index++) {
        final node = append(chat, 'level $index', parent: parent);
        if (index == 0) root = node.nodeId;
        parent = node.nodeId;
      }
    });
    expect(store.path(chat, limit: 2).map((message) => message.text), ['level 1203', 'level 1204']);
    store.deleteFrom(chat, root);
    expect(store.allNodes(chat), isEmpty);
    expect(store.path(chat), isEmpty);
    expect(store.search('level'), isEmpty);
  });

  test('future schema versions fail open without overwriting user data', () async {
    final directory = Directory.systemTemp.createTempSync('tavern-future-');
    final path = '${directory.path}/tavern.db';
    try {
      final original = sqlite3.open(path);
      original.execute('CREATE TABLE future_data(value TEXT)');
      original.execute("INSERT INTO future_data VALUES ('keep')");
      original.execute('PRAGMA user_version = 999');
      original.close();
      expect(() => ChatStore.open(path), throwsStateError);
      final inspect = sqlite3.open(path);
      try {
        expect(inspect.select('PRAGMA user_version').first['user_version'], 999);
        expect(inspect.select('SELECT value FROM future_data').single['value'], 'keep');
      } finally {
        inspect.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('closed stores reject reads and writes; close is idempotent', () async {
    await store.close();
    await store.close();
    expect(() => store.listChats(), throwsStateError);
    expect(() => store.createChat(characterId: 'card'), throwsStateError);
  });
}
