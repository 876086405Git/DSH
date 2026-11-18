import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  late Database database;
  late ChatStore store;
  late String chat;
  late TavernMessage node;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-t23-stream-store-');
    path = '${directory.path}/chat.sqlite3';
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    chat = store.createChat(characterId: 'card', title: 'chat');
    node = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Speaker',
      text: 'oldtoken',
      reasoning: 'old reasoning',
      usage: const TavernUsage(promptTokens: 7),
      extra: {
        'foreign': {'keep': true},
        'dshgo': {
          'inspection': {'status': 'completed'},
          'keep': 9,
        },
      },
    );
    store.updateChat(
      chat,
      metadata: {
        'foreign': 'keep',
        'dshgo': {
          'latestInspection': {'nodeId': node.nodeId},
        },
      },
    );
    _audit(database);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('checkpoint reads project body together without rewriting metadata or FTS', () {
    final before = _row(database, node.nodeId);
    final beforeChat = store.chat(chat);
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'middleword', reasoning: 'new reasoning');
    store.writeStreamingBody(chat, node.nodeId, text: 'lastword');
    final after = _row(database, node.nodeId);
    for (final key in ['text', 'reasoning', 'usage', 'extra', 'original']) {
      expect(after[key], before[key], reason: key);
    }
    expect(after['stream_text'], 'lastword');
    expect(after['stream_reasoning'], isNull);
    expect(store.message(chat, node.nodeId).text, 'lastword');
    expect(store.message(chat, node.nodeId).reasoning, isNull);
    expect(store.message(chat, node.nodeId).usage, isNull);
    expect((store.node(chat, node.nodeId).extra['dshgo']! as Map<String, Object?>).containsKey('inspection'), isFalse);
    expect(store.node(chat, node.nodeId).extra['foreign'], {'keep': true});
    expect(store.path(chat).single.text, 'lastword');
    expect(store.allNodes(chat).single.message.text, 'lastword');
    expect(store.children(chat, null).single.message.text, 'lastword');
    expect(store.listChats().single.lastText, 'lastword');
    expect(store.chat(chat).updatedAt, beforeChat.updatedAt);
    expect(store.chat(chat).metadata, beforeChat.metadata);
    expect(_events(database, 'body'), [1, 1]);
    expect(_events(database, 'text'), isEmpty);
    expect(_events(database, 'extra'), isEmpty);
    expect(_matches(database, 'oldtoken'), [node.nodeId]);
    expect(_matches(database, 'lastword'), isEmpty);
    expect(store.search('oldtoken', chatId: chat), isEmpty);
    expect(store.search('lastword', chatId: chat), isEmpty);
    _integrity(database);
    store.endStreamingWrites();
    expect(_sync(database), 2);
  });

  test('empty body and null reasoning use one pending marker', () {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: '');
    expect(store.message(chat, node.nodeId).text, '');
    expect(store.message(chat, node.nodeId).reasoning, isNull);
    expect(store.listChats().single.lastText, '');
    expect(_row(database, node.nodeId)['stream_text'], '');
    _integrity(database);
    store.endStreamingWrites();
  });

  test('chat commits retain body-only identity without publishing rolled-back edits', () async {
    final commits = <({String chatId, bool bodyOnly})>[];
    final legacy = <String>[];
    final subscription = store.chatCommits.listen(commits.add);
    final legacySubscription = store.changes.listen(legacy.add);
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'draft');
    store.endStreamingWrites();
    expect(
      () => store.transaction<void>(() {
        store.updateChat(chat, title: 'rolled back');
        throw StateError('fixture');
      }),
      throwsStateError,
    );
    store.updateMessage(chat, node.nodeId, text: 'complete');
    await Future<void>.delayed(Duration.zero);
    expect(commits, [(chatId: chat, bodyOnly: true), (chatId: chat, bodyOnly: false)]);
    expect(legacy, [chat, chat]);
    await subscription.cancel();
    await legacySubscription.cancel();
  });

  test('metadata usage and original-only edits neither index nor promote a draft', () {
    store.updateMessage(chat, node.nodeId, extra: {'keep': 'metadata'});
    store.updateMessage(chat, node.nodeId, usage: const TavernUsage(completionTokens: 3));
    store.updateMessage(
      chat,
      node.nodeId,
      original: {
        'unknown': ['x'],
      },
    );
    expect(_events(database, 'text'), isEmpty);
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'drafttoken');
    store.updateMessage(chat, node.nodeId, extra: {'keep': 'during'});
    store.updateMessage(chat, node.nodeId, clearUsage: true);
    store.updateMessage(
      chat,
      node.nodeId,
      original: {
        'unknown': ['y'],
      },
    );
    final row = _row(database, node.nodeId);
    expect(row['text'], 'oldtoken');
    expect(row['stream_text'], 'drafttoken');
    expect(store.message(chat, node.nodeId).text, 'drafttoken');
    expect(_events(database, 'text'), isEmpty);
    expect(_events(database, 'extra'), [2, 2]);
    expect(_sync(database), 1);
    store.endStreamingWrites();
  });

  test('terminal body replaces the true old indexed value once in FULL', () {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'interimword', reasoning: 'draft reason');
    store.transaction(() {
      expect(_sync(database), 2);
      store.updateMessage(
        chat,
        node.nodeId,
        text: 'finalword',
        reasoning: 'final reason',
        usage: const TavernUsage(promptTokens: 11),
        extra: {
          'dshgo': {
            'inspection': {'status': 'completed'},
          },
        },
      );
      store.updateMessage(chat, node.nodeId, original: {'preserved': true});
    });
    expect(_sync(database), 1);
    expect(_events(database, 'text'), [2]);
    expect(_events(database, 'body'), [1]);
    final row = _row(database, node.nodeId);
    expect(row['stream_text'], isNull);
    expect(row['stream_reasoning'], isNull);
    expect(store.message(chat, node.nodeId).text, 'finalword');
    expect(store.message(chat, node.nodeId).reasoning, 'final reason');
    expect(store.message(chat, node.nodeId).usage!.promptTokens, 11);
    expect(_matches(database, 'oldtoken'), isEmpty);
    expect(_matches(database, 'interimword'), isEmpty);
    expect(_matches(database, 'finalword'), [node.nodeId]);
    expect(store.search('oldtoken', chatId: chat), isEmpty);
    expect(store.search('finalword', chatId: chat).single.text, 'finalword');
    _integrity(database);
    store.endStreamingWrites();
  });

  test('reasoning-only ordinary edit promotes pending text and clears a null reason explicitly', () {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'pendingword', reasoning: 'temporary');
    store.updateMessage(chat, node.nodeId, clearReasoning: true);
    expect(store.message(chat, node.nodeId).text, 'pendingword');
    expect(store.message(chat, node.nodeId).reasoning, isNull);
    expect(store.message(chat, node.nodeId).usage, isNull);
    expect(store.node(chat, node.nodeId).extra, {
      'foreign': {'keep': true},
      'dshgo': {'keep': 9},
    });
    expect(_row(database, node.nodeId)['stream_text'], isNull);
    expect(_events(database, 'text'), [2]);
    expect(_matches(database, 'oldtoken'), isEmpty);
    expect(_matches(database, 'pendingword'), [node.nodeId]);
    _integrity(database);
    store.endStreamingWrites();
  });

  test('concurrent stream references keep ordinary and nested transactions FULL', () {
    expect(_sync(database), 2);
    store.beginStreamingWrites();
    store.beginStreamingWrites();
    expect(_sync(database), 1);
    store.transaction(() {
      expect(_sync(database), 2);
      store.transaction(() => expect(_sync(database), 2));
      expect(() => store.beginStreamingWrites(), throwsStateError);
      expect(() => store.endStreamingWrites(), throwsStateError);
      expect(() => store.writeStreamingBody(chat, node.nodeId, text: 'nested'), throwsStateError);
      store.createPreset(name: 'during stream', sourceText: '{}', raw: {});
    });
    expect(_sync(database), 1);
    expect(
      () => store.transaction<void>(() {
        expect(_sync(database), 2);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(_sync(database), 1);
    store.endStreamingWrites();
    expect(_sync(database), 1);
    store.writeStreamingBody(chat, node.nodeId, text: 'second stream');
    expect(_events(database, 'body'), [1]);
    store.endStreamingWrites();
    expect(_sync(database), 2);
    expect(() => store.endStreamingWrites(), throwsStateError);
    expect(() => store.writeStreamingBody(chat, node.nodeId, text: 'late'), throwsStateError);
    expect(_sync(database), 2);
  });

  test('failed checkpoint keeps prior committed body and can retry without losing the mode', () {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'savedword');
    database.execute('''CREATE TRIGGER reject_body BEFORE UPDATE OF stream_text ON nodes
      WHEN NEW.stream_text = 'rejectedword' BEGIN SELECT RAISE(ABORT, 'fixture_body'); END''');
    expect(() => store.writeStreamingBody(chat, node.nodeId, text: 'rejectedword'), throwsA(isA<SqliteException>()));
    expect(store.message(chat, node.nodeId).text, 'savedword');
    expect(_events(database, 'body'), [1]);
    expect(_sync(database), 1);
    database.execute('DROP TRIGGER reject_body');
    store.writeStreamingBody(chat, node.nodeId, text: 'rejectedword');
    expect(store.message(chat, node.nodeId).text, 'rejectedword');
    expect(_events(database, 'body'), [1, 1]);
    _integrity(database);
    store.endStreamingWrites();
  });

  test('failed terminal transaction retains draft baseline and index for a bounded retry', () {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'savedword');
    database.execute('''CREATE TRIGGER reject_final BEFORE UPDATE OF text ON nodes
      WHEN NEW.text = 'finalword' BEGIN SELECT RAISE(ABORT, 'fixture_final'); END''');
    expect(
      () => store.updateMessage(chat, node.nodeId, text: 'finalword', extra: {'changed': true}),
      throwsA(isA<SqliteException>()),
    );
    expect(_row(database, node.nodeId)['text'], 'oldtoken');
    expect(_row(database, node.nodeId)['stream_text'], 'savedword');
    expect(_events(database, 'text'), isEmpty);
    expect(_matches(database, 'oldtoken'), [node.nodeId]);
    _integrity(database);
    database.execute('DROP TRIGGER reject_final');
    store.updateMessage(chat, node.nodeId, text: 'finalword');
    expect(_events(database, 'text'), [2]);
    expect(_matches(database, 'oldtoken'), isEmpty);
    expect(_matches(database, 'finalword'), [node.nodeId]);
    store.endStreamingWrites();
  });

  test('pending row and chat deletion remove the indexed baseline without stale terms', () {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'neverindexed');
    store.deleteFrom(chat, node.nodeId);
    expect(_matches(database, 'oldtoken'), isEmpty);
    expect(_matches(database, 'neverindexed'), isEmpty);
    final second = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Speaker',
      text: 'secondbase',
    );
    store.writeStreamingBody(chat, second.nodeId, text: 'secondpending');
    store.deleteChat(chat);
    expect(_matches(database, 'secondbase'), isEmpty);
    expect(_matches(database, 'secondpending'), isEmpty);
    _integrity(database);
    store.endStreamingWrites();
  });

  test('reopen promotes the checkpoint once and removes only its obsolete evidence', () async {
    final otherChat = store.createChat(characterId: 'other', title: 'other');
    final other = store.append(
      otherChat,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Other',
      text: 'otherword',
      extra: {
        'dshgo': {
          'inspection': {'status': 'completed', 'keep': 'other'},
        },
      },
    );
    store.updateChat(
      otherChat,
      metadata: {
        'dshgo': {
          'latestInspection': {'nodeId': other.nodeId},
        },
      },
    );
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'recoveredword');
    await store.close();
    database = sqlite3.open(path);
    expect(_row(database, node.nodeId)['stream_text'], 'recoveredword');
    store = ChatStore.fromDatabase(database);
    expect(store.message(chat, node.nodeId).text, 'recoveredword');
    expect(store.message(chat, node.nodeId).reasoning, isNull);
    expect(store.message(chat, node.nodeId).usage, isNull);
    final extra = store.node(chat, node.nodeId).extra;
    expect(extra['foreign'], {'keep': true});
    expect(extra['dshgo'], {'keep': 9});
    expect(store.chat(chat).metadata, {'foreign': 'keep', 'dshgo': <String, Object?>{}});
    expect((store.node(otherChat, other.nodeId).extra['dshgo']! as Map<String, Object?>)['inspection'], {
      'status': 'completed',
      'keep': 'other',
    });
    expect((store.chat(otherChat).metadata['dshgo']! as Map<String, Object?>)['latestInspection'], {
      'nodeId': other.nodeId,
    });
    expect(_events(database, 'text'), [2]);
    expect(_row(database, node.nodeId)['stream_text'], isNull);
    expect(_matches(database, 'oldtoken'), isEmpty);
    expect(_matches(database, 'recoveredword'), [node.nodeId]);
    expect(store.search('recoveredword', chatId: chat).single.text, 'recoveredword');
    _integrity(database);
    await store.close();
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    expect(_events(database, 'text'), [2]);
    expect(_sync(database), 2);
  });

  test('recovery failure rolls back body index and evidence clearing before open returns', () async {
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, node.nodeId, text: 'recoveredword');
    database.execute('''CREATE TRIGGER reject_recovery BEFORE UPDATE OF text ON nodes
      WHEN OLD.stream_text IS NOT NULL BEGIN SELECT RAISE(ABORT, 'fixture_recovery'); END''');
    final before = _row(database, node.nodeId);
    final metadata = store.chat(chat).metadata;
    await store.close();
    expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
    database = sqlite3.open(path);
    expect(_row(database, node.nodeId), before);
    expect(
      jsonDecode(database.select('SELECT metadata FROM chats WHERE id = ?', [chat]).single['metadata']! as String),
      metadata,
    );
    expect(_matches(database, 'oldtoken'), [node.nodeId]);
    _integrity(database);
    database.execute('DROP TRIGGER reject_recovery');
    store = ChatStore.fromDatabase(database);
    expect(store.message(chat, node.nodeId).text, 'recoveredword');
    expect(_matches(database, 'oldtoken'), isEmpty);
  });

  test('real frozen schema3 migrates through4 with preset report source and unknown columns intact', () async {
    await store.close();
    final oldPath = '${directory.path}/schema3.sqlite3';
    database = sqlite3.open(oldPath);
    database.execute(File('test/fixtures/t23_schema_v3.sql').readAsStringSync());
    database.execute('ALTER TABLE presets ADD COLUMN future_vendor TEXT');
    database.execute(
      '''INSERT INTO presets(id,name,source_text,raw_json,envelope_json,import_report_json,created_at,updated_at,future_vendor)
      VALUES('p','old','source','{}',NULL,'{"version":1}',10,11,'keep')''',
    );
    final before = Map<String, Object?>.from(database.select('SELECT * FROM presets').single);
    store = ChatStore.fromDatabase(database);
    expect(ChatStore.schemaVersion, greaterThanOrEqualTo(4));
    expect(database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
    expect(Map<String, Object?>.from(database.select('SELECT * FROM presets').single), before);
    expect(
      database.select('PRAGMA table_info(nodes)').map((row) => row['name']),
      containsAll(['stream_text', 'stream_reasoning']),
    );
    expect(database.select("SELECT name FROM sqlite_master WHERE name = 'nodes_stream_pending'"), hasLength(1));
    _integrity(database);
  });

  test('schema4 collision rolls back the genuine schema3 migration', () async {
    await store.close();
    final oldPath = '${directory.path}/collision.sqlite3';
    database = sqlite3.open(oldPath);
    database.execute(File('test/fixtures/t23_schema_v3.sql').readAsStringSync());
    database.execute('ALTER TABLE nodes ADD COLUMN stream_reasoning TEXT');
    database.close();
    expect(() => ChatStore.open(oldPath), throwsA(isA<SqliteException>()));
    database = sqlite3.open(oldPath);
    expect(database.select('PRAGMA user_version').single['user_version'], 3);
    expect(database.select('PRAGMA table_info(nodes)').map((row) => row['name']), isNot(contains('stream_text')));
    expect(database.select("SELECT name FROM sqlite_master WHERE name = 'nodes_stream_pending'"), isEmpty);
    database.execute('ALTER TABLE nodes DROP COLUMN stream_reasoning');
    store = ChatStore.fromDatabase(database);
    expect(database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
  });
}

void _audit(Database database) {
  database.execute('''CREATE TABLE stream_audit(kind TEXT NOT NULL, node_id TEXT NOT NULL, sync INTEGER NOT NULL);
    CREATE TRIGGER audit_body AFTER UPDATE OF stream_text ON nodes WHEN NEW.stream_text IS NOT NULL BEGIN
      INSERT INTO stream_audit SELECT 'body', NEW.id, synchronous FROM pragma_synchronous;
    END;
    CREATE TRIGGER audit_text AFTER UPDATE OF text ON nodes BEGIN
      INSERT INTO stream_audit SELECT 'text', NEW.id, synchronous FROM pragma_synchronous;
    END;
    CREATE TRIGGER audit_extra AFTER UPDATE OF extra ON nodes BEGIN
      INSERT INTO stream_audit SELECT 'extra', NEW.id, synchronous FROM pragma_synchronous;
    END;''');
}

int _sync(Database database) => database.select('PRAGMA synchronous').single['synchronous'] as int;
Map<String, Object?> _row(Database database, String id) =>
    Map<String, Object?>.from(database.select('SELECT * FROM nodes WHERE id = ?', [id]).single);
List<int> _events(Database database, String kind) => [
  for (final row in database.select('SELECT sync FROM stream_audit WHERE kind = ? ORDER BY rowid', [kind]))
    row['sync'] as int,
];
List<String> _matches(Database database, String word) => [
  for (final row in database.select(
    'SELECT n.id FROM nodes_fts JOIN nodes n ON n.seq = nodes_fts.rowid WHERE nodes_fts MATCH ?',
    [word],
  ))
    row['id'] as String,
];
void _integrity(Database database) =>
    database.execute("INSERT INTO nodes_fts(nodes_fts, rank) VALUES('integrity-check', 1)");
