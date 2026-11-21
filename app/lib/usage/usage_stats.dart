// 发送匿名使用统计: anonymous, per-day counts kept on the phone and sent once
// each, the day after (contracts v1–v3, usage_ledger.dart, and Android's v4
// daily ledger). On by default; seeing the switch only records that it was
// shown. Android daily activity is counted for every install, the switch on or
// off: switched off, the v4 report carries the foreground flags and nothing
// else. Off means the rest is neither counted nor uploaded; the local engine
// lease is revoked and its aggregate discarded.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../phone/phone_channel.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../state/android_features.dart';
import '../state/connection_state.dart';
import '../state/phone_state.dart' show phoneChannelProvider;
import '../state/update_state.dart';
import 'usage_ledger.dart';
import 'usage_net.dart';
import 'usage_v4_ledger.dart';

export 'usage_ledger.dart' show UsageCount;
export 'usage_v4_ledger.dart' show UsageTokenSource, UsageOperation, UsageOutcome;

class UsageStatsState {
  const UsageStatsState({this.loaded = false, this.enabled = true, this.noticed = false, this.v4Noticed = false});

  final bool loaded;

  /// The switch. On unless the person turned it off.
  final bool enabled;

  /// The person has seen the switch and what it says.
  final bool noticed;

  /// The person has seen the Android v4 notice (the upgrade toast).
  final bool v4Noticed;

  /// The full statistics: switched on. Android daily activity is counted
  /// either way (see [UsageStatsController.observesDaily]).
  bool get collecting => loaded && enabled;

  UsageStatsState copyWith({bool? loaded, bool? enabled, bool? noticed, bool? v4Noticed}) => UsageStatsState(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    noticed: noticed ?? this.noticed,
    v4Noticed: v4Noticed ?? this.v4Noticed,
  );
}

// Seams: tests set the clock, the network, the phone and the app's front.
final usageClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final usageHttpProvider = Provider<UsageHttp>((ref) => const IoUsageHttp());
final usageEndpointProvider = Provider<Uri>((ref) => usageEndpoint);
final usageV4EndpointProvider = Provider<Uri?>((ref) => usageV4Endpoint);
final usageDeviceProvider = Provider<Future<UsageDevice> Function()>((ref) => const UsageDeviceChannel().read);
final usageLanguageProvider = Provider<String Function()>(
  (ref) =>
      () => AppLocale.current.languageCode,
);

/// Calls back each time the app comes to the front; returns how to stop.
final usageResumesProvider = Provider<VoidCallback Function(VoidCallback onResume)>(
  (ref) =>
      (onResume) => AppLifecycleListener(onResume: onResume).dispose,
);

/// A phone control task began between [before] and [now]: a new number, or
/// active again.
bool phoneTaskStarted(PhoneTaskStatus before, PhoneTaskStatus now) =>
    now.active && (!before.active || (now.id != null && now.id != before.id));

/// The on-device engine's launch while it runs (`direct`, `proot`).
String? _engineMode(LocalRuntimeState s) =>
    s.status.phase == RuntimePhase.running ? s.status.currentExecutionMode : null;

class UsageStatsController extends Notifier<UsageStatsState> {
  static const enabledKey = 'usage_stats_enabled';
  static const noticedKey = 'usage_stats_noticed';
  static const daysKey = 'usage_stats_days';
  static const iidKey = 'usage_stats_iid';
  static const iidSinceKey = 'usage_stats_iid_since';
  static const failedAtKey = 'usage_stats_failed_at';
  static const closedDayKey = 'usage_stats_closed_day';
  static const v4NoticeKey = 'usage_stats_v4_noticed';
  static const v4LedgerKey = 'usage_stats_v4_ledger';

  /// After a send failed, the next one waits at least this long.
  static const retryGap = Duration(minutes: 10);
  static const timeout = Duration(seconds: 10);

