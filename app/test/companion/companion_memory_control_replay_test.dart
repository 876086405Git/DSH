// r2 fixture 5: fixed tool calls through actual maintenance HTTP, then actual
// light chat HTTP. This is not a Page, host engine or model-semantics test.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

const _usage = {
  'input_tokens': 20,
  'cache_read_input_tokens': 3,
  'cache_creation_input_tokens': 0,
  'output_tokens': 12,
};

http.Response _reply(String text) => http.Response.bytes(
  utf8.encode(
    [
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': text},
      },
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': _usage,
      },
      {'type': 'message_stop'},
    ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  ),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

http.Response _tools(List<MemoryRow> inputs) => http.Response.bytes(
  utf8.encode(
    [
      for (var index = 0; index < inputs.length; index++) ...[
        {
          'type': 'content_block_start',
          'index': index,
          'content_block': {
            'type': 'tool_use',
            'id': 'memory-$index',
            'name': 'remember',
            'input': <String, Object?>{},
          },
        },
        {
          'type': 'content_block_delta',
          'index': index,
          'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(inputs[index])},
        },
        {'type': 'content_block_stop', 'index': index},
      ],
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use'},
        'usage': _usage,
      },
      {'type': 'message_stop'},
    ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  ),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

MemoryRow _create(String source, String text, String word) => {
  'source': source,
  'kind': 'fact',
  'text': text,
  'keywords': [word],
};

class _Phone {
  _Phone(this.directory) {
    _open();
    addTearDown(() async {
      await worker.stop();
      owner.dispose();
      await directory.delete(recursive: true);
    });
  }

  final Directory directory;
  int now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;
  late CompanionMemoryStore store;
  late CompanionMemoryOwner owner;
  late CompanionMemoryWorker worker;
  final auxiliaryPosts = <MemoryRow>[];
  final chatPosts = <MemoryRow>[];
  List<MemoryRow> Function(MemoryRow) answer = (_) => throw StateError('No auxiliary request expected');

  void _open() {
    store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
    owner = CompanionMemoryOwner(store, CompanionLocal.at(directory), nowMilliseconds: () => now);
    var expectedResults = 0;
    final route = CompanionLightMemoryTransport(
      apiKey: () => 'offline-replay-placeholder',
      client: () => MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), companionLightEndpoint);
        final body = jsonDecode(request.body) as MemoryRow;
        auxiliaryPosts.add(body);
        expect(body['thinking'], {'type': 'disabled'});
        expect(body['max_tokens'], 800);
        expect((body['tools'] as List).map((tool) => (tool as Map)['name']), contains('remember'));
        final messages = (body['messages'] as List<Object?>).cast<MemoryRow>();
        final input = jsonDecode(messages.first['content'] as String) as MemoryRow;
        expect(input['type'], 'memory_maintenance_context');
        expect(input['processed_at_utc'], DateTime.fromMillisecondsSinceEpoch(now, isUtc: true).toIso8601String());
        final receipt = store.requests().singleWhere((row) => row['state'] == 'sent' && row['terminal'] == null);
        expect(receipt['sent_at_ms'], now);
        if (messages.length == 1) {
          final calls = answer(input);
          expectedResults = calls.length;
          return calls.isEmpty ? _reply('本轮没有其它需要改动。') : _tools(calls);
        }
        expect(messages, hasLength(3));
        final results = (messages.last['content'] as List).cast<MemoryRow>();
        expect(results, hasLength(expectedResults));
        for (var index = 0; index < results.length; index++) {
          expect(results[index]['type'], 'tool_result');
          expect(results[index]['tool_use_id'], 'memory-$index');
          expect(results[index]['is_error'], isNot(true));
        }
        // Earlier result text is retired after later own commits. The final
        // real result still confirms the last write; cards are checked below.
        expect((jsonDecode(results.last['content'] as String) as Map)['applied'], isTrue);
        return _reply('已保存这些独立事实。');
      }),
    );
    worker = CompanionMemoryWorker(
      store: store,
      transport: () => route,
      nowMilliseconds: () => now,
      estimateTokens: estimateCompanionMemoryTokens,
      maintenanceTools: (turn, current, committed) => CompanionAgentMemoryTools.maintenance(
        memory: owner,
        turn: turn,
        isCurrent: current,
        forgottenNotice: '',
        onMaintenanceCommitted: ({required memory, required turnId, required beforeRevision, required revision}) {
          committed(memory: memory, turnId: turnId, beforeRevision: beforeRevision, revision: revision);
        },
      ),
    );
  }

  Future<void> reopen() async {
    await worker.stop();
    owner.dispose();
    _open();
  }

  MemoryRow say(String id, String text, {String role = 'user'}) => store.submitMessage(
    id: id,
    sessionId: store.lightSessionId,
    text: text,
    role: role,
    saidAtUtc: now,
    offsetMinutes: 480,
  );

  Future<MemoryRow> chat(String input) async {
    now += 60000;
    say('chat-${chatPosts.length}', input);
    final selection = owner.select(input);
    final lines = companionLightContext([
      for (final row in store.messages(sessionId: store.lightSessionId, forModel: true, limit: 24))
        row['role'] == 'user' ? CompanionLine.user(row['text'] as String) : CompanionLine.her(row['text'] as String),
    ]);
    final system = companionLightSystem();
    final id = store.reserveRequest(
      category: 'chat',
      provider: 'deepseek',
      model: companionLightModel,
      inputTokens: estimateCompanionMemoryTokens(
        '$system\n${lines.map((line) => line.text).join('\n')}\n${selection.block}',
      ),
      outputTokens: 800,
    )!;
    final client = MockClient((request) async {
      chatPosts.add(jsonDecode(request.body) as MemoryRow);
      expect(store.requests().singleWhere((row) => row['id'] == id)['state'], 'sent');
      return _reply('固定回包，不评价回答语义。');
    });
    try {
      expect(
        await streamCompanionReply(
          client: client,
          apiKey: 'offline-replay-placeholder',
          system: system,
          lines: lines,
          memory: selection,
          onSent: () => store.markRequestSent(id),
          onUsage: (usage) {
            store.recordUsage(id, usage.toJson());
            store.finishRequest(id, terminal: usage.terminal);
          },
        ).join(),
        '固定回包，不评价回答语义。',
      );
    } finally {
      client.close();
    }
    final messages = (chatPosts.last['messages'] as List<Object?>).cast<MemoryRow>();
    final parts = (messages.last['content'] as List<Object?>).cast<MemoryRow>();
    final block = jsonDecode(parts.last['text'] as String) as MemoryRow;
    expect(block['type'], 'companion_memory');
    expect((block['items'] as List<Object?>).map((item) => (item as MemoryRow)['id']), selection.ids);
    return block;
  }
}

