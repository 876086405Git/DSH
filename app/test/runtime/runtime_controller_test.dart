import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends RuntimeBridge {
  final stream = StreamController<RuntimeEvent>.broadcast(sync: true);
  final initialStatus = Completer<RuntimeStatus>();
  final initialLogs = Completer<RuntimeLogSnapshot>();
  final statusResults = <Completer<RuntimeStatus>>[];

  @override
  Stream<RuntimeEvent> get events => stream.stream;
  @override
  Future<RuntimeStatus> status() {
    final result = statusResults.isEmpty ? initialStatus : Completer<RuntimeStatus>();
    statusResults.add(result);
    return result.future;
  }

  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) => initialLogs.future;

  Object? startError;
  Object? reopenError;
  var reopens = 0;

  @override
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) async {
    if (startError case final error?) throw error;
  }

  @override
  Future<void> reopenApp() async {
    reopens++;
    if (reopenError case final error?) throw error;
  }

  @override
  Future<void> reset({ResetKeep keep = const ResetKeep()}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late _Bridge bridge;
  late ProviderContainer container;
  setUp(() {
    bridge = _Bridge();
    container = ProviderContainer(overrides: [runtimeBridgeProvider.overrideWithValue(bridge)]);
    container.read(localRuntimeProvider);
  });
  tearDown(() async {
    container.dispose();
    await bridge.stream.close();
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('no native runtime (no dsh/runtime handler): loaded, only remote hosts', () async {
    bridge.initialStatus.completeError(MissingPluginException());
    await flush();
    final state = container.read(localRuntimeProvider);
    expect(state.loaded, isTrue);
    expect(state.available, isFalse);
  });

  test('any other status failure still counts as a runtime that is there', () async {
    bridge.initialStatus.completeError(PlatformException(code: 'io'));
    await flush();
    expect(container.read(localRuntimeProvider).available, isTrue);
  });

  test('late logs cannot overwrite a newer running event', () async {
    bridge.initialStatus.complete(const RuntimeStatus(phase: RuntimePhase.starting));
    await flush();
    expect(container.read(localRuntimeProvider).loaded, isTrue);
    bridge.stream.add(const RuntimeStatusEvent(RuntimeStatus(phase: RuntimePhase.running)));
    bridge.initialLogs.complete(const RuntimeLogSnapshot([RuntimeLogEntry(1, 'old log', 'stdout')], 1));
    await flush();
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.running);
    expect(container.read(localRuntimeLogsProvider), ['old log']);
  });

  for (final latest in [
    const RuntimeStatus(
      phase: RuntimePhase.running,
      baseUrl: 'http://127.0.0.1:41234',
      token: 'synthetic-current-launch',
    ),
    const RuntimeStatus(phase: RuntimePhase.installed),
    const RuntimeStatus(phase: RuntimePhase.installing),
  ]) {
    test('late initial status cannot overwrite a newer ${latest.phase.name} event', () async {
      bridge.stream.add(RuntimeStatusEvent(latest));
      expect(container.read(localRuntimeProvider).status, same(latest));
      if (latest.phase == RuntimePhase.installing) {
        bridge.stream.add(const RuntimeProgressEvent(step: 'extract', done: 1, total: 2));
      }
      bridge.initialStatus.complete(
        const RuntimeStatus(
          phase: RuntimePhase.running,
          baseUrl: 'http://127.0.0.1:3080',
          token: 'synthetic-retired-launch',
        ),
      );
      await flush();
      final current = container.read(localRuntimeProvider);
      expect(
        (current.status.phase, current.status.baseUrl, current.status.token),
        (latest.phase, latest.baseUrl, latest.token),
      );
      expect(current.loaded, isTrue);
      if (latest.phase == RuntimePhase.installing) expect(current.progress?.done, 1);
    });
  }

  test('the status read after reset supersedes a pending initial read', () async {
    final reset = container.read(localRuntimeProvider.notifier).reset();
    await flush();
    expect(bridge.statusResults, hasLength(2));
    const resetStatus = RuntimeStatus(phase: RuntimePhase.notInstalled);
    bridge.statusResults.last.complete(resetStatus);
    await reset;
    bridge.initialStatus.complete(
      const RuntimeStatus(
        phase: RuntimePhase.running,
        baseUrl: 'http://127.0.0.1:3080',
        token: 'synthetic-retired-launch',
      ),
    );
    await flush();
    final status = container.read(localRuntimeProvider).status;
    expect((status.phase, status.baseUrl, status.token), (RuntimePhase.notInstalled, null, null));
  });

  test('a retired read failure cannot finish loading for a newer read', () async {
    final reset = container.read(localRuntimeProvider.notifier).reset();
    await flush();
    expect(bridge.statusResults, hasLength(2));
    bridge.initialStatus.completeError(StateError('retired status query failed'));
    await flush();
    final loadedWhilePending = container.read(localRuntimeProvider).loaded;
    bridge.statusResults.last.complete(const RuntimeStatus(phase: RuntimePhase.notInstalled));
    await reset;
    expect(loadedWhilePending, isFalse);
    expect(container.read(localRuntimeProvider).loaded, isTrue);
  });

  test('keeps the most recent 1000 log lines', () async {
    bridge.initialStatus.complete(const RuntimeStatus(phase: RuntimePhase.installed));
    bridge.initialLogs.complete(const RuntimeLogSnapshot([], 0));
    await flush();
    for (var i = 0; i < 1005; i++) {
      bridge.stream.add(RuntimeLogsEvent([RuntimeLogEntry(i + 1, 'line $i', 'stdout')]));
    }
    final logs = container.read(localRuntimeLogsProvider);
    expect(logs.length, 1000);
    expect(logs.first, 'line 5');
    expect(logs.last, 'line 1004');
  });

  test('leaving installation clears progress and notices advance sequence', () {
    bridge.stream.add(const RuntimeStatusEvent(RuntimeStatus(phase: RuntimePhase.installing)));
    bridge.stream.add(const RuntimeProgressEvent(step: 'extract', done: 1, total: 2));
    expect(container.read(localRuntimeProvider).progress?.done, 1);
    bridge.stream.add(const RuntimeStatusEvent(RuntimeStatus(phase: RuntimePhase.running)));
    expect(container.read(localRuntimeProvider).progress, isNull);
    bridge.stream.add(const RuntimeNoticeEvent('已启动'));
    expect(container.read(localRuntimeProvider).notice?.seq, 1);
    bridge.stream.add(const RuntimeNoticeEvent('已启动'));
    expect(container.read(localRuntimeProvider).notice?.seq, 2);
  });

  group('a start HarmonyOS can only do in a new process', () {
    final once = PlatformException(code: 'ohos_restart_required');

    test('reopens the app', () async {
      bridge.startError = once;
      await container.read(localRuntimeProvider.notifier).start();
      expect(bridge.reopens, 1);
      expect(container.read(localRuntimeProvider).notice, isNull);
    });

    test('says so when the system refuses, and goes no further', () async {
      bridge.startError = once;
      bridge.reopenError = PlatformException(code: '16000053');
      await container.read(localRuntimeProvider.notifier).startIn(EngineMode.normal);
      expect(bridge.reopens, 1);
      expect(container.read(localRuntimeProvider).notice, isNotNull);
    });

    test('any other refusal stays the caller\'s', () async {
      bridge.startError = PlatformException(code: 'install_busy');
      await expectLater(container.read(localRuntimeProvider.notifier).start(), throwsA(isA<PlatformException>()));
      expect(bridge.reopens, 0);
    });

    test('a plain start asks nothing more', () async {
      await container.read(localRuntimeProvider.notifier).start();
      expect(bridge.reopens, 0);
    });
  });

  test('a status failure still ends initial loading', () async {
    bridge.initialStatus.completeError(StateError('offline'));
    await flush();
    expect(container.read(localRuntimeProvider).loaded, isTrue);
  });
}
