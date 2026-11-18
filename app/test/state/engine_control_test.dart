import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart' show operatingSystemProvider;
import 'package:dsh_app/state/engine_control.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart';

class _Runtime extends RecordingRuntime {
  _Runtime(super.initial, this.calls);
  final List<String> calls;

  @override
  Future<void> stop() {
    calls.add('stop');
    return super.stop();
  }

  @override
  Future<void> start() async {
    calls.add('start');
    await super.start();
  }

  @override
  Future<void> startIn(EngineMode mode) async {
    calls.add(mode.name);
    await super.startIn(mode);
  }
}

class _Bridge extends FakeBridge {
  _Bridge(this.order);
  final List<String> order;
  @override
  Future<LastKnownGood> restoreLastKnownGood() async {
    order.add('restore');
    return const LastKnownGood.none();
  }
}

void main() {
  LocalRuntimeState phase(RuntimePhase phase) => LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: phase));

  test('restart already stopping waits for installed without another stop', () async {
    final calls = <String>[];
    final runtime = _Runtime(phase(RuntimePhase.stopping), calls);
    final container = ProviderContainer(overrides: [localRuntimeProvider.overrideWith(() => runtime)]);
    addTearDown(container.dispose);
    final restarting = EngineControl.restart(container);
    expect(runtime.stops, 0);
    expect(calls, isEmpty);
    runtime.emit(phase(RuntimePhase.installed));
    await restarting;
    expect(calls, ['start']);
  });

  test('safe mode restore precedes stop and normal start', () async {
    final calls = <String>[];
    final runtime = _Runtime(LocalRuntimeState(loaded: true, status: safeStatus()), calls);
    final container = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime),
        runtimeBridgeProvider.overrideWithValue(_Bridge(calls)),
      ],
    );
    addTearDown(container.dispose);
    await EngineControl.restoreLastKnownGood(container);
    expect(calls, ['restore', 'stop', 'normal']);
  });

  test('OH safe mode waits for stop before restore and normal start', () async {
    final calls = <String>[];
    final runtime = _Runtime(LocalRuntimeState(loaded: true, status: safeStatus()), calls);
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('ohos'),
        localRuntimeProvider.overrideWith(() => runtime),
        runtimeBridgeProvider.overrideWithValue(_Bridge(calls)),
      ],
    );
    addTearDown(container.dispose);
    await EngineControl.restoreLastKnownGood(container);
    expect(calls, ['stop', 'restore', 'normal']);
  });

  test('Android safe mode preserves restore before stop and normal start', () async {
    final calls = <String>[];
    final runtime = _Runtime(LocalRuntimeState(loaded: true, status: safeStatus()), calls);
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('android'),
        localRuntimeProvider.overrideWith(() => runtime),
        runtimeBridgeProvider.overrideWithValue(_Bridge(calls)),
      ],
    );
    addTearDown(container.dispose);
    await EngineControl.restoreLastKnownGood(container);
    expect(calls, ['restore', 'stop', 'normal']);
  });
}
