import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'companion_reminder.dart';

/// A single, just-accepted command's current-page opportunity. This value is
/// never persisted or reconstructed by a read, reconnect or process restart.
typedef CompanionNotesForegroundCapture = ({MemoryRow task, DshClient client, CompanionTasksCapability capability});

/// One task detail owns this exchange. Closing it never closes the shared
/// client, cancels the durable task, or grants a later foreground opportunity.
class CompanionNotesForeground {
  CompanionNotesForeground._(this.captured, this.client, this.hostKey);
  final MemoryRow captured;
  final DshClient client;
  final String hostKey;
  final abort = DshHttpAbort();
  final _finished = Completer<void>();
  bool _withdrawn = false;
  void Function()? _onWithdraw;
  ({Object error, StackTrace stack})? _failure;
  Future<void> get finished => _finished.future;
  bool get active => !_withdrawn && !abort.isAborted && !_finished.isCompleted;
  void close() {
    if (_withdrawn || _finished.isCompleted) {
      return;
    }
    _withdrawn = true;
    try {
      _onWithdraw?.call();
    } on Object catch (error, stack) {
      // The owned response must still close if recording uncertainty fails.
      // Its retained future reports the failure after the reader has drained.
      _failure ??= (error: error, stack: stack);
    } finally {
      abort.abort();
    }
  }
}

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
  final Map<String, CompanionNotesForeground> _foregrounds = {};

  CompanionNotesForeground foreground(
    MemoryRow captured, {
    required DshClient client,
    required String hostKey,
    required CompanionTasksCapability capability,
    required bool Function() isCurrent,
    required void Function(MemoryRow task) observed,
  }) {
    final id = captured['task_id']! as String;
    if (_foregrounds.containsKey(id)) {
      throw const DshRemoteException('companion/task-conflict', 'The original foreground request is still closing');
    }
    final owned = CompanionNotesForeground._(captured, client, hostKey);
    _foregrounds[id] = owned;
    retainReceipt(owned.finished);
    unawaited(() async {
      try {
        final snapshot = await client.readCompanionHostTask(
          hostStoreId: captured['host_store_id']! as String,
          taskId: id,
        );
        if (snapshot == null) {
          throw const DshRemoteException('companion/task-not-found', 'The original task was not found');
        }
        final checked = store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
        if (!owned.active || !isCurrent()) {
          return;
        }
        observed(checked);
        final request = store.prepareHostTaskForeground(
          taskId: id,
          taskRev: captured['task_rev']! as int,
          hostKey: hostKey,
          hostStoreId: captured['host_store_id']! as String,
          hostExecutionId: captured['host_execution_id']! as String,
        );
        var lastReceiptSeq = checked['applied_host_receipt_seq']! as int;
        int? uncertainSeq;
        bool mark(int seq) => store.markHostTaskForegroundUncertain(
          taskId: id,
          taskRev: captured['task_rev']! as int,
          hostKey: hostKey,
          hostStoreId: captured['host_store_id']! as String,
          hostExecutionId: captured['host_execution_id']! as String,
          expectedHostReceiptSeq: seq,
        );
        owned._onWithdraw = () {
          if (mark(lastReceiptSeq)) {
            uncertainSeq = lastReceiptSeq;
          }
        };
        // No await separates the durable uncertainty, last page guard and POST.
        if (!owned.active || !isCurrent()) {
          owned.close();
          return;
        }
        await client.runCompanionNotesForeground(
          capability,
          taskId: id,
          request: request,
          abort: owned.abort,
          onAbnormal: (error, stack) {
            if (!owned.abort.isAborted) {
              owned._failure ??= (error: error, stack: stack);
            }
            owned.close();
          },
          onSnapshot: (value) {
            final before = store.hostTask(id)!;
            final keepUncertain =
                owned._withdrawn &&
                uncertainSeq != null &&
                before['applied_host_receipt_seq'] == uncertainSeq &&
                before['state'] == 'unknown' &&
                before['wait_reason'] == 'host_receipt_unknown';
            final imported = store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: value);
            lastReceiptSeq = value['runnerReceiptSeq']! as int;
            if (keepUncertain) {
              uncertainSeq = mark(lastReceiptSeq) ? lastReceiptSeq : null;
            }
            if (owned.active && isCurrent()) {
              observed(imported);
            }
            changed();
          },
        );
      } on Object catch (error, stack) {
        if (!owned.abort.isAborted) {
          owned._failure ??= (error: error, stack: stack);
        }
        owned.close();
      } finally {
        // Do not re-mark here: a later GET may already have settled the same
        // sequence while this old reader was draining.
        final failure = owned._failure;
        if (failure == null) {
          owned._finished.complete();
        } else {
          owned._finished.completeError(failure.error, failure.stack);
        }
        if (identical(_foregrounds[id], owned)) {
          _foregrounds.remove(id);
        }
        changed();
      }
    }());
    return owned;
  }

  void closeForegrounds() {
    for (final owned in _foregrounds.values) {
      owned.close();
    }
  }

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
    if (submitPending &&
        const ['host.find_draft', 'host.compare_drafts', 'host.receipts_to_sheet'].contains(current['kind']) &&
        commands.every((row) => row['possible_sent_at_ms'] == null)) {
      final available = capability ?? await client.readCompanionTasksCapability();
      if (available == null ||
          (current['kind'] == 'host.find_draft'
              ? !available.findDraft || !available.sourceRead
              : current['kind'] == 'host.compare_drafts'
              ? !available.compareDrafts
              : !available.receiptsToSheet || !available.artifactRead)) {
        throw const DshRemoteException('companion/task-unavailable', 'The Host cannot accept this find task');
      }
      if (available.hostStoreId != hostStore) {
        throw const DshRemoteException(
          'companion/task-store-mismatch',
          'The selected directory belongs to the original task store',
        );
      }
    }
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
      if (available == null ||
          available.hostStoreId == null ||
          (current['kind'] == 'host.find_draft'
              ? !available.findDraft
              : current['kind'] == 'host.compare_drafts'
              ? !available.compareDrafts
              : current['kind'] == 'host.receipts_to_sheet'
              ? !available.receiptsToSheet
              : !available.notes)) {
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

/// Find commands name one directory and one civil day. The quoted label is
/// only a picker hint; a real Host binding supplies the directory reference.
MemoryRow? parseCompanionFind(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'[。.!！]+$'), '');
  const kind = 'host.find_draft';
  if (const ['取消这次找稿', '取消找稿', '不用找稿了', '别找了'].contains(text)) {
    return {'kind': kind, 'operation': 'cancel'};
  }
  if (RegExp(r'^(?:[“‘「『"\x27]|不要|不用|别|假设|故事|台词|他说|她说)').hasMatch(text)) {
    return null;
  }
  const folder = r'(?:“([^”]+)”|‘([^’]+)’|「([^」]+)」|"([^"]+)")';
  final main = RegExp(
    // ignore: prefer_interpolation_to_compose_strings
    r'^(等(?:家里|这台)?电脑(?:开了|上线)[，,]\s*)?'
            r'(?:请帮我|请|帮我)?(?:当前|这台|家里)?(?:电脑)?在' +
        folder +
        r'(?:这个文件夹)?的?(?:这一层|本层)找(昨天|今天|\d{4}-\d{2}-\d{2})'
            r'(?:改|修改)(?:过)?的(?:稿子|稿件|稿|文件)(?=$|[，,。])',
  ).firstMatch(text);
  if (main == null) {
    return text.contains('电脑') && text.contains('找') && (text.contains('稿') || text.contains('文件夹'))
        ? {'kind': kind, 'operation': 'clarify'}
        : null;
  }
  final label = [for (var group = 2; group <= 5; group++) main.group(group)].whereType<String>().single;
  if (label.trim().isEmpty) {
    return {'kind': kind, 'operation': 'clarify'};
  }
  String? afterExit;
  var allowQueue = main.group(1) != null;
  String? deadlineTime;
  List<String>? extensions;
  List<String>? deadlineChoices;
  final clauses = text
      .substring(main.end)
      .split(RegExp(r'[，,。]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty);
  for (final clause in clauses) {
    if (const ['不用翻别处', '不要翻别处', '只查这一层', '原件别动', '不要改原件'].contains(clause)) {
      continue;
    }
    if (const ['离开后继续', '我先走了也继续', '我先去布场', '我离开就停', '我走就停'].contains(clause)) {
      final value = clause.endsWith('停') ? 'pause' : 'continue';
      if (afterExit != null && afterExit != value) {
        return {'kind': kind, 'operation': 'clarify'};
      }
      afterExit = value;
      continue;
    }
    if (const ['电脑上线以后再做', '电脑开了以后再做', '等电脑上线'].contains(clause)) {
      allowQueue = true;
      continue;
    }
    final format = switch (clause.toLowerCase()) {
      '只查md' || '只查markdown' => <String>['md'],
      '只查txt' || '只查纯文本' => <String>['txt'],
      '只查md和txt' || '只查markdown和纯文本' => <String>['md', 'txt'],
      _ => null,
    };
    if (format != null && extensions == null) {
      extensions = format;
      continue;
    }
    final deadline = RegExp(
      r'^(?:在|今天)?((?:[01]\d|2[0-3]):[0-5]\d|今晚七点|晚上七点|七点)(?:以)?前'
      r'(?:完成|给我|把能打开的入口留在小屋|留在小屋)?$',
    ).firstMatch(clause);
    if (deadline != null && deadlineTime == null && deadlineChoices == null) {
      final wording = deadline.group(1)!;
      if (wording == '七点') {
        deadlineChoices = ['07:00', '19:00'];
      } else {
        deadlineTime = wording.endsWith('七点') ? '19:00' : wording;
      }
      continue;
    }
    return {'kind': kind, 'operation': 'clarify'};
  }
  // An unspoken permission to keep working after exit is not inferred from
  // a date or a file name. The supported whole clauses above make it explicit.
  if (afterExit == null) {
    return {'kind': kind, 'operation': 'clarify'};
  }
  return {
    'kind': kind,
    'operation': 'create',
    'directory': label,
    'day': main.group(6),
    'afterExit': afterExit,
    'allowQueue': allowQueue,
    'deadlineTime': deadlineTime,
    'deadlineChoices': ?deadlineChoices,
    'extensions': extensions ?? ['md', 'txt'],
  };
}

/// Freeze the original source day and deadline once, before opening a picker.
/// A repeated accepted command uses its stored agreement instead of this path.
Future<MemoryRow?> companionHostAgreement(MemoryRow source, MemoryRow command, CompanionReminders clock) async {
  final zone = source['zone_id'];
  final offset = source['offset_seconds'];
  if (zone is! String || zone.isEmpty || offset is! int) {
    return null;
  }
  final local = DateTime.fromMillisecondsSinceEpoch((source['said_at_utc']! as int) + offset * 1000, isUtc: true);
  final today = DateTime.utc(local.year, local.month, local.day).toIso8601String().substring(0, 10);
  final date = switch (command['day']) {
    '今天' => today,
    '昨天' => DateTime.utc(local.year, local.month, local.day - 1).toIso8601String().substring(0, 10),
    _ => command['day'] as String,
  };
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
    if (command.containsKey('outputName')) 'outputName': command['outputName'] ?? '$date-待办.md',
  };
}

