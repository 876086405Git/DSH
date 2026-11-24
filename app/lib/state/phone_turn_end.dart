// Native session tasks finish from the exact host run-end receipt. Legacy engines retain
// the original single-candidate association. Both paths retain return preference,
// foreground/bot routing and the existing native return/notification fallback.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../companion/companion_agent_phone_tools.dart' show companionPhoneWindow;
import '../notify/chat_alerts.dart';
import '../notify/notify_channel.dart';
import '../l10n/l10n.dart';
import 'app_info.dart';
import 'bots_state.dart';
import 'chat_reveal.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'notify_state.dart' show appForegroundProvider, notifyChannelProvider;
import 'phone_state.dart';

void _trace(String message) {
  if (!kReleaseMode && const bool.fromEnvironment('DSH_PHONE_TURN_TRACE')) {
    debugPrint('DSH_PHONE_TURN $message');
  }
}

/// 设置 → 手机操控 → 「完成后返回 dsh-go」, on by default.
class PhoneReturnPrefController extends Notifier<bool> {
  static const key = 'phone_return_after_done';

  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getBool(key);
      if (stored != null && ref.mounted) state = stored;
    } catch (_) {
      // No preferences backend: the default.
    }
  }

  /// Applies after the stored value is in, so a late load can't undo it.
  Future<void> set(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, value);
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final phoneReturnPrefProvider = NotifierProvider<PhoneReturnPrefController, bool>(PhoneReturnPrefController.new);

/// Which local turn end is the phone task's. Plain Dart (unit-tested).
class PhoneTurnLink {
  int? _taskId;
  bool _armed = false;
  Set<String>? _candidates;
  ({int taskId, String sessionId, Set<String> candidates})? _lastClaim;

  int? get taskId => _taskId;

  /// A phone task ran (or was stopped) and its turn hasn't ended yet.
  bool get armed => _armed;

  /// The conversations it may belong to; null while unknown. Only one is usable.
  Set<String>? get candidates => _candidates;

  /// A status push. True when a new task began: report the conversations
  /// running now with [began].
  bool onStatus(PhoneTaskStatus task) {
    if (task.active) {
      if (task.id == null) return false;
      final fresh = task.id != _taskId;
      if (fresh) {
        _taskId = task.id;
        _armed = true;
        _candidates = null;
        _lastClaim = null;
      }
      return fresh;
    }
    // Over without a stop (minutes idle, engine gone): the overlay went with
    // it and the person has moved on; that turn ending later changes nothing.
    if (!task.stopped && task.id == _taskId) {
      _armed = false;
      _candidates = null;
    }
    return false;
  }

  /// All local conversations running when the task began, including subagents.
  void began(Iterable<String> running) {
    if (!_armed) return;
    _candidates = running.toSet();
  }

  /// Claims an end only for the single captured candidate of this native task.
  bool onTurnEnd(String sessionId) {
    if (!_armed || _taskId == null) return false;
    final c = _candidates;
    if (c == null || c.length != 1 || !c.contains(sessionId)) return false;
    _lastClaim = (taskId: _taskId!, sessionId: sessionId, candidates: c);
    _armed = false;
    _candidates = null;
    return true;
  }

  /// Busy is not evidence that some other conversation owns the task.
  void refused(String sessionId, int taskId) {
    final last = _lastClaim;
    if (last == null || last.sessionId != sessionId || last.taskId != taskId || _taskId != taskId || _armed) return;
    _armed = true;
    _candidates = last.candidates;
  }

  /// The connection or a newer run invalidated the task's ownership evidence.
  void invalidate() {
    _armed = false;
    _candidates = null;
    _lastClaim = null;
  }
}

class _OwnerRead {
  _OwnerRead(this.taskId, this.client, this.generation, this.lifetime);
  final int taskId;
  final DshClient client;
  final MuxGeneration? generation;
  final Object lifetime;
  bool valid = true;
  StreamSubscription<DshConnectionState>? mux;
  StreamSubscription<HostEvent>? events;

  void retire() {
    valid = false;
    unawaited(mux?.cancel());
    unawaited(events?.cancel());
  }
}

class _DeferredPhoneEnd {
  _DeferredPhoneEnd(this.read, this.ready);
  final _OwnerRead read;
  final void Function() ready;
  Timer? timer;
}

