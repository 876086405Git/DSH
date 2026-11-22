// Some phone makers cut an app's network as soon as it
// leaves the screen, foreground service or not (vivo until 「允许后台高耗电」 is
// on). The engine runs as this app, so a turn left running in the background
// stalls on failed requests and picks up again only when the app comes back.
// This decides when to say so: one quiet line in the chat on the way back,
// leading to 后台保活 (ui/notify/background_net_host.dart draws it).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../state/chat_state.dart';
import '../state/connection_state.dart';
import '../state/notify_state.dart' show launchNoticeShownProvider;
import '../state/sessions_state.dart';
import 'runtime_bridge.dart';
import 'runtime_state.dart';

/// Why the line shows.
enum BackgroundNetReason {
  /// Android reported this app's network blocked while it was in the background.
  blocked,

  /// The engine's model requests could not get through while the app was in the background
  /// (vendor blocks do not always reach Android's own blocked status).
  failures,

  /// After the first finished turn, on a phone whose maker holds background apps back: once.
  intro;

  String get text => switch (this) {
    blocked || failures => appL10n.stateBackgroundRestricted,
    intro => appL10n.stateBackgroundFinish,
  };
}

/// The decisions, without timers, storage or the platform (unit-tested).
abstract final class BackgroundNetPolicy {
  /// Per reason: the first time and once more, until the app is let run in the background.
  static const maxShows = 2;

  /// Makers that hold background apps back out of the box.
  static const strictVendors = {'vivo', 'xiaomi', 'huawei', 'honor', 'oppo'};

  /// What a return to the app after [since] calls for. Only while the app is not exempt from
  /// battery optimization ([exempt] false; null means unknown, so nothing is said).
  static BackgroundNetReason? onReturn({
    required DateTime since,
    required bool? exempt,
    required Map<BackgroundNetReason, int> shown,
    DateTime? blockedAt,
    bool Function()? transportFailed,
  }) {
    if (exempt != false) return null;
    final reason = blockedAt != null && !blockedAt.isBefore(since)
        ? BackgroundNetReason.blocked
        : (transportFailed?.call() ?? false)
        ? BackgroundNetReason.failures
        : null;
    if (reason == null || (shown[reason] ?? 0) >= maxShows) return null;
    return reason;
  }

  /// Whether the engine retried a model request for a transport failure between [since] and
  /// [until]. The on-device engine shares this clock, so event times compare directly.
  static bool transportFailedIn(Iterable<SessionLogEvent> events, DateTime since, DateTime until) {
    for (final event in events.toList().reversed) {
      if (event.time.isBefore(since)) return false;
      if (event.time.isAfter(until)) continue;
      if (event is LlmRetryEvent && event.failure?.code == 'TRANSPORT') return true;
    }
    return false;
  }

  /// The one-time intro after a finished turn.
  static bool introDue({
    required bool introduced,
    required String? vendor,
    required bool? exempt,
    required Map<BackgroundNetReason, int> shown,
  }) => !introduced && strictVendors.contains(vendor) && exempt == false && shown.values.every((n) => n == 0);
}

/// The line to show now, or null. The host feeds it app visibility; the person dismisses it.
class BackgroundNetController extends Notifier<BackgroundNetReason?> {
  static const _shownKey = 'background_net.shown.';
  static const _introKey = 'background_net.intro';

  final Map<BackgroundNetReason, int> _shown = {};
  bool _introduced = false;
  Future<void>? _loading;
  DateTime? _since;
  bool _visible = true;
  final Set<String> _running = {};
  StreamSubscription<HostEvent>? _events;

  RuntimeBridge get _bridge => ref.read(runtimeBridgeProvider);

