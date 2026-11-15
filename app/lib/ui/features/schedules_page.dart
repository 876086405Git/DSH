// Native mirror of the official 自动化任务 page (`dsh-client-ui-schedule`):
// the Host's task catalog with an 全部 / 已开启 / 已结束 filter, 「新建」, and a
// detail page with the rule, the instruction, 编辑 (name, instruction, run
// time: `schedule/update`), 立即运行, the run history and delete. A new task
// is created by its conversation's model (`schedule_create`), from the exact
// request the editor writes (schedule_editor/).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/android_features.dart';
import '../../state/connection_state.dart';
import '../../state/features_state.dart';
import '../../state/hosts_state.dart';
import '../../state/schedule_editor_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_dialog.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/search_capsule.dart';
import '../common/segmented_pill.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'feature_format.dart';
import 'feature_kit.dart';
import 'feature_widgets.dart';
import '../common/smooth_size.dart';
import 'schedule_editor/schedule_editor_page.dart';
import 'schedule_editor/schedule_pickers.dart' show zoneLabel;
import '../common/brief_notice.dart';

enum ScheduleFilter { all, active, ended }

class SchedulesPage extends ConsumerStatefulWidget {
  const SchedulesPage({super.key, this.now});

  /// Clock override (tests).
  final DateTime? now;

  @override
  ConsumerState<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends ConsumerState<SchedulesPage> {
  ScheduleFilter _filter = ScheduleFilter.all;
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Like the official list: the stored name, the instruction and the rule.
  bool _matches(ScheduleTask t) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.prompt.toLowerCase().contains(q) ||
        scheduleRule(t).toLowerCase().contains(q);
  }

