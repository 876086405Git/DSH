import 'dart:async';
import 'dart:math' as math;

import 'companion_notice_channel.dart';
import 'companion_notice_decision.dart';
import 'companion_notice_model.dart';
import 'companion_notice_rate.dart';

export 'companion_notice_channel.dart';
export 'companion_notice_decision.dart';
export 'companion_notice_model.dart';
export 'companion_notice_rate.dart';

class CompanionNoticeTriage {
  CompanionNoticeTriage({
    required this.channel,
    required this.rate,
    required this.model,
    required this.deliver,
    required this.onFailure,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CompanionNotices channel;
  final CompanionNoticeRate rate;
  final CompanionNoticeModelTransport model;
  final void Function(CompanionNoticeDecision) deliver;
  final void Function(String code) onFailure;
  final DateTime Function() _now;
  static const window = Duration(seconds: 20);

  StreamSubscription<int>? _signals;
  Timer? _timer;
  Future<void>? _job;
  Future<void>? _closing;
  int? _epoch;
  int _generation = 0;
  bool _dirty = false, _closed = false;

  void start() {
    if (_closed || _signals != null) return;
    _signals = channel.signals.listen((epoch) {
      if (_epoch != null && epoch != _epoch) invalidate();
      _epoch = epoch;
      wake();
    }, onError: (Object _) => onFailure('notice_signal'));
    wake(); // Includes pending notifications received while Flutter was absent.
  }

  void invalidate() {
    if (_closed) return;
    _generation++;
    model.cancel();
    wake();
  }

  /// A change of credentials or a native hint may wake the same serial owner.
  void wake() {
    if (_closed) return;
    _timer?.cancel();
    _dirty = true;
    if (_job != null) return;
    _job = Future<void>.microtask(_run).whenComplete(() {
      _job = null;
      if (_dirty && !_closed) wake();
    });
  }

  void _later(int at) {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: math.max(1, at - _now().millisecondsSinceEpoch)), wake);
  }

  Future<void> _run() async {
    while (_dirty && !_closed) {
      _dirty = false;
      try {
        await _one(_generation);
      } on Object {
        if (!_closed) onFailure('notice_channel_or_store');
        // A failed native call has no trustworthy new inbox/consent snapshot.
        // A subsequent listener signal, credential change or visit can resume.
      }
    }
  }

  Future<void> _one(int generation) async {
    bool alive() => !_closed && generation == _generation;
    if (!model.configured) return;
    final status = await channel.status();
    if (!alive()) return;
    _epoch = status.epoch;
    if (!status.readable) return;
    final pending = await channel.pending();
    if (!alive() || pending.isEmpty) return;
    final now = _now();
    final at = now.millisecondsSinceEpoch;
    final modelReady = rate.availableAt(now);
    if (modelReady > at) {
      _later(modelReady);
      return;
    }
    final cooldown = rate.cooldowns(now);
    final queue = pending.where((p) => status.level(p.pkg) != CompanionNoticeLevel.off).toList()
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
    CompanionNoticePending? first;
    int? earliest;
    for (final p in queue) {
      final due = math.max(p.atMs + window.inMilliseconds, cooldown[p.key] ?? 0);
      if (due <= at) {
        first = p;
        break;
      }
      earliest = earliest == null ? due : math.min(earliest, due);
    }
    if (first == null) {
      if (earliest != null) _later(earliest);
      return;
    }
    final pkg = first.pkg;
    final level = status.level(pkg);
    final keys = queue.where((p) => p.pkg == pkg && (cooldown[p.key] ?? 0) <= at).map((p) => p.key).take(8).toList();
    final batch = await channel.takeBatch(pkg, keys, status.epoch);
    if (!alive() || batch == null || batch.level != level) return;
    Future<bool> authorize() async {
      if (!alive()) return false;
      final latest = await channel.status();
      return alive() && latest.epoch == batch.epoch && latest.readable && latest.level(pkg) == level;
    }

    List<CompanionNoticeDecision> decisions;
    try {
      decisions = await model.classify(
        batch,
        current: alive,
        authorize: authorize,
        reserve: () => alive() && rate.reserve(_now(), batch.items.map((p) => p.key)),
        fingerprint: rate.fingerprint,
      );
    } on Object catch (error) {
      if (!alive()) return;
      final code = error is CompanionNoticeFailure ? error.code : 'model_failure';
      if (code != 'cancelled' && code != 'rate_limited') {
        rate.failed(_now());
        onFailure(code);
      }
      // The original batch was removed by takeBatch. Only remaining/new items
      // can be considered when the persistent backoff expires.
      _dirty = true;
      return;
    }
    if (!await authorize()) return;
    if (!await channel.record(batch.epoch, judged: batch.items.length) || !alive()) {
      return;
    }
    rate.succeeded();
    for (final decision in decisions) {
      if (!alive()) return;
      deliver(decision);
    }
    _dirty = true;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _generation++;
    _timer?.cancel();
    model.cancel();
    return _closing = _finish();
  }

  Future<void> _finish() async {
    try {
      await _signals?.cancel();
      await _job;
    } finally {
      rate.close();
    }
  }
}
