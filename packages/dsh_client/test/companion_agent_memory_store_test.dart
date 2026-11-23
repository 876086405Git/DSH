import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

/// A stored message on the fields a test captured from it: the store may also
/// carry its own extraction bookkeeping on the row.
Map<String, Object?> _captured(CompanionMemoryStore store, Map<String, Object?> like) {
  final row = store.messages().singleWhere((source) => source['id'] == like['id']);
  return {for (final key in like.keys) key: row[key]};
}

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1800000000000, nextId = 0;
  String id() => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';
  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now, createId: id);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow say(String messageId, String text) =>
      store.submitMessage(id: messageId, sessionId: 'light:agent', text: text, saidAtUtc: now, offsetMinutes: 0);
  MemoryRow seed(String text, {List<String> keywords = const []}) {
    final cardId = id();
    store.saveManual(
      CompanionMemory(id: cardId, text: text, keywords: keywords),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    return store.cards().singleWhere((card) => card['id'] == cardId);
  }

  String begin(MemoryRow source, [Iterable<MemoryRow> shown = const []]) =>
      store.beginAgentTurn(
            messageId: source['id']! as String,
            expectedSourceRev: source['source_rev']! as int,
            shownCardRevisions: {for (final card in shown) card['id']! as String: card['row_rev']! as int},
          )['id']!
          as String;
  CompanionAgentMemoryResult call(String turn, String callId, String name, MemoryRow input) =>
      store.applyAgentMemoryTool(turnId: turn, callId: callId, toolName: name, input: input);

  String character(String key) => store.ensureCompanionCharacter(sourceKey: key)['id']! as String;
  MemoryRow sayAs(String messageId, String text, String roleId, {String role = 'user'}) => store.submitMessage(
    id: messageId,
    sessionId: 'light:agent',
    text: text,
    role: role,
    saidAtUtc: now,
    offsetMinutes: 0,
    characterId: roleId,
  );
  MemoryRow actualCard(String cardId) => store.cards(includeInactive: true).singleWhere((row) => row['id'] == cardId);
  void grantMaintenance(MemoryRow turn) => store.grantAgentCards(
    turnId: turn['id']! as String,
    cardRevisions: {
      for (final card in turn['cards'] as List<MemoryRow>) card['id']! as String: card['row_rev']! as int,
    },
  );

  void observed(String requestId, {int input = 100, int output = 10}) {
    store.markRequestSent(requestId);
    store.recordUsage(requestId, {
      'input_uncached': input,
      'input_cache_read': 0,
      'input_cache_write': 0,
      'output_tokens': output,
      'usage_semantics': 'provider_raw',
    });
    store.finishRequest(requestId, terminal: 'complete');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-agent-memory-');
    now = 1800000000000;
    nextId = 0;
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('structured corrections use current references without reparsing the user sentence', () {
    final card = seed('面试安排在周四');
    final source = say('source', '我把面试改成周五了，稍后再确认。');
    final turn = begin(source, [card]);
    final before = store.archive['control_revision'];
    final first = call(turn, 'revise-1', 'revise', {'card': card['id'], 'text': '面试安排在周五'});
    expect(first.applied, isTrue);
    expect(first.beforeControlRevision, before);
    expect(first.controlRevision, (before! as int) + 1);
    expect(first.currentCardRevisions[card['id']], 2);
    final second = call(turn, 'revise-2', 'revise', {'card': card['id'], 'text': '面试安排在周五下午'});
    expect(second.applied, isTrue);
    expect(second.beforeControlRevision, first.controlRevision);
    expect(second.currentCardRevisions[card['id']], 3);
    expect(store.cards().single['text'], '面试安排在周五下午');
    expect((store.cards().single['evidence'] as List).single, containsPair('message_id', 'source'));
    expect(store.messages().single['text'], source['text']);
    expect(
      store.beginAgentTurn(messageId: 'source', expectedSourceRev: 1, shownCardRevisions: const {})['changed_cards'],
      [card['id']],
    );

    // Changing an existing automatic card must inherit the new topic, even
    // when its previous topic is equally quiet and later explicitly restored.
    store.closeAgentTurn(turn);
    final coffeeMaking = begin(say('rewrite-coffee-source', '我喝咖啡不加糖。'));
    final coffeeCard = call(coffeeMaking, 'rewrite-coffee', 'remember', {
      'text': '我喝咖啡不加糖。',
      'keywords': ['咖啡'],
    }).targetId!;
    expect(call(coffeeMaking, 'rewrite-coffee-never', 'quiet', {'card': coffeeCard, 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(coffeeMaking);
    final coffeeTopic = actualCard(coffeeCard)['topic_id'];
    final interviewSource = say('rewrite-interview-source', '面试安排在周五下午。');
    final interview = begin(interviewSource, [actualCard(card['id']! as String)]);
    expect(
      call(interview, 'rewrite-interview-keyword', 'remember', {
        'card': card['id'],
        'text': '面试安排在周五下午',
        'keywords': ['面试'],
      }).applied,
      isTrue,
    );
    expect(call(interview, 'rewrite-interview-never', 'quiet', {'card': card['id'], 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(interview);
    final interviewTopic = actualCard(card['id']! as String)['topic_id'];
    final controlsBeforeRewrite = store.topicControls();
    const rewrittenText = '我最近的咖啡甜度是无糖';
    final rewritingSource = say('rewrite-current-source', rewrittenText);
    final rewriting = begin(rewritingSource, [actualCard(card['id']! as String)]);
    final rewritten = call(rewriting, 'rewrite-existing', 'remember', {
      'card': card['id'],
      'text': rewrittenText,
      'keywords': ['无糖'],
    });
    expect(rewritten.applied, isTrue);
    expect(rewritten.changedCardIds, [card['id']]);
    final rewrittenCard = actualCard(card['id']! as String);
    expect(rewrittenCard['manual'], isFalse);
    expect(rewrittenCard['topic_id'], coffeeTopic);
    expect(rewrittenCard['topic_mode'], 'never');
    expect((rewrittenCard['evidence'] as List).single, containsPair('message_id', rewritingSource['id']));
    expect(store.topicControls(), controlsBeforeRewrite);
    expect(store.cards(includeInactive: true).where((row) => row['topic_id'] == interviewTopic), isEmpty);
    store.closeAgentTurn(rewriting);
    final restoringOld = begin(say('rewrite-restore-old-source', '面试以后可以聊了。'));
    final oldControl = call(restoringOld, 'rewrite-read-old', 'recall', {'query': '面试'});
    expect(oldControl.recalledControl, {
      'topic_id': interviewTopic,
      'mode': 'never',
      'anchors': ['面试'],
      'character_id': null,
    });
    expect(
      call(restoringOld, 'rewrite-restore-old', 'quiet', {'topic': interviewTopic, 'mode': 'normal'}).applied,
      isTrue,
    );
    expect(actualCard(card['id']! as String), rewrittenCard);
    expect(actualCard(coffeeCard)['topic_mode'], 'never');
    expect(explicitMemoryTopics('无糖', store.cards()), isEmpty);
    final afterOldRestore = selectMemoryContext(
      store.memoryRetrievalCandidates(characterId: null),
      input: '无糖',
      nowMs: now,
      controlRevision: store.archive['control_revision']! as int,
    );
    expect(afterOldRestore.ids, isNot(contains(card['id'])));
    expect(afterOldRestore.block, isNot(contains(rewrittenText)));
    expect(store.requests(), isEmpty);
  });

  test('new cards inherit only their exact character control and ambiguous controls write no card', () {
    final a = character('local:topic-a');
    final b = character('local:topic-b');
    final first = begin(sayAs('a-first', '我们周五一起复诊。', a));
    final saved = call(first, 'remember-a', 'remember', {
      'collection': 'our_story',
      'text': '我们周五一起复诊。',
      'keywords': ['复诊'],
    });
    expect(saved.applied, isTrue);
    expect(call(first, 'quiet-a', 'quiet', {'card': saved.targetId, 'mode': 'never'}).applied, isTrue);
    final privateTopic = actualCard(saved.targetId!)['topic_id'];

    final same = begin(sayAs('a-later', '我们周六一起复诊。', a));
    final sameCard = call(same, 'remember-a-later', 'remember', {
      'collection': 'our_story',
      'text': '我们周六一起复诊。',
      'keywords': ['复诊'],
    });
    expect(sameCard.applied, isTrue);
    expect(actualCard(sameCard.targetId!)['topic_id'], privateTopic);
    expect(actualCard(sameCard.targetId!)['topic_mode'], 'never');
    final other = begin(sayAs('b-first', '我们周六一起复诊。', b));
    final otherCard = call(other, 'remember-b', 'remember', {
      'collection': 'our_story',
      'text': '我们周六一起复诊。',
      'keywords': ['复诊'],
    });
    expect(otherCard.applied, isTrue);
    expect(actualCard(otherCard.targetId!)['topic_id'], isNot(privateTopic));
    expect(actualCard(otherCard.targetId!)['topic_mode'], 'normal');
    final shared = begin(sayAs('shared-first', '我周六复诊。', a));
    final sharedCard = call(shared, 'remember-shared', 'remember', {
      'text': '你周六复诊。',
      'keywords': ['复诊'],
    });
    expect(sharedCard.applied, isTrue);
    expect(actualCard(sharedCard.targetId!)['character_id'], isNull);
    expect(actualCard(sharedCard.targetId!)['topic_id'], isNot(privateTopic));
    expect(actualCard(sharedCard.targetId!)['topic_mode'], 'normal');

    // Two independently controlled shared topics are real public-tool effects.
    // Neither a role mismatch nor ambiguous anchors can invent a new success.
    final setup = begin(say('independent', '修琴周六完成，陶杯周日烧好。'));
    final music = call(setup, 'music', 'remember', {
      'text': '修琴周六完成。',
      'keywords': ['修琴'],
    });
    final pottery = call(setup, 'pottery', 'remember', {
      'text': '陶杯周日烧好。',
      'keywords': ['陶杯'],
    });
    expect(music.applied, isTrue);
    expect(pottery.applied, isTrue);
    expect(actualCard(music.targetId!)['topic_id'], isNot(actualCard(pottery.targetId!)['topic_id']));
    expect(call(setup, 'quiet-music', 'quiet', {'card': music.targetId, 'mode': 'never'}).applied, isTrue);
    expect(call(setup, 'quiet-pottery', 'quiet', {'card': pottery.targetId, 'mode': 'never'}).applied, isTrue);
    reopen();
    final attempt = begin(say('ambiguous', '修琴和陶杯以后再谈。'));
    final beforeCards = store.cards(includeInactive: true);
    final beforeArchive = store.archive;
    final rejected = call(attempt, 'ambiguous-write', 'remember', {
      'text': '修琴和陶杯以后再谈。',
      'keywords': ['修琴', '陶杯'],
    });
    expect(rejected.applied, isFalse);
    expect(rejected.code, 'ambiguous_controlled_topic');
    expect(rejected.changedCardIds, isEmpty);
    expect(rejected.targetId, isNull);
    expect(store.cards(includeInactive: true), beforeCards);
    expect(store.archive, beforeArchive);
    expect(store.agentToolCall(turnId: attempt, callId: 'ambiguous-write')!.state, 'ignored');

    // Three actual sources create independent topics before any star control.
    // Keep the original live-topic ambiguity above: restoring empty controls
    // must not guess that two independently controlled facts are one topic.
    final otherControls = store.topicControls();
    const starText = '我们喜欢一起看星星。';
    final stars = <String>[];
    for (final sourceId in const ['star-one', 'star-two', 'star-three']) {
      final making = begin(sayAs(sourceId, starText, a));
      final made = call(making, 'remember-star', 'remember', {
        'collection': 'our_story',
        'text': starText,
        'keywords': ['星星'],
      });
      expect(made.applied, isTrue);
      stars.add(made.targetId!);
      store.closeAgentTurn(making);
    }
    final starTopics = [for (final cardId in stars) actualCard(cardId)['topic_id']! as String];
    expect(starTopics.toSet(), hasLength(3));
    final quieting = begin(sayAs('stars-less', '以后少提星星。', a), stars.map(actualCard));
    expect(call(quieting, 'less-one', 'quiet', {'card': stars[0], 'mode': 'less'}).applied, isTrue);
    expect(call(quieting, 'less-two', 'quiet', {'card': stars[1], 'mode': 'less'}).applied, isTrue);
    expect(call(quieting, 'less-three', 'quiet', {'card': stars[2], 'mode': 'less'}).applied, isTrue);
    store.closeAgentTurn(quieting);
    final merging = begin(sayAs('stars-merge', '把同一件看星星的事合成一条。', a), stars.map(actualCard));
    final merged = call(merging, 'merge-three', 'merge', {'card': stars[0], 'from': stars.skip(1).toList()});
    expect(merged.applied, isTrue);
    expect(merged.changedCardIds, unorderedEquals(stars));
    expect(actualCard(stars[0])['topic_mode'], 'less');
    expect(store.cards(includeInactive: true).where((card) => stars.skip(1).contains(card['id'])), isEmpty);
    store.closeAgentTurn(merging);

    final restoringSource = sayAs('stars-allowed', '以后可以聊星星了，我们仍喜欢一起看星星。', a);
    final restoring = begin(restoringSource, [actualCard(stars[0])]);
    expect(call(restoring, 'normal-result', 'quiet', {'card': stars[0], 'mode': 'normal'}).applied, isTrue);
    final emptyTopics = starTopics.skip(1).toSet();
    final emptyControls = store.topicControls().where((row) => emptyTopics.contains(row['topic_id'])).toList();
    expect(emptyControls, hasLength(2));
    expect(emptyControls.every((row) => row['mode'] == 'less' && jsonEncode(row['anchors']) == '["星星"]'), isTrue);
    final stillAmbiguous = call(restoring, 'stars-before-read', 'remember', {
      'collection': 'our_story',
      'text': starText,
      'keywords': ['星星'],
    });
    expect(stillAmbiguous.code, 'ambiguous_controlled_topic');
    final cardsBeforeRestore = store.cards(includeInactive: true);
    final archiveBeforeRead = store.archive;
    expect(
      call(restoring, 'unread-topic', 'quiet', {'topic': starTopics[1], 'mode': 'normal'}).code,
      'topic_not_in_turn',
    );
    expect(store.archive, archiveBeforeRead);
    final otherRole = begin(sayAs('b-stars', '以后可以聊星星了。', b));
    final otherRead = call(otherRole, 'b-read-stars', 'recall', {'query': '星星'});
    expect(otherRead.applied, isTrue);
    expect(otherRead.recalledControl, isNull);
    expect(otherRead.recallSelection!.ids, isNot(contains(stars[0])));
    expect(
      call(otherRole, 'b-restore-stars', 'quiet', {'topic': starTopics[1], 'mode': 'normal'}).code,
      'topic_not_in_turn',
    );
    store.closeAgentTurn(otherRole);

    final beforeFirstRead = store.archive;
    final firstRead = call(restoring, 'read-star-control', 'recall', {'query': '星星'});
    expect(firstRead.applied, isTrue);
    expect(firstRead.changedCardIds, isEmpty);
    expect(firstRead.recallSelection!.ids, contains(stars[0]));
    final firstTopic = firstRead.recalledControl!['topic_id']! as String;
    expect(emptyTopics, contains(firstTopic));
    expect(firstRead.targetId, firstTopic);
    expect(firstRead.recalledControl, {
      'topic_id': firstTopic,
      'mode': 'less',
      'anchors': ['星星'],
      'character_id': a,
    });
    expect(store.archive, beforeFirstRead);
    final firstRestore = call(restoring, 'restore-first-control', 'quiet', {'topic': firstTopic, 'mode': 'normal'});
    expect(firstRestore.applied, isTrue);
    expect(firstRestore.changedCardIds, isEmpty);
    expect(firstRestore.targetId, firstTopic);
    final secondTopic = emptyTopics.singleWhere((topic) => topic != firstTopic);
    final oldRead = call(restoring, 'read-star-control', 'recall', {'query': '星星'});
    expect(oldRead.replayed, isTrue);
    expect(oldRead.targetId, firstTopic);
    expect(oldRead.recalledControl, isNull, reason: 'replaying a read cannot grant the next matching control');
    expect(
      call(restoring, 'second-without-read', 'quiet', {'topic': secondTopic, 'mode': 'normal'}).code,
      'topic_not_in_turn',
    );
    final secondRead = call(restoring, 'read-next-star-control', 'recall', {'query': '星星'});
    expect(secondRead.recalledControl, {
      'topic_id': secondTopic,
      'mode': 'less',
      'anchors': ['星星'],
      'character_id': a,
    });
    // This receipt really grants the still-quiet second control before cold
    // reopen. Reading its old identity must not reopen the closed execution.
    reopen();
    final closedRead = call(restoring, 'read-next-star-control', 'recall', {'query': '星星'});
    expect(closedRead.replayed, isTrue);
    expect(closedRead.targetId, secondTopic);
    expect(closedRead.recalledControl, isNull);
    expect(closedRead.recallSelection, isNull);
    expect(call(restoring, 'closed-restore', 'quiet', {'topic': secondTopic, 'mode': 'normal'}).code, 'turn_closed');
    final continuedSource = sayAs('stars-continue', '星星现在可以聊了，我们喜欢一起看星星。', a);
    final continued = begin(continuedSource);
    expect(
      call(continued, 'fresh-read-star-control', 'recall', {'query': '星星'}).recalledControl,
      secondRead.recalledControl,
    );
    final secondRestore = call(continued, 'restore-second-control', 'quiet', {'topic': secondTopic, 'mode': 'normal'});
    expect(secondRestore.applied, isTrue);
    expect(secondRestore.changedCardIds, isEmpty);
    final restoredArchive = store.archive;
    expect(
      call(continued, 'restore-second-control', 'quiet', {'topic': secondTopic, 'mode': 'normal'}).replayed,
      isTrue,
    );
    expect(store.archive, restoredArchive);
    expect(store.cards(includeInactive: true), cardsBeforeRestore);
    expect(store.topicControls(), otherControls);
    final afterRestore = call(continued, 'stars-after-restore', 'remember', {
      'collection': 'our_story',
      'text': starText,
      'keywords': ['星星'],
    });
    expect(afterRestore.applied, isTrue);
    expect(actualCard(afterRestore.targetId!)['topic_mode'], 'normal');
    expect(actualCard(afterRestore.targetId!)['character_id'], a);
    expect(
      store.beginAgentTurn(
        messageId: continuedSource['id']! as String,
        expectedSourceRev: 1,
        shownCardRevisions: const {},
      )['changed_cards'],
      [afterRestore.targetId],
    );

    // A live private topic now yields its real control receipt. Topic-only
    // writes still accept normal, not less; keep this private never control
    // for the shared manual-card isolation checks below.
    store.closeAgentTurn(continued);
    final liveSource = sayAs('live-topic-only', '以后可以聊复诊了。', a);
    final liveTurn = begin(liveSource);
    final liveRead = call(liveTurn, 'read-live-topic', 'recall', {'query': '复诊'});
    expect(liveRead.applied, isTrue);
    expect(liveRead.recalledControl, {
      'topic_id': privateTopic,
      'mode': 'never',
      'anchors': ['复诊'],
      'character_id': a,
    });
    expect(
      call(liveTurn, 'topic-less-is-not-normal', 'quiet', {'topic': privateTopic, 'mode': 'less'}).code,
      'invalid_mode',
    );
    expect(actualCard(saved.targetId!)['topic_mode'], 'never');
    expect(
      store.beginAgentTurn(
        messageId: liveSource['id']! as String,
        expectedSourceRev: 1,
        shownCardRevisions: const {},
      )['changed_cards'],
      isEmpty,
    );
    expect(actualCard(afterRestore.targetId!)['topic_mode'], 'normal');
    expect(store.topicControls(), otherControls);
    expect(store.requests(), isEmpty, reason: 'these are public SDK transactions, not HTTP request receipts');

    // The real editor creates a new shared manual card with no keywords. A
    // new fact is not permission to reopen an existing expression control.
    store.closeAgentTurn(liveTurn);
    const coffeeText = '我最近的咖啡甜度是无糖';
    final coffeeSource = begin(say('manual-coffee-source', coffeeText));
    final coffee = call(coffeeSource, 'remember-coffee', 'remember', {
      'text': coffeeText,
      'keywords': ['咖啡'],
    }).targetId!;
    store.closeAgentTurn(coffeeSource);
    final coffeeControl = begin(say('manual-coffee-control', '以后不要提咖啡了。'), [actualCard(coffee)]);
    expect(call(coffeeControl, 'quiet-coffee', 'quiet', {'card': coffee, 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(coffeeControl);
    final coffeeBefore = actualCard(coffee);
    final controlsBeforeManual = store.topicControls();
    final manualCoffee = seed(coffeeText);
    expect(manualCoffee['collection'], 'about_you');
    expect(manualCoffee['character_id'], isNull);
    expect(manualCoffee['manual'], isTrue);
    expect(manualCoffee['keywords'], isEmpty);
    expect(manualCoffee['topic_id'], coffeeBefore['topic_id']);
    expect(manualCoffee['topic_mode'], 'never');
    expect(actualCard(coffee), coffeeBefore);
    expect(store.topicControls(), controlsBeforeManual);
    expect(explicitMemoryTopics('最近', store.cards()), isEmpty);
    final ordinary = selectMemoryContext(
      store.memoryRetrievalCandidates(characterId: null),
      input: '最近',
      nowMs: now,
      controlRevision: store.archive['control_revision']! as int,
    );
    expect(ordinary.ids, isNot(contains(manualCoffee['id'])));
    expect(ordinary.block, isNot(contains(coffeeText)));

    // The existing clinic control belongs to a, while its shared card remains
    // normal. A manual shared card must not inherit a private role's control.
    final privateBefore = actualCard(saved.targetId!);
    final sharedBefore = actualCard(sharedCard.targetId!);
    final manualShared = seed('我们周六一起复诊。', keywords: ['复诊']);
    expect(manualShared['character_id'], isNull);
    expect(manualShared['topic_id'], isNot(privateTopic));
    expect(manualShared['topic_mode'], 'normal');
    expect(actualCard(saved.targetId!), privateBefore);
    expect(actualCard(sharedCard.targetId!), sharedBefore);
    final unrelatedManual = seed('今天想折一架纸飞机。');
    expect(unrelatedManual['topic_mode'], 'normal');
    expect(store.topicControls(), controlsBeforeManual);

    final manualCardsBefore = store.cards(includeInactive: true);
    final manualArchiveBefore = store.archive;
    expect(
      () => seed('修琴和陶杯都准备好了。'),
      throwsA(
        isA<DshRemoteException>()
            .having((error) => error.code, 'code', 'companion/invalid-request')
            .having((error) => error.details['status'], 'status', 400)
            .having((error) => error.details['reason'], 'reason', 'ambiguous_controlled_topic'),
      ),
    );
    expect(store.cards(includeInactive: true), manualCardsBefore);
    expect(store.archive, manualArchiveBefore);
    expect(store.topicControls(), controlsBeforeManual);

    // Create both normal topics before quieting either. Public merge then
    // normal of its result leaves one actual empty less control, not a fake ID.
    const windText = '我最近买的风铃是蓝色。';
    final windTurn = begin(say('manual-empty-source', windText));
    final windFirst = call(windTurn, 'wind-first', 'remember', {
      'text': windText,
      'keywords': ['风铃'],
    }).targetId!;
    final windSecond = call(windTurn, 'wind-second', 'remember', {
      'text': windText,
      'keywords': ['风铃'],
    }).targetId!;
    final windFirstTopic = actualCard(windFirst)['topic_id'];
    final windEmptyTopic = actualCard(windSecond)['topic_id'];
    expect(windFirstTopic, isNot(windEmptyTopic));
    expect(call(windTurn, 'less-wind-first', 'quiet', {'card': windFirst, 'mode': 'less'}).applied, isTrue);
    expect(call(windTurn, 'less-wind-second', 'quiet', {'card': windSecond, 'mode': 'less'}).applied, isTrue);
    store.closeAgentTurn(windTurn);
    final windMerge = begin(say('manual-empty-merge', '把两条相同的风铃记忆合并，现在可以聊合并的这条。'), [
      actualCard(windFirst),
      actualCard(windSecond),
    ]);
    expect(
      call(windMerge, 'merge-wind', 'merge', {
        'card': windFirst,
        'from': [windSecond],
      }).applied,
      isTrue,
    );
    expect(call(windMerge, 'normal-wind-result', 'quiet', {'card': windFirst, 'mode': 'normal'}).applied, isTrue);
    store.closeAgentTurn(windMerge);
    final windTargetBefore = actualCard(windFirst);
    expect(windTargetBefore['topic_id'], windFirstTopic);
    expect(windTargetBefore['topic_mode'], 'normal');
    expect(store.cards(includeInactive: true).where((row) => row['topic_id'] == windEmptyTopic), isEmpty);
    final windControls = store.topicControls();
    expect(windControls.singleWhere((row) => row['topic_id'] == windEmptyTopic), {
      'topic_id': windEmptyTopic,
      'mode': 'less',
      'anchors': ['风铃'],
    });
    final manualEmpty = seed('我最近喜欢听风铃的声音。');
    expect(manualEmpty['topic_id'], windEmptyTopic);
    expect(manualEmpty['topic_mode'], 'less');
    expect(manualEmpty['keywords'], isEmpty);
    expect(store.topicControls(), windControls);
    expect(actualCard(windFirst), windTargetBefore);

    // The existing Page editor can change this unrelated, keyword-free card.
    // Zero matches keep its topic; ambiguous matches cannot commit a prefix.
    final editingId = unrelatedManual['id']! as String;
    store.saveManual(
      CompanionMemory(id: editingId, text: '我最近想做一架纸飞机。'),
      expectedRowRev: actualCard(editingId)['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(actualCard(editingId)['topic_id'], unrelatedManual['topic_id']);
    expect(actualCard(editingId)['topic_mode'], 'normal');
    final beforeAmbiguousEdit = store.cards(includeInactive: true);
    final archiveBeforeAmbiguousEdit = store.archive;
    final controlsBeforeEdit = store.topicControls();
    expect(
      () => store.saveManual(
        CompanionMemory(id: editingId, text: '修琴和陶杯都准备好了。'),
        expectedRowRev: actualCard(editingId)['row_rev']! as int,
        currentValueChange: true,
        realityKnown: true,
      ),
      throwsA(
        isA<DshRemoteException>()
            .having((error) => error.code, 'code', 'companion/invalid-request')
            .having((error) => error.details['status'], 'status', 400)
            .having((error) => error.details['reason'], 'reason', 'ambiguous_controlled_topic'),
      ),
    );
    expect(store.cards(includeInactive: true), beforeAmbiguousEdit);
    expect(store.archive, archiveBeforeAmbiguousEdit);
    expect(store.topicControls(), controlsBeforeEdit);
    store.saveManual(
      CompanionMemory(id: editingId, text: coffeeText),
      expectedRowRev: actualCard(editingId)['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(actualCard(editingId)['manual'], isTrue);
    expect(actualCard(editingId)['keywords'], isEmpty);
    expect(actualCard(editingId)['topic_id'], coffeeBefore['topic_id']);
    expect(actualCard(editingId)['topic_mode'], 'never');
    expect(actualCard(coffee), coffeeBefore);
    expect(store.topicControls(), controlsBeforeEdit);
    expect(explicitMemoryTopics('最近', store.cards()), isEmpty);
    final afterEditing = selectMemoryContext(
      store.memoryRetrievalCandidates(characterId: null),
      input: '最近',
      nowMs: now,
      controlRevision: store.archive['control_revision']! as int,
    );
    expect(afterEditing.ids, isNot(contains(editingId)));
    expect(afterEditing.block, isNot(contains(coffeeText)));
  });

  for (final mode in const ['less', 'never']) {
    test('a remembered shared topic keeps $mode across reopen without quieting another clause', () {
      store.initializeInitiative({
        'v': 2,
        'lastGreetingAtMs': null,
        'inviteAtMs': <int>[],
        'signalAtMs': <int>[],
        'declinedUntilMs': 0,
        'night': null,
      });
      final first = begin(say('controlled-first', '我在周末骑行。'));
      final saved = call(first, 'remember-first', 'remember', {
        'text': '你在周末骑行。',
        'keywords': ['骑行'],
      });
      expect(saved.applied, isTrue);
      final scheduled = call(first, 'schedule-first', 'ask_later', {'card': saved.targetId, 'whenMs': now});
      expect(scheduled.applied, isTrue);
      final ticket = store.nextFollowup(nowMs: now)!;
      expect(ticket['id'], scheduled.targetId);
      final spend = store.reserveInitiative(
        kind: 'followup',
        nowMs: now,
        maxPerDay: 2,
        gapMs: 0,
        followupId: ticket['id']! as String,
      )!;
      final outcome = mode == 'less' ? 'shown' : 'unknown';
      store.settleInitiative(spend, outcome: outcome);
      expect(store.followups().single['state'], mode == 'less' ? 'asked' : 'maybe_shown');
      // This SDK fixture records a sent request through the public ledger API;
      // it does not claim an HTTP provider was contacted.
      final request = store.reserveRequest(
        category: 'chat',
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 100,
        outputTokens: 800,
      )!;
      observed(request);
      final paid = store.requests();
      expect(paid.single['id'], request);
      expect(paid.single['sent_at_ms'], isNotNull);
      expect(paid.single['state'], 'finished');
      final spent = database
          .select('SELECT * FROM memory_initiative_spends')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      expect(spent.single['state'], outcome);
      final consumed = store.followups().single;
      final consumedCard = actualCard(saved.targetId!);
      expect(
        call(first, 'already-normal-consumed', 'quiet', {'card': saved.targetId, 'mode': 'normal'}).applied,
        isTrue,
      );
      final stillConsumed = store.followups().single;
      expect(stillConsumed['id'], consumed['id']);
      expect(stillConsumed['state'], consumed['state']);
      expect(stillConsumed['presented_at_ms'], consumed['presented_at_ms']);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(actualCard(saved.targetId!), consumedCard);
      expect(database.select('SELECT * FROM memory_initiative_spends'), spent);
      expect(store.requests(), paid);
      expect(call(first, 'quiet-first', 'quiet', {'card': saved.targetId, 'mode': mode}).applied, isTrue);
      final topic = actualCard(saved.targetId!)['topic_id'];
      reopen();

      final later = begin(say('controlled-later', '我会在河边骑行，也想做面包。'));
      final related = call(later, 'remember-related', 'remember', {
        'text': '你会在河边骑行。',
        'keywords': ['骑行'],
      });
      final unrelated = call(later, 'remember-unrelated', 'remember', {
        'text': '你想做面包。',
        'keywords': ['面包'],
      });
      expect(related.applied, isTrue);
      expect(unrelated.applied, isTrue);
      expect(actualCard(related.targetId!)['topic_id'], topic);
      expect(actualCard(related.targetId!)['topic_mode'], mode);
      expect(actualCard(unrelated.targetId!)['topic_id'], isNot(topic));
      expect(actualCard(unrelated.targetId!)['topic_mode'], 'normal');
      expect(call(later, 'ask-muted', 'ask_later', {'card': related.targetId, 'whenMs': now}).code, 'topic_quiet');
      expect(
        (actualCard(related.targetId!)['evidence'] as List).single,
        containsPair('message_id', 'controlled-later'),
      );
      reopen();
      expect(actualCard(related.targetId!)['topic_id'], topic);
      expect(actualCard(related.targetId!)['topic_mode'], mode);
      expect(actualCard(unrelated.targetId!)['topic_mode'], 'normal');

      final oldOpportunities = store.followups();
      expect(oldOpportunities.single['state'], mode == 'less' ? 'closed' : 'maybe_shown');
      final controlled = [actualCard(saved.targetId!), actualCard(related.targetId!)];
      final independent = actualCard(unrelated.targetId!);
      final cutoff = store.archive['history_after_seq'];
      final restoring = begin(say('restore-normal', '以后可以聊骑行了。'), controlled);
      final restored = call(restoring, 'restore-normal', 'quiet', {'card': saved.targetId, 'mode': 'normal'});
      expect(restored.applied, isTrue);
      expect(restored.targetId, topic);
      expect(restored.changedCardIds, unorderedEquals(controlled.map((card) => card['id'])));
      for (final card in controlled) {
        expect(actualCard(card['id']! as String), {...card, 'topic_mode': 'normal', 'maintenance_row_rev': 0});
      }
      final topicRow = database.select('SELECT mode,control_anchors FROM memory_topics WHERE id=?', [topic]).single;
      expect(topicRow['mode'], 'normal');
      expect(jsonDecode(topicRow['control_anchors']! as String), isEmpty);
      expect(store.topicControls().any((row) => row['topic_id'] == topic), isFalse);
      expect(actualCard(unrelated.targetId!), independent);
      expect(store.archive['history_after_seq'], cutoff);
      expect(store.followups(), oldOpportunities);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(database.select('SELECT * FROM memory_initiative_spends'), spent);
      expect(store.requests(), paid);

      final fresh = begin(say('normal-new-source', '现在我改去公园骑行。'));
      final remembered = call(fresh, 'normal-new-memory', 'remember', {
        'text': '你现在去公园骑行。',
        'keywords': ['骑行'],
      });
      expect(remembered.applied, isTrue);
      expect(actualCard(remembered.targetId!)['topic_mode'], 'normal');
      expect(
        (actualCard(remembered.targetId!)['evidence'] as List).single,
        containsPair('message_id', 'normal-new-source'),
      );
      reopen();
      expect(actualCard(saved.targetId!)['topic_mode'], 'normal');
      expect(actualCard(related.targetId!)['topic_mode'], 'normal');
      expect(actualCard(remembered.targetId!)['topic_mode'], 'normal');
      expect(actualCard(unrelated.targetId!), independent);
      expect(store.followups(), oldOpportunities);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(database.select('SELECT * FROM memory_initiative_spends'), spent);
      expect(store.requests(), paid);

      // Create both same-fact cards before either new control exists. Their
      // distinct keywords are each present in their own original source.
      const sameFact = '你喜欢在天台看星星。';
      final targetTurn = begin(say('merge-quiet-target-source', '我喜欢在天台看星星。'));
      final targetMemory = call(targetTurn, 'merge-quiet-target', 'remember', {
        'text': sameFact,
        'keywords': ['天台'],
      });
      expect(targetMemory.applied, isTrue);
      store.closeAgentTurn(targetTurn);
      final fromTurn = begin(say('merge-quiet-from-source', '我喜欢在天台看星星。'));
      final fromMemory = call(fromTurn, 'merge-quiet-from', 'remember', {
        'text': sameFact,
        'keywords': ['星星'],
      });
      expect(fromMemory.applied, isTrue);
      store.closeAgentTurn(fromTurn);
      final targetId = targetMemory.targetId!, fromId = fromMemory.targetId!;
      final targetTopic = actualCard(targetId)['topic_id'], fromTopic = actualCard(fromId)['topic_id'];
      expect(targetTopic, isNot(fromTopic));
      final targetMode = mode == 'less' ? 'never' : 'less';
      final quietTarget = begin(say('merge-quiet-target-command', '按这个主题控制频率。'), [actualCard(targetId)]);
      expect(call(quietTarget, 'quiet-target', 'quiet', {'card': targetId, 'mode': targetMode}).applied, isTrue);
      store.closeAgentTurn(quietTarget);
      final quietFrom = begin(say('merge-quiet-from-command', '另一条也按这个主题控制频率。'), [actualCard(fromId)]);
      expect(call(quietFrom, 'quiet-from', 'quiet', {'card': fromId, 'mode': mode}).applied, isTrue);
      store.closeAgentTurn(quietFrom);
      final controls = database
          .select('SELECT id,mode,control_anchors FROM memory_topics WHERE id IN (?,?) ORDER BY id', [
            targetTopic,
            fromTopic,
          ])
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      expect(jsonDecode(controls.singleWhere((row) => row['id'] == targetTopic)['control_anchors']! as String), ['天台']);
      expect(jsonDecode(controls.singleWhere((row) => row['id'] == fromTopic)['control_anchors']! as String), ['星星']);
      final joining = begin(say('merge-quiet-command', '这两条说的是同一件事。'), [actualCard(targetId), actualCard(fromId)]);
      final joined = call(joining, 'merge-quiet', 'merge', {
        'card': targetId,
        'from': [fromId],
      });
      expect(joined.applied, isTrue);
      expect(joined.changedCardIds, unorderedEquals([targetId, fromId]));
      expect(joined.targetId, targetId);
      expect(actualCard(targetId)['topic_mode'], 'never');
      expect(actualCard(targetId)['topic_id'], mode == 'never' ? fromTopic : targetTopic);
      expect(store.cards().any((card) => card['id'] == fromId), isFalse);
      final emptyLessTopic = mode == 'less' ? fromTopic : targetTopic;
      expect(store.cards().any((card) => card['topic_id'] == emptyLessTopic), isFalse);
      expect(
        database.select('SELECT id,mode,control_anchors FROM memory_topics WHERE id IN (?,?) ORDER BY id', [
          targetTopic,
          fromTopic,
        ]),
        controls,
      );
      store.closeAgentTurn(joining);
      reopen();
      expect(
        database.select('SELECT id,mode,control_anchors FROM memory_topics WHERE id IN (?,?) ORDER BY id', [
          targetTopic,
          fromTopic,
        ]),
        controls,
      );
      // Only the original from-topic anchor occurs here. An empty controlled
      // topic still applies its own mode, without inheriting the other anchor.
      final fromOnly = begin(say('merge-from-only-source', '我还想看星星。'));
      final fromOnlyMemory = call(fromOnly, 'merge-from-only', 'remember', {
        'text': '你还想看星星。',
        'keywords': ['星星'],
      });
      expect(fromOnlyMemory.applied, isTrue);
      expect(actualCard(fromOnlyMemory.targetId!)['topic_id'], fromTopic);
      expect(actualCard(fromOnlyMemory.targetId!)['topic_mode'], mode);
      expect(
        call(fromOnly, 'merge-from-only-later', 'ask_later', {'card': fromOnlyMemory.targetId, 'whenMs': now}).code,
        'topic_quiet',
      );
      expect(actualCard(unrelated.targetId!), independent);
      expect(store.requests(), paid);
      expect(database.select('SELECT * FROM memory_initiative_spends'), spent);
    });
  }

  test('unknown and empty calls write no cards and one source keeps its three-card budget', () {
    final source = say('source', '我们慢慢聊就好。');
    final turn = begin(source);
    final before = store.archive;
    expect(call(turn, 'unknown', 'forget', {'card': 'not-supplied'}).code, 'card_not_in_turn');
    expect(call(turn, 'empty', 'remember', {'text': '  '}).code, 'content_empty');
    expect(store.cards(), isEmpty);
    expect(store.archive, before);
    final receipts = [
      for (var index = 0; index < 3; index++)
        call(turn, 'save-$index', 'remember', {'text': '记忆 $index', if (index == 1) 'keywords': <String>[]}),
    ];
    expect(receipts.every((receipt) => receipt.applied), isTrue);
    final after = store.cards();
    expect(after.singleWhere((card) => card['id'] == receipts.first.targetId)['keywords'], ['记忆 0']);
    expect(after.singleWhere((card) => card['id'] == receipts[1].targetId)['keywords'], isEmpty);
    expect(
      selectMemoryContext(
        after,
        input: '记忆 0',
        nowMs: now,
        controlRevision: store.archive['control_revision']! as int,
      ).ids,
      [receipts.first.targetId],
    );
    final repeatedTurn = begin(source);
    expect(repeatedTurn, turn);
    expect(call(repeatedTurn, 'fourth', 'remember', {'text': '第四张'}).code, 'card_limit');
    final replay = call(turn, 'save-0', 'remember', {'text': '记忆 0'});
    expect(replay.replayed, isTrue);
    expect(replay.targetId, receipts.first.targetId);
    expect(store.cards(), after);
    expect(() => call(turn, 'save-0', 'remember', {'text': '替换参数'}), throwsA(isA<DshRemoteException>()));
    final stored = jsonEncode([
      for (final row in database.select('SELECT * FROM memory_agent_calls')) {...row},
    ]);
    expect(stored, isNot(contains('记忆 0')));
    expect(stored, isNot(contains('第四张')));

    // Four independent source turns legally inherit one persistent control.
    // No individual turn writes more than its existing three-card allowance.
    store.closeAgentTurn(turn);
    final rideOneTurn = begin(say('ride-one', '我骑车常走河边路。'));
    final rideOne = call(rideOneTurn, 'remember-ride-one', 'remember', {
      'text': '我骑车常走河边路。',
      'keywords': ['骑车'],
    }).targetId!;
    expect(call(rideOneTurn, 'quiet-riding', 'quiet', {'card': rideOne, 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(rideOneTurn);
    final rideTwoTurn = begin(say('ride-two', '我骑车戴蓝色头盔。'));
    final rideTwo = call(rideTwoTurn, 'remember-ride-two', 'remember', {
      'text': '我骑车戴蓝色头盔。',
      'keywords': ['骑车'],
    }).targetId!;
    store.closeAgentTurn(rideTwoTurn);
    final rideThreeTurn = begin(say('ride-three', '我骑车用银色车灯。'));
    final rideThree = call(rideThreeTurn, 'remember-ride-three', 'remember', {
      'text': '我骑车用银色车灯。',
      'keywords': ['骑车'],
    }).targetId!;
    store.closeAgentTurn(rideThreeTurn);
    final rideFourTurn = begin(say('ride-four', '我骑车穿黄色雨衣。'));
    final rideFour = call(rideFourTurn, 'remember-ride-four', 'remember', {
      'text': '我骑车穿黄色雨衣。',
      'keywords': ['骑车'],
    }).targetId!;
    store.closeAgentTurn(rideFourTurn);
    final rideIds = [rideOne, rideTwo, rideThree, rideFour];
    final rideTopic = actualCard(rideOne)['topic_id']! as String;
    expect(rideIds.map((id) => actualCard(id)['topic_id']), everyElement(rideTopic));
    expect(rideIds.map((id) => actualCard(id)['topic_mode']), everyElement('never'));

    // The old card path is unchanged, even when every actual card is granted.
    final cardProbe = begin(say('ride-card-probe', '以后可以聊骑车了，保留这四件不同的事。'), rideIds.map(actualCard));
    final beforeCardProbe = store.cards(includeInactive: true);
    final rejectedCard = call(cardProbe, 'normal-four-cards', 'quiet', {'card': rideOne, 'mode': 'normal'});
    expect(rejectedCard.code, 'card_limit');
    expect(rejectedCard.changedCardIds, isEmpty);
    expect(store.cards(includeInactive: true), beforeCardProbe);
    store.closeAgentTurn(cardProbe);

    final spendingSource = say('ride-topic-normal', '我现在愿意恢复刚才的话题。我的书签是竹制的。我的杯垫是陶瓷的。我的笔记本是方格的。我的印章是木制的。');
    final spendingTurn = begin(spendingSource);
    final spentOne = call(spendingTurn, 'spent-one', 'remember', {'text': '我的书签是竹制的。', 'keywords': <String>[]});
    final spentTwo = call(spendingTurn, 'spent-two', 'remember', {'text': '我的杯垫是陶瓷的。', 'keywords': <String>[]});
    final spentThree = call(spendingTurn, 'spent-three', 'remember', {'text': '我的笔记本是方格的。', 'keywords': <String>[]});
    expect([spentOne, spentTwo, spentThree].every((receipt) => receipt.applied), isTrue);
    final spentIds = [spentOne.targetId!, spentTwo.targetId!, spentThree.targetId!];
    expect(
      call(spendingTurn, 'unread-riding-topic', 'quiet', {'topic': rideTopic, 'mode': 'normal'}).code,
      'topic_not_in_turn',
    );
    final topicRead = call(spendingTurn, 'read-riding-topic', 'recall', {'query': '骑车'});
    expect(topicRead.applied, isTrue);
    expect(topicRead.recallSelection!.ids, isEmpty);
    expect(topicRead.recalledControl, {
      'topic_id': rideTopic,
      'mode': 'never',
      'anchors': ['骑车'],
      'character_id': null,
    });
    final beforeTopicNormal = store.cards(includeInactive: true);
    final sourceRowsBeforeNormal = store.messages();
    final restored = call(spendingTurn, 'restore-riding-topic', 'quiet', {'topic': rideTopic, 'mode': 'normal'});
    expect(restored.applied, isTrue);
    expect(restored.targetId, rideTopic);
    expect(restored.changedCardIds, isEmpty);
    // cards() joins the topic mode. All card fields and nested proof values
    // remain unchanged; the mode observed through that join must change.
    expect(store.cards(includeInactive: true), [
      for (final row in beforeTopicNormal) {...row, if (row['topic_id'] == rideTopic) 'topic_mode': 'normal'},
    ]);
    expect(store.messages(), sourceRowsBeforeNormal);
    expect(store.topicControls(), isEmpty);
    expect(
      store.beginAgentTurn(
        messageId: spendingSource['id']! as String,
        expectedSourceRev: spendingSource['source_rev']! as int,
        shownCardRevisions: const {},
      )['changed_cards'],
      unorderedEquals(spentIds),
    );
    final oldTopicRead = call(spendingTurn, 'read-riding-topic', 'recall', {'query': '骑车'});
    expect(oldTopicRead.replayed, isTrue);
    expect(oldTopicRead.targetId, rideTopic);
    expect(oldTopicRead.recalledControl, isNull);
    final cardsAfterRestore = store.cards(includeInactive: true);
    final archiveAfterRestore = store.archive;
    final stillFourth = call(spendingTurn, 'still-fourth', 'remember', {'text': '我的印章是木制的。', 'keywords': <String>[]});
    expect(stillFourth.code, 'card_limit');
    expect(stillFourth.changedCardIds, isEmpty);
    expect(store.cards(includeInactive: true), cardsAfterRestore);
    expect(store.archive, archiveAfterRestore);
    expect(store.requests(), isEmpty, reason: 'public SDK tool transactions do not manufacture HTTP receipts');
  });

  test('forget budgets the complete R33 body closure while independent shared-proof facts survive', () {
    final original = say('original', '我住杭州，也养猫。');
    final claimed = store.nextBatch(forceTail: true, estimateTokens: (text) => text.length)!;
    final texts = ['我住杭州。', '我养猫。', '我住杭州，也养猫。', '我住杭州；也养猫。', '我住杭州\n也养猫。'];
    final proposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': claimed.id,
        'covered_message_ids': [original['id']],
        'completion': 'complete',
        'operations': [
          for (final text in texts)
            {
              'op': 'create',
              'kind': 'fact',
              'text': text,
              'keywords': ['杭州', '养猫'],
              'evidence': [
                {'message_id': original['id'], 'quote': original['text']},
              ],
            },
        ],
      }),
      claimed,
    );
    expect(store.commitExtraction(claimed, proposal), isTrue);
    final cards = store.cards();
    final home = cards.singleWhere((card) => card['text'] == '我住杭州。');
    final cat = cards.singleWhere((card) => card['text'] == '我养猫。');
    final turn = begin(say('first-request', '那条居住信息不用保留了。'), cards);
    final before = store.archive;
    expect(call(turn, 'forget-home', 'forget', {'card': home['id']}).code, 'card_limit');
    expect(store.cards(), cards);
    expect(store.archive, before);
    final overBudget = call(turn, 'forget-home-and-source', 'forget', {'card': home['id'], 'deleteChat': true});
    expect(overBudget.applied, isFalse);
    expect(overBudget.code, 'card_limit');
    expect(store.cards(), cards);
    expect(store.archive, before);
    expect(store.messages().singleWhere((row) => row['id'] == original['id'])['text'], original['text']);
    // A separate real manual deletion makes a later user turn fit the budget.
    final extra = cards.singleWhere((card) => card['text'] == '我住杭州\n也养猫。');
    store.deleteCard(id: extra['id']! as String, expectedRowRev: extra['row_rev']! as int);
    final next = begin(say('next-request', '现在忘掉居住信息。'), store.cards());
    final compounds = store.cards().where((row) => row['id'] != home['id'] && row['id'] != cat['id']).toList();
    final accepted = call(next, 'forget-home', 'forget', {
      'changes': [
        {'card': home['id'], 'forget': true},
        for (final card in compounds) {'card': card['id'], 'text': '我养猫。'},
      ],
    });
    expect(accepted.applied, isTrue);
    expect(accepted.changedCardIds, hasLength(3));
    expect(store.cards().singleWhere((row) => row['id'] == cat['id']), cat);
    expect(store.cards().every((row) => row['text'] == '我养猫。'), isTrue);
    for (final retained in store.cards()) {
      expect((retained['evidence'] as List).single, containsPair('quote', original['text']));
    }
    expect(store.messages().where((row) => row['id'] == 'original').single['text'], original['text']);
    expect(database.select('SELECT * FROM memory_deleted_messages'), isEmpty);

    // One selected raw root does not authorize another member of a derived
    // AND group merely because that composite is also explicitly removed.
    store.closeAgentTurn(next);
    final rawX = say('and-raw-x', '我住厦门。');
    final rawY = say('and-raw-y', '我收集邮票。');
    final extraction = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final extracting =
        store.beginAgentMaintenance(kind: 'extract', claimId: extraction['id']! as String)['id']! as String;
    final rootX = call(extracting, 'and-home', 'remember', {
      'text': '我住厦门。',
      'sources': [rawX['id']],
    }).targetId!;
    final independentY = call(extracting, 'and-stamps', 'remember', {
      'text': '我收集邮票。',
      'sources': [rawY['id']],
    }).targetId!;
    final composite = call(extracting, 'and-both', 'remember', {
      'text': '我住厦门，也收集邮票。',
      'sources': [rawX['id'], rawY['id']],
    }).targetId!;
    store.finishAgentMaintenance(turnId: extracting, complete: true);
    final proof = (actualCard(composite)['evidence'] as List).cast<MemoryRow>();
    expect(proof.map((row) => row['support_group']).toSet(), hasLength(1));
    expect(proof.map((row) => row['message_id']), unorderedEquals([rawX['id'], rawY['id']]));
    final unchangedY = actualCard(independentY);
    say('and-forget', '忘掉厦门住址，连原话也删，集邮的事保留。');
    final deletionClaim = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final deletionTurn = store.beginAgentMaintenance(kind: 'extract', claimId: deletionClaim['id']! as String);
    final deleting = deletionTurn['id']! as String;
    expect(deletionTurn['source_message_id'], isNull);
    store.grantAgentCards(turnId: deleting, cardRevisions: {rootX: actualCard(rootX)['row_rev']! as int});
    final shown = call(deleting, 'and-related', 'related', {'card': rootX}).relatedCards!;
    expect(shown.map((row) => row['id']), containsAll([rootX, composite]));
    final removed = call(deleting, 'and-delete-source', 'forget', {
      'card': rootX,
      'deleteChat': true,
      'changes': [
        {'card': rootX, 'forget': true},
        {'card': composite, 'forget': true},
      ],
    });
    expect(removed.applied, isTrue);
    expect(removed.changedCardIds, unorderedEquals([rootX, composite]));
    // A maintenance turn still forgets the cards, but cannot request an erase.
    expect(removed.rawEraseState, 'maintenance');
    expect(removed.pendingRawEraseId, isNull);
    expect(store.pendingRawErase(characterId: null), isNull);
    expect(_captured(store, rawX), rawX);
    final keptY = store.messages().singleWhere((row) => row['id'] == rawY['id']);
    expect(keptY['text'], rawY['text']);
    expect(keptY['source_rev'], rawY['source_rev']);
    expect(actualCard(independentY), unchangedY);
    expect(store.isAgentTurnCurrent(deleting), isTrue);
    store.finishAgentMaintenance(turnId: deleting, complete: true);

    // Losing Y_X's only proof is not permission to treat its body as another
    // raw root. A same-body Y_Z can exist independently before any merge.
    final rawZ = say('duplicate-raw-z', '我喜欢铜管乐。');
    final zTurn = begin(rawZ);
    final fromZ = call(zTurn, 'duplicate-z', 'remember', {'text': '我喜欢铜管乐。'}).targetId!;
    store.closeAgentTurn(zTurn);
    final sharedRaw = say('duplicate-raw-x', '我住梧桐路，也喜欢铜管乐。');
    final sharedTurn = begin(sharedRaw);
    final primary = call(sharedTurn, 'duplicate-home', 'remember', {'text': '我住梧桐路。'}).targetId!;
    final fromX = call(sharedTurn, 'duplicate-x', 'remember', {'text': '我喜欢铜管乐。'}).targetId!;
    store.closeAgentTurn(sharedTurn);
    final duplicateTurn = begin(say('duplicate-forget', '忘掉梧桐路住址和那句原话，独立说过的爱好保留。'), [actualCard(primary)]);
    expect(
      call(duplicateTurn, 'duplicate-root-related', 'related', {'card': primary}).relatedCards!.map((row) => row['id']),
      contains(fromX),
    );
    expect(
      call(duplicateTurn, 'duplicate-fact-related', 'related', {'card': fromX}).relatedCards!.map((row) => row['id']),
      contains(fromZ),
    );
    final retainedBefore = actualCard(fromZ);
    final isolated = call(duplicateTurn, 'duplicate-delete', 'forget', {
      'card': primary,
      'deleteChat': true,
      'changes': [
        {'card': fromX, 'forget': true},
        {'card': primary, 'forget': true},
        {'card': fromZ, 'text': '我喜欢铜管乐。'},
      ],
    });
    expect(isolated.applied, isTrue);
    expect(isolated.targetId, primary);
    expect(isolated.changedCardIds, unorderedEquals([primary, fromX, fromZ]));
    expect(isolated.rawEraseState, 'pending');
    final isolatedId = isolated.pendingRawEraseId!;
    final isolatedView = store.pendingRawErase(characterId: null)!;
    expect(isolatedView.id, isolatedId);
    expect(isolatedView.previewText, sharedRaw['text']);
    expect(isolatedView.rawMessageCount, 1);
    expect(isolatedView.expiresAtUtcMs, isNull);
    expect(store.confirmRawErase(isolatedId, characterId: null).state, 'deferred');
    expect(_captured(store, sharedRaw), sharedRaw);
    expect(call(duplicateTurn, 'ignored-while-pending', 'unknown_memory_tool', const {}).code, 'unknown_memory_tool');
    expect(store.pendingRawErase(characterId: null)!.id, isolatedId);
    expect(store.confirmRawErase('another-id', characterId: null).state, 'not_found');
    expect(store.pendingRawErase(characterId: null)!.id, isolatedId);
    final beforeIndependentPin = store.archive;
    store.setPinned(id: independentY, expectedRowRev: actualCard(independentY)['row_rev']! as int, pinned: true);
    expect(store.archive['memory_revision'], (beforeIndependentPin['memory_revision']! as int) + 1);
    expect(store.archive['control_revision'], beforeIndependentPin['control_revision']);
    expect(store.pendingRawErase(characterId: null)!.id, isolatedId);
    store.closeAgentTurn(duplicateTurn);
    expect(store.markRawEraseOffered(isolatedId, characterId: null).state, 'awaiting');
    final cutoff = store.archive['history_after_seq'];
    say('while-choosing', '这段等待期间的新聊天仍应保留。');
    final isolatedConfirmed = store.confirmRawErase(isolatedId, characterId: null);
    expect(isolatedConfirmed.state, 'confirmed');
    expect(isolatedConfirmed.changedCardIds, isEmpty);
    expect(store.archive['history_after_seq'], cutoff);
    expect(store.messages().any((row) => row['id'] == sharedRaw['id']), isFalse);
    expect(store.cards().where((row) => row['id'] == primary || row['id'] == fromX), isEmpty);
    final independentRaw = store.messages().singleWhere((row) => row['id'] == rawZ['id']);
    expect(independentRaw['text'], rawZ['text']);
    expect(independentRaw['source_rev'], rawZ['source_rev']);
    final retainedAfter = actualCard(fromZ);
    expect(retainedAfter['text'], retainedBefore['text']);
    expect(retainedAfter['row_rev'], (retainedBefore['row_rev']! as int) + 1);
    expect(retainedAfter['current_basis_seq'], retainedBefore['current_basis_seq']);
    expect(retainedAfter['source_at_ms'], retainedBefore['source_at_ms']);
    expect((retainedAfter['evidence'] as List).single, containsPair('message_id', rawZ['id']));
    final afterConfirmed = store.archive;
    expect(store.confirmRawErase(isolatedId, characterId: null).changedCardIds, isEmpty);
    expect(store.declineRawErase(isolatedId, characterId: null).state, 'confirmed');
    expect(store.invalidateRawErase(), isFalse);
    expect(store.archive, afterConfirmed);
    store.closeAgentTurn(duplicateTurn);

    // A legacy extraction can add a literal dependency without bumping control.
    // Its real new source shares no proof ID with the frozen original.
    final laterRaw = say('later-raw', '我收藏青石灯。');
    final laterCreating = begin(laterRaw);
    final laterCard = call(laterCreating, 'later-card', 'remember', {'text': '我收藏青石灯。'}).targetId!;
    store.closeAgentTurn(laterCreating);
    final laterDeleting = begin(say('later-request', '忘掉青石灯，原话也不留。'), [actualCard(laterCard)]);
    final laterPending = call(laterDeleting, 'later-delete', 'forget', {'card': laterCard, 'deleteChat': true});
    final laterId = laterPending.pendingRawEraseId!;
    store.closeAgentTurn(laterDeleting);
    expect(store.markRawEraseOffered(laterId, characterId: null).state, 'awaiting');
    final beforeLateExtraction = store.archive;
    final lateSource = say('later-proof', '我收藏青石灯，也种兰花。');
    final lateBatch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.length)!;
    final lateProposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': lateBatch.id,
        'covered_message_ids': [lateSource['id']],
        'completion': 'complete',
        'operations': [
          {
            'op': 'create',
            'kind': 'fact',
            'text': '我收藏青石灯，也种兰花。',
            'keywords': ['青石灯'],
            'evidence': [
              {'message_id': lateSource['id'], 'quote': lateSource['text']},
            ],
          },
        ],
      }),
      lateBatch,
    );
    expect(store.commitExtraction(lateBatch, lateProposal), isTrue);
    expect(store.archive['control_revision'], beforeLateExtraction['control_revision']);
    expect(store.archive['memory_revision'], greaterThan(beforeLateExtraction['memory_revision']! as int));
    final afterLateExtraction = store.cards();
    expect(store.confirmRawErase(laterId, characterId: null).state, 'invalidated');
    expect(store.cards(), afterLateExtraction);
    expect(_captured(store, laterRaw), laterRaw);
    expect(store.pendingRawErase(characterId: null), isNull);
  });

  test(
    'ADD49 current maintenance cannot replace a manual correction with older evidence or partly apply its group',
    () {
      now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
      final old = say('old-interview', '面试安排在周四。');
      final initial = begin(old);
      final interview = call(initial, 'first-interview', 'remember', {'text': '面试安排在周四。'}).targetId!;
      store.closeAgentTurn(initial);
      final beforeEdit = actualCard(interview);
      now += 3600000;
      store.saveManual(
        CompanionMemory(id: interview, text: '面试安排在周五。'),
        expectedRowRev: beforeEdit['row_rev']! as int,
        currentValueChange: true,
        realityKnown: true,
      );
      final corrected = actualCard(interview);
      expect(corrected['current_basis_seq'], greaterThan(old['first_seq']! as int));
      now += 3600000;
      final fresh = say('new-interview', '面试又改成周六了；我也开始学提琴。');
      final later = begin(fresh);
      final violin = call(later, 'first-violin', 'remember', {'text': '我开始学提琴。'}).targetId!;
      store.closeAgentTurn(later);
      final independent = actualCard(violin);
      expect(fresh['first_seq'], greaterThan(corrected['current_basis_seq']! as int));
      now += 86400000;
      final claim = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      final turn = store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String);
      final turnId = turn['id']! as String;
      grantMaintenance(turn);
      expect(
        store.isAgentTurnCurrent(turnId),
        isTrue,
        reason: 'this is a new claim after the manual control, not a stale run',
      );
      final control = store.archive['control_revision'];
      expect(
        call(turnId, 'old-again', 'revise', {'card': interview, 'source': old['id'], 'text': '面试安排在周四。'}).code,
        'older_than_current',
      );
      expect(actualCard(interview), corrected);
      expect(
        call(turnId, 'group-old', 'revise', {
          'changes': [
            {'card': violin, 'source': fresh['id'], 'text': '我在学提琴。'},
            {'card': interview, 'source': old['id'], 'text': '面试安排在周四。'},
          ],
        }).code,
        'older_than_current',
      );
      expect(actualCard(violin), independent, reason: 'an earlier valid member cannot survive a rejected group');
      expect(actualCard(interview), corrected);
      expect(store.archive['control_revision'], control);
      expect(store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String)['changed_cards'], isEmpty);
      final accepted = call(turnId, 'group-new', 'revise', {
        'changes': [
          {'card': violin, 'source': fresh['id'], 'text': '我在学提琴。'},
          {'card': interview, 'source': fresh['id'], 'text': '面试安排在周六。'},
        ],
      });
      expect(accepted.applied, isTrue, reason: 'equal-basis rewording and genuinely newer evidence remain legal');
      expect(accepted.changedCardIds, unorderedEquals([violin, interview]));
      expect(actualCard(violin)['current_basis_seq'], independent['current_basis_seq']);
      expect(actualCard(interview)['current_basis_seq'], fresh['first_seq']);
      expect(actualCard(interview)['text'], '面试安排在周六。');
      store.finishAgentMaintenance(turnId: turnId, complete: true);
      reopen();
      expect(actualCard(interview)['text'], '面试安排在周六。');
      expect(store.messages().singleWhere((row) => row['id'] == old['id'])['text'], old['text']);
    },
  );

  test('ADD53 grouped corrections use the planned parent basis without accepting genuinely older evidence', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    final old = say('group-parent-old', '面试安排在周四。');
    final creating = begin(old);
    final parent = call(creating, 'parent', 'remember', {'text': '面试安排在周四。'}).targetId!;
    store.closeAgentTurn(creating);
    now += 3600000;
    final detail = say('group-child-old', '面试前要把材料准备好。');
    final linking = begin(detail, [actualCard(parent)]);
    final child = call(linking, 'child', 'remember', {
      'text': '周四面试前要准备好材料。',
      'references': [parent],
    }).targetId!;
    store.closeAgentTurn(linking);
    final parentBefore = actualCard(parent);
    final childBefore = actualCard(child);
    expect(childBefore['current_basis_seq'], greaterThan(parentBefore['current_basis_seq']! as int));
    expect(parentBefore['source_at_ms'], old['said_at_utc']);
    expect(childBefore['source_at_ms'], detail['said_at_utc']);
    now += 3600000;
    final fresh = say('group-parent-new', '面试改到周五，材料也按周五安排。');
    expect(fresh['first_seq'], greaterThan(childBefore['current_basis_seq']! as int));
    now += 86400000;
    final claim = store.nextAgentMaintenance(
      kind: 'organize',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
    )!;
    final turn = store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String);
    final turnId = turn['id']! as String;
    grantMaintenance(turn);
    expect((turn['sources'] as List).map((row) => (row as MemoryRow)['id']), containsAll([old['id'], fresh['id']]));
    expect((turn['cards'] as List).map((row) => (row as MemoryRow)['id']), containsAll([parent, child]));
    final archive = store.archive;
    final rejected = call(turnId, 'old-group', 'revise', {
      'changes': [
        {
          'card': child,
          'text': '周四面试前要准备好材料。',
          'sources': <String>[],
          'references': [parent],
        },
        {'card': parent, 'source': old['id'], 'text': '面试还是安排在周四。'},
      ],
    });
    expect(rejected.code, 'older_than_current');
    expect(rejected.applied, isFalse);
    expect(actualCard(parent), parentBefore);
    expect(actualCard(child), childBefore);
    expect(store.archive, archive);
    expect(store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String)['changed_cards'], isEmpty);
    final accepted = call(turnId, 'fresh-group', 'revise', {
      'changes': [
        {
          'card': child,
          'text': '周五面试前要准备好材料。',
          'sources': <String>[],
          'references': [parent],
        },
        {'card': parent, 'source': fresh['id'], 'text': '面试安排在周五。'},
      ],
    });
    expect(accepted.applied, isTrue, reason: 'the child precedes its freshly revised parent in the same plan');
    expect(accepted.changedCardIds, unorderedEquals([parent, child]));
    final parentAfter = actualCard(parent);
    final childAfter = actualCard(child);
    expect(parentAfter['text'], '面试安排在周五。');
    expect(childAfter['text'], '周五面试前要准备好材料。');
    expect(parentAfter['row_rev'], (parentBefore['row_rev']! as int) + 1);
    expect(childAfter['row_rev'], (childBefore['row_rev']! as int) + 1);
    expect(parentAfter['current_basis_seq'], fresh['first_seq']);
    expect(childAfter['current_basis_seq'], fresh['first_seq']);
    expect(parentAfter['source_at_ms'], fresh['said_at_utc']);
    expect(childAfter['source_at_ms'], fresh['said_at_utc']);
    expect(
      database.select('SELECT parent_card_id,parent_row_rev FROM memory_card_references WHERE card_id=?', [child]),
      [
        {'parent_card_id': parent, 'parent_row_rev': parentAfter['row_rev']},
      ],
    );
    expect(store.memoryRetrievalCandidates(characterId: null).map((row) => row['id']), containsAll([parent, child]));
    expect(store.archive['control_revision'], (archive['control_revision']! as int) + 1);
    store.finishAgentMaintenance(turnId: turnId, complete: true);
    reopen();
    expect(actualCard(parent)['current_basis_seq'], fresh['first_seq']);
    expect(actualCard(child)['current_basis_seq'], fresh['first_seq']);
    expect(actualCard(parent)['source_at_ms'], fresh['said_at_utc']);
    expect(actualCard(child)['source_at_ms'], fresh['said_at_utc']);
    expect(store.memoryRetrievalCandidates(characterId: null).map((row) => row['id']), containsAll([parent, child]));
  });

  test('an external control invalidates a turn after recall grants only its actual returned IDs', () {
    final card = seed('我喜欢蓝色', keywords: ['蓝色']);
    final other = seed('另一个独立事实');
    final source = say('source', '说说蓝色。');
    final turn = begin(source);
    final read = call(turn, 'read', 'recall', {'query': '蓝色'});
    expect(read.applied, isTrue);
    expect(read.recallSelection!.ids, [card['id']]);
    expect(call(turn, 'unseen', 'revise', {'card': other['id'], 'text': '未授予的改写'}).code, 'card_not_in_turn');
    store.grantAgentCards(turnId: turn, cardRevisions: {card['id']! as String: card['row_rev']! as int});
    store.saveManual(
      CompanionMemory(id: card['id']! as String, text: '我喜欢橙色'),
      expectedRowRev: card['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(call(turn, 'late', 'revise', {'card': card['id'], 'text': '旧请求的绿色'}).code, 'control_changed');
    expect(store.cards().singleWhere((row) => row['id'] == card['id'])['text'], '我喜欢橙色');

    final raw = say('controlled-raw', '我收藏石版画。');
    final making = begin(raw);
    final rawCard = call(making, 'controlled-card', 'remember', {'text': '我收藏石版画。'}).targetId!;
    store.closeAgentTurn(making);
    final removing = begin(say('controlled-request', '忘记石版画，连原话也删。'), [actualCard(rawCard)]);
    final requested = call(removing, 'controlled-delete', 'forget', {'card': rawCard, 'deleteChat': true});
    final rawEraseId = requested.pendingRawEraseId!;
    store.closeAgentTurn(removing);
    expect(store.markRawEraseOffered(rawEraseId, characterId: null).state, 'awaiting');
    final changedCard = actualCard(card['id']! as String);
    store.saveManual(
      CompanionMemory(id: card['id']! as String, text: '我喜欢黑色'),
      expectedRowRev: changedCard['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    final afterExternalControl = store.archive;
    expect(store.confirmRawErase(rawEraseId, characterId: null).state, 'invalidated');
    expect(store.archive, afterExternalControl);
    expect(_captured(store, raw), raw);

    final expiringRaw = say('expiring-raw', '我喜欢海盐饼干。');
    final expiringMaking = begin(expiringRaw);
    final expiringCard = call(expiringMaking, 'expiring-card', 'remember', {'text': '我喜欢海盐饼干。'}).targetId!;
    store.closeAgentTurn(expiringMaking);
    final expiringTurn = begin(say('expiring-request', '海盐饼干的记忆连原话也删。'), [actualCard(expiringCard)]);
    final expiring = call(expiringTurn, 'expiring-delete', 'forget', {'card': expiringCard, 'deleteChat': true});
    final expiringId = expiring.pendingRawEraseId!;
    expect(store.markRawEraseOffered(expiringId, characterId: null).state, 'awaiting');
    final beforeExpiry = store.archive;
    now += const Duration(minutes: 5).inMilliseconds;
    expect(store.confirmRawErase(expiringId, characterId: null).state, 'expired');
    expect(store.markRawEraseOffered(expiringId, characterId: null).state, 'expired');
    expect(store.archive, beforeExpiry);
    expect(_captured(store, expiringRaw), expiringRaw);
    expect(store.pendingRawErase(characterId: null), isNull);
    store.closeAgentTurn(expiringTurn);
  });

  test('structured ask-later reaches real reserve and once-only presentation without a raw invitation regex', () {
    store.initializeInitiative({
      'v': 2,
      'lastGreetingAtMs': null,
      'inviteAtMs': <int>[],
      'signalAtMs': <int>[],
      'declinedUntilMs': 0,
      'night': null,
    });
    final card = seed('这次修琴的情况');
    final source = say('source', '过一阵子再聊这个吧。');
    final turn = begin(source, [card]);
    final scheduled = call(turn, 'later', 'ask_later', {'card': card['id'], 'whenMs': now + 60000});
    expect(scheduled.applied, isTrue);
    expect(store.nextFollowup(nowMs: now), isNull);
    now += 60000;
    final initial = store.nextFollowup(nowMs: now)!;
    expect(initial['id'], scheduled.targetId);
    expect(initial['agent_origin'], 1);
    expect(initial['invitation'], source['text']);
    expect(store.isFollowupCurrent(initial, nowMs: now), isTrue);
    expect(call(turn, 'another-card', 'remember', {'text': '用户喜欢轻松聊天'}).applied, isTrue);
    expect(store.isFollowupCurrent(initial, nowMs: now), isFalse);
    final current = store.nextFollowup(nowMs: now)!;
    expect(current['id'], initial['id']);
    final spend = store.reserveInitiative(
      kind: 'followup',
      nowMs: now,
      maxPerDay: 2,
      gapMs: 0,
      followupId: current['id']! as String,
    )!;
    store.settleInitiative(spend, outcome: 'shown');
    expect(store.nextFollowup(nowMs: now), isNull);
    reopen();
    expect(store.followups().single['state'], 'asked');
    expect(store.nextFollowup(nowMs: now), isNull);
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    expect(store.followups(), isEmpty);
  });

  test('quiet and cancel retire actual pending followups without changing an unrelated card', () {
    final first = seed('项目进度');
    final other = seed('喜欢喝茶');
    final turn = begin(say('source', '这几件事都聊过了。'), [first, other]);
    expect(call(turn, 'schedule', 'ask_later', {'card': first['id'], 'whenMs': now}).applied, isTrue);
    expect(store.nextFollowup(nowMs: now), isNotNull);
    final pending = store.nextFollowup(nowMs: now)!;
    final cardBeforeNormal = actualCard(first['id']! as String);
    final paid = store.requests();
    expect(call(turn, 'already-normal', 'quiet', {'card': first['id'], 'mode': 'normal'}).applied, isTrue);
    final rebound = store.nextFollowup(nowMs: now)!;
    expect(store.isFollowupCurrent(pending, nowMs: now), isFalse);
    expect(store.isFollowupCurrent(rebound, nowMs: now), isTrue);
    for (final field in const [
      'id',
      'state',
      'card_id',
      'card_rev',
      'message_id',
      'source_rev',
      'invitation',
      'opens_at_ms',
      'expires_at_ms',
      'presented_at_ms',
    ]) {
      expect(rebound[field], pending[field]);
    }
    expect(actualCard(first['id']! as String), cardBeforeNormal);
    expect(store.requests(), paid);
    expect(call(turn, 'quiet', 'quiet', {'card': first['id'], 'mode': 'less'}).applied, isTrue);
    expect(store.nextFollowup(nowMs: now), isNull);
    expect(store.cards().singleWhere((card) => card['id'] == other['id']), other);
    expect(call(turn, 'quiet-topic', 'ask_later', {'card': first['id'], 'whenMs': now}).code, 'topic_quiet');
    expect(call(turn, 'other-later', 'ask_later', {'card': other['id'], 'whenMs': now}).applied, isTrue);
    expect(call(turn, 'cancel', 'cancel', {'card': other['id']}).applied, isTrue);
    expect(store.nextFollowup(nowMs: now), isNull);
    expect(store.cards().singleWhere((card) => card['id'] == other['id'])['plan_state'], 'cancelled');
  });

  test('cold reopen keeps identity receipts but never creates a fresh execution allowance', () {
    final source = say('source', '这是这次实际发送的原话。');
    final turn = begin(source);
    final remembered = call(turn, 'save', 'remember', {'text': '仅存一次的事实'});
    final pending = store.reserveAgentTaskCall(
      turnId: turn,
      callId: 'task',
      toolName: 'reminder',
      input: {'text': '待定'},
    );
    expect(pending.state, 'pending');
    reopen();
    final restored = store.beginAgentTurn(messageId: 'source', expectedSourceRev: 1, shownCardRevisions: const {});
    expect(restored['id'], turn);
    expect(restored['closed'], 1);
    expect(store.agentToolCall(turnId: turn, callId: 'save')!.targetId, remembered.targetId);
    expect(store.agentToolCall(turnId: turn, callId: 'task')!.state, 'pending');
    expect(call(turn, 'new-model-call', 'remember', {'text': '不可重规划'}).code, 'turn_closed');
    expect(store.cards(), hasLength(1));
    expect(store.taskForCommand('source', pending.itemNo), isNull);

    final keptRaw = say('declined-raw', '我喜欢叶片标本。');
    final keptTurn = begin(keptRaw);
    final keptCard = call(keptTurn, 'kept-card', 'remember', {'text': '我喜欢叶片标本。'}).targetId!;
    store.closeAgentTurn(keptTurn);
    final declining = begin(say('decline-request', '这条标本记忆连原话也删。'), [actualCard(keptCard)]);
    final offered = call(declining, 'decline-delete', 'forget', {'card': keptCard, 'deleteChat': true});
    final declinedId = offered.pendingRawEraseId!;
    final beforeDecline = store.archive, beforeDeclineMessages = store.messages(), beforeDeclineCards = store.cards();
    expect(store.declineRawErase(declinedId, characterId: null).state, 'declined');
    expect(store.confirmRawErase(declinedId, characterId: null).state, 'declined');
    expect(store.archive, beforeDecline);
    expect(store.messages(), beforeDeclineMessages);
    expect(store.cards(), beforeDeclineCards);
    expect(_captured(store, keptRaw), keptRaw);
    store.closeAgentTurn(declining);

    final coldRaw = say('cold-raw', '我保存蓝色贝壳。');
    final coldMaking = begin(coldRaw);
    final coldCard = call(coldMaking, 'cold-card', 'remember', {'text': '我保存蓝色贝壳。'}).targetId!;
    store.closeAgentTurn(coldMaking);
    final coldDeleting = begin(say('cold-request', '忘掉蓝色贝壳，原话也不要。'), [actualCard(coldCard)]);
    final coldInput = <String, Object?>{'card': coldCard, 'deleteChat': true};
    final coldPending = call(coldDeleting, 'cold-delete', 'forget', coldInput);
    final coldId = coldPending.pendingRawEraseId!;
    expect(store.confirmRawErase(declinedId, characterId: null).state, 'not_found');
    expect(store.pendingRawErase(characterId: null)!.id, coldId);
    expect(store.markRawEraseOffered(coldId, characterId: null).state, 'awaiting');
    final deadline = store.pendingRawErase(characterId: null)!.expiresAtUtcMs!;
    expect(deadline, now + const Duration(minutes: 5).inMilliseconds);
    now += 60000;
    expect(store.markRawEraseOffered(coldId, characterId: null).state, 'awaiting');
    expect(store.pendingRawErase(characterId: null)!.expiresAtUtcMs, deadline);
    store.closeAgentTurn(coldDeleting);
    reopen();
    expect(store.pendingRawErase(characterId: null), isNull);
    expect(store.confirmRawErase(coldId, characterId: null).state, 'not_found');
    final coldReplay = call(coldDeleting, 'cold-delete', 'forget', coldInput);
    expect(coldReplay.replayed, isTrue);
    expect(coldReplay.rawEraseState, 'unavailable');
    expect(coldReplay.pendingRawEraseId, isNull);
    expect(_captured(store, coldRaw), coldRaw);
    expect(call(coldDeleting, 'cold-new-delete', 'forget', coldInput).code, 'turn_closed');
  });

  test('durable ordinals share original task fingerprints and late accepted receipts can drain', () {
    final source = say('source', '请提醒喝水，也记下蓝色。');
    const spec = CompanionReminderSpec(text: '喝水', waitReason: 'date_missing');
    final original = store.createReminderFromMessage(
      messageId: 'source',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      executorId: 'phone',
      reminder: spec,
    );
    final turn = begin(source);
    final memory = call(turn, 'remember', 'remember', {'text': '蓝色'});
    final callInput = <String, Object?>{'text': '喝水'};
    final task = store.reserveAgentTaskCall(turnId: turn, callId: 'remind', toolName: 'reminder', input: callInput);
    expect(memory.itemNo, 1);
    expect(task.itemNo, 2);
    expect(
      store.reserveAgentTaskCall(turnId: turn, callId: 'remind', toolName: 'reminder', input: callInput).itemNo,
      2,
    );
    final actual = store.createReminderFromMessage(
      messageId: 'source',
      expectedSourceRev: 1,
      itemNo: task.itemNo,
      roomMode: 'light',
      executorId: 'phone',
      reminder: spec,
    );
    store.closeAgentTurn(turn);
    final settled = store.finishAgentTaskCall(turnId: turn, callId: 'remind', taskId: actual['task_id']! as String);
    expect(settled.state, 'accepted');
    expect(settled.taskId, actual['task_id']);
    expect(settled.taskId, isNot(original['task_id']));
    expect(store.taskForCommand('source', 2), actual);
    expect(
      store.finishAgentTaskCall(turnId: turn, callId: 'remind', taskId: actual['task_id']! as String).replayed,
      isTrue,
    );
  });

  test('a failed SQL commit rolls back the effect, call receipt and turn budget together', () {
    final turn = begin(say('source', '一次真实原话。'));
    database.execute(
      "CREATE TRIGGER fail_agent BEFORE INSERT ON memory_cards BEGIN SELECT RAISE(ABORT, 'fixture'); END",
    );
    expect(() => call(turn, 'save', 'remember', {'text': '必须原子保存'}), throwsA(isA<SqliteException>()));
    expect(store.cards(), isEmpty);
    expect(store.agentToolCall(turnId: turn, callId: 'save'), isNull);
    expect(database.select('SELECT changed_cards FROM memory_agent_turns').single['changed_cards'], '[]');
    database.execute('DROP TRIGGER fail_agent');
    expect(call(turn, 'save', 'remember', {'text': '必须原子保存'}).applied, isTrue);
  });

  test('a real schema14 fixture upgrades without changing existing cards or archive identity', () {
    final card = seed('原来就有的手记');
    say('source', '原来的聊天');
    final before = store.archive;
    restoreOldMemorySchema(database, 14);
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 17);
    expect(store.cards(), [card]);
    expect(store.archive, before);
    expect(database.select('SELECT * FROM memory_agent_turns'), isEmpty);
    expect(database.select('SELECT * FROM memory_agent_calls'), isEmpty);
  });

  test('a complete forget group retains independent clauses and rejects a bad later rewrite before writing', () {
    final original = say('original-group', '我住杭州，也喜欢红茶。');
    final creating = begin(original);
    final home = call(creating, 'home', 'remember', {'text': '我住杭州。'}).targetId!;
    final tea = call(creating, 'tea', 'remember', {
      'text': '我喜欢红茶。',
      'keywords': ['红茶', '饮品'],
    }).targetId!;
    final combined = call(creating, 'both', 'remember', {
      'text': '我住杭州，也喜欢红茶。',
      'keywords': ['我住杭州，也喜欢红茶。', '红茶'],
    }).targetId!;
    store.closeAgentTurn(creating);
    final turn = begin(say('forget-address', '住址不要保留，红茶那部分留着。'), [actualCard(home)]);
    final related = call(turn, 'related', 'related', {'card': home});
    expect(related.relatedCards!.map((row) => row['id']), containsAll([home, tea, combined]));
    final before = store.cards();
    final archive = store.archive;
    expect(
      call(turn, 'bad-tail', 'forget', {
        'changes': [
          {'card': home, 'forget': true},
          {'card': combined, 'text': '   '},
        ],
      }).code,
      'content_empty',
    );
    expect(store.cards(), before);
    expect(store.archive, archive);
    final originalMessages = store.messages();
    final badRawTail = call(turn, 'bad-raw-tail', 'forget', {
      'card': home,
      'deleteChat': true,
      'changes': [
        {'card': home, 'forget': true},
        {'card': combined, 'text': '   '},
      ],
    });
    expect(badRawTail.applied, isFalse);
    expect(badRawTail.code, 'content_empty');
    expect(store.cards(), before);
    expect(store.archive, archive);
    expect(store.messages(), originalMessages);
    expect(
      store.beginAgentTurn(
        messageId: 'forget-address',
        expectedSourceRev: 1,
        shownCardRevisions: const {},
      )['changed_cards'],
      isEmpty,
    );
    final applied = call(turn, 'retain-tea', 'forget', {
      'changes': [
        {'card': home, 'forget': true},
        {'card': combined, 'text': '我喜欢红茶。'},
      ],
    });
    expect(applied.applied, isTrue);
    expect(applied.changedCardIds, unorderedEquals([home, combined]));
    expect(store.cards().map((row) => row['id']), unorderedEquals([tea, combined]));
    expect(actualCard(tea), before.singleWhere((row) => row['id'] == tea));
    expect(actualCard(combined)['keywords'], ['红茶']);
    final retainedProof = (actualCard(combined)['evidence'] as List).cast<MemoryRow>();
    expect(retainedProof.single['message_id'], original['id']);
    expect(retainedProof.single['quote'], original['text']);
    expect(retainedProof.any((row) => row['message_id'] == 'forget-address'), isFalse);
    expect(store.messages().singleWhere((row) => row['id'] == original['id'])['text'], original['text']);
    expect(store.archive['control_revision'], (archive['control_revision']! as int) + 1);

    // Keep this original default-forget group as the independent control.
    // Public remember/merge/saveManual calls create the raw-linked survivors;
    // neither their proof groups nor their manual flag is inserted by SQL.
    store.closeAgentTurn(turn);
    final independentCards = store.cards();
    final independentSource = store.messages().singleWhere((row) => row['id'] == original['id']);
    final rawZ = say('raw-or-z', '我喜欢铜管乐。');
    final zTurn = begin(rawZ);
    final alternative = call(zTurn, 'or-z', 'remember', {
      'text': '我喜欢铜管乐。',
      'keywords': ['铜管乐'],
    }).targetId!;
    store.closeAgentTurn(zTurn);
    now += 60000;
    final rawX = say('raw-or-x', '我住厦门，也喜欢铜管乐和模型火车。');
    final xTurn = begin(rawX);
    final rawRoot = call(xTurn, 'raw-home', 'remember', {'text': '我住厦门。'}).targetId!;
    final duplicate = call(xTurn, 'or-x', 'remember', {
      'text': '我喜欢铜管乐。',
      'keywords': ['铜管乐'],
    }).targetId!;
    final manualProof = call(xTurn, 'manual-proof', 'remember', {'text': '我喜欢模型火车。'}).targetId!;
    final currentCards = store.cards(), currentMessages = store.messages(), currentArchive = store.archive;
    final currentRefused = call(xTurn, 'raw-current-source', 'forget', {'card': rawRoot, 'deleteChat': true});
    expect(currentRefused.applied, isFalse);
    expect(currentRefused.code, 'current_source');
    expect(store.cards(), currentCards);
    expect(store.messages(), currentMessages);
    expect(store.archive, currentArchive);
    store.closeAgentTurn(xTurn);
    final mergeOr = begin(say('merge-or', '铜管乐两条说的是同一件事。'), [actualCard(alternative), actualCard(duplicate)]);
    expect(
      call(mergeOr, 'merge-or', 'merge', {
        'card': alternative,
        'from': [duplicate],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(mergeOr);
    now += 60000;
    final manual = seed('我喜欢模型火车。', keywords: ['模型火车']);
    final manualId = manual['id']! as String;
    final mergeManual = begin(say('merge-manual', '模型火车这两条也相同。'), [actualCard(manualId), actualCard(manualProof)]);
    expect(
      call(mergeManual, 'merge-manual', 'merge', {
        'card': manualId,
        'from': [manualProof],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(mergeManual);
    final orBefore = actualCard(alternative);
    final manualBefore = actualCard(manualId);
    final alternatives = (orBefore['evidence'] as List).cast<MemoryRow>();
    expect(alternatives.map((row) => row['support_group']).toSet(), hasLength(2));
    expect(alternatives.map((row) => row['message_id']), unorderedEquals([rawZ['id'], rawX['id']]));
    expect(manualBefore['manual'], isTrue);
    expect((manualBefore['evidence'] as List).single, containsPair('message_id', rawX['id']));
    final request = store.reserveRequest(
      category: 'chat',
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 100,
      outputTokens: 800,
    )!;
    observed(request);
    final paid = store.requests();
    final deleting = begin(say('raw-forget', '忘掉厦门住址，连原话也删。'), [actualCard(rawRoot)]);
    final rawRelated = call(deleting, 'raw-related', 'related', {'card': rawRoot}).relatedCards!;
    expect(rawRelated.map((row) => row['id']), containsAll([rawRoot, alternative, manualId]));
    final rawRemoved = call(deleting, 'raw-forget', 'forget', {'card': rawRoot, 'deleteChat': true});
    expect(rawRemoved.applied, isTrue);
    expect(rawRemoved.changedCardIds, [rawRoot]);
    expect(rawRemoved.rawEraseState, 'pending');
    final rawEraseId = rawRemoved.pendingRawEraseId!;
    expect(_captured(store, rawX), rawX);
    expect(actualCard(alternative), orBefore);
    expect(actualCard(manualId), manualBefore);
    expect(store.requests(), paid);
    store.closeAgentTurn(deleting);
    expect(store.markRawEraseOffered(rawEraseId, characterId: null).state, 'awaiting');
    final rawConfirmed = store.confirmRawErase(rawEraseId, characterId: null);
    expect(rawConfirmed.state, 'confirmed');
    expect(rawConfirmed.changedCardIds, unorderedEquals([alternative, manualId]));
    expect(store.messages().any((row) => row['id'] == rawX['id']), isFalse);
    final keptZ = store.messages().singleWhere((row) => row['id'] == rawZ['id']);
    expect(keptZ['text'], rawZ['text']);
    expect(keptZ['source_rev'], rawZ['source_rev']);
    final keptOriginal = store.messages().singleWhere((row) => row['id'] == original['id']);
    expect(keptOriginal['text'], independentSource['text']);
    expect(keptOriginal['source_rev'], independentSource['source_rev']);
    for (final card in independentCards) {
      expect(actualCard(card['id']! as String), card);
    }
    final orAfter = actualCard(alternative);
    expect(orAfter['row_rev'], (orBefore['row_rev']! as int) + 1);
    expect(orAfter['manual'], isFalse);
    expect(orAfter['text'], orBefore['text']);
    expect(orAfter['current_basis_seq'], rawZ['first_seq']);
    expect(orAfter['source_at_ms'], rawZ['said_at_utc']);
    expect((orAfter['evidence'] as List).single, containsPair('message_id', rawZ['id']));
    final manualAfter = actualCard(manualId);
    expect(manualAfter['row_rev'], (manualBefore['row_rev']! as int) + 1);
    expect(manualAfter['manual'], isTrue);
    expect(manualAfter['text'], manualBefore['text']);
    expect(manualAfter['current_basis_seq'], manualBefore['current_basis_seq']);
    expect(manualAfter['source_at_ms'], manualBefore['source_at_ms']);
    expect(manualAfter['evidence'], isEmpty);
    expect(store.requests(), paid);
    expect(store.requests().single['sent_at_ms'], isNotNull);
    expect(store.requests().single['state'], 'finished');
    expect(store.requests().single['terminal'], 'complete');
    expect(store.requests().single['output_tokens'], 10);
    expect(
      () => say('raw-or-x', '我住厦门，也喜欢铜管乐和模型火车。'),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/deleted-source')),
    );
    store.closeAgentTurn(deleting);

    // A retained OR parent loses its newer basis. A child with an independent
    // direct proof must see that planned basis, not the parent's old row.
    now += 60000;
    final rawS = say('raw-ref-s', '铜管乐是我的爱好。');
    now += 60000;
    final rawK = say('raw-ref-k', '我的电话尾号是四二六一，我仍喜欢铜管乐。');
    final kTurn = begin(rawK);
    final refRoot = call(kTurn, 'ref-root', 'remember', {'text': '我的电话尾号是四二六一。'}).targetId!;
    final newerOr = call(kTurn, 'newer-or', 'remember', {
      'text': '我喜欢铜管乐。',
      'keywords': ['铜管乐'],
    }).targetId!;
    store.closeAgentTurn(kTurn);
    final mergeAgain = begin(say('merge-again', '仍然是同一个铜管乐爱好。'), [actualCard(alternative), actualCard(newerOr)]);
    expect(
      call(mergeAgain, 'merge-again', 'merge', {
        'card': alternative,
        'from': [newerOr],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(mergeAgain);
    final childClaim = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final childTurn =
        store.beginAgentMaintenance(kind: 'extract', claimId: childClaim['id']! as String)['id']! as String;
    store.grantAgentCards(turnId: childTurn, cardRevisions: {alternative: actualCard(alternative)['row_rev']! as int});
    final child = call(childTurn, 'reference-child', 'remember', {
      'text': '铜管乐是用户的爱好。',
      'sources': [rawS['id']],
      'references': [alternative],
    }).targetId!;
    store.finishAgentMaintenance(turnId: childTurn, complete: true);
    expect(actualCard(child)['current_basis_seq'], rawK['first_seq']);
    expect((actualCard(child)['evidence'] as List).single, containsPair('message_id', rawS['id']));
    expect(rawS['first_seq']! as int, lessThan(rawK['first_seq']! as int));
    final refDeleting = begin(say('reference-forget', '忘掉电话号码，连原话也删。'), [actualCard(refRoot)]);
    expect(
      call(refDeleting, 'reference-root-related', 'related', {'card': refRoot}).relatedCards!.map((row) => row['id']),
      contains(alternative),
    );
    expect(
      call(refDeleting, 'reference-parent-related', 'related', {
        'card': alternative,
      }).relatedCards!.map((row) => row['id']),
      contains(child),
    );
    final beforeRefCards = store.cards(), beforeRefMessages = store.messages(), beforeRefArchive = store.archive;
    final refused = call(refDeleting, 'reference-forget', 'forget', {
      'card': refRoot,
      'deleteChat': true,
      'changes': [
        {'card': refRoot, 'forget': true},
        {
          'card': child,
          'text': '铜管乐是用户的爱好。',
          'references': [alternative],
        },
      ],
    });
    expect(refused.applied, isFalse);
    expect(refused.code, 'older_than_current');
    expect(store.cards(), beforeRefCards);
    expect(store.messages(), beforeRefMessages);
    expect(store.archive, beforeRefArchive);
    expect(store.requests(), paid);

    // A prepared destination topic must survive deletion of its last card in
    // this same public group. The retained rewrite uses the new real source.
    store.closeAgentTurn(refDeleting);
    final destinationRaw = say('destination-source', '我喝咖啡不加糖。');
    final destinationMaking = begin(destinationRaw);
    final destination = call(destinationMaking, 'destination-card', 'remember', {
      'text': '我喝咖啡不加糖。',
      'keywords': ['咖啡'],
    }).targetId!;
    expect(
      call(destinationMaking, 'destination-never', 'quiet', {'card': destination, 'mode': 'never'}).applied,
      isTrue,
    );
    store.closeAgentTurn(destinationMaking);
    final destinationTopic = actualCard(destination)['topic_id'];
    final movingMaking = begin(say('moving-source', '我想折一架纸飞机。'));
    final movingCard = call(movingMaking, 'moving-card', 'remember', {
      'text': '我想折一架纸飞机。',
      'keywords': ['纸飞机'],
    }).targetId!;
    store.closeAgentTurn(movingMaking);
    expect(store.cards().where((row) => row['topic_id'] == destinationTopic).map((row) => row['id']), [destination]);
    final destinationControls = store.topicControls();
    final movingSource = say('moving-current-source', '旧咖啡条目删掉，将这张记录改成我最近的咖啡甜度是无糖。');
    final moving = begin(movingSource, [actualCard(destination), actualCard(movingCard)]);
    final moved = call(moving, 'move-and-forget', 'forget', {
      'changes': [
        {'card': destination, 'forget': true},
        {
          'card': movingCard,
          'text': '我最近的咖啡甜度是无糖。',
          'keywords': ['无糖'],
          'sources': [movingSource['id']],
        },
      ],
    });
    expect(moved.applied, isTrue);
    expect(moved.changedCardIds, unorderedEquals([destination, movingCard]));
    expect(store.cards(includeInactive: true).any((row) => row['id'] == destination), isFalse);
    expect(actualCard(movingCard)['topic_id'], destinationTopic);
    expect(actualCard(movingCard)['topic_mode'], 'never');
    expect((actualCard(movingCard)['evidence'] as List).single, containsPair('message_id', movingSource['id']));
    expect(store.topicControls(), destinationControls);
    expect(
      store.messages().singleWhere((row) => row['id'] == destinationRaw['id']),
      allOf(
        containsPair('text', destinationRaw['text']),
        containsPair('source_rev', destinationRaw['source_rev']),
        containsPair('first_seq', destinationRaw['first_seq']),
      ),
    );
    expect(store.requests(), paid);

    // Surviving direct proof and a current parent both support the refreshed
    // basis. A retained child checks the preview before the same values persist.
    store.closeAgentTurn(moving);
    now += 60000;
    final refreshR10 = say('refresh-r10', '我喜欢陶笛，也参加周末合奏。');
    final refreshFirst = begin(refreshR10);
    final refreshCard = call(refreshFirst, 'refresh-r', 'remember', {'text': '我喜欢陶笛。'}).targetId!;
    final refreshChild = call(refreshFirst, 'refresh-c', 'remember', {'text': '我参加周末合奏。'}).targetId!;
    store.closeAgentTurn(refreshFirst);
    now += 60000;
    final refreshR20 = say('refresh-r20', '我住银杏路，也喜欢陶笛。');
    final refreshSecond = begin(refreshR20);
    final refreshRoot = call(refreshSecond, 'refresh-x', 'remember', {
      'text': '我住银杏路。',
      'keywords': ['银杏路'],
    }).targetId!;
    final refreshDuplicate = call(refreshSecond, 'refresh-duplicate', 'remember', {'text': '我喜欢陶笛。'}).targetId!;
    store.closeAgentTurn(refreshSecond);
    final refreshMerge = begin(say('refresh-merge', '两条陶笛记录是同一个爱好。'), [
      actualCard(refreshCard),
      actualCard(refreshDuplicate),
    ]);
    expect(
      call(refreshMerge, 'refresh-merge', 'merge', {
        'card': refreshCard,
        'from': [refreshDuplicate],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(refreshMerge);
    now += 60000;
    final refreshR30 = say('refresh-r30', '我把音乐当作长期爱好，临时玻璃展已经看完。');
    final refreshThird = begin(refreshR30);
    final refreshParent = call(refreshThird, 'refresh-p', 'remember', {'text': '我把音乐当作长期爱好。'}).targetId!;
    final refreshDisposable = call(refreshThird, 'refresh-d', 'remember', {'text': '临时玻璃展已经看完。'}).targetId!;
    store.closeAgentTurn(refreshThird);
    final refreshLink = begin(say('refresh-link', '忘掉临时玻璃展，陶笛和合奏的记录参照音乐爱好。'), [
      actualCard(refreshDisposable),
      actualCard(refreshCard),
      actualCard(refreshChild),
      actualCard(refreshParent),
    ]);
    expect(
      call(refreshLink, 'refresh-link', 'forget', {
        'changes': [
          {'card': refreshDisposable, 'forget': true},
          {
            'card': refreshCard,
            'text': '我喜欢陶笛。',
            'references': [refreshParent],
          },
          {
            'card': refreshChild,
            'text': '我参加周末合奏。',
            'references': [refreshCard],
          },
        ],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(refreshLink);
    final refreshBefore = actualCard(refreshCard);
    final refreshChildBefore = actualCard(refreshChild);
    final refreshParentBefore = actualCard(refreshParent);
    final refreshProofs = (refreshBefore['evidence'] as List).cast<MemoryRow>();
    expect(refreshProofs.map((proof) => proof['support_group']).toSet(), hasLength(2));
    expect(refreshProofs.map((proof) => proof['message_id']), unorderedEquals([refreshR10['id'], refreshR20['id']]));
    expect(refreshBefore['current_basis_seq'], refreshR30['first_seq']);
    expect(refreshChildBefore['current_basis_seq'], refreshR30['first_seq']);
    final refreshDeleting = begin(say('refresh-delete', '忘掉银杏路，连原话也删。'), [
      actualCard(refreshRoot),
      refreshBefore,
      refreshChildBefore,
    ]);
    final refreshRemoved = call(refreshDeleting, 'refresh-delete', 'forget', {
      'card': refreshRoot,
      'deleteChat': true,
      'changes': [
        {'card': refreshRoot, 'forget': true},
        {
          'card': refreshChild,
          'text': '我参加周末合奏。',
          'references': [refreshCard],
        },
      ],
    });
    expect(refreshRemoved.applied, isTrue);
    expect(refreshRemoved.changedCardIds, unorderedEquals([refreshRoot, refreshChild]));
    expect(refreshRemoved.rawEraseState, 'pending');
    expect(actualCard(refreshCard), refreshBefore);
    expect(actualCard(refreshChild)['row_rev'], (refreshChildBefore['row_rev']! as int) + 1);
    expect(_captured(store, refreshR20), refreshR20);
    store.closeAgentTurn(refreshDeleting);
    final refreshId = refreshRemoved.pendingRawEraseId!;
    expect(store.markRawEraseOffered(refreshId, characterId: null).state, 'awaiting');
    final refreshConfirmed = store.confirmRawErase(refreshId, characterId: null);
    expect(refreshConfirmed.state, 'confirmed');
    expect(refreshConfirmed.changedCardIds, unorderedEquals([refreshCard, refreshChild]));
    final refreshed = actualCard(refreshCard);
    expect(refreshed['row_rev'], (refreshBefore['row_rev']! as int) + 1);
    expect(refreshed['current_basis_seq'], refreshR30['first_seq']);
    expect(refreshed['source_at_ms'], refreshR30['said_at_utc']);
    expect((refreshed['evidence'] as List).single, containsPair('message_id', refreshR10['id']));
    final refreshedChild = actualCard(refreshChild);
    expect(refreshedChild['row_rev'], (refreshChildBefore['row_rev']! as int) + 2);
    expect(refreshedChild['current_basis_seq'], refreshR30['first_seq']);
    expect(refreshedChild['source_at_ms'], refreshR30['said_at_utc']);
    expect(
      (refreshedChild['evidence'] as List).single,
      allOf(
        containsPair('message_id', refreshR10['id']),
        containsPair('source_rev', refreshR10['source_rev']),
        containsPair('quote', refreshR10['text']),
      ),
    );
    expect(actualCard(refreshParent), refreshParentBefore);
    expect(
      store.memoryRetrievalCandidates(characterId: null).map((card) => card['id']),
      containsAll([refreshCard, refreshChild, refreshParent]),
    );
    expect(store.messages().any((source) => source['id'] == refreshR20['id']), isFalse);
    // The surviving originals keep every field the test captured; the store may
    // also carry its own extraction bookkeeping on them.
    Map<String, Object?> captured(Map<String, Object?> like) {
      final row = store.messages().singleWhere((source) => source['id'] == like['id']);
      return {for (final key in like.keys) key: row[key]};
    }

    expect(captured(refreshR10), refreshR10);
    expect(captured(refreshR30), refreshR30);
    expect(store.requests(), paid);
    store.closeAgentTurn(refreshDeleting);
  });

  test('retrieval checks matching and obsolete paths to the same ancestor in one query', () {
    final parent = seed('我喜欢茶。'), left = seed('我喜欢绿茶。'), right = seed('我喜欢红茶。'), root = seed('我常去茶店。');
    void link(MemoryRow child, MemoryRow ancestor, int revision) => database.execute(
      'INSERT INTO memory_card_references(card_id,parent_card_id,parent_row_rev) VALUES (?,?,?)',
      [child['id'], ancestor['id'], revision],
    );
    link(left, parent, 1);
    link(right, parent, 2);
    link(root, left, 1);
    link(root, right, 1);
    var checks = 0;
    database.trace = SqliteTraceCallback((event) {
      if (event is SqliteTraceStatement && (event.sql?.contains('memory_card_references') ?? false)) checks++;
      return 0;
    });
    final candidates = store.memoryRetrievalCandidates(characterId: null);
    database.trace = null;
    expect(candidates.map((card) => card['id']), [parent['id'], left['id']]);
    expect(checks, 1);
  });

  test('planned reference revisions stay current while another character becomes read-stale without a write', () {
    final firstRole = character('local:first');
    final secondRole = character('local:second');
    final first = begin(sayAs('first-facts', '我住杭州，我们聊过这个地方。', firstRole));
    final home = call(first, 'home', 'remember', {
      'text': '我住杭州。',
      'keywords': ['住处'],
    }).targetId!;
    final story = call(first, 'story', 'remember', {
      'collection': 'our_story',
      'text': '我们聊过用户的住处。',
      'sources': <String>[],
      'references': [home],
    }).targetId!;
    store.closeAgentTurn(first);
    final second = begin(sayAs('second-facts', '我们也聊到过住处。', secondRole), [actualCard(home)]);
    final otherStory = call(second, 'story', 'remember', {
      'collection': 'our_story',
      'text': '另一个角色一起聊过住处。',
      'sources': <String>[],
      'references': [home],
    }).targetId!;
    store.closeAgentTurn(second);
    final otherBefore = actualCard(otherStory);
    final rawDeleting = begin(sayAs('raw-cross-role', '忘掉住址，连原话也删。', firstRole), [actualCard(home)]);
    final rawRelated = call(rawDeleting, 'raw-cross-role-related', 'related', {'card': home}).relatedCards!;
    expect(rawRelated.map((row) => row['id']), contains(story));
    expect(rawRelated.map((row) => row['id']), isNot(contains(otherStory)));
    final beforeRawCards = store.cards(), beforeRawMessages = store.messages(), beforeRawArchive = store.archive;
    final rawRefused = call(rawDeleting, 'raw-cross-role', 'forget', {
      'card': home,
      'deleteChat': true,
      'changes': [
        {'card': home, 'forget': true},
        {'card': story, 'forget': true},
      ],
    });
    expect(rawRefused.applied, isFalse);
    expect(rawRefused.code, 'card_not_in_turn');
    expect(store.cards(), beforeRawCards);
    expect(store.messages(), beforeRawMessages);
    expect(store.archive, beforeRawArchive);
    store.closeAgentTurn(rawDeleting);
    final editing = begin(sayAs('new-address', '现在住南京了。', firstRole), [actualCard(home), actualCard(story)]);
    final candidates = call(editing, 'related', 'related', {'card': home}).relatedCards!;
    expect(candidates.map((row) => row['id']), isNot(contains(otherStory)));
    expect(call(editing, 'incomplete', 'revise', {'card': home, 'text': '我住南京。'}).code, 'incomplete_effect_set');
    final edited = call(editing, 'complete', 'revise', {
      'changes': [
        {'card': home, 'text': '我住南京。'},
        {
          'card': story,
          'text': '我们聊过新的住处。',
          'sources': <String>[],
          'references': [home],
        },
      ],
    });
    expect(edited.applied, isTrue);
    expect(edited.currentCardRevisions[home], 2);
    expect(edited.currentCardRevisions[story], 2);
    expect(store.memoryRetrievalCandidates(characterId: firstRole).map((row) => row['id']), contains(story));
    expect(store.memoryPageCards(characterId: firstRole).map((row) => row['id']), isNot(contains(story)));
    expect(actualCard(otherStory), otherBefore);
    expect(
      store.memoryRetrievalCandidates(characterId: secondRole).map((row) => row['id']),
      isNot(contains(otherStory)),
    );
    final stale = store.staleMemoryTargets(characterId: secondRole).single;
    expect(stale['id'], otherStory);
    expect(stale.containsKey('text'), isFalse);
    final cleanup = begin(sayAs('clean-stale', '不用再保留之前的故事。', secondRole));
    final shown = call(cleanup, 'stale', 'related', const {}).relatedCards!.single;
    expect(shown['id'], otherStory);
    expect(shown.containsKey('text'), isFalse);
    expect(call(cleanup, 'forget-stale', 'forget', {'card': otherStory}).applied, isTrue);
    expect(actualCard(home)['text'], '我住南京。');
    expect(actualCard(story)['text'], '我们聊过新的住处。');
  });

  test('a live notice may be recalled in chat but never read by an extraction turn', () {
    final card = store.rememberNotice(
      eventId: '1'.padLeft(64, '0'),
      notificationKey: '2'.padLeft(64, '0'),
      packageName: 'example.delivery',
      appName: 'Parcel',
      text: 'The parcel is ready for pickup.',
      observedAtMs: now,
      expectedControlRevision: store.archive['control_revision']! as int,
    )!;
    final id = card['id']! as String;
    final chat = begin(say('question', 'How is the parcel?'));
    CompanionAgentMemoryResult recall(String turn, String callId) => store.applyAgentMemoryTool(
      turnId: turn,
      callId: callId,
      toolName: 'recall',
      input: {'query': 'parcel'},
      rankedRecallIds: [id],
    );
    final fromChat = recall(chat, 'chat-lookup').recallSelection!;
    expect(fromChat.ids, [id]);
    expect(fromChat.block, contains('example.delivery'));
    expect(
      call(chat, 'chat-related', 'related', {'card': id}).relatedCards!.single['source'],
      containsPair('kind', 'notice'),
    );
    store.closeAgentTurn(chat);

    final claim = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final maintenance = store.beginAgentMaintenance(kind: 'extract', claimId: claim['id']! as String);
    final maintenanceId = maintenance['id']! as String;
    expect((maintenance['cards'] as List<MemoryRow>).map((row) => row['id']), isNot(contains(id)));
    final fromMaintenance = recall(maintenanceId, 'extract-lookup').recallSelection!;
    expect(fromMaintenance.ids, isEmpty);
    expect(fromMaintenance.block, isNot(contains('Parcel')));
    // Even a previously shown ID cannot turn the management tool into a source of notice text.
    store.grantAgentCards(turnId: maintenanceId, cardRevisions: {id: 1});
    final related = call(maintenanceId, 'extract-related', 'related', {'card': id});
    expect(related.relatedCards, isEmpty);
    store.finishAgentMaintenance(turnId: maintenanceId, complete: true);
  });

  test('semantic merge preserves actual AND and OR proof groups and consumed followup identity', () {
    final first = say('proof-one', '我住在杭州。');
    final second = say('proof-two', '住处一直没有变化。');
    final claim = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final turn = store.beginAgentMaintenance(kind: 'extract', claimId: claim['id']! as String)['id']! as String;
    final target = call(turn, 'two-proofs', 'remember', {
      'text': '我住杭州。',
      'sources': [first['id'], second['id']],
    }).targetId!;
    store.finishAgentMaintenance(turnId: turn, complete: true);
    final detail = say('proof-dependent', '住处也是我们聊过的话题。');
    final dependentTurn = begin(detail, [actualCard(target)]);
    final dependent = call(dependentTurn, 'dependent', 'remember', {
      'text': '我们聊过用户在杭州的住处。',
      'references': [target],
    }).targetId!;
    store.closeAgentTurn(dependentTurn);
    expect(actualCard(dependent)['current_basis_seq'], greaterThan(actualCard(target)['current_basis_seq']! as int));
    final quietDependent = begin(say('quiet-dependent', '这条聊过住处的记录少提一点。'), [actualCard(dependent)]);
    expect(call(quietDependent, 'quiet-dependent', 'quiet', {'card': dependent, 'mode': 'less'}).applied, isTrue);
    store.closeAgentTurn(quietDependent);
    now += 3600000;
    final third = say('proof-three', '我的居住地是杭州。');
    expect(third['said_at_utc'], greaterThan(actualCard(target)['source_at_ms']! as int));
    final otherTurn = begin(third);
    final from = call(otherTurn, 'one-proof', 'remember', {'text': '我的居住地是杭州。'}).targetId!;
    store.closeAgentTurn(otherTurn);
    store.initializeInitiative({
      'v': 2,
      'lastGreetingAtMs': null,
      'inviteAtMs': <int>[],
      'signalAtMs': <int>[],
      'declinedUntilMs': 0,
      'night': null,
    });
    final invitation = begin(say('invitation', '现在可以再聊住处。'), [actualCard(from)]);
    final ticket = call(invitation, 'ask', 'ask_later', {'card': from, 'whenMs': now}).targetId!;
    final spend = store.reserveInitiative(kind: 'followup', nowMs: now, maxPerDay: 2, gapMs: 0, followupId: ticket)!;
    store.settleInitiative(spend, outcome: 'shown');
    store.closeAgentTurn(invitation);
    expect(third['first_seq'], greaterThan(actualCard(dependent)['current_basis_seq']! as int));
    final merging = begin(say('merge', '这两条说的是同一个住处。'), [actualCard(target), actualCard(from), actualCard(dependent)]);
    final merged = call(merging, 'merge-same', 'merge', {
      'card': target,
      'from': [from],
      'text': '我住杭州。',
      'updates': [
        {
          'card': dependent,
          'text': '我们聊过用户在杭州的同一个住处。',
          'sources': <String>[],
          'references': [target],
        },
      ],
    });
    expect(merged.applied, isTrue);
    expect(merged.changedCardIds, unorderedEquals([target, from, dependent]));
    expect(actualCard(target)['current_basis_seq'], third['first_seq']);
    expect(actualCard(dependent)['current_basis_seq'], third['first_seq']);
    expect(actualCard(target)['source_at_ms'], third['said_at_utc']);
    expect(actualCard(dependent)['source_at_ms'], third['said_at_utc']);
    expect(
      database.select('SELECT parent_row_rev FROM memory_card_references WHERE card_id=?', [
        dependent,
      ]).single['parent_row_rev'],
      actualCard(target)['row_rev'],
    );
    expect(store.memoryRetrievalCandidates(characterId: null).map((row) => row['id']), contains(dependent));
    final proofs = (actualCard(target)['evidence'] as List).cast<MemoryRow>();
    final groups = <String, Set<Object?>>{};
    for (final proof in proofs) {
      (groups[proof['support_group']! as String] ??= {}).add(proof['message_id']);
    }
    expect(
      groups.values,
      unorderedEquals([
        {first['id'], second['id']},
        {third['id']},
      ]),
    );
    expect(store.cards().map((row) => row['id']), unorderedEquals([target, dependent]));
    final consumed = store.followups().singleWhere((row) => row['id'] == ticket);
    expect(consumed['state'], 'asked');
    expect(consumed['card_id'], target);
    expect(store.nextFollowup(nowMs: now), isNull);
    expect(store.requests(), isEmpty);
    expect(actualCard(target)['topic_mode'], 'normal');
    expect(actualCard(dependent)['topic_mode'], 'less');
    store.closeAgentTurn(merging);

    // T and F describe the same fact. U and V share only their respective
    // topic keyword; they have different bodies, originals and no references.
    const sameFact = '你周四安排修琴，修的是小提琴。';
    final targetTurn = begin(say('topic-target-source', '我周四安排修琴，修的是小提琴。'));
    final topicTarget = call(targetTurn, 'topic-target', 'remember', {
      'text': sameFact,
      'keywords': ['修琴'],
    });
    expect(topicTarget.applied, isTrue);
    expect(
      call(targetTurn, 'topic-target-less', 'quiet', {'card': topicTarget.targetId, 'mode': 'less'}).applied,
      isTrue,
    );
    store.closeAgentTurn(targetTurn);
    final neighborTurn = begin(say('topic-target-neighbor-source', '我想请修琴师给中提琴调弦。'));
    final targetNeighbor = call(neighborTurn, 'topic-target-neighbor', 'remember', {
      'text': '你想请修琴师给中提琴调弦。',
      'keywords': ['修琴'],
    });
    expect(targetNeighbor.applied, isTrue);
    store.closeAgentTurn(neighborTurn);
    final topicTargetId = topicTarget.targetId!, targetNeighborId = targetNeighbor.targetId!;
    final normalTopic = actualCard(topicTargetId)['topic_id'];
    expect(actualCard(targetNeighborId)['topic_id'], normalTopic);
    final restoring = begin(say('topic-target-normal-source', '以后可以聊修琴了。'), [
      actualCard(topicTargetId),
      actualCard(targetNeighborId),
    ]);
    expect(call(restoring, 'topic-target-normal', 'quiet', {'card': topicTargetId, 'mode': 'normal'}).applied, isTrue);
    final scheduledTarget = call(restoring, 'topic-target-later', 'ask_later', {'card': topicTargetId, 'whenMs': now});
    expect(scheduledTarget.applied, isTrue);
    store.closeAgentTurn(restoring);
    final fromTurn = begin(say('topic-from-source', '我周四安排修琴，修的是小提琴。'));
    final topicFrom = call(fromTurn, 'topic-from', 'remember', {
      'text': sameFact,
      'keywords': ['小提琴'],
    });
    expect(topicFrom.applied, isTrue);
    expect(call(fromTurn, 'topic-from-never', 'quiet', {'card': topicFrom.targetId, 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(fromTurn);
    final fromNeighborTurn = begin(say('topic-from-neighbor-source', '我喜欢小提琴的暖色音色。'));
    final fromNeighbor = call(fromNeighborTurn, 'topic-from-neighbor', 'remember', {
      'text': '你喜欢小提琴的暖色音色。',
      'keywords': ['小提琴'],
    });
    expect(fromNeighbor.applied, isTrue);
    store.closeAgentTurn(fromNeighborTurn);
    final topicFromId = topicFrom.targetId!, fromNeighborId = fromNeighbor.targetId!;
    final neverTopic = actualCard(topicFromId)['topic_id'];
    expect(neverTopic, isNot(normalTopic));
    expect(actualCard(fromNeighborId)['topic_id'], neverTopic);
    final untouchedNormal = actualCard(targetNeighborId), untouchedNever = actualCard(fromNeighborId);
    expect(untouchedNormal['topic_mode'], 'normal');
    expect(untouchedNever['topic_mode'], 'never');
    final topics = database
        .select('SELECT id,mode,control_anchors FROM memory_topics WHERE id IN (?,?) ORDER BY id', [
          normalTopic,
          neverTopic,
        ])
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    expect(jsonDecode(topics.singleWhere((row) => row['id'] == normalTopic)['control_anchors']! as String), isEmpty);
    expect(jsonDecode(topics.singleWhere((row) => row['id'] == neverTopic)['control_anchors']! as String), ['小提琴']);
    final pendingTarget = store.followups().singleWhere((row) => row['id'] == scheduledTarget.targetId);
    expect(pendingTarget['state'], 'pending');
    expect(store.isFollowupCurrent(pendingTarget, nowMs: now), isTrue);
    final originalSpends = database
        .select('SELECT * FROM memory_initiative_spends')
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    expect(originalSpends.single['id'], spend);
    expect(originalSpends.single['state'], 'shown');
    final mergingTopics = begin(say('merge-topics-source', '这两条修琴记录是同一件事。'), [
      actualCard(topicTargetId),
      actualCard(topicFromId),
    ]);
    final mergedTopics = call(mergingTopics, 'merge-topics', 'merge', {
      'card': topicTargetId,
      'from': [topicFromId],
    });
    expect(mergedTopics.applied, isTrue);
    expect(mergedTopics.changedCardIds, unorderedEquals([topicTargetId, topicFromId]));
    expect(mergedTopics.targetId, topicTargetId);
    expect(actualCard(topicTargetId)['topic_id'], neverTopic);
    expect(actualCard(topicTargetId)['topic_mode'], 'never');
    expect(store.cards().any((card) => card['id'] == topicFromId), isFalse);
    expect(actualCard(targetNeighborId), untouchedNormal);
    expect(actualCard(fromNeighborId), untouchedNever);
    expect(
      database.select('SELECT id,mode,control_anchors FROM memory_topics WHERE id IN (?,?) ORDER BY id', [
        normalTopic,
        neverTopic,
      ]),
      topics,
    );
    // Read the stored state before nextFollowup can refresh it. The merge
    // itself must retire this actual pending invitation without a new debit.
    final closedTarget = store.followups().singleWhere((row) => row['id'] == scheduledTarget.targetId);
    expect(closedTarget['state'], 'closed');
    expect(closedTarget['reason'], 'quiet');
    expect(closedTarget['card_id'], topicTargetId);
    for (final field in const [
      'id',
      'message_id',
      'source_rev',
      'invitation',
      'opens_at_ms',
      'expires_at_ms',
      'presented_at_ms',
    ]) {
      expect(closedTarget[field], pendingTarget[field]);
    }
    expect(database.select('SELECT * FROM memory_initiative_spends'), originalSpends);
    expect(store.nextFollowup(nowMs: now), isNull);
    expect(store.requests(), isEmpty);

    // These real originals identify the same unsweetened latte as coffee.
    // Internal controls may both match an explicit new synonymous body.
    store.closeAgentTurn(mergingTopics);
    final bodyExternalMaking = begin(say('body-external-source', '我喝咖啡不加糖。'));
    final bodyExternal = call(bodyExternalMaking, 'body-external', 'remember', {
      'text': '我喝咖啡不加糖。',
      'keywords': ['咖啡'],
    }).targetId!;
    expect(
      call(bodyExternalMaking, 'body-external-less', 'quiet', {'card': bodyExternal, 'mode': 'less'}).applied,
      isTrue,
    );
    store.closeAgentTurn(bodyExternalMaking);
    final bodyTargetRaw = say('body-target-source', '我最近的咖啡都是拿铁，甜度是无糖。');
    final bodyTargetMaking = begin(bodyTargetRaw);
    final bodyTarget = call(bodyTargetMaking, 'body-target', 'remember', {
      'text': '我最近的拿铁甜度是无糖。',
      'keywords': ['拿铁'],
    }).targetId!;
    store.closeAgentTurn(bodyTargetMaking);
    final bodyFromRaw = say('body-from-source', '我点的拿铁就是咖啡，最近一直选无糖。');
    final bodyFromMaking = begin(bodyFromRaw);
    final bodyFrom = call(bodyFromMaking, 'body-from', 'remember', {
      'text': '我点的拿铁最近一直无糖。',
      'keywords': ['无糖'],
    }).targetId!;
    store.closeAgentTurn(bodyFromMaking);
    final bodyQuieting = begin(say('body-quiet-source', '拿铁少提，无糖的这条不要主动提。'), [
      actualCard(bodyTarget),
      actualCard(bodyFrom),
    ]);
    expect(call(bodyQuieting, 'body-target-less', 'quiet', {'card': bodyTarget, 'mode': 'less'}).applied, isTrue);
    expect(call(bodyQuieting, 'body-from-never', 'quiet', {'card': bodyFrom, 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(bodyQuieting);
    final bodyNeverTopic = actualCard(bodyFrom)['topic_id'];
    final bodyExternalTopic = actualCard(bodyExternal)['topic_id'];
    final bodyJoining = begin(say('body-merge-source', '这两条拿铁记录是同一种咖啡的无糖甜度。'), [
      actualCard(bodyTarget),
      actualCard(bodyFrom),
    ]);
    final beforeMixedBody = store.cards(includeInactive: true);
    final beforeMixedArchive = store.archive;
    final bodyControls = store.topicControls();
    final mixedBody = call(bodyJoining, 'body-mixed', 'merge', {
      'card': bodyTarget,
      'from': [bodyFrom],
      'text': '我最近的咖啡拿铁一直无糖。',
      'keywords': ['拿铁', '无糖'],
    });
    expect(mixedBody.applied, isFalse);
    expect(mixedBody.code, 'ambiguous_controlled_topic');
    expect(mixedBody.changedCardIds, isEmpty);
    expect(store.cards(includeInactive: true), beforeMixedBody);
    expect(store.archive, beforeMixedArchive);
    expect(store.topicControls(), bodyControls);
    final internalBody = call(bodyJoining, 'body-internal', 'merge', {
      'card': bodyTarget,
      'from': [bodyFrom],
      'text': '最近我的拿铁一直无糖。',
      'keywords': ['拿铁', '无糖'],
    });
    expect(internalBody.applied, isTrue);
    expect(internalBody.changedCardIds, unorderedEquals([bodyTarget, bodyFrom]));
    expect(actualCard(bodyTarget)['topic_id'], bodyNeverTopic);
    expect(actualCard(bodyTarget)['topic_mode'], 'never');
    expect(
      (actualCard(bodyTarget)['evidence'] as List).cast<MemoryRow>().map((row) => row['message_id']),
      unorderedEquals([bodyTargetRaw['id'], bodyFromRaw['id']]),
    );
    expect(store.topicControls(), bodyControls);
    store.closeAgentTurn(bodyJoining);

    // A later explicit body matches only the external coffee control. Its
    // less mode wins over the old never participant because it is this topic.
    final bodyAnotherMaking = begin(say('body-another-source', '这种饮品就是刚才的拿铁咖啡，我一直不加糖。'));
    final bodyAnother = call(bodyAnotherMaking, 'body-another', 'remember', {
      'text': '这种饮品一直不加糖。',
      'keywords': ['饮品'],
    }).targetId!;
    store.closeAgentTurn(bodyAnotherMaking);
    final bodyExternalJoining = begin(say('body-external-merge-source', '这条饮品记录与前面的咖啡甜度是同一件事。'), [
      actualCard(bodyTarget),
      actualCard(bodyAnother),
    ]);
    final externalBody = call(bodyExternalJoining, 'body-external-merge', 'merge', {
      'card': bodyTarget,
      'from': [bodyAnother],
      'text': '我最近喝咖啡不加糖。',
      'keywords': ['咖啡'],
    });
    expect(externalBody.applied, isTrue);
    expect(externalBody.changedCardIds, unorderedEquals([bodyTarget, bodyAnother]));
    expect(actualCard(bodyTarget)['topic_id'], bodyExternalTopic);
    expect(actualCard(bodyTarget)['topic_mode'], 'less');
    expect(store.cards(includeInactive: true).any((row) => row['id'] == bodyAnother), isFalse);
    expect(store.cards(includeInactive: true).where((row) => row['topic_id'] == bodyNeverTopic), isEmpty);
    expect(store.topicControls(), bodyControls);
    expect(
      call(bodyExternalJoining, 'body-still-quiet', 'ask_later', {'card': bodyTarget, 'whenMs': now}).code,
      'topic_quiet',
    );
    expect(store.requests(), isEmpty);
  });

  test('ADD49 a person card keeps typed editor keywords through manual save and reopen', () {
    final role = character('local:person-editor');
    final original = sayAs('person-source', '小周就是周老师，是我的朋友。', role);
    final turn = begin(original);
    final person = call(turn, 'new-person', 'person', {
      'text': '周老师是用户的朋友。',
      'aliases': ['小周', '周老师'],
      'keywords': ['朋友', '小周'],
    }).targetId!;
    expect(call(turn, 'quiet-person-editor', 'quiet', {'card': person, 'mode': 'never'}).applied, isTrue);
    store.closeAgentTurn(turn);
    final row = store.memoryPageCards(characterId: role).single;
    expect(row['topic_mode'], 'never');
    // This is the editor's public-row contract and its actual save API. A
    // List<dynamic> containing strings still fails this List<String> cast.
    final keywords = row['keywords'] as List<String>;
    expect(keywords, unorderedEquals(['朋友', '小周', '周老师']));
    final revision = store.saveManual(
      CompanionMemory(
        id: row['id']! as String,
        text: '周老师是我的提琴老师。',
        kind: row['kind']! as String,
        keywords: keywords,
        pinned: row['pinned'] == true,
      ),
      expectedRowRev: row['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    reopen();
    final saved = store.memoryPageCards(characterId: role).single;
    expect(saved['id'], person);
    expect(saved['row_rev'], revision);
    expect(saved['text'], '周老师是我的提琴老师。');
    expect(saved['collection'], 'person');
    expect(saved['keywords'] as List<String>, unorderedEquals(keywords));
    expect(store.messages().single['text'], original['text']);
    expect(saved['topic_id'], row['topic_id']);
    expect(saved['topic_mode'], 'never');
  });

  test('person aliases stay shared while stories and model history keep their captured character', () {
    final firstRole = character('workshop:["https://example.test","companion","one"]');
    final secondRole = character('local:other');
    expect(character('workshop:["https://example.test","companion","one"]'), firstRole);
    final first = begin(sayAs('about-person', '小周就是周老师，我和她一起谈过红茶。', firstRole));
    final person = call(first, 'person', 'person', {
      'text': '周老师是用户的朋友。',
      'aliases': ['小周', '周老师'],
      'keywords': <String>[],
    }).targetId!;
    final story = call(first, 'private', 'remember', {'collection': 'our_story', 'text': '我们聊过红茶。'}).targetId!;
    store.closeAgentTurn(first);
    say('legacy-user', '旧的用户原话');
    store.submitMessage(
      id: 'legacy-assistant',
      sessionId: 'light:agent',
      role: 'assistant',
      text: '没有可追认角色的旧回答',
      saidAtUtc: now,
      offsetMinutes: 0,
    );
    sayAs('own-assistant', '第一位的实际回答', firstRole, role: 'assistant');
    sayAs('other-user', '第二位的原话', secondRole);
    sayAs('other-assistant', '第二位的回答', secondRole, role: 'assistant');
    final candidates = store.memoryRetrievalCandidates(characterId: secondRole, input: '小周近况如何');
    expect(candidates.map((row) => row['id']), contains(person));
    expect(candidates.map((row) => row['id']), isNot(contains(story)));
    expect(
      selectMemoryContext(
        candidates,
        input: '小周近况如何',
        nowMs: now,
        controlRevision: store.archive['control_revision']! as int,
      ).ids,
      [person],
    );
    expect(store.memoryPageCards(characterId: firstRole).map((row) => row['id']), [person]);
    expect(
      store.modelMessages(sessionId: 'light:agent', characterId: firstRole, limit: 1).single['id'],
      'own-assistant',
    );
    expect(store.modelMessages(sessionId: 'light:agent', characterId: null).map((row) => row['id']), ['legacy-user']);
    expect(
      store
          .modelMessages(sessionId: 'light:agent', characterId: firstRole)
          .any((row) => row['id'] == 'legacy-assistant' || row['id'] == 'other-user'),
      isFalse,
    );
  });

  test('maintenance roles share one write budget and every continuation has its own usage receipt', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    final firstRole = character('local:keeper-first');
    final secondRole = character('local:keeper-second');
    final firstSource = sayAs('day-first', '今天喝了红茶。', firstRole);
    sayAs('day-second', '今天散步了。', secondRole);
    now += 86400000;
    final estimatedContexts = <MemoryRow>[];
    final claim = store.nextAgentMaintenance(
      kind: 'organize',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      estimateContextTokens: (context) {
        estimatedContexts.add(context);
        return jsonEncode(context).length;
      },
    )!;
    expect(claim['scope_characters'], [null, firstRole, secondRole]);
    final shared = store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String);
    final sharedId = shared['id']! as String;
    expect(
      estimatedContexts,
      contains(
        allOf(
          containsPair('local_day', '2026-10-01'),
          containsPair('character_id', null),
          containsPair('zone_id', 'offset:0'),
          containsPair('sources', shared['sources']),
          containsPair('cards', shared['cards']),
          containsPair('presentations', shared['presentations']),
        ),
      ),
    );
    final one = store.reserveAgentMaintenanceRequest(
      turnId: sharedId,
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 500,
      outputTokens: 50,
    )!;
    expect(
      store.reserveAgentMaintenanceRequest(
        turnId: sharedId,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 500,
        outputTokens: 50,
      ),
      isNull,
    );
    observed(one);
    final two = store.reserveAgentMaintenanceRequest(
      turnId: sharedId,
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 550,
      outputTokens: 50,
    )!;
    expect(two, isNot(one));
    observed(two, input: 120, output: 12);
    final diary = call(sharedId, 'diary', 'diary', {
      'text': '用户今天喝了红茶，也散了步。',
      'sources': (shared['sources'] as List).map((row) => (row as MemoryRow)['id']).toList(),
    });
    expect(diary.applied, isTrue);
    expect(actualCard(diary.targetId!)['local_day'], '2026-10-01');
    expect(store.isAgentTurnCurrent(sharedId), isTrue);
    store.finishAgentMaintenance(turnId: sharedId, complete: true);
    final first = store.beginAgentMaintenance(
      kind: 'organize',
      claimId: claim['id']! as String,
      characterId: firstRole,
    );
    final firstId = first['id']! as String;
    expect((first['sources'] as List).every((row) => (row as MemoryRow)['character_id'] == firstRole), isTrue);
    final three = store.reserveAgentMaintenanceRequest(
      turnId: firstId,
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 400,
      outputTokens: 50,
    )!;
    observed(three, input: 80, output: 8);
    expect(
      call(firstId, 'impression', 'impression', {'text': '用户愿意分享日常。', 'source': firstSource['id']}).applied,
      isTrue,
    );
    expect(
      call(firstId, 'story', 'remember', {
        'collection': 'our_story',
        'text': '我们聊过今天的红茶。',
        'source': firstSource['id'],
      }).applied,
      isTrue,
    );
    expect(
      call(firstId, 'fourth', 'remember', {'text': '超出整个父机会的第四张', 'source': firstSource['id']}).code,
      'card_limit',
    );
    store.finishAgentMaintenance(turnId: firstId, complete: true);
    expect(
      () => store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String, characterId: secondRole),
      throwsA(isA<DshRemoteException>()),
    );
    expect(store.requests().map((row) => row['id']), unorderedEquals([one, two, three]));
    expect(store.requests().fold<int>(0, (sum, row) => sum + (row['input_uncached']! as int)), 300);
    expect(store.requests().every((row) => row['terminal'] == 'complete'), isTrue);
    expect(
      store.nextAgentMaintenance(kind: 'organize', offsetMinutes: 0, estimateTokens: (text) => text.length),
      isNull,
    );
    now += 86400000;
    final later = store.nextAgentMaintenance(
      kind: 'organize',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
    )!;
    expect(later['scope_characters'], [secondRole]);
    final remaining = store.beginAgentMaintenance(
      kind: 'organize',
      claimId: later['id']! as String,
      characterId: secondRole,
    );
    expect((remaining['sources'] as List).map((row) => (row as MemoryRow)['id']), ['day-second']);
    store.grantAgentCards(
      turnId: remaining['id']! as String,
      cardRevisions: {
        for (final row in remaining['cards'] as List<MemoryRow>) row['id']! as String: row['row_rev']! as int,
      },
    );
    expect(
      call(remaining['id']! as String, 'not-a-new-day', 'diary', {
        'text': '不能把前天的角色欠账当作昨天的日记。',
        'source': 'day-second',
      }).code,
      'diary_day_source_required',
    );
    expect(
      call(remaining['id']! as String, 'second-impression', 'impression', {
        'text': '用户会分享散步的日常。',
        'source': 'day-second',
      }).applied,
      isTrue,
    );
    store.finishAgentMaintenance(turnId: remaining['id']! as String, complete: true);
    now += 86400000;
    reopen();
    expect(
      store.nextAgentMaintenance(kind: 'organize', offsetMinutes: 0, estimateTokens: (text) => text.length),
      isNull,
      reason: 'the served role revision is not recaptured from an older unfinished parent',
    );

    // The Page also exposes an existing private impression. Its real stored
    // role, not shared or another role's stronger control, chooses the topic.
    final editingImpression = store.cards().singleWhere(
      (row) => row['collection'] == 'impression' && row['character_id'] == firstRole,
    );
    final otherImpression = store.cards().singleWhere(
      (row) => row['collection'] == 'impression' && row['character_id'] == secondRole,
    );
    final editorOwnMaking = begin(sayAs('editor-own-source', '我们最近聊过咖啡。', firstRole));
    final editorOwn = call(editorOwnMaking, 'editor-own', 'remember', {
      'collection': 'our_story',
      'text': '我们最近聊过咖啡。',
      'keywords': ['咖啡'],
    }).targetId!;
    expect(call(editorOwnMaking, 'editor-own-less', 'quiet', {'card': editorOwn, 'mode': 'less'}).applied, isTrue);
    store.closeAgentTurn(editorOwnMaking);
    final editorOtherMaking = begin(sayAs('editor-other-source', '我们谈过咖啡的温度。', secondRole));
    final editorOther = call(editorOtherMaking, 'editor-other', 'remember', {
      'collection': 'our_story',
      'text': '我们谈过咖啡的温度。',
      'keywords': ['咖啡'],
    }).targetId!;
    expect(
      call(editorOtherMaking, 'editor-other-never', 'quiet', {'card': editorOther, 'mode': 'never'}).applied,
      isTrue,
    );
    store.closeAgentTurn(editorOtherMaking);
    final editorSharedMaking = begin(say('editor-shared-source', '我喝咖啡不加糖。'));
    final editorShared = call(editorSharedMaking, 'editor-shared', 'remember', {
      'text': '我喝咖啡不加糖。',
      'keywords': ['咖啡'],
    }).targetId!;
    expect(
      call(editorSharedMaking, 'editor-shared-never', 'quiet', {'card': editorShared, 'mode': 'never'}).applied,
      isTrue,
    );
    store.closeAgentTurn(editorSharedMaking);
    final editorOwnBefore = actualCard(editorOwn);
    final editorOtherBefore = actualCard(editorOther);
    final editorSharedBefore = actualCard(editorShared);
    final editorControls = store.topicControls();
    final editorRequests = store.requests();
    final editingImpressionId = editingImpression['id']! as String;
    expect(store.memoryPageCards(characterId: firstRole).map((row) => row['id']), contains(editingImpressionId));
    expect(
      store.memoryPageCards(characterId: secondRole).map((row) => row['id']),
      isNot(contains(editingImpressionId)),
    );
    store.saveManual(
      CompanionMemory(
        id: editingImpressionId,
        text: '我们聊起咖啡时彼此更放松。',
        kind: editingImpression['kind']! as String,
        keywords: (editingImpression['keywords']! as List).cast<String>(),
        pinned: editingImpression['pinned'] == true,
      ),
      expectedRowRev: actualCard(editingImpressionId)['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    final privateEdited = actualCard(editingImpressionId);
    expect(privateEdited['collection'], 'impression');
    expect(privateEdited['character_id'], firstRole);
    expect(privateEdited['topic_id'], editorOwnBefore['topic_id']);
    expect(privateEdited['topic_mode'], 'less');
    expect(privateEdited['row_rev'], (editingImpression['row_rev']! as int) + 1);
    expect(actualCard(editorOwn), editorOwnBefore);
    expect(actualCard(editorOther), editorOtherBefore);
    expect(actualCard(editorShared), editorSharedBefore);
    expect(actualCard(otherImpression['id']! as String), otherImpression);
    expect(store.topicControls(), editorControls);
    expect(store.requests(), editorRequests);

    // Keep the three existing coffee controls above. A different real topic
    // makes the fixed-layer invitation and ambiguity checks independent.
    final magnoliaMaking = begin(sayAs('fixed-magnolia-source', '我们看过玉兰，也谈过散步。', firstRole));
    final magnolia = call(magnoliaMaking, 'fixed-magnolia', 'remember', {
      'collection': 'our_story',
      'text': '我们看过玉兰。',
      'keywords': ['玉兰'],
    });
    expect(magnolia.applied, isTrue);
    expect(
      call(magnoliaMaking, 'fixed-magnolia-never', 'quiet', {'card': magnolia.targetId, 'mode': 'never'}).applied,
      isTrue,
    );
    store.closeAgentTurn(magnoliaMaking);
    final bookMaking = begin(say('fixed-book-source', '我喜欢读纸书。'));
    final book = call(bookMaking, 'fixed-book', 'remember', {
      'text': '我喜欢读纸书。',
      'keywords': ['纸书'],
    });
    expect(book.applied, isTrue);
    store.closeAgentTurn(bookMaking);
    final impressionSource = sayAs('fixed-invitation-source', '我们聊过玉兰，散步时更自在。', firstRole);
    final impressionWriting = begin(impressionSource, [actualCard(editingImpressionId), actualCard(book.targetId!)]);
    expect(
      call(impressionWriting, 'fixed-invitation-impression', 'impression', {
        'card': editingImpressionId,
        'text': '聊过玉兰后，散步时彼此更自在。',
        'keywords': ['散步'],
        'sources': [impressionSource['id']],
        'references': [book.targetId],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(impressionWriting);
    final invitedImpression = actualCard(editingImpressionId);
    expect(invitedImpression['topic_id'], actualCard(magnolia.targetId!)['topic_id']);
    expect(invitedImpression['topic_mode'], 'never');
    expect(invitedImpression['keywords'], ['散步']);
    final cardsBeforeFixedReads = store.cards();
    final controlsBeforeFixedReads = store.topicControls();
    final archiveBeforeFixedReads = store.archive;
    final requestsBeforeFixedReads = store.requests();
    expect(
      store
          .memoryFixedLayerCards(characterId: firstRole, fromDay: '2026-10-02', beforeDay: '2026-10-04')
          .map((row) => row['id']),
      isNot(contains(editingImpressionId)),
    );
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊玉兰',
          )
          .map((row) => row['id']),
      contains(editingImpressionId),
    );
    expect(
      store
          .memoryFixedLayerCards(
            characterId: null,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊玉兰',
          )
          .map((row) => row['id']),
      isNot(contains(editingImpressionId)),
    );
    expect(
      store
          .memoryFixedLayerCards(
            characterId: secondRole,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊玉兰',
          )
          .map((row) => row['id']),
      isNot(contains(editingImpressionId)),
    );
    expect(store.cards(), cardsBeforeFixedReads);
    expect(store.topicControls(), controlsBeforeFixedReads);
    expect(store.archive, archiveBeforeFixedReads);
    expect(store.requests(), requestsBeforeFixedReads);

    // A shared ordinary card is outside the fixed subset but inside the
    // same real selection domain, so it can make the invitation ambiguous.
    final ambiguousMaking = begin(say('fixed-shared-magnolia-source', '我在窗边养了一盆玉兰。'));
    final ambiguous = call(ambiguousMaking, 'fixed-shared-magnolia', 'remember', {
      'text': '我在窗边养了一盆玉兰。',
      'keywords': ['玉兰'],
    });
    expect(ambiguous.applied, isTrue);
    expect(
      call(ambiguousMaking, 'fixed-shared-magnolia-never', 'quiet', {
        'card': ambiguous.targetId,
        'mode': 'never',
      }).applied,
      isTrue,
    );
    expect(actualCard(ambiguous.targetId!)['topic_id'], isNot(invitedImpression['topic_id']));
    expect(store.memoryPageCards(characterId: firstRole).map((row) => row['id']), contains(editingImpressionId));
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊玉兰',
          )
          .map((row) => row['id']),
      isNot(contains(editingImpressionId)),
    );
    expect(
      call(ambiguousMaking, 'fixed-shared-magnolia-forget', 'forget', {'card': ambiguous.targetId}).applied,
      isTrue,
    );
    store.closeAgentTurn(ambiguousMaking);
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊玉兰',
          )
          .map((row) => row['id']),
      contains(editingImpressionId),
    );

    // The other role can update a shared parent without rewriting this
    // private impression. An invitation cannot revive its stale reference.
    final bookChanging = begin(sayAs('fixed-book-changed-source', '我现在主要读电子书。', secondRole), [
      actualCard(book.targetId!),
    ]);
    expect(
      call(bookChanging, 'fixed-book-changed', 'remember', {
        'card': book.targetId,
        'text': '我现在主要读电子书。',
        'keywords': ['电子书'],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(bookChanging);
    expect(store.memoryPageCards(characterId: firstRole).map((row) => row['id']), isNot(contains(editingImpressionId)));
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊玉兰',
          )
          .map((row) => row['id']),
      isNot(contains(editingImpressionId)),
    );

    // These are the Scope's explicit half-open date bounds, not a claim
    // that the Owner's current October 4 window includes October 1.
    final dated = actualCard(diary.targetId!);
    store.saveManual(
      CompanionMemory(id: diary.targetId!, text: dated['text']! as String, keywords: const ['红茶']),
      expectedRowRev: dated['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    final diaryQuieting = begin(say('fixed-diary-quiet-source', '那天日记里的红茶暂时不主动聊。'), [actualCard(diary.targetId!)]);
    expect(
      call(diaryQuieting, 'fixed-diary-never', 'quiet', {'card': diary.targetId, 'mode': 'never'}).applied,
      isTrue,
    );
    store.closeAgentTurn(diaryQuieting);
    expect(actualCard(diary.targetId!)['local_day'], '2026-10-01');
    expect(
      store
          .memoryFixedLayerCards(characterId: firstRole, fromDay: '2026-09-30', beforeDay: '2026-10-02')
          .map((row) => row['id']),
      isNot(contains(diary.targetId)),
    );
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-09-30',
            beforeDay: '2026-10-02',
            explicitUserInput: '聊聊红茶',
          )
          .map((row) => row['id']),
      contains(diary.targetId),
    );
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-09-30',
            beforeDay: '2026-10-01',
            explicitUserInput: '聊聊红茶',
          )
          .map((row) => row['id']),
      isNot(contains(diary.targetId)),
    );
    expect(
      store
          .memoryFixedLayerCards(
            characterId: firstRole,
            fromDay: '2026-10-02',
            beforeDay: '2026-10-04',
            explicitUserInput: '聊聊红茶',
          )
          .map((row) => row['id']),
      isNot(contains(diary.targetId)),
    );
  });

  test('a genuinely unsent maintenance claim closes without consuming a daily permit or reopening its turn', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    say('unsent-day-source', '今天读完了一章书。');
    now += 86400000;
    expect(
      store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
        estimateContextTokens: (_) => memoryBatchInputTokens + 1,
      ),
      isNull,
    );
    expect(database.select('SELECT * FROM memory_agent_maintenance_claims'), isEmpty);
    final first = store.nextAgentMaintenance(
      kind: 'organize',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
    )!;
    final original = store.beginAgentMaintenance(kind: 'organize', claimId: first['id']! as String);
    store.finishAgentMaintenance(turnId: original['id']! as String, complete: false);
    expect(
      database.select('SELECT state FROM memory_agent_maintenance_claims WHERE id=?', [first['id']]).single['state'],
      'not_sent',
    );
    expect(call(original['id']! as String, 'late', 'remember', {'text': '旧机会不可复活'}).code, 'turn_closed');
    final second = store.nextAgentMaintenance(
      kind: 'organize',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
    )!;
    expect(second['id'], isNot(first['id']));
    final active = store.beginAgentMaintenance(kind: 'organize', claimId: second['id']! as String);
    final request = store.reserveAgentMaintenanceRequest(
      turnId: active['id']! as String,
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 100,
      outputTokens: 20,
    )!;
    store.markRequestSent(request);
    expect(
      () => store.finishAgentMaintenance(turnId: active['id']! as String, complete: false),
      throwsA(isA<DshRemoteException>()),
    );
    store.finishRequest(request, terminal: 'error');
    store.finishAgentMaintenance(turnId: active['id']! as String, complete: false);
    expect(
      store.nextAgentMaintenance(kind: 'organize', offsetMinutes: 0, estimateTokens: (text) => text.length),
      isNull,
    );
    reopen();
    expect(store.requests().single['id'], request);
    expect(store.requests().single['terminal'], 'error');
    expect(store.requests().single['raw_usage'], isNull);
    expect(store.isAgentTurnCurrent(active['id']! as String), isFalse);
    expect(store.cards(), isEmpty);
  });

  test('local exact consolidation reads evidence once and only for potentially equal cards', () {
    for (final (i, text) in ['绿茶。', '红茶。', '绿茶。', '乌龙。'].indexed) {
      final turn = begin(say('tea-$i', text));
      expect(call(turn, 'remember-$i', 'remember', {'text': text}).applied, isTrue);
      store.closeAgentTurn(turn);
    }
    var reads = 0, evidenceRows = 0;
    int? statement;
    database.trace = SqliteTraceCallback((event) {
      if (event is SqliteTraceStatement && (event.sql?.contains('SELECT s.*, m.role, m.scope, m.first_seq') ?? false)) {
        reads++;
        statement = event.statementAddress;
      } else if (event is SqliteTraceRow && event.statementAddress == statement) {
        evidenceRows++;
      } else if (event is SqliteTraceProfile && event.statementAddress == statement) {
        statement = null;
      }
      return 0;
    });
    expect(store.mergeAgentExactDuplicates(), 0);
    database.trace = null;
    expect((reads, evidenceRows), (1, 2));
  });

  test('local exact consolidation preserves shared proof alternatives and merges only one same-collection pair', () {
    final one = say('exact-one', '我住在杭州。');
    final firstTurn = begin(one);
    final target = call(firstTurn, 'first', 'remember', {
      'text': '用户住在杭州。',
      'keywords': ['住处'],
    }).targetId!;
    store.closeAgentTurn(firstTurn);
    now++;
    final two = say('exact-two', '我的住处还是杭州。');
    final secondTurn = begin(two);
    final alternate = call(secondTurn, 'alternate', 'remember', {'text': '用户住在杭州。'}).targetId!;
    store.closeAgentTurn(secondTurn);
    final mergeTurn = begin(say('confirm-same', '这两条说的是同一个住处。'), [actualCard(target), actualCard(alternate)]);
    expect(
      call(mergeTurn, 'explicit-merge', 'merge', {
        'card': target,
        'from': [alternate],
      }).applied,
      isTrue,
    );
    store.closeAgentTurn(mergeTurn);
    final claim = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final turn = store.beginAgentMaintenance(kind: 'extract', claimId: claim['id']! as String);
    for (var index = 0; index < 2; index++) {
      expect(
        call(turn['id']! as String, 'duplicate-$index', 'remember', {
          'text': '用户住在杭州。',
          'source': one['id'],
          'keywords': ['杭州'],
        }).applied,
        isTrue,
      );
    }
    final person = call(turn['id']! as String, 'different-collection', 'person', {
      'text': '用户住在杭州。',
      'aliases': ['用户'],
      'source': one['id'],
    }).targetId!;
    final personBefore = actualCard(person);
    expect(store.mergeAgentExactDuplicates(), 0, reason: 'the live captured parent gets to finish first');
    expect(store.cards(), hasLength(4));
    store.finishAgentMaintenance(turnId: turn['id']! as String, complete: true);
    expect(store.mergeAgentExactDuplicates(), 1);
    expect(store.cards(), hasLength(3), reason: 'one invocation changes only the one local pair');
    expect(actualCard(person), personBefore, reason: 'equal wording does not cross collection');
    final withAlternatives = store.cards().singleWhere(
      (row) => (row['evidence'] as List).any((proof) => (proof as MemoryRow)['message_id'] == two['id']),
    );
    final groups = <String, Set<Object?>>{};
    for (final proof in (withAlternatives['evidence'] as List).cast<MemoryRow>()) {
      (groups[proof['support_group']! as String] ??= {}).add(proof['message_id']);
    }
    expect(
      groups.values,
      unorderedEquals([
        {one['id']},
        {two['id']},
      ]),
    );
    expect(withAlternatives['keywords'], containsAll(['住处', '杭州']));
    expect(store.requests(), isEmpty);
    expect(database.select('SELECT * FROM memory_agent_maintenance_claims'), hasLength(1));
  });

  for (final day in [
    (
      name: 'spring',
      today: DateTime.utc(2026, 3, 9, 12),
      localDay: '2026-03-08',
      oldOffset: -300,
      currentOffset: -240,
      before: DateTime.utc(2026, 3, 8, 4, 30),
      early: DateTime.utc(2026, 3, 8, 5, 30),
      late: DateTime.utc(2026, 3, 9, 3, 30),
      after: DateTime.utc(2026, 3, 9, 4, 30),
    ),
    (
      name: 'autumn',
      today: DateTime.utc(2026, 11, 2, 12),
      localDay: '2026-11-01',
      oldOffset: -240,
      currentOffset: -300,
      before: DateTime.utc(2026, 11, 1, 3, 30),
      early: DateTime.utc(2026, 11, 1, 4, 30),
      late: DateTime.utc(2026, 11, 2, 4, 30),
      after: DateTime.utc(2026, 11, 2, 5, 30),
    ),
  ]) {
    test('ADD49 ${day.name} diary selects and validates the original source offset', () {
      now = day.today.millisecondsSinceEpoch;
      MemoryRow put(String messageId, String text, DateTime at, int offset) => store.submitMessage(
        id: messageId,
        sessionId: 'light:agent',
        text: text,
        saidAtUtc: at.millisecondsSinceEpoch,
        offsetMinutes: offset,
      );
      put('outside-before', '前一天的话。', day.before, day.oldOffset);
      final early = put('day-early', '当天一早的话。', day.early, day.oldOffset);
      final late = put('day-late', '当天晚间的话。', day.late, day.currentOffset);
      put('outside-after', '第二天的话。', day.after, day.currentOffset);
      final claim = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: day.currentOffset,
        estimateTokens: (text) => text.length,
      )!;
      final turn = store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String);
      expect(turn['local_day'], day.localDay);
      final sources = (turn['sources'] as List).cast<MemoryRow>();
      expect(sources.map((source) => source['id']), [early['id'], late['id']]);
      for (final original in [early, late]) {
        final captured = sources.singleWhere((source) => source['id'] == original['id']);
        expect(captured['said_at_utc'], original['said_at_utc']);
        expect(captured['offset_minutes'], original['offset_minutes']);
      }
      // Use the early source alone: autumn's 00:30 would be rejected as the
      // previous day if the diary validator still used today's new offset.
      final written = call(turn['id']! as String, 'write-local-day', 'diary', {
        'text': '当天一早的记录。',
        'source': early['id'],
      });
      expect(written.applied, isTrue);
      store.finishAgentMaintenance(turnId: turn['id']! as String, complete: true);
      reopen();
      final diary = actualCard(written.targetId!);
      expect(diary['local_day'], day.localDay);
      expect(diary['day_zone_id'], 'offset:${day.currentOffset}');
      final proof = (diary['evidence'] as List).single as MemoryRow;
      expect(proof['message_id'], early['id']);
      expect(proof['said_at_utc'], early['said_at_utc']);
      expect(proof['offset_minutes'], day.oldOffset);
    });
  }

  test(
    'a new diary needs its real target-day source while a controlled old-diary rewrite keeps its original day and proof',
    () {
      now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
      final original = say('old-day-source', '我住在杭州，也喜欢红茶。');
      final initial = begin(original);
      final location = call(initial, 'location', 'remember', {'text': '住在杭州'}).targetId!;
      store.closeAgentTurn(initial);
      now += 86400000;
      final claim = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      final turn = store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String);
      grantMaintenance(turn);
      final before = store.archive['memory_revision'];
      expect(
        call(turn['id']! as String, 'references-only', 'diary', {
          'text': '仅凭旧卡不能填写当天发生了什么。',
          'references': [location],
        }).code,
        'diary_day_source_required',
      );
      expect(store.archive['memory_revision'], before);
      expect(store.cards(), hasLength(1));
      final diary = call(turn['id']! as String, 'real-day', 'diary', {
        'text': '住在杭州，也喜欢红茶。',
        'source': original['id'],
      }).targetId!;
      expect(actualCard(diary)['local_day'], '2026-10-01');
      expect(actualCard(diary)['keywords'], ['住在杭州，也喜欢红茶。']);
      store.finishAgentMaintenance(turnId: turn['id']! as String, complete: true);
      final control = say('later-control', '不要记住我的住处，喜欢红茶这件事保留。');
      now += 86400000;
      final nextClaim = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      final next = store.beginAgentMaintenance(kind: 'organize', claimId: nextClaim['id']! as String);
      grantMaintenance(next);
      expect(next['local_day'], '2026-10-02');
      expect(
        call(next['id']! as String, 'retain-tea', 'forget', {
          'changes': [
            {'card': location, 'forget': true},
            {'card': diary, 'text': '喜欢红茶。'},
          ],
        }).applied,
        isTrue,
      );
      final retained = actualCard(diary);
      expect(retained['text'], '喜欢红茶。');
      expect(retained['keywords'], ['喜欢红茶。']);
      expect(retained['local_day'], '2026-10-01');
      expect(retained['day_zone_id'], 'offset:0');
      expect((retained['evidence'] as List).map((proof) => (proof as MemoryRow)['message_id']), [original['id']]);
      expect(
        (retained['evidence'] as List).any((proof) => (proof as MemoryRow)['message_id'] == control['id']),
        isFalse,
      );
      expect(store.cards().map((row) => row['id']), [diary]);
      final fresh = store.beginAgentMaintenance(kind: 'organize', claimId: nextClaim['id']! as String);
      expect(fresh['id'], next['id']);
      expect(fresh['closed'], 0);
      expect(fresh['sources'], isEmpty, reason: 'the same live claim uses the new history cutoff');
      final visible = (fresh['cards'] as List<MemoryRow>).single;
      expect(visible['id'], diary);
      expect(visible['row_rev'], retained['row_rev']);
      expect(visible['text'], '喜欢红茶。');
      expect(visible['keywords'], ['喜欢红茶。']);
      expect(jsonEncode(fresh), isNot(contains('杭州')));
      expect(visible['local_day'], retained['local_day']);
      expect(visible['evidence'], isEmpty, reason: 'the retained local proof still contains the forgotten address');
      grantMaintenance(fresh);
      expect(store.isAgentTurnCurrent(next['id']! as String), isTrue);
      expect(actualCard(diary), retained, reason: 'context projection and actual grants do not rewrite local proof');
      expect(store.messages().singleWhere((row) => row['id'] == original['id'])['text'], original['text']);
    },
  );

  test(
    'an unsent role after a sent shared scope interrupts the parent and resumes only that unserved role in a new parent',
    () {
      now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
      final role = character('local:unserved-role');
      final source = sayAs('unserved-source', '今天一起谈了散步。', role);
      now += 86400000;
      final first = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      final shared = store.beginAgentMaintenance(kind: 'organize', claimId: first['id']! as String);
      final request = store.reserveAgentMaintenanceRequest(
        turnId: shared['id']! as String,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 100,
        outputTokens: 10,
      )!;
      observed(request);
      store.finishAgentMaintenance(turnId: shared['id']! as String, complete: true);
      final untouched = store.beginAgentMaintenance(
        kind: 'organize',
        claimId: first['id']! as String,
        characterId: role,
      );
      store.finishAgentMaintenance(turnId: untouched['id']! as String, complete: false);
      final old = database.select('SELECT state,completed_scopes FROM memory_agent_maintenance_claims WHERE id=?', [
        first['id'],
      ]).single;
      expect(old['state'], 'interrupted');
      expect(jsonDecode(old['completed_scopes'] as String), ['']);
      expect(store.isAgentTurnCurrent(untouched['id']! as String), isFalse);
      expect(
        store.nextAgentMaintenance(kind: 'organize', offsetMinutes: 0, estimateTokens: (text) => text.length),
        isNull,
      );
      now += 86400000;
      reopen();
      final next = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      expect(next['id'], isNot(first['id']));
      expect(next['scope_characters'], [role]);
      final live = store.beginAgentMaintenance(kind: 'organize', claimId: next['id']! as String, characterId: role);
      expect(live['id'], isNot(untouched['id']));
      expect((live['sources'] as List).map((row) => (row as MemoryRow)['id']), [source['id']]);
      expect(call(untouched['id']! as String, 'no-reopen', 'remember', {'text': '不能重开旧机会。'}).code, 'turn_closed');
      final nextRequest = store.reserveAgentMaintenanceRequest(
        turnId: live['id']! as String,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 100,
        outputTokens: 10,
      )!;
      observed(nextRequest);
      expect(
        call(live['id']! as String, 'real-impression', 'impression', {
          'text': '用户愿意分享一起散步的日常。',
          'source': source['id'],
        }).applied,
        isTrue,
      );
      store.finishAgentMaintenance(turnId: live['id']! as String, complete: true);
      now += 86400000;
      reopen();
      expect(
        store.nextAgentMaintenance(kind: 'organize', offsetMinutes: 0, estimateTokens: (text) => text.length),
        isNull,
      );
      expect(store.requests().map((row) => row['id']), unorderedEquals([request, nextRequest]));
    },
  );

  test(
    'cold interrupted organization consumes its served source scope without marking a later card revision or an unserved role',
    () {
      now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
      final role = character('local:cold-organize');
      final source = sayAs('cold-organize-source', '今天聊过练琴。', role);
      final card = seed('偏好简洁的说明。');
      now += 86400000;
      final claim = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      final turn = store.beginAgentMaintenance(kind: 'organize', claimId: claim['id']! as String);
      grantMaintenance(turn);
      final request = store.reserveAgentMaintenanceRequest(
        turnId: turn['id']! as String,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 100,
        outputTokens: 10,
      )!;
      store.markRequestUncertain(request);
      store.setPinned(id: card['id']! as String, expectedRowRev: card['row_rev']! as int, pinned: true);
      reopen();
      expect(store.requests().single['terminal'], 'dispatch_unknown');
      final changed = actualCard(card['id']! as String);
      expect(changed['row_rev'], (card['row_rev']! as int) + 1);
      expect(
        changed['maintenance_row_rev'],
        isNot(changed['row_rev']),
        reason: 'the old captured revision cannot consume a new edit',
      );
      expect(
        jsonDecode(
          database.select('SELECT completed_scopes FROM memory_agent_maintenance_claims WHERE id=?', [
                claim['id'],
              ]).single['completed_scopes']
              as String,
        ),
        [''],
      );
      now += 86400000;
      final next = store.nextAgentMaintenance(
        kind: 'organize',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
      )!;
      expect(next['scope_characters'], [null, role]);
      final shared = store.beginAgentMaintenance(kind: 'organize', claimId: next['id']! as String);
      expect(shared['sources'], isEmpty, reason: 'old role material cannot become a new shared diary day');
      grantMaintenance(shared);
      store.finishAgentMaintenance(turnId: shared['id']! as String, complete: true);
      final pending = store.beginAgentMaintenance(kind: 'organize', claimId: next['id']! as String, characterId: role);
      expect((pending['sources'] as List).map((row) => (row as MemoryRow)['id']), [source['id']]);
      expect(store.requests(), hasLength(1));
    },
  );

  test('scoped followup selection skips a failed candidate without asking it or crossing character invitations', () {
    final firstRole = character('local:followup-first');
    final secondRole = character('local:followup-second');
    final first = seed('修琴进度');
    final next = seed('烧杯进度');
    final elsewhere = seed('别处的安排');
    final one = begin(sayAs('first-invite', '之后再聊这两件事。', firstRole), [first, next]);
    final firstId = call(one, 'later-a', 'ask_later', {'card': first['id'], 'whenMs': now}).targetId!;
    final nextId = call(one, 'later-b', 'ask_later', {'card': next['id'], 'whenMs': now + 1}).targetId!;
    store.closeAgentTurn(one);
    final two = begin(sayAs('other-invite', '之后聊别处。', secondRole), [elsewhere]);
    final otherId = call(two, 'other', 'ask_later', {'card': elsewhere['id'], 'whenMs': now}).targetId!;
    now += 2;
    final chosen = store.nextAgentFollowup(nowMs: now, characterId: firstRole)!;
    expect(chosen['id'], firstId);
    expect(store.nextAgentFollowup(nowMs: now, characterId: firstRole, excludedIds: {firstId})!['id'], nextId);
    expect(store.nextAgentFollowup(nowMs: now, characterId: secondRole)!['id'], otherId);
    expect(store.nextAgentFollowup(nowMs: now, characterId: null), isNull);
    expect(store.isAgentFollowupCurrent(chosen, nowMs: now, characterId: secondRole), isFalse);
    expect(store.followups().every((row) => row['state'] == 'pending' && row['presented_at_ms'] == null), isTrue);
    expect(database.select('SELECT * FROM memory_initiative_spends'), isEmpty);
  });

  test('semantic relationship facts require an actual shown ticket and never reopen a settled day', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    final role = character('local:dialogue');
    final assistant = sayAs('real-question', '想听听你的今天。', role, role: 'assistant');
    store.recordCompanionPresentation(
      characterId: role,
      presentationId: 'display-one',
      kind: 'assistant',
      presentedAtMs: now,
      assistantSourceId: assistant['id']! as String,
    );
    now += 1000;
    final answer = sayAs('real-answer', '今天工作很累，后来休息了一会儿。', role);
    store.recordCompanionInteraction(
      characterId: role,
      eventId: 'chat-one',
      kind: 'chat',
      atMs: now,
      offsetMinutes: 0,
      sourceId: answer['id']! as String,
    );
    final claim = store.nextAgentMaintenance(
      kind: 'extract',
      offsetMinutes: 0,
      estimateTokens: (text) => text.length,
      forceTail: true,
    )!;
    final active = store.beginAgentMaintenance(kind: 'extract', claimId: claim['id']! as String, characterId: role);
    final turn = active['id']! as String;
    expect((active['sources'] as List).map((row) => (row as MemoryRow)['id']), [assistant['id'], answer['id']]);
    expect((active['presentations'] as List).single, containsPair('id', 'display-one'));
    expect(
      call(turn, 'fake-display', 'relationship', {
        'kind': 'answered_question',
        'source': answer['id'],
        'presentation': 'not-shown',
      }).code,
      'presentation_not_in_turn',
    );
    expect(database.select("SELECT * FROM memory_affinity_events WHERE kind='answered_question'"), isEmpty);
    expect(
      call(turn, 'actual-answer', 'relationship', {
        'kind': 'answered_question',
        'source': answer['id'],
        'presentation': 'display-one',
      }).applied,
      isTrue,
    );
    expect(
      call(turn, 'same-answer', 'relationship', {
        'kind': 'answered_question',
        'source': answer['id'],
        'presentation': 'display-one',
      }).applied,
      isTrue,
    );
    expect(database.select('SELECT kind FROM memory_affinity_presentations').single['kind'], 'question');
    expect(database.select('SELECT answer_count FROM memory_affinity_days').single['answer_count'], 1);
    store.recordCompanionPresentation(
      characterId: role,
      presentationId: 'display-one',
      kind: 'assistant',
      presentedAtMs: assistant['said_at_utc']! as int,
      assistantSourceId: assistant['id']! as String,
    );
    now = DateTime.utc(2026, 10, 2, 12).millisecondsSinceEpoch;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    final settled = store.companionAffinity(characterId: role);
    expect(
      call(turn, 'late-classification', 'relationship', {'kind': 'confiding', 'source': answer['id']}).code,
      'affinity_day_settled',
    );
    expect(store.companionAffinity(characterId: role), settled);
    expect(database.select("SELECT * FROM memory_affinity_events WHERE kind='confiding'"), isEmpty);
    store.finishAgentMaintenance(turnId: turn, complete: true);
  });

  test(
    'schema15 upgrade preserves actual chat calls and accepted task location while adding closed maintenance lanes',
    () {
      final source = say('old-source', '记下红茶，也提醒喝水。');
      final turn = begin(source);
      final remembered = call(turn, 'memory', 'remember', {'text': '喜欢红茶'});
      final pending = store.reserveAgentTaskCall(
        turnId: turn,
        callId: 'task',
        toolName: 'reminder',
        input: {'text': '喝水'},
      );
      final task = store.createReminderFromMessage(
        messageId: 'old-source',
        expectedSourceRev: 1,
        itemNo: pending.itemNo,
        roomMode: 'light',
        executorId: 'phone',
        reminder: const CompanionReminderSpec(text: '喝水', waitReason: 'date_missing'),
      );
      store.finishAgentTaskCall(turnId: turn, callId: 'task', taskId: task['task_id']! as String);
      final beforeCard = store.cards();
      final beforeCalls = [
        for (final row in database.select('SELECT * FROM memory_agent_calls ORDER BY item_no')) {...row},
      ];
      final archive = store.archive;
      restoreOldMemorySchema(database, 15);
      expect(database.select('PRAGMA user_version').single['user_version'], 15);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      reopen();
      expect(database.select('PRAGMA user_version').single['user_version'], 17);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      expect(store.archive, archive);
      expect(store.cards(), beforeCard);
      expect([
        for (final row in database.select('SELECT * FROM memory_agent_calls ORDER BY item_no')) {...row},
      ], beforeCalls);
      expect(store.agentToolCall(turnId: turn, callId: 'memory')!.targetId, remembered.targetId);
      expect(store.agentToolCall(turnId: turn, callId: 'task')!.taskId, task['task_id']);
      expect(store.taskForCommand('old-source', pending.itemNo), task);
      expect(
        store.beginAgentTurn(messageId: 'old-source', expectedSourceRev: 1, shownCardRevisions: const {})['closed'],
        1,
      );
      expect(database.select('SELECT * FROM memory_agent_maintenance_claims'), isEmpty);
    },
  );

  test('actual presence and source facts settle once, keep today open and recover without bypassing the daily cap', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    final day = now;
    final role = character('local:affinity');
    for (var index = 0; index < 8; index++) {
      final source = sayAs('chat-$index', '今天第 $index 次真正发送。', role);
      store.recordCompanionInteraction(
        characterId: role,
        eventId: 'chat-$index',
        kind: 'chat',
        atMs: now,
        offsetMinutes: 0,
        sourceId: source['id']! as String,
      );
    }
    store.recordCompanionInteraction(
      characterId: role,
      eventId: 'retry-same-source',
      kind: 'chat',
      atMs: now,
      offsetMinutes: 0,
      sourceId: 'chat-0',
    );
    store.recordCompanionPresence(
      characterId: role,
      segmentId: 'visible',
      startedAtMs: now,
      elapsedMs: 1800000,
      offsetMinutes: 0,
    );
    store.recordCompanionPresence(
      characterId: role,
      segmentId: 'visible',
      startedAtMs: now,
      elapsedMs: 3600000,
      offsetMinutes: 0,
    );
    store.recordCompanionPresence(
      characterId: role,
      segmentId: 'visible',
      startedAtMs: now,
      elapsedMs: 3600000,
      offsetMinutes: 0,
    );
    for (final kind in ['pet', 'snack', 'play']) {
      for (var index = 0; index < 3; index++) {
        store.recordCompanionInteraction(
          characterId: role,
          eventId: '$kind-$index',
          kind: kind,
          atMs: now,
          offsetMinutes: 0,
        );
      }
    }
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role)!['score_milli'], 0);
    now = day + 86400000;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role)!['score_milli'], 6775);
    expect(
      database.select('SELECT companionship_ms,chat_turns FROM memory_affinity_days').single,
      containsPair('companionship_ms', 3600000),
    );
    expect(database.select('SELECT chat_turns FROM memory_affinity_days').single['chat_turns'], 8);
    final once = store.companionAffinity(characterId: role);
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role), once);
    now = day + 6 * 86400000;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role)!['score_milli'], 2775);
    final returning = sayAs('returning', '我回来啦。', role);
    store.recordCompanionInteraction(
      characterId: role,
      eventId: 'returning',
      kind: 'chat',
      atMs: now,
      offsetMinutes: 0,
      sourceId: returning['id']! as String,
    );
    now += 86400000;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    final recovered = store.companionAffinity(characterId: role)!;
    expect(recovered['score_milli'], 4561);
    expect(recovered['peak_milli'], 6775);
    expect(recovered['floor_milli'], 0);
  });

  test('legacy phone and first Host seeds adjust one role by max-delta without erasing earned activity', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    final role = character('local:legacy-owner');
    final other = character('local:new-character');
    expect(
      store.importCompanionAffinity(
        characterId: role,
        sourceKind: 'phone',
        sourceId: 'one-phone-slot',
        closeness: .1,
        observedAtMs: now,
        offsetMinutes: 0,
      ),
      isTrue,
    );
    expect(store.companionAffinity(characterId: role)!['first_met_ms'], isNull);
    final source = sayAs('real-after-import', '真正的今天。', role);
    store.recordCompanionInteraction(
      characterId: role,
      eventId: 'after-import',
      kind: 'chat',
      atMs: now,
      offsetMinutes: 0,
      sourceId: source['id']! as String,
    );
    now += 86400000;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role)!['score_milli'], 100550);
    expect(
      store.importCompanionAffinity(
        characterId: role,
        sourceKind: 'host',
        sourceId: 'first-host-store',
        closeness: .2,
        observedAtMs: now,
        offsetMinutes: 0,
      ),
      isTrue,
    );
    final updated = store.companionAffinity(characterId: role)!;
    expect(updated['score_milli'], 200550);
    expect(updated['peak_milli'], 200550);
    expect(updated['tier'], 2);
    expect(updated['floor_milli'], 100000);
    expect(
      store.importCompanionAffinity(
        characterId: role,
        sourceKind: 'host',
        sourceId: 'different-host-store',
        closeness: .9,
        observedAtMs: now,
        offsetMinutes: 0,
      ),
      isFalse,
    );
    expect(
      store.importCompanionAffinity(
        characterId: other,
        sourceKind: 'phone',
        sourceId: 'one-phone-slot',
        closeness: .1,
        observedAtMs: now,
        offsetMinutes: 0,
      ),
      isFalse,
    );
    expect(store.companionAffinity(characterId: role), updated);
    expect(store.companionAffinity(characterId: other), isNull);
    final seeds = database.select(
      'SELECT old_seed_milli,new_seed_milli FROM memory_affinity_legacy_sources WHERE source_kind=?',
      ['host'],
    ).single;
    expect(seeds['old_seed_milli'], 100000);
    expect(seeds['new_seed_milli'], 200000);
    expect(database.select('SELECT COUNT(*) AS n FROM memory_affinity_days').single['n'], 1);
  });

  test(
    'incomplete dispatched maintenance retires only its exact source events and preserves unknown usage on cold open',
    () {
      final firstRole = character('local:interrupted-first');
      final secondRole = character('local:interrupted-second');
      final first = sayAs('first-pending', '第一位的原话。', firstRole);
      final second = sayAs('second-pending', '第二位的旧原话。', secondRole);
      final claim = store.nextAgentMaintenance(
        kind: 'extract',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
        forceTail: true,
      )!;
      final active = store.beginAgentMaintenance(
        kind: 'extract',
        claimId: claim['id']! as String,
        characterId: firstRole,
      );
      final request = store.reserveAgentMaintenanceRequest(
        turnId: active['id']! as String,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 200,
        outputTokens: 20,
      )!;
      store.markRequestSent(request);
      store.finishRequest(request, terminal: 'error');
      store.finishAgentMaintenance(turnId: active['id']! as String, complete: false);
      final retired = database.select('SELECT state,reason FROM memory_events WHERE seq=?', [
        first['event_seq'],
      ]).single;
      expect(retired['state'], 'skipped');
      expect(retired['reason'], 'maintenance_incomplete');
      expect(
        database.select('SELECT state FROM memory_events WHERE seq=?', [second['event_seq']]).single['state'],
        'pending',
      );
      final edited = store.editMessage(id: second['id']! as String, expectedSourceRev: 1, text: '第二位真正修改后的新原话。');
      final retry = store.nextAgentMaintenance(
        kind: 'extract',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
        forceTail: true,
      )!;
      final next = store.beginAgentMaintenance(
        kind: 'extract',
        claimId: retry['id']! as String,
        characterId: secondRole,
      );
      expect((next['sources'] as List).map((row) => (row as MemoryRow)['id']), [second['id']]);
      expect((next['sources'] as List).single, containsPair('source_rev', 2));
      final uncertain = store.reserveAgentMaintenanceRequest(
        turnId: next['id']! as String,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 200,
        outputTokens: 20,
      )!;
      store.markRequestUncertain(uncertain);
      reopen();
      expect(
        database.select('SELECT state,reason FROM memory_events WHERE seq=?', [edited['event_seq']]).single,
        containsPair('reason', 'maintenance_incomplete'),
      );
      expect(
        database.select('SELECT state FROM memory_events WHERE seq=?', [second['event_seq']]).single['state'],
        'superseded',
      );
      expect(
        store.nextAgentMaintenance(
          kind: 'extract',
          offsetMinutes: 0,
          estimateTokens: (text) => text.length,
          forceTail: true,
        ),
        isNull,
      );
      expect(store.requests().singleWhere((row) => row['id'] == uncertain)['terminal'], 'dispatch_unknown');
      expect(store.requests().singleWhere((row) => row['id'] == request)['terminal'], 'error');
      expect(store.messages().singleWhere((row) => row['id'] == first['id'])['text'], first['text']);
      expect(store.messages().singleWhere((row) => row['id'] == second['id'])['text'], edited['text']);
      expect(store.cards(), isEmpty);
    },
  );

  test('legacy seed without activity grants only three completed absence days before the first decay', () {
    now = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
    final role = character('local:seed-without-activity');
    expect(
      store.importCompanionAffinity(
        characterId: role,
        sourceKind: 'phone',
        sourceId: 'phone-only',
        closeness: .105,
        observedAtMs: now,
        offsetMinutes: 0,
      ),
      isTrue,
    );
    expect(database.select('SELECT * FROM memory_affinity_days'), isEmpty);
    now = DateTime.utc(2026, 10, 4, 12).millisecondsSinceEpoch;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role)!['score_milli'], 105000);
    expect(store.companionAffinity(characterId: role)!['settled_through_day'], '2026-10-03');
    now = DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch;
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    final afterFourth = store.companionAffinity(characterId: role)!;
    expect(afterFourth['score_milli'], 103000);
    expect(afterFourth['peak_milli'], 105000);
    expect(afterFourth['floor_milli'], 100000);
    expect(afterFourth['first_met_ms'], isNull);
    expect(database.select('SELECT * FROM memory_affinity_days'), isEmpty);
    store.settleCompanionAffinity(nowMs: now, offsetMinutes: 0);
    expect(store.companionAffinity(characterId: role), afterFourth);
  });
}
