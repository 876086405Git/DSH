import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../companion/companion_memory.dart';
import '../../companion/companion_reminder.dart';
import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'companion_memory_page.dart' show companionMemoryId;

String companionReminderFailure(L10n l10n, Object error) {
  if (error is PlatformException && error.code == 'reminder_executor_changed') {
    return l10n.companionReminderNotHere;
  }
  if (error is MissingPluginException || error is PlatformException) {
    return l10n.companionReminderPlatformUnavailable;
  }
  return error is DshRemoteException && error.code.endsWith('conflict')
      ? l10n.companionMemoryConflict : l10n.companionReminderSaveFailed;
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
      final memory = widget.memory ?? await ref.read(
        companionMemoryOwnerProvider('${(await getApplicationSupportDirectory()).path}/companion').future,
      );
      if (!mounted) {
        return;
      }
      _memory = memory;
      memory.addListener(_changed);
      try {
        _executorId = await ref.read(companionRemindersProvider).executorId();
      } on PlatformException {
        // Keep the saved agreement readable without claiming it is scheduled here.
      } on MissingPluginException {
        // A platform without this executor can still show the original record.
      }
      if (mounted) {
        setState(() {});
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
      _executorId = await reminders.executorId();
      if (!mounted) {
        return;
      }
      final row = widget.taskId == null ? null : memory.store.task(widget.taskId!);
      final pending = row != null && (row['state'] == 'waiting' || row['state'] == 'unknown');
      if (row != null && _owns(row) && (!resume || pending)) {
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
              id: companionMemoryId(), sessionId: task['source_session_id']! as String, text: raw,
              saidAtUtc: observed.utcMs, offsetMinutes: observed.offsetSeconds ~/ 60,
              zoneId: observed.zoneId, offsetSeconds: observed.offsetSeconds,
            );
      _retry = (taskId: taskId, raw: raw, source: source);
      final operation = reminders.submit(
        store: memory.store, source: source, part: (itemNo: 0, raw: raw, command: command),
        roomMode: task['room_mode']! as String, previous: task, selectedOffsetSeconds: selectedOffsetSeconds,
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
      builder: (dialog) => StatefulBuilder(builder: (dialog, update) => AlertDialog(
        title: Text(dialog.l10n.companionReminderEdit),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(initialValue: text, onChanged: (value) => text = value,
              decoration: InputDecoration(labelText: dialog.l10n.companionReminderText)),
          TextFormField(initialValue: when, onChanged: (value) => when = value,
              decoration: InputDecoration(labelText: dialog.l10n.companionReminderWhen,
                  hintText: dialog.l10n.companionReminderWhenHint, errorText: problem)),
          TextFormField(initialValue: zone, onChanged: (value) => zone = value,
              decoration: InputDecoration(labelText: dialog.l10n.companionReminderZone,
                  hintText: dialog.l10n.companionReminderZoneHint)),
        ])),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
          FilledButton(onPressed: saving ? null : () async {
            final expression = '$when ${zone.trim()}'.trim();
            final raw = '$expression提醒我$text';
            final parts = parseCompanionReminders(raw);
            final parsed = parts.length == 1 ? parts.single.command : null;
            if (parsed == null || parsed.operation != 'create') {
              update(() => problem = dialog.l10n.companionReminderSyntax);
              return;
            }
            update(() => saving = true);
            final ok = await _apply(task, (operation: 'amend', text: text, when: expression, target: null), raw);
            if (!dialog.mounted) {
              return;
            }
            if (ok) {
              Navigator.pop(dialog);
            } else {
              update(() => saving = false);
            }
          }, child: Text(dialog.l10n.commonSave)),
        ],
      )),
    );
  }

  Future<void> _chooseOccurrence(MemoryRow task) async {
    final reminders = ref.read(companionRemindersProvider);
    try {
      final result = await reminders.resolve(task['local_date']! as String, task['local_time']! as String, task['zone_id']! as String);
      if (!mounted) {
        return;
      }
      final moments = result['moments']! as List;
      if (result['kind'] != 'overlap') {
        showBriefNotice(context, context.l10n.companionReminderInvalidTime);
        return;
      }
      final selected = await showAppDialog<int>(context: context, builder: (dialog) => SimpleDialog(
        title: Text(dialog.l10n.companionReminderOverlap),
        children: [for (var index = 0; index < moments.length; index++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, (moments[index] as Map)['offsetSeconds']! as int),
            child: Text(index == 0 ? dialog.l10n.companionReminderFirst : dialog.l10n.companionReminderSecond),
          ),
        ],
      ));
      if (!mounted || selected == null) {
        return;
      }
      final expression = '${task['local_date']} ${task['local_time']} ${task['zone_id']}';
      final first = selected == (moments.first as Map)['offsetSeconds'];
      final choice = first ? context.l10n.companionReminderFirst : context.l10n.companionReminderSecond;
      final raw = '$expression提醒我${task['reminder_text']}，$choice';
      await _apply(task, (operation: 'amend', text: null, when: expression, target: null), raw, selectedOffsetSeconds: selected);
    } on Object {
      if (mounted) {
        showBriefNotice(context, context.l10n.companionReminderInvalidTime);
      }
    }
  }

  Widget _detail(MemoryRow task) {
    final l10n = context.l10n;
    final receipts = _memory!.store.taskReceipts(task['task_id']! as String);
    final notification = receipts.where((receipt) => receipt['step_key'] == 'notification').toList();
    final opened = notification.any((receipt) => receipt['event_kind'] == 'opened');
    final submitted = notification.any((receipt) => receipt['event_kind'] == 'returned' && receipt['outcome'] == 'succeeded');
    // Another revision's returned/opened receipt cannot settle this claim.
    // Active observations use their own attempt ID but the same revision/tag.
    final unknown = notification.any((claim) => claim['event_kind'] == 'claimed' &&
      !notification.any((receipt) => receipt['task_rev'] == claim['task_rev'] && (
        (receipt['attempt_id'] == claim['attempt_id'] && (
          receipt['event_kind'] == 'opened' ||
          (receipt['event_kind'] == 'returned' && receipt['outcome'] == 'succeeded') ||
          (receipt['event_kind'] == 'skipped' && receipt['outcome'] == 'not_performed')
        )) ||
        (receipt['event_kind'] == 'active_observed' && claim['effect_id'] != null &&
          receipt['effect_id'] == claim['effect_id'])
      )));
    final reason = task['wait_reason'];
    final settings = switch (reason) {
      'exact_alarm_unavailable' => 'exact',
      'notifications_disabled' || 'notification_channel_disabled' || 'notification_group_disabled' => 'notifications',
      _ => null,
    };
    return Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(task['reminder_text'] as String? ?? l10n.companionReminderTextMissing, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (task['local_date'] != null || task['local_time'] != null)
        Text('${task['local_date'] ?? ''} ${task['local_time'] ?? ''} ${task['zone_id'] ?? ''}'.trim()),
      const SizedBox(height: 8),
      Text(companionReminderLine(l10n, task, executorId: _executorId)),
      if (!_owns(task) && task['state'] == 'done') Text(l10n.companionReminderPastRegistration),
      if (widget.openedRevision != null && widget.openedRevision != task['task_rev'])
        Text(l10n.companionTaskChanged),
      if (opened) Text(l10n.companionReminderOpened),
      if (submitted) Text(l10n.companionReminderSubmittedNotification),
      if (unknown) Text(l10n.companionReminderUnknownNotification),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (_owns(task) && task['cancel_requested'] == 0) ...[
          OutlinedButton(onPressed: _busy ? null : () => _edit(task), child: Text(l10n.companionReminderEdit)),
          OutlinedButton(onPressed: _busy ? null : () => _apply(task,
            (operation: 'cancel', text: null, when: null, target: null),
            l10n.companionReminderCancelSource(task['reminder_text'] as String? ?? ''),
          ), child: Text(l10n.companionReminderCancel)),
        ],
        if (_owns(task) && task['cancel_requested'] == 0 && reason == 'time_overlap')
          FilledButton(onPressed: _busy ? null : () => _chooseOccurrence(task), child: Text(l10n.companionReminderOverlap)),
        if (_owns(task) && settings != null)
          FilledButton(onPressed: _busy ? null : () => ref.read(companionRemindersProvider).openSettings(settings),
              child: Text(l10n.companionReminderSettings)),
      ]),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final memory = _memory;
    final task = memory == null || widget.taskId == null ? null : memory.store.task(widget.taskId!);
    final rows = memory == null || widget.sourceSessionId == null
        ? <MemoryRow>[] : memory.store.tasks(sourceSessionId: widget.sourceSessionId);
    return AppPage.list(title: l10n.companionTasksTitle, actions: [
      IconButton(tooltip: l10n.companionReminderCheck, icon: const Icon(AppIcons.refresh),
          onPressed: memory == null || _busy ? null : _refresh),
    ], children: [
      if (_loadFailed) EmptyView(icon: AppIcons.reminder, title: l10n.companionMemoryLoadFailed)
      else if (memory == null) const Center(child: CircularProgressIndicator())
      else if (widget.taskId != null)
        if (task == null) EmptyView(icon: AppIcons.reminder, title: l10n.companionTaskMissing)
        else _detail(task)
      else if (rows.isEmpty) EmptyView(icon: AppIcons.reminder, title: l10n.companionTasksEmpty)
      else SheetGroup(children: [for (final row in rows)
        SettingsTile(icon: AppIcons.reminder, title: row['reminder_text'] as String? ?? l10n.companionReminderTextMissing,
          subtitle: companionReminderLine(l10n, row, executorId: _executorId), onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => CompanionTasksPage(memory: memory, taskId: row['task_id']! as String),
          )),
        ),
      ]),
    ]);
  }
}
