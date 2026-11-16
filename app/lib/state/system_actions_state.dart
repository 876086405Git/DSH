// 系统操作 (HarmonyOS): the local engine's phone tools reach the system through
// one [DshPhoneSession], which this controller opens and closes. It lives while
// the switch is on, the local engine is connected and DSH Go is on screen; the
// engine refuses new work off screen anyway. A call already under way is left to
// finish when the app goes away (`open` itself sends it away; a handoff waits for
// the person to come back), and the session goes once that call has ended.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_channel.dart' show PhoneLogEntry;
import '../runtime/phone_callback_bridge.dart';
import '../runtime/runtime_state.dart';
import 'connection_state.dart';

/// [OhosPhoneNative]; tests swap it.
final systemActionsNativeProvider = Provider<DshPhoneNative>((ref) => const OhosPhoneNative());

/// Whether this build and device can set alarms and timers. Even then the service
/// can say no when asked: it may not be turned on, or be at its limit.
enum ReminderAccess { available, notThisBuild, notThisDevice }

/// Null while it's being asked, or if the native side couldn't say.
final reminderAccessProvider = FutureProvider<ReminderAccess?>((ref) async {
  try {
    return switch (await ref.read(runtimeBridgeProvider).reminderAccess()) {
      'granted' => ReminderAccess.available,
      'denied' => ReminderAccess.notThisBuild,
      'unsupported' => ReminderAccess.notThisDevice,
      _ => null,
    };
  } catch (_) {
    return null;
  }
});

/// Where the switch stands right now.
enum SystemActionsLink {
  off,

  /// On, without a connected local engine.
  waitingEngine,

  /// On, and DSH Go isn't on screen: nothing new can start.
  offScreen,
  connecting,

  /// A session is taking the engine's calls.
  ready,

  /// The session wouldn't open or dropped; trying again.
  unavailable,

  /// This build has no native side for it; trying again wouldn't help.
  unsupported,
}

class SystemActionsState {
  const SystemActionsState({
    this.loaded = false,
    this.enabled = false,
    this.disclosureAccepted = false,
    this.link = SystemActionsLink.off,
    this.handoff,
    this.log = const [],
  });

  /// False until the saved switch is read.
  final bool loaded;
  final bool enabled;
  final bool disclosureAccepted;
  final SystemActionsLink link;

  /// The call waiting for the person to press continue or stop.
  final DshPhoneRequest? handoff;

  /// Newest first; what ran and how it came out, never its arguments.
  final List<PhoneLogEntry> log;

  SystemActionsState copyWith({
    bool? loaded,
    bool? enabled,
    bool? disclosureAccepted,
    SystemActionsLink? link,
    DshPhoneRequest? handoff,
    bool clearHandoff = false,
    List<PhoneLogEntry>? log,
  }) => SystemActionsState(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    disclosureAccepted: disclosureAccepted ?? this.disclosureAccepted,
    link: link ?? this.link,
    handoff: clearHandoff ? null : handoff ?? this.handoff,
    log: log ?? this.log,
  );
}

/// The action log's word for [result]: only what is known. Opening a page isn't
/// the job done, and a continue press proves the press.
String phoneResultDecision(DshPhoneResult result) => switch (result.status) {
  DshPhoneStatus.succeeded when result.evidence == DshPhoneEvidence.userConfirmed => 'continue',
  DshPhoneStatus.succeeded when result.evidence == DshPhoneEvidence.openedUi => 'opened_ui',
  DshPhoneStatus.succeeded when result.effect == DshPhoneEffect.reminderScheduled => 'reminder_scheduled',
  DshPhoneStatus.succeeded => 'ok',
  DshPhoneStatus.unknown => 'result_unknown',
  DshPhoneStatus.cancelled => 'stopped',
  DshPhoneStatus.timedOut => 'timeout',
  DshPhoneStatus.failed when result.code == 'unsupported' => 'unsupported',
  DshPhoneStatus.failed => 'error',
};

class SystemActionsController extends Notifier<SystemActionsState> {
  static const enabledKey = 'system_actions_enabled';
  static const disclosureKey = 'system_actions_disclosure_v1';
  static const logKey = 'system_actions_log';
  static const logLimit = 200;

