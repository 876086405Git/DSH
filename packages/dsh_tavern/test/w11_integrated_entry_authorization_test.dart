import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;

void main() {
  for (final echoLateReceiver in [false, true]) {
    test('late Entry refresh cannot authorize a Final-added tool; extra receiver=$echoLateReceiver', () async {
      final f = await _fixture(condition: false, echoLateReceiver: echoLateReceiver);
      final h = f.h, host = f.host;
      final heldPlan = h.stream();
      final held = await h.bridge.generateRaw(
        f.context.id,
        TavernHelperRawRequest.fromJson({
          'should_stream': true,
          'ordered_prompts': [
            {'role': 'user', 'content': 'held helper'},
          ],
        }),
      );
      await generationSignal(held, heldPlan.listening.future);
      var stopped = false;
      host.onDispatch = (event, _) async {
        if (event.namespace == 'tavern' && event.name == 'GENERATION_STARTED') {
          stopped = await (h.bridge as TavernHelperGenerationControl).stopHelperGenerationById(held.id);
          heldPlan.finish();
          expect((await generationFailure(held)).code, TavernScriptErrorCode.cancelled);
        }
        return TavernScriptDispatchAck(eventId: event.eventId);
      };

      final nativePlan = generationJsonResponse(h, _toolResponse('fixture_tool'));
      final events = await h.engine.send(f.chat, 'native question').toList();
      _succeeded(events);
      expect(stopped, isTrue);
      expect(host.conditions, 1);
      expect(host.nativeRegistry.map((call) => call.mode), ['sync', 'read', 'read', 'refresh']);
      expect(host.nativeRegistry.first.active, isNot(contains('fixture-slot')));
      for (final call in host.nativeRegistry.skip(1)) {
        expect(call.active, contains('fixture-slot'), reason: 'The real Helper STOP restored prompt defaults.');
      }
      for (final call in host.nativeRegistry.take(3)) {
        expect(call.returnedNames, isEmpty, reason: 'Reads do not resynchronize the early empty registry.');
      }
      expect(host.nativeRegistry.last.returnedNames, echoLateReceiver ? ['fixture_tool'] : isEmpty);
      expect(host.beforeFinalTools.single, isEmpty, reason: 'Wire selection precedes the late refresh.');
      final native = await nativePlan.seen.future;
      expect(_toolNames(native.body), ['fixture_tool'], reason: 'Final really added this name to the HTTP body.');
      expect(native.body['tool_choice'], 'auto');
      expect(host.requests, h.requests.map((request) => request.body).toList());
      expect(host.actions, 0, reason: 'A wire-only name cannot create a generation-owned action binding.');
      expect(h.requests, hasLength(2), reason: 'The held Helper and native call produce no tool follow-up.');

      final logicalId = events.whereType<TavernTurnStarted>().single.logicalTurnId!;
      final turn = (await h.engine.readToolTurn(logicalId))!;
      expect(turn.requests, hasLength(1));
      final wireAuthorization = h.inspect(
        (db) =>
            db.select('SELECT wire_authorization_json FROM tool_requests WHERE id = ?', [
                  turn.requests.single.requestId,
                ]).single['wire_authorization_json']!
                as String,
      );
      expect((jsonDecode(wireAuthorization) as Map)['spresetTools'], isEmpty);
      final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
      expect(receipt.kind, 'fixture_tool');
      expect(receipt.status, 'rejected');

      // The host receives the late sync with default-enabled identifiers;
      // a later real Helper can offer the tool. Its own sync is not presented
      // as an isolated proof of the page registry's implementation.
      final nextPlan = h.reply('later helper');
      final next = await h.bridge.generate(
        f.context.id,
        TavernHelperGenerateRequest.fromJson({'user_input': 'later helper input'}),
      );
      final nextRequest = await generationRequest(next, nextPlan);
      await next.result;
      expect(_toolNames(nextRequest.body), ['fixture_tool']);
      expect(host.conditions, 1, reason: 'The later Helper does not reevaluate native Entry conditions.');
      expect(host.actions, 0);
      await h.close();
      if (echoLateReceiver) {
        expect(host.lateReceiverSession, isNotNull);
        expect(host.released, isNot(contains(host.lateReceiverSession)));
      }
    });
  }

  for (final rollOnlyAtRead in [false, true]) {
    test('reserved roll is filtered per phase but diagnosed once; first appears at read=$rollOnlyAtRead', () async {
      final f = await _fixture(condition: true, reservedRoll: true, rollOnlyAtRead: rollOnlyAtRead);
      final h = f.h, host = f.host;
      generationJsonResponse(h, _toolResponse('roll'));
      final events = await h.engine.send(f.chat, 'native question').toList();
      _succeeded(events);
      expect(host.conditions, 1);
      expect(host.nativeRegistry.map((call) => call.mode), ['sync', 'read', 'read', 'refresh']);
      expect(host.nativeRegistry.first.returnedNames, [rollOnlyAtRead ? 'fixture_tool' : 'roll']);
      for (final call in host.nativeRegistry.skip(1).take(2)) {
        expect(call.returnedNames, ['roll']);
      }
      expect(host.nativeRegistry.last.returnedNames, isEmpty);
      expect(host.beforeFinalTools.single, isEmpty);
      expect(_toolNames(h.requests.single.body), isEmpty);
      expect(host.actions, 0);
      final done = events.whereType<TavernTurnDone>().single;
      expect(
        done.hookIssues.where(
          (issue) => issue.stage == 'ToolBindings' && issue.message.contains('reserved native tool: roll'),
        ),
        hasLength(1),
        reason: 'One diagnostic per binding/name, including a conflict that first appears in read.',
      );
      final logicalId = events.whereType<TavernTurnStarted>().single.logicalTurnId!;
      final turn = (await h.engine.readToolTurn(logicalId))!;
      final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
      expect(receipt.status, 'rejected');
      await h.close();
      expect(host.reservedReceiverSessions, hasLength(rollOnlyAtRead ? 2 : 3));
      expect(host.allReceiverSessions, hasLength(3));
      expect(host.released, containsAll(host.allReceiverSessions));
      expect(host.released, containsAll(host.reservedReceiverSessions));
    });
  }
}