/// The first release accepts these complete clauses, not a bag of keywords.
/// A and B are selected in that order by the person before a task is stored.
MemoryRow? parseCompanionCompare(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'[。.!！]+$'), '');
  const kind = 'host.compare_drafts';
  if (const ['取消这次对稿', '取消对稿', '不用对稿了', '别对了', '别比较了'].contains(text)) {
    return {'kind': kind, 'operation': 'cancel'};
  }
  if (RegExp(r'^(?:[“‘「『"\x27]|不要|不用|别|假设|故事|台词|他说|她说)').hasMatch(text)) {
    return null;
  }
  final clauses = text.split(RegExp(r'[，,。]')).map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  if (clauses.isEmpty || !RegExp(r'^这两份是我(?:明天上台的)?\s*A\s*稿和\s*B\s*稿$').hasMatch(clauses.first)) {
    return text.contains('电脑') && RegExp(r'对稿|对比|比较|对一遍').hasMatch(text)
        ? {'kind': kind, 'operation': 'clarify'}
        : null;
  }
  bool? allowQueue;
  String? afterExit;
  String? deadlineTime;
  var requested = false;
  for (final clause in clauses.skip(1)) {
    if (const ['电脑上线就帮我对一遍', '电脑开了就帮我对一遍', '请电脑帮我对一遍', '电脑帮我对一遍'].contains(clause)) {
      if (allowQueue != null) {
        return {'kind': kind, 'operation': 'clarify'};
      }
      allowQueue = clause.startsWith('电脑上线') || clause.startsWith('电脑开了');
      continue;
    }
    final highlights = RegExp(
      r'^(?:((?:[01]\d|2[0-3]):[0-5]\d|晚上八点|今晚八点)前)?'
      r'列至多三处最值得重新练的改动$',
    ).firstMatch(clause);
    if (highlights != null && !requested) {
      requested = true;
      final deadline = highlights.group(1);
      deadlineTime = deadline == null
          ? null
          : deadline.endsWith('八点')
          ? '20:00'
          : deadline;
      continue;
    }
    if (const ['我先去排练', '离开后继续', '我先走了也继续', '我离开就停', '我走就停'].contains(clause)) {
      final value = clause.endsWith('停') ? 'pause' : 'continue';
      if (afterExit != null && afterExit != value) {
        return {'kind': kind, 'operation': 'clarify'};
      }
      afterExit = value;
      continue;
    }
    if (const ['两个原文件都别动', '原文件别动', '原件别动', '不要改原件'].contains(clause)) {
      continue;
    }
    return {'kind': kind, 'operation': 'clarify'};
  }
  if (allowQueue == null || afterExit == null || !requested) {
    return {'kind': kind, 'operation': 'clarify'};
  }
  return {
    'kind': kind,
    'operation': 'create',
    'allowQueue': allowQueue,
    'afterExit': afterExit,
    'deadlineTime': deadlineTime,
  };
}

