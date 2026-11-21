import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/android_features.dart';
import '../../state/live_activity_state.dart';
import '../../state/notify_state.dart';
import '../phone/phone_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

/// Re-reads what the system allows whenever the app comes back (the person may
/// have just changed it in system settings).
mixin _RefreshOnResume<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        ref.invalidate(notifySystemStatusProvider);
        ref.invalidate(liveSystemStatusProvider);
        // 实时活动 may have just been allowed there: offer the running activity
        // again (the native side posts nothing new if it already shows it).
        unawaited(ref.read(notifyChannelProvider).live(ref.read(livePushProvider)));
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }
}

/// 设置 → 对话 → 通知: the current state at a glance; opens [NotificationSettingsPage].
class NotificationSettingsTile extends ConsumerStatefulWidget {
  const NotificationSettingsTile({super.key, this.tint = 3});

  /// The hub group's hue.
  final int tint;

  @override
  ConsumerState<NotificationSettingsTile> createState() => _NotificationSettingsTileState();
}

class _NotificationSettingsTileState extends ConsumerState<NotificationSettingsTile>
    with _RefreshOnResume<NotificationSettingsTile> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final prefs = ref.watch(notifyPrefsProvider);
    final system = ref.watch(notifySystemStatusProvider).value ?? const NotifySystemStatus();
    final Widget value;
    if (!prefs.enabled) {
      value = Text(l10n.pluginsTurnedOff, style: TextStyle(color: colors.textTertiary));
    } else if (!system.allOpen) {
      value = Text(
        system.enabled ? l10n.pluginsNotificationsPartlyBlocked : l10n.pluginsNotificationsBlocked,
        style: TextStyle(color: colors.warning),
      );
    } else {
      value = Text(l10n.pluginsTurnedOn);
    }
    return SettingsTile(
      icon: AppIcons.notificationsOn,
      tint: widget.tint,
      spot: SettingsIndex.entry(SettingsPageId.notifications),
      value: value,
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NotificationSettingsPage())),
    );
  }
}

