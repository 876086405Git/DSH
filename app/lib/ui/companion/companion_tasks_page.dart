import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../companion/companion_context.dart';
import '../../companion/companion_maps.dart';
import '../../companion/companion_host_tasks.dart';
import '../../companion/companion_memory.dart';
import '../../companion/companion_public_lookup.dart';
import '../../companion/companion_reminder.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../../notify/chat_alerts.dart' show companionHostKey;
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../../state/sheet_files.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../settings/settings_widgets.dart';
import '../files/table_view.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../workspace/directory_picker.dart';
import 'companion_ask.dart';
import 'companion_draft_inputs.dart';
import 'companion_receipt_inputs.dart';
import 'companion_memory_page.dart' show companionMemoryId;

/// 「11月21日 08:00」 in this phone's local time; the year only when it is not this one.
String _moment(L10n l10n, int epochMs) {
  final at = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final day = at.year == DateTime.now().year ? l10n.monthDay(at) : '${at.year}-${two(at.month)}-${two(at.day)}';
  return '$day ${two(at.hour)}:${two(at.minute)}';
}

Future<CompanionMapSpec?> chooseCompanionMapTarget(
  BuildContext context,
  CompanionMaps maps,
  String address, {
  required bool Function() isCurrent,
  required void Function(bool) choosing,
  void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute)? onRouteChanged,
}) async {
  final found = await maps.targets(address);
  if (!context.mounted || !isCurrent()) {
    throw const DshClosedException('map page changed while querying targets');
  }
  final defaultTarget = found['defaultTarget'];
  Map<Object?, Object?>? target = found['kind'] == 'known' && defaultTarget is Map<Object?, Object?>
      ? defaultTarget
      : null;
  var kind = target == null ? 'choice' : 'default';
  final targets = found['targets']! as List<Object?>;
  if (target == null && targets.isNotEmpty) {
    choosing(true);
    try {
      target = await showAppDialog<Map<String, Object?>>(
        context: context,
        onRouteChanged: onRouteChanged,
        builder: (dialog) => SimpleDialog(
          title: Text(dialog.l10n.companionMapChoose),
          children: [
            for (final value in targets)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, Map<String, Object?>.from(value)),
                child: Text((value as Map<Object?, Object?>)['label']! as String),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, <String, Object?>{'systemChoice': true}),
              child: Text(dialog.l10n.companionMapSystemChoice),
            ),
            SimpleDialogOption(onPressed: () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
          ],
        ),
      );
    } finally {
      choosing(false);
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('map page changed during target selection');
    }
    if (target == null) {
      return null;
    }
    if (target['systemChoice'] == true) {
      target = null;
    } else {
      kind = 'selected';
    }
  }
  // An empty package query is not proof that no map can handle geo. A fixed
  // native chooser handoff may still be attempted; its result stays waiting.
  return CompanionMapSpec(
    address: address,
    targetKind: kind,
    packageName: target?['packageName'] as String?,
    componentName: target?['componentName'] as String?,
    packageUid: target?['uid'] as int?,
    targetLabel: target?['label'] as String?,
  );
}