  Future<void> _open(ScheduleTask task) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ScheduleDetailPage(task: task, now: widget.now),
    ),
  );

  Future<void> _create() async {
    final created = await Navigator.of(context)
        .push<ScheduleTask>(MaterialPageRoute(builder: (_) => ScheduleEditorPage(now: widget.now)));
    if (created == null || !mounted) return;
    showBriefNotice(context, context.l10n.featuresScheduleCreated);
    unawaited(_open(created));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tasks = ref.watch(schedulesProvider);
    final list = tasks.value;
    final shown = [
      for (final t in list ?? const <ScheduleTask>[])
        if (_matches(t) &&
            switch (_filter) {
              ScheduleFilter.all => true,
              ScheduleFilter.active => t.active,
              ScheduleFilter.ended => !t.active,
            })
          t,
    ];
    final Widget body;
    if (ref.watch(activeConnectionProvider).value == null) {
      body = const FeatureOffline();
    } else if (list == null && tasks.hasError) {
      body = FeatureMessage.error(
        title: l10n.featuresSchedulesReadFailed,
        error: tasks.error!,
        onRetry: () => ref.invalidate(schedulesProvider),
      );
    } else if (list == null) {
      body = const FeatureLoading();
    } else if (list.isEmpty) {
      body = FeatureMessage(
        tile: FeatureKind.automation,
        title: l10n.featuresSchedulesEmpty,
        body: l10n.featuresSchedulesEmptyHint,
        action: (l10n.featuresScheduleNewTask, () => unawaited(_create())),
      );
    } else if (shown.isEmpty && _query.trim().isNotEmpty) {
      body = FeatureMessage(icon: AppIcons.noResults, title: l10n.featuresSchedulesNoMatch);
    } else if (shown.isEmpty) {
      body = FeatureMessage(
        icon: AppIcons.noMatches,
        title: _filter == ScheduleFilter.active ? l10n.featuresSchedulesNoActive : l10n.featuresSchedulesNoEnded,
      );
    } else {
      body = ListPageCard(
        children: [
          for (final (i, task) in shown.indexed)
            FadeSlideIn(
              index: i,
              child: _TaskRow(task: task, now: widget.now, onTap: () => unawaited(_open(task))),
            ),
        ],
      );
    }
    return AppPage.list(
      title: l10n.featuresSchedules,
      subtitle: Text(l10n.featuresSchedulesSubtitle),
      actions: [
        GlassIconButton(
          icon: AppIcons.add,
          tooltip: l10n.featuresNew,
          onPressed: ref.watch(activeConnectionProvider).value == null ? null : () => unawaited(_create()),
        ),
      ],
      children: [
        // The on-device engine is suspended with the app: a remote host's tasks don't care.
        if (!ref.watch(androidSystemFeaturesProvider) && ref.watch(activeHostProvider).isLocal)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(l10n.harmonySchedulesLocal, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (list != null && list.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchCapsule(
              hint: l10n.featuresSchedulesSearch,
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              onClear: () => setState(() {
                _search.clear();
                _query = '';
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SegmentedPill<ScheduleFilter>(
              segments: [
                PillSegment(ScheduleFilter.all, l10n.featuresSchedulesAllCount(list.length)),
                PillSegment(
                  ScheduleFilter.active,
                  l10n.featuresSchedulesActiveCount(list.where((t) => t.active).length),
                ),
                PillSegment(
                  ScheduleFilter.ended,
                  l10n.featuresSchedulesEndedCount(list.where((t) => !t.active).length),
                ),
              ],
              selected: _filter,
              onChanged: (f) => setState(() => _filter = f),
            ),
          ),
        ],
        // A filter switch cross-fades the list (and its height) instead of
        // swapping it in one frame.
        SmoothSize(
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.std,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            switchInCurve: AppMotion.std,
            switchOutCurve: AppMotion.std,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: KeyedSubtree(key: ValueKey(_filter), child: body),
          ),
        ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onTap, this.now});

  final ScheduleTask task;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListPageRow(
      icon: task.recurring ? AppIcons.recurring : AppIcons.automation,
      iconColor: task.active ? null : DshColors.of(context).textTertiary,
      title: task.title.isEmpty ? l10n.featuresScheduleUntitled : task.title,
      subtitle: scheduleSummary(task, now: now),
      onTap: onTap,
    );
  }
}

/// One task: rule, prompt, run history, related conversation, delete.
class ScheduleDetailPage extends ConsumerStatefulWidget {
  const ScheduleDetailPage({super.key, required this.task, this.now});

  final ScheduleTask task;
  final DateTime? now;

  @override
  ConsumerState<ScheduleDetailPage> createState() => _ScheduleDetailPageState();
}

class _ScheduleDetailPageState extends ConsumerState<ScheduleDetailPage> {
  late ScheduleTask _task = widget.task;
  bool _busy = false;

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// The freshest copy of the task: the catalog's, else the last one seen.
  ScheduleTask _current() {
    final live = ref.read(schedulesProvider).value?.where((t) => t.id == _task.id).firstOrNull;
    return live ?? _task;
  }

  Future<void> _openEditor() async {
    final saved = await Navigator.of(context).push<ScheduleTask>(
      MaterialPageRoute(
        builder: (_) => ScheduleEditorPage(task: _current(), now: widget.now),
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _task = saved);
    showBriefNotice(context, context.l10n.commonSaved);
  }

  Future<void> _runNow() async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return _toast(context.l10n.commonEngineUnreachable);
    final task = _current();
    setState(() => _busy = true);
    try {
      await runScheduleNow(client, task, timeZone: ref.read(deviceTimeZoneProvider).value);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(context.l10n.featuresScheduleSent),
          persist: false,
          action: SnackBarAction(
            label: context.l10n.featuresView,
            onPressed: () => openSessionInChat(context, ref, task.sessionId),
          ),
        ),
      );
    } catch (_) {
      if (mounted) _toast(context.l10n.featuresSendFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.featuresScheduleDeleteTitle),
        content: Text(context.l10n.featuresScheduleDeleteHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return _toast(context.l10n.commonEngineUnreachable);
    setState(() => _busy = true);
    try {
      final deleted = await client.deleteSchedule(_current());
      ref.invalidate(schedulesProvider);
      if (!mounted) return;
      if (deleted) {
        showBriefNotice(context, context.l10n.featuresScheduleDeleted);
      } else {
        _toast(context.l10n.featuresScheduleNotFound);
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(featureErrorText(context.l10n.featuresDeleteFailed, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final task = ref.watch(schedulesProvider).value?.where((t) => t.id == _task.id).firstOrNull ?? _task;
    final sessions = ref.watch(sessionsProvider).value;
    final session = sessions?.where((s) => s.sessionId == task.sessionId).firstOrNull;
    final sessionTitle = session?.projections.title?.trim();
    final history = ref.watch(scheduleHistoryProvider(widget.task));
    const gap = SizedBox(height: 24);
    return AppPage(
      title: task.title.isEmpty ? l10n.featuresScheduleUntitled : task.title,
      hero: PageHero(
        leading: DecoratedBox(
          decoration: ShapeDecoration(
            color: task.active ? colors.identity[5] : theme.colorScheme.onSurface.withValues(alpha: 0.06),
            shape: const CircleBorder(),
          ),
          child: SizedBox.square(
            dimension: 56,
            child: Icon(
              task.recurring ? AppIcons.recurring : AppIcons.automation,
              size: 26,
              color: task.active ? colors.onIdentity[5] : colors.textTertiary,
            ),
          ),
        ),
        title: task.title.isEmpty ? l10n.featuresScheduleUntitled : task.title,
        subtitle: Text(task.active ? l10n.featuresScheduleActive : l10n.featuresEnded),
        stats: [
          (scheduleRule(task), l10n.featuresScheduleRun),
          if (task.active && task.scheduledAt != null)
            (formatWhen(task.scheduledAt!, now: widget.now), l10n.featuresScheduleNextRun)
          else if (task.lastDeliveredAt case final last?)
            (formatWhen(last, now: widget.now), l10n.featuresScheduleLastRun),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            ListPageCard(
              title: l10n.featuresScheduleRule,
              children: [
                if (task.active)
                  if (task.lastDeliveredAt case final last?)
                    ListPageRow(
                      icon: AppIcons.history,
                      title: l10n.featuresScheduleLastRun,
                      value: formatWhen(last, now: widget.now),
                    ),
                if (task.timeZone case final tz?)
                  ListPageRow(
                    icon: AppIcons.timeZone,
                    title: l10n.featuresTimeZone,
                    value: zoneLabel(tz, at: widget.now),
                  ),
                ListPageRow(
                  icon: AppIcons.chat,
                  title: l10n.featuresScheduleLinkedChat,
                  subtitle: sessions == null
                      ? null
                      : session == null
                      ? l10n.featuresScheduleChatDeleted
                      : sessionTitle == null || sessionTitle.isEmpty
                      ? l10n.commonUntitledChat
                      : sessionTitle,
                  onTap: session == null ? null : () => openSessionInChat(context, ref, task.sessionId),
                ),
              ],
            ),
            gap,
            ListPageCard(
              title: l10n.featuresScheduleInstruction,
              children: [
                FeatureBlock(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: SelectableText(task.prompt, style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
                ),
              ],
            ),
            gap,
            ListPageCard(
              children: [
                if (task.active)
                  ListPageRow(
                    icon: AppIcons.edit,
                    title: l10n.featuresScheduleEdit,
                    onTap: _busy ? null : () => unawaited(_openEditor()),
                  ),
                ListPageRow(
                  icon: AppIcons.play,
                  title: l10n.featuresScheduleRunNow,
                  chevron: false,
                  onTap: _busy ? null : () => unawaited(_runNow()),
                ),
              ],
            ),
            gap,
            ListPageCard(
              title: l10n.featuresScheduleHistory,
              children: switch (history) {
                AsyncData(:final value) when value.runs.isEmpty => [
                  ListPageRow(
                    icon: AppIcons.history,
                    iconColor: colors.textTertiary,
                    title: value.missing == null
                        ? l10n.featuresScheduleNeverRun
                        : l10n.featuresScheduleHistoryUnavailable,
                  ),
                ],
                AsyncData(:final value) => [
                  for (final run in value.runs)
                    ListPageRow(
                      icon: AppIcons.history,
                      title: run.deliveredAt == null ? '—' : formatWhen(run.deliveredAt!, now: widget.now),
                      subtitle: run.prompt?.split('\n').first,
                    ),
                ],
                AsyncError(:final error) => [
                  ListPageRow(
                    icon: AppIcons.error,
                    title: l10n.featuresScheduleHistoryReadFailed,
                    subtitle: featureErrorReason(error),
                    meta: l10n.commonRetry,
                    onTap: () => ref.invalidate(scheduleHistoryProvider(widget.task)),
                  ),
                ],
                _ => [const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 18))],
              },
            ),
            if (history.value case final h? when h.pruned && h.retentionDays != null)
              FeatureNote(
                h.retentionRecords == null
                    ? l10n.featuresScheduleRetentionUnknown(h.retentionDays!)
                    : l10n.featuresScheduleRetention(h.retentionDays!, h.retentionRecords!),
              ),
            gap,
            ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.delete,
                  danger: true,
                  title: l10n.featuresScheduleDelete,
                  chevron: false,
                  onTap: _busy ? null : () => unawaited(_delete()),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
