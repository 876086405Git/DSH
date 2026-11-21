import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'companion_reminder.dart';

/// Phone ownership ends at durable commands and complete Host snapshots. The
/// original Host owns execution, approvals and files even after leaving the
/// room. Refresh is read-only. Only an explicit retry may replay an immutable
/// command after an actual read of that same original store.
class CompanionHostTasks {
  CompanionHostTasks({required this.store, required this.changed, required this.retainReceipt});
  final CompanionMemoryStore store;
  final void Function() changed;
  final void Function(Future<void>) retainReceipt;
  final Map<(String, int, String), Future<MemoryRow>> _pending = {};

  Future<MemoryRow> run(
    MemoryRow captured, {
    required DshClient client,
    required String hostKey,
    bool initialOpportunity = false,
    bool submitPending = false,
    bool retryWaiting = false,
    bool replayMissing = false,
    bool resendPendingCommand = false,
    CompanionTasksCapability? capability,
  }) {
    final id = captured['task_id']! as String;
    final revision = captured['task_rev']! as int;
    final key = (
      id,
      revision,
      resendPendingCommand
          ? 'command'
          : retryWaiting
          ? 'retry'
          : replayMissing
          ? 'recover'
          : submitPending
          ? 'submit'
          : 'read',
    );
    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }
    final completed = Completer<MemoryRow>();
    _pending[key] = completed.future;
    // Registration precedes even the first capability/read request.
    retainReceipt(completed.future.then<void>((_) {}));
    unawaited(() async {
      try {
        completed.complete(
          await _execute(
            id,
            revision,
            client,
            hostKey,
            initialOpportunity,
            submitPending,
            retryWaiting,
            replayMissing,
            resendPendingCommand,
            capability,
          ),
        );
      } on Object catch (error, stack) {
        completed.completeError(error, stack);
      } finally {
        _pending.remove(key);
      }
    }());
    return completed.future;
  }

  Future<MemoryRow> _execute(
    String id,
    int revision,
    DshClient client,
    String hostKey,
    bool initialOpportunity,
    bool submitPending,
    bool retryWaiting,
    bool replayMissing,
    bool resendPendingCommand,
    CompanionTasksCapability? capability,
  ) async {
    var current = store.hostTask(id)!;
    if (current['host_key'] != hostKey) {
      throw const DshRemoteException('companion/task-original-host', 'Connect the original task Host');
    }
    final commands = store.hostTaskCommands(id);
    if (current['state'] == 'cancelled' && commands.every((row) => row['possible_sent_at_ms'] == null)) {
      return current;
    }
    var hostStore = current['host_store_id'] as String?;
    var readOriginal = false;
    var missingOriginal = false;
    if (hostStore != null) {
      final snapshot = await client.readCompanionHostTask(hostStoreId: hostStore, taskId: id);
      readOriginal = true;
      missingOriginal = snapshot == null;
      if (snapshot != null) {
        current = store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
        changed();
      }
    } else {
      if (!submitPending) {
        return current;
      }
      final available = capability ?? await client.readCompanionTasksCapability();
      if (available == null || !available.notes || available.hostStoreId == null) {
        throw const DshRemoteException('companion/task-unavailable', 'The Host cannot durably accept this task');
      }
      hostStore = available.hostStoreId!;
    }
    // A newer real command may have arrived while the GET was pending. Its
    // owner sends that command; this old caller may only import its receipt.
    current = store.hostTask(id)!;
    if (current['task_rev'] != revision) {
      return current;
    }
    if (retryWaiting) {
      return _dispatch(
        id,
        1,
        client,
        hostKey,
        hostStore,
        initialOpportunity: false,
        readOriginal: readOriginal,
        retryWaiting: true,
      );
    }
    final recoverMissing = replayMissing && readOriginal && missingOriginal && current['snapshot'] == null;
    final observed = current['snapshot'] as Map?;
    // An unacknowledged higher amendment/cancellation is an existing command,
    // not permission to rerun an unknown physical step. Only this explicit
    // action may replay it after an actual read of the original task store.
    final resendCommand =
        resendPendingCommand &&
        readOriginal &&
        const ['amend', 'cancel'].contains(current['operation']) &&
        (observed == null || (observed['taskRev']! as int) < revision);
    if (!recoverMissing &&
        !resendCommand &&
        (!submitPending || store.hostTaskCommands(id).last['possible_sent_at_ms'] != null)) {
      // This per-call observation is not a new persisted task state. A page
      // cannot enable an old approval just because a cached snapshot remains
      // readable after the original store returned a real 404.
      return {...current, 'observed_host_snapshot': readOriginal && !missingOriginal};
    }
    current = await _dispatch(
      id,
      revision,
      client,
      hostKey,
      hostStore,
      initialOpportunity: initialOpportunity,
      readOriginal: readOriginal,
    );
    final snapshot = current['snapshot'] as Map?;
    if (current['task_rev'] == revision &&
        current['operation'] == 'amend' &&
        current['cancel_requested'] == 0 &&
        snapshot?['taskRev'] == revision &&
        snapshot?['originalCreatePresent'] == false) {
      // The Host has durably stored the new full agreement but still needs
      // the unchanged original identity. It must never execute revision one.
      current = await _dispatch(
        id,
        1,
        client,
        hostKey,
        hostStore,
        initialOpportunity: initialOpportunity,
        readOriginal: readOriginal,
      );
    }
    return current;
  }

  Future<MemoryRow> _dispatch(
    String id,
    int revision,
    DshClient client,
    String hostKey,
    String hostStore, {
    required bool initialOpportunity,
    required bool readOriginal,
    bool retryWaiting = false,
  }) async {
    final command = store.prepareHostTaskOperation(
      taskId: id,
      taskRev: revision,
      hostKey: hostKey,
      hostStoreId: hostStore,
      initialOpportunity: initialOpportunity,
      replayAfterRead: readOriginal,
      retryWaiting: retryWaiting,
    );
    changed();
    if (command == null) {
      return store.hostTask(id)!;
    }
    try {
      final snapshot = await client.writeCompanionHostTask(
        taskId: id,
        operation: command['operation']! as String,
        request: Map<String, Object?>.from(command['request']! as Map),
      );
      final result = store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
      changed();
      return result;
    } on DshRemoteException catch (error) {
      final snapshot = error.details['snapshot'];
      if (snapshot is Map<String, Object?>) {
        store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
        changed();
      }
      rethrow;
    }
  }
}

