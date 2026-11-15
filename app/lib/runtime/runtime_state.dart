import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/settings_state.dart';
import '../state/read_list_epoch.dart';
import 'runtime_bridge.dart';

final runtimeBridgeProvider = Provider<RuntimeBridge>((ref) => RuntimeBridge());

/// [RuntimeBridge.batteryExempt]; invalidate to read it again.
final batteryExemptProvider = FutureProvider<bool?>((ref) => ref.watch(runtimeBridgeProvider).batteryExempt());

/// A one-off message from the runtime (e.g. "已用安全模式启动"); [seq] tells repeats apart.
class RuntimeNotice {
  const RuntimeNotice(this.seq, this.text);
  final int seq;
  final String text;
}

/// What the UI needs to know about the local runtime.
/// What the engine reported about moving saved paths when the app's container changed
/// (runtime/ios/storage/preload.mjs). Only ever said on iOS, and said again at every start while
/// it's still true.
enum RelocationIssue {
  /// Old history whose original location can't be proven: it's kept as it is, not repaired.
  originUnavailable('[IOS_RELOCATION_ORIGIN_UNAVAILABLE]'),

  /// Some conversations couldn't be moved and were set aside with the reason.
  sessionIsolated('[IOS_RELOCATION_SESSION_ISOLATED]');

  const RelocationIssue(this.code);

  /// How Node prints the warning's code. The rest of the line isn't for matching on.
  final String code;

  String get text => switch (this) {
    RelocationIssue.originUnavailable => appL10n.iosRelocationOriginUnavailable,
    RelocationIssue.sessionIsolated => appL10n.iosRelocationSessionIsolated,
  };
}

class LocalRuntimeState {
  const LocalRuntimeState({
    this.status = const RuntimeStatus.unknown(),
    this.progress,
    this.loaded = false,
    this.notice,
    this.available = true,
    this.relocation = const {},
  });

  final RuntimeStatus status;
  final RuntimeProgressEvent? progress;

  /// False until the first status arrives from the native side.
  final bool loaded;

  /// The latest notice; shown once by `SafeModeNoticeListener`.
  final RuntimeNotice? notice;

  /// False when this build has no native runtime at all (no `dsh/runtime`
  /// handler, e.g. HarmonyOS before its engine host lands): only remote hosts.
  final bool available;

  /// What this start of the engine reported; cleared when the next one begins.
  final Set<RelocationIssue> relocation;

  LocalRuntimeState copyWith({
    RuntimeStatus? status,
    RuntimeProgressEvent? progress,
    bool clearProgress = false,
    bool? loaded,
    RuntimeNotice? notice,
    bool? available,
    Set<RelocationIssue>? relocation,
  }) => LocalRuntimeState(
    status: status ?? this.status,
    progress: clearProgress ? null : (progress ?? this.progress),
    loaded: loaded ?? this.loaded,
    notice: notice ?? this.notice,
    available: available ?? this.available,
    relocation: relocation ?? this.relocation,
  );
}

class LocalRuntimeController extends Notifier<LocalRuntimeState> {
  StreamSubscription<RuntimeEvent>? _sub;
  var _statusRevision = 0;

  /// Said once per launch of the app: the engine repeats these at every start.
  final _relocationSaid = <RelocationIssue>{};

  RuntimeBridge get _bridge => ref.read(runtimeBridgeProvider);

  @override
  LocalRuntimeState build() {
    // Keep collecting before the log screen opens, without watching its updates.
    ref.read(localRuntimeLogsProvider);
    _sub = _bridge.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    unawaited(_refresh());
    return const LocalRuntimeState();
  }

  Future<void> _refresh() async {
    final r = ref;
    // A later query or status event retires this in-flight snapshot.
    final revision = ++_statusRevision;
    try {
      final status = await _bridge.status();
      if (!r.mounted || revision != _statusRevision) return;
      state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
    } on MissingPluginException {
      if (r.mounted) state = state.copyWith(loaded: true, available: false);
    } catch (_) {
      if (r.mounted && revision == _statusRevision) state = state.copyWith(loaded: true);
    }
  }

