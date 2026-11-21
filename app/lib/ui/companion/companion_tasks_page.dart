import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../companion/companion_context.dart';
import '../../companion/companion_memory.dart';
import '../../companion/companion_public_lookup.dart';
import '../../companion/companion_reminder.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../../notify/chat_alerts.dart' show companionHostKey;
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../workspace/directory_picker.dart';
import 'companion_ask.dart';
import 'companion_memory_page.dart' show companionMemoryId;

/// 「11月21日 08:00」 in this phone's local time; the year only when it is not this one.
String _moment(L10n l10n, int epochMs) {
  final at = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final day = at.year == DateTime.now().year ? l10n.monthDay(at) : '${at.year}-${two(at.month)}-${two(at.day)}';
  return '$day ${two(at.hour)}:${two(at.minute)}';
}

String companionReminderFailure(L10n l10n, Object error) {
  if (error is PlatformException && error.code == 'reminder_executor_changed') {
    return l10n.companionReminderNotHere;
  }
  if (error is MissingPluginException || error is PlatformException) {
    return l10n.companionReminderPlatformUnavailable;
  }
  return error is DshRemoteException && error.code.endsWith('conflict')
      ? l10n.companionMemoryConflict
      : l10n.companionReminderSaveFailed;
}

String companionReminderLine(L10n l10n, MemoryRow task, {required String? executorId}) {
  if (executorId == null) {
    return l10n.companionReminderPlatformUnavailable;
  }
  if (task['executor_id'] != executorId) {
    return l10n.companionReminderNotHere;
  }
  if (task['state'] == 'unknown') {
    return task['cancel_requested'] == 1 ? l10n.companionReminderCancelUnknown : l10n.companionReminderUnknown;
  }
  return switch (task['wait_reason']) {
    'text_missing' => l10n.companionReminderTextMissing,
    'date_missing' => l10n.companionReminderDateMissing,
    'time_missing' => l10n.companionReminderTimeMissing,
    'zone_missing' => l10n.companionReminderZoneMissing,
    'time_gap' => l10n.companionReminderGap,
    'time_overlap' => l10n.companionReminderOverlap,
    'exact_alarm_unavailable' => l10n.companionReminderExactMissing,
    'notifications_disabled' => l10n.companionReminderNotificationsMissing,
    'notification_channel_disabled' => l10n.companionReminderChannelMissing,
    'notification_group_disabled' => l10n.companionReminderGroupMissing,
    'time_passed' => l10n.companionReminderTimePassed,
    'invalid_time' => l10n.companionReminderInvalidTime,
    'cancellation_unconfirmed' => l10n.companionReminderCancelUnknown,
    _ => switch (task['state']) {
      'done' => l10n.companionReminderDone,
      'cancelled' => l10n.companionReminderCancelled,
      'queued' || 'running' => l10n.companionReminderQueued,
      _ => l10n.companionReminderFailed,
    },
  };
}

String companionLookupLine(L10n l10n, MemoryRow task, {required String? executorId}) {
  if (executorId == null || task['executor_id'] != executorId) {
    return l10n.companionLookupNotHere;
  }
  if (task['cancel_requested'] == 1) {
    return task['state'] == 'cancelled' ? l10n.companionLookupCancelled : l10n.companionLookupCancelUnknown;
  }
  final result = task['result'];
  if (result is Map && result['conclusion'] is String) {
    return result['conclusion']! as String;
  }
  return switch (task['wait_reason']) {
    'lookup_deadline' => l10n.companionLookupDeadline,
    'lookup_unavailable' => l10n.companionLookupUnavailable,
    'lookup_input_limit' => l10n.companionLookupInputLimit,
    'lookup_query_long' => l10n.companionLookupQueryLong,
    'lookup_answer_incomplete' => l10n.companionLookupAnswerIncomplete,
    _ => switch (task['state']) {
      'done' => l10n.companionLookupDone,
      'partial' => l10n.companionLookupPartial,
      'unknown' => l10n.companionLookupUnknown,
      'queued' || 'running' => l10n.companionLookupQueued,
      _ => l10n.companionLookupFailed,
    },
  };
}

String companionNotesLine(L10n l10n, MemoryRow task) {
  if (task['cancel_requested'] == 1 && task['state'] != 'cancelled') {
    return l10n.companionNotesCancelUnknown;
  }
  return switch (task['wait_reason']) {
    'foreground_control_unavailable' => l10n.companionNotesPauseUnavailable,
    'host_initial_opportunity_lost' => l10n.companionNotesOpportunityLost,
    'host_deadline' => l10n.companionNotesDeadline,
    'original_create_missing' => l10n.companionNotesOriginalPending,
    'no_matching_inputs' => l10n.companionNotesNoInputs,
    'output_exists' => l10n.companionNotesOutputExists,
    'input_file_count_limit' => l10n.companionNotesFileCountLimit,
    'input_file_size_limit' => l10n.companionNotesFileSizeLimit,
    'input_total_size_limit' => l10n.companionNotesTotalSizeLimit,
    'model_input_limit' => l10n.companionNotesModelLimit,
    _ => switch (task['state']) {
      'queued' => l10n.companionNotesQueued,
      'running' => l10n.companionNotesRunning,
      'done' => l10n.companionNotesDone,
      'partial' => l10n.companionNotesPartial,
      'cancelled' => l10n.companionNotesCancelled,
      'failed' => l10n.companionNotesFailed,
      'waiting' => l10n.companionNotesWaiting,
      _ => l10n.companionNotesUnknown,
    },
  };
}

