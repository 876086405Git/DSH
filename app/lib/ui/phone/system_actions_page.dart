import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../state/system_actions_state.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/overview_card.dart';
import '../features/feature_kit.dart';
import '../features/permission_page.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'action_log_page.dart';
import 'phone_disclosure_sheet.dart';
import 'phone_widgets.dart';

/// 设置 → 系统操作, HarmonyOS's page where Android has 手机操控: the switch, what
/// the phone tools can and can't do there, how each call is confirmed, and the log.
class SystemActionsPage extends ConsumerStatefulWidget {
  const SystemActionsPage({super.key});

  /// Entries shown in 「最近操作」 on this page.
  static const recentCount = 3;

  @override
  ConsumerState<SystemActionsPage> createState() => _SystemActionsPageState();
}

class _SystemActionsPageState extends ConsumerState<SystemActionsPage> {
  bool _toggling = false;

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _onToggle(bool next) async {
    if (_toggling) return;
    final actions = ref.read(systemActionsProvider.notifier);
    if (next && !ref.read(systemActionsProvider).disclosureAccepted) {
      if (!await showPhoneDisclosure(context, harmony: true) || !mounted) return;
      await actions.acceptDisclosure();
    }
    setState(() => _toggling = true);
    final saved = await actions.setEnabled(next);
    if (!mounted) return;
    setState(() => _toggling = false);
    if (!saved) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.systemActionsToggleFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(systemActionsProvider);
    final status = systemActionsLine(l10n, state.link);
    final recent = state.log.take(SystemActionsPage.recentCount).toList();
    final reminders = ref.watch(reminderAccessProvider).value;
    const gap = SizedBox(height: 24);
    return AppPage.list(
      title: l10n.systemActionsTitle,
      subtitle: Text(l10n.systemActionsSubtitle),
      children: [
        if (!ref.watch(activeHostProvider).isLocal) ...[
          PhoneNote(
            icon: AppIcons.remoteHost,
            title: l10n.systemActionsRemoteTitle,
            text: l10n.systemActionsRemoteHint,
          ),
          const SizedBox(height: 10),
        ],
        OverviewCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          leading: const FeatureTile(FeatureKind.phone, size: OverviewCard.avatarSize),
          title: Text(l10n.systemActionsTitle),
          subtitle: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Text(status, key: ValueKey(status)),
          ),
          onTap: state.loaded && !_toggling ? () => unawaited(_onToggle(!state.enabled)) : null,
          trailing: Switch(
            key: const ValueKey('system-actions-switch'),
            value: state.enabled,
            onChanged: state.loaded && !_toggling ? (v) => unawaited(_onToggle(v)) : null,
          ),
        ),
        const SizedBox(height: 10),
        PhoneNote(title: l10n.systemActionsOnScreenTitle, text: l10n.systemActionsOnScreenBody),
        gap,
        ListPageCard(
          title: l10n.systemActionsCanTitle,
          children: [
            ListPageRow(
              icon: AppIcons.webApp,
              title: l10n.systemActionsCanOpen,
              subtitle: l10n.systemActionsCanOpenHint,
            ),
            ListPageRow(
              icon: AppIcons.alarmClock,
              title: l10n.systemActionsCanPages,
              subtitle: l10n.systemActionsCanPagesHint,
            ),
            ListPageRow(
              icon: AppIcons.operate,
              title: l10n.systemActionsCanSettings,
              subtitle: l10n.systemActionsCanSettingsHint,
              subtitleMaxLines: 2,
            ),
            ListPageRow(
              icon: AppIcons.backgroundPrompt,
              title: l10n.systemActionsCanNotify,
              subtitle: l10n.systemActionsCanNotifyHint,
            ),
            ListPageRow(
              icon: AppIcons.copy,
              title: l10n.systemActionsCanClipboard,
              subtitle: l10n.systemActionsCanClipboardHint,
            ),
            if (reminders == ReminderAccess.available)
              ListPageRow(
                icon: AppIcons.alarmClock,
                title: l10n.harmonyRemindersTitle,
                subtitle: l10n.harmonyRemindersCanHint,
                subtitleMaxLines: 3,
              ),
            ListPageRow(
              icon: AppIcons.lock,
              title: l10n.systemActionsCanHandoff,
              subtitle: l10n.systemActionsCanHandoffHint,
              subtitleMaxLines: 2,
            ),
          ],
        ),
        gap,
        ListPageCard(
          title: l10n.systemActionsCannotTitle,
          children: [
            ListPageRow(
              icon: AppIcons.blocked,
              title: l10n.systemActionsCannotScreen,
              subtitle: l10n.systemActionsCannotScreenHint,
            ),
            if (reminders == ReminderAccess.notThisBuild || reminders == ReminderAccess.notThisDevice)
              ListPageRow(
                icon: AppIcons.blocked,
                title: l10n.harmonyRemindersTitle,
                subtitle: reminders == ReminderAccess.notThisBuild
                    ? l10n.harmonyRemindersNoBuild
                    : l10n.harmonyRemindersNoDevice,
              ),
            ListPageRow(
              icon: AppIcons.blocked,
              title: l10n.systemActionsCannotOther,
              titleMaxLines: 2,
              subtitle: l10n.systemActionsCannotOtherHint,
              subtitleMaxLines: 2,
            ),
          ],
        ),
        gap,
        ListPageCard(
          children: [
            ListPageRow(
              icon: AppIcons.permissions,
              title: l10n.systemActionsConfirmTitle,
              subtitle: l10n.systemActionsConfirmHint,
              subtitleMaxLines: 3,
              value: l10n.systemActionsConfirmValue,
              onTap: () => _push(PermissionPage(sessionId: ref.read(currentSessionProvider))),
            ),
          ],
        ),
        gap,
        ListPageCard(
          title: l10n.phoneControlRecentActions,
          children: [
            for (final entry in recent) ActionLogRow(entry),
            ListPageRow(
              icon: AppIcons.history,
              title: l10n.phoneActionLogTitle,
              subtitle: l10n.systemActionsLogHint,
              onTap: () => _push(const SystemActionsLogPage()),
            ),
          ],
        ),
      ],
    );
  }
}

/// The switch's line: only what is true right now.
String systemActionsLine(L10n l10n, SystemActionsLink link) => switch (link) {
  SystemActionsLink.off => l10n.hubValueOff,
  SystemActionsLink.waitingEngine => l10n.systemActionsWaitingEngine,
  SystemActionsLink.offScreen => l10n.systemActionsOffScreen,
  SystemActionsLink.connecting => l10n.systemActionsConnecting,
  SystemActionsLink.ready => l10n.systemActionsReady,
  SystemActionsLink.unavailable => l10n.systemActionsUnavailable,
  SystemActionsLink.unsupported => l10n.systemActionsUnsupported,
};

/// 操作记录 on HarmonyOS: the rows of [PhoneActionLogPage], from this app's own
/// log (the native log behind that page is Android's).
class SystemActionsLogPage extends ConsumerWidget {
  const SystemActionsLogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final log = ref.watch(systemActionsProvider.select((s) => s.log));
    return AppPage.list(
      title: l10n.phoneActionLogTitle,
      subtitle: Text(l10n.systemActionsLogHint),
      children: [
        if (log.isEmpty)
          EmptyView(
            icon: AppIcons.history,
            title: l10n.phoneActionLogEmpty,
            message: l10n.systemActionsLogEmptyHint,
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