String companionMapLine(L10n l10n, MemoryRow task, {required String? executorId}) {
  if (task['state'] == 'cancelled') {
    return l10n.companionMapCancelled;
  }
  if (task['state'] == 'unknown') {
    return l10n.companionMapUnknown;
  }
  if (task['state'] == 'done') {
    return l10n.companionMapDone;
  }
  if (executorId == null) {
    return l10n.companionMapUnavailable;
  }
  if (task['executor_id'] != executorId) {
    return l10n.companionMapNotHere;
  }
  return switch (task['state']) {
    'failed' => l10n.companionMapFailed,
    'waiting' => task['wait_reason'] == 'map_target_choice' ? l10n.companionMapChoiceWaiting : l10n.companionMapWaiting,
    _ => l10n.companionMapQueued,
  };
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
  if (task['cancel_requested'] == 1) {
    return task['state'] == 'cancelled' ? l10n.companionReminderCancelled : l10n.companionReminderCancelUnknown;
  }
  if (task['state'] == 'unknown') {
    return l10n.companionReminderUnknown;
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
  if (task['kind'] == 'host.receipts_to_sheet') {
    if (task['cancel_requested'] == 1 && task['state'] != 'cancelled') {
      return l10n.companionReceiptCancelUnknown;
    }
    return switch (task['wait_reason']) {
      'foreground_control_unavailable' => l10n.companionNotesPauseUnavailable,
      'host_initial_opportunity_lost' => l10n.companionNotesOpportunityLost,
      'host_deadline' || 'deadline_expired' => l10n.companionReceiptDeadline,
      'original_create_missing' => l10n.companionReceiptOriginalPending,
      'receipt_fields_unavailable' => l10n.companionReceiptNoFields,
      'prior_revision_effect' => l10n.companionReceiptPriorResult,
      'output_exists' => l10n.companionReceiptOutputExists,
      _ => switch (task['state']) {
        'queued' => l10n.companionReceiptQueued,
        'running' => l10n.companionReceiptRunning,
        'done' => l10n.companionReceiptDone,
        'partial' => l10n.companionReceiptPartial,
        'cancelled' => l10n.companionReceiptCancelled,
        'failed' => l10n.companionReceiptFailed,
        'waiting' => l10n.companionReceiptWaiting,
        _ => l10n.companionReceiptUnknown,
      },
    };
  }
  if (task['kind'] == 'host.compare_drafts') {
    if (task['cancel_requested'] == 1 && task['state'] != 'cancelled') {
      return l10n.companionCompareCancelUnknown;
    }
    return switch (task['wait_reason']) {
      'foreground_control_unavailable' => l10n.companionNotesPauseUnavailable,
      'host_initial_opportunity_lost' => l10n.companionNotesOpportunityLost,
      'host_deadline' => l10n.companionCompareDeadline,
      'original_create_missing' => l10n.companionCompareOriginalPending,
      _ => switch (task['state']) {
        'queued' => l10n.companionCompareQueued,
        'running' => l10n.companionCompareRunning,
        'done' => l10n.companionCompareDone,
        'partial' => l10n.companionComparePartial,
        'cancelled' => l10n.companionCompareCancelled,
        'failed' => l10n.companionCompareFailed,
        'waiting' => l10n.companionCompareWaiting,
        _ => l10n.companionCompareUnknown,
      },
    };
  }
  if (task['kind'] == 'host.find_draft') {
    if (task['cancel_requested'] == 1 && task['state'] != 'cancelled') {
      return l10n.companionFindCancelUnknown;
    }
    return switch (task['wait_reason']) {
      'foreground_control_unavailable' => l10n.companionNotesPauseUnavailable,
      'host_initial_opportunity_lost' => l10n.companionNotesOpportunityLost,
      'host_deadline' => l10n.companionFindDeadline,
      'original_create_missing' => l10n.companionFindOriginalPending,
      _ => switch (task['state']) {
        'queued' => l10n.companionNotesQueued,
        'running' => l10n.companionNotesRunning,
        'done' => l10n.companionFindDone,
        'partial' => l10n.companionFindPartial,
        'cancelled' => l10n.companionFindCancelled,
        'failed' => l10n.companionFindFailed,
        'waiting' => l10n.companionFindWaiting,
        _ => l10n.companionFindUnknown,
      },
    };
  }
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
  const CompanionTasksPage({
    super.key,
    this.memory,
    this.sourceSessionId,
    this.taskId,
    this.openedRevision,
    this.freshNotes = const [],
  });

  final CompanionMemoryOwner? memory;
  final String? sourceSessionId;
  final String? taskId;
  final int? openedRevision;

  /// Only the just-submitted Page supplies these captures. Historical reads,
  /// normal task navigation and reconstruction never create this opportunity.
  final List<CompanionNotesForegroundCapture> freshNotes;

  @override
  ConsumerState<CompanionTasksPage> createState() => _CompanionTasksPageState();
}

class _CompanionTasksPageState extends ConsumerState<CompanionTasksPage> {
  CompanionMemoryOwner? _memory;
  String? _executorId;
  bool _busy = false;
  bool _loadFailed = false;
  static const _taskPageSize = 100;
  int _taskLimit = _taskPageSize;
  DshClient? _notesVerifiedClient;
  String? _notesVerifiedStore;
  CompanionTasksCapability? _notesForegroundCapability;
  CompanionNotesForeground? _foreground;
  ModalRoute<Object?>? _taskRoute;
  bool _taskTickerEnabled = true;
  bool _foregroundReadNeeded = false;
  int _nextFreshNote = 0;
  bool _freshNotesLive = true;
  String? _notesViewedId;
  ({CompanionNotesForeground owner, String eventId, ModalRoute<Object?> route})? _approvalRiskRoute;
  late final AppLifecycleListener _lifecycle;
  late final CompanionMapHandoff _mapHandoff;
  bool _mapRouteShown = true;
  String? _mapViewedId;
  ({String taskId, String raw, MemoryRow source})? _retry;

  @override
  void initState() {
    super.initState();
    _mapHandoff = CompanionMapHandoff(ref.read(companionMapsProvider));
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_refresh(resume: true)),
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          _mapHandoff.close();
          _closeForeground(retireFresh: true);
        }
      },
    );
    ref.listenManual(activeHostProvider, (_, _) => _foregroundConnectionChanged());
    ref.listenManual(
      activeConnectionProvider.select((value) => value.value?.client),
      (_, _) => _foregroundConnectionChanged(),
    );
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
        final task = widget.taskId == null ? null : memory.store.task(widget.taskId!);
        final rows = widget.taskId == null && widget.sourceSessionId != null
            ? memory.store.tasks(sourceSessionId: widget.sourceSessionId, limit: _taskLimit)
            : const <MemoryRow>[];
        final mapsOnly = rows.isNotEmpty && rows.every((row) => row['kind'] == 'phone.map_open');
        final hostsOnly =
            rows.isNotEmpty &&
            rows.every(
              (row) => const [
                'host.notes_to_todo',
                'host.find_draft',
                'host.compare_drafts',
                'host.receipts_to_sheet',
              ].contains(row['kind']),
            );
        if (task?['kind'] == 'phone.map_open' || mapsOnly) {
          _executorId = await ref.read(companionMapsProvider).executorId();
        } else if (!hostsOnly && (widget.taskId == null || memory.store.hostTask(widget.taskId!) == null)) {
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
          if (widget.freshNotes.isEmpty) {
            unawaited(_refresh());
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _startNextFreshNote();
              }
            });
          }
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
      final owned = _foreground;
      if (owned != null && !_foregroundCurrent(owned)) {
        _closeForeground(retireFresh: _taskRoute?.isCurrent != true || !_taskTickerEnabled);
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    _closeForeground(retireFresh: true);
    _mapHandoff.close();
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
      final selectedId = _notesViewedId ?? _mapViewedId ?? widget.taskId;
      final selected = selectedId == null ? null : memory.store.hostTask(selectedId);
      if (selected != null) {
        _notesVerifiedClient = null;
        _notesVerifiedStore = null;
        _notesForegroundCapability = null;
        final client = ref.read(activeConnectionProvider).value?.client;
        final hostKey = companionHostKey(ref.read(activeHostProvider));
        if (client != null && selected['host_key'] == hostKey) {
          try {
            final checked = await memory.hostTasks.run(selected, client: client, hostKey: hostKey);
            if (mounted &&
                identical(client, ref.read(activeConnectionProvider).value?.client) &&
                hostKey == companionHostKey(ref.read(activeHostProvider)) &&
                checked['observed_host_snapshot'] == true) {
              _notesVerifiedClient = client;
              _notesVerifiedStore = checked['host_store_id']! as String;
              _foregroundReadNeeded = false;
              if (checked['kind'] == 'host.notes_to_todo' &&
                  (checked['agreement']! as MemoryRow)['afterExit'] == 'pause') {
                final capability = await client.readCompanionTasksCapability();
                if (mounted &&
                    identical(client, ref.read(activeConnectionProvider).value?.client) &&
                    capability?.hostStoreId == checked['host_store_id']) {
                  _notesForegroundCapability = capability;
                }
              }
            }
          } on Object {
            if (mounted) {
              showBriefNotice(context, context.l10n.companionNotesSaveFailed);
            }
          }
        }
        return;
      }
      final rows = selectedId == null && widget.sourceSessionId != null
          ? memory.store.tasks(sourceSessionId: widget.sourceSessionId, limit: _taskLimit)
          : const <MemoryRow>[];
      if (rows.isNotEmpty &&
          rows.every(
            (row) => const [
              'host.notes_to_todo',
              'host.find_draft',
              'host.compare_drafts',
              'host.receipts_to_sheet',
            ].contains(row['kind']),
          )) {
        return;
      }
      if ((selectedId != null && memory.store.mapTask(selectedId) != null) ||
          (rows.isNotEmpty && rows.every((row) => row['kind'] == 'phone.map_open'))) {
        _executorId = await ref.read(companionMapsProvider).executorId();
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
        _startNextFreshNote();
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
    if (task['kind'] == 'phone.map_open') {
      return _mapDetail(_memory!.store.mapTask(task['task_id']! as String)!);
    }
    if (const [
      'host.notes_to_todo',
      'host.find_draft',
      'host.compare_drafts',
      'host.receipts_to_sheet',
    ].contains(task['kind'])) {
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

  bool get _mapHere =>
      mounted &&
      _mapRouteShown &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _applyMap(MemoryRow task, {bool cancel = false}) async {
    if (_busy || !_mapHere) {
      return;
    }
    final memory = _memory!;
    final id = task['task_id']! as String;
    var activeId = id;
    var revision = task['task_rev']! as int;
    if (cancel) {
      _mapHandoff.close();
    }
    final generation = _mapHandoff.generation;
    bool current() =>
        _mapHere && generation == _mapHandoff.generation && memory.store.mapTask(activeId)?['task_rev'] == revision;
    final l10n = context.l10n;
    final raw = cancel ? l10n.companionMapCancelSource : l10n.companionMapReopenSource;
    setState(() => _busy = true);
    try {
      final retry = _retry;
      MemoryRow source;
      if (retry != null && retry.taskId == id && retry.raw == raw) {
        source = retry.source;
      } else {
        final observed = await ref.read(companionRemindersProvider).clock();
        if (!current()) {
          return;
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
        updated = memory.store.mapTask(accepted['task_id']! as String)!;
      } else if (cancel) {
        updated = memory.store.cancelMapOpen(
          taskId: id,
          expectedTaskRev: revision,
          messageId: source['id']! as String,
          expectedSourceRev: source['source_rev']! as int,
          itemNo: 0,
        );
      } else {
        final executor = await ref.read(companionMapsProvider).executorId();
        if (!current()) {
          return;
        }
        _executorId = executor;
        updated = memory.store.reopenMapOpenFromMessage(
          oldTaskId: id,
          expectedTaskRev: revision,
          messageId: source['id']! as String,
          expectedSourceRev: source['source_rev']! as int,
          itemNo: 0,
          executorId: executor,
        );
      }
      memory.changed();
      activeId = updated['task_id']! as String;
      revision = updated['task_rev']! as int;
      setState(() => _mapViewedId = activeId);
      if (!cancel && accepted == null) {
        try {
          await _mapHandoff.execute(memory.store, updated, isCurrent: current);
        } on PlatformException {
          // The persisted claim determines whether this was not performed or
          // may already have happened. A channel error is not a new receipt.
        } on MissingPluginException {
          // Keep the accepted task readable; reopening a page never dispatches it.
        }
      }
      _retry = null;
    } on Object {
      if (mounted && _mapHere) {
        showBriefNotice(context, l10n.companionMapSaveFailed);
      }
    } finally {
      memory.changed();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _mapDetail(MemoryRow task) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task['address']! as String, style: Theme.of(context).textTheme.titleLarge),
          if (task['target_label'] case final String label) Text(l10n.companionMapTarget(label)),
          const SizedBox(height: 12),
          Text(companionMapLine(l10n, task, executorId: _executorId)),
          if (_executorId != null && task['executor_id'] != _executorId) Text(l10n.companionMapNotHere),
          OutlinedButton.icon(
            icon: const Icon(AppIcons.copy),
            label: Text(l10n.companionMapCopy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: task['address']! as String));
            },
          ),
          if (_executorId != null)
            FilledButton(
              onPressed: _busy ? null : () => _memory!.retainReceipt(_applyMap(task)),
              child: Text(l10n.companionMapReopen),
            ),
          if (task['cancel_requested'] == 0 && !const ['done', 'cancelled'].contains(task['state']))
            OutlinedButton(
              onPressed: _busy ? null : () => _memory!.retainReceipt(_applyMap(task, cancel: true)),
              child: Text(l10n.companionMapCancel),
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
    List<String>? extensions,
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
    final find = task['kind'] == 'host.find_draft';
    final id = task['task_id']! as String;
    final revision = task['task_rev']! as int;
    final deadlineWords = clearDeadline
        ? l10n.companionNotesClearDeadline
        : deadlineText.isEmpty
        ? l10n.companionNotesKeepDeadline
        : deadlineText;
    final exitWords = afterExit == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue;
    final queueWords = allowQueue == true ? l10n.companionNotesAllowQueue : l10n.companionNotesNoQueue;
    final raw = find
        ? cancel
              ? l10n.companionFindCancelSource
              : l10n.companionFindAmendSource(
                  date!,
                  extensions!.join('/'),
                  deadlineWords,
                  exitWords,
                  queueWords,
                  chooseSource ? l10n.companionFindChooseAgain : l10n.companionFindKeepDirectory,
                )
        : cancel
        ? l10n.companionNotesCancelSource(args['outputName']! as String)
        : l10n.companionNotesAmendSource(
            date!,
            name!,
            deadlineWords,
            exitWords,
            queueWords,
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
        updated = find
            ? memory.store.cancelFindDraftTask(
                taskId: id,
                expectedTaskRev: revision,
                messageId: source['id']! as String,
                expectedSourceRev: source['source_rev']! as int,
                itemNo: 0,
              )
            : memory.store.cancelNotesTask(
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
              (find ? !capability.findDraft || !capability.sourceRead : !capability.notes) ||
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
              title: find
                  ? l10n.companionFindChooseAgain
                  : output
                  ? l10n.companionNotesChooseOutput
                  : l10n.companionNotesChooseDirectory,
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
        if (find) {
          args['extensions'] = extensions;
        } else {
          args['outputName'] = name;
        }
        final changed = <String, Object?>{
          'args': args,
          'deadlineAtMs': deadline,
          'afterExit': afterExit,
          'allowQueue': allowQueue,
        };
        updated = find
            ? memory.store.amendFindDraftTask(
                taskId: id,
                expectedTaskRev: revision,
                messageId: source['id']! as String,
                expectedSourceRev: source['source_rev']! as int,
                itemNo: 0,
                agreement: changed,
                directoryLabels: labels,
              )
            : memory.store.amendNotesTask(
                taskId: id,
                expectedTaskRev: revision,
                messageId: source['id']! as String,
                expectedSourceRev: source['source_rev']! as int,
                itemNo: 0,
                agreement: changed,
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
        _startNextFreshNote();
      }
    }
  }

  Future<bool> _applyCompare(
    MemoryRow task, {
    bool cancel = false,
    String deadlineText = '',
    bool clearDeadline = false,
    String? afterExit,
    bool? allowQueue,
    bool chooseInputs = false,
    BuildContext? actionContext,
  }) async {
    if (_busy) {
      return false;
    }
    final memory = _memory!;
    final clock = ref.read(companionRemindersProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final l10n = context.l10n;
    final agreement = task['agreement']! as MemoryRow;
    final id = task['task_id']! as String;
    final revision = task['task_rev']! as int;
    final action = actionContext ?? context;
    final deadlineWords = clearDeadline
        ? l10n.companionNotesClearDeadline
        : deadlineText.isEmpty
        ? l10n.companionNotesKeepDeadline
        : deadlineText;
    final raw = cancel
        ? l10n.companionCompareCancelSource
        : l10n.companionCompareAmendSource(
            deadlineWords,
            afterExit == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue,
            allowQueue == true ? l10n.companionNotesAllowQueue : l10n.companionNotesNoQueue,
            chooseInputs ? l10n.companionCompareChooseAgain : l10n.companionCompareKeepInputs,
          );
    bool current() =>
        mounted &&
        action.mounted &&
        (ModalRoute.of(action)?.isCurrent ?? true) &&
        memory.store.hostTask(id)?['task_rev'] == revision;
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
        updated = memory.store.cancelCompareDraftTask(
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
          final zone = source['zone_id'];
          if (match == null || zone is! String) {
            throw const FormatException('A complete local deadline is required');
          }
          final resolved = await clock.resolve(match.group(1)!, match.group(2)!, zone);
          if (resolved['kind'] != 'unique') {
            throw const FormatException('The local deadline is not unique');
          }
          deadline = ((resolved['moments']! as List<Object?>).single! as Map<Object?, Object?>)['epochMs']! as int;
        }
        if (!current()) {
          return false;
        }
        var inputs = (task['directory_labels']! as MemoryRow)['inputs']! as MemoryRow;
        if (chooseInputs) {
          if (!selectedHost()) {
            throw const DshRemoteException('companion/task-original-host', 'Select the original task Host');
          }
          final capability = client == null ? null : await client.readCompanionTasksCapability();
          if (!selectedHost() ||
              (client != null &&
                  (capability == null ||
                      !capability.compareDrafts ||
                      capability.hostStoreId != task['host_store_id']))) {
            throw const DshRemoteException('companion/task-store-mismatch', 'The original task store is unavailable');
          }
          if (!action.mounted) {
            return false;
          }
          final selected = await chooseCompanionDraftInputs(
            action,
            store: memory.store,
            hostKey: hostKey,
            client: client,
            capability: capability,
            originalStoreId: task['host_store_id']! as String,
            isCurrent: selectedHost,
          );
          if (!selectedHost() || selected == null) {
            return false;
          }
          inputs = selected;
        }
        if (!current()) {
          return false;
        }
        updated = memory.store.amendCompareDraftTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: source['id']! as String,
          expectedSourceRev: source['source_rev']! as int,
          itemNo: 0,
          inputs: inputs,
          agreement: {
            'args': {
              for (final side in ['a', 'b'])
                side: {
                  'sourceRef': (inputs[side]! as MemoryRow)['sourceRef'],
                  'version': (inputs[side]! as MemoryRow)['version'],
                },
              'maxHighlights': 3,
            },
            'deadlineAtMs': deadline,
            'afterExit': afterExit,
            'allowQueue': allowQueue,
          },
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
        showBriefNotice(context, l10n.companionCompareSaveFailed);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _applyReceipts(
    MemoryRow task, {
    bool cancel = false,
    String? name,
    String deadlineText = '',
    bool clearDeadline = false,
    String? afterExit,
    bool? allowQueue,
    bool chooseInputs = false,
    bool chooseOutput = false,
    BuildContext? actionContext,
  }) async {
    if (_busy) {
      return false;
    }
    final memory = _memory!;
    final clock = ref.read(companionRemindersProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final l10n = context.l10n;
    final agreement = task['agreement']! as MemoryRow;
    final id = task['task_id']! as String;
    final revision = task['task_rev']! as int;
    final action = actionContext ?? context;
    final deadlineWords = clearDeadline
        ? l10n.companionNotesClearDeadline
        : deadlineText.isEmpty
        ? l10n.companionNotesKeepDeadline
        : deadlineText;
    final raw = cancel
        ? l10n.companionReceiptCancelSource
        : l10n.companionReceiptAmendSource(
            name!,
            deadlineWords,
            afterExit == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue,
            allowQueue == true ? l10n.companionNotesAllowQueue : l10n.companionNotesNoQueue,
            chooseInputs ? l10n.companionReceiptChooseAgain : l10n.companionReceiptKeepInputs,
            chooseOutput ? l10n.companionNotesChooseOutput : l10n.companionReceiptKeepOutput,
          );
    bool current() =>
        mounted &&
        action.mounted &&
        (ModalRoute.of(action)?.isCurrent ?? true) &&
        memory.store.hostTask(id)?['task_rev'] == revision;
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
        updated = memory.store.cancelReceiptsTask(
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
          final zone = source['zone_id'];
          if (match == null || zone is! String) {
            throw const FormatException('A complete local deadline is required');
          }
          final resolved = await clock.resolve(match.group(1)!, match.group(2)!, zone);
          if (resolved['kind'] != 'unique') {
            throw const FormatException('The local deadline is not unique');
          }
          deadline = ((resolved['moments']! as List<Object?>).single! as Map<Object?, Object?>)['epochMs']! as int;
        }
        if (!current()) {
          return false;
        }
        final labels = task['directory_labels']! as MemoryRow;
        var inputs = (labels['inputs']! as List<Object?>).cast<MemoryRow>();
        var output = labels['outputDirectory']! as MemoryRow;
        if (chooseInputs || chooseOutput) {
          if (!selectedHost()) {
            throw const DshRemoteException('companion/task-original-host', 'Select the original task Host');
          }
          final capability = client == null ? null : await client.readCompanionTasksCapability();
          if (!selectedHost() ||
              (client != null &&
                  (capability == null ||
                      !capability.receiptsToSheet ||
                      capability.hostStoreId != task['host_store_id']))) {
            throw const DshRemoteException('companion/task-store-mismatch', 'The original task store is unavailable');
          }
          if (!action.mounted) {
            return false;
          }
          final selected = await chooseCompanionReceiptInputs(
            action,
            store: memory.store,
            hostKey: hostKey,
            client: client,
            capability: capability,
            originalStoreId: task['host_store_id']! as String,
            keptInputs: chooseInputs ? null : inputs,
            keptOutput: chooseOutput ? null : output,
            isCurrent: selectedHost,
          );
          if (!selectedHost() || selected == null) {
            return false;
          }
          inputs = selected.inputs;
          output = selected.outputDirectory;
        }
        if (!current()) {
          return false;
        }
        updated = memory.store.amendReceiptsTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: source['id']! as String,
          expectedSourceRev: source['source_rev']! as int,
          itemNo: 0,
          inputs: inputs,
          outputDirectory: output,
          agreement: {
            'args': {
              'inputs': [
                for (final input in inputs) {'sourceRef': input['sourceRef'], 'version': input['version']},
              ],
              'outputDirRef': output['folderRef'],
              'outputName': name,
              'writeMode': 'createNew',
            },
            'deadlineAtMs': deadline,
            'afterExit': afterExit,
            'allowQueue': allowQueue,
          },
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
        showBriefNotice(context, l10n.companionReceiptSaveFailed);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _editReceipts(MemoryRow task) async {
    final agreement = task['agreement']! as MemoryRow;
    var name = (agreement['args']! as MemoryRow)['outputName']! as String;
    var afterExit = agreement['afterExit']! as String;
    var allowQueue = agreement['allowQueue']! as bool;
    var deadline = '';
    var clearDeadline = false;
    var chooseInputs = false;
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
                  initialValue: name,
                  onChanged: (value) => name = value,
                  decoration: InputDecoration(labelText: dialog.l10n.companionReceiptOutputName),
                ),
                TextFormField(
                  onChanged: (value) => deadline = value,
                  decoration: InputDecoration(
                    labelText: dialog.l10n.companionNotesDeadlineField,
                    hintText: 'YYYY-MM-DD HH:mm',
                    helperText: dialog.l10n.companionCompareNewDeadline,
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
                  value: chooseInputs,
                  onChanged: (value) => update(() => chooseInputs = value!),
                  title: Text(dialog.l10n.companionReceiptChooseAgain),
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
                      final ok = await _applyReceipts(
                        task,
                        name: name,
                        deadlineText: deadline.trim(),
                        clearDeadline: clearDeadline,
                        afterExit: afterExit,
                        allowQueue: allowQueue,
                        chooseInputs: chooseInputs,
                        chooseOutput: chooseOutput,
                        actionContext: dialog,
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

  Future<void> _editCompare(MemoryRow task) async {
    final agreement = task['agreement']! as MemoryRow;
    var afterExit = agreement['afterExit']! as String;
    var allowQueue = agreement['allowQueue']! as bool;
    var deadline = '';
    var clearDeadline = false;
    var chooseInputs = false;
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
                  onChanged: (value) => deadline = value,
                  decoration: InputDecoration(
                    labelText: dialog.l10n.companionNotesDeadlineField,
                    hintText: 'YYYY-MM-DD HH:mm',
                    helperText: dialog.l10n.companionCompareNewDeadline,
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
                  value: chooseInputs,
                  onChanged: (value) => update(() => chooseInputs = value!),
                  title: Text(dialog.l10n.companionCompareChooseAgain),
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
                      final ok = await _applyCompare(
                        task,
                        deadlineText: deadline.trim(),
                        clearDeadline: clearDeadline,
                        afterExit: afterExit,
                        allowQueue: allowQueue,
                        chooseInputs: chooseInputs,
                        actionContext: dialog,
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

  Future<void> _editNotes(MemoryRow task) async {
    final agreement = task['agreement']! as Map;
    final args = agreement['args']! as Map;
    final find = task['kind'] == 'host.find_draft';
    var date = args['localDate']! as String;
    var name = args['outputName'] as String? ?? '';
    var formats = find ? (args['extensions']! as List<Object?>).join(',') : '';
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
                  decoration: InputDecoration(
                    labelText: find ? dialog.l10n.companionFindDate : dialog.l10n.companionNotesDate,
                    hintText: 'YYYY-MM-DD',
                  ),
                ),
                if (find)
                  DropdownButton<String>(
                    value: formats,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'md,txt', child: Text('Markdown / .txt')),
                      DropdownMenuItem(value: 'md', child: Text('Markdown')),
                      DropdownMenuItem(value: 'txt', child: Text('.txt')),
                    ],
                    onChanged: (value) => update(() => formats = value!),
                  )
                else
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
                  title: Text(find ? dialog.l10n.companionFindChooseAgain : dialog.l10n.companionNotesChooseDirectory),
                ),
                if (!find)
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
                        extensions: find ? formats.split(',') : null,
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
    if (task['kind'] == 'host.notes_to_todo' && (task['agreement']! as MemoryRow)['afterExit'] == 'pause') {
      final owned = _foreground;
      if (owned == null || !_foregroundCurrent(owned)) {
        return false;
      }
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

  void _foregroundConnectionChanged() {
    _closeForeground(retireFresh: true);
    _notesForegroundCapability = null;
    _notesVerifiedClient = null;
    _notesVerifiedStore = null;
    if (mounted) {
      setState(() {});
    }
  }

  void _closeForeground({bool retireFresh = false}) {
    if (retireFresh) {
      _freshNotesLive = false;
    }
    final owned = _foreground;
    if (owned != null && owned.active) {
      final current = _memory?.store.hostTask(owned.captured['task_id']! as String);
      _foregroundReadNeeded =
          current?['task_rev'] == owned.captured['task_rev'] &&
          !const ['done', 'partial', 'failed', 'cancelled'].contains(current?['state']);
      owned.close();
    }
    _approvalRiskRoute = null;
  }

  bool _foregroundCurrent(CompanionNotesForeground owned) {
    if (!mounted ||
        !identical(owned, _foreground) ||
        !owned.active ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !_taskTickerEnabled ||
        !identical(owned.client, ref.read(activeConnectionProvider).value?.client) ||
        owned.hostKey != companionHostKey(ref.read(activeHostProvider))) {
      return false;
    }
    final captured = owned.captured;
    final current = _memory!.store.hostTask(captured['task_id']! as String);
    if (current == null ||
        current['task_rev'] != captured['task_rev'] ||
        current['cancel_requested'] != 0 ||
        current['source_session_id'] != captured['source_session_id'] ||
        current['host_store_id'] != captured['host_store_id'] ||
        current['host_execution_id'] != captured['host_execution_id'] ||
        (current['agreement']! as MemoryRow)['afterExit'] != 'pause' ||
        const ['done', 'partial', 'failed', 'cancelled'].contains(current['state'])) {
      return false;
    }
    if (_taskRoute?.isCurrent == true) {
      return true;
    }
    final risk = _approvalRiskRoute;
    final approval = (current['snapshot'] as MemoryRow?)?['approval'] as MemoryRow?;
    return risk != null && identical(risk.owner, owned) && risk.route.isCurrent && approval?['eventId'] == risk.eventId;
  }

  void _observeApprovalRiskRoute(
    MemoryRow task,
    MemoryRow captured,
    ApprovalRequest request,
    ModalRoute<Object?> route,
  ) {
    final owned = _foreground;
    if (owned == null || request.eventId != captured['eventId'] || request.callId != captured['callId']) {
      return;
    }
    if (!identical(_approvalRiskRoute?.route, route)) {
      if (!_notesApprovalCurrent(task, captured) || _taskRoute?.isCurrent != true) {
        return;
      }
      _approvalRiskRoute = (owner: owned, eventId: request.eventId, route: route);
    }
    if (!_foregroundCurrent(owned)) {
      _closeForeground(retireFresh: _taskRoute?.isCurrent != true || !_taskTickerEnabled);
    } else if (route.navigator != null && !route.isActive && _taskRoute?.isCurrent == true) {
      _approvalRiskRoute = null;
    }
  }

  bool _canForeground(MemoryRow task) =>
      task['kind'] == 'host.notes_to_todo' &&
      (task['agreement']! as MemoryRow)['afterExit'] == 'pause' &&
      task['cancel_requested'] == 0 &&
      !const ['done', 'partial', 'failed', 'cancelled'].contains(task['state']) &&
      task['host_execution_id'] != null &&
      _notesForegroundCapability?.notesForeground == true &&
      _notesForegroundCapability?.hostStoreId == task['host_store_id'] &&
      identical(_notesVerifiedClient, ref.read(activeConnectionProvider).value?.client) &&
      _notesHostHere(task);

  bool _freshNoteCurrent(CompanionNotesForegroundCapture capture) {
    final task = capture.task;
    final current = _memory?.store.hostTask(task['task_id']! as String);
    final deadline = (task['agreement']! as MemoryRow)['deadlineAtMs'] as int?;
    return _freshNotesLive &&
        current != null &&
        task['kind'] == 'host.notes_to_todo' &&
        capture.capability.notesForeground &&
        capture.capability.hostStoreId == task['host_store_id'] &&
        identical(capture.client, ref.read(activeConnectionProvider).value?.client) &&
        task['host_key'] == companionHostKey(ref.read(activeHostProvider)) &&
        const [
          'task_rev',
          'host_store_id',
          'host_execution_id',
          'source_session_id',
        ].every((key) => current[key] == task[key]) &&
        current['cancel_requested'] == 0 &&
        (current['agreement']! as MemoryRow)['afterExit'] == 'pause' &&
        !const ['done', 'partial', 'failed', 'cancelled'].contains(current['state']) &&
        (deadline == null || DateTime.now().millisecondsSinceEpoch < deadline);
  }

  void _startNextFreshNote() {
    if (!_freshNotesLive ||
        _foreground != null ||
        _busy ||
        _memory == null ||
        _nextFreshNote >= widget.freshNotes.length) {
      return;
    }
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !_taskTickerEnabled ||
        _taskRoute?.isCurrent != true) {
      _freshNotesLive = false;
      return;
    }
    while (_nextFreshNote < widget.freshNotes.length) {
      final capture = widget.freshNotes[_nextFreshNote++];
      if (!_freshNoteCurrent(capture)) {
        continue;
      }
      setState(() {
        _notesViewedId = capture.task['task_id']! as String;
        _notesVerifiedClient = null;
        _notesVerifiedStore = null;
        _notesForegroundCapability = capture.capability;
      });
      _startForeground(capture.task, fresh: capture);
      return;
    }
  }

  void _startForeground(MemoryRow task, {CompanionNotesForegroundCapture? fresh}) {
    if (_busy ||
        _foreground != null ||
        (fresh == null ? !_canForeground(task) : !_freshNoteCurrent(fresh)) ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !_taskTickerEnabled ||
        _taskRoute?.isCurrent != true) {
      return;
    }
    final memory = _memory!;
    final client = ref.read(activeConnectionProvider).value!.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    late final CompanionNotesForeground owned;
    try {
      owned = memory.hostTasks.foreground(
        task,
        client: client,
        hostKey: hostKey,
        capability: fresh?.capability ?? _notesForegroundCapability!,
        isCurrent: () => _foregroundCurrent(owned),
        observed: (checked) {
          if (_foregroundCurrent(owned)) {
            _notesVerifiedClient = client;
            _notesVerifiedStore = checked['host_store_id']! as String;
            _foregroundReadNeeded = false;
          }
        },
      );
    } on DshException {
      showBriefNotice(context, context.l10n.companionNotesSaveFailed);
      return;
    }
    setState(() {
      _foreground = owned;
      _foregroundReadNeeded = false;
    });
    unawaited(
      owned.finished
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              _freshNotesLive = false;
              if (mounted && identical(_foreground, owned)) {
                final current = memory.store.hostTask(task['task_id']! as String);
                _foregroundReadNeeded =
                    current?['task_rev'] == task['task_rev'] &&
                    current?['state'] == 'unknown' &&
                    current?['wait_reason'] == 'host_receipt_unknown';
              }
            },
          )
          .whenComplete(() {
            if (mounted && identical(_foreground, owned)) {
              setState(() {
                _foreground = null;
                _approvalRiskRoute = null;
              });
              _startNextFreshNote();
            }
          }),
    );
  }

  Future<void> _openHostFile(MemoryRow task, Map<String, Object?> item, {int? sourceRevision}) async {
    if (_busy || !_notesHostHere(task)) {
      return;
    }
    final client = ref.read(activeConnectionProvider).value!.client;
    setState(() => _busy = true);
    try {
      final result = sourceRevision == null
          ? await client.readCompanionHostArtifact(
              hostStoreId: task['host_store_id']! as String,
              taskId: task['task_id']! as String,
              hostExecutionId: task['host_execution_id']! as String,
              artifactId: item['artifactId']! as String,
            )
          : await client.readCompanionHostSource(
              hostStoreId: task['host_store_id']! as String,
              taskId: task['task_id']! as String,
              hostExecutionId: task['host_execution_id']! as String,
              sourceRef: item['sourceRef']! as String,
            );
      if (sourceRevision != null &&
          (result['taskRev'] != sourceRevision ||
              result['version'] != item['version'] ||
              result['relativePath'] != item['relativePath'])) {
        throw const DshProtocolException('The source response does not match the original find result');
      }
      if (!mounted) {
        return;
      }
      await showAppDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(item['relativePath']! as String),
          content: SingleChildScrollView(
            child: SelectableText(
              result['status'] == 'available'
                  ? result['content']! as String
                  : sourceRevision != null
                  ? switch (result['status']) {
                      'missing' => dialog.l10n.companionFindSourceMissing,
                      'changed' => dialog.l10n.companionFindSourceChanged,
                      'not_readable' => dialog.l10n.companionFindSourceUnreadable,
                      _ => dialog.l10n.companionFindSourceUnknown,
                    }
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
        showBriefNotice(
          context,
          sourceRevision == null ? context.l10n.companionNotesFileUnknown : context.l10n.companionFindSourceUnknown,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _notesDetail(MemoryRow task) {
    if (task['kind'] == 'host.receipts_to_sheet') {
      return _receiptsDetail(task);
    }
    if (task['kind'] == 'host.compare_drafts') {
      return _compareDetail(task);
    }
    final l10n = context.l10n;
    final agreement = task['agreement']! as Map;
    final args = agreement['args']! as Map;
    final find = task['kind'] == 'host.find_draft';
    final labels = task['directory_labels']! as Map;
    final snapshot = task['snapshot'] as Map?;
    final approval = snapshot?['approval'];
    final artifacts = ((snapshot?['artifacts'] as List<Object?>?) ?? const []).cast<MemoryRow>();
    final steps = (snapshot?['steps'] as List<Object?>?) ?? const [];
    final pendingCommand =
        task['host_store_id'] != null &&
        const ['amend', 'cancel'].contains(task['operation']) &&
        (snapshot == null || (snapshot['taskRev']! as int) < (task['task_rev']! as int));
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            find ? l10n.companionFindTitle : args['outputName']! as String,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text('${args['localDate']} ${args['timeZone']}'),
          Text(
            find
                ? l10n.companionFindScope((args['extensions']! as List<Object?>).join('/'))
                : l10n.companionNotesModifiedDay,
          ),
          if (labels['source'] case final String path)
            Text(find ? l10n.companionFindSourceDirectory(path) : l10n.companionNotesSourceDirectory(path)),
          if (labels['output'] case final String path) Text(l10n.companionNotesOutputDirectory(path)),
          Text(agreement['afterExit'] == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue),
          if (agreement['allowQueue'] == true) Text(l10n.companionNotesAllowQueue),
          if (agreement['deadlineAtMs'] case final int at) Text(l10n.companionNotesDue(_moment(l10n, at))),
          const SizedBox(height: 8),
          Text(
            _foregroundReadNeeded && !find
                ? l10n.companionNotesForegroundUnknown
                : _canForeground(task) &&
                      const ['foreground_control_unavailable', 'foreground_required'].contains(task['wait_reason'])
                ? l10n.companionNotesForegroundReady
                : companionNotesLine(l10n, task),
          ),
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
              onApprovalRiskRouteChanged: !find && agreement['afterExit'] == 'pause'
                  ? (request, route) =>
                        _observeApprovalRiskRoute(task, Map<String, Object?>.from(approval), request, route)
                  : null,
            ),
          ],
          if (find)
            for (final value in steps.cast<Map<String, Object?>>())
              if (value['stepKey'] == 'readInputs')
                if ((value['result'] as MemoryRow?)?['completion'] case final MemoryRow report)
                  _findReport(task, value, report),
          for (final value in artifacts) ...[
            const SizedBox(height: 16),
            Text(value['relativePath']! as String),
            OutlinedButton(
              onPressed: _busy || !_notesHostHere(task) ? null : () => _openHostFile(task, value),
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
          if (task['cancel_requested'] == 0 &&
              task['state'] != 'cancelled' &&
              (find || !const ['done', 'partial'].contains(task['state'])))
            Wrap(
              spacing: 8,
              children: [
                if (!pendingCommand && _canForeground(task))
                  FilledButton(
                    onPressed: _busy || _foreground != null ? null : () => _startForeground(task),
                    child: Text(l10n.companionNotesForegroundStart),
                  ),
                if (!pendingCommand &&
                    (find || agreement['afterExit'] != 'pause' || task['state'] == 'queued') &&
                    _notesHostHere(task) &&
                    approval == null &&
                    task['wait_reason'] != 'foreground_control_unavailable' &&
                    (task['state'] == 'waiting' || task['state'] == 'queued'))
                  FilledButton(
                    onPressed: _busy ? null : () => _retryNotes(task),
                    child: Text(task['state'] == 'queued' ? l10n.companionNotesSubmitSaved : l10n.companionNotesRetry),
                  ),
                OutlinedButton(onPressed: _busy ? null : () => _editNotes(task), child: Text(l10n.companionNotesEdit)),
                if (!find || !const ['done', 'partial'].contains(task['state']))
                  OutlinedButton(
                    onPressed: _busy ? null : () => _applyNotes(task, cancel: true),
                    child: Text(find ? l10n.companionFindCancel : l10n.companionNotesCancel),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _openReceiptWorkbook(MemoryRow task, MemoryRow artifact) async {
    if (_busy || !_notesHostHere(task)) {
      return;
    }
    final client = ref.read(activeConnectionProvider).value!.client;
    final id = task['task_id']! as String;
    bool current() {
      if (!(ModalRoute.of(context)?.isCurrent ?? true) ||
          !_notesHostHere(task) ||
          !identical(client, ref.read(activeConnectionProvider).value?.client)) {
        return false;
      }
      final latest = _memory!.store.hostTask(id);
      final saved = (latest?['snapshot'] as MemoryRow?)?['artifacts'] as List<Object?>?;
      return latest?['host_store_id'] == task['host_store_id'] &&
          latest?['host_execution_id'] == task['host_execution_id'] &&
          saved != null &&
          saved.cast<MemoryRow>().any(
            (row) =>
                row['artifactId'] == artifact['artifactId'] &&
                row['sha256'] == artifact['sha256'] &&
                row['size'] == artifact['size'],
          );
    }

    setState(() => _busy = true);
    try {
      final bytes = await client.readCompanionHostArtifactBytes(
        hostStoreId: task['host_store_id']! as String,
        taskId: id,
        hostExecutionId: task['host_execution_id']! as String,
        artifact: artifact,
      );
      if (!mounted || !current()) {
        return;
      }
      final grids = await compute(parseXlsx, bytes);
      if (!mounted || !current()) {
        return;
      }
      if (grids.length != 1 || grids.single.truncated) {
        throw const SheetFormatException('The original receipt workbook could not be displayed completely');
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AppPage(
            title: artifact['relativePath']! as String,
            slivers: [SliverFillRemaining(hasScrollBody: true, child: SheetTable(grid: grids.single))],
          ),
        ),
      );
    } on Object {
      if (mounted && current()) {
        showBriefNotice(context, context.l10n.companionReceiptOpenFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _receiptsDetail(MemoryRow task) {
    final l10n = context.l10n;
    final agreement = task['agreement']! as MemoryRow;
    final args = agreement['args']! as MemoryRow;
    final labels = task['directory_labels']! as MemoryRow;
    final inputs = (labels['inputs']! as List<Object?>).cast<MemoryRow>();
    final snapshot = task['snapshot'] as MemoryRow?;
    final approval = snapshot?['approval'];
    final artifacts = ((snapshot?['artifacts'] as List<Object?>?) ?? const <Object?>[]).cast<MemoryRow>();
    final reports = <int, MemoryRow>{};
    for (final step in ((snapshot?['steps'] as List<Object?>?) ?? const <Object?>[]).cast<MemoryRow>()) {
      final result = step['result'] as MemoryRow?;
      final completion = result?['completion'] as MemoryRow?;
      final report = completion?['report'];
      if (completion != null && report is MemoryRow) {
        final revision = step['taskRev']! as int;
        // Prefer the report attached to a published workbook. Otherwise show
        // the last actual observation, retaining old attempts in storage.
        if (reports[revision]?['artifactId'] == null || completion['artifactId'] is String) {
          reports[revision] = {'report': report, 'artifactId': completion['artifactId']};
        }
      }
    }
    final pendingCommand =
        const ['amend', 'cancel'].contains(task['operation']) &&
        (snapshot == null || (snapshot['taskRev']! as int) < (task['task_rev']! as int));
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(args['outputName']! as String, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          for (final (index, input) in inputs.indexed)
            Text('${l10n.companionReceiptInput('${index + 1}')}：${input['displayName']}'),
          Text(l10n.companionNotesOutputDirectory((labels['outputDirectory']! as MemoryRow)['displayPath']! as String)),
          Text(agreement['afterExit'] == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue),
          if (agreement['allowQueue'] == true) Text(l10n.companionNotesAllowQueue),
          if (agreement['deadlineAtMs'] case final int at) Text(l10n.companionNotesDue(_moment(l10n, at))),
          const SizedBox(height: 8),
          Text(companionNotesLine(l10n, task)),
          if (!_notesHostHere(task)) Text(l10n.companionReceiptOriginalHost),
          if (approval is MemoryRow && _notesApprovalCurrent(task, approval)) ...[
            Text(l10n.companionNotesApproval),
            CompanionAsk(
              key: ValueKey('receipt-${task['task_id']}-${approval['eventId']}'),
              sessionId: approval['agentId']! as String,
              approvalTarget: (
                eventId: approval['eventId']! as String,
                callId: approval['callId'] as String?,
                isCurrent: () => _notesApprovalCurrent(task, approval),
              ),
            ),
          ],
          for (final entry in reports.entries) ...[
            const SizedBox(height: 16),
            Text(
              entry.key == task['task_rev'] ? l10n.companionReceiptReport : l10n.companionReceiptPreviousReport,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _receiptReport(entry.value['report']! as MemoryRow),
          ],
          for (final artifact in artifacts)
            OutlinedButton(
              onPressed: _busy || !_notesHostHere(task) ? null : () => _openReceiptWorkbook(task, artifact),
              child: Text(l10n.companionReceiptOpenWorkbook(artifact['relativePath']! as String)),
            ),
          if (_notesHostHere(task) && pendingCommand)
            OutlinedButton(
              onPressed: _busy ? null : () => _retryNotes(task, pendingCommand: true),
              child: Text(
                task['operation'] == 'cancel' ? l10n.companionNotesResendCancel : l10n.companionNotesResendAmend,
              ),
            )
          else if (_notesHostHere(task) && snapshot == null && task['state'] == 'unknown')
            OutlinedButton(
              onPressed: _busy ? null : () => _retryNotes(task, missing: true),
              child: Text(l10n.companionNotesResendOriginal),
            ),
          if (task['cancel_requested'] == 0 && task['state'] != 'cancelled')
            Wrap(
              spacing: 8,
              children: [
                if (!pendingCommand &&
                    _notesHostHere(task) &&
                    approval == null &&
                    task['wait_reason'] != 'foreground_control_unavailable' &&
                    const ['queued', 'waiting'].contains(task['state']))
                  FilledButton(
                    onPressed: _busy ? null : () => _retryNotes(task),
                    child: Text(task['state'] == 'queued' ? l10n.companionNotesSubmitSaved : l10n.companionNotesRetry),
                  ),
                if (artifacts.isEmpty)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _editReceipts(task),
                    child: Text(l10n.companionNotesEdit),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _applyReceipts(task, cancel: true),
                  child: Text(l10n.commonCancel),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _receiptReport(MemoryRow report) {
    final l10n = context.l10n;
    final sources = (report['sources']! as List<Object?>).cast<MemoryRow>();
    final rows = (report['rows']! as List<Object?>).cast<MemoryRow>();
    final coverage = report['coverage']! as MemoryRow;
    final gaps = (coverage['gaps']! as List<Object?>).cast<MemoryRow>();
    final labels = {
      'date': l10n.companionReceiptDate,
      'item': l10n.companionReceiptItem,
      'amount': l10n.companionReceiptAmount,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.companionReceiptCoverage('${coverage['rowsWithVerifiedFields']}')),
        for (final (index, source) in sources.indexed) ...[
          const SizedBox(height: 12),
          Text(source['displayName']! as String, style: Theme.of(context).textTheme.titleSmall),
          if (source['readComplete'] != true) Text(l10n.companionReceiptUnread),
          if (source['parseComplete'] != true) Text(l10n.companionReceiptParseFailed),
          if (source['textLayerOnly'] == true) Text(l10n.companionReceiptImageScope),
          if (source['reason'] == 'pdf_empty_text') Text(l10n.companionReceiptNoText),
          if (gaps.any((gap) => gap['sourceRef'] == source['sourceRef'] && gap['field'] == 'verification'))
            Text(l10n.companionReceiptChanged),
          for (final key in labels.keys) ...[
            SelectableText(
              '${labels[key]}：${(rows[index][key]! as MemoryRow)['state'] == 'verified' ? (rows[index][key]! as MemoryRow)['value'] : l10n.companionReceiptUnverified(_receiptReason((rows[index][key]! as MemoryRow)['reason']! as String))}',
            ),
            if ((rows[index][key]! as MemoryRow)['evidence'] case final MemoryRow evidence) ...[
              Text(
                evidence['page'] == null
                    ? l10n.companionReceiptSourcePosition('${evidence['lineStart']}', '${evidence['lineEnd']}')
                    : l10n.companionReceiptPdfPosition(
                        '${evidence['page']}',
                        '${evidence['lineStart']}',
                        '${evidence['lineEnd']}',
                      ),
              ),
              SelectableText(evidence['quote']! as String),
            ],
          ],
        ],
      ],
    );
  }

  String _receiptReason(String reason) => switch (reason) {
    'pdf_empty_text' => context.l10n.companionReceiptNoText,
    'input_not_read' ||
    'input_unavailable' ||
    'task_owner_stopping' ||
    'deadline_expired' => context.l10n.companionReceiptUnread,
    'input_changed' ||
    'input_changed_at_publish' ||
    'input_unavailable_at_publish' => context.l10n.companionReceiptChanged,
    'pdf_password_required' => context.l10n.companionReceiptPassword,
    'pdf_unavailable' || 'pdf_runtime_unavailable' => context.l10n.companionReceiptPdfUnavailable,
    'input_too_large' ||
    'pdf_input_limit' ||
    'pdf_page_limit' ||
    'pdf_text_limit' ||
    'pdf_item_limit' => context.l10n.companionReceiptLimit,
    'input_not_utf8' || 'pdf_invalid' || 'pdf_parse_failed' => context.l10n.companionReceiptParseFailed,
    'date_not_verified' || 'date_ambiguous_or_unsupported' => context.l10n.companionReceiptDateUnknown,
    'item_not_verified' || 'item_ambiguous_or_unsupported' => context.l10n.companionReceiptItemUnknown,
    'amount_not_verified' || 'amount_ambiguous_or_unsupported' => context.l10n.companionReceiptAmountUnknown,
    _ => context.l10n.companionReceiptFieldUnknown,
  };

  Widget _compareDetail(MemoryRow task) {
    final l10n = context.l10n;
    final agreement = task['agreement']! as MemoryRow;
    final inputs = (task['directory_labels']! as MemoryRow)['inputs']! as MemoryRow;
    final snapshot = task['snapshot'] as MemoryRow?;
    final approval = snapshot?['approval'];
    final steps = (snapshot?['steps'] as List<Object?>?) ?? const <Object?>[];
    final reports = <int, (MemoryRow, MemoryRow)>{};
    for (final step in steps.cast<MemoryRow>()) {
      if (step['stepKey'] != 'report') {
        continue;
      }
      if ((step['result'] as MemoryRow?)?['completion'] case final MemoryRow report) {
        final revision = step['taskRev']! as int;
        final previous = reports[revision];
        // Keep every attempt in storage, but show the published report for a
        // revision, or its latest unfinished observation while none is published.
        if (previous == null || previous.$2['published'] != true) {
          reports[revision] = (step, report);
        }
      }
    }
    final pendingCommand =
        const ['amend', 'cancel'].contains(task['operation']) &&
        (snapshot == null || (snapshot['taskRev']! as int) < (task['task_rev']! as int));
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.companionCompareTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          for (final side in ['a', 'b'])
            Text(
              '${side == 'a' ? l10n.companionCompareA : l10n.companionCompareB}：${(inputs[side]! as MemoryRow)['displayName']}',
            ),
          Text(agreement['afterExit'] == 'pause' ? l10n.companionNotesPause : l10n.companionNotesContinue),
          if (agreement['allowQueue'] == true) Text(l10n.companionNotesAllowQueue),
          if (agreement['deadlineAtMs'] case final int at) Text(l10n.companionNotesDue(_moment(l10n, at))),
          const SizedBox(height: 8),
          Text(companionNotesLine(l10n, task)),
          if (!_notesHostHere(task)) Text(l10n.companionCompareOriginalHost),
          if (approval is MemoryRow && _notesApprovalCurrent(task, approval)) ...[
            Text(l10n.companionNotesApproval),
            CompanionAsk(
              key: ValueKey('compare-${task['task_id']}-${approval['eventId']}'),
              sessionId: approval['agentId']! as String,
              approvalTarget: (
                eventId: approval['eventId']! as String,
                callId: approval['callId'] as String?,
                isCurrent: () => _notesApprovalCurrent(task, approval),
              ),
            ),
          ],
          for (final (step, report) in reports.values) _compareReport(task, step, report),
          if (_notesHostHere(task) && pendingCommand)
            OutlinedButton(
              onPressed: _busy ? null : () => _retryNotes(task, pendingCommand: true),
              child: Text(
                task['operation'] == 'cancel' ? l10n.companionNotesResendCancel : l10n.companionNotesResendAmend,
              ),
            )
          else if (_notesHostHere(task) && snapshot == null && task['state'] == 'unknown')
            OutlinedButton(
              onPressed: _busy ? null : () => _retryNotes(task, missing: true),
              child: Text(l10n.companionNotesResendOriginal),
            ),
          if (task['cancel_requested'] == 0 && task['state'] != 'cancelled')
            Wrap(
              spacing: 8,
              children: [
                if (!pendingCommand &&
                    _notesHostHere(task) &&
                    approval == null &&
                    task['wait_reason'] != 'foreground_control_unavailable' &&
                    const ['queued', 'waiting'].contains(task['state']))
                  FilledButton(
                    onPressed: _busy ? null : () => _retryNotes(task),
                    child: Text(task['state'] == 'queued' ? l10n.companionNotesSubmitSaved : l10n.companionNotesRetry),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _editCompare(task),
                  child: Text(l10n.companionNotesEdit),
                ),
                if (!const ['done', 'partial'].contains(task['state']))
                  OutlinedButton(
                    onPressed: _busy ? null : () => _applyCompare(task, cancel: true),
                    child: Text(l10n.companionCompareCancel),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _compareReport(MemoryRow task, MemoryRow step, MemoryRow report) {
    final l10n = context.l10n;
    final coverage = report['coverage']! as MemoryRow;
    final differences = (report['differences']! as List<Object?>).cast<MemoryRow>().toList();
    final suggestions = report['suggestions']! as MemoryRow;
    final practices = (suggestions['items']! as List<Object?>).cast<MemoryRow>().toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          report['published'] != true
              ? l10n.companionCompareUnfinishedReport
              : step['taskRev'] == task['task_rev']
              ? l10n.companionCompareReport
              : l10n.companionComparePreviousReport,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final source in (report['sources']! as List<Object?>).cast<MemoryRow>()) ...[
          Text('${source['side'] == 'a' ? l10n.companionCompareA : l10n.companionCompareB}：${source['displayName']}'),
          if (source['readComplete'] != true)
            Text(l10n.companionCompareUnread)
          else if (source['verifiedAtPublish'] != true)
            Text(l10n.companionCompareChanged),
        ],
        if (coverage['comparisonComplete'] != true || (coverage['gaps']! as List<Object?>).isNotEmpty)
          Text(l10n.companionCompareIncomplete),
        if (report['identical'] == true) Text(l10n.companionCompareIdentical),
        if (coverage['totalChangeGroups'] case final int total)
          if (total > 0) Text(l10n.companionCompareCoverage('$total', '${differences.length}')),
        if (report['selection'] == 'source_order' && differences.isNotEmpty) Text(l10n.companionCompareSourceOrder),
        for (var index = 0; index < differences.length; index++) ...[
          const SizedBox(height: 12),
          Text(l10n.companionCompareDifference('${index + 1}'), style: Theme.of(context).textTheme.titleSmall),
          for (final side in ['a', 'b']) ...[
            Text(
              '${side == 'a' ? l10n.companionCompareA : l10n.companionCompareB} · '
              '${_comparePosition(differences[index][side]! as MemoryRow)}',
            ),
            if (((differences[index][side]! as MemoryRow)['excerpts']! as List<Object?>).isEmpty)
              Text(l10n.companionCompareNoExcerpt),
            for (final quote
                in ((differences[index][side]! as MemoryRow)['excerpts']! as List<Object?>).cast<MemoryRow>())
              SelectableText(quote['text']! as String),
          ],
        ],
        if (practices.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(l10n.companionCompareSuggestions, style: Theme.of(context).textTheme.titleMedium),
          for (final item in practices)
            Text(
              l10n.companionComparePractice(
                '${differences.indexWhere((value) => value['id'] == item['differenceId']) + 1}',
                item['practice']! as String,
              ),
            ),
        ] else if (suggestions['status'] == 'unknown')
          Text(l10n.companionCompareSuggestionsUnknown)
        else if (suggestions['status'] == 'unavailable')
          Text(l10n.companionCompareSuggestionsMissing),
      ],
    );
  }

  String _comparePosition(MemoryRow side) {
    final l10n = context.l10n;
    if (side['paragraphs'] case final MemoryRow paragraphs) {
      final from = paragraphs['from'];
      final to = paragraphs['to'];
      return l10n.companionCompareParagraph(from == to ? '$from' : '$from–$to');
    }
    if (side['boundary'] case final MemoryRow boundary) {
      final before = boundary['beforeParagraph'];
      final after = boundary['afterParagraph'];
      if (before != null && after != null) {
        return l10n.companionCompareBetween('$before', '$after');
      }
      if (before != null) {
        return l10n.companionCompareAfter('$before');
      }
      if (after != null) {
        return l10n.companionCompareBefore('$after');
      }
    }
    final start = side['lineStart']! as int;
    final end = side['lineEnd']! as int;
    return l10n.companionCompareLines(end > start + 1 ? '$start–${end - 1}' : '$start');
  }

  Widget _findReport(MemoryRow task, MemoryRow step, MemoryRow report) {
    final l10n = context.l10n;
    final scope = report['scope']! as MemoryRow;
    final coverage = report['coverage']! as MemoryRow;
    final matches = report['matches']! as List<Object?>;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          step['taskRev'] == task['task_rev'] ? l10n.companionFindReport : l10n.companionFindPreviousReport,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text('${scope['displayPath']} · ${scope['localDate']} ${scope['timeZone']}'),
        Text(
          l10n.companionFindCoverage(
            '${coverage['entriesChecked']}',
            '${coverage['supportedFilesChecked']}',
            coverage['candidateLimitReached'] == true
                ? '≥${coverage['matchingCandidates']}'
                : '${coverage['matchingCandidates']}',
          ),
        ),
        Text(
          coverage['enumerationComplete'] == true
              ? l10n.companionFindEnumerationComplete
              : l10n.companionFindEnumerationPartial,
        ),
        if (coverage['entryLimitReached'] == true) Text(l10n.companionFindEntryLimit),
        if (coverage['candidateLimitReached'] == true) Text(l10n.companionFindCandidateLimit),
        if (matches.isEmpty && coverage['enumerationComplete'] == true && (coverage['gaps']! as List<Object?>).isEmpty)
          Text(l10n.companionFindEmpty),
        for (final gap in (coverage['gaps']! as List<Object?>).cast<MemoryRow>())
          Text(
            gap['relativePath'] == null
                ? l10n.companionFindEnumerationPartial
                : l10n.companionFindGap(gap['relativePath']! as String),
          ),
        for (final match in matches.cast<Map<String, Object?>>()) ...[
          const SizedBox(height: 12),
          Text(match['relativePath']! as String, style: Theme.of(context).textTheme.titleSmall),
          Text(l10n.companionFindModified(_findModified(match, scope['timeZone']! as String))),
          Text(match['openable'] == true ? l10n.companionFindWasOpenable : l10n.companionFindWasUnreadable),
          OutlinedButton(
            onPressed: _busy || !_notesHostHere(task)
                ? null
                : () => _openHostFile(task, match, sourceRevision: step['taskRev']! as int),
            child: Text(l10n.companionFindOpenSource),
          ),
        ],
        if (!_notesHostHere(task)) Text(l10n.companionFindSourceOffline),
      ],
    );
  }

  String _findModified(MemoryRow match, String zone) {
    final offset = match['modifiedOffsetSeconds']! as int;
    final local = DateTime.fromMillisecondsSinceEpoch((match['modifiedAtMs']! as int) + offset * 1000, isUtc: true);
    final seconds = offset.abs();
    String two(int value) => value.toString().padLeft(2, '0');
    final suffix =
        '${offset < 0 ? '-' : '+'}${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}'
        '${seconds % 60 == 0 ? '' : ':${two(seconds % 60)}'}';
    return '${local.toIso8601String().replaceFirst('Z', '')} $zone (UTC$suffix)';
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
    _taskRoute = ModalRoute.of<Object?>(context);
    _taskTickerEnabled = TickerMode.valuesOf(context).enabled;
    final foreground = _foreground;
    if (foreground != null && !_foregroundCurrent(foreground)) {
      _closeForeground(retireFresh: _taskRoute?.isCurrent != true || !_taskTickerEnabled);
    }
    final shown = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
    if (!shown && (foreground == null || !_foregroundCurrent(foreground))) {
      _freshNotesLive = false;
    }
    if (_mapRouteShown && !shown) {
      _mapHandoff.close();
    }
    _mapRouteShown = shown;
    final memory = _memory;
    final selectedId = _notesViewedId ?? _mapViewedId ?? widget.taskId;
    final task = memory == null || selectedId == null ? null : memory.store.task(selectedId);
    final rows = memory == null || widget.sourceSessionId == null
        ? <MemoryRow>[]
        : memory.store.tasks(sourceSessionId: widget.sourceSessionId, limit: _taskLimit + 1);
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
        else if (selectedId != null)
          if (task == null) EmptyView(icon: AppIcons.reminder, title: l10n.companionTaskMissing) else _detail(task)
        else if (rows.isEmpty)
          EmptyView(icon: AppIcons.reminder, title: l10n.companionTasksEmpty)
        else
          SheetGroup(
            children: [
              for (final row in rows.take(_taskLimit))
                SettingsTile(
                  icon: row['kind'] == 'phone.map_open'
                      ? AppIcons.plan
                      : const [
                          'host.notes_to_todo',
                          'host.compare_drafts',
                          'host.receipts_to_sheet',
                        ].contains(row['kind'])
                      ? AppIcons.document
                      : row['kind'] == 'host.find_draft'
                      ? AppIcons.search
                      : row['kind'] == 'public.lookup'
                      ? AppIcons.search
                      : AppIcons.reminder,
                  title: row['kind'] == 'phone.map_open'
                      ? memory.store.mapTask(row['task_id']! as String)!['address']! as String
                      : row['kind'] == 'public.lookup'
                      ? row['lookup_question']! as String
                      : row['kind'] == 'host.notes_to_todo'
                      ? l10n.companionNotesTitle
                      : row['kind'] == 'host.find_draft'
                      ? l10n.companionFindTitle
                      : row['kind'] == 'host.compare_drafts'
                      ? l10n.companionCompareTitle
                      : row['kind'] == 'host.receipts_to_sheet'
                      ? l10n.companionReceiptTitle
                      : row['reminder_text'] as String? ?? l10n.companionReminderTextMissing,
                  subtitle: row['kind'] == 'phone.map_open'
                      ? companionMapLine(l10n, row, executorId: _executorId)
                      : row['kind'] == 'public.lookup'
                      ? companionLookupLine(l10n, row, executorId: _executorId)
                      : const [
                          'host.notes_to_todo',
                          'host.find_draft',
                          'host.compare_drafts',
                          'host.receipts_to_sheet',
                        ].contains(row['kind'])
                      ? companionNotesLine(l10n, row)
                      : companionReminderLine(l10n, row, executorId: _executorId),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CompanionTasksPage(memory: memory, taskId: row['task_id']! as String),
                    ),
                  ),
                ),
              if (rows.length > _taskLimit)
                Center(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() => _taskLimit += _taskPageSize);
                            unawaited(_refresh());
                          },
                    child: Text(l10n.companionTasksEarlier),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