/// The room passes its shared owner and original source session. A trusted
/// notification opens only its stored task; it never selects another host or
/// sends a model request. Native records the actual notification-open event.
class CompanionTasksPage extends ConsumerStatefulWidget {
  const CompanionTasksPage({super.key, this.memory, this.sourceSessionId, this.taskId, this.openedRevision});

  final CompanionMemoryOwner? memory;
  final String? sourceSessionId;
  final String? taskId;
  final int? openedRevision;

  @override
  ConsumerState<CompanionTasksPage> createState() => _CompanionTasksPageState();
}

class _CompanionTasksPageState extends ConsumerState<CompanionTasksPage> {
  CompanionMemoryOwner? _memory;
  String? _executorId;
  bool _busy = false;
  bool _loadFailed = false;
  DshClient? _notesVerifiedClient;
  String? _notesVerifiedStore;
  late final AppLifecycleListener _lifecycle;
  ({String taskId, String raw, MemoryRow source})? _retry;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_refresh(resume: true)));
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final CompanionMemoryOwner memory =
          widget.memory ??
          (await ref.read(
            companionMemoryOwnerProvider('${(await getApplicationSupportDirectory()).path}/companion').future,
          ))!;
      if (!mounted) {
        return;
      }
      _memory = memory;
      memory.addListener(_changed);
      try {
        if (widget.taskId == null || memory.store.hostTask(widget.taskId!) == null) {
          _executorId = await ref.read(companionRemindersProvider).executorId();
        }
      } on PlatformException {
        // Keep the saved agreement readable without claiming it is scheduled here.
      } on MissingPluginException {
        // A platform without this executor can still show the original record.
      }
      if (mounted) {
        setState(() {});
        final hostTask = widget.taskId == null ? null : memory.store.hostTask(widget.taskId!);
        if (hostTask != null) {
          unawaited(_refresh());
          return;
        }
        final row = widget.taskId == null ? null : memory.store.lookupTask(widget.taskId!);
        if (row != null && _owns(row)) {
          _resumeLookup(row);
        }
      }
    } on Object {
      if (mounted) {
        setState(() => _loadFailed = true);
      }
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _memory?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _refresh({bool resume = false}) async {
    final memory = _memory;
    if (memory == null || _busy) {
      return;
    }
    final reminders = ref.read(companionRemindersProvider);
    setState(() => _busy = true);
    try {
      final selected = widget.taskId == null ? null : memory.store.hostTask(widget.taskId!);
      if (selected != null) {
        _notesVerifiedClient = null;
        _notesVerifiedStore = null;
        final client = ref.read(activeConnectionProvider).value?.client;
        final hostKey = companionHostKey(ref.read(activeHostProvider));
        if (client != null && selected['host_key'] == hostKey) {
          try {
            final checked = await memory.hostTasks.run(selected, client: client, hostKey: hostKey);
            if (checked['observed_host_snapshot'] == true) {
              _notesVerifiedClient = client;
              _notesVerifiedStore = checked['host_store_id']! as String;
            }
          } on Object {
            if (mounted) {
              showBriefNotice(context, context.l10n.companionNotesSaveFailed);
            }
          }
        }
        return;
      }
      _executorId = await reminders.executorId();
      if (!mounted) {
        return;
      }
      final row = widget.taskId == null ? null : memory.store.task(widget.taskId!);
      final pending = row != null && (row['state'] == 'waiting' || row['state'] == 'unknown');
      if (!resume && row != null && row['kind'] == 'public.lookup' && row['state'] == 'cancelled') {
        final read = memory.lookups.readReceipts(
          row,
          host: ref.read(activeConnectionProvider).value?.client,
          hostKey: companionHostKey(ref.read(activeHostProvider)),
        );
        memory.retainReceipt(read);
        await read;
      } else if (row != null && row['kind'] == 'public.lookup' && _owns(row)) {
        _resumeLookup(memory.store.lookupTask(row['task_id']! as String)!);
      } else if (row != null && _owns(row) && (!resume || pending)) {
        await reminders.wake(row['task_id']! as String);
      }
    } on PlatformException {
      _executorId = null;
    } on MissingPluginException {
      _executorId = null;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  bool _owns(MemoryRow task) => _executorId != null && task['executor_id'] == _executorId;

  void _resumeLookup(MemoryRow task) {
    final memory = _memory!;
    final host = ref.read(activeConnectionProvider).value?.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final key = ref.read(settingsProvider).apiKey;
    final factory = ref.read(companionLightClientProvider);
    final operation = task['cancel_requested'] == 1
        ? memory.lookups.stop(task, executorId: _executorId!, host: host, hostKey: hostKey)
        : memory.lookups.run(
            task,
            executorId: _executorId!,
            requestId: companionMemoryId,
            estimateTokens: estimateCompanionMemoryTokens,
            host: host,
            hostKey: hostKey,
            direct: CompanionLookupDirect(
              client: factory,
              apiKey: () => key,
              nowMilliseconds: memory.lookups.nowMilliseconds,
              estimateTokens: estimateCompanionMemoryTokens,
            ),
          );
    final drained = operation.then<void>((_) {});
    memory.retainReceipt(drained);
    unawaited(
      drained.catchError((Object _) {
        if (mounted) {
          showBriefNotice(context, context.l10n.companionLookupSaveFailed);
        }
      }),
    );
  }

  Future<void> _cancelLookup(MemoryRow task) async {
    if (_busy || !_owns(task)) {
      return;
    }
    final memory = _memory!;
    final host = ref.read(activeConnectionProvider).value?.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final raw = context.l10n.companionLookupCancelSource(task['lookup_place_name']! as String);
    setState(() => _busy = true);
    try {
      final clock = await ref.read(companionRemindersProvider).clock();
      if (!mounted) {
        return;
      }
      final source = memory.store.submitMessage(
        id: companionMemoryId(),
        sessionId: task['source_session_id']! as String,
        text: raw,
        saidAtUtc: clock.utcMs,
        offsetMinutes: clock.offsetSeconds ~/ 60,
        zoneId: clock.zoneId,
        offsetSeconds: clock.offsetSeconds,
      );
      final cancelled = memory.store.cancelLookup(
        taskId: task['task_id']! as String,
        expectedTaskRev: task['task_rev']! as int,
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
        itemNo: 0,
      );
      memory.changed();
      final operation = memory.lookups.stop(cancelled, executorId: _executorId!, host: host, hostKey: hostKey);
      memory.retainReceipt(operation);
      await operation;
    } on Object {
      if (mounted) {
        showBriefNotice(context, context.l10n.companionLookupSaveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _apply(
    MemoryRow task,
    CompanionReminderCommand command,
    String raw, {
    int? selectedOffsetSeconds,
  }) async {
    if (_busy || !_owns(task)) {
      return false;
    }
    final memory = _memory!;
    final reminders = ref.read(companionRemindersProvider);
    setState(() => _busy = true);
    try {
      final observed = await reminders.clock();
      final taskId = task['task_id']! as String;
      final old = _retry;
      final source = old != null && old.taskId == taskId && old.raw == raw
          ? old.source
          : memory.store.submitMessage(
              id: companionMemoryId(),
              sessionId: task['source_session_id']! as String,
              text: raw,
              saidAtUtc: observed.utcMs,
              offsetMinutes: observed.offsetSeconds ~/ 60,
              zoneId: observed.zoneId,
              offsetSeconds: observed.offsetSeconds,
            );
      _retry = (taskId: taskId, raw: raw, source: source);
      final operation = reminders.submit(
        store: memory.store,
        source: source,
        part: (itemNo: 0, raw: raw, command: command),
        roomMode: task['room_mode']! as String,
        previous: task,
        selectedOffsetSeconds: selectedOffsetSeconds,
        isCurrent: () => mounted,
      );
      memory.retainReceipt(operation.then<void>((_) {}));
      await operation;
      _retry = null;
      memory.changed();
      return true;
    } on Object catch (error) {
      if (mounted) {
        showBriefNotice(context, companionReminderFailure(context.l10n, error));
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _edit(MemoryRow task) async {
    var text = task['reminder_text'] as String? ?? '';
    var when = '${task['local_date'] ?? ''} ${task['local_time'] ?? ''}'.trim();
    var zone = task['zone_id'] as String? ?? '';
    String? problem;
    var saving = false;
    await showAppDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: Text(dialog.l10n.companionReminderEdit),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: text,
                  onChanged: (value) => text = value,
                  decoration: InputDecoration(labelText: dialog.l10n.companionReminderText),
                ),
                TextFormField(
                  initialValue: when,
                  onChanged: (value) => when = value,
                  decoration: InputDecoration(
                    labelText: dialog.l10n.companionReminderWhen,
                    hintText: dialog.l10n.companionReminderWhenHint,
                    errorText: problem,
                  ),
                ),
                TextFormField(
                  initialValue: zone,
                  onChanged: (value) => zone = value,
                  decoration: InputDecoration(
                    labelText: dialog.l10n.companionReminderZone,
                    hintText: dialog.l10n.companionReminderZoneHint,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final expression = '$when ${zone.trim()}'.trim();
                      final raw = '$expression提醒我$text';
                      final parts = parseCompanionReminders(raw);
                      final parsed = parts.length == 1 ? parts.single.command : null;
                      if (parsed == null || parsed.operation != 'create') {
                        update(() => problem = dialog.l10n.companionReminderSyntax);
                        return;
                      }
                      update(() => saving = true);
                      final ok = await _apply(task, (
                        operation: 'amend',
                        text: text,
                        when: expression,
                        target: null,
                      ), raw);
                      if (!dialog.mounted) {
                        return;
                      }
                      if (ok) {
                        Navigator.pop(dialog);
                      } else {
                        update(() => saving = false);
                      }
                    },
              child: Text(dialog.l10n.commonSave),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseOccurrence(MemoryRow task) async {
    final reminders = ref.read(companionRemindersProvider);
    try {
      final result = await reminders.resolve(
        task['local_date']! as String,
        task['local_time']! as String,
        task['zone_id']! as String,
      );
      if (!mounted) {
        return;
      }
      final moments = result['moments']! as List;
      if (result['kind'] != 'overlap') {
        showBriefNotice(context, context.l10n.companionReminderInvalidTime);
        return;
      }
      final selected = await showAppDialog<int>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: Text(dialog.l10n.companionReminderOverlap),
          children: [
            for (var index = 0; index < moments.length; index++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, (moments[index] as Map)['offsetSeconds']! as int),
                child: Text(index == 0 ? dialog.l10n.companionReminderFirst : dialog.l10n.companionReminderSecond),
              ),
          ],
        ),
      );
      if (!mounted || selected == null) {
        return;
      }
      final expression = '${task['local_date']} ${task['local_time']} ${task['zone_id']}';
      final first = selected == (moments.first as Map)['offsetSeconds'];
      final choice = first ? context.l10n.companionReminderFirst : context.l10n.companionReminderSecond;
      final raw = '$expression提醒我${task['reminder_text']}，$choice';
      await _apply(
        task,
        (operation: 'amend', text: null, when: expression, target: null),
        raw,
        selectedOffsetSeconds: selected,
      );
    } on Object {
      if (mounted) {
        showBriefNotice(context, context.l10n.companionReminderInvalidTime);
      }
    }
  }

  Widget _detail(MemoryRow task) {
    if (task['kind'] == 'host.notes_to_todo') {
      return _notesDetail(_memory!.store.hostTask(task['task_id']! as String)!);
    }
    if (task['kind'] == 'public.lookup') {
      return _lookupDetail(_memory!.store.lookupTask(task['task_id']! as String)!);
    }
    final l10n = context.l10n;
    final receipts = _memory!.store.taskReceipts(task['task_id']! as String);
    final notification = receipts.where((receipt) => receipt['step_key'] == 'notification').toList();
    // Another revision's returned/opened receipt cannot settle this claim.
    // Active observations use their own attempt ID but the same revision/tag.
    final unknown = notification.any(
      (claim) =>
          claim['event_kind'] == 'claimed' &&
          !notification.any(
            (receipt) =>
                receipt['task_rev'] == claim['task_rev'] &&
                ((receipt['attempt_id'] == claim['attempt_id'] &&
                        (receipt['event_kind'] == 'opened' ||
                            (receipt['event_kind'] == 'returned' && receipt['outcome'] == 'succeeded') ||
                            (receipt['event_kind'] == 'skipped' && receipt['outcome'] == 'not_performed'))) ||
                    (receipt['event_kind'] == 'active_observed' &&
                        claim['effect_id'] != null &&
                        receipt['effect_id'] == claim['effect_id'])),
          ),
    );
    final reason = task['wait_reason'];
    final settings = switch (reason) {
      'exact_alarm_unavailable' => 'exact',
      'notifications_disabled' || 'notification_channel_disabled' || 'notification_group_disabled' => 'notifications',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task['reminder_text'] as String? ?? l10n.companionReminderTextMissing,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (task['local_date'] != null || task['local_time'] != null)
            Text('${task['local_date'] ?? ''} ${task['local_time'] ?? ''} ${task['zone_id'] ?? ''}'.trim()),
          const SizedBox(height: 8),
          Text(companionReminderLine(l10n, task, executorId: _executorId)),
          if (!_owns(task) && task['state'] == 'done') Text(l10n.companionReminderPastRegistration),
          if (widget.openedRevision != null && widget.openedRevision != task['task_rev'])
            Text(l10n.companionTaskChanged),
          if (unknown) Text(l10n.companionReminderUnknownNotification),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_owns(task) && task['cancel_requested'] == 0) ...[
                OutlinedButton(onPressed: _busy ? null : () => _edit(task), child: Text(l10n.companionReminderEdit)),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _apply(task, (
                          operation: 'cancel',
                          text: null,
                          when: null,
                          target: null,
                        ), l10n.companionReminderCancelSource(task['reminder_text'] as String? ?? '')),
                  child: Text(l10n.companionReminderCancel),
                ),
              ],
              if (_owns(task) && task['cancel_requested'] == 0 && reason == 'time_overlap')
                FilledButton(
                  onPressed: _busy ? null : () => _chooseOccurrence(task),
                  child: Text(l10n.companionReminderOverlap),
                ),
              if (_owns(task) && settings != null)
                FilledButton(
                  onPressed: _busy ? null : () => ref.read(companionRemindersProvider).openSettings(settings),
                  child: Text(l10n.companionReminderSettings),
                ),
            ],
          ),
        ],
      ),
    );
  }

  bool _notesHostHere(MemoryRow task) =>
      ref.read(activeConnectionProvider).value?.client != null &&
      task['host_key'] == companionHostKey(ref.read(activeHostProvider));

  Future<bool> _applyNotes(
    MemoryRow task, {
    bool cancel = false,
    String? date,
    String? name,
    String deadlineText = '',
    bool clearDeadline = false,
    String? afterExit,
    bool? allowQueue,
    bool chooseSource = false,
    bool chooseOutput = false,
  }) async {
    if (_busy) {
      return false;
    }
    final memory = _memory!;
    final clock = ref.read(companionRemindersProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final l10n = context.l10n;
    final agreement = task['agreement']! as Map;
    final args = Map<String, Object?>.from(agreement['args']! as Map);
    final id = task['task_id']! as String;
    final revision = task['task_rev']! as int;
    final raw = cancel
        ? l10n.companionNotesCancelSource(args['outputName']! as String)
        : l10n.companionNotesAmendSource(
            date!,
            name!,
            clearDeadline
                ? l10n.companionNotesClearDeadline
                : deadlineText.isEmpty
                ? l10n.companionNotesKeepDeadline
                : deadlineText,
            afterExit == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue,
            allowQueue == true ? l10n.companionNotesAllowQueue : l10n.companionNotesNoQueue,
            chooseSource ? l10n.companionNotesChooseDirectory : l10n.companionNotesKeepDirectory,
            chooseOutput ? l10n.companionNotesChooseOutput : l10n.companionNotesKeepOutput,
          );
    bool current() => mounted && memory.store.hostTask(id)?['task_rev'] == revision;
    bool selectedHost() =>
        current() &&
        task['host_key'] == hostKey &&
        hostKey == companionHostKey(ref.read(activeHostProvider)) &&
        identical(client, ref.read(activeConnectionProvider).value?.client);
    setState(() => _busy = true);
    try {
      final retry = _retry;
      MemoryRow source;
      if (retry != null && retry.taskId == id && retry.raw == raw) {
        source = retry.source;
      } else {
        final observed = await clock.clock();
        if (!current()) {
          return false;
        }
        source = memory.store.submitMessage(
          id: companionMemoryId(),
          sessionId: task['source_session_id']! as String,
          text: raw,
          saidAtUtc: observed.utcMs,
          offsetMinutes: observed.offsetSeconds ~/ 60,
          zoneId: observed.zoneId,
          offsetSeconds: observed.offsetSeconds,
        );
        _retry = (taskId: id, raw: raw, source: source);
      }
      final accepted = memory.store.taskForCommand(source['id']! as String, 0);
      MemoryRow updated;
      if (accepted != null) {
        updated = memory.store.hostTask(accepted['task_id']! as String)!;
      } else if (cancel) {
        updated = memory.store.cancelNotesTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: source['id']! as String,
          expectedSourceRev: source['source_rev']! as int,
          itemNo: 0,
        );
      } else {
        int? deadline = clearDeadline ? null : agreement['deadlineAtMs'] as int?;
        if (!clearDeadline && deadlineText.isNotEmpty) {
          final match = RegExp(r'^(\d{4}-\d{2}-\d{2}) ((?:[01]\d|2[0-3]):[0-5]\d)$').firstMatch(deadlineText);
          if (match == null) {
            throw const FormatException('A complete local deadline is required');
          }
          final resolved = await clock.resolve(match.group(1)!, match.group(2)!, args['timeZone']! as String);
          if (resolved['kind'] != 'unique') {
            throw const FormatException('The local deadline is not unique');
          }
          deadline = ((resolved['moments']! as List).single as Map)['epochMs']! as int;
        }
        if (!current()) {
          return false;
        }
        final labels = Map<String, Object?>.from(task['directory_labels']! as Map);
        if (chooseSource || chooseOutput) {
          if (client == null || !selectedHost()) {
            throw const DshRemoteException('companion/task-original-host', 'Connect the original task Host');
          }
          final capability = await client.readCompanionTasksCapability();
          if (!selectedHost() ||
              capability == null ||
              !capability.notes ||
              (task['host_store_id'] != null && capability.hostStoreId != task['host_store_id'])) {
            throw const DshRemoteException('companion/task-store-mismatch', 'The original task store is unavailable');
          }
          for (final output in [false, true]) {
            if (!(output ? chooseOutput : chooseSource)) {
              continue;
            }
            if (!mounted) return false;
            final path = await showDirectoryPicker(
              context,
              title: output ? l10n.companionNotesChooseOutput : l10n.companionNotesChooseDirectory,
            );
            if (!selectedHost() || path == null) {
              return false;
            }
            final bound = await client.bindCompanionNotesDirectory(capability, path);
            if (!selectedHost()) {
              return false;
            }
            args[output ? 'outputDirRef' : 'folderRef'] = bound['folderRef'];
            labels[output ? 'output' : 'source'] = bound['displayPath'];
          }
        }
        if (!current()) {
          return false;
        }
        args['localDate'] = date;
        args['outputName'] = name;
        updated = memory.store.amendNotesTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: source['id']! as String,
          expectedSourceRev: source['source_rev']! as int,
          itemNo: 0,
          agreement: {'args': args, 'deadlineAtMs': deadline, 'afterExit': afterExit, 'allowQueue': allowQueue},
          directoryLabels: labels,
        );
      }
      memory.changed();
      if (client != null && updated['host_key'] == hostKey) {
        await memory.hostTasks.run(
          updated,
          client: client,
          hostKey: hostKey,
          initialOpportunity: true,
          submitPending: true,
        );
      }
      _retry = null;
      return true;
    } on Object {
      if (mounted) {
        showBriefNotice(context, l10n.companionNotesSaveFailed);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _editNotes(MemoryRow task) async {
    final agreement = task['agreement']! as Map;
    final args = agreement['args']! as Map;
    var date = args['localDate']! as String;
    var name = args['outputName']! as String;
    var afterExit = agreement['afterExit']! as String;
    var allowQueue = agreement['allowQueue']! as bool;
    var deadline = '';
    var clearDeadline = false;
    var chooseSource = false;
    var chooseOutput = false;
    var saving = false;
    await showAppDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: Text(dialog.l10n.companionNotesEdit),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: date,
                  onChanged: (value) => date = value,
                  decoration: InputDecoration(labelText: dialog.l10n.companionNotesDate, hintText: 'YYYY-MM-DD'),
                ),
                TextFormField(
                  initialValue: name,
                  onChanged: (value) => name = value,
                  decoration: InputDecoration(labelText: dialog.l10n.companionNotesFilename),
                ),
                TextFormField(
                  onChanged: (value) => deadline = value,
                  decoration: InputDecoration(
                    labelText: dialog.l10n.companionNotesDeadlineField,
                    hintText: 'YYYY-MM-DD HH:mm (${args['timeZone']})',
                  ),
                ),
                CheckboxListTile(
                  value: clearDeadline,
                  onChanged: (value) => update(() => clearDeadline = value!),
                  title: Text(dialog.l10n.companionNotesClearDeadline),
                ),
                DropdownButton<String>(
                  value: afterExit,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(value: 'continue', child: Text(dialog.l10n.companionNotesContinue)),
                    DropdownMenuItem(value: 'pause', child: Text(dialog.l10n.companionNotesPause)),
                  ],
                  onChanged: (value) => update(() => afterExit = value!),
                ),
                CheckboxListTile(
                  value: allowQueue,
                  onChanged: (value) => update(() => allowQueue = value!),
                  title: Text(dialog.l10n.companionNotesAllowQueue),
                ),
                CheckboxListTile(
                  value: chooseSource,
                  onChanged: (value) => update(() => chooseSource = value!),
                  title: Text(dialog.l10n.companionNotesChooseDirectory),
                ),
                CheckboxListTile(
                  value: chooseOutput,
                  onChanged: (value) => update(() => chooseOutput = value!),
                  title: Text(dialog.l10n.companionNotesChooseOutput),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      update(() => saving = true);
                      final ok = await _applyNotes(
                        task,
                        date: date.trim(),
                        name: name.trim(),
                        afterExit: afterExit,
                        allowQueue: allowQueue,
                        deadlineText: deadline.trim(),
                        clearDeadline: clearDeadline,
                        chooseSource: chooseSource,
                        chooseOutput: chooseOutput,
                      );
                      if (!dialog.mounted) {
                        return;
                      }
                      if (ok) {
                        Navigator.pop(dialog);
                      } else {
                        update(() => saving = false);
                      }
                    },
              child: Text(dialog.l10n.commonSave),
            ),
          ],
        ),
      ),
    );
  }

  bool _notesApprovalCurrent(MemoryRow task, Map captured) {
    if (!mounted ||
        !_notesHostHere(task) ||
        !identical(_notesVerifiedClient, ref.read(activeConnectionProvider).value?.client) ||
        task['host_store_id'] != _notesVerifiedStore) {
      return false;
    }
    final current = _memory!.store.hostTask(task['task_id']! as String);
    final snapshot = current?['snapshot'] as Map?;
    final approval = snapshot?['approval'];
    return current?['task_rev'] == task['task_rev'] &&
        current?['cancel_requested'] == 0 &&
        current?['state'] == 'waiting' &&
        approval is Map &&
        const [
          'taskRev',
          'stepKey',
          'agentId',
          'approvalId',
          'eventId',
          'callId',
        ].every((key) => approval[key] == captured[key]) &&
        approval['taskRev'] == current?['task_rev'];
  }

  Future<void> _openNotesArtifact(MemoryRow task, Map artifact) async {
    if (_busy || !_notesHostHere(task)) {
      return;
    }
    final client = ref.read(activeConnectionProvider).value!.client;
    setState(() => _busy = true);
    try {
      final result = await client.readCompanionHostArtifact(
        hostStoreId: task['host_store_id']! as String,
        taskId: task['task_id']! as String,
        hostExecutionId: task['host_execution_id']! as String,
        artifactId: artifact['artifactId']! as String,
      );
      if (!mounted) {
        return;
      }
      await showAppDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(artifact['relativePath']! as String),
          content: SingleChildScrollView(
            child: SelectableText(
              result['status'] == 'available'
                  ? result['content']! as String
                  : switch (result['status']) {
                      'missing' => dialog.l10n.companionNotesFileMissing,
                      'changed' => dialog.l10n.companionNotesFileChanged,
                      _ => dialog.l10n.companionNotesFileUnknown,
                    },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.l10n.commonClose))],
        ),
      );
    } on Object {
      if (mounted) {
        showBriefNotice(context, context.l10n.companionNotesFileUnknown);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _notesDetail(MemoryRow task) {
    final l10n = context.l10n;
    final agreement = task['agreement']! as Map;
    final args = agreement['args']! as Map;
    final labels = task['directory_labels']! as Map;
    final snapshot = task['snapshot'] as Map?;
    final approval = snapshot?['approval'];
    final artifacts = (snapshot?['artifacts'] as List?) ?? const [];
    final pendingCommand =
        task['host_store_id'] != null &&
        const ['amend', 'cancel'].contains(task['operation']) &&
        (snapshot == null || (snapshot['taskRev']! as int) < (task['task_rev']! as int));
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(args['outputName']! as String, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('${args['localDate']} ${args['timeZone']}'),
          Text(l10n.companionNotesModifiedDay),
          if (labels['source'] case final String path) Text(l10n.companionNotesSourceDirectory(path)),
          if (labels['output'] case final String path) Text(l10n.companionNotesOutputDirectory(path)),
          Text(agreement['afterExit'] == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue),
          if (agreement['allowQueue'] == true) Text(l10n.companionNotesAllowQueue),
          if (agreement['deadlineAtMs'] case final int at) Text(l10n.companionNotesDue(_moment(l10n, at))),
          const SizedBox(height: 8),
          Text(companionNotesLine(l10n, task)),
          if (!_notesHostHere(task)) Text(l10n.companionNotesOriginalHost),
          if (approval is Map && _notesApprovalCurrent(task, approval)) ...[
            Text(l10n.companionNotesApproval),
            CompanionAsk(
              key: ValueKey('notes-${task['task_id']}-${approval['eventId']}'),
              sessionId: approval['agentId']! as String,
              approvalTarget: (
                eventId: approval['eventId']! as String,
                callId: approval['callId'] as String?,
                isCurrent: () => _notesApprovalCurrent(task, approval),
              ),
            ),
          ],
          for (final value in artifacts) ...[
            const SizedBox(height: 16),
            Text((value as Map)['relativePath']! as String),
            OutlinedButton(
              onPressed: _busy || !_notesHostHere(task) ? null : () => _openNotesArtifact(task, value),
              child: Text(l10n.companionNotesOpenFile),
            ),
          ],
          if (_notesHostHere(task) && pendingCommand)
            OutlinedButton(
              onPressed: _busy ? null : () => _retryNotes(task, pendingCommand: true),
              child: Text(
                task['operation'] == 'cancel' ? l10n.companionNotesResendCancel : l10n.companionNotesResendAmend,
              ),
            )
          else if (_notesHostHere(task) &&
              task['snapshot'] == null &&
              task['host_store_id'] != null &&
              task['state'] == 'unknown')
            OutlinedButton(
              onPressed: _busy ? null : () => _retryNotes(task, missing: true),
              child: Text(l10n.companionNotesResendOriginal),
            ),
          if (task['cancel_requested'] == 0 && !const ['done', 'partial', 'cancelled'].contains(task['state']))
            Wrap(
              spacing: 8,
              children: [
                if (!pendingCommand &&
                    _notesHostHere(task) &&
                    approval == null &&
                    task['wait_reason'] != 'foreground_control_unavailable' &&
                    (task['state'] == 'waiting' || task['state'] == 'queued'))
                  FilledButton(
                    onPressed: _busy ? null : () => _retryNotes(task),
                    child: Text(task['state'] == 'queued' ? l10n.companionNotesSubmitSaved : l10n.companionNotesRetry),
                  ),
                OutlinedButton(onPressed: _busy ? null : () => _editNotes(task), child: Text(l10n.companionNotesEdit)),
                OutlinedButton(
                  onPressed: _busy ? null : () => _applyNotes(task, cancel: true),
                  child: Text(l10n.companionNotesCancel),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _retryNotes(MemoryRow task, {bool missing = false, bool pendingCommand = false}) async {
    if (_busy || !_notesHostHere(task)) {
      return;
    }
    final client = ref.read(activeConnectionProvider).value!.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final unsent = _memory!.store.hostTaskCommands(task['task_id']! as String).last['possible_sent_at_ms'] == null;
    setState(() => _busy = true);
    try {
      await _memory!.hostTasks.run(
        task,
        client: client,
        hostKey: hostKey,
        submitPending: !missing && !pendingCommand && unsent,
        initialOpportunity: !missing && !pendingCommand && unsent,
        retryWaiting: !missing && !pendingCommand && !unsent,
        replayMissing: missing,
        resendPendingCommand: pendingCommand,
      );
    } on Object {
      if (mounted) {
        showBriefNotice(context, context.l10n.companionNotesSaveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _lookupDetail(MemoryRow task) {
    final l10n = context.l10n;
    final attempts = _memory!.store.lookupAttempts(task['task_id']! as String);
    final sources = <String, MemoryRow>{};
    for (final attempt in attempts) {
      for (final value in attempt['sourceMetadata']! as List) {
        final source = Map<String, Object?>.from(value as Map);
        final url = source['url']! as String;
        if (companionLookupUrl(url) && (source['kind'] == 'fetch' || !sources.containsKey(url))) {
          sources[url] = source;
        }
      }
    }
    final result = task['result'];
    final evidence = result is Map && result['evidence'] is List ? result['evidence'] as List : const [];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task['lookup_question']! as String, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('${task['local_date']} ${task['zone_id']}'),
          const SizedBox(height: 8),
          Text(companionLookupLine(l10n, task, executorId: _executorId)),
          if (!_owns(task) && result is Map && result['conclusion'] is String) Text(result['conclusion']! as String),
          if (sources.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(l10n.companionLookupSources, style: Theme.of(context).textTheme.titleMedium),
            for (final source in sources.values) ...[
              const SizedBox(height: 12),
              Text(source['title'] as String? ?? l10n.companionLookupNoTitle),
              TextButton(
                onPressed: () => unawaited(
                  launchUrl(
                    Uri.parse(source['url']! as String),
                    mode: LaunchMode.externalApplication,
                  ).catchError((_) => false),
                ),
                child: Text(source['url']! as String),
              ),
              Text(l10n.companionLookupObservedAt(_moment(l10n, source['observedAtMs']! as int))),
              if (source['kind'] == 'search') Text(l10n.companionLookupSearchOnly),
              for (final proof in evidence)
                if ((proof as Map)['url'] == source['url']) Text(proof['quote']! as String),
            ],
          ],
          const SizedBox(height: 16),
          if (_owns(task) &&
              task['cancel_requested'] == 0 &&
              const ['queued', 'running', 'unknown'].contains(task['state']))
            OutlinedButton(
              onPressed: _busy ? null : () => _cancelLookup(task),
              child: Text(l10n.companionLookupCancel),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final memory = _memory;
    final task = memory == null || widget.taskId == null ? null : memory.store.task(widget.taskId!);
    final rows = memory == null || widget.sourceSessionId == null
        ? <MemoryRow>[]
        : memory.store.tasks(sourceSessionId: widget.sourceSessionId);
    return AppPage.list(
      title: l10n.companionTasksTitle,
      actions: [
        IconButton(
          tooltip: l10n.companionReminderCheck,
          icon: const Icon(AppIcons.refresh),
          onPressed: memory == null || _busy ? null : _refresh,
        ),
      ],
      children: [
        if (_loadFailed)
          EmptyView(icon: AppIcons.reminder, title: l10n.companionMemoryLoadFailed)
        else if (memory == null)
          const Center(child: CircularProgressIndicator())
        else if (widget.taskId != null)
          if (task == null) EmptyView(icon: AppIcons.reminder, title: l10n.companionTaskMissing) else _detail(task)
        else if (rows.isEmpty)
          EmptyView(icon: AppIcons.reminder, title: l10n.companionTasksEmpty)
        else
          SheetGroup(
            children: [
              for (final row in rows)
                SettingsTile(
                  icon: row['kind'] == 'host.notes_to_todo'
                      ? AppIcons.document
                      : row['kind'] == 'public.lookup'
                      ? AppIcons.search
                      : AppIcons.reminder,
                  title: row['kind'] == 'public.lookup'
                      ? row['lookup_question']! as String
                      : row['kind'] == 'host.notes_to_todo'
                      ? l10n.companionNotesTitle
                      : row['reminder_text'] as String? ?? l10n.companionReminderTextMissing,
                  subtitle: row['kind'] == 'public.lookup'
                      ? companionLookupLine(l10n, row, executorId: _executorId)
                      : row['kind'] == 'host.notes_to_todo'
                      ? companionNotesLine(l10n, row)
                      : companionReminderLine(l10n, row, executorId: _executorId),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CompanionTasksPage(memory: memory, taskId: row['task_id']! as String),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
