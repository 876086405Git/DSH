import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../state/android_features.dart';
import '../state/app_info.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show appForegroundProvider;
import '../state/settings_state.dart';
import 'app_error_log.dart';
import 'diagnostics_bundle.dart';
import 'diagnostics_channel.dart';
import 'diagnostics_sections.dart';

enum AutomaticDiagnosticsPhase { waiting, collecting, analyzing, complete, failed, cancelled }

typedef DiagnosticSender = Future<void> Function(
  String prompt,
  bool Function() isCurrent,
  Future<void> Function(String sessionId, Future<void> Function() cancel) created,
);

/// A single owner; dependencies are injected so asynchronous revocation and
/// persistence-before-send can be checked without Android or a model request.
class AutomaticDiagnostics extends ChangeNotifier {
  AutomaticDiagnostics({
    required this.collect,
    required this.load,
    required this.store,
    this.guardStaleCancellation = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<DiagnosticsSnapshot> Function() collect;
  final Future<Map<String, Object?>> Function() load;
  final Future<void> Function(Map<String, Object?> checkpoint) store;
  final bool guardStaleCancellation;
  AutomaticDiagnosticsPhase phase = AutomaticDiagnosticsPhase.waiting;
  String? reportSessionId;
  String? failureCode;
  final Map<String, int> _through = {};
  final Map<String, int> _fingerprints = {};
  final DateTime Function() _clock;
  late final Future<void> ready = _restore();
  bool _busy = false;
  bool _disposed = false;
  bool _storageFailed = false;
  int _epoch = 0;
  Object? _owner;
  DiagnosticSender? _send;
  Future<void> Function()? _cancel;

  bool get eligible => _send != null;
  bool get busy => _busy;

  /// The integration replaces the owner on disable, background, host change or
  /// reconnect. Every awaited boundary checks this generation before more RPCs.
  void configure(Object? owner, DiagnosticSender? send) {
    if (_disposed || identical(owner, _owner)) return;
    _owner = owner;
    _send = send;
    _epoch++;
    final cancel = _cancel;
    _cancel = null;
    if (_busy) {
      phase = AutomaticDiagnosticsPhase.cancelled;
      if (cancel != null) unawaited(_cancelOnce(cancel));
    }
    _notifyLater();
  }

  Future<void> _cancelOnce(Future<void> Function() cancel) async {
    final epoch = _epoch;
    try {
      await cancel().timeout(const Duration(seconds: 10));
    } catch (_) {
      // OH cancellation may finish after an owner change or explicit recovery.
      // A failure in the still-current generation remains visible.
      if (!_disposed && (!guardStaleCancellation || epoch == _epoch)) {
        failureCode = 'cancel_failed';
        phase = AutomaticDiagnosticsPhase.failed;
        notifyListeners();
      }
    }
  }

  Map<String, Object?> _checkpoint() => {
    'through': Map<String, int>.of(_through),
    'fingerprints': Map<String, int>.of(_fingerprints),
    'sessionId': reportSessionId,
    'phase': phase.name,
    'failureCode': failureCode,
  };

  void _notifyLater() => scheduleMicrotask(() {
    if (!_disposed) notifyListeners();
  });

  Future<void> _restore() async {
    try {
      final saved = await load();
      if (_disposed) return;
      final through = saved['through'];
      if (through is Map) {
        for (final key in const ['appErrors', 'voiceStages', 'processExits']) {
          if (through[key] case final int value) _through[key] = value;
        }
      }
      final fingerprints = saved['fingerprints'];
      if (fingerprints is Map) {
        for (final entry in fingerprints.entries.take(32)) {
          if (entry.key is String && entry.value is int) _fingerprints[entry.key as String] = entry.value as int;
        }
      }
      reportSessionId = saved['sessionId'] is String ? saved['sessionId'] as String : null;
      // A killed process must not silently resubmit an ambiguous request.
      phase = switch (saved['phase']) {
        'complete' => AutomaticDiagnosticsPhase.complete,
        'analyzing' || 'collecting' || 'cancelled' => AutomaticDiagnosticsPhase.cancelled,
        'failed' => AutomaticDiagnosticsPhase.failed,
        _ => AutomaticDiagnosticsPhase.waiting,
      };
      failureCode = saved['failureCode'] is String ? saved['failureCode'] as String : null;
      _storageFailed = failureCode == 'store_failed';
      if (_storageFailed) phase = AutomaticDiagnosticsPhase.failed;
    } catch (_) {
      _storageFailed = true;
      phase = AutomaticDiagnosticsPhase.failed;
      failureCode = 'store_failed';
    }
    if (!_disposed) notifyListeners();
  }

  /// Explicit local recovery only. Baseline retained failures before unlocking;
  /// this method never creates a conversation or calls the model sender.
  Future<void> recoverStorage({required bool Function() isCurrent}) async {
    if (_disposed || _busy || !_storageFailed || !isCurrent()) return;
    _busy = true;
    // Recovery owns new state even when the connection owner remains null.
    if (guardStaleCancellation) _epoch++;
    final epoch = _epoch;
    bool current() => !_disposed && epoch == _epoch && isCurrent();
    notifyListeners();
    try {
      await ready;
      if (!current()) return;
      Map<String, Object?> saved = const {};
      try {
        saved = await load().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Only this deliberate recovery may rebuild unreadable local state.
      }
      if (!current()) return;
      final through = saved['through'];
      if (through is Map) {
        for (final key in const ['appErrors', 'voiceStages', 'processExits']) {
          final at = through[key];
          if (at is int && at > (_through[key] ?? 0)) _through[key] = at;
        }
      }
      final fingerprints = saved['fingerprints'];
      if (fingerprints is Map) {
        for (final entry in fingerprints.entries.take(32)) {
          if (entry.key is String && entry.value is int && entry.value > (_fingerprints[entry.key] ?? 0)) {
            _fingerprints[entry.key as String] = entry.value as int;
          }
        }
      }
      final snapshot = await collect().timeout(const Duration(seconds: 5));
      if (!current()) return;
      final evidence = snapshot.native.evidence;
      final availability = evidence['availability'];
      const kinds = ['appErrors', 'voiceStages', 'processExits'];
      if (kinds.any((key) => evidence[key] is! List) ||
          availability is Map && kinds.any((key) => availability[key] == 'unavailable')) {
        throw StateError('diagnostics_recovery_evidence_unavailable');
      }
      final now = _clock().millisecondsSinceEpoch;
      _fingerprints.removeWhere((_, at) => at < now - const Duration(hours: 24).inMilliseconds);
      for (final signature in diagnosticFailureFingerprints(snapshot, const {})) {
        _fingerprints.putIfAbsent(signature, () => now);
      }
      for (final entry in diagnosticFailureWatermarks(snapshot.native.evidence).entries) {
        if (entry.value > (_through[entry.key] ?? 0)) _through[entry.key] = entry.value;
      }
      while (_fingerprints.length > 32) {
        _fingerprints.remove(_fingerprints.keys.first);
      }
      await store({..._checkpoint(), 'phase': 'waiting', 'failureCode': null});
      if (!current()) return;
      _storageFailed = false;
      failureCode = null;
      phase = AutomaticDiagnosticsPhase.waiting;
    } catch (_) {
      _storageFailed = true;
    } finally {
      _busy = false;
      if (_storageFailed) {
        failureCode = 'store_failed';
        phase = AutomaticDiagnosticsPhase.failed;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> check() async {
    if (_disposed || _busy || _send == null || _storageFailed) return;
    _busy = true;
    final epoch = _epoch;
    final send = _send!;
    bool current() => !_disposed && epoch == _epoch && _send != null;
    try {
      await ready;
      if (!current() || _storageFailed) return;
      final previousPhase = phase;
      phase = AutomaticDiagnosticsPhase.collecting;
      notifyListeners();
      final snapshot = await collect().timeout(const Duration(seconds: 5));
      if (!current()) return;
      final next = diagnosticFailureWatermarks(snapshot.native.evidence);
      final fresh = next.entries.any((e) => e.value > (_through[e.key] ?? 0));
      if (!fresh) {
        phase = previousPhase;
        return;
      }
      final now = _clock().millisecondsSinceEpoch;
      final cutoff = now - const Duration(hours: 24).inMilliseconds;
      _fingerprints.removeWhere((_, at) => at < cutoff);
      final signatures = diagnosticFailureFingerprints(
        snapshot,
        _through,
      ).where((s) => !_fingerprints.containsKey(s)).toList();
      for (final e in next.entries) {
        if (e.value > (_through[e.key] ?? 0)) _through[e.key] = e.value;
      }
      for (final signature in signatures) {
        _fingerprints[signature] = now;
      }
      while (_fingerprints.length > 32) {
        _fingerprints.remove(_fingerprints.keys.first);
      }
      phase = signatures.isEmpty ? previousPhase : AutomaticDiagnosticsPhase.analyzing;
      if (signatures.isNotEmpty) failureCode = null;
      // Consumed even on failure. Persist BEFORE create/prompt, never retry the
      // same evidence after a crash, timeout or ambiguous network response.
      try {
        await store(_checkpoint());
      } catch (_) {
        _storageFailed = true;
        rethrow;
      }
      if (!current() || signatures.isEmpty) return;
      final prompt =
          '请仅根据以下结构化 dsh-Go 故障事实进行分析，给出证据、不确定性和最小手动恢复步骤。'
          '不要调用工具、执行命令、改权限、读取其他文件、创建计划或向 GitHub 外发；未授权进一步采集。\n'
          '${jsonEncode(diagnosticsAnalysisFacts(snapshot))}';
      await send(prompt, current, (id, cancel) async {
        if (!current()) return;
        reportSessionId = id;
        _cancel = cancel;
        await store(_checkpoint());
        if (current()) notifyListeners();
      });
      if (!current()) return;
      phase = AutomaticDiagnosticsPhase.complete;
      await store(_checkpoint());
    } catch (_) {
      // Do not enter AppErrorLog: analysis failures must not diagnose themselves.
      if (current()) {
        phase = AutomaticDiagnosticsPhase.failed;
        failureCode = _storageFailed ? 'store_failed' : 'analysis_failed';
        try {
          await store(_checkpoint());
        } catch (_) {
          _storageFailed = true;
          failureCode = 'store_failed';
        }
      }
    } finally {
      _cancel = null;
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    final cancel = _cancel;
    _cancel = null;
    if (cancel != null) unawaited(_cancelOnce(cancel));
    super.dispose();
  }
}

/// Fixed three integer watermarks, bounded across restarts. Native events use
/// Unix milliseconds; events with the same timestamp are one failure batch.
Map<String, int> diagnosticFailureWatermarks(Map<String, Object?> evidence) {
  final result = <String, int>{};
  for (final key in const ['appErrors', 'voiceStages', 'processExits']) {
    final rows = evidence[key];
    if (rows is! List) continue;
    for (final row in rows.whereType<Map>()) {
      final at = row['at'];
      if (_isFailure(key, row) && at is int && at > (result[key] ?? 0)) result[key] = at;
    }
  }
  return result;
}

bool _isFailure(String key, Map row) => switch (key) {
  // A model/session error could be our own failed analysis.
  'appErrors' => row['source'] == 'flutter' || row['source'] == 'platform',
  'voiceStages' => row['stage'] == 'error' || row['stage'] == 'failed',
  'processExits' =>
    row['source'] == 'hiAppEvent'
        ? const ['APP_CRASH', 'APP_FREEZE'].contains(row['event'])
        : const [3, 4, 5, 6].contains(row['reason']),
  _ => false,
};

/// Stable content-free identities: no timestamps, messages, credentials or raw
/// logs. Only hashes and attempt times are retained, at most 32 for 24 hours.
Set<String> diagnosticFailureFingerprints(DiagnosticsSnapshot snapshot, Map<String, int> through) {
  final evidence = snapshot.native.evidence;
  final version = [AppInfo.version, snapshot.native.app['versionName'], snapshot.native.app['versionCode']];
  final voice = evidence['voiceStages'];
  final lastVoice = voice is List && voice.isNotEmpty && voice.last is Map ? voice.last as Map : const {};
  final result = <String>{};
  for (final key in const ['appErrors', 'voiceStages', 'processExits']) {
    final rows = evidence[key];
    if (rows is! List) continue;
    for (final row in rows.whereType<Map>()) {
      final at = row['at'];
      if (!_isFailure(key, row) || at is! int || at <= (through[key] ?? 0)) continue;
      final fields = switch (key) {
        'appErrors' => [row['source'], row['errorType'], row['stack']],
        'voiceStages' => [row['stage'], row['backend'], row['code']],
        _ =>
          row['source'] == 'hiAppEvent'
              ? [row['source'], row['event'], row['crashType'], lastVoice['stage'], lastVoice['backend']]
              : [row['reason'], row['status'], lastVoice['stage'], lastVoice['backend']],
      };
      result.add(sha256.convert(utf8.encode(jsonEncode([version, key, fields]))).toString());
    }
  }
  return result;
}

/// No ChatController, selected-session mutation, global defaults or approval
/// responder: a normal persisted session with a server-side no-tools preset.
Future<void> sendDiagnosticAnalysis(
  DshClient client,
  String prompt,
  bool Function() current,
  Future<void> Function(String, Future<void> Function()) created, {
  Duration rpcWait = const Duration(seconds: 10),
}) async {
  void guard() {
    if (!current()) throw StateError('diagnostics_revoked');
  }

  guard();
  const preset = 'dsh-go-diagnostics';
  final session = await client.createSession(cwd: '/root/workspace', agentPreset: preset).timeout(rpcWait);
  guard();
  if (session.sessionId.isEmpty || session.agentPreset != preset) {
    throw StateError('diagnostics_analysis_preset_unavailable');
  }
  final id = session.sessionId;
  StreamSubscription<DshEvent>? subscription;
  Future<String>? rawSubmission;
  Future<void>? stopping;
  Future<void>? cancellation;
  final ended = Completer<String>();
  Future<void> cancelOnce() => cancellation ??= client.cancel(id).timeout(rpcWait);
  Future<void> stop() => stopping ??= (() async {
    if (!ended.isCompleted) ended.complete('cancelled');
    await subscription?.cancel();
    final pending = rawSubmission;
    if (pending != null) {
      // prompt queues a request; its timeout does not abort the original RPC.
      // cancel accepts idle sessions too, so never send it before that RPC
      // settles. Keep the raw future for a single late cancellation, not retry.
      final settled = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      try {
        await settled.timeout(rpcWait);
      } on TimeoutException {
        unawaited(
          settled.then((_) => cancelOnce()).catchError((Object _) {
            // stop() already reported an uncertain stop; retain that visible
            // failure instead of entering AppErrorLog or retrying cancellation.
          }),
        );
        rethrow;
      }
    }
    await cancelOnce();
  })();
  await created(id, stop);
  guard();
  // The dedicated preset must restrict tools with allow: [] and override the
  // inherited PTC executor with native. Persona scoping alone does NOT hide root
  // MCP. No skills, runtime context or AGENTS are mounted. A normal preset (even
  // read-only/plan mode) is not equivalent; never fall back to it.
  final projections = await client.projections(id).timeout(rpcWait);
  guard();
  if (projections?.agentPreset != preset) throw StateError('diagnostics_analysis_preset_not_confirmed');
  await client.renameSession(id, appL10n.automaticDiagnosticsReportTitle).timeout(rpcWait);
  guard();
  final ready = Completer<void>();
  void observe(DshEvent event) {
    if (event is SessionSnapshotEvent) {
      if (!ready.isCompleted) ready.complete();
      for (final item in event.events) {
        observe(item);
      }
    } else if (event is TurnEndedEvent && !ended.isCompleted) {
      ended.complete(event.reason.kind);
    }
  }

  subscription = client
      .watch(id)
      .listen(
        observe,
        onError: (Object _) {
          if (!ready.isCompleted) ready.complete();
          if (!ended.isCompleted) ended.complete('error');
        },
        onDone: () {
          if (!ready.isCompleted) ready.complete();
          if (!ended.isCompleted) ended.complete('closed');
        },
      );
  var submitted = false;
  try {
    await ready.future.timeout(rpcWait);
    guard();
    if (ended.isCompleted) throw StateError('diagnostics_follow_failed');
    submitted = true;
    rawSubmission = client.prompt(id, prompt);
    await rawSubmission.timeout(rpcWait);
    final reason = await ended.future.timeout(const Duration(minutes: 2));
    guard();
    if (reason != 'completed') throw StateError('diagnostics_turn_failed');
  } catch (_) {
    // A sent/ambiguous request cannot be withdrawn; ask the original local
    // engine to stop once. Never resend, nor redirect cancellation to a new host.
    if (submitted && current()) await stop();
    rethrow;
  } finally {
    await subscription.cancel();
  }
}

final automaticDiagnosticsProvider = Provider<AutomaticDiagnostics>((ref) {
  const key = 'automatic_diagnostics_checkpoint';
  final coordinator = AutomaticDiagnostics(
    guardStaleCancellation: ref.watch(operatingSystemProvider) == 'ohos',
    collect: () async {
      // Capture ref-bound state before the platform await. No ref access after
      // await: this provider can be disposed or the host can change meanwhile.
      final status = ref.read(localRuntimeProvider).status;
      final settings = ref.read(settingsProvider);
      final channel = ref.read(diagnosticsChannelProvider);
      final native = await channel.info();
      return DiagnosticsSnapshot(at: DateTime.now(), status: status, settings: settings, native: native);
    },
    load: () async {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return {};
      final value = jsonDecode(raw);
      if (value is! Map) throw StateError('diagnostics_invalid_checkpoint');
      return Map<String, Object?>.from(value);
    },
    store: (value) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, jsonEncode(value))) throw StateError('diagnostics_store_failed');
    },
  );
  Timer? poll;
  DshClient? owner;
  ProviderSubscription<AsyncValue<HostConnection?>>? activeSubscription;
  ProviderSubscription<AsyncValue<HostConnection?>>? localSubscription;
  bool updating = false;
  bool updateAgain = false;
  void useClient(DshClient? next) {
    if (identical(next, owner)) return;
    owner = next;
    coordinator.configure(
      next,
      next == null ? null : (prompt, current, created) => sendDiagnosticAnalysis(next, prompt, current, created),
    );
    poll?.cancel();
    poll = next == null ? null : Timer.periodic(const Duration(minutes: 1), (_) => unawaited(coordinator.check()));
    if (next != null) scheduleMicrotask(() => unawaited(coordinator.check()));
  }

  void update() {
    if (!ref.mounted) return;
    if (updating) {
      updateAgain = true;
      return;
    }
    updating = true;
    try {
      do {
        updateAgain = false;
        final settings = ref.read(settingsProvider);
        final baseReady =
            settings.loaded &&
            settings.automaticDiagnostics &&
            ref.read(appForegroundProvider) &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
            ref.read(activeHostProvider).isLocal &&
            ref.read(localRuntimeProvider).loaded &&
            ref.read(localRuntimeProvider).status.phase == RuntimePhase.running;
        if (!baseReady) {
          // Revoke before removing listeners. Closed/default-off diagnostics
          // must not construct either connection (including remote host links).
          useClient(null);
          activeSubscription?.close();
          activeSubscription = null;
          localSubscription?.close();
          localSubscription = null;
          continue;
        }
        // Ref.listen returns a closable subscription. Keep the coordinator
        // stable while lazily attaching connections only after the base gates.
        localSubscription ??= ref.listen(localConnectionProvider, (_, _) => update());
        activeSubscription ??= ref.listen(activeConnectionProvider, (_, _) => update());
        final active = activeSubscription!.read();
        final local = localSubscription!.read();
        final client = local.value?.client;
        final eligible =
            !active.isLoading &&
            !active.hasError &&
            !local.isLoading &&
            !local.hasError &&
            client != null &&
            active.value?.isLocal == true &&
            identical(active.value?.client, client);
        useClient(eligible ? client : null);
      } while (updateAgain && ref.mounted);
    } finally {
      updating = false;
    }
  }

  final lifecycle = AppLifecycleListener(onStateChange: (_) => update());
  ref.listen(settingsProvider, (_, _) => update());
  ref.listen(activeHostProvider, (_, _) => update());
  ref.listen(localRuntimeProvider.select((s) => (s.loaded, s.status.phase)), (_, _) => update());
  ref.listen(appForegroundProvider, (_, _) => update());
  void changed() => unawaited(coordinator.check());
  appErrorLog.revision.addListener(changed);
  ref.onDispose(() {
    poll?.cancel();
    activeSubscription?.close();
    localSubscription?.close();
    lifecycle.dispose();
    appErrorLog.revision.removeListener(changed);
    coordinator.dispose();
  });
  unawaited(coordinator.ready);
  update();
  return coordinator;
});
