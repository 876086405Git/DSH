import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

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
  });

  for (final mode in const ['less', 'never']) {
    test('a remembered shared topic keeps $mode across reopen without quieting another clause', () {
      final first = begin(say('controlled-first', '我在周末骑行。'));
      final saved = call(first, 'remember-first', 'remember', {
        'text': '你在周末骑行。',
        'keywords': ['骑行'],
      });
      expect(saved.applied, isTrue);
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
    expect(database.select('PRAGMA user_version').single['user_version'], 16);
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
    store.closeAgentTurn(turn);
    final row = store.memoryPageCards(characterId: role).single;
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
      expect(database.select('PRAGMA user_version').single['user_version'], 16);
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
