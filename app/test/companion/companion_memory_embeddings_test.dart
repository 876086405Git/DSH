// These regressions exercise the real Store and Dart retrieval service. The
// platform boundary returns explicit synthetic unit vectors; this is not a
// tokenizer, ONNX, semantic-quality, or device-performance test.
import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:dsh_app/companion/companion_memory_embeddings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/companion_memory_embeddings');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  late CompanionMemoryEmbeddings embeddings;
  late Future<Object?> Function(MethodCall) native;
  late Completer<void> unloaded;
  late List<MethodCall> calls;
  var nextId = 0;
  const now = 1800000000000;

  String id() => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';
  List<double> unit(int axis) => List<double>.filled(512, 0)..[axis] = 1;

  MemoryRow shared(String text) {
    final cardId = id();
    store.saveManual(
      CompanionMemory(id: cardId, text: text, keywords: const []),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    return store.cards().singleWhere((row) => row['id'] == cardId);
  }

  MemoryRow story(String characterId, String text) {
    final messageId = id();
    store.submitMessage(
      id: messageId,
      sessionId: 'light:embedding-test',
      text: text,
      saidAtUtc: now,
      offsetMinutes: 0,
      characterId: characterId,
    );
    final turn = store.beginAgentTurn(messageId: messageId, expectedSourceRev: 1, shownCardRevisions: const {});
    final turnId = turn['id']! as String;
    final receipt = store.applyAgentMemoryTool(
      turnId: turnId,
      callId: 'remember-story',
      toolName: 'remember',
      input: {'collection': 'our_story', 'text': text, 'keywords': <String>[]},
    );
    expect(receipt.applied, isTrue);
    store.closeAgentTurn(turnId);
    return store
        .memoryRetrievalCandidates(characterId: characterId)
        .singleWhere((row) => row['id'] == receipt.targetId);
  }

  setUp(() async {
    nextId = 0;
    directory = await Directory.systemTemp.createTemp('companion-embedding-');
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: id);
    unloaded = Completer<void>();
    calls = [];
    native = (_) async => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'unload') {
        if (!unloaded.isCompleted) unloaded.complete();
        return null;
      }
      return native(call);
    });
    embeddings = CompanionMemoryEmbeddings(channel: channel, supported: true);
  });

  tearDown(() async {
    embeddings.dispose();
    await unloaded.future;
    messenger.setMockMethodCallHandler(channel, null);
    store.close();
    await directory.delete(recursive: true);
  });

  test('role filtering precedes native input and ranking does not grant or revise memories', () async {
    final a = store.ensureCompanionCharacter(sourceKey: 'test:character-a')['id']! as String;
    final b = store.ensureCompanionCharacter(sourceKey: 'test:character-b')['id']! as String;
    final common = shared('共同事实');
    final own = story(a, '甲角色一起看的海');
    final other = story(b, '乙角色私下的约定');
    final archiveBefore = store.archive;
    final grantsBefore = [
      for (final row in database.select('SELECT id,shown_cards FROM memory_agent_turns ORDER BY id')) {...row},
    ];
    final encoded = <String>[];
    native = (call) async {
      if (call.method == 'load') return {'modelKey': 'explicit-test-model', 'dimensions': 512};
      expect(call.method, 'embed');
      final args = Map<String, Object?>.from(call.arguments as Map);
      final texts = (args['texts'] as List).cast<String>();
      encoded.addAll(texts);
      return [for (final text in texts) unit(args['query'] == true || text == own['text'] ? 0 : 1)];
    };
    final result = await embeddings.rank(store: store, characterId: a, query: '查询', isCurrent: () => true);
    expect(result!.map((row) => row['id']), [own['id'], common['id']]);
    expect(encoded, isNot(contains(other['text'])));
    expect(encoded, containsAll(['查询', own['text'], common['text']]));
    expect(store.archive, archiveBefore);
    expect([
      for (final row in database.select('SELECT id,shown_cards FROM memory_agent_turns ORDER BY id')) {...row},
    ], grantsBefore);
    expect(
      database.select('SELECT card_id FROM memory_embeddings').map((row) => row['card_id']),
      unorderedEquals([own['id'], common['id']]),
    );
    final count = calls.where((call) => call.method == 'embed').length;
    await embeddings.rank(store: store, characterId: a, query: '第二次查询', isCurrent: () => true);
    expect(calls.where((call) => call.method == 'embed').length, count + 1);
    // A tool round trip of the same turn ranks the same text again: no new encoding.
    await embeddings.rank(store: store, characterId: a, query: '第二次查询', isCurrent: () => true);
    expect(calls.where((call) => call.method == 'embed').length, count + 1);
    expect(
      store.saveMemoryEmbedding(
        characterId: a,
        cardId: other['id']! as String,
        rowRevision: other['row_rev']! as int,
        modelKey: 'explicit-test-model',
        vector: unit(0),
      ),
      isFalse,
    );
    store.saveManual(
      CompanionMemory(id: common['id']! as String, text: '共同事实已更正', keywords: const []),
      expectedRowRev: common['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(database.select('SELECT card_id FROM memory_embeddings').map((row) => row['card_id']), [own['id']]);
  });

  test('control change during query inference retires the result and stale cache writes lose CAS', () async {
    final card = shared('修改前的事实');
    final control = store.archive['control_revision'];
    final entered = Completer<void>();
    final reply = Completer<List<List<double>>>();
    native = (call) async {
      if (call.method == 'load') return {'modelKey': 'explicit-test-model', 'dimensions': 512};
      expect(call.method, 'embed');
      expect((call.arguments as Map)['query'], isTrue);
      entered.complete();
      return reply.future;
    };
    final future = embeddings.rank(
      store: store,
      characterId: null,
      query: '查询',
      isCurrent: () => store.archive['control_revision'] == control,
    );
    final rejected = expectLater(future, throwsA(isA<CompanionMemoryRetrievalCancelled>()));
    await entered.future;
    try {
      store.saveManual(
        CompanionMemory(id: card['id']! as String, text: '修改后的事实', keywords: const []),
        expectedRowRev: card['row_rev']! as int,
        currentValueChange: true,
        realityKnown: true,
      );
      expect(store.archive['control_revision'], isNot(control));
    } finally {
      reply.complete([unit(0)]);
    }
    await rejected;
    expect(calls.where((call) => call.method == 'embed'), hasLength(1));
    expect(database.select('SELECT * FROM memory_embeddings'), isEmpty);
    expect(
      store.saveMemoryEmbedding(
        characterId: null,
        cardId: card['id']! as String,
        rowRevision: card['row_rev']! as int,
        modelKey: 'explicit-test-model',
        vector: unit(0),
      ),
      isFalse,
    );
  });

  test('missing optional model is null without downloading and empty candidates need no native call', () async {
    expect(await embeddings.rank(store: store, characterId: null, query: '空', isCurrent: () => true), isEmpty);
    expect(calls, isEmpty);
    shared('还没有下载本地模型');
    expect(await embeddings.rank(store: store, characterId: null, query: '查询', isCurrent: () => true), isNull);
    expect(calls.map((call) => call.method), ['load']);
    expect(embeddings.status, CompanionMemoryModelStatus.notDownloaded);
    expect(database.select('SELECT * FROM memory_embeddings'), isEmpty);
  });
}
