// 发送匿名使用统计: anonymous, per-day counts kept on the phone and sent once
// each, the day after (contracts v1–v3, usage_ledger.dart). On by default, but
// nothing is counted until the person has seen the switch (first run's
// 「想让 DSH Go 帮你做哪些事」, or 设置 › 隐私与分享). Off means nothing is
// counted, nothing is kept and no request is made.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../phone/phone_channel.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../state/phone_state.dart' show phoneChannelProvider;
import 'usage_ledger.dart';
import 'usage_net.dart';

export 'usage_ledger.dart' show UsageCount;

class UsageStatsState {
  const UsageStatsState({this.loaded = false, this.enabled = true, this.noticed = false});

  final bool loaded;

  /// The switch. On unless the person turned it off.
  final bool enabled;

  /// The person has seen the switch and what it says.
  final bool noticed;

  /// Counting and sending: switched on, and told about it.
  bool get collecting => loaded && enabled && noticed;

  UsageStatsState copyWith({bool? loaded, bool? enabled, bool? noticed}) => UsageStatsState(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    noticed: noticed ?? this.noticed,
  );
}

// Seams: tests set the clock, the network, the phone and the app's front.
final usageClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final usageHttpProvider = Provider<UsageHttp>((ref) => const IoUsageHttp());
final usageEndpointProvider = Provider<Uri>((ref) => usageEndpoint);
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

  /// After a send failed, the next one waits at least this long.
  static const retryGap = Duration(minutes: 10);
  static const timeout = Duration(seconds: 10);

  var _ledger = UsageLedger();
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
      if (enabled) {
        _ledger = UsageLedger.decode(prefs.getString(daysKey));
        _iid = prefs.getString(iidKey);
        _iidSince = time(iidSinceKey);
        _failedAt = time(failedAtKey);
        _closedDay = prefs.getString(closedDayKey);
        _saved = (_ledger.encode(), _iid, _iidSince, _failedAt, _closedDay);
      }
      state = UsageStatsState(loaded: true, enabled: enabled, noticed: prefs.getBool(noticedKey) ?? false);
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
    ref.listen(localRuntimeProvider.select(_engineMode), (_, mode) {
      if (mode != null) _record((ledger, now) => ledger.engine(mode, now));
    }, fireImmediately: true);
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
        sub = channel.statusChanges.listen((s) {
          if (phoneTaskStarted(last, s.task)) count(UsageCount.phone);
          last = s.task;
        }, onError: (_) {});
      } catch (_) {}
    }());
  }

  /// One more [c] today.
  void count(UsageCount c) => _record((ledger, now) => ledger.count(c, now));

  /// A model reply reported its tokens: [input] (cached input included) and
  /// [output]. Only what the provider said; nothing is estimated.
  void tokens(int input, int output) => _record((ledger, now) => ledger.tokens(input, output, now));

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
  /// page): from now on the app counts, unless it is off.
  Future<void> markNoticed() async {
    await _loaded;
    if (!ref.mounted || state.noticed) return;
    state = state.copyWith(noticed: true);
    await _write((prefs) => prefs.setBool(noticedKey, true));
    unawaited(foreground());
  }

  /// 发送匿名使用统计. Off drops the install id and every count at once.
  Future<void> setEnabled(bool enabled) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(enabled: enabled, noticed: true);
    if (!enabled) {
      _ledger = UsageLedger();
      _iid = null;
      _iidSince = null;
      _failedAt = null;
      _closedDay = null;
      _device = null;
      _saved = null;
    }
    await _write((prefs) async {
      await prefs.setBool(enabledKey, enabled);
      await prefs.setBool(noticedKey, true);
      if (!enabled) {
        for (final key in [daysKey, iidKey, iidSinceKey, failedAtKey, closedDayKey]) {
          await prefs.remove(key);
        }
      }
    });
    if (enabled) unawaited(foreground());
  }

  /// The app came to the front: today is a day in use, and the days before
  /// that haven't gone out yet go now.
  Future<void> foreground() async {
    if (!UsageBuild.active) return;
    await _loaded;
    if (!ref.mounted || !state.collecting) return;
    _ledger.touch(_now());
    _save();
    await send();
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