/// I/J have a deadline, not a file-modification date window. Resolve the spoken
/// time against the original source day; a later retry uses the saved terms.
Future<MemoryRow?> companionCompareAgreement(MemoryRow source, MemoryRow command, CompanionReminders clock) async {
  int? deadlineAt;
  if (command['deadlineTime'] case final String time) {
    final zone = source['zone_id'];
    final offset = source['offset_seconds'];
    if (zone is! String || zone.isEmpty || offset is! int) {
      return null;
    }
    final local = DateTime.fromMillisecondsSinceEpoch((source['said_at_utc']! as int) + offset * 1000, isUtc: true);
    final day = DateTime.utc(local.year, local.month, local.day).toIso8601String().substring(0, 10);
    final resolved = await clock.resolve(day, time, zone);
    if (resolved['kind'] != 'unique') {
      return null;
    }
    deadlineAt = ((resolved['moments']! as List<Object?>).single! as Map<Object?, Object?>)['epochMs']! as int;
  }
  return {'deadlineAtMs': deadlineAt, 'afterExit': command['afterExit'], 'allowQueue': command['allowQueue']};
}

/// Only complete supported clauses accept a receipt task. Selecting all four
/// originals and the output folder remains an explicit phone action.
MemoryRow? parseCompanionReceipts(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'[。.!！]+$'), '');
  const kind = 'host.receipts_to_sheet';
  if (const ['取消整理票据', '取消这次整理票据', '别整理票据了', '这张表先别做了'].contains(text)) {
    return {'kind': kind, 'operation': 'cancel'};
  }
  if (RegExp(r'^(?:[“‘「『"\x27]|不要|不用|别|假设|故事|台词|他说|她说)').hasMatch(text)) {
    return null;
  }
  final clauses = text.split(RegExp(r'[，,。]')).map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  if (clauses.isEmpty || !const ['等电脑开了', '等电脑上线', '请电脑现在处理'].contains(clauses.first)) {
    return RegExp(r'四张票|整理票据').hasMatch(text) && RegExp(r'新建|表|电脑').hasMatch(text)
        ? {'kind': kind, 'operation': 'clarify'}
        : null;
  }
  var originals = false;
  String? outputName;
  String? deadlineTime;
  String? afterExit;
  for (final clause in clauses.skip(1)) {
    if (!originals && RegExp(r'''^把我选的(?:[‘“「'].*[’”」'])?这四张票整理成日期、项目、金额$''').hasMatch(clause)) {
      originals = true;
      continue;
    }
    final deadline = RegExp(r'^((?:[01]\d|2[0-3]):[0-5]\d|今晚八点|晚上八点)前$').firstMatch(clause);
    if (deadline != null && deadlineTime == null) {
      final value = deadline.group(1)!;
      deadlineTime = value.endsWith('八点') ? '20:00' : value;
      continue;
    }
    final output = RegExp(r'^在这个文件夹新建《([^/\\\x00]+\.xlsx)》$').firstMatch(clause);
    if (output != null && outputName == null) {
      outputName = output.group(1)!;
      continue;
    }
    if (const ['我先去吃饭', '离开后继续', '我先走了也继续', '我离开就停', '我走就停'].contains(clause)) {
      final value = clause.endsWith('停') ? 'pause' : 'continue';
      if (afterExit != null && afterExit != value) {
        return {'kind': kind, 'operation': 'clarify'};
      }
      afterExit = value;
      continue;
    }
    if (const ['原件别动', '不要改原件', '四份原件都别动'].contains(clause)) {
      continue;
    }
    return {'kind': kind, 'operation': 'clarify'};
  }
  if (!originals || outputName == null || afterExit == null) {
    return {'kind': kind, 'operation': 'clarify'};
  }
  return {
    'kind': kind,
    'operation': 'create',
    'allowQueue': clauses.first.startsWith('等'),
    'afterExit': afterExit,
    'deadlineTime': deadlineTime,
    'outputName': outputName,
  };
}
