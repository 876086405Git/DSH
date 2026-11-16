import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Chinese name of a phone tool (`tap`, `mcp__phone__tap`, …).
String phoneToolLabel(String tool) {
  final name = tool.startsWith('mcp__phone__') ? tool.substring('mcp__phone__'.length) : tool;
  return switch (name) {
    'screen' => appL10n.phoneToolScreen,
    'collect' => appL10n.phoneToolCollect,
    'tap' => appL10n.phoneToolTap,
    'type' => appL10n.phoneToolType,
    'scroll' => appL10n.phoneToolScroll,
    'key' => appL10n.phoneToolKey,
    'tap_xy' => appL10n.phoneToolTapCoordinates,
    'handoff' => appL10n.phoneToolHandoff,
    'open' => appL10n.phoneToolOpenApp,
    'apps' => appL10n.phoneToolListApps,
    'intent' => appL10n.phoneToolIntent,
    'notify' => appL10n.phoneToolNotify,
    'clipboard' => appL10n.phoneToolClipboard,
    '' => appL10n.phoneToolAction,
    _ => name,
  };
}

String phoneDecisionLabel(PhoneLogEntry e) => switch (e.decision) {
  PhoneDecision.done => e.rawDecision == 'continue' ? appL10n.phoneDecisionContinued : appL10n.phoneDecisionDone,
  PhoneDecision.allowed => appL10n.phoneDecisionAllowed,
  PhoneDecision.denied => appL10n.commonDeclined,
  PhoneDecision.stopped => e.rawDecision == 'paused' ? appL10n.phoneDecisionPauseExpired : appL10n.commonStopped,
  PhoneDecision.blocked => appL10n.phoneDecisionBlocked,
  PhoneDecision.failed => switch (e.rawDecision) {
    'timeout' => appL10n.phoneDecisionTimeout,
    'unavailable' => appL10n.phoneDecisionUnavailable,
    'stale' => appL10n.phoneDecisionScreenChanged,
    _ => appL10n.phoneDecisionFailed,
  },
  // 系统操作's own words, for what isn't simply done or failed (HarmonyOS).
  PhoneDecision.unknown => switch (e.rawDecision) {
    'opened_ui' => appL10n.systemActionsOpenedUi,
    'reminder_scheduled' => appL10n.harmonyReminderSet,
    'result_unknown' => appL10n.systemActionsResultUnknown,
    'unsupported' => appL10n.systemActionsNotSupported,
    final raw => raw ?? '',
  },
};

String formatLogTime(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == n.year && t.month == n.month && t.day == n.day) return hm;
  return '${appL10n.monthDay(t)} $hm';
}

/// One action-log line: what was done, in which app, when, and how it was decided.
class ActionLogRow extends StatelessWidget {
  const ActionLogRow(this.entry, {super.key});

  final PhoneLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final (icon, color) = switch (entry.decision) {
      PhoneDecision.done || PhoneDecision.allowed => (AppIcons.allowed, colors.success),
      PhoneDecision.denied || PhoneDecision.stopped => (AppIcons.stopped, colors.warning),
      PhoneDecision.blocked => (AppIcons.blocked, colors.danger),
      PhoneDecision.failed => (AppIcons.error, colors.danger),
      PhoneDecision.unknown => (AppIcons.pending, colors.textTertiary),
    };
    final tool = phoneToolLabel(entry.tool);
    final title = entry.summary.isEmpty ? tool : entry.summary;
    final meta = [
      ?entry.app,
      if (entry.summary.isNotEmpty) tool,
      formatLogTime(entry.time),
    ].where((s) => s.isNotEmpty).join(' · ');
    final decision = phoneDecisionLabel(entry);
    return MergeSemantics(
      child: ListPageRow(
        leading: Icon(icon, size: 20, color: color),
        title: title,
        subtitle: meta.isEmpty ? null : meta,
        meta: decision,
        metaColor: color,
      ),
    );
  }
}

/// 操作记录: every step DSH took on the phone (no screen contents).
class PhoneActionLogPage extends ConsumerStatefulWidget {
  const PhoneActionLogPage({super.key});

  static const limit = 200;

  @override
  ConsumerState<PhoneActionLogPage> createState() => _PhoneActionLogPageState();
}

class _PhoneActionLogPageState extends ConsumerState<PhoneActionLogPage> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(phoneProvider.notifier).refreshLog(limit: PhoneActionLogPage.limit));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final log = ref.watch(phoneProvider.select((s) => s.log));
    return AppPage.list(
      title: l10n.phoneActionLogTitle,
      subtitle: Text(l10n.phoneActionLogSubtitle),
      actions: [
        GlassIconButton(
          icon: AppIcons.refresh,
          tooltip: l10n.phoneActionLogRefresh,
          onPressed: () => unawaited(ref.read(phoneProvider.notifier).refreshLog(limit: PhoneActionLogPage.limit)),
        ),
      ],
      children: [
        if (log.isEmpty)
          EmptyView(
            icon: AppIcons.history,
            title: l10n.phoneActionLogEmpty,
            message: l10n.phoneActionLogEmptyHint,
            padding: EdgeInsets.fromLTRB(32, 40, 32, 24),
          )
        else
          ListPageCard(
            children: [for (final (i, e) in log.indexed) FadeSlideIn(index: i, child: ActionLogRow(e))],
          ),
      ],
    );
  }
}