  /// A session that lasted this long says the link works: the next failure
  /// starts its wait over.
  static const _settled = Duration(seconds: 30);

  DshPhoneSession? _session;
  DshConnection? _connection;
  StreamSubscription<DshPhoneUpdate>? _updates;
  DateTime? _openedAt;

  /// The call the session claimed and hasn't reported yet.
  DshPhoneRequest? _current;
  String? _failure;
  bool _visible = true;
  bool _syncing = false;
  bool _again = false;
  bool _unsupported = false;
  int _failures = 0;
  Timer? _retry;

  @override
  SystemActionsState build() {
    final now = WidgetsBinding.instance.lifecycleState;
    _visible = now != AppLifecycleState.hidden && now != AppLifecycleState.paused && now != AppLifecycleState.detached;
    final lifecycle = AppLifecycleListener(
      onShow: () {
        _visible = true;
        _startOver();
      },
      onHide: () {
        _visible = false;
        _sync();
      },
    );
    ref.listen(localConnectionProvider, (_, _) => _startOver());
    ref.onDispose(() {
      lifecycle.dispose();
      _retry?.cancel();
      unawaited(_session?.close());
      unawaited(_updates?.cancel());
    });
    unawaited(_load());
    return const SystemActionsState();
  }

  Future<void> _load() async {
    final r = ref;
    var enabled = false;
    var accepted = false;
    var log = const <PhoneLogEntry>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(enabledKey) ?? false;
      accepted = prefs.getBool(disclosureKey) ?? false;
      log = [
        for (final line in prefs.getStringList(logKey) ?? const <String>[])
          PhoneLogEntry.fromMap((jsonDecode(line) as Map).cast<Object?, Object?>()),
      ];
    } catch (_) {
      // Nothing readable: off, which is the safe side.
    }
    if (!r.mounted) return;
    state = state.copyWith(loaded: true, enabled: enabled, disclosureAccepted: accepted, log: log);
    _sync();
  }

  Future<void> acceptDisclosure() async {
    state = state.copyWith(disclosureAccepted: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(disclosureKey, true);
    } catch (_) {}
  }

  /// False when it couldn't be saved (nothing changes).
  Future<bool> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, enabled);
    } catch (_) {
      return false;
    }
    if (!ref.mounted) return false;
    state = state.copyWith(enabled: enabled);
    _startOver();
    return true;
  }

  /// The person pressed continue: the only thing that can make a handoff
  /// succeed. False when it didn't count; the prompt says what's next.
  Future<bool> continueHandoff() async {
    final (session, request) = (_session, state.handoff);
    if (session == null || request == null) return false;
    try {
      return (await session.continueHandoff(request.requestId)).accepted;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopHandoff() async {
    final (session, request) = (_session, state.handoff);
    if (session == null || request == null) return false;
    try {
      await session.stop(request.requestId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whatever just changed (the switch, the engine, back on screen) gets a
  /// fresh attempt, without the wait left over from earlier failures.
  void _startOver() {
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    _unsupported = false;
    _sync();
  }

  /// One step at a time: opening and closing wait for the native side, and
  /// what changes meanwhile is looked at once they're done.
  void _sync() {
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    unawaited(() async {
      try {
        do {
          _again = false;
          await _step();
        } while (_again && ref.mounted);
      } finally {
        _syncing = false;
      }
    }());
  }

  DshConnection? get _engine {
    final carrier = ref.read(localConnectionProvider).value?.client.carrier;
    return carrier is DshHttpCarrier ? carrier.connection : null;
  }

  Future<void> _step() async {
    if (!ref.mounted) return;
    final engine = _engine;
    final open = _session;
    if (open != null) {
      if (!state.enabled) _link(SystemActionsLink.off);
      if (!state.enabled || !identical(engine, _connection) || (!_visible && _current == null)) {
        await open.close();
      } else {
        _link(_visible ? SystemActionsLink.ready : SystemActionsLink.offScreen);
      }
      return;
    }
    if (!state.enabled) return _link(SystemActionsLink.off);
    if (engine == null) return _link(SystemActionsLink.waitingEngine);
    if (!_visible) return _link(SystemActionsLink.offScreen);
    if (_unsupported) return _link(SystemActionsLink.unsupported);
    if (_retry?.isActive ?? false) return;
    // Retrying stays 「正在重试」 rather than flickering between the two.
    if (_failures == 0) _link(SystemActionsLink.connecting);
    final DshPhoneSession session;
    try {
      session = await DshPhoneSession.open(engine, enabled: true, native: ref.read(systemActionsNativeProvider));
    } catch (error) {
      if (ref.mounted) _failed(error is DshPhoneException ? error.code : 'native_unavailable');
      return;
    }
    if (!ref.mounted) {
      await session.close();
      return;
    }
    _session = session;
    _connection = engine;
    _openedAt = DateTime.now();
    _updates = session.updates.listen(_onUpdate);
    _again = true;
    unawaited(session.run());
  }

  void _link(SystemActionsLink link) {
    if (state.link != link) state = state.copyWith(link: link);
  }

  /// Off screen is nothing to wait out: the next show starts over.
  void _failed(String code) {
    if (code == 'unsupported') {
      _unsupported = true;
      _link(SystemActionsLink.unsupported);
      return;
    }
    if (code == 'not_foreground' || code == 'ohos_phone_foreground') {
      _link(SystemActionsLink.offScreen);
    } else {
      _link(SystemActionsLink.unavailable);
    }
    final wait = Duration(seconds: math.min(30, 1 << math.min(_failures, 5)));
    _failures++;
    _retry?.cancel();
    _retry = Timer(wait, _sync);
  }

  void _onUpdate(DshPhoneUpdate update) {
    if (!ref.mounted) return;
    switch (update.phase) {
      case DshPhonePhase.idle:
        break;
      case DshPhonePhase.executing:
        _current = update.request;
      case DshPhonePhase.waitingUser:
        _current = update.request;
        if (state.handoff?.requestId != update.request?.requestId) state = state.copyWith(handoff: update.request);
      case DshPhonePhase.finished:
        // No result: it was stopped, expired or cancelled while it waited.
        _record(_current, update.result == null ? 'stopped' : phoneResultDecision(update.result!));
        _current = null;
        state = state.copyWith(clearHandoff: true);
        // Not from inside the session's own update: it hasn't finished its step.
        scheduleMicrotask(_sync);
      case DshPhonePhase.failed:
        _failure = update.code ?? 'callback_unavailable';
      case DshPhonePhase.closed:
        _closed();
    }
  }

  void _closed() {
    final current = _current;
    if (current != null) _record(current, current.isHandoff ? 'stopped' : 'result_unknown');
    _current = null;
    if (DateTime.now().difference(_openedAt ?? DateTime.now()) > _settled) _failures = 0;
    _session = null;
    _connection = null;
    unawaited(_updates?.cancel());
    _updates = null;
    state = state.copyWith(clearHandoff: true);
    final failure = _failure;
    _failure = null;
    if (failure != null && state.enabled && _visible) _failed(failure);
    scheduleMicrotask(_sync);
  }

  void _record(DshPhoneRequest? request, String decision) {
    if (request == null) return;
    final map = {'time': DateTime.now().millisecondsSinceEpoch, 'tool': request.tool, 'decision': decision};
    final log = [PhoneLogEntry.fromMap(map), ...state.log].take(logLimit).toList(growable: false);
    state = state.copyWith(log: log);
    unawaited(_saveLog());
  }

  /// In order, one write at a time, the latest last.
  Future<void> _saving = Future.value();
  Future<void> _saveLog() => _saving = _saving.then((_) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(logKey, [
        for (final e in state.log)
          jsonEncode({'time': e.time?.millisecondsSinceEpoch, 'tool': e.tool, 'decision': e.rawDecision}),
      ]);
    } catch (_) {}
  });
}

final systemActionsProvider = NotifierProvider<SystemActionsController, SystemActionsState>(
  SystemActionsController.new,
);