void main() {
  for (final kind in ['never', 'forget', 'normal', 'delete']) {
    final never = kind == 'never';
    final name = switch (kind) {
      'never' => 'fixture 5 never survives editing old mixed source across reopen and all three actual request paths',
      'forget' => 'fixture 5 forget keeps the edited old source out but admits a new source across all three actual request paths',
      'delete' =>
        'fixture 16 deleting edited raw source removes withdrawn facts before extraction consolidation and actual chat',
      _ => 'fixture 5 natural normal command releases the saved control before new source extraction and actual chat',
    };
    test(name, () async {
      final phone = _Phone(await Directory.systemTemp.createTemp('companion-never-replay-'));
      // Real non-extractable history gives the fixture its literal 200..204
      // sequence numbers, without directly changing the archive's counter.
      for (var i = 1; i < 200; i++) {
        phone.say('old-assistant-$i', '旧助手行 $i', role: 'assistant');
      }
      final independent = phone.say('coffee-200', '我喝咖啡都选无糖。');
      final original = phone.say('mixed-201', '我周五复诊，周六去公园。');
      expect(independent['first_seq'], 200);
      expect(original['first_seq'], 201);
      phone.now += 180000;
      phone.answer = (input) {
        expect(input['kind'], 'extract');
        expect((input['sources'] as List).cast<MemoryRow>().map((row) => row['id']), ['coffee-200', 'mixed-201']);
        return [
          _create('coffee-200', '你喝咖啡都选无糖。', '咖啡'),
          _create('mixed-201', '你周五复诊。', '复诊'),
          _create('mixed-201', '你周六去公园。', '公园'),
        ];
      };
      expect(await phone.worker.extract(offsetMinutes: 480), CompanionMemoryWork.committed);
      final clinic = phone.store.cards().singleWhere((row) => row['text'] == '你周五复诊。');
      final coffee = phone.store.cards().singleWhere((row) => row['text'] == '你喝咖啡都选无糖。');
      final initialKind = kind == 'forget' ? 'forget' : 'never';
      final command = phone.say('control-202', kind == 'forget' ? '忘掉那次复诊，聊天留着' : '别主动提那次复诊');
      expect(command['first_seq'], 202);
      final control = parseMemoryControl(command['text'] as String, phone.store.cards())!;
      expect(control['ambiguous'], isFalse);
      expect(control['kind'], initialKind);
      expect(control['delete_chat'], isFalse);
      expect(control['target_card_ids'], kind == 'forget' ? [clinic['id']] : isEmpty);
      phone.store.applyControl(
        topicIds: [clinic['topic_id'] as String],
        kind: initialKind,
        controlMessageId: 'control-202',
      );
      if (kind == 'forget') {
        expect(phone.store.cards(includeInactive: true).map((row) => row['id']), isNot(contains(clinic['id'])));
      }
      expect(phone.store.archive['history_after_seq'], 202);
      expect(phone.auxiliaryPosts, hasLength(2), reason: 'an explicit control is local');
      phone.now += 60000;
      final edited = phone.store.editMessage(id: 'mixed-201', expectedSourceRev: 1, text: '我周五复诊，周日去公园。');
      expect(edited['first_seq'], 201);
      expect(edited['event_seq'], 203);
      expect(edited['source_rev'], 2);
      expect(
        phone.store.messages().singleWhere((row) => row['id'] == 'mixed-201')['extraction_reason'],
        'history_cutoff',
      );
      expect(phone.store.cards().map((row) => row['id']), [coffee['id']]);
      expect(await phone.worker.extract(offsetMinutes: 480), CompanionMemoryWork.idle);
      expect(phone.auxiliaryPosts, hasLength(2));
      await phone.reopen();
      expect(phone.store.archive['history_after_seq'], 202);

      if (kind == 'delete') {
        phone.store.deleteMessage(id: 'mixed-201', expectedSourceRev: 2);
        await phone.reopen();
        expect(phone.store.cards(includeInactive: true).map((row) => row['id']), [coffee['id']]);
        expect(phone.store.topicControls(), isEmpty);
        expect(phone.store.messages().any((row) => row['id'] == 'mixed-201'), isFalse);
      }

      const newText = '我周六复诊。酸奶我现在只买原味，我买酸奶还是选原味。';
      final newSequence = kind == 'delete' ? 205 : 204;
      final newSourceId = 'new-$newSequence';
      final newSource = phone.say(newSourceId, newText);
      expect(newSource['first_seq'], newSequence);
      if (kind == 'normal') {
        final release = phone.say('normal-205', '以后可以聊复诊');
        expect(release['first_seq'], 205);
        // No new clinic card exists yet: this uses only the continuing control,
        // through the retained public control API; this is not an Agent UI test.
        final parsed = parseMemoryControl(
          release['text'] as String,
          phone.store.cards(),
          topicControls: phone.store.topicControls(),
        )!;
        expect(parsed['ambiguous'], isFalse);
        expect(parsed['kind'], 'normal');
        expect(parsed['topic_ids'], [clinic['topic_id']]);
        phone.store.applyControl(
          topicIds: (parsed['topic_ids'] as List<Object?>).cast<String>(),
          kind: parsed['kind'] as String,
          controlMessageId: release['id'] as String,
        );
        expect(phone.store.topicControls(), isEmpty);
        expect(phone.auxiliaryPosts, hasLength(2), reason: 'release is also a local control');
      }
      phone.now += 180000;
      phone.answer = (input) {
        expect((input['sources'] as List<Object?>).map((row) => (row as MemoryRow)['id']), [newSourceId]);
        expect(((input['sources'] as List<Object?>).single as MemoryRow)['text'], newText);
        for (final forbidden in ['mixed-201', 'control-202', 'normal-205', '以后可以聊复诊', '我周五复诊', '周日去公园']) {
          expect(jsonEncode(input), isNot(contains(forbidden)));
        }
        return [
          _create(newSourceId, '你周六复诊。', '复诊'),
          _create(newSourceId, '你现在买酸奶只选原味。', '酸奶'),
          _create(newSourceId, '酸奶你现在还是选原味。', '酸奶'),
        ];
      };
      expect(await phone.worker.extract(offsetMinutes: 480), CompanionMemoryWork.committed);
      final freshClinic = phone.store.cards().singleWhere((row) => row['text'] == '你周六复诊。');
      // never is a continuing control; forget removed the former fact/topic.
      // The later independent source must not be conflated with edited old M.
      expect(freshClinic['topic_id'], never ? clinic['topic_id'] : isNot(clinic['topic_id']));
      expect(freshClinic['topic_mode'], never ? 'never' : 'normal');
      expect((freshClinic['evidence'] as List<Object?>).cast<MemoryRow>().map((row) => row['message_id']), [
        newSourceId,
      ]);
      final beforeMaintenance = phone.auxiliaryPosts.length;
      phone.answer = (input) {
        expect(input['kind'], 'organize');
        final rows = (input['cards'] as List<Object?>).cast<MemoryRow>();
        final yogurts = rows.where((row) => (row['text'] as String).contains('酸奶')).toList();
        expect(yogurts, hasLength(2));
        expect(
          yogurts.every((row) => row['topic_mode'] == 'normal'),
          isTrue,
          reason: 'a full composite source cannot spread the clinic control to yogurt',
        );
        expect(
          rows.map((row) => row['id']),
          contains(coffee['id']),
          reason: 'A2 maintenance includes independent eligible cards, not only old duplicate pairs',
        );
        expect(rows.map((row) => row['id']), never ? isNot(contains(freshClinic['id'])) : contains(freshClinic['id']));
        // Today's original is not yesterday's diary source. Eligible card proof
        // remains usable without replaying the withdrawn mixed raw message.
        expect(input['sources'], isEmpty);
        for (final forbidden in ['mixed-201', '我周五复诊', '你周五复诊', '公园']) {
          expect(jsonEncode(input), isNot(contains(forbidden)));
        }
        return <MemoryRow>[];
      };
      expect(await phone.worker.consolidate(offsetMinutes: 480), CompanionMemoryWork.committed);
      expect(phone.auxiliaryPosts, hasLength(beforeMaintenance + 1));
      expect(phone.auxiliaryPosts.last['system'], contains('phone memory using the supplied memory tools'));

      final incidental = await phone.chat('今天碰巧听到复诊和咖啡这些词。');
      final ordinaryIds = (incidental['items'] as List<Object?>).map((item) => (item as MemoryRow)['id']);
      expect(ordinaryIds, contains(coffee['id']));
      expect(ordinaryIds, never ? isNot(contains(freshClinic['id'])) : contains(freshClinic['id']));
      final explicit = await phone.chat('我想问复诊');
      expect((explicit['items'] as List<Object?>).map((item) => (item as MemoryRow)['id']), [freshClinic['id']]);
      expect(
        phone.store.cards().singleWhere((row) => row['id'] == freshClinic['id'])['topic_mode'],
        never ? 'never' : 'normal',
      );
      for (final body in phone.chatPosts) {
        for (final forbidden in [
          '我周五复诊',
          '你周五复诊',
          '周六去公园',
          '周日去公园',
          '旧助手行',
          'control_anchors',
          'cleanup_history_complete',
          'memory_card_cleanup_sources',
        ]) {
          expect(jsonEncode(body), isNot(contains(forbidden)));
        }
      }
      final oldSource = phone.store.messages().where((row) => row['id'] == 'mixed-201');
      if (kind == 'delete') {
        expect(oldSource, isEmpty);
      } else {
        expect(oldSource.single['text'], '我周五复诊，周日去公园。');
      }
      final receipts = phone.store.requests();
      expect(receipts.where((row) => row['category'] == 'extract'), hasLength(4));
      expect(receipts.map((row) => row['id']).toSet(), hasLength(7));
      expect(receipts.where((row) => row['category'] == 'extract').map((row) => row['batch_id']).toSet(), hasLength(2));
      expect(receipts.where((row) => row['category'] == 'organize'), hasLength(1));
      expect(receipts.where((row) => row['category'] == 'chat'), hasLength(2));
      for (final receipt in receipts) {
        expect(receipt['state'], 'finished');
        expect((receipt['raw_usage'] as MemoryRow)['final_usage'], _usage);
      }
    });
  }
}