typedef _RegistryCall = ({String mode, List<Object?> active, List<String> returnedNames});

// JavaScript evaluation is the existing page-host boundary fake. The actual
// engine, generation/STOP coordination, HTTP codec and SQLite are exercised.
class _CrossHost extends SPresetHost {
  _CrossHost({
    required this.condition,
    required this.echoLateReceiver,
    required this.reservedRoll,
    required this.rollOnlyAtRead,
  }) {
    handler = _evaluate;
  }

  final bool condition, echoLateReceiver, reservedRoll, rollOnlyAtRead;
  int conditions = 0;
  String? nativeId;
  String? lateReceiverSession;
  final nativeRegistry = <_RegistryCall>[];
  final beforeFinalTools = <List<String>>[];
  final reservedReceiverSessions = <String>[];
  final allReceiverSessions = <String>[];

  Future<TavernSPresetEvaluationResult> _evaluate(TavernSPresetEvaluationRequest request) async {
    if (request.stage == 'EntryCondition') {
      conditions++;
      nativeId = request.generationId;
      return TavernSPresetEvaluationResult(requestId: request.requestId, value: condition);
    }
    final native = request.generationId == nativeId;
    if (request.kind == TavernSPresetEvaluationKind.toolRegistry) {
      final response = await defaultEvaluate(request);
      final registry = response.value! as Map<String, Object?>;
      if (native) {
        final input = request.arguments.single! as Map<String, Object?>;
        final mode = (input['registryMode'] ?? 'sync') as String;
        final tools = (registry['tools']! as List<Object?>).cast<Map<String, Object?>>();
        if (reservedRoll && (!rollOnlyAtRead || mode == 'read')) {
          for (final tool in tools) {
            final session = 'reserved-roll-$mode-${nativeRegistry.length}';
            tool['sessionId'] = session;
            (tool['definition']! as Map<String, Object?>)['name'] = 'roll';
            reservedReceiverSessions.add('${request.sessionScope}:$session');
          }
        }
        if (reservedRoll) {
          allReceiverSessions.addAll([for (final tool in tools) '${request.sessionScope}:${tool['sessionId']}']);
        }
        if (mode == 'refresh' && echoLateReceiver) {
          // The shipped page returns an empty list for refresh. This extra
          // structurally valid response row is a deliberate boundary control:
          // it must not bind a receiver or authorize the current generation.
          tools.add({
            'identifier': 'fixture-slot',
            'code': 'fixture-definition',
            'sessionId': 'late-refresh-receiver',
            'definition': {
              'name': 'fixture_tool',
              'description': 'late refresh',
              'parameters': {'type': 'object'},
              'hasAction': true,
            },
          });
          lateReceiverSession = '${request.sessionScope}:late-refresh-receiver';
        }
        nativeRegistry.add((
          mode: mode,
          active: List<Object?>.from(input['activeIdentifiers']! as List),
          returnedNames: [for (final tool in tools) (tool['definition']! as Map)['name']! as String],
        ));
      }
      return TavernSPresetEvaluationResult(requestId: request.requestId, value: registry);
    }
    if (request.stage == 'FinalRequestProcessing' && native) {
      final args = request.arguments;
      final body = (args.single! as Map<String, Object?>)['request']! as Map<String, Object?>;
      beforeFinalTools.add(_toolNames(body));
      if (!reservedRoll) {
        body['tools'] = [
          {
            'type': 'function',
            'function': {
              'name': 'fixture_tool',
              'description': 'Final-only offer',
              'parameters': {'type': 'object'},
            },
          },
        ];
        body['tool_choice'] = 'auto';
      }
      return TavernSPresetEvaluationResult(requestId: request.requestId, isUndefined: true, arguments: args);
    }
    return defaultEvaluate(request);
  }
}

