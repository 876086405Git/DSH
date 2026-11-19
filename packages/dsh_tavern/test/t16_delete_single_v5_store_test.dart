import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  const chat = 'chat';
  late Directory directory;
  late String file;
  late Database database;
  late ChatStore store;
  var serial = 0;

  ChatStore open(Database connection) => ChatStore.fromDatabase(
    connection,
    clock: () => DateTime.utc(2026, 11, 10),
    createId: () => 'generated-${++serial}',
  );

  setUp(() async {
    serial = 0;
    directory = await Directory.systemTemp.createTemp('dsh-t16-single-v5-');
    file = '${directory.path}/chat.sqlite3';
    database = sqlite3.open(file);
    store = open(database);
    store.createChat(
      id: chat,
      characterId: 'card',
      variables: {'facadeOwned': true},
      metadata: {
        'foreign': [null, 'kept'],
      },
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  String add(
    String id, {
    String? parent,
    Map<String, Object?>? state,
    bool makeCurrent = true,
    Map<String, Object?> extra = const {},
  }) => store
      .append(
        chat,
        id: id,
        parentId: parent,
        role: TavernRole.character,
        speaker: 'Guide',
        text: '${id}word',
        reasoning: 'reasoning $id',
        usage: const TavernUsage(promptTokens: 99, completionTokens: 9),
        state: state,
        makeCurrent: makeCurrent,
        extra: extra,
        original: {
          'unknown': [id, null],
        },
      )
      .nodeId;

  List<String> path() => store.path(chat, limit: 1000).map((message) => message.nodeId).toList();
  Map<String, Object?> raw(String id) =>
      Map<String, Object?>.from(database.select('SELECT * FROM nodes WHERE id=?', [id]).single);
  List<Map<String, Object?>> rows(String query) => [
    for (final row in database.select(query)) Map<String, Object?>.from(row),
  ];
  int revision() =>
      database.select('SELECT tree_revision FROM chats WHERE id=?', [chat]).single['tree_revision'] as int;
  Map<String, Object?> extra(String id) => jsonDecode(raw(id)['extra'] as String) as Map<String, Object?>;
  Map<String, Object?> full(String id) =>
      jsonDecode(
            database.select('SELECT full_json FROM node_states WHERE node_id=?', [id]).single['full_json'] as String,
          )
          as Map<String, Object?>;
  String snapshot() => jsonEncode({
    'chats': rows('SELECT * FROM chats ORDER BY id'),
    'nodes': rows('SELECT * FROM nodes ORDER BY seq'),
    'states': rows('SELECT * FROM node_states ORDER BY node_id'),
    'deletions': rows('SELECT * FROM deleted_subtrees ORDER BY id'),
  });
  List<String> fts(String query) => [
    for (final row in database.select(
      '''SELECT n.id FROM nodes_fts JOIN nodes n ON n.seq=nodes_fts.rowid
        WHERE nodes_fts MATCH ? ORDER BY n.seq''',
      [query],
    ))
      row['id'] as String,
  ];
  void integrity() {
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    expect(
      database.select('''SELECT n.id FROM nodes n LEFT JOIN nodes p ON p.id=n.parent_id
      WHERE (n.parent_id IS NULL AND n.depth != 1)
        OR (n.parent_id IS NOT NULL AND (p.id IS NULL OR n.depth != p.depth + 1))'''),
      isEmpty,
    );
    database.execute("INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1)");
  }

  test('a deleted direct child keeps its state and undo ignores its permanently removed saved parent', () {
    final root = add('r', state: {'n': 0});
    final target = add('a', parent: root, state: {'n': 1});
    final child = add('b', parent: target, state: {'n': 1, 'child': 2});
    final leaf = add('d', parent: child, state: {'n': 1, 'child': 3});
    final childState = store.nodeState(chat, child);
    final leafState = store.nodeState(chat, leaf);
    final token = store.softDeleteFrom(chat, child);
    expect(path(), [root, target]);
    final oldBatch = rows('SELECT * FROM deleted_subtrees').single;
    final beforeRevision = revision();

    store.deleteMessage(chat, target);

    expect(revision(), beforeRevision + 1);
    expect(path(), [root]);
    expect(raw(child)['parent_id'], root);
    expect(raw(child)['deleted_by'], token);
    expect(full(child), childState);
    expect(database.select('SELECT delta_json FROM node_states WHERE node_id=?', [child]).single['delta_json'], '[]');
    expect(rows('SELECT * FROM deleted_subtrees').single, oldBatch);
    expect(store.allNodes(chat).map((node) => node.message.nodeId), [root]);
    expect(() => store.nodeState(chat, child), throwsStateError);
    expect(store.searchChat(chat, 'bword'), isEmpty);
    expect(fts('bword'), [child]);
    expect(fts('aword'), isEmpty);
    integrity();
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(path(), [root]);
    expect(store.node(chat, root).selectedChildId, isNull);
    expect(store.nodeState(chat, child), childState);
    expect(store.nodeState(chat, leaf), leafState);
    store.selectNode(chat, child);
    expect(path(), [root, child, leaf]);
    integrity();
  });

  test('all direct children retain separate deletion batches and merge with visible siblings by original sequence', () {
    final root = add('r');
    final before = add('before', parent: root, makeCurrent: false);
    final target = add('a', parent: root, state: {'n': 1});
    final first = add('b', parent: target, state: {'n': 1, 'branch': 'first'});
    final firstLeaf = add('bdeep', parent: first, state: {'n': 2});
    final between = add('between', parent: root, makeCurrent: false);
    final second = add('c', parent: target, state: {'n': 1, 'branch': 'second'});
    final secondLeaf = add('cdeep', parent: second, state: {'n': 3});
    final visible = add('visible', parent: target, state: {'n': 4});
    final states = {
      for (final id in [first, firstLeaf, second, secondLeaf, visible]) id: store.nodeState(chat, id),
    };
    final firstToken = store.softDeleteFrom(chat, first);
    final secondToken = store.softDeleteFrom(chat, second);
    final captured = <String>[];

    store.deleteMessage(
      chat,
      target,
      capturePortableState: (child, state) {
        captured.add(child.message.nodeId);
        expect(child.message.parentId, target);
        expect(raw(child.message.nodeId)['parent_id'], target);
        return {...state, 'captured': child.message.nodeId};
      },
    );

    expect(captured, [first, second, visible]);
    expect(path(), [root, visible]);
    expect(store.children(chat, root).map((node) => node.message.nodeId), [before, between, visible]);
    expect(raw(first)['deleted_by'], firstToken);
    expect(raw(second)['deleted_by'], secondToken);
    expect(store.undoDeleteFrom(chat, secondToken), isTrue);
    expect(store.undoDeleteFrom(chat, firstToken), isTrue);
    expect(path(), [root, visible]);
    final siblings = store.children(chat, root);
    expect(siblings.map((node) => node.message.nodeId), [before, first, between, second, visible]);
    expect(siblings.map((node) => node.message.siblingIndex), [0, 1, 2, 3, 4]);
    expect(siblings.every((node) => node.message.siblingCount == 5), isTrue);
    for (final entry in states.entries) {
      expect(store.nodeState(chat, entry.key), entry.value, reason: entry.key);
    }
    integrity();
  });

  test('nested tokens follow the new physical parent and a blocked undo does not consume its batch', () {
    final root = add('r', state: {'n': 0});
    final target = add('a', parent: root, state: {'n': 1});
    final child = add('b', parent: target, state: {'n': 2});
    final deep = add('d', parent: child, state: {'n': 3});
    final leaf = add('e', parent: deep, state: {'n': 4});
    final expected = {
      for (final id in [child, deep, leaf]) id: store.nodeState(chat, id),
    };
    final deepToken = store.softDeleteFrom(chat, deep);
    final childToken = store.softDeleteFrom(chat, child);
    store.deleteMessage(chat, target);
    expect(raw(child)['parent_id'], root);
    expect(raw(deep)['parent_id'], child);
    expect(raw(child)['deleted_by'], childToken);
    expect(raw(deep)['deleted_by'], deepToken);
    final beforeBlocked = snapshot();
    expect(store.undoDeleteFrom(chat, deepToken), isFalse);
    expect(snapshot(), beforeBlocked);
    expect(store.undoDeleteFrom(chat, childToken), isTrue);
    expect(store.undoDeleteFrom(chat, deepToken), isTrue);
    expect(path(), [root]);
    for (final entry in expected.entries) {
      expect(store.nodeState(chat, entry.key), entry.value);
    }
    expect(database.select('SELECT * FROM deleted_subtrees'), isEmpty);
    integrity();
  });

  test('a marked child promoted to a root can be undone without reviving the deleted root selection', () {
    final root = add('r', state: {'n': 0});
    final child = add('b', parent: root, state: {'n': 1});
    final leaf = add('d', parent: child, state: {'n': 2});
    final token = store.softDeleteFrom(chat, child);
    store.deleteMessage(chat, root);
    expect(path(), isEmpty);
    expect(raw(child)['parent_id'], isNull);
    expect(raw(child)['depth'], 1);
    expect(raw(leaf)['depth'], 2);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(path(), isEmpty);
    expect(store.chat(chat).selectedRootId, isNull);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(store.children(chat, null).single.message.nodeId, child);
    expect(store.nodeState(chat, leaf), {'n': 2});
    store.selectNode(chat, child);
    expect(path(), [child, leaf]);
    integrity();
  });

  test('reopening purges promoted marked roots and their states while preserving the visible sibling', () async {
    final root = add('r', state: {'n': 0});
    final child = add('b', parent: root, state: {'n': 1});
    final deep = add('d', parent: child, state: {'n': 2});
    final deepToken = store.softDeleteFrom(chat, deep);
    final childToken = store.softDeleteFrom(chat, child);
    final visible = add(
      'visible',
      parent: root,
      state: {'n': 7},
      extra: {
        'foreign': [true, null],
      },
    );
    store.deleteMessage(chat, root);
    expect(path(), [visible]);
    expect(raw(child)['parent_id'], isNull);
    final visibleRow = raw(visible);
    await store.close();
    database = sqlite3.open(file);
    store = open(database);
    expect(path(), [visible]);
    expect(raw(visible), visibleRow);
    expect(store.nodeState(chat, visible), {'n': 7});
    expect(rows('SELECT id FROM nodes'), [
      {'id': visible},
    ]);
    expect(rows('SELECT node_id FROM node_states'), [
      {'node_id': visible},
    ]);
    expect(database.select('SELECT * FROM deleted_subtrees'), isEmpty);
    expect(fts('bword OR dword OR rword'), isEmpty);
    expect(store.undoDeleteFrom(chat, childToken), isFalse);
    expect(store.undoDeleteFrom(chat, deepToken), isFalse);
    integrity();
  });

  test('portable capture cannot change physical checkpoints or overwrite other raw extras', () {
    final root = add(
      'r',
      state: {
        'variables': {'n': 0},
      },
    );
    final target = add(
      'a',
      parent: root,
      state: {
        'variables': {'n': 1},
        'physical': true,
      },
    );
    final child = add(
      'b',
      parent: target,
      state: {
        'variables': {'n': 1},
        'physical': true,
        'child': 2,
      },
      extra: {
        'foreign': {
          'kept': [null, 4],
        },
        'dshgo': {
          'branchName': 'B',
          'unknown': {'kept': true},
          'tavernState': {
            'variables': {'n': 8},
            'stChatIdHash': null,
          },
        },
      },
    );
    final leaf = add(
      'd',
      parent: child,
      state: {
        'variables': {'n': 1},
        'physical': true,
        'child': 3,
      },
    );
    final other = add(
      'c',
      parent: target,
      state: {
        'variables': {'n': 2},
      },
    );
    final physical = {
      for (final id in [child, leaf, other]) id: store.nodeState(chat, id),
    };
    final originalExtra = extra(child);
    final token = store.softDeleteFrom(chat, child);
    final calls = <String>[];
    store.deleteMessage(
      chat,
      target,
      capturePortableState: (node, state) {
        calls.add(node.message.nodeId);
        expect(raw(node.message.nodeId)['parent_id'], target);
        expect(database.select('SELECT id FROM nodes WHERE id=?', [target]), hasLength(1));
        // The real facade may add a missing hash to the map it receives. Even
        // a nested mutation here must not alter the pre-encoded physical full.
        (state['variables']! as Map<String, Object?>)['n'] = 900;
        if (node.message.nodeId == child) {
          final own = node.extra['dshgo']! as Map<String, Object?>;
          return jsonDecode(jsonEncode(own['tavernState'])) as Map<String, Object?>;
        }
        state['stChatIdHash'] = 0;
        return state;
      },
    );
    expect(calls, [child, other]);
    expect(full(child), physical[child]);
    expect(full(other), physical[other]);
    expect(extra(child), originalExtra);
    expect((extra(other)['dshgo']! as Map<String, Object?>)['tavernState'], {
      'variables': {'n': 900},
      'stChatIdHash': 0,
    });
    expect(store.undoDeleteFrom(chat, token), isTrue);
    for (final entry in physical.entries) {
      expect(store.nodeState(chat, entry.key), entry.value, reason: entry.key);
    }
    integrity();
  });

  for (final pending in [false, true]) {
    test('raw inspection reporting markers and unknown extras survive capture with pending=$pending', () {
      final root = add('r');
      final target = add('a', parent: root);
      const child = 'b';
      final ownedExtra = <String, Object?>{
        'foreign': {
          'kept': [null, '海'],
        },
        'dshgo': {
          'branchName': 'kept branch',
          'unknown': [1, 2],
          'tavernState': {
            'variables': {'n': 4},
            'stChatIdHash': 0,
          },
          'inspection': {
            'version': 1,
            'chatId': chat,
            'nodeId': child,
            'reportedUsage': {'promptTokens': 0, 'cacheHitTokens': 0, 'completionTokens': 0, 'model': 'reported'},
            'future': {'keep': true},
          },
        },
      };
      add(
        child,
        parent: target,
        state: {
          'variables': {'n': 1},
        },
        extra: ownedExtra,
      );
      final leaf = add(
        'd',
        parent: child,
        state: {
          'variables': {'n': 2},
        },
      );
      if (pending) {
        store.beginStreamingWrites();
        store.writeStreamingBody(chat, child, text: 'draftword', reasoning: 'draft reasoning');
      }
      final token = store.softDeleteFrom(chat, child);
      final before = raw(child);
      expect(before['extra'], jsonEncode(ownedExtra));
      final beforeLeaf = raw(leaf);
      store.deleteMessage(
        chat,
        target,
        capturePortableState: (node, state) {
          final own = node.extra['dshgo']! as Map<String, Object?>;
          expect(own.containsKey('inspection'), !pending);
          return {
            'variables': {'n': 4},
            'stChatIdHash': 0,
            'captured': true,
          };
        },
      );
      final after = raw(child);
      final expectedExtra = jsonDecode(jsonEncode(ownedExtra)) as Map<String, Object?>;
      (expectedExtra['dshgo']! as Map<String, Object?>)['tavernState'] = {
        'variables': {'n': 4},
        'stChatIdHash': 0,
        'captured': true,
      };
      expect(after['extra'], jsonEncode(expectedExtra));
      expect(
        after['display_context'],
        jsonEncode({
          'dshgo': {'tavernState': (expectedExtra['dshgo']! as Map<String, Object?>)['tavernState'], 'chatJsonl': null},
          'scriptExtra': {'foreign': expectedExtra['foreign']},
        }),
      );
      for (final key in before.keys.where((key) => !{'parent_id', 'depth', 'extra', 'display_context'}.contains(key))) {
        expect(after[key], before[key], reason: key);
      }
      expect(raw(leaf), {...beforeLeaf, 'depth': (beforeLeaf['depth']! as int) - 1});
      expect(after['deleted_by'], token);
      expect(after['reported_usage'], isNotNull);
      expect(fts('bword'), [child]);
      expect(fts('draftword'), isEmpty);
      expect(store.searchChat(chat, 'bword'), isEmpty);
      expect(store.undoDeleteFrom(chat, token), isTrue);
      final message = store.message(chat, child);
      expect(message.text, pending ? 'draftword' : 'bword');
      if (pending) {
        expect(message.reportedUsage, isNull);
        expect(message.usage, isNull);
        expect(database.select('PRAGMA synchronous').single['synchronous'], 1);
        store.endStreamingWrites();
      } else {
        expect(message.reportedUsage!.promptTokens, 0);
        expect(message.reportedUsage!.model, 'reported');
        expect(message.usage!.promptTokens, 99);
      }
      integrity();
    });
  }

  test('a callback failure rolls back the outer transaction and leaves the deletion token reusable', () async {
    final root = add('r');
    final target = add('a', parent: root, state: {'n': 1});
    final child = add('b', parent: target, state: {'n': 2});
    final other = add('c', parent: target, state: {'n': 3});
    final token = store.softDeleteFrom(chat, child);
    final before = snapshot();
    await Future<void>.delayed(Duration.zero);
    final changes = <String>[];
    final subscription = store.changes.listen(changes.add);
    addTearDown(subscription.cancel);
    final captured = <String>[];
    expect(
      () => store.transaction(() {
        store.updateChat(chat, variables: {'mustRollBack': true});
        store.deleteMessage(
          chat,
          target,
          capturePortableState: (node, state) {
            captured.add(node.message.nodeId);
            if (node.message.nodeId == other) throw StateError('fixture capture');
            return {...state, 'prepared': true};
          },
        );
      }),
      throwsStateError,
    );
    expect(captured, [child, other]);
    expect(snapshot(), before);
    expect(database.autocommit, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(changes, isEmpty);
    integrity();
    store.deleteMessage(chat, target, capturePortableState: (node, state) => {...state, 'prepared': true});
    await Future<void>.delayed(Duration.zero);
    expect(changes, [chat]);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(store.nodeState(chat, child), {'n': 2});
    expect(path(), [root, other]);
    integrity();
  });

  for (final fault in ['checkpoint', 'portable', 'delete', 'touch']) {
    test('a $fault failure restores marked rows portable state revisions and FTS atomically', () async {
      final root = add('r');
      final target = add('a', parent: root, state: {'n': 1});
      final child = add(
        'b',
        parent: target,
        state: {'n': 2},
        extra: {
          'foreign': ['kept'],
        },
      );
      add('d', parent: child, state: {'n': 3});
      final other = add('c', parent: target, state: {'n': 4});
      final token = store.softDeleteFrom(chat, child);
      store.selectNode(chat, target, restoreDescendants: false);
      final before = snapshot();
      final trigger = switch (fault) {
        'checkpoint' =>
          '''CREATE TRIGGER reject_single BEFORE UPDATE OF full_json ON node_states
          WHEN NEW.node_id='c' BEGIN SELECT RAISE(ABORT,'checkpoint'); END''',
        'portable' =>
          '''CREATE TRIGGER reject_single BEFORE UPDATE OF extra ON nodes
          WHEN NEW.id='c' BEGIN SELECT RAISE(ABORT,'portable'); END''',
        'delete' =>
          '''CREATE TRIGGER reject_single BEFORE DELETE ON nodes
          WHEN OLD.id='a' BEGIN SELECT RAISE(ABORT,'delete'); END''',
        _ =>
          '''CREATE TRIGGER reject_single BEFORE UPDATE OF tree_revision ON chats
          WHEN NEW.id='chat' BEGIN SELECT RAISE(ABORT,'touch'); END''',
      };
      database.execute(trigger);
      await Future<void>.delayed(Duration.zero);
      final changes = <String>[];
      final subscription = store.changes.listen(changes.add);
      addTearDown(subscription.cancel);
      void remove() =>
          store.deleteMessage(chat, target, capturePortableState: (node, state) => {...state, 'prepared': true});
      expect(remove, throwsA(isA<SqliteException>()));
      expect(snapshot(), before);
      expect(database.autocommit, isTrue);
      expect(fts('aword'), [target]);
      expect(fts('bword'), [child]);
      await Future<void>.delayed(Duration.zero);
      expect(changes, isEmpty);
      integrity();
      database.execute('DROP TRIGGER reject_single');
      remove();
      expect(path(), [root]);
      expect(raw(child)['deleted_by'], token);
      expect(raw(child)['parent_id'], root);
      expect(store.message(chat, other).parentId, root);
      expect(fts('aword'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(changes, [chat]);
      expect(store.undoDeleteFrom(chat, token), isTrue);
      expect(path(), [root]);
      integrity();
    });
  }

  test('a marked target is rejected and ordinary reads and writes remain unable to bypass visibility', () {
    final root = add('r');
    final child = add('b', parent: root, state: {'n': 1});
    add('d', parent: child, state: {'n': 2});
    final token = store.softDeleteFrom(chat, child);
    final before = snapshot();
    var called = false;
    expect(
      () => store.deleteMessage(
        chat,
        child,
        capturePortableState: (node, state) {
          called = true;
          return state;
        },
      ),
      throwsStateError,
    );
    expect(called, isFalse);
    for (final readOrWrite in <void Function()>[
      () {
        store.node(chat, child);
      },
      () {
        store.message(chat, child);
      },
      () {
        store.nodeState(chat, child);
      },
      () {
        store.children(chat, child);
      },
      () {
        store.updateMessage(chat, child, extra: {'mustNotAppear': true});
      },
    ]) {
      expect(readOrWrite, throwsStateError);
    }
    expect(snapshot(), before);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(path(), [root, child, 'd']);
    integrity();
  });
}
