import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

ScriptJson _data() => <String, Object?>{
  'stat_data': <String, Object?>{'counter': 1},
  'schema': <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
};

bool _isMvu(TavernScriptDispatch request) => const {
  'mag_variable_initialized',
  'mag_variable_update_started',
  'mag_command_parsed',
  'mag_variable_update_ended',
}.contains(request.name);

// These are the actual chat, node and state carriers. This is not an assertion
// that arbitrary macro/listener side effects cannot write other resources.
ScriptJson _rows(ScriptFixture h) => h.inspect(
  (db) => <String, Object?>{
    'chats': [for (final row in db.select('SELECT * FROM chats ORDER BY id')) Map<String, Object?>.from(row)],
    'nodes': [for (final row in db.select('SELECT * FROM nodes ORDER BY seq')) Map<String, Object?>.from(row)],
    'states': [
      for (final row in db.select('SELECT * FROM node_states ORDER BY node_id')) Map<String, Object?>.from(row),
    ],
  },
);

// Retain the exact Future returned to the engine by the real fixture host.
// Waiting for it below is test cleanup after the engine's cancellation race.
class _MvuHost extends ScriptHost {
  Future<TavernScriptDispatchAck>? parsedDispatch;

  @override
  Future<TavernScriptDispatchAck> dispatch(TavernScriptDispatch request, TavernScriptCancellation cancellation) {
    final future = super.dispatch(request, cancellation);
    if (request.name == 'mag_command_parsed') {
      parsedDispatch = future;
    }
    return future;
  }
}

