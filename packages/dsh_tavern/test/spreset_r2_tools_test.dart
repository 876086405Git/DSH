import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' as fixture;
import 'support/stage1_engine_harness.dart';

class _ToolsHost extends fixture.SPresetHost {
  _ToolsHost(this.names, {this.editFinal}) {
    handler = evaluateFixture;
  }
  final Map<String, String> names;
  final void Function(Map<String, Object?>)? editFinal;

  Future<TavernSPresetEvaluationResult> evaluateFixture(TavernSPresetEvaluationRequest request) async {
    if (request.kind == TavernSPresetEvaluationKind.toolRegistry) {
      final result = await defaultEvaluate(request);
      final registry = result.value! as Map<String, Object?>;
      for (final raw in registry['tools']! as List) {
        final tool = raw as Map<String, Object?>;
        final name = names[tool['identifier']];
        if (name == null) throw StateError('Unexpected fixture binding.');
        tool['sessionId'] = 'tool:$name';
        final definition = tool['definition']! as Map<String, Object?>;
        definition['name'] = name;
        definition['description'] = 'SPreset fixture for $name';
      }
      return TavernSPresetEvaluationResult(requestId: request.requestId, value: registry);
    }
    if (request.stage == 'FinalRequestProcessing') {
      final args = request.arguments;
      final input = args.single! as Map<String, Object?>;
      editFinal?.call(input['request']! as Map<String, Object?>);
      return TavernSPresetEvaluationResult(requestId: request.requestId, isUndefined: true, arguments: args);
    }
    return defaultEvaluate(request);
  }
}

ChatPreset _toolsPreset(Map<String, String> names, {Object characterId = 100001}) {
  final raw = fixture
      .preset(
        {
          'ToolBindings': {
            for (final entry in names.entries)
              entry.key: {'enabled': true, 'valid': true, 'uuid': entry.key, 'code': 'synthetic ${entry.value}'},
          },
          'FinalRequestProcessing': {'enabled': true, 'script': 'synthetic-final'},
        },
        calling: true,
        stream: false,
      )
      .raw;
  final prompts = raw['prompts']! as List<Object?>;
  final order = (raw['prompt_order']! as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
    (row) => row['character_id'].toString() == '100001',
  );
  order['character_id'] = characterId;
  for (final id in names.keys) {
    prompts.add({'identifier': id, 'role': 'system', 'content': '', 'injection_position': 0});
    (order['order']! as List<Object?>).add({'identifier': id, 'enabled': true});
  }
  return ChatPreset(raw);
}

Map<String, Object?> _toolResponse(List<String> names) => {
  'choices': [
    {
      'index': 0,
      'message': {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          for (var i = 0; i < names.length; i++)
            {
              'id': 'call-$i',
              'type': 'function',
              'function': {'name': names[i], 'arguments': '{}'},
            },
        ],
      },
      'finish_reason': 'tool_calls',
    },
  ],
};

