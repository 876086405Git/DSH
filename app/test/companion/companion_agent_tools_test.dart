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
}
