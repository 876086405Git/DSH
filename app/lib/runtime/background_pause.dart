// HarmonyOS suspends an app soon after it leaves the screen, and the on-device
// engine runs as this app: a turn left running gets the system's short grant at
// best, then stops where it is, with nothing to say it did. How long the grant was
// and whether the turn can pick up afterwards take a device to know, so this says
// only that it may have paused: one quiet line in the chat on the way back
// (ui/notify/background_pause_host.dart draws it). With the long-running task held for
// the whole time away, nothing paused, so there's no line. Android's own line, about a phone
// cutting the network, is runtime/background_net.dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'runtime_bridge.dart' show RuntimeBackgroundTask;
import 'runtime_state.dart';

import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show appForegroundProvider, launchNoticeShownProvider;
import '../state/sessions_state.dart';

/// The decision, without timers or the platform (unit-tested).
abstract final class BackgroundPausePolicy {
  /// Away this long and the app may well have been suspended. The system only
  /// says 「几秒」 (best practices, background tasks), and a running turn's grant
  /// can run longer: well past the first, so a quick look at another app isn't
  /// told about a pause it most likely never had.
  static const suspendedAfter = Duration(seconds: 10);

  /// Whether a return after [away] calls for the line: the on-device engine is
  /// the [local] host (a remote one kept going), and its turn [wasRunning] on
  /// leaving and is [running] still (one that ended first has nothing to go on with),
  /// and no long-running task [keptRunning] the turn going all that time (HarmonyOS).
  /// Nor did it pause if the system is still letting it [continued] (iOS 26); one that
  /// lost that did.
  static bool onReturn({
    required Duration away,
    required bool local,
    required bool wasRunning,
    required bool running,
    bool keptRunning = false,
    bool continued = false,
  }) => local && wasRunning && running && !keptRunning && !continued && away >= suspendedAfter;
}

/// Whether the line shows. It follows the app on and off screen by itself; a
/// tap dismisses it and it goes by itself while the turn may well have moved on.
class BackgroundPauseController extends Notifier<bool> {
  /// How long the line stays: the pause is only news for a moment.
  @visibleForTesting
  static Duration shownFor = const Duration(seconds: 8);

  /// The clock (tests).
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// When the app left, and whether a turn was going then.
  DateTime? _since;
  bool _wasRunning = false;

  /// Whether the long-running task started while away, and whether it then ended
  /// with the app still away, which leaves the turn to the short grant at best.
  bool _taskHeld = false;
  bool _taskLost = false;
  Timer? _timer;

  @override
  bool build() {
    ref.listen(appForegroundProvider, (_, foreground) => _onScreen(foreground));
    // Over a remote host's conversation it would be about something else.
    ref.listen(activeHostProvider, (_, host) {
      if (!host.isLocal) dismiss();
    });
    ref.listen(localRuntimeProvider.select((runtime) => runtime.status.backgroundTask), (_, task) => _onTask(task));
    ref.onDispose(() => _timer?.cancel());
    return false;
  }

  /// The conversation open now has a turn going.
  bool get _turnRunning {
    final sessionId = ref.read(currentSessionProvider);
    return sessionId != null && ref.exists(chatProvider(sessionId)) && ref.read(chatProvider(sessionId)).running;
  }

  void _onTask(RuntimeBackgroundTask? task) {
    if (_since == null) return;
    if (task?.longRunning == true) {
      _taskHeld = true;
    } else if (_taskHeld && task?.foreground != true) {
      _taskLost = true;
    }
  }

  void _onScreen(bool foreground) {
    if (!foreground) {
      dismiss();
      _since = now();
      _wasRunning = _turnRunning;
      _taskHeld = _taskLost = false;
      return;
    }
    final since = _since;
    _since = null;
    if (since == null) return;
    final due = BackgroundPausePolicy.onReturn(
      away: now().difference(since),
      local: ref.read(activeHostProvider).isLocal,
      wasRunning: _wasRunning,
      running: _turnRunning,
      keptRunning: _taskHeld && !_taskLost,
      continued: ref.read(localRuntimeProvider).status.continuedRun,
    );
    if (!due) return;
    ref.read(launchNoticeShownProvider.notifier).set(true);
    state = true;
    _timer = Timer(shownFor, dismiss);
  }

  /// Tapped away, or its time is up.
  void dismiss() {
    _timer?.cancel();
    _timer = null;
    state = false;
  }
}

final backgroundPauseProvider = NotifierProvider<BackgroundPauseController, bool>(BackgroundPauseController.new);
