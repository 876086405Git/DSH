// These regressions exercise the real Store and Dart retrieval service. The
// platform boundary returns explicit synthetic unit vectors; this is not a
// tokenizer, ONNX, semantic-quality, or device-performance test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:dsh_app/companion/companion_memory_embeddings.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/companion_memory_embeddings');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  late CompanionMemoryEmbeddings embeddings;
  CompanionMemoryOwner? owner;
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
    owner = null;
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
    final memory = owner;
    if (memory == null) {
      embeddings.dispose();
    } else {
      memory.dispose();
    }
    await unloaded.future;
    messenger.setMockMethodCallHandler(channel, null);
    if (memory == null) store.close();
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

    // A fixed impression can identify the topic of an ordinary card whose
    // own keywords differ. Preserve that full-domain permission through the
    // real encoder, Owner selector and the public SDK recall transaction.
    final c = store.ensureCompanionCharacter(sourceKey: 'test:character-c')['id']! as String;
    final currentCommon = store.cards().singleWhere((row) => row['id'] == common['id']);
    final quietSource = store.submitMessage(
      id: id(), sessionId: 'light:embedding-test', characterId: c,
      text: '那条共同事实暂时不主动聊。', saidAtUtc: now, offsetMinutes: 0,
    );
    final quietTurn = store.beginAgentTurn(
      messageId: quietSource['id']! as String,
      expectedSourceRev: quietSource['source_rev']! as int,
      shownCardRevisions: {currentCommon['id']! as String: currentCommon['row_rev']! as int},
    )['id']! as String;
    expect(store.applyAgentMemoryTool(
      turnId: quietTurn, callId: 'quiet-common', toolName: 'quiet',
      input: {'card': currentCommon['id'], 'mode': 'never'},
    ).applied, isTrue);
    store.closeAgentTurn(quietTurn);
    final impressionSource = store.submitMessage(
      id: id(), sessionId: 'light:embedding-test', characterId: c,
      text: '我和你聊咖啡的时候很放松。', saidAtUtc: now, offsetMinutes: 0,
    );
    final impressionTurn = store.beginAgentTurn(
      messageId: impressionSource['id']! as String,
      expectedSourceRev: impressionSource['source_rev']! as int,
      shownCardRevisions: const {},
    )['id']! as String;
    final impression = store.applyAgentMemoryTool(
      turnId: impressionTurn, callId: 'fixed-coffee', toolName: 'impression',
      input: {'text': '聊咖啡时彼此很放松。', 'keywords': ['咖啡']},
    );
    expect(impression.applied, isTrue);
    expect(store.applyAgentMemoryTool(
      turnId: impressionTurn, callId: 'quiet-coffee', toolName: 'quiet',
      input: {'card': impression.targetId, 'mode': 'never'},
    ).applied, isTrue);
    store.closeAgentTurn(impressionTurn);
    final walkSource = store.submitMessage(
      id: id(), sessionId: 'light:embedding-test', characterId: c,
      text: '我们聊过咖啡，也一起散步。', saidAtUtc: now, offsetMinutes: 0,
    );
    final walkTurn = store.beginAgentTurn(
      messageId: walkSource['id']! as String,
      expectedSourceRev: walkSource['source_rev']! as int,
      shownCardRevisions: const {},
    )['id']! as String;
    final walk = store.applyAgentMemoryTool(
      turnId: walkTurn, callId: 'ordinary-walk', toolName: 'remember',
      input: {'collection': 'our_story', 'text': '我们聊过咖啡，也一起散步。', 'keywords': ['散步']},
    );
    expect(walk.applied, isTrue);
    store.closeAgentTurn(walkTurn);
    final fixedCard = store.cards().singleWhere((row) => row['id'] == impression.targetId);
    final ordinaryCard = store.cards().singleWhere((row) => row['id'] == walk.targetId);
    expect(fixedCard['layer'], 'impression');
    expect(ordinaryCard['layer'], 'card');
    expect(ordinaryCard['keywords'], ['散步']);
    expect(ordinaryCard['topic_id'], fixedCard['topic_id']);
    expect(ordinaryCard['topic_mode'], 'never');
    expect(store.memoryRetrievalCandidates(characterId: c, input: '聊聊咖啡').map((row) => row['id']), [walk.targetId]);
    final cardsBeforeInvitation = store.cards();
    final controlsBeforeInvitation = store.topicControls();
    final archiveBeforeInvitation = store.archive;
    final encodedBeforeInvitation = encoded.length;
    expect(await embeddings.rank(store: store, characterId: c, query: '聊聊咖啡', isCurrent: () => true), isEmpty);
    expect(encoded.skip(encodedBeforeInvitation), isEmpty);
    // The model may shorten the query while the invitation remains the person's actual words.
    final invited = await embeddings.rank(
      store: store, characterId: c, query: '咖啡', explicitInput: '聊聊咖啡', isCurrent: () => true,
    );
    expect(invited!.map((row) => row['id']), [walk.targetId]);
    expect(encoded.skip(encodedBeforeInvitation), contains(ordinaryCard['text']));
    expect(encoded.skip(encodedBeforeInvitation), isNot(contains(fixedCard['text'])));
    final memory = CompanionMemoryOwner(
      store, CompanionLocal.at(directory, nowMilliseconds: () => now),
      nowMilliseconds: () => now, embeddings: embeddings,
    );
    owner = memory;
    final selected = await memory.selectForAgent(
      '聊聊咖啡', characterId: c, offsetMinutes: 0,
      explicitUserInput: '聊聊咖啡', isCurrent: () => true,
    );
    expect(selected.ids, [impression.targetId, walk.targetId]);
    expect((jsonDecode(selected.block) as Map)['items'], contains(containsPair('id', walk.targetId)));
    final uninvited = await memory.selectForAgent(
      '聊聊咖啡', characterId: c, offsetMinutes: 0, isCurrent: () => true,
    );
    expect(uninvited.ids, isEmpty);
    expect(store.cards(), cardsBeforeInvitation);
    expect(store.topicControls(), controlsBeforeInvitation);
    expect(store.archive, archiveBeforeInvitation);

    final recallSource = store.submitMessage(
      id: id(), sessionId: 'light:embedding-test', characterId: c,
      text: '聊聊咖啡', saidAtUtc: now, offsetMinutes: 0,
    );
    final recallTurn = store.beginAgentTurn(
      messageId: recallSource['id']! as String,
      expectedSourceRev: recallSource['source_rev']! as int,
      shownCardRevisions: const {},
    )['id']! as String;
    final uninvitedIds = await memory.recallIds('聊聊咖啡', characterId: c, isCurrent: () => true);
    expect(uninvitedIds, isEmpty);
    final actualRankedIds = await memory.recallIds(
      '咖啡', explicitUserInput: recallSource['text']! as String,
      characterId: c, isCurrent: () => store.isAgentTurnCurrent(recallTurn),
    );
    expect(actualRankedIds, [walk.targetId]);
    final recalled = store.applyAgentMemoryTool(
      turnId: recallTurn, callId: 'ranked-coffee', toolName: 'recall',
      input: {'query': '咖啡'}, rankedRecallIds: actualRankedIds,
    );
    expect(recalled.applied, isTrue);
    expect(recalled.recallSelection!.ids, [walk.targetId]);
    expect(store.beginAgentTurn(
      messageId: recallSource['id']! as String,
      expectedSourceRev: recallSource['source_rev']! as int,
      shownCardRevisions: const {},
    )['shown_cards'], {walk.targetId!: ordinaryCard['row_rev']});
    final replayed = store.applyAgentMemoryTool(
      turnId: recallTurn, callId: 'ranked-coffee', toolName: 'recall',
      input: {'query': '咖啡'}, rankedRecallIds: actualRankedIds,
    );
    expect(replayed.replayed, isTrue);
    expect(replayed.recallSelection!.ids, [walk.targetId]);
    expect(store.cards(), cardsBeforeInvitation);
    expect(store.topicControls(), controlsBeforeInvitation);
    store.closeAgentTurn(recallTurn);
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
    expect(embeddings.knownUnavailable, isFalse, reason: 'not checked yet: the next request may load it');
    shared('还没有下载本地模型');
    expect(await embeddings.rank(store: store, characterId: null, query: '查询', isCurrent: () => true), isNull);
    expect(calls.map((call) => call.method), ['load']);
    expect(embeddings.knownUnavailable, isTrue);
    expect(embeddings.status, CompanionMemoryModelStatus.notDownloaded);
    expect(database.select('SELECT * FROM memory_embeddings'), isEmpty);
  });
}