  void _onEvent(RuntimeEvent event) {
    switch (event) {
      case RuntimeStatusEvent(:final status):
        if (status.phase == RuntimePhase.starting && state.relocation.isNotEmpty) {
          state = state.copyWith(relocation: const {});
        }
        _statusRevision++;
        state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
      case RuntimeProgressEvent():
        state = state.copyWith(progress: event);
      case RuntimeLogsEvent(:final entries):
        for (final entry in entries) {
          for (final issue in RelocationIssue.values) {
            if (!entry.line.contains(issue.code) || state.relocation.contains(issue)) continue;
            state = state.copyWith(
              relocation: {...state.relocation, issue},
              notice: _relocationSaid.add(issue) ? RuntimeNotice((state.notice?.seq ?? 0) + 1, issue.text) : null,
            );
          }
        }
      case RuntimeNoticeEvent(:final text):
        state = state.copyWith(notice: RuntimeNotice((state.notice?.seq ?? 0) + 1, text));
    }
  }

  Future<void> install() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install();
  }

  /// Installs without what a reset kept but could not put back.
  Future<void> installDroppingKept() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install(dropKept: true);
  }

  /// The API key is not passed here: it is written to DSH's own credential store
  /// after connecting (see connection_state.dart), so it can change without a restart.
  /// Keeps the current mode: in safe mode this starts safe mode again.
  Future<void> start() {
    final settings = ref.read(settingsProvider);
    return _startOrReopen(
      () => _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies),
    );
  }

  /// Starts in [mode]; [EngineMode.normal] from safe mode begins the two-minute trial.
  Future<void> startIn(EngineMode mode) {
    final settings = ref.read(settingsProvider);
    return _startOrReopen(
      () => _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies, mode: mode),
    );
  }

  /// HarmonyOS's engine runs in the app's own process and only once, so a second
  /// start takes a new process. Every stop-then-start in the app ends up here.
  Future<void> _startOrReopen(Future<void> Function() start) async {
    try {
      await start();
    } on PlatformException catch (e) {
      if (e.code != 'ohos_restart_required') rethrow;
      try {
        await _bridge.reopenApp();
      } on PlatformException {
        // The system says no while the app isn't on top, or within 3 s of the last time.
        state = state.copyWith(notice: RuntimeNotice((state.notice?.seq ?? 0) + 1, appL10n.engineReopenFailed));
      }
    }
  }

  Future<void> stop() => _bridge.stop();

  Future<void> reset() => resetKeeping(const ResetKeep());

  /// Resets the runtime; [keep] comes back with the next install.
  Future<void> resetKeeping(ResetKeep keep) async {
    final r = ref;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await _bridge.reset(keep: keep);
    if (r.mounted) await _refresh();
  }
}

final localRuntimeProvider = NotifierProvider<LocalRuntimeController, LocalRuntimeState>(LocalRuntimeController.new);

/// The last 1000 engine log lines. The native snapshot and the live batches share
/// one sequence, so batches that arrive while the snapshot is read are neither lost
/// nor shown twice.
class LocalRuntimeLogsController extends Notifier<List<String>> {
  static const _maxLogs = 1000;

  @override
  List<String> build() {
    final r = ref;
    final bridge = r.read(runtimeBridgeProvider);
    final lines = ListQueue<String>();
    final pending = ListQueue<RuntimeLogEntry>();
    var loading = true;
    var throughSeq = 0;

    bool append(Iterable<RuntimeLogEntry> entries) {
      var changed = false;
      for (final entry in entries) {
        if (entry.seq <= throughSeq) continue;
        lines.addLast(entry.line);
        if (lines.length > _maxLogs) lines.removeFirst();
        throughSeq = entry.seq;
        changed = true;
      }
      return changed;
    }

    final sub = bridge.events.listen((event) {
      if (event is! RuntimeLogsEvent) return;
      if (loading) {
        pending.addAll(event.entries);
        while (pending.length > _maxLogs) {
          pending.removeFirst();
        }
      } else if (append(event.entries)) {
        state = List.unmodifiable(lines);
      }
    }, onError: (_) {});
    r.onDispose(sub.cancel);

    Future<void> bootstrap() async {
      try {
        final snapshot = await bridge.logSnapshot();
        if (!r.mounted) return;
        append(snapshot.entries);
        throughSeq = snapshot.throughSeq;
      } catch (_) {
        // Live batches still give a useful tail.
        if (!r.mounted) return;
      }
      append(pending);
      pending.clear();
      loading = false;
      state = List.unmodifiable(lines);
    }

    unawaited(bootstrap());
    return const [];
  }
}

final localRuntimeLogsProvider = NotifierProvider<LocalRuntimeLogsController, List<String>>(
  LocalRuntimeLogsController.new,
);
