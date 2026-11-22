// Phone selection -> actual request serializer, shared by both room modes.
import 'dart:convert';

import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final now = DateTime.utc(2026, 11, 21, 1);
  late CompanionMemoryStore store;
  const id = '11111111-1111-4111-8111-111111111111';

  setUp(() {
    store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now.millisecondsSinceEpoch);
    store.saveManual(
      const CompanionMemory(id: id, text: '我的咖啡甜度是无糖'),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
  });
  tearDown(() => store.close());

  MemorySelection select(String input) => selectMemoryContext(
    store.cards(),
    input: input,
    nowMs: now.millisecondsSinceEpoch,
    controlRevision: store.archive['control_revision']! as int,
  );

  Future<Map<String, Object?>> request(String input, MemorySelection selected) async {
    Map<String, Object?>? body;
    final client = MockClient((sent) async {
      body = jsonDecode(sent.body) as Map<String, Object?>;
      return http.Response('data: {"type":"message_stop"}\n\n', 200);
    });
    await streamCompanionReply(
      client: client,
      apiKey: 'test',
      system: companionLightSystem(persona: '固定人设'),
      lines: [CompanionLine.user(input)],
      memory: selected,
    ).drain<void>();
    client.close();
    return body!;
  }

  test('both modes use the one phone block and stable system contains no selected card', () async {
    final selected = select('咖啡甜度');
    expect(selected.ids, [id]);
    final body = await request('咖啡甜度', selected);
    final system = jsonEncode(body['system']);
    expect(system, contains('固定人设'));
    expect(system, contains('companion_memory'));
    expect(system, isNot(contains('我的咖啡甜度是无糖')));
    final messages = body['messages']! as List;
    final blocks = (messages.single as Map)['content']! as List;
    expect(blocks, [
      {'type': 'text', 'text': '咖啡甜度'},
      {'type': 'text', 'text': selected.block},
    ]);
    final full = companionFullContextPlan(
      text: '咖啡甜度',
      sessionId: 'session',
      requestId: 'request',
      profile: const CompanionContextProfile(),
      supported: true,
      now: now,
      instanceId: 'instance',
      profileRevision: 0,
      memoryMode: 'phone',
      recall: false,
      phoneMemory: {
        'archiveId': store.archive['id'],
        'controlRevision': selected.controlRevision,
        'historyAfterSeq': store.archive['history_after_seq'],
        'block': selected.block,
      },
    );
    expect((full.update!['phoneMemory']! as Map<String, Object?>)['block'], selected.block);
    expect(full.update!.containsKey('query'), isFalse);
  });

  test('empty phone selection clears the host request while light sends only raw user text', () async {
    final selected = select('咖啡甜度？');
    expect(selected.ids, isEmpty);
    final body = await request('咖啡甜度？', selected);
    expect((body['messages']! as List).single, {'role': 'user', 'content': '咖啡甜度？'});
    final full = companionFullContextPlan(
      text: '咖啡甜度？',
      sessionId: 'session',
      requestId: 'empty',
      profile: const CompanionContextProfile(),
      supported: true,
      now: now,
      instanceId: 'instance',
      profileRevision: 0,
      memoryMode: 'phone',
      recall: false,
      phoneMemory: {
        'archiveId': store.archive['id'],
        'controlRevision': selected.controlRevision,
        'historyAfterSeq': store.archive['history_after_seq'],
        'block': selected.block,
      },
    );
    expect((full.update!['phoneMemory']! as Map<String, Object?>)['block'], selected.block);
    expect(jsonDecode(selected.block)['items'], isEmpty);
  });

  test('request construction never writes the selected block into reusable raw history', () {
    final history = [(role: 'user', text: '原话'), (role: 'assistant', text: '旧答'), (role: 'user', text: '咖啡甜度')];
    final first = companionRequestMessages(history, memory: select('咖啡甜度'));
    expect((first.last['content']! as List), hasLength(2));
    expect(history.last.text, '咖啡甜度');
    final second = companionRequestMessages([
      ...history,
      (role: 'assistant', text: '这次回答'),
      (role: 'user', text: '别的事'),
    ], memory: select('别的事'));
    expect(jsonEncode(second), isNot(contains('我的咖啡甜度是无糖')));
    expect(second.last['content'], '别的事');
  });
}
