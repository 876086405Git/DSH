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
  MemoryRow seed(String text) {
    final cardId = id();
    store.saveManual(
      CompanionMemory(id: cardId, text: text),
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
    final accepted = call(next, 'forget-home', 'forget', {'card': home['id']});
    expect(accepted.applied, isTrue);
    expect(accepted.changedCardIds, hasLength(3));
    expect(store.cards(), [cat]);
    expect((store.cards().single['evidence'] as List).single, containsPair('quote', original['text']));
    expect(store.messages().where((row) => row['id'] == 'original').single['text'], original['text']);
    expect(database.select('SELECT * FROM memory_deleted_messages'), isEmpty);
  });

  test('an external control invalidates the turn and recall alone grants no write permission', () {
    final card = seed('我喜欢蓝色');
    final source = say('source', '说说蓝色。');
    final turn = begin(source);
    expect(call(turn, 'read', 'recall', {'query': '蓝色'}).applied, isTrue);
    expect(call(turn, 'unseen', 'revise', {'card': card['id'], 'text': '我喜欢绿色'}).code, 'card_not_in_turn');
    store.grantAgentCards(turnId: turn, cardRevisions: {card['id']! as String: card['row_rev']! as int});
    store.saveManual(
      CompanionMemory(id: card['id']! as String, text: '我喜欢橙色'),
      expectedRowRev: card['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(call(turn, 'late', 'revise', {'card': card['id'], 'text': '旧请求的绿色'}).code, 'control_changed');
    expect(store.cards().single['text'], '我喜欢橙色');
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
    expect(database.select('PRAGMA user_version').single['user_version'], 15);
    expect(store.cards(), [card]);
    expect(store.archive, before);
    expect(database.select('SELECT * FROM memory_agent_turns'), isEmpty);
    expect(database.select('SELECT * FROM memory_agent_calls'), isEmpty);
  });
}