/// A deliberately finite, whole-clause command. The directory comes from the
/// real Host picker and a durable Host binding, never from model output.
MemoryRow? parseCompanionNotes(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'[。.!！]+$'), '');
  if (const ['取消这次笔记整理', '取消笔记整理', '不用整理笔记了'].contains(text)) {
    return {'operation': 'cancel', 'outputName': null};
  }
  final cancel = RegExp(r'^取消《([^《》]+)》的笔记整理$').firstMatch(text);
  if (cancel != null) {
    return {'operation': 'cancel', 'outputName': cancel.group(1)};
  }
  if (RegExp(r'^(?:[“「『"\x27]|不要|不用|别|假设|故事|台词|他说|她说)').hasMatch(text)) {
    return null;
  }
  final clauses = text.split(RegExp(r'[，,]')).map((item) => item.trim()).toList();
  final main = RegExp(
    r'^(?:请|帮我|让)?(?:当前|这台)?电脑(?:把|将)'
    r'(今天|\d{4}-\d{2}-\d{2})的笔记(?:整理|另存)(?:成|为)(?:一页)?待办(?:清单)?$',
  ).firstMatch(clauses.first);
  if (main == null) {
    return text.contains('电脑') && text.contains('笔记') && text.contains('待办') ? {'operation': 'clarify'} : null;
  }
  String? afterExit;
  var allowQueue = false;
  String? deadlineTime;
  String? outputName;
  for (final clause in clauses.skip(1)) {
    if (const ['原件别动', '不要改原件'].contains(clause)) {
      continue;
    }
    if (const ['我先走了也继续', '离开后继续', '我离开就停', '我走就停'].contains(clause)) {
      final value = clause.endsWith('继续') ? 'continue' : 'pause';
      if (afterExit != null && afterExit != value) {
        return {'operation': 'clarify'};
      }
      afterExit = value;
      continue;
    }
    if (const ['电脑上线以后再做', '电脑开了以后再做'].contains(clause)) {
      allowQueue = true;
      continue;
    }
    final deadline = RegExp(r'^(?:在)?((?:[01]\d|2[0-3]):[0-5]\d)前(?:完成|给我)?$').firstMatch(clause);
    if (deadline != null && deadlineTime == null) {
      deadlineTime = deadline.group(1);
      continue;
    }
    final name = RegExp(r'^文件名(?:为|是)《([^《》]+)》$').firstMatch(clause);
    if (name != null && outputName == null) {
      outputName = name.group(1);
      continue;
    }
    // An unparsed condition may change the scope or deadline; it is not
    // permission to silently keep only the recognised first clause.
    return {'operation': 'clarify'};
  }
  return {
    'operation': 'create',
    'day': main.group(1),
    'afterExit': afterExit ?? 'continue',
    'allowQueue': allowQueue,
    'deadlineTime': deadlineTime,
    'outputName': outputName,
  };
}

/// Freeze the original source day and deadline once, before opening a picker.
/// A repeated accepted command uses its stored agreement instead of this path.
Future<MemoryRow?> companionNotesAgreement(MemoryRow source, MemoryRow command, CompanionReminders clock) async {
  final zone = source['zone_id'];
  final offset = source['offset_seconds'];
  if (zone is! String || zone.isEmpty || offset is! int) {
    return null;
  }
  final local = DateTime.fromMillisecondsSinceEpoch((source['said_at_utc']! as int) + offset * 1000, isUtc: true);
  final today = DateTime.utc(local.year, local.month, local.day).toIso8601String().substring(0, 10);
  final date = command['day'] == '今天' ? today : command['day'] as String;
  final parsed = DateTime.tryParse('${date}T00:00:00Z');
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != date) {
    return null;
  }
  // No spoken deadline stays null. The Host's accumulated actual-work budget
  // is not a phone-side wall clock deadline, especially while awaiting approval.
  int? deadlineAt;
  if (command['deadlineTime'] case final String time) {
    final resolved = await clock.resolve(today, time, zone);
    if (resolved['kind'] != 'unique') {
      return null;
    }
    deadlineAt = ((resolved['moments']! as List).single as Map)['epochMs']! as int;
  }
  return {
    'localDate': date,
    'timeZone': zone,
    'deadlineAtMs': deadlineAt,
    'afterExit': command['afterExit'],
    'allowQueue': command['allowQueue'],
    'outputName': command['outputName'] ?? '$date-待办.md',
  };
}