void main() {
  test('MVU Bridge carries sequential JSON feedback without adopting the manual candidate', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('MVU feedback', greeting: 'A physical greeting.');
    final chat = await h.engine.createChat(character);
    final first = await h.context(chat, instanceId: 'mvu-first');
    final second = await h.context(chat, instanceId: 'mvu-second');
    final otherChat = await h.engine.createChat(character);
    final other = await h.context(otherChat, instanceId: 'mvu-other-chat');
    final host = ScriptHost();
    final events = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    final order = <(String, String)>[];
    final initialCounters = <Object?>[];
    final secondBeforeCounters = <Object?>[];
    var clearCommands = false;

    host.onDispatch = (request, cancellation) async {
      if (!_isMvu(request)) {
        return TavernScriptDispatchAck(eventId: request.eventId);
      }
      expect(request.chatId, chat);
      expect(request.contextId, isNot(other.id));
      expect(request.namespace, 'tavern');
      final args = request.args;
      final data = scriptMap(args.first);
      final isFirst = request.contextId == first.id;
      order.add((request.contextId, request.name!));
      switch (request.name) {
        case 'mag_variable_update_started':
          if (isFirst) {
            initialCounters.add(scriptMap(data['stat_data'])['counter']);
            scriptMap(data['stat_data'])['counter'] = 5;
          } else {
            expect(request.contextId, second.id);
            expect(scriptMap(data['stat_data'])['counter'], 5);
          }
          return TavernScriptDispatchAck(
            eventId: request.eventId,
            mvu: TavernScriptMvuFeedback(data: data),
          );
        case 'mag_command_parsed':
          if (isFirst) {
            return TavernScriptDispatchAck(
              eventId: request.eventId,
              mvu: TavernScriptMvuFeedback(
                data: data,
                commands: clearCommands
                    ? <ScriptJson>[]
                    : <ScriptJson>[
                        <String, Object?>{
                          'type': 'add',
                          'full_match': 'listener numeric addition',
                          'args': <Object?>['counter', 2],
                          'reason': '',
                        },
                      ],
              ),
            );
          }
          if (clearCommands) {
            expect(args[1], isEmpty);
          } else {
            expect(args[1], [
              <String, Object?>{
                'type': 'add',
                'full_match': 'listener numeric addition',
                'args': <Object?>['counter', 2],
                'reason': '',
              },
            ]);
          }
          // Omitted commands preserve the preceding context's actual list.
          return TavernScriptDispatchAck(
            eventId: request.eventId,
            mvu: TavernScriptMvuFeedback(data: data),
          );
        case 'mag_variable_update_ended':
          final before = scriptMap(args[1]);
          if (isFirst) {
            scriptMap(before['stat_data'])['counter'] = scriptMap(data['stat_data'])['counter'];
            return TavernScriptDispatchAck(
              eventId: request.eventId,
              mvu: TavernScriptMvuFeedback(data: data, beforeData: before),
            );
          }
          secondBeforeCounters.add(scriptMap(before['stat_data'])['counter']);
          return TavernScriptDispatchAck(
            eventId: request.eventId,
            mvu: TavernScriptMvuFeedback(data: data),
          );
        default:
          throw StateError('Manual parsing unexpectedly initialized a physical page.');
      }
    };
    h.bridge.attachHost(host);
    final stored = _rows(h);
    final previous = _data();
    final result = await h.bridge.parseMvuMessage(first.id, "_.add('counter', 1);", previous);
    expect(result.issues, isEmpty);
    expect(scriptMap(result.data['stat_data'])['counter'], 7);
    expect(previous, _data());
    expect(initialCounters, [1]);
    expect(secondBeforeCounters, [7]);
    expect(order, [
      (first.id, 'mag_variable_update_started'),
      (second.id, 'mag_variable_update_started'),
      (first.id, 'mag_command_parsed'),
      (second.id, 'mag_command_parsed'),
      (first.id, 'mag_variable_update_ended'),
      (second.id, 'mag_variable_update_ended'),
    ]);
    // Ended feedback changes the core comparison candidate. Without that
    // feedback, the changed counter would generate its schema property.
    expect(result.data['schema'], <String, Object?>{'type': 'object', 'properties': <String, Object?>{}});
    await events.until(
      (event) =>
          event.name == 'mag_variable_update_ended' && event.contextId == second.id && event.phase == 'acknowledged',
    );

    clearCommands = true;
    order.clear();
    final mutableInput = _data();
    final pending = h.bridge.parseMvuMessage(first.id, "_.add('counter', 1);", mutableInput);
    scriptMap(mutableInput['stat_data'])['counter'] = 88;
    final cleared = await pending;
    expect(cleared.issues, isEmpty);
    expect(scriptMap(cleared.data['stat_data'])['counter'], 5);
    expect(initialCounters, [1, 1]);
    expect(secondBeforeCounters, [7, 5]);
    expect(scriptMap(mutableInput['stat_data'])['counter'], 88);

    h.bridge.attachHost(null);
    final unhosted = await h.bridge.parseMvuMessage(first.id, "_.add('counter', 1);", previous);
    expect(unhosted.issues, isEmpty);
    expect(scriptMap(unhosted.data['stat_data'])['counter'], 2);
    expect(previous, _data());
    expect(events.values.where((event) => _isMvu(event.dispatch)).every((event) => !event.committed), isTrue);
    expect(_rows(h), stored);
    h.expectNoGeneration();
  });

  test('MVU Bridge rejects invalid and late feedback while retaining real external commit facts', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('MVU cancellation', greeting: 'Keep this physical page.');
    final chat = await h.engine.createChat(character);
    final context = await h.context(chat, instanceId: 'mvu-caller');
    final listener = await h.context(chat, instanceId: 'mvu-waiting-listener');
    final host = _MvuHost();
    final events = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    final previous = _data();
    ScriptJson? afterExternalWrite;
    String? wrongEvent;

    host.onDispatch = (request, cancellation) async {
      if (request.name != 'mag_command_parsed') {
        return TavernScriptDispatchAck(eventId: request.eventId);
      }
      await h.bridge.replaceVariables(context.id, scriptChat, <String, Object?>{'external': 'kept'});
      afterExternalWrite = _rows(h);
      wrongEvent = request.eventId;
      final data = scriptMap(request.args.first);
      scriptMap(data['stat_data'])['counter'] = 999;
      return TavernScriptDispatchAck(
        eventId: 'different-${request.eventId}',
        issues: [
          TavernScriptIssue(
            code: 'external_write',
            message: 'The chat variable write completed.',
            committed: true,
            contextId: context.id,
            eventId: request.eventId,
          ),
        ],
        mvu: TavernScriptMvuFeedback(data: data),
      );
    };
    h.bridge.attachHost(host);
    await expectLater(
      h.bridge.parseMvuMessage(context.id, "_.add('counter', 1);", previous),
      throwsA(
        scriptError(TavernScriptErrorCode.hookFailure)
            .having((error) => error.committed, 'actual external commit', isTrue)
            .having(
              (error) => error.issues.any((issue) => issue.code == 'external_write' && issue.committed),
              'preserved external receipt',
              isTrue,
            ),
      ),
    );
    expect(afterExternalWrite, isNotNull);
    expect(_rows(h), afterExternalWrite);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value, <String, Object?>{'external': 'kept'});
    final failed = await events.until((event) => event.dispatch.eventId == wrongEvent && event.phase == 'failed');
    expect(failed.committed, isTrue);
    expect(host.deliveries.where((request) => request.name == 'mag_variable_update_ended'), isEmpty);
    expect(previous, _data());

    final stored = _rows(h);
    host.deliveries.clear();
    host.onDispatch = (request, cancellation) async {
      if (request.name != 'mag_variable_update_started') {
        return TavernScriptDispatchAck(eventId: request.eventId);
      }
      final data = scriptMap(request.args.first);
      scriptMap(data['stat_data'])['counter'] = 999;
      return TavernScriptDispatchAck(
        eventId: request.eventId,
        mvu: TavernScriptMvuFeedback(data: data, commands: <ScriptJson>[]),
      );
    };
    await expectLater(
      h.bridge.parseMvuMessage(context.id, "_.add('counter', 1);", previous),
      throwsA(
        scriptError(TavernScriptErrorCode.hookFailure)
            .having((error) => error.committed, 'candidate not adopted', isFalse)
            .having(
              (error) =>
                  error.issues.any((issue) => issue.code == 'shapeMismatch' && issue.details['field'] == 'commands'),
              'phase field rejected',
              isTrue,
            ),
      ),
    );
    expect(host.deliveries.where((request) => request.name == 'mag_command_parsed'), isEmpty);
    expect(_rows(h), stored);
    expect(previous, _data());

    // A completed macro effect remains committed when a later MVU phase
    // rejects its candidate. The public parse still never writes that candidate.
    host.onDispatch = (request, cancellation) async => TavernScriptDispatchAck(
      eventId: request.name == 'mag_variable_update_started' ? 'wrong-${request.eventId}' : request.eventId,
    );
    await expectLater(
      h.bridge.parseMvuMessage(context.id, "{{setglobalvar::mvu_receipt::saved}}_.add('counter', 1);", previous),
      throwsA(
        scriptError(
          TavernScriptErrorCode.hookFailure,
        ).having((error) => error.committed, 'earlier macro adoption survives phase failure', isTrue),
      ),
    );
    const globalTarget = TavernVariableTarget(scope: TavernVariableScope.global);
    final savedGlobals = (await h.bridge.getVariables(context.id, globalTarget)).value;
    expect(savedGlobals['mvu_receipt'], 'saved');
    expect(_rows(h), stored);

    // Native init expansion creates a pending global intent, but a failed
    // settings write must not be reported as an adopted file or MVU candidate.
    host.onDispatch = (request, cancellation) async => TavernScriptDispatchAck(eventId: request.eventId);
    await h.bridge.replaceBook(context.id, TavernScriptBookRef.embedded(characterId: character), <String, Object?>{
      'name': 'MVU pending global',
      'entries': <Object?>[
        <String, Object?>{
          'id': 1,
          'comment': '[initvar]pending',
          'keys': <String>[],
          'enabled': false,
          'insertion_order': 0,
          'content': 'counter: 1{{setglobalvar::mvu_pending::unsaved}}',
          'extensions': <String, Object?>{},
        },
      ],
    });
    final blocker = Directory('${h.engine.directory.path}/settings.json.writing');
    await blocker.create();
    try {
      await expectLater(
        h.bridge.setMvuEnabled(context.id, true),
        throwsA(
          scriptError(
            TavernScriptErrorCode.storage,
          ).having((error) => error.committed, 'pending intent is not file adoption', isFalse),
        ),
      );
      expect((await h.bridge.getVariables(context.id, globalTarget)).value, savedGlobals);
      expect(_rows(h), stored);
    } finally {
      await blocker.delete();
    }
    // Explicitly replace through the real writer to settle the failed native
    // intent before the rest of this same fixture continues.
    await h.bridge.replaceVariables(context.id, globalTarget, savedGlobals);

    final entered = Completer<void>();
    final release = Completer<void>();
    TavernScriptCancellation? capturedCancellation;
    host.parsedDispatch = null;
    host.deliveries.clear();
    host.onDispatch = (request, cancellation) {
      if (request.name != 'mag_command_parsed' || request.contextId != listener.id) {
        return Future.value(TavernScriptDispatchAck(eventId: request.eventId));
      }
      capturedCancellation = cancellation;
      entered.complete();
      return release.future.then((_) {
        final data = scriptMap(request.args.first);
        scriptMap(data['stat_data'])['counter'] = 999;
        return TavernScriptDispatchAck(
          eventId: request.eventId,
          mvu: TavernScriptMvuFeedback(data: data),
        );
      });
    };
    final running = h.bridge.parseMvuMessage(context.id, "_.add('counter', 1);", previous);
    // Observe the original rejection immediately; keep its actual error as
    // the oracle even if a gate assertion fails before the normal await.
    final outcome = running.then<Object>((value) => value, onError: (Object error, StackTrace _) => error);
    try {
      await entered.future.timeout(const Duration(seconds: 5));
      // The caller closes while a different context owns the pending Ack.
      await h.bridge.closeContext(context.id);
      expect(
        await outcome.timeout(const Duration(seconds: 5)),
        scriptError(TavernScriptErrorCode.cancelled).having((error) => error.committed, 'cancelled candidate', isFalse),
      );
      expect(capturedCancellation?.isCancelled, isTrue);
      expect(host.deliveries.where((request) => request.name == 'mag_variable_update_ended'), isEmpty);
      expect(_rows(h), stored);
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
      try {
        await h.bridge.closeContext(context.id);
      } finally {
        try {
          await outcome;
        } finally {
          final originalDispatch = host.parsedDispatch;
          if (originalDispatch != null) {
            await originalDispatch;
          }
        }
      }
    }
    expect(_rows(h), stored);
    expect(previous, _data());
    h.expectNoGeneration();
  });
}