  var _ledger = UsageLedger();
  var _v4 = UsageV4Ledger();
  String? _v4Saved;
  Future<void>? _v4Sending;
  DateTime? _v4Failed;
  String? _v4ClosedDay;
  Future<void> _engineUsageQueue = Future.value();
  Timer? _usageTimer;
  String? _iid;
  DateTime? _iidSince;
  DateTime? _failedAt;

  /// The newest contract the share host takes: one lower each time it
  /// refused a body (400), until the app starts again.
  int _contract = usageContract;

  /// The local day the share host said it collects nothing (404).
  String? _closedDay;
  UsageDevice? _device;
  late Future<void> _loaded;
  Future<void> _writes = Future.value();
  Future<void>? _sending;

  /// What was last written, so an unchanged ledger isn't written again.
  (String, String?, DateTime?, DateTime?, String?)? _saved;

  DateTime _now() => ref.read(usageClockProvider)();
  bool get _v4Platform => ref.read(operatingSystemProvider) == 'android';

  /// Android's daily activity: counted for every install, whatever the switch
  /// says. With the switch off only the foreground flags go out.
  bool get observesDaily => UsageBuild.active && _v4Platform;

  /// Model usage and operation results: the full statistics are on.
  bool get observesChatLogUsage => observesDaily && state.collecting;

