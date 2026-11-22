import 'dart:convert';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// These use real SQLite and explicit trees. They do not measure UI latency or
// infer query counts from timings; corrupted links are read-only fixtures.
void main() {
  late Database database;
  late ChatStore store;
  var milliseconds = 1000;
  setUp(() {
    milliseconds = 1000;
    database = sqlite3.openInMemory();
    store = ChatStore.fromDatabase(
      database,
      clock: () => DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
    );
  });
  tearDown(() async {
    await store.close();
  });

  String chat(String id, {String character = 'card'}) => store.createChat(id: id, characterId: character);
  TavernMessage append(String chatId, String id, {String? parent}) =>
      store.append(chatId, id: id, parentId: parent, role: TavernRole.character, speaker: 'Whale', text: id);
  List<String> history(String chatId, String? leaf) =>
      store.historyTo(chatId, leaf).map((node) => node.message.nodeId).toList();
  List<String> page(String chatId, {int limit = 60, String? before}) =>
      store.path(chatId, limit: limit, beforeNodeId: before).map((node) => node.nodeId).toList();

  test('an explicit 2005-node history is complete while path keeps its default page size', () {
    final id = chat('long');
    store.transaction(() {
      for (var i = 0; i < 2005; i++) {
        _insert(database, id, 'n$i', parent: i == 0 ? null : 'n${i - 1}', depth: i + 1);
      }
      _select(database, id, 'n0', 'n2004');
    });
    expect(history(id, 'n2004'), List.generate(2005, (i) => 'n$i'));
    expect(page(id), List.generate(60, (i) => 'n${1945 + i}'));
    expect(history(id, 'n71'), List.generate(72, (i) => 'n$i'));
    expect(store.chat(id).currentLeafId, 'n2004');
  });

  test('inactive histories retain complete stored fields without changing remembered selection', () {
    final id = chat('branches');
    append(id, 'root');
    final a = store.append(
      id,
      id: 'a',
      parentId: 'root',
      role: TavernRole.narrator,
      speaker: 'Narrator',
      text: 'hidden branch',
      reasoning: 'stored thought',
      hidden: true,
      usage: const TavernUsage(promptTokens: 13, cacheHitTokens: 5, completionTokens: 8),
      extra: {
        'dshgo': {'macroHash': 0},
        'opaque': {
          'values': [1, null, 'x'],
        },
      },
      original: {
        'is_system': true,
        'extra': {'vendor': 'keep'},
      },
    );
    append(id, 'a-child', parent: a.nodeId);
    append(id, 'b', parent: 'root');
    append(id, 'b-child', parent: 'b');
    final before = store.chat(id);
    final nodes = store.historyTo(id, 'a-child');
    expect(nodes.map((node) => node.message.nodeId), ['root', 'a', 'a-child']);
    final selected = nodes[1];
    expect(selected.depth, 2);
    expect(selected.selectedChildId, 'a-child');
    expect(selected.message.role, TavernRole.narrator);
    expect(selected.message.speaker, 'Narrator');
    expect(selected.message.text, 'hidden branch');
    expect(selected.message.reasoning, 'stored thought');
    expect(selected.message.hidden, isTrue);
    expect(selected.message.usage!.cacheHitTokens, 5);
    expect(selected.message.siblingIndex, 0);
    expect(selected.message.siblingCount, 2);
    expect(selected.extra, {
      'dshgo': {'macroHash': 0},
      'opaque': {
        'values': [1, null, 'x'],
      },
    });
    expect(selected.original, {
      'is_system': true,
      'extra': {'vendor': 'keep'},
    });
    selected.extra['opaque'] = 'mutated returned copy';
    expect(store.node(id, 'a').extra['opaque'], {
      'values': [1, null, 'x'],
    });
    expect(store.chat(id).currentLeafId, before.currentLeafId);
    expect(store.chat(id).selectedRootId, before.selectedRootId);
    expect(store.node(id, 'root').selectedChildId, 'b');
    expect(page(id), ['root', 'b', 'b-child']);
  });

  test('ancestry order does not depend on insertion sequence, timestamps, or stored depth', () {
    final id = chat('unordered');
    store.transaction(() {
      _insert(database, id, 'leaf', parent: 'middle', depth: 7, at: 10);
      _insert(database, id, 'root', depth: 2, at: 30);
      _insert(database, id, 'middle', parent: 'root', depth: 99, at: 20);
      _select(database, id, 'root', 'leaf');
    });
    expect(history(id, 'leaf'), ['root', 'middle', 'leaf']);
    expect(page(id), ['root', 'middle', 'leaf']);
    expect(store.historyTo(id, 'leaf').map((node) => node.depth), [2, 99, 7]);
  });

  test('shared path query preserves exclusive cursors, limits, and inactive-cursor rejection', () {
    final id = chat('pages');
    for (var i = 0; i < 6; i++) {
      append(id, 'n$i', parent: i == 0 ? null : 'n${i - 1}');
    }
    store.append(
      id,
      id: 'inactive',
      parentId: 'n0',
      role: TavernRole.user,
      speaker: 'User',
      text: 'inactive',
      makeCurrent: false,
    );
    expect(page(id, limit: 2), ['n4', 'n5']);
    expect(page(id, limit: 2, before: 'n4'), ['n2', 'n3']);
    expect(page(id, limit: 2, before: 'n2'), ['n0', 'n1']);
    expect(page(id, before: 'n0'), isEmpty);
    expect(page(id, limit: 0), isEmpty);
    expect(page(id, limit: 0, before: 'n0'), isEmpty);
    expect(() => page(id, limit: -1), throwsArgumentError);
    expect(() => page('missing-chat', limit: -1), throwsArgumentError);
    expect(() => page('missing-chat', limit: 0), throwsStateError);
    expect(() => page(id, limit: 0, before: 'missing-node'), throwsStateError);
    expect(() => page(id, limit: 0, before: 'inactive'), throwsStateError);
    expect(() => page(id, before: 'inactive'), throwsStateError);
    expect(history(id, 'inactive'), ['n0', 'inactive']);
    expect(store.chat(id).currentLeafId, 'n5');
  });

  test('null and absent leaves keep empty-history and missing-identity contracts distinct', () {
    final id = chat('empty');
    expect(history(id, null), isEmpty);
    expect(page(id), isEmpty);
    expect(() => history(id, 'absent'), throwsStateError);
    expect(() => history('missing-chat', null), throwsStateError);
    append(id, 'root');
    expect(history(id, null), isEmpty);
    expect(history(id, 'root'), ['root']);
  });

  test('a foreign leaf or cross-chat parent is rejected without leaking another chat', () {
    final first = chat('first');
    final second = chat('second');
    append(first, 'local');
    append(second, 'foreign');
    expect(() => history(first, 'foreign'), throwsStateError);
    // The SQL foreign key is global; the recursive query must enforce chat_id.
    database.execute('UPDATE nodes SET parent_id = ? WHERE id = ?', ['foreign', 'local']);
    expect(() => history(first, 'local'), throwsStateError);
    expect(() => page(first), throwsStateError);
    expect(history(second, 'foreign'), ['foreign']);
  });

  test('a dangling parent fails instead of silently returning a truncated history', () {
    final id = chat('broken');
    database.execute('PRAGMA foreign_keys = OFF');
    _insert(database, id, 'orphan', parent: 'missing-parent');
    _select(database, id, 'orphan', 'orphan');
    database.execute('PRAGMA foreign_keys = ON');
    expect(() => history(id, 'orphan'), throwsStateError);
    expect(() => page(id), throwsStateError);
    // A finite page need not inspect ancestry beyond the requested boundary.
    expect(page(id, limit: 1), ['orphan']);
  });

  test('a self-cycle terminates and rejects full reads and off-path cursor checks', () {
    final id = chat('self-cycle');
    append(id, 'loop');
    store.append(
      id,
      id: 'unrelated',
      parentId: null,
      role: TavernRole.user,
      speaker: 'User',
      text: 'unrelated',
      makeCurrent: false,
    );
    database.execute('UPDATE nodes SET parent_id = id WHERE id = ?', ['loop']);
    expect(() => history(id, 'loop'), throwsStateError);
    expect(() => page(id), throwsStateError);
    expect(() => page(id, before: 'unrelated'), throwsStateError);
    expect(page(id, limit: 1), ['loop']);
  });

  test('a two-node cycle is deduplicated before reconstruction detects the repeated parent', () {
    final id = chat('pair-cycle');
    append(id, 'a');
    append(id, 'b', parent: 'a');
    database.execute('UPDATE nodes SET parent_id = ? WHERE id = ?', ['b', 'a']);
    expect(() => history(id, 'b'), throwsStateError);
    expect(() => page(id), throwsStateError);
    expect(() => page(id, before: 'a'), throwsStateError);
    expect(page(id, limit: 2), ['a', 'b']);
  });

  test('path and history keep full messages while streaming suppresses stale terminal evidence', () {
    final id = chat('pending');
    append(id, 'other-root');
    final at = DateTime.utc(2024, 1, 2, 3, 4, 5);
    const speaker = '\ufeffWhale\u0001';
    const character = '\ufeffactor';
    const text = '\ufeffoldword\u0000海🌊';
    const reasoning = '\ufeff\ufeffold reasoning';
    final opaque = List<String>.filled(4096, 'opaque').join();
    store.append(
      id,
      id: 'reply',
      parentId: null,
      role: TavernRole.character,
      speaker: speaker,
      speakerCharacterId: character,
      text: text,
      reasoning: reasoning,
      at: at,
      hidden: true,
      usage: const TavernUsage(promptTokens: 7, cacheHitTokens: 2, completionTokens: 3, model: 'estimate'),
      extra: {
        'dshgo': {
          'inspection': {
            'version': 1,
            'chatId': id,
            'nodeId': 'reply',
            'status': 'completed',
            'reportedUsage': {'promptTokens': 12, 'cacheHitTokens': 4, 'completionTokens': 5, 'model': 'reported'},
          },
          'keep': 1,
        },
        'opaque': opaque,
      },
      original: {'vendor': 'preserved', 'opaque': opaque},
    );
    final saved = store.path(id).single;
    expect(
      [
        saved.nodeId,
        saved.parentId,
        saved.role,
        saved.speaker,
        saved.speakerCharacterId,
        saved.text,
        saved.reasoning,
        saved.at,
        saved.hidden,
        saved.siblingIndex,
        saved.siblingCount,
      ],
      ['reply', null, TavernRole.character, speaker, character, text, reasoning, at, true, 1, 2],
    );
    expect(
      [saved.usage?.promptTokens, saved.usage?.cacheHitTokens, saved.usage?.completionTokens, saved.usage?.model],
      [7, 2, 3, 'estimate'],
    );
    expect(
      [
        saved.reportedUsage?.promptTokens,
        saved.reportedUsage?.cacheHitTokens,
        saved.reportedUsage?.completionTokens,
        saved.reportedUsage?.model,
      ],
      [12, 4, 5, 'reported'],
    );
    expect(store.path(id, beforeNodeId: 'reply'), isEmpty);
    store.beginStreamingWrites();
    try {
      store.writeStreamingBody(id, 'reply', text: '\ufeffnewword', reasoning: '\u0001\ufeffnew reason');
      final pending = store.path(id).single;
      expect([pending.text, pending.reasoning], ['\ufeffnewword', '\u0001\ufeffnew reason']);
      store.writeStreamingBody(id, 'reply', text: '', reasoning: null);
    } finally {
      store.endStreamingWrites();
    }
    final empty = store.path(id).single;
    expect([empty.text, empty.reasoning, empty.usage, empty.reportedUsage], ['', null, null, null]);
    final node = store.historyTo(id, 'reply').single;
    expect(node.message.text, '');
    expect(node.message.reasoning, isNull);
    expect(node.message.usage, isNull);
    expect(node.message.reportedUsage, isNull);
    expect(node.extra, {
      'dshgo': {'keep': 1},
      'opaque': opaque,
    });
    expect(node.original, {'vendor': 'preserved', 'opaque': opaque});
    expect(jsonDecode(database.select('SELECT extra FROM nodes WHERE id = ?', ['reply']).single['extra'] as String), {
      'dshgo': {
        'inspection': {
          'version': 1,
          'chatId': id,
          'nodeId': 'reply',
          'status': 'completed',
          'reportedUsage': {'promptTokens': 12, 'cacheHitTokens': 4, 'completionTokens': 5, 'model': 'reported'},
        },
        'keep': 1,
      },
      'opaque': opaque,
    });
  });

  test('character statistics aggregate empty and populated chats with current recency', () {
    expect(store.characterChatStats(), isEmpty);
    final first = chat('one', character: 'a');
    milliseconds = 2000;
    final second = chat('two', character: 'a');
    milliseconds = 3000;
    final other = chat('other', character: 'b');
    append(other, 'body');
    // Stats must not deserialize node documents or require a current body.
    database.execute("UPDATE nodes SET extra = 'invalid JSON' WHERE id = 'body'");
    var stats = store.characterChatStats();
    expect(stats.keys.toSet(), {'a', 'b'});
    expect(stats['a']!.count, 2);
    expect(stats['a']!.lastAt.millisecondsSinceEpoch, 2000);
    expect(stats['b']!.count, 1);
    expect(stats['b']!.lastAt.millisecondsSinceEpoch, 3000);
    milliseconds = 4000;
    store.updateChat(first, title: 'renamed empty chat');
    stats = store.characterChatStats();
    expect(stats['a']!.lastAt.millisecondsSinceEpoch, 4000);
    store.deleteChat(first);
    expect(store.characterChatStats()['a']!.count, 1);
    expect(store.characterChatStats()['a']!.lastAt, store.chat(second).updatedAt);
  });
}

void _insert(Database database, String chatId, String id, {String? parent, int depth = 1, int at = 1000}) {
  database.execute(
    '''INSERT INTO nodes(id, chat_id, parent_id, depth, role, speaker, text, at)
    VALUES (?, ?, ?, ?, 'character', 'Whale', ?, ?)''',
    [id, chatId, parent, depth, 'text-$id', at],
  );
}

void _select(Database database, String chatId, String root, String leaf) {
  database.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [root, leaf, chatId]);
}
