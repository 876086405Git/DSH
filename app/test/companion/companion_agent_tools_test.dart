import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory root;
  late CompanionMemoryOwner memory;
  var sequence = 0;
  const now = 1800000000000;
  String nextId() => '00000000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}';
  MemoryRow say(String messageId, String text) =>
      memory.store.submitMessage(id: messageId, sessionId: 'light:tools', text: text, saidAtUtc: now, offsetMinutes: 0);
  MemoryRow seed() {
    final cardId = nextId();
    memory.store.saveManual(
      CompanionMemory(id: cardId, text: '我喜欢蓝色', keywords: const ['蓝色']),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    return memory.store.cards().single;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('companion-agent-tools-');
    sequence = 0;
    memory = CompanionMemoryOwner(
      CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now, createId: nextId),
      CompanionLocal.at(root, nowMilliseconds: () => now),
      nowMilliseconds: () => now,
    );
  });
  tearDown(() async {
    memory.dispose();
    await root.delete(recursive: true);
  });

  test('the bound executor confirms the actual own commit before notifying the shared owner', () async {
    final card = seed();
    final source = say('source', '蓝色现在有了不同的意义。');
    final before = memory.store.archive['control_revision']! as int;
    var known = before;
    final events = <Map<String, Object?>>[];
    final tools = CompanionAgentMemoryTools(
      memory: memory,
      source: source,
      isCurrent: () => true,
      forgottenNotice: '好，忘掉了。',
      onCommitted: ({required memory, required sourceId, required beforeRevision, required revision}) {
        events.add({
          'event': 'confirm',
          'memory': memory,
          'sourceId': sourceId,
          'before': beforeRevision,
          'after': revision,
        });
        known = revision;
      },
    );
    memory.addListener(() {
      events.add({'event': 'changed', 'actual': memory.store.archive['control_revision'], 'known': known});
    });
    tools.grantSelection(memory.select('蓝色'));
    final binding = tools.bindings.singleWhere((entry) => entry.definition.name == 'revise');
    final result = await binding.execute(
      CompanionAgentToolCall(
        id: 'edit',
        name: 'revise',
        input: {
          'card': card['id'],
          'text': '我喜欢深蓝色',
          'keywords': ['蓝色'],
        },
      ),
    );
    expect(result.isError, isFalse);
    expect(result.notice, isNull);
    expect(events, [
      {'event': 'confirm', 'memory': memory, 'sourceId': 'source', 'before': before, 'after': before + 1},
      {'event': 'changed', 'actual': before + 1, 'known': before + 1},
    ]);
    expect(tools.isCurrent, isTrue);
    expect(memory.store.cards().single['text'], '我喜欢深蓝色');
    final edited = memory.store.cards().single;
    memory.store.saveManual(
      CompanionMemory(id: card['id']! as String, text: '我现在喜欢绿色'),
      expectedRowRev: edited['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    final late = await binding.execute(
      CompanionAgentToolCall(id: 'late', name: 'revise', input: {'card': card['id'], 'text': '旧的蓝色'}),
    );
    expect(late.isError, isTrue);
    expect(jsonDecode(late.content), containsPair('applied', false));
    expect(memory.store.cards().single['text'], '我现在喜欢绿色');
    expect(events, hasLength(2));
    tools.close();
  });

  test('recall grants returned IDs and successful deletion supplies a natural notice', () async {
    final card = seed();
    final source = say('source', '那件事暂时不用保留了。');
    final commits = <int>[];
    final tools = CompanionAgentMemoryTools(
      memory: memory,
      source: source,
      isCurrent: () => true,
      forgottenNotice: '好，忘掉了。',
      onCommitted: ({required memory, required sourceId, required beforeRevision, required revision}) =>
          commits.add(revision),
    );
    expect(tools.bindings.map((entry) => entry.definition.name), [
      'remember',
      'forget',
      'revise',
      'related',
      'merge',
      'person',
      'quiet',
      'cancel',
      'postpone',
      'ask_later',
      'recall',
    ]);
    final forget = tools.bindings.singleWhere((entry) => entry.definition.name == 'forget').execute;
    final refused = await forget(CompanionAgentToolCall(id: 'unseen', name: 'forget', input: {'card': card['id']}));
    expect(refused.isError, isTrue);
    expect(refused.content, contains('not applied'));
    expect(refused.notice, isNull);
    expect(memory.store.cards(), [card]);
    final recall = tools.bindings.singleWhere((entry) => entry.definition.name == 'recall').execute;
    final recalled = await recall(const CompanionAgentToolCall(id: 'recall', name: 'recall', input: {'query': '蓝色'}));
    final selection = (jsonDecode(recalled.content) as Map)['selection'] as Map;
    expect((selection['items'] as List).single, containsPair('id', card['id']));
    expect(commits, isEmpty);
    final accepted = await forget(CompanionAgentToolCall(id: 'forget', name: 'forget', input: {'card': card['id']}));
    expect(accepted.isError, isFalse);
    expect(accepted.notice, '好，忘掉了。');
    expect(jsonDecode(accepted.content), containsPair('changedCardIds', [card['id']]));
    expect(memory.store.cards(), isEmpty);
    expect(memory.store.messages().single['text'], source['text']);
    expect(commits, hasLength(1));
    final replay = await forget(CompanionAgentToolCall(id: 'forget', name: 'forget', input: {'card': card['id']}));
    expect(jsonDecode(replay.content), containsPair('replayed', true));
    expect(commits, hasLength(1));
    tools.close();
  });

  test('an awaited semantic rank rechecks the actual turn and never falls back after cancellation', () async {
    final card = seed();
    final source = say('source-rank', '蓝色那条先看一下。');
    final held = Completer<List<String>?>();
    var queries = 0;
    final tools = CompanionAgentMemoryTools(
      memory: memory,
      source: source,
      isCurrent: () => true,
      forgottenNotice: '好，忘掉了。',
      semanticRecall: (query) {
        queries++;
        return held.future;
      },
      onCommitted: ({required memory, required sourceId, required beforeRevision, required revision}) {},
    );
    final pending = tools.execute(const CompanionAgentToolCall(id: 'rank', name: 'recall', input: {'query': '蓝色'}));
    expect(queries, 1);
    memory.store.saveManual(
      CompanionMemory(id: card['id']! as String, text: '现在改成绿色'),
      expectedRowRev: card['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    held.complete([card['id']! as String]);
    final stale = await pending;
    expect(stale.isError, isTrue);
    expect(jsonDecode(stale.content), containsPair('code', 'turn_not_current'));
    expect(memory.store.agentToolCall(turnId: tools.turnId, callId: 'rank'), isNull);
    expect(memory.store.cards().single['text'], '现在改成绿色');
    tools.close();
    final cancelled = CompanionAgentMemoryTools(
      memory: memory,
      source: say('cancelled-rank', '再看看绿色。'),
      isCurrent: () => true,
      forgottenNotice: '好，忘掉了。',
      semanticRecall: (_) => Future<List<String>?>.error(StateError('retrieval cancelled')),
      onCommitted: ({required memory, required sourceId, required beforeRevision, required revision}) {},
    );
    final failed = await cancelled.execute(
      const CompanionAgentToolCall(id: 'fail', name: 'recall', input: {'query': '绿色'}),
    );
    expect(failed.isError, isTrue);
    expect(jsonDecode(failed.content), containsPair('code', 'recall_unavailable'));
    expect(memory.store.agentToolCall(turnId: cancelled.turnId, callId: 'fail'), isNull);
    cancelled.close();
  });

  test(
    'the actual maintenance adapter confirms its claim before changed and gives one physical receipt per round',
    () async {
      final source = say('actual-maintenance-source', '用户喜欢安静喝红茶。');
      final claim = memory.store.nextAgentMaintenance(
        kind: 'extract',
        offsetMinutes: 0,
        estimateTokens: (text) => text.length,
        forceTail: true,
      )!;
      final turn = memory.store.beginAgentMaintenance(kind: 'extract', claimId: claim['id']! as String);
      final before = memory.store.archive['control_revision']! as int;
      var known = before;
      final events = <MemoryRow>[];
      final tools = CompanionAgentMemoryTools.maintenance(
        memory: memory,
        turn: turn,
        isCurrent: () => true,
        forgottenNotice: '好，忘掉了。',
        onMaintenanceCommitted: ({required memory, required turnId, required beforeRevision, required revision}) {
          events.add({
            'event': 'confirm',
            'turn': turnId,
            'before': beforeRevision,
            'known': known,
            'after': revision,
            'current': memory.store.isAgentTurnCurrent(turnId),
          });
          known = revision;
        },
      );
      memory.addListener(() {
        events.add({'event': 'changed', 'actual': memory.store.archive['control_revision'], 'known': known});
      });
      tools.grantCards((turn['cards'] as List).cast<MemoryRow>());
      expect(tools.bindings.any((item) => item.definition.name == 'diary'), isFalse);
      expect(tools.bindings.any((item) => item.definition.name == 'relationship'), isFalse);
      final request = memory.store.reserveAgentMaintenanceRequest(
        turnId: tools.turnId,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 200,
        outputTokens: 30,
      )!;
      memory.store.markRequestSent(request);
      memory.store.recordUsage(request, {
        'input_uncached': 180,
        'input_cache_read': 0,
        'input_cache_write': 0,
        'output_tokens': 20,
        'usage_semantics': 'provider_raw',
      });
      memory.store.finishRequest(request, terminal: 'complete');
      final result = await tools.execute(
        CompanionAgentToolCall(
          id: 'remember',
          name: 'remember',
          input: {
            'text': '用户喜欢安静喝红茶。',
            'source': source['id'],
            'keywords': ['红茶'],
          },
        ),
      );
      expect(result.isError, isFalse);
      expect(events, [
        {
          'event': 'confirm',
          'turn': turn['id'],
          'before': before,
          'known': before,
          'after': before + 1,
          'current': true,
        },
        {'event': 'changed', 'actual': before + 1, 'known': before + 1},
      ]);
      expect(tools.isCurrent, isTrue);
      final again = memory.store.reserveAgentMaintenanceRequest(
        turnId: tools.turnId,
        provider: 'deepseek',
        model: 'deepseek-flash',
        inputTokens: 220,
        outputTokens: 30,
      )!;
      expect(again, isNot(request));
      memory.store.finishRequest(again, terminal: 'not_sent');
      memory.store.finishAgentMaintenance(turnId: tools.turnId, complete: true);
      tools.close();
      expect(memory.store.requests().map((row) => row['id']), unorderedEquals([request, again]));
      expect(memory.store.requests().singleWhere((row) => row['id'] == request)['output_tokens'], 20);
      expect(
        memory.store.nextAgentMaintenance(
          kind: 'extract',
          offsetMinutes: 0,
          estimateTokens: (text) => text.length,
          forceTail: true,
        ),
        isNull,
      );
      final late = await tools.execute(
        CompanionAgentToolCall(id: 'late', name: 'remember', input: {'text': '不可复活旧维护', 'source': source['id']}),
      );
      expect(late.isError, isTrue);
      expect(memory.store.cards(), hasLength(1));
    },
  );
}
