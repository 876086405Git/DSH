import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'spreset_engine_test.dart' show SPresetHost, preset, toolExtension;
import 'support/stage1_engine_harness.dart';

void main() {
  for (final mode in ['sync', 'read']) {
    test('cancel after $mode receiver creation releases the late returned receiver after actual drain', () async {
      final h = await Stage1Harness.open(state: false, deepseek: false);
      final host = _LateRegistryHost(mode);
      h.engine.scripts.attachHost(host);
      await h.engine.setPreset(preset(toolExtension(), calling: true));
      Object? streamError;
      final eventsFuture = h.engine.send(h.chatId, 'late registry resource probe').toList().catchError((Object error) {
        streamError = error;
        return <TavernEvent>[];
      });
      Future<void>? closing;
      var closed = false;
      try {
        await host.created.future;
        host.trace.add('stop');
        h.engine.stop(h.chatId);
        host.trace.add('close-start');
        closing = h.engine.close().then((_) {
          closed = true;
          host.trace.add('close-complete');
        });
        await Future<void>.delayed(Duration.zero);
        final closedWhileHeld = closed;
        final releasedWhileHeld = List<String>.of(host.released);
        host.trace.add('release-actual-host-future');
        host.allowResult.complete();
        await host.actualReturning.future;
        final events = await eventsFuture;
        await closing;
        final evidence = {
          'registryMode': mode,
          'boundary':
              'Real public native engine/SQLite and host Future; receiver storage is controlled Dart host state, not WebView.',
          'trace': host.trace,
          'closedWhileHostHeld': closedWhileHeld,
          'releasedWhileHostHeld': releasedWhileHeld,
          'evalSession': host.registry!.sessionId,
          'returnedToolSession': host.receiverSession,
          'releasedAfterClose': host.released,
          'liveReceiversAfterClose': host.liveReceivers.toList(),
          'modelCalls': h.model.generated,
          'events': events.map((event) => event.runtimeType.toString()).toList(),
          'streamError': streamError?.toString(),
        };
        print('LATE_REGISTRY_RELEASE ${jsonEncode(evidence)}');
        expect(closedWhileHeld, isFalse, reason: 'Logical cancellation is not actual host drain.');
        expect(releasedWhileHeld, isEmpty);
        expect(streamError, isNull);
        expect(h.model.generated, 0);
        expect(host.actions, 0);
        expect(host.released, contains(host.registry!.sessionId));
        expect(
          host.released,
          contains(host.receiverSession),
          reason: 'Actual late registry result owns this receiver.',
        );
        expect(host.liveReceivers, isEmpty);
      } finally {
        if (!host.allowResult.isCompleted) host.allowResult.complete();
        await eventsFuture;
        await closing;
      }
    });
  }
}

class _LateRegistryHost extends SPresetHost {
  _LateRegistryHost(this.targetMode) {
    handler = (request) async {
      final response = await defaultEvaluate(request);
      if (request.kind != TavernSPresetEvaluationKind.toolRegistry) return response;
      final mode = (request.arguments.single! as Map)['registryMode'] ?? 'sync';
      if (mode != targetMode || registry != null) return response;
      registry = request;
      final value = response.value! as Map<String, Object?>;
      final tools = (value['tools']! as List<Object?>).cast<Map<String, Object?>>();
      expect(tools, hasLength(1));
      if (mode == 'read') {
        // A later shared-registry read can expose a receiver absent in early sync.
        // The controlled host reports that fact; it does not emulate page JavaScript.
        tools.single['sessionId'] = 'tool:late_fixture_tool';
        (tools.single['definition']! as Map<String, Object?>)['name'] = 'late_fixture_tool';
      }
      receiverSession = '${request.sessionScope}:${tools.single['sessionId']}';
      liveReceivers.add(receiverSession);
      trace.add('receiver-created');
      created.complete();
      await allowResult.future;
      trace.add('actual-host-result-returning');
      actualReturning.complete();
      return TavernSPresetEvaluationResult(
        requestId: request.requestId,
        value: value,
        committed: response.committed,
        arguments: response.arguments,
      );
    };
  }
  final String targetMode;
  final created = Completer<void>();
  final allowResult = Completer<void>();
  final actualReturning = Completer<void>();
  final liveReceivers = <String>{};
  final trace = <String>[];
  TavernSPresetEvaluationRequest? registry;
  late String receiverSession;

  @override
  Future<void> releaseSPresetSession(String sessionId) async {
    trace.add('release:$sessionId');
    liveReceivers.remove(sessionId);
    await super.releaseSPresetSession(sessionId);
  }
}