  @override
  BackgroundNetReason? build() {
    _loading ??= _load();
    // Turn ends on the on-device engine: when to introduce 后台保活.
    ref.listen(localHostEventsProvider, (_, next) => _follow(next), fireImmediately: true);
    ref.onDispose(() => unawaited(_events?.cancel()));
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final reason in BackgroundNetReason.values) {
        _shown[reason] = prefs.getInt('$_shownKey${reason.name}') ?? 0;
      }
      _introduced = prefs.getBool(_introKey) ?? false;
    } catch (_) {
      // No storage (tests without a mock): start from nothing.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final MapEntry(:key, :value) in _shown.entries) {
        await prefs.setInt('$_shownKey${key.name}', value);
      }
      await prefs.setBool(_introKey, _introduced);
    } catch (_) {}
  }

  void _follow(Stream<HostEvent>? events) {
    unawaited(_events?.cancel());
    _events = null;
    _running.clear();
    if (events == null) return;
    _events = events.listen((event) {
      if (event is! SessionStatusEvent) return;
      if (event.running) {
        _running.add(event.sessionId);
      } else if (_running.remove(event.sessionId)) {
        unawaited(_onTurnEnded());
      }
    });
  }

  /// The app left the screen ([visible] false) or came back.
  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) {
      _since = DateTime.now();
      return;
    }
    final since = _since;
    _since = null;
    if (since != null) unawaited(_onReturn(since));
  }

  Future<bool?> _exempt() async {
    final exempt = await _bridge.batteryExempt();
    if (exempt == true && _shown.values.any((n) => n > 0)) {
      // Let run in the background: a later revoke may bring the line back.
      _shown.updateAll((_, _) => 0);
      unawaited(_save());
    }
    return exempt;
  }

  Future<void> _onReturn(DateTime since) async {
    await _loading;
    final now = DateTime.now();
    final status = ref.read(localRuntimeProvider).status;
    final reason = BackgroundNetPolicy.onReturn(
      since: since,
      exempt: await _exempt(),
      shown: _shown,
      blockedAt: status.networkBlockedAt,
      transportFailed: () => _transportFailed(since, now),
    );
    if (reason == null || !ref.mounted || !_visible) return;
    _show(reason);
  }

  /// The open conversation's log, if it is on the on-device engine and already loaded.
  bool _transportFailed(DateTime since, DateTime until) {
    final connection = ref.read(activeConnectionProvider).value;
    final sessionId = ref.read(currentSessionProvider);
    if (connection == null || !connection.isLocal || sessionId == null) return false;
    if (!ref.exists(chatProvider(sessionId))) return false;
    return BackgroundNetPolicy.transportFailedIn(ref.read(chatProvider(sessionId).notifier).events, since, until);
  }

  Future<void> _onTurnEnded() async {
    await _loading;
    if (_introduced || !_visible || state != null) return;
    final vendor = (await ref.read(backgroundSettingsProvider.future))?.vendor;
    final due = BackgroundNetPolicy.introDue(
      introduced: _introduced,
      vendor: vendor,
      exempt: await _exempt(),
      shown: _shown,
    );
    if (!due || !ref.mounted || !_visible) return;
    _show(BackgroundNetReason.intro);
  }

  void _show(BackgroundNetReason reason) {
    _shown[reason] = (_shown[reason] ?? 0) + 1;
    // Any line about background running counts as the introduction.
    _introduced = true;
    unawaited(_save());
    ref.read(launchNoticeShownProvider.notifier).set(true);
    state = reason;
  }

  /// Tapped away, or 去放行 was tapped.
  void dismiss() => state = null;
}

/// The on-device engine's `$events` (turn ends for the intro); null while it is not connected.
final localHostEventsProvider = Provider<Stream<HostEvent>?>(
  (ref) => ref.watch(localConnectionProvider.select((c) => c.value?.client))?.hostEvents,
);

/// The phone maker and the app's name in system settings; null without the native side.
final backgroundSettingsProvider = FutureProvider<BackgroundSettingsInfo?>(
  (ref) => ref.watch(runtimeBridgeProvider).backgroundSettings(),
);

final backgroundNetProvider = NotifierProvider<BackgroundNetController, BackgroundNetReason?>(
  BackgroundNetController.new,
);