void main() {
  const names = {'first-slot': 'fixture_tool', 'second-slot': 'other_tool'};
  for (final row in <({String label, Object? choice, List<String> allowed, bool removeTools})>[
    (label: 'missing', choice: null, allowed: ['fixture_tool', 'other_tool'], removeTools: false),
    (label: 'auto', choice: 'auto', allowed: ['fixture_tool', 'other_tool'], removeTools: false),
    (label: 'required', choice: 'required', allowed: ['fixture_tool', 'other_tool'], removeTools: false),
    (label: 'none', choice: 'none', allowed: [], removeTools: false),
    (
      label: 'named first',
      choice: {
        'type': 'function',
        'function': {'name': 'fixture_tool'},
      },
      allowed: ['fixture_tool'],
      removeTools: false,
    ),
    (
      label: 'named second',
      choice: {
        'type': 'function',
        'function': {'name': 'other_tool'},
      },
      allowed: ['other_tool'],
      removeTools: false,
    ),
    (
      label: 'unknown name',
      choice: {
        'type': 'function',
        'function': {'name': 'absent'},
      },
      allowed: [],
      removeTools: false,
    ),
    (
      label: 'invalid name type',
      choice: {
        'type': 'function',
        'function': {'name': 42},
      },
      allowed: [],
      removeTools: false,
    ),
    (label: 'unknown choice', choice: 'unsupported', allowed: [], removeTools: false),
    (label: 'removed tools', choice: 'auto', allowed: [], removeTools: true),
  ]) {
    test('final wire ${row.label} supplies one SPreset authorization set through HTTP, action and replay', () async {
      final h = await generationFixture();
      final character = await h.card('Final wire tools');
      final chat = await h.engine.createChat(character);
      final host = _ToolsHost(
        names,
        editFinal: (body) {
          if (row.label == 'missing') {
            body.remove('tool_choice');
          } else {
            body['tool_choice'] = row.choice;
          }
          if (row.removeTools) body.remove('tools');
        },
      );
      h.bridge.attachHost(host);
      await h.engine.setPreset(_toolsPreset(names));
      generationJsonResponse(h, _toolResponse(names.values.toList()));
      if (row.allowed.isNotEmpty) h.reply('final');
      final events = await h.engine.send(chat, 'question').toList();
      expect(events.whereType<TavernTurnFailed>(), isEmpty);
      expect(host.actions, row.allowed.length);
      expect(h.requests, hasLength(row.allowed.isEmpty ? 1 : 2));
      final first = h.requests.first.body;
      expect(first['tool_choice'], row.choice);
      expect(first.containsKey('tools'), !row.removeTools);
      expect(host.requests, h.requests.map((request) => request.body).toList());
      final id = events.whereType<TavernTurnStarted>().single.logicalTurnId!;
      final turn = (await h.engine.readToolTurn(id))!;
      final captured = h.inspect(
        (db) =>
            db.select('SELECT wire_authorization_json FROM tool_requests WHERE id = ?', [
                  turn.requests.first.requestId,
                ]).single['wire_authorization_json']!
                as String,
      );
      expect((jsonDecode(captured) as Map)['spresetTools'], row.allowed);
      final receipts = [for (final id in turn.receiptIds) (await h.engine.readToolReceipt(id))!];
      for (final receipt in receipts) {
        expect(receipt.status, row.allowed.contains(receipt.kind) ? 'completed_no_change' : 'rejected');
      }
      if (h.requests.length == 2) {
        final exchange = generationMessages(h.requests.last).where((message) => message['role'] == 'tool').toList();
        expect(exchange, hasLength(2));
        var action = 0;
        for (var i = 0; i < 2; i++) {
          final name = names.values.elementAt(i);
          expect(exchange[i]['tool_call_id'], 'call-$i');
          if (row.allowed.contains(name)) {
            expect(exchange[i]['content'], 'answer-${++action}');
          } else {
            expect((jsonDecode(exchange[i]['content']! as String) as Map)['status'], 'rejected');
          }
        }
      }
    });
  }

  test('string character_id activates the same binding in prompt assembly and actual HTTP tools', () async {
    final h = await generationFixture();
    final character = await h.card('String order');
    final chat = await h.engine.createChat(character);
    final host = _ToolsHost(const {'slot': 'fixture_tool'});
    h.bridge.attachHost(host);
    await h.engine.setPreset(_toolsPreset(host.names, characterId: '100001'));
    generationJsonResponse(h, _toolResponse(['fixture_tool']));
    h.reply('final');
    final events = await h.engine.send(chat, 'question').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(host.actions, 1);
    expect(h.requests, hasLength(2));
    expect(stage1Rows(h.requests.first.body['tools']).map((tool) => stage1Map(tool['function'])['name']), [
      'fixture_tool',
    ]);
  });

  for (final nativeEnabled in [false, true]) {
    test('reserved SPreset definitions are excluded before offering with native tools=$nativeEnabled', () async {
      final h = await Stage1Harness.open(state: nativeEnabled, deepseek: nativeEnabled);
      if (nativeEnabled) await h.enableMemory();
      final host = _ToolsHost(const {'r': 'roll', 'm': 'remember', 's': 'update_state'});
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(_toolsPreset(host.names));
      final active = await h.start();
      final definitions = stage1Rows(active.call.body!['tools']);
      expect(
        definitions.map((tool) => stage1Map(tool['function'])['name']).toSet(),
        nativeEnabled ? {'roll', 'remember', 'update_state'} : isEmpty,
      );
      expect(
        definitions.any((tool) => stage1Map(tool['function'])['description'].toString().startsWith('SPreset fixture')),
        isFalse,
      );
      await stage1Finish(active.call, content: 'final');
      await active.events.done.future;
      final done = active.events.values.whereType<TavernTurnDone>().single;
      expect(
        done.hookIssues.where(
          (issue) => issue.stage == 'ToolBindings' && issue.message.contains('reserved native tool'),
        ),
        hasLength(3),
      );
      expect(host.actions, 0);
      await h.reopen();
      for (final name in host.names.values) {
        expect(host.released.any((id) => id.endsWith(':tool:$name')), isTrue);
      }
    });
  }

  for (final row in <({String label, Object? value, bool allowed})>[
    (label: 'absent', value: null, allowed: true),
    (label: 'disabled', value: {'type': 'disabled'}, allowed: true),
    (label: 'enabled', value: {'type': 'enabled'}, allowed: false),
    (label: 'unknown type', value: {'type': 'other'}, allowed: false),
    (label: 'explicit null', value: null, allowed: false),
  ]) {
    test('update_state reads final thinking ${row.label} after FinalRequestProcessing', () async {
      final h = await Stage1Harness.open();
      final host = _ToolsHost(
        const {},
        editFinal: (body) {
          if (row.label == 'absent') {
            body.remove('thinking');
          } else {
            body['thinking'] = row.value;
          }
        },
      );
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(_toolsPreset(const {}));
      final active = await h.start();
      expect(active.call.body!['thinking'], row.value);
      expect(
        stage1Rows(active.call.body!['tools']).any((tool) => stage1Map(tool['function'])['name'] == 'update_state'),
        isTrue,
      );
      await stage1Finish(
        active.call,
        content: 'final',
        tools: [
          Stage1Call(0, 'state-call', 'update_state', {
            'ops': [stage1Set(7)],
          }),
        ],
      );
      await active.events.done.future;
      expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(stage1Map((await h.engine.readState(h.chatId)).values)['n'], row.allowed ? 7 : 0);
      final turn = await h.turn(active.events);
      final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
      expect(receipt.status, row.allowed ? 'committed' : 'rejected');
    });
  }

  for (final actual in <bool?>[true, false, null]) {
    test('terminal recovery before an in-flight action returns retains only actual committed=$actual facts', () async {
      final h = await Stage1Harness.open(state: false, deepseek: false);
      final host = _ToolsHost(const {'slot': 'fixture_tool'});
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      host.handler = (request) async {
        if (request.kind != TavernSPresetEvaluationKind.toolAction) return host.evaluateFixture(request);
        host.actions++;
        entered.complete();
        await release.future;
        return TavernSPresetEvaluationResult(requestId: request.requestId, value: 'observed', committed: actual);
      };
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(_toolsPreset(host.names));
      final active = await h.start();
      await stage1Finish(active.call, reason: 'tool_calls', tools: [Stage1Call(0, 'recover', 'fixture_tool', {})]);
      await entered.future;
      final before = await h.turn(active.events);
      final id = before.receiptIds.single;
      expect((await h.engine.readToolReceipt(id))!.status, 'prepared');
      // A second real SQLite store performs its startup recovery while the
      // controlled old host call is still pending. This is a recovery race,
      // not a claim that the App cancellation Future reports later JS success.
      final recovered = ChatStore.fromDatabase(sqlite3.open('${h.root.path}/tavern.sqlite3'));
      try {
        expect(recovered.readToolReceipt(id)!.status, 'unresolved');
        expect(recovered.readToolTurn(before.logicalTurnId)!.status, 'interrupted');
      } finally {
        await recovered.close();
      }
      release.complete();
      await active.events.done.future;
      final after = (await h.engine.readToolReceipt(id))!;
      expect(
        after.status,
        actual == null
            ? 'unresolved'
            : actual
            ? 'committed'
            : 'completed_no_change',
      );
      expect(after.committed, actual);
      if (actual != null) expect((after.result!['value']! as Map)['result'], 'observed');
      expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
      expect(h.model.generated, 1);
      expect(host.actions, 1);
      expect(h.database((db) => db.select('PRAGMA foreign_key_check')), isEmpty);
    });
  }

  test(
    'a host that settles cancellation immediately leaves an unknown terminal receipt without another action',
    () async {
      final h = await Stage1Harness.open(state: false, deepseek: false);
      final host = _ToolsHost(const {'slot': 'fixture_tool'});
      final entered = Completer<void>();
      host.handler = (request) async {
        if (request.kind != TavernSPresetEvaluationKind.toolAction) return host.evaluateFixture(request);
        host.actions++;
        entered.complete();
        await h.model.allCalls.single.cancellation!.whenCancelled;
        throw StateError('App cancellation: outcome unknown');
      };
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(_toolsPreset(host.names));
      final active = await h.start();
      await stage1Finish(active.call, reason: 'tool_calls', tools: [Stage1Call(0, 'cancelled', 'fixture_tool', {})]);
      await entered.future;
      h.engine.stop(h.chatId);
      await active.events.done.future;
      final turn = await h.turn(active.events);
      final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
      expect(receipt.status, 'unresolved');
      expect(receipt.committed, isNull);
      expect(host.actions, 1);
      expect(h.model.generated, 1);
      await h.reopen();
      expect((await h.engine.readToolReceipt(receipt.executionId))!.status, 'unresolved');
    },
  );
}
