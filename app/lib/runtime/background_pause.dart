// HarmonyOS suspends an app within seconds of it leaving the screen, and the
// on-device engine runs as this app: a turn left running stops where it is, with
// nothing to say it did. Whether it can pick up afterwards takes a device to
// know, so this says only that it paused: one quiet line in the chat on the way
// back (ui/notify/background_pause_host.dart draws it). Android's own line, about a
// phone cutting the network, is runtime/background_net.dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show appForegroundProvider, launchNoticeShownProvider;
import '../state/sessions_state.dart';
import 'runtime_state.dart';

/// The decision, without timers or the platform (unit-tested).
abstract final class BackgroundPausePolicy {
  /// Away this long and the app has been suspended. The system only says 「几秒」
  /// (best practices, background tasks): well past that, so a quick look at
  /// another app isn't told about a pause it most likely never had.
  static const suspendedAfter = Duration(seconds: 10);

  /// Whether a return after [away] calls for the line: the on-device engine is
  /// the [local] host (a remote one kept going), and its turn [wasRunning] on
  /// leaving and is [running] still (one that ended first has nothing to go on with). Nor did
  /// it pause if the system is still letting it [continued] (iOS 26); one that lost that did.
  static bool onReturn({
    required Duration away,
    required bool local,
    required bool wasRunning,
    required bool running,
    bool continued = false,
  }) => local && wasRunning && running && !continued && away >= suspendedAfter;
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
  Timer? _timer;

  @override
  bool build() {
    ref.listen(appForegroundProvider, (_, foreground) => _onScreen(foreground));
    // Over a remote host's conversation it would be about something else.
    ref.listen(activeHostProvider, (_, host) {
      if (!host.isLocal) dismiss();
    });
    ref.onDispose(() => _timer?.cancel());
    return false;
  }

  /// The conversation open now has a turn going.
  bool get _turnRunning {
    final sessionId = ref.read(currentSessionProvider);
    return sessionId != null && ref.exists(chatProvider(sessionId)) && ref.read(chatProvider(sessionId)).running;
  }

  void _onScreen(bool foreground) {
    if (!foreground) {
      dismiss();
      _since = now();
      _wasRunning = _turnRunning;
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
