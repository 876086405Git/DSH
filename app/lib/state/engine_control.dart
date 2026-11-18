import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'android_features.dart' show operatingSystemProvider;

/// Multi-step engine actions built on [localRuntimeProvider].
///
/// They take the [ProviderContainer] (not a WidgetRef) so they keep working after
/// the screen that started them is popped.
abstract final class EngineControl {
  /// Stops the local DSH, waits for exit, then requests a new start.
  /// An incomplete stop leaves the engine stopping; no new start is requested.
  /// [mode] null keeps the current mode (a restart in safe mode stays in safe mode).
  /// Returns false when the stop did not finish, so no start was requested.
  static Future<bool> restart(ProviderContainer container, {EngineMode? mode}) => _restart(container, mode: mode);

  static Future<bool> _restart(ProviderContainer container, {EngineMode? mode}) async {
    final runtime = container.read(localRuntimeProvider.notifier);
    final phase = container.read(localRuntimeProvider).status.phase;
    if (phase == RuntimePhase.running || phase == RuntimePhase.starting || phase == RuntimePhase.stopping) {
      if (!await _stopAndWait(container)) return false;
    }
    if (mode == null) {
      await runtime.start();
    } else {
      await runtime.startIn(mode);
    }
    return true;
  }

  /// Changes the local index mode only after stopping, then requests a start
  /// in the existing normal/safe profile. A rejected stop or write cannot start.
  static Future<void> setWorkspaceRecovery(ProviderContainer container, {required bool enabled}) async {
    if (!await _stopAndWait(container)) throw PlatformException(code: 'runtime_not_stopped');
    await container.read(runtimeBridgeProvider).setWorkspaceRecovery(enabled);
    if (!await _restart(container)) {
      throw PlatformException(code: 'runtime_not_stopped_after_recovery');
    }
  }

  /// Starts the engine unless it is already starting or running.
  static Future<void> ensureStarted(ProviderContainer container) async {
    final phase = container.read(localRuntimeProvider).status.phase;
    if (phase == RuntimePhase.installed || phase == RuntimePhase.error) {
      await container.read(localRuntimeProvider.notifier).start();
    }
  }

  /// Whether the launch-time auto start should run. After two failures in a row with
  /// automatic safe mode turned off, the failure card waits for the user instead.
  /// In every other case `start()` itself picks the right mode, so callers need
  /// nothing else.
  static bool shouldAutoStart(RuntimeStatus status) =>
      !(status.safeState == SafeModeState.off && !status.autoSafe && status.strikes >= 2);

  /// What the launch-time start goes by. A run that merely didn't end cleanly
  /// (HarmonyOS, [RuntimeFailure.causeUnknown]: the system reclaiming the app
  /// reads the same) doesn't stop the next one until [shouldAutoStart] says so.
  static bool startsAtLaunch(RuntimeStatus status) {
    final unclean =
        status.phase == RuntimePhase.error &&
        status.error == null &&
        status.failure?.kind == FailureKind.killed &&
        status.failure!.causeUnknown;
    return (status.phase == RuntimePhase.installed || unclean) && shouldAutoStart(status);
  }

  /// Stops before renaming home-level files, then starts the safe profile.
  static Future<void> enterSafeMode(ProviderContainer container, {List<String> moveAside = const []}) async {
    if (moveAside.isEmpty) {
      if (!await _restart(container, mode: EngineMode.safe)) throw PlatformException(code: 'runtime_not_stopped');
      return;
    }
    if (!await _stopAndWait(container)) throw PlatformException(code: 'runtime_not_stopped');
    await container.read(runtimeBridgeProvider).moveAside(moveAside);
    if (!await _restart(container, mode: EngineMode.safe)) {
      throw PlatformException(code: 'runtime_not_stopped_after_recovery');
    }
  }

  /// Back to the user's own profile; failing again within two minutes returns to safe mode.
  static Future<void> leaveSafeMode(ProviderContainer container) => restart(container, mode: EngineMode.normal);

  /// Puts the main profile back to its last good plugin set, then starts in normal mode
  /// (from safe mode that is the two-minute trial). Needs no model, key or network.
  static Future<LastKnownGood> restoreLastKnownGood(ProviderContainer container) async {
    final status = container.read(localRuntimeProvider).status;
    final busy =
        status.phase == RuntimePhase.running ||
        status.phase == RuntimePhase.starting ||
        status.phase == RuntimePhase.stopping;
    // Only a currently running safe profile may keep running during this write.
    // OH must observe the embedded Node's exit even when its safe profile runs.
    final safeRunning =
        status.inSafeMode &&
        status.phase == RuntimePhase.running &&
        container.read(operatingSystemProvider) != 'ohos';
    if (busy && !safeRunning && !await _stopAndWait(container)) {
      throw PlatformException(code: 'runtime_not_stopped');
    }
    final changed = await container.read(runtimeBridgeProvider).restoreLastKnownGood();
    if (!await _restart(container, mode: EngineMode.normal)) {
      throw PlatformException(code: 'runtime_not_stopped_after_recovery');
    }
    return changed;
  }

  static Future<bool> _stopAndWait(ProviderContainer container) async {
    bool stoppedNow() {
      final phase = container.read(localRuntimeProvider).status.phase;
      return !phase.isBusy && phase != RuntimePhase.running;
    }

    final stopped = Completer<bool>();
    final sub = container.listen<RuntimePhase>(localRuntimeProvider.select((s) => s.status.phase), (_, next) {
      if (!next.isBusy && next != RuntimePhase.running && !stopped.isCompleted) {
        stopped.complete(true);
      }
    });
    try {
      if (stoppedNow()) return true;
      if (container.read(localRuntimeProvider).status.phase != RuntimePhase.stopping) {
        await container.read(localRuntimeProvider.notifier).stop();
      }
      if (stoppedNow()) return true;
      // This bounds the UI wait, not native cleanup. Native recovery rechecks ownership.
      return await stopped.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
    } finally {
      sub.close();
    }
  }
}