/// Master switch, one switch per kind of event, and the way back to the
/// system settings when notifications are blocked there.
class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  ConsumerState<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends ConsumerState<NotificationSettingsPage>
    with _RefreshOnResume<NotificationSettingsPage> {
  bool get _ohos => ref.read(operatingSystemProvider) == 'ohos';

  void _settingsFailed() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        wordsForIos
            ? appL10n.iosNotificationSettingsFailed
            : _ohos
            ? appL10n.harmonyNotificationSettingsFailed
            : appL10n.pluginsNotificationSettingsFailed,
      ),
    ),
  );

  Future<void> _openSystem({String? channel}) async {
    final opened = await ref.read(notifyChannelProvider).openSettings(channel: channel);
    if (!mounted) return;
    _readAgainOnHarmony();
    if (!opened) _settingsFailed();
  }

  /// On HarmonyOS a half-sheet over the app, closed by now: there may be no resume to read again on.
  void _readAgainOnHarmony() {
    if (!_ohos) return;
    ref.invalidate(notifySystemStatusProvider);
    ref.invalidate(liveSystemStatusProvider);
  }

  Widget? _systemNote(NotifySystemStatus system) {
    if (system.allOpen) return null;
    final String title;
    final String text;
    String? channel;
    if (!system.enabled) {
      title = appL10n.pluginsSystemNotificationsOff;
      text = appL10n.pluginsBackgroundNoAlerts;
    } else if (_ohos) {
      // One system slot carries both kinds of alert: there is one switch to name.
      title = appL10n.harmonyAlertsOffTitle;
      text = appL10n.harmonyAlertsOffText;
    } else if (!system.attention) {
      title = appL10n.pluginsApprovalNotificationsOff;
      text = appL10n.pluginsBackgroundNoApprovalAlerts;
      channel = 'attention';
    } else {
      title = appL10n.pluginsDoneNotificationsOff;
      text = appL10n.pluginsBackgroundNoDoneAlerts;
      channel = 'done';
    }
    return PhoneNote(
      tone: NoteTone.warn,
      icon: AppIcons.notificationsOff,
      title: title,
      text: text,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      action: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: DshColors.of(context).onWarningContainer,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 0),
        ),
        iconAlignment: IconAlignment.end,
        icon: const Icon(AppIcons.forward, size: 16),
        onPressed: () => unawaited(_openSystem(channel: channel)),
        label: Text(appL10n.pluginsTurnOn),
      ),
    );
  }

  /// The live activity is on here but the system holds it back: the way to its switch.
  Widget _liveNote() => PhoneNote(
    tone: NoteTone.warn,
    icon: AppIcons.notificationsOff,
    title: _ohos ? appL10n.harmonyLiveBlockedTitle : appL10n.liveBlockedTitle,
    text: _ohos
        ? appL10n.harmonyLiveBlockedText
        : wordsForIos
        ? appL10n.liveIosBlockedText
        : appL10n.liveBlockedText,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    action: TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: DshColors.of(context).onWarningContainer,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 0),
      ),
      iconAlignment: IconAlignment.end,
      icon: const Icon(AppIcons.forward, size: 16),
      onPressed: () => unawaited(_openLive()),
      label: Text(appL10n.pluginsTurnOn),
    ),
  );

  Future<void> _openLive() async {
    final opened = await ref.read(notifyChannelProvider).openLiveSettings();
    if (!mounted) return;
    _readAgainOnHarmony();
    if (!opened) _settingsFailed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(notifyPrefsProvider);
    final notifier = ref.read(notifyPrefsProvider.notifier);
    final system = ref.watch(notifySystemStatusProvider).value ?? const NotifySystemStatus();
    // Unknown until the phone answers: no 「不支持」 flashing up meanwhile.
    final live = ref.watch(liveSystemStatusProvider).value;
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    // HarmonyOS has no live card in this build, only a plain progress notification.
    // A read that failed says nothing about whether it has one: the switch stays as it is.
    final liveSupported = ohos ? (live == null || live.readFailed || live.ordinaryFallback) : (live?.supported ?? true);
    final on = prefs.enabled;
    final note = on ? _systemNote(system) : null;
    final liveBlocked =
        on &&
        prefs.live &&
        live != null &&
        (ohos ? live.ordinaryFallback && !live.ordinaryAllowed : live.supported && !live.allowed);

    return AppPage.list(
      title: l10n.pluginsNotifications,
      subtitle: Text(l10n.pluginsNotificationsDescription),
      children: [
        ?note,
        SettingsSection(
          children: [
            SettingsSwitchTile(
              spot: Spots.notifyEnabled,
              subtitle: l10n.pluginsNotificationsAndBanners,
              value: on,
              onChanged: (v) => unawaited(notifier.setEnabled(v)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.pluginsAlerts,
          footer: Text(
            !ohos
                ? l10n.pluginsRemoteAlertsRequirement
                : ref.watch(localRuntimeProvider.select((s) => s.status.longTaskEligible))
                ? l10n.harmonyAlertsRequirementLong
                : l10n.harmonyAlertsRequirement,
          ),
          children: [
            SettingsSwitchTile(
              spot: Spots.notifyDone,
              subtitle: l10n.pluginsReplyPreview,
              value: prefs.done,
              onChanged: on ? (v) => unawaited(notifier.setDone(v)) : null,
            ),
            SettingsSwitchTile(
              spot: Spots.notifyFailed,
              subtitle: l10n.pluginsErrorOrStoppedDescription,
              value: prefs.failed,
              onChanged: on ? (v) => unawaited(notifier.setFailed(v)) : null,
            ),
            SettingsSwitchTile(
              spot: Spots.notifyApproval,
              subtitle: l10n.pluginsApprovalDescription,
              value: prefs.approval,
              onChanged: on ? (v) => unawaited(notifier.setApproval(v)) : null,
            ),
            SettingsSwitchTile(
              spot: Spots.notifyQuestion,
              subtitle: l10n.pluginsQuestionsDescription,
              value: prefs.question,
              onChanged: on ? (v) => unawaited(notifier.setQuestion(v)) : null,
            ),
          ],
        ),
        if (liveBlocked) _liveNote(),
        SettingsSection(
          title: ohos ? l10n.harmonyLiveTitle : l10n.liveSettingsTitle,
          footer: Text(
            ohos
                ? l10n.harmonyLiveFooter
                : wordsForIos
                ? l10n.liveIosFooter
                : l10n.liveSettingsFooter,
          ),
          children: [
            SettingsSwitchTile(
              spot: Spots.notifyLive,
              title: ohos ? l10n.harmonyLiveSwitch : null,
              subtitle: ohos
                  ? (liveSupported ? l10n.harmonyLiveSubtitle : l10n.harmonyLiveUnavailable)
                  : wordsForIos
                  ? (liveSupported ? l10n.liveIosSubtitle : l10n.liveIosUnsupported)
                  : liveSupported
                  ? l10n.liveSettingsSubtitle
                  : l10n.liveUnsupported,
              value: prefs.live && liveSupported,
              onChanged: on && liveSupported ? (v) => unawaited(notifier.setLive(v)) : null,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.pluginsSystemSettings,
          // Android posts a public version for the lock screen; here the real text goes to the system.
          footer: Text(ohos ? l10n.harmonyLockScreenPrivacy : l10n.pluginsLockScreenPrivacy),
          children: [
            SettingsTile(
              spot: Spots.notifySystem,
              subtitle: ohos
                  ? l10n.harmonyEnableBanner
                  : wordsForIos
                  ? l10n.iosEnableBanners
                  : l10n.pluginsEnableFloatingNotifications,
              onTap: () => unawaited(_openSystem()),
            ),
          ],
        ),
      ],
    );
  }
}