Future<({ScriptFixture h, _CrossHost host, String chat, TavernScriptContext context})> _fixture({
  required bool condition,
  bool echoLateReceiver = false,
  bool reservedRoll = false,
  bool rollOnlyAtRead = false,
}) async {
  final h = await generationFixture();
  final host = _CrossHost(
    condition: condition,
    echoLateReceiver: echoLateReceiver,
    reservedRoll: reservedRoll,
    rollOnlyAtRead: rollOnlyAtRead,
  );
  h.bridge.attachHost(host);
  final raw = preset(
    toolExtension(
      extra: {
        'FinalRequestProcessing': {'enabled': true, 'script': 'synthetic-final'},
      },
    ),
    calling: true,
    stream: false,
  ).raw;
  raw.addAll({'temperature': 0.4, 'frequency_penalty': 0, 'presence_penalty': 0, 'top_p': 1, 'top_k': 0});
  (raw['prompts']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((entry) => entry['identifier'] == 'fixture-slot')
      .addAll({'spreset_condition_enabled': true, 'spreset_condition_script': 'synthetic-condition'});
  await h.engine.setPreset(ChatPreset(raw));
  final actor = await h.card('Entry authorization actor');
  final chat = await h.emptyChat(actor);
  final context = await h.context(chat, characterId: actor);
  return (h: h, host: host, chat: chat, context: context);
}

Map<String, Object?> _toolResponse(String name) => {
  'choices': [
    {
      'index': 0,
      'message': {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-fixture',
            'type': 'function',
            'function': {'name': name, 'arguments': '{}'},
          },
        ],
      },
      'finish_reason': 'tool_calls',
    },
  ],
};

List<String> _toolNames(Map<String, Object?> body) => [
  for (final item in (body['tools'] as List<Object?>? ?? const []))
    ((item! as Map<String, Object?>)['function']! as Map<String, Object?>)['name']! as String,
];

void _succeeded(List<TavernEvent> events) {
  final failures = events.whereType<TavernTurnFailed>().toList();
  expect(failures, isEmpty, reason: failures.map((failure) => '${failure.kind.name}: ${failure.detail}').join('\n'));
  expect(events.whereType<TavernTurnDone>(), hasLength(1));
}