/// Watches the phone task and ends it with its turn ([onTurnEnd], called by
/// ChatAlertsController for every local turn end). Kept alive with
/// [phoneStopWatcherProvider] by the home shell, so it has seen the task begin.
class PhoneTurnEndController extends Notifier<void> {
  final link = PhoneTurnLink();
  bool _sessionTasks = false;
  final _nativeEnds = <(int, String, int)>{};
  final _nativeLatest = <String, int>{};
  Object _lifetime = Object();
  _OwnerRead? _reading;
  DshClient? _ownerClient;
  MuxGeneration? _ownerGeneration;
  final _deferred = <String, _DeferredPhoneEnd>{};

  static const ownerWait = Duration(seconds: 5);
  static const maxDeferredEnds = 8;

  @override
  void build() {
    final lifetime = _lifetime = Object();
    final channel = ref.watch(phoneChannelProvider);
    ref.listen(localConnectionProvider, (before, after) {
      final old = before?.value?.client;
      final next = after.value?.client;
      if (old != null && !identical(old, next)) {
        link.invalidate();
        _nativeEnds.clear();
        _nativeLatest.clear();
        final reading = _reading;
        if (reading != null) _retireRead(reading);
        _ownerClient = null;
        _ownerGeneration = null;
      }
      if (link.armed &&
          link.candidates == null &&
          after.value?.client != null &&
          !identical(before?.value?.client, after.value?.client)) {
        unawaited(_snapshot(link.taskId!));
      }
    });
    StreamSubscription<PhoneStatus>? sub;
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      if (identical(_lifetime, lifetime)) {
        _lifetime = Object();
        _reading?.retire();
        _reading = null;
        for (final pending in _deferred.values) {
          pending.timer?.cancel();
        }
        _deferred.clear();
        link.invalidate();
      }
      unawaited(sub?.cancel());
    });
    unawaited(() async {
      try {
        final status = await channel.status();
        // No native side (tests, an older build): nothing to watch.
        if (disposed || !status.ready) return;
        _onStatus(status);
        sub = channel.statusChanges.listen((status) {
          if (!disposed) _onStatus(status);
        }, onError: (_) {});
      } catch (_) {
        // No platform channels at all (plain unit tests).
      }
    }());
  }

  void _onStatus(PhoneStatus status) {
    if (status.taskProtocol == 1) {
      for (final task in status.tasks) {
        final id = task.id, session = task.sessionId;
        if (id == null || id <= 0 || session == null) continue;
        final latest = _nativeLatest[session];
        if (latest == null || id > latest) _nativeLatest[session] = id;
      }
      for (final task in status.tasks) {
        final id = task.id, run = task.endedRunId, generation = task.endedGeneration;
        if (id != null && id > 0 && task.sessionId != null && run != null && generation != null &&
            _nativeEnds.add((id, run, generation))) {
          unawaited(_nativeEnded(task));
        }
      }
    }
    final legacy = status.taskProtocol == 1
        ? status.tasks.where((task) => task.sessionId == null).firstOrNull ?? const PhoneTaskStatus()
        : status.task;
    _sessionTasks = status.taskProtocol == 1 && !legacy.active && !legacy.stopped;
    if (_sessionTasks) {
      link.invalidate();
      final reading = _reading;
      if (reading != null) _retireRead(reading);
      return;
    }
    _trace(
      'task=${legacy.id} event=status active=${legacy.active} stopped=${legacy.stopped} paused=${legacy.paused}',
    );
    if (link.onStatus(legacy)) {
      final reading = _reading;
      if (reading != null) _retireRead(reading, invalidate: false);
      _ownerClient = null;
      _ownerGeneration = null;
      _trace('task=${link.taskId} event=begin');
      // iOS binds the task to the authenticated engine request at admission.
      // A session-list snapshot is for legacy Android tasks with no owner; it
      // can be ambiguous or still pending while the exact iOS owner is known.
      final client = ref.read(localConnectionProvider).value?.client;
      final owner = legacy.ownerSessionId;
      if (owner != null && owner.isNotEmpty && client != null) {
        _ownerClient = client;
        _ownerGeneration = client.mux.generation;
        link.began([owner]);
      } else {
        unawaited(_snapshot(link.taskId!));
      }
    } else if (!link.armed) {
      final reading = _reading;
      if (reading != null) _retireRead(reading, invalidate: false);
    }
  }

  Future<void> _nativeEnded(PhoneTaskStatus task) async {
    final id = task.id!, session = task.sessionId!;
    final lifetime = _lifetime;
    final client = ref.read(localConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    // A companion task goes back to her room (lib/ui/shell/system_entry_host.dart).
    // Asked for from her floating self or her notification, it was outside the
    // app: the person stays where the task left them, her reply in her bubble.
    final companion = companionPhoneWindow(session);
    final reopen = ref.read(phoneReturnPrefProvider) && !ref.read(appForegroundProvider) &&
        (companion == null || companion == 'room');
    final bot = companion == null && ref.read(dsBotSessionFilterProvider)(HostRef.local, session);
    final result = await ref.read(phoneChannelProvider).finishTask(
      taskId: id, sessionId: session, host: HostRef.local.encode(), reopen: reopen,
      runId: task.endedRunId, generation: task.endedGeneration, appOnly: bot,
    );
    // No conversation to reveal, and a chat notification would open none.
    if (companion != null) return;
    if (!ref.mounted || !identical(_lifetime, lifetime) || !result.current ||
        _nativeLatest[session] != id ||
        !identical(ref.read(localConnectionProvider).value?.client, client) ||
        !identical(client?.mux.generation, generation)) {
      return;
    }
    if (result.opened && result.launched && !bot) ref.read(chatRevealProvider.notifier).reveal(session);
    if (result.closed && reopen && !result.opened && !result.notified && !bot && !ref.read(appForegroundProvider)) {
      await ref.read(notifyChannelProvider).tryShow(
        NotifyPost(group: notifyGroup(HostRef.local, session), key: 'phone-$id', attention: true,
          title: AppInfo.name, text: task.completion == 'completed' ? appL10n.phoneTaskResultReady : appL10n.phoneTaskEndedResult, publicText: appL10n.phoneTaskEndedResult,
          sessionId: session, host: HostRef.local, kind: 'phone-result'),
        stillCurrent: () => ref.mounted && identical(_lifetime, lifetime) && _nativeLatest[session] == id &&
          !ref.read(appForegroundProvider) && identical(ref.read(localConnectionProvider).value?.client, client) &&
          identical(client?.mux.generation, generation),
      );
    }
  }

  bool _currentRead(_OwnerRead read) =>
      ref.mounted &&
      read.valid &&
      identical(_lifetime, read.lifetime) &&
      identical(_reading, read) &&
      link.armed &&
      link.taskId == read.taskId &&
      identical(ref.read(localConnectionProvider).value?.client, read.client) &&
      identical(read.client.mux.generation, read.generation);

  void _settleDeferred(_OwnerRead read, {required bool resume}) {
    final keys = [
      for (final e in _deferred.entries)
        if (identical(e.value.read, read)) e.key,
    ];
    for (final key in keys) {
      final pending = _deferred.remove(key)!;
      pending.timer?.cancel();
      if (resume && ref.mounted && identical(_lifetime, read.lifetime)) pending.ready();
    }
  }

  void _retireRead(_OwnerRead read, {bool invalidate = true}) {
    read.retire();
    if (identical(_reading, read)) {
      _reading = null;
      if (invalidate) link.invalidate();
    }
    // New runs, tasks and connections revoke the end itself. Replaying it as
    // an ordinary notification would revive the UI after ownership was lost.
    _settleDeferred(read, resume: false);
  }

  Future<void> _snapshot(int taskId) async {
    final scope = ref;
    final client = scope.read(localConnectionProvider).value?.client;
    if (client == null) return;
    final previous = _reading;
    if (previous != null && previous.taskId == taskId && identical(previous.client, client)) return;
    final read = _reading = _OwnerRead(taskId, client, client.mux.generation, _lifetime);
    read.mux = client.mux.states.listen((_) {
      if (read.valid) _retireRead(read);
    });
    read.events = client.hostEvents.listen((event) {
      if (event is SessionStatusEvent && event.running && _deferred.containsKey(event.sessionId)) {
        // A later run must never be finished using the earlier end and snapshot.
        if (read.valid) _retireRead(read);
      }
    });
    try {
      final sessions = await client.listSessions().timeout(ownerWait);
      if (!_currentRead(read)) return;
      _ownerClient = client;
      _ownerGeneration = read.generation;
      link.began([
        for (final s in sessions)
          if (s.running) s.sessionId,
      ]);
      _trace('task=$taskId event=snapshot candidates=${link.candidates?.length}');
    } catch (_) {
      _trace('task=$taskId event=snapshot-unavailable');
    } finally {
      // Success, ambiguity and a failed/timed-out read may resume normal
      // notification handling only while the original task scope is current.
      final resume = _currentRead(read);
      read.retire();
      if (identical(_reading, read)) _reading = null;
      _settleDeferred(read, resume: resume);
    }
  }

  /// Holds a turn alert only while this task's initial owner read is in flight.
  /// The caller retries once with this hook disabled; timeout/ambiguity must not
  /// requeue forever or turn the currently viewed conversation into proof.
  bool deferTurnEnd(ChatAlert alert, void Function() ready) {
    final read = _reading;
    if (!alert.host.isLocal ||
        alert.key != turnKey ||
        alert.turnEndKind == null ||
        !link.armed ||
        link.candidates != null ||
        read == null ||
        !read.valid ||
        read.taskId != link.taskId ||
        !identical(read.lifetime, _lifetime)) {
      return false;
    }
    if (_deferred.containsKey(alert.sessionId)) return true;
    if (_deferred.length >= maxDeferredEnds) return false;
    final pending = _DeferredPhoneEnd(read, ready);
    _deferred[alert.sessionId] = pending;
    pending.timer = Timer(ownerWait, () {
      if (!identical(_deferred[alert.sessionId], pending)) return;
      _deferred.remove(alert.sessionId);
      if (_currentRead(read)) ready();
    });
    return true;
  }

  /// [alert] is a turn end on some host. Null unless it is the phone task's;
  /// then the overlay is closing (and the app maybe coming back to that
  /// conversation) and the future says how it went.
  Future<PhoneFinish>? onTurnEnd(ChatAlert alert) {
    if (_sessionTasks) return null;
    if (!alert.host.isLocal || alert.key != turnKey || alert.turnEndKind == null) return null;
    final scope = ref;
    final lifetime = _lifetime;
    final client = scope.read(localConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    if (link.candidates != null &&
        (!identical(client, _ownerClient) || !identical(client?.mux.generation, _ownerGeneration))) {
      link.invalidate();
      return null;
    }
    final candidates = link.candidates?.length;
    if (link.armed) _trace('task=${link.taskId} event=end kind=${alert.kind.name} candidates=$candidates');
    if (!link.onTurnEnd(alert.sessionId)) {
      if (link.armed) _trace('task=${link.taskId} event=end-ignored candidates=$candidates');
      return null;
    }
    final taskId = link.taskId!;
    final reopen = ref.read(phoneReturnPrefProvider) && !ref.read(appForegroundProvider);
    // DS Bot's conversations live in their room, not the chat: just the app.
    final bot = ref.read(dsBotSessionFilterProvider)(alert.host, alert.sessionId);
    final channel = ref.read(phoneChannelProvider);
    return () async {
      final result = await channel.finishTask(
        taskId: taskId,
        sessionId: bot ? null : alert.sessionId,
        host: alert.host.encode(),
        reopen: reopen,
      );
      _trace(
        'task=$taskId event=finish closed=${result.closed} busy=${result.busy} opened=${result.opened} launched=${result.launched}',
      );
      if (!scope.mounted ||
          !identical(_lifetime, lifetime) ||
          link.taskId != taskId ||
          !result.current ||
          !identical(scope.read(localConnectionProvider).value?.client, client) ||
          !identical(client?.mux.generation, generation)) {
        return result.retired();
      }
      if (result.busy) link.refused(alert.sessionId, taskId);
      if (result.opened && result.launched && !bot && ref.mounted && link.taskId == taskId) {
        ref.read(chatRevealProvider.notifier).reveal(alert.sessionId);
      }
      if (result.closed && reopen && !result.opened && !result.notified && !bot && !scope.read(appForegroundProvider)) {
        // Return is an explicit phone-control preference. This operational
        // fallback also works with ordinary chat turn notifications off.
        final notified = await scope
            .read(notifyChannelProvider)
            .tryShow(
              NotifyPost(
                group: notifyGroup(alert.host, alert.sessionId),
                key: 'phone-$taskId',
                attention: true,
                title: AppInfo.name,
                text: alert.kind == AlertKind.done ? appL10n.phoneTaskResultReady : appL10n.phoneTaskEndedResult,
                publicText: appL10n.phoneTaskEndedResult,
                sessionId: alert.sessionId,
                host: alert.host,
                kind: 'phone-result',
              ),
              stillCurrent: () =>
                  scope.mounted &&
                  identical(_lifetime, lifetime) &&
                  link.taskId == taskId &&
                  !scope.read(appForegroundProvider) &&
                  identical(scope.read(localConnectionProvider).value?.client, client) &&
                  identical(client?.mux.generation, generation),
            );
        if (notified) return result.withNotice();
      }
      return result;
    }();
  }
}

final phoneTurnEndProvider = NotifierProvider<PhoneTurnEndController, void>(PhoneTurnEndController.new);