  @override
  UsageStatsState build() {
    _loaded = _load();
    if (UsageBuild.active) _watch();
    return const UsageStatsState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final enabled = prefs.getBool(enabledKey) ?? true;
      DateTime? time(String key) => switch (prefs.getInt(key)) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        null => null,
      };
      // The v4 daily activity survives the switch: only its other rows are off.
      _v4 = UsageV4Ledger.decode(prefs.getString(v4LedgerKey));
      _v4Saved = _v4.encode();
      if (enabled) {
        _ledger = UsageLedger.decode(prefs.getString(daysKey));
        _iid = prefs.getString(iidKey);
        _iidSince = time(iidSinceKey);
        _failedAt = time(failedAtKey);
        _closedDay = prefs.getString(closedDayKey);
        _saved = (_ledger.encode(), _iid, _iidSince, _failedAt, _closedDay);
      }
      state = UsageStatsState(
        loaded: true,
        enabled: enabled,
        noticed: prefs.getBool(noticedKey) ?? false,
        v4Noticed: prefs.getBool(v4NoticeKey) ?? false,
      );
    } catch (_) {
      // No preferences backend: nothing kept, so nothing collected.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  /// Release builds: today counts when the app comes to the front, and the
  /// days before go out; the engine's launch and phone control tasks are
  /// noted as they happen.
  void _watch() {
    ref.onDispose(ref.read(usageResumesProvider)(() => unawaited(foreground())));
    // A cold start comes up in front.
    unawaited(foreground());
    void Function(UsageOutcome, {UsageOperation? actual})? launch;
    ref.listen(localRuntimeProvider.select((s) => s.status), (previous, next) {
      if (next.phase == RuntimePhase.starting) {
        launch ??= beginOperation(UsageOperation.runtimeOther);
        return;
      }
      if (previous?.phase != RuntimePhase.starting) return;
      launch?.call(
        switch (next.phase) {
          RuntimePhase.running when next.isRunning => UsageOutcome.ready,
          RuntimePhase.error => UsageOutcome.failed,
          RuntimePhase.stopping => UsageOutcome.cancelled,
          _ => UsageOutcome.unknown,
        },
        actual: switch (next.currentExecutionMode ?? previous?.currentExecutionMode) {
          'direct' => UsageOperation.runtimeDirect,
          'proot' => UsageOperation.runtimeProot,
          _ => UsageOperation.runtimeOther,
        },
      );
      launch = null;
    });
    ref.listen(localRuntimeProvider.select(_engineMode), (_, mode) {
      if (mode != null) _record((ledger, now) => ledger.engine(mode, now));
    }, fireImmediately: true);
    if (_v4Platform) {
      ref.listen(localConnectionProvider.select((s) => s.value?.client), (_, client) {
        if (client != null && observesChatLogUsage) unawaited(_syncEngineUsage(client, true));
      });
      _usageTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (observesChatLogUsage) {
          final client = ref.read(localConnectionProvider).value?.client;
          if (client != null) unawaited(_syncEngineUsage(client, true));
        }
      });
      ref.onDispose(() => _usageTimer?.cancel());
      void Function(UsageOutcome, {UsageOperation? actual})? download;
      void Function(UsageOutcome, {UsageOperation? actual})? install;
      ref.listen(appUpdateProvider, (previous, next) {
        if (next.task == UpdateTaskPhase.installing) {
          install ??= beginOperation(UsageOperation.updateInstall);
        } else if (previous?.task == UpdateTaskPhase.installing) {
          install?.call(switch (next.task) {
            UpdateTaskPhase.idle when next.current != previous?.current => UsageOutcome.ready,
            UpdateTaskPhase.failed => UsageOutcome.failed,
            _ => UsageOutcome.unknown,
          });
          install = null;
        }
        final task = next.task;
        switch (task) {
          case UpdateTaskPhase.downloading:
            download ??= beginOperation(UsageOperation.updateDownload);
          case UpdateTaskPhase.verifying:
            break;
          default:
            download?.call(switch (task) {
              UpdateTaskPhase.ready => UsageOutcome.ready,
              UpdateTaskPhase.failed => UsageOutcome.failed,
              UpdateTaskPhase.idle => UsageOutcome.cancelled,
              _ => UsageOutcome.unknown,
            });
            download = null;
        }
      });
    }
    final channel = ref.read(phoneChannelProvider);
    StreamSubscription<PhoneStatus>? sub;
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      unawaited(sub?.cancel());
    });
    unawaited(() async {
      try {
        final first = await channel.status();
        // Listening with no native side reports an error: only once it answered.
        if (disposed || !first.ready) return;
        var last = first.task;
        (String, int)? owner;
        void Function(UsageOutcome, {UsageOperation? actual})? task;
        sub = channel.statusChanges.listen((s) {
          final next = s.task;
          if (owner != null && owner == (next.endedRunId, next.endedGeneration)) {
            task?.call(switch (next) {
              PhoneTaskStatus(cleanupFailed: true) => UsageOutcome.failed,
              PhoneTaskStatus(stopped: true) => UsageOutcome.cancelled,
              PhoneTaskStatus(completion: 'completed') => UsageOutcome.ready,
              _ => UsageOutcome.unknown,
            });
            task = null;
            owner = null;
          }
          if (phoneTaskStarted(last, next)) {
            count(UsageCount.phone);
            if ((next.runId, next.generation) case (final run?, final generation?)) {
              task?.call(UsageOutcome.unknown);
              task = beginOperation(UsageOperation.phoneTask);
              owner = (run, generation);
            }
          }
          last = next;
        }, onError: (_) {});
      } catch (_) {}
    }());
  }

  /// One more [c] today.
  void count(UsageCount c) => _record((ledger, now) => ledger.count(c, now));

  /// A model reply reported its tokens: [input] (cached input included) and
  /// [output]. Only what the provider said; nothing is estimated.
  void tokens(int input, int output) => _record((ledger, now) => ledger.tokens(input, output, now));

  void chatLogUsage(Map<String, Object?>? rawUsage, {bool partial = false, required bool local}) {
    if (local) return; // Local settlements are owned by the bridge.
    tokenUsage(UsageTokenSource.chatLog, rawUsage, partial: partial);
  }

  // Use the authenticated local carrier. Stock hosts just have no route.
  Future<void> _syncEngineUsage(DshClient client, bool enabled) {
    final ledger = _v4;
    return _engineUsageQueue = _engineUsageQueue.then((_) async {
      if (enabled && (!ref.mounted || !identical(ledger, _v4) || !observesChatLogUsage)) return;
      final carrier = client.carrier;
      if (carrier is! DshHttpCarrier) return;
      try {
        final response = await carrier.connection.postBytes(
          '/dsh-go/v1/usage/collect',
          utf8.encode(enabled ? 'on' : 'off'),
          followRedirects: false,
          timeout: const Duration(seconds: 3),
          maxResponseBytes: 8192,
        );
        if (!enabled ||
            !ref.mounted ||
            !identical(ledger, _v4) ||
            !observesChatLogUsage ||
            ref.read(localConnectionProvider).value?.client != client) {
          return;
        }
        if (response.statusCode != 200) return;
        final reply = jsonDecode(response.text);
        if (reply case {'v': 1, 'epoch': final String epoch, 'days': final Map<String, dynamic> days}) {
          ledger.engineSnapshot(_now(), epoch, days);
          await _saveV4();
        }
      } on Exception {
        // A disconnected/restarted host can be read on the next foreground or poll.
      }
    });
  }

  void tokenUsage(UsageTokenSource source, Map<String, Object?>? rawUsage, {bool partial = false}) {
    if (!observesChatLogUsage) return;
    final now = _now();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _v4.foreground(now);
    _v4.token(now, source, rawUsage, partial: partial);
    unawaited(_saveV4());
  }

  void Function(UsageOutcome, {UsageOperation? actual})? beginOperation(UsageOperation kind) {
    if (!observesChatLogUsage) return null;
    final ledger = _v4;
    final clock = Stopwatch()..start();
    return (outcome, {actual}) {
      if (!clock.isRunning) return;
      clock.stop();
      if (!ref.mounted || !observesChatLogUsage || !identical(ledger, _v4)) return;
      _v4.operation(_now(), actual ?? kind, outcome, clock.elapsed);
      unawaited(_saveV4());
    };
  }

  /// The host's plugin list was read: [installed] plugins on it.
  void plugins(int installed) => _record((ledger, now) => ledger.plugins(installed, now));

  void _record(void Function(UsageLedger ledger, DateTime now) change) {
    if (!UsageBuild.active) return;
    // The day it happened, even if the ledger is still being read.
    final at = _now();
    unawaited(
      _loaded.then((_) {
        if (!ref.mounted || !state.collecting) return;
        change(_ledger, at);
        _save();
      }),
    );
  }

  /// The switch was in front of the person (first run, or the settings
  /// page): noted as told. Counting does not wait for this.
  Future<void> markNoticed() async {
    await _loaded;
    if (!ref.mounted) return;
    final v4 = _v4Platform && !state.v4Noticed;
    if (state.noticed && !v4) return;
    state = state.copyWith(noticed: true, v4Noticed: v4 ? true : null);
    await _write((prefs) async {
      await prefs.setBool(noticedKey, true);
      if (v4) await prefs.setBool(v4NoticeKey, true);
    });
    unawaited(foreground());
  }

  /// 发送匿名使用统计. Off drops the full statistics and their local data at
  /// once; Android's daily activity keeps going, carrying just the foreground
  /// flags (see [observesDaily]).
  Future<void> setEnabled(bool enabled) async {
    await _loaded;
    if (!ref.mounted) return;
    final local = !enabled && _v4Platform && UsageBuild.active ? ref.read(localConnectionProvider).value?.client : null;
    state = state.copyWith(enabled: enabled, noticed: true);
    String? daily;
    if (!enabled) {
      _ledger = UsageLedger();
      _iid = null;
      _iidSince = null;
      _failedAt = null;
      _closedDay = null;
      _device = null;
      _saved = null;
      _v4 = _v4.onlyDaily();
      daily = _v4.encode();
      _v4Saved = daily;
      _v4Failed = null;
      _v4ClosedDay = null;
      if (local != null) unawaited(_syncEngineUsage(local, false));
    }
    await _write((prefs) async {
      await prefs.setBool(enabledKey, enabled);
      await prefs.setBool(noticedKey, true);
      if (!enabled) {
        for (final key in [daysKey, iidKey, iidSinceKey, failedAtKey, closedDayKey]) {
          await prefs.remove(key);
        }
        if (daily != null) await prefs.setString(v4LedgerKey, daily);
      }
    });
    if (enabled) unawaited(foreground());
  }

  /// The app came to the front: today is a day in use, and the days before
  /// that haven't gone out yet go now.
  Future<void> foreground() async {
    if (!UsageBuild.active) return;
    await _loaded;
    if (!ref.mounted) return;
    final full = state.collecting;
    if (full) {
      _ledger.touch(_now());
      _save();
    }
    if (!observesDaily) {
      if (full) await send();
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) _v4.foreground(_now());
    if (full) {
      final client = ref.read(localConnectionProvider).value?.client;
      if (client != null) await _syncEngineUsage(client, true);
      if (!ref.mounted) return;
      unawaited(_readExits());
    }
    unawaited(_saveV4());
    await Future.wait([if (full) send(), _v4Sending ??= _sendV4().whenComplete(() => _v4Sending = null)]);
  }

  Future<void> _readExits() async {
    final ledger = _v4;
    final at = _now().millisecondsSinceEpoch;
    final old = ledger.exitCursor;
    // Start the observation window at opt-in; no historical pre-consent exits.
    if (old == 0) {
      ledger.exitCursor = at;
      await _saveV4();
      return;
    }
    try {
      final result = await const MethodChannel('dsh/usage').invokeListMethod<Object?>('abnormalExits', old);
      if (result == null ||
          !ref.mounted ||
          !identical(ledger, _v4) ||
          !observesChatLogUsage ||
          ledger.exitCursor != old) {
        return;
      }
      ledger.exitCursor = at;
      for (final item in result) {
        if (item case [final int timestamp, final String kind] when timestamp > old && timestamp <= at) {
          ledger.operation(
            _now(),
            kind == 'anr' ? UsageOperation.anr : UsageOperation.crash,
            UsageOutcome.failed,
            Duration.zero,
          );
        }
      }
      await _saveV4();
    } on Exception {
      // Older Android and stale channels provide no authoritative evidence.
    }
  }

  Future<void> _saveV4() {
    final snapshot = _v4.encode();
    if (snapshot == _v4Saved) return _writes;
    _v4Saved = snapshot;
    return _write((prefs) => prefs.setString(v4LedgerKey, snapshot));
  }

  Future<void> _sendV4() async {
    final ledger = _v4;
    bool live() => ref.mounted && identical(ledger, _v4) && observesDaily;
    final now = _now();
    final today = usageV4Day(now);
    final endpoint = ref.read(usageV4EndpointProvider);
    final due = ledger.due(now);
    await _saveV4();
    if (!live() || endpoint == null || due.isEmpty || _v4ClosedDay == today) return;
    if (_v4Failed case final failed? when !now.isBefore(failed) && now.difference(failed) < retryGap) return;
    final cached = _device;
    final device = cached != null && cached.app.isNotEmpty ? cached : await ref.read(usageDeviceProvider)();
    if (!live() || device.app.isEmpty) return;
    final http = ref.read(usageHttpProvider);
    for (final day in due) {
      // Switched off, the day goes as a daily-activity report: the base row only.
      final body = ledger.days[day]!.seal(day, device, dailyOnly: !state.collecting);
      ledger.sealedThrough = day;
      await _saveV4();
      if (!live()) return;
      int? status;
      try {
        status = await http.post(endpoint, body, timeout: timeout);
      } on Exception {
        // Retry the same sealed body after the usual foreground backoff.
      }
      if (!live()) return;
      switch (status) {
        case 204:
          ledger.days.remove(day);
          _v4Failed = null;
          await _saveV4();
          if (!live()) return;
        case 404:
          _v4ClosedDay = today;
          return;
        case 400 || 413:
          debugPrint('Usage v4 report refused ($status)');
          ledger.days.remove(day);
          await _saveV4();
          if (!live()) return;
        default:
          _v4Failed = now;
          return;
      }
    }
  }

  /// Sends the days that are due, oldest first, one request each; stops at
  /// the first failure (and for the day at a 404). Only one run at a time.
  Future<void> send() => _sending ??= _send().whenComplete(() => _sending = null);

  Future<void> _send() async {
    // A run belongs to the ledger it started with: turning off replaces it,
    // so off and on again while a request waits leaves the run nothing to do.
    final ledger = _ledger;
    bool live() => ref.mounted && state.collecting && identical(_ledger, ledger);
    if (!UsageBuild.active || !live()) return;
    final now = _now();
    if (_failedAt case final at? when !now.isBefore(at) && now.difference(at) < retryGap) return;
    if (_closedDay == usageDay(now)) return;
    _closedDay = null;
    final due = _ledger.due(now);
    if (due.isEmpty) {
      // Days too old or given up may have gone.
      _save();
      return;
    }
    final device = _device ??= await ref.read(usageDeviceProvider)();
    if (!live()) return;
    final iid = _currentIid(now);
    final http = ref.read(usageHttpProvider);
    final endpoint = ref.read(usageEndpointProvider);
    final lang = ref.read(usageLanguageProvider)();
    for (final day in due) {
      final record = _ledger.days[day];
      if (record == null) continue;
      Map<String, Object> body() =>
          usagePayload(iid: iid, day: day, record: record, device: device, lang: lang, version: _contract);
      var payload = body();
      // The host would refuse it (400): not worth a request.
      if (usageProblem(payload, now) != null) {
        _ledger.drop(day);
        continue;
      }
      int? status;
      try {
        status = await http.post(endpoint, jsonEncode(payload), timeout: timeout);
        // A host from before v3 refuses its counts, one from before v2 the
        // model and system: the same day again one contract lower, and that
        // one for the rest of this run of the app.
        while (status == 400 && (payload['v']! as int) > 1 && live()) {
          _contract = (payload['v']! as int) - 1;
          payload = body();
          // No answer to the lower one is a failed send, not the earlier 400.
          status = null;
          status = await http.post(endpoint, jsonEncode(payload), timeout: timeout);
        }
      } catch (_) {
        // Quietly: tried again the next time the app comes to the front.
      }
      // Turned off meanwhile: everything is gone already.
      if (!live()) return;
      switch (UsageReply.of(status)) {
        case UsageReply.sent:
          _ledger.sent(day);
        case UsageReply.refused:
          _ledger.drop(day);
        case UsageReply.closed:
          _closedDay = usageDay(now);
          _save();
          return;
        case UsageReply.later:
          _ledger.failed(day);
          _failedAt = now;
          _save();
          return;
      }
    }
    _failedAt = null;
    _save();
  }

  /// The install id, a new one when there is none or it is
  /// [usageIidLifetime] old.
  String _currentIid(DateTime now) {
    final since = _iidSince;
    if (_iid == null || since == null || now.difference(since) >= usageIidLifetime) {
      _iid = newUsageIid();
      _iidSince = now;
    }
    return _iid!;
  }

  void _save() {
    final days = _ledger.encode();
    final iid = _iid;
    final since = _iidSince;
    final failedAt = _failedAt;
    final closedDay = _closedDay;
    // Coming to the front on a day already noted changes nothing.
    final snapshot = (days, iid, since, failedAt, closedDay);
    if (snapshot == _saved) return;
    _saved = snapshot;
    unawaited(
      _write((prefs) async {
        await prefs.setString(daysKey, days);
        if (iid != null && since != null) {
          await prefs.setString(iidKey, iid);
          await prefs.setInt(iidSinceKey, since.millisecondsSinceEpoch);
        }
        if (failedAt == null) {
          await prefs.remove(failedAtKey);
        } else {
          await prefs.setInt(failedAtKey, failedAt.millisecondsSinceEpoch);
        }
        if (closedDay == null) {
          await prefs.remove(closedDayKey);
        } else {
          await prefs.setString(closedDayKey, closedDay);
        }
      }),
    );
  }

  /// Writes in the order asked, so turning off is never undone by a save
  /// that was already on its way.
  Future<void> _write(Future<void> Function(SharedPreferences prefs) body) => _writes = _writes.then((_) async {
    try {
      await body(await SharedPreferences.getInstance());
    } catch (_) {}
  });
}

final usageStatsProvider = NotifierProvider<UsageStatsController, UsageStatsState>(UsageStatsController.new);
