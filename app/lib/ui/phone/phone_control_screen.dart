import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/android_features.dart';
import '../../state/hosts_state.dart';
import '../../state/ios_phone_link_state.dart';
import '../../state/phone_overlay_prefs.dart';
import '../../state/phone_skills_state.dart';
import '../../state/phone_state.dart';
import '../../state/phone_turn_end.dart';
import '../common/app_sheet.dart';
import '../common/app_dialog.dart';
import '../common/ask_ai.dart';
import '../common/brief_notice.dart';
import '../common/risk_notice.dart';
import '../common/feature_tile.dart';
import '../settings/background_guide_page.dart';
import '../settings/index/spots.dart';
import '../settings/index/spot_anchor.dart';
import '../common/list_page_row.dart';
import '../common/overview_card.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'action_log_page.dart';
import 'android_shell_page.dart';
import 'a11y_restore_sheet.dart';
import 'always_allow_page.dart';
import 'app_rules_page.dart';
import 'dnd_mode_page.dart';
import 'ios_pet_pip_section.dart';
import 'ios_phone_link_section.dart';
import 'phone_disclosure_sheet.dart';
import 'phone_background_guide.dart';
import 'phone_unlock_page.dart';
import 'phone_self_check_panel.dart';
import '../chat/widgets/phone_skill_banner.dart';
import 'phone_skills_page.dart';
import 'phone_widgets.dart';
import 'restricted_settings_guide.dart';
import 'screen_text_sheet.dart';

extension PhoneConfirmModeText on PhoneConfirmMode {
  String get label => switch (this) {
    PhoneConfirmMode.ask => appL10n.phoneConfirmAsk,
    PhoneConfirmMode.task => appL10n.phoneConfirmTask,
    PhoneConfirmMode.always => appL10n.phoneConfirmAlways,
  };

  String get detail => switch (this) {
    PhoneConfirmMode.ask => appL10n.phoneConfirmAskHint,
    PhoneConfirmMode.task => appL10n.phoneConfirmTaskHint,
    PhoneConfirmMode.always => appL10n.phoneConfirmAlwaysHint,
  };

  IconData get icon => switch (this) {
    PhoneConfirmMode.ask => AppIcons.askFirst,
    PhoneConfirmMode.task => AppIcons.askPerTask,
    PhoneConfirmMode.always => AppIcons.noConfirm,
  };
}

/// Where a row of 确认方式's 「这些由你来操作」 goes.
enum _ConfirmLink { appRules, unlocks }

/// 设置 → 手机操控: the master switch behind
/// the 显著披露, permission status with fixes, a test read, 不打扰模式, the app
/// list and the action log.
class PhoneControlScreen extends ConsumerStatefulWidget {
  const PhoneControlScreen({super.key});

  /// Entries shown in 「最近操作」 on this page.
  static const recentCount = 3;

  @override
  ConsumerState<PhoneControlScreen> createState() => _PhoneControlScreenState();
}

class _PhoneControlScreenState extends ConsumerState<PhoneControlScreen> {
  late final AppLifecycleListener _lifecycle;

  /// Sent to the accessibility settings and not back with it on yet.
  bool _awaitingA11y = false;

  /// Came back from there still off: point at the restricted-settings guide.
  bool _a11yAttemptFailed = false;
  bool _testing = false;
  bool _ocrSaving = false;
  bool _interruptionBusy = false;
  bool _backgroundGuideShown = false;
  int _resumeRead = 0;

  PhoneController get _phone => ref.read(phoneProvider.notifier);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    // A fresh read each time the page opens (the provider may be older).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _phone.refresh();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _onResume() async {
    unawaited(ref.read(phoneLinkProvider.notifier).refresh());
    // Notifications, 实时活动 or the vendor's permission may have changed in the system settings.
    ref.invalidate(phoneSystemIslandProvider);
    final read = ++_resumeRead;
    await _phone.refreshStatus();
    if (!mounted || read != _resumeRead) return;
    if (!_awaitingA11y) return;
    final on = ref.read(phoneProvider).status.a11y.enabled;
    setState(() {
      _awaitingA11y = false;
      _a11yAttemptFailed = !on;
    });
  }

  Future<void> _setLocalOcr(bool enabled) async {
    if (_ocrSaving) return;
    setState(() => _ocrSaving = true);
    final ok = await ref.read(phoneProvider.notifier).setLocalOcrEnabled(enabled);
    if (!mounted) return;
    setState(() => _ocrSaving = false);
    _toast(ok ? context.l10n.commonSaved : context.l10n.phoneActionFailedLater);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 确认方式: the three ways, then what stays with the person whichever is
  /// picked (so 全程自动 stopping at a password isn't taken for a fault),
  /// with the two places those are changed.
  Future<void> _pickConfirmMode(PhoneConfirmMode current) async {
    final picked = await showAppSheet<Object>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(context.l10n.phoneConfirmTitle),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SheetGroup(
                      children: [
                        for (final mode in PhoneConfirmMode.values)
                          ListPageRow(
                            icon: mode.icon,
                            title: mode.label,
                            subtitle: mode.detail,
                            chevron: false,
                            trailing: mode == current
                                ? Icon(AppIcons.selected, size: 22, color: Theme.of(sheet).colorScheme.primary)
                                : const SizedBox.square(dimension: 22),
                            onTap: () => Navigator.pop(sheet, mode),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _YoursGroup(onLink: (link) => Navigator.pop(sheet, link)),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (picked) {
      case _ConfirmLink.appRules:
        _push(const PhoneAppRulesPage());
        return;
      case _ConfirmLink.unlocks:
        _push(const PhoneUnlockPage());
        return;
    }
    final next = picked is PhoneConfirmMode ? picked : null;
    if (next == null || next == current) return;
    // 本任务免确认 needs no notice: each task still asks once, at its start.
    if (next == PhoneConfirmMode.always) {
      final ok = await confirmRisk(context, RiskNotices.phoneConfirmAlways);
      if (!ok || !mounted) return;
    }
    final done = await _phone.setConfirmMode(next);
    if (!done && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.phoneConfirmSaveFailed)));
    }
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _onToggle(bool next) async {
    if (next && !ref.read(phoneProvider).disclosureAccepted) {
      final ok = await showPhoneDisclosure(context);
      if (!ok || !mounted) return;
      await _phone.acceptDisclosure();
    }
    final result = await _phone.setEnabled(next);
    if (!mounted) return;
    if (!result.ok) {
      _toast(next ? context.l10n.phoneEnableFailed : context.l10n.phoneDisableFailed);
      return;
    }
    final runtime = ref.read(localRuntimeProvider).status;
    final String done;
    if (result.restarting) {
      done = next ? context.l10n.phoneControlEnabledRestarting : context.l10n.phoneControlDisabledRestarting;
    } else if (next && runtime.phase != RuntimePhase.running) {
      done = context.l10n.phoneControlEnabledPending;
    } else {
      done = next ? context.l10n.phoneEnabled : context.l10n.phoneDisabled;
    }
    // A confirmation: brief. The failure above keeps the default four seconds.
    showBriefNotice(context, done);
    if (next) await _offerBackgroundGuide();
  }

  Future<void> _showBackgroundGuide() async {
    final open = await showPhoneBackgroundGuide(context, ref.read(phoneProvider).status.device);
    if (mounted && open) await _openAppDetails();
  }

  Future<void> _offerBackgroundGuide() async {
    if (_backgroundGuideShown) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || !ref.read(phoneProvider).status.enabled || prefs.get(phoneBackgroundGuideSeenKey) == true) return;
      _backgroundGuideShown = true;
      await _showBackgroundGuide();
      await prefs.setBool(phoneBackgroundGuideSeenKey, true);
    } catch (_) {
      // The same guide remains available on this settings page.
    }
  }

  Future<void> _openA11y() async {
    setState(() => _awaitingA11y = true);
    final ok = await _phone.openAccessibilitySettings();
    if (!ok && mounted) {
      setState(() => _awaitingA11y = false);
      _toast(context.l10n.phoneOpenAccessibilityFailed);
    }
  }

  Future<void> _openAppDetails() async {
    final ok = await _phone.openAppDetails();
    if (!ok && mounted) _toast(context.l10n.phoneOpenAppInfoFailed);
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() => _testing = true);
    final result = await _phone.testScreen();
    if (!mounted) return;
    setState(() => _testing = false);
    await showScreenTextSheet(context, result);
  }

  /// Bound to the task the row showed: a tap queued before another task was
  /// selected still stops that one, never its successor.
  Future<void> _stopTask(int? taskId) async {
    final ok = await _phone.stopTask(taskId: taskId);
    if (!ok && mounted) _toast(context.l10n.phoneStopFailed);
  }

  Future<void> _retryTaskCleanup(int taskId) async {
    final ok = await _phone.retryTaskCleanup(taskId);
    if (!ok && mounted) _toast(context.l10n.phoneCleanupRetryFailed);
  }

  Future<void> _taskInterruptionAction(String? batchToken) async {
    if (_interruptionBusy) return;
    setState(() => _interruptionBusy = true);
    try {
      final ok = batchToken == null
          ? await _phone.retryTaskInterruptionStorage()
          : await _phone.acknowledgeTaskInterruption(batchToken);
      if (!ok && mounted) _toast(context.l10n.phoneInterruptionActionFailed);
    } finally {
      if (mounted) setState(() => _interruptionBusy = false);
    }
  }

  Future<void> _resumeTask(int taskId) async {
    final ok = await _phone.resumeTask(taskId);
    if (!ok && mounted) _toast(context.l10n.phoneResumeTaskFailed);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(operatingSystemProvider) == 'ios') return _buildIOS();
    final l10n = context.l10n;
    final state = ref.watch(phoneProvider);
    final blocker = ref.watch(phoneBlockerProvider);
    final runtime = ref.watch(localRuntimeProvider.select((s) => s.status));
    final status = state.status;
    final ready = state.loaded && status.ready;
    final toggle = _switchHandler(state, blocker);
    final targetSpot = SpotFocus.maybeOf(context)?.target;
    final task = status.task;
    // A stopped task is inactive. Keep an explicit, session-scoped way to allow future calls.
    final stoppedSessions = <Object, PhoneTaskStatus>{};
    int recoveryPriority(PhoneTaskStatus item) => item.cleanupFailed
        ? 3
        : item.finishing || item.draining || item.retiring
        ? 2
        : 1;
    for (final item in status.tasks) {
      if (item.id == null || !(item.stopped || item.finishing || item.draining)) continue;
      if (item.sessionId == null && !item.finishing && !item.draining && !item.cleanupFailed) continue;
      final key = item.sessionId ?? #legacyPhoneTask;
      final previous = stoppedSessions[key];
      // A later stopped run must not hide the old resource that still requires cleanup.
      if (previous == null || recoveryPriority(item) >= recoveryPriority(previous)) stoppedSessions[key] = item;
    }
    const gap = SizedBox(height: 24);

    return AppPage.list(
      title: l10n.phoneControlTitle,
      subtitle: Text(l10n.phoneControlSubtitle),
      actions: const [AskAiButton(AskAiTopic.phoneControl)],
      children: [
        if (blocker != null) ...[_BlockerNote(blocker), const SizedBox(height: 10)],
        OverviewCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          leading: const FeatureTile(FeatureKind.phone, size: OverviewCard.avatarSize),
          title: Text(l10n.phoneControlTitle),
          subtitle: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Text(_statusLine(state, runtime, blocker), key: ValueKey(_statusLine(state, runtime, blocker))),
          ),
          onTap: toggle == null ? null : () => _onToggle(!status.enabled),
          trailing: state.toggling
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
                )
              : Switch(value: status.enabled, onChanged: toggle),
        ),
        if (state.policies?.unlocks.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: UnlockedTag(onTap: () => _push(const PhoneUnlockPage())),
            ),
          ),
        if (status.taskInterruption.visible) ...[
          const SizedBox(height: 12),
          ListPageCard(
            children: [
              ListPageRow(
                key: const ValueKey('phone-task-interruption'),
                icon: AppIcons.paused,
                title: l10n.phoneInterruptionTitle,
                subtitle: status.taskInterruption.state == 'loading'
                    ? l10n.phoneInterruptionLoading
                    : status.taskInterruption.state == 'error'
                    ? l10n.phoneInterruptionStorageError
                    : l10n.phoneInterruptionHint(status.taskInterruption.count),
                trailing: status.taskInterruption.state == 'loading'
                    ? null
                    : FixButton(
                        key: const ValueKey('phone-task-interruption-action'),
                        label: status.taskInterruption.canAcknowledge
                            ? l10n.phoneInterruptionAcknowledge
                            : l10n.phoneInterruptionRetry,
                        onPressed: !ready || _interruptionBusy
                            ? null
                            : () => _taskInterruptionAction(status.taskInterruption.batchToken),
                      ),
              ),
            ],
          ),
        ],
        if (task.active) ...[
          const SizedBox(height: 12),
          ListPageCard(
            children: [
              ListPageRow(
                icon: task.paused ? AppIcons.paused : AppIcons.phoneControl,
                iconColor: Theme.of(context).colorScheme.primary,
                title: task.app == null ? l10n.phoneControlWorking : l10n.phoneControlWorkingApp(task.app!),
                subtitle: task.paused
                    ? l10n.commonPaused
                    : task.waived
                    ? l10n.phoneControlTaskNoConfirmHint
                    : l10n.phoneControlFloatingBarHint,
                trailing: FixButton(label: l10n.commonStop, onPressed: ready ? () => _stopTask(task.id) : null),
              ),
            ],
          ),
        ],
        for (final waiting in status.tasks.where(
          (item) => item.id != null && item.waitingForResources && !item.stopped && !item.finishing && !item.draining,
        )) ...[
          const SizedBox(height: 12),
          ListPageCard(
            children: [
              ListPageRow(
                key: ValueKey('phone-waiting-${waiting.id}'),
                trailing: FixButton(label: l10n.commonStop, onPressed: ready ? () => _stopTask(waiting.id) : null),
                icon: AppIcons.phoneControl,
                title: l10n.phoneTaskWaiting(waiting.id!),
                subtitle: waiting.waitingForApp != null
                    ? waiting.waitingForApp!.packageName != null
                          ? l10n.phoneTaskWaitingApp(waiting.waitingForApp!.packageName!, waiting.waitingForMs ~/ 1000)
                          : l10n.phoneTaskWaitingUnknown(waiting.waitingForMs ~/ 1000)
                    : l10n.phoneTaskWaitingScreen(
                        waiting.waitingForScreen == 'background'
                            ? l10n.phoneTaskBackgroundResource
                            : l10n.phoneTaskMainResource,
                        waiting.waitingForMs ~/ 1000,
                      ),
              ),
            ],
          ),
        ],
        for (final stopped in stoppedSessions.values) ...[
          const SizedBox(height: 12),
          ListPageCard(
            children: [
              ListPageRow(
                icon: AppIcons.paused,
                title: stopped.stopped ? l10n.phoneStoppedTask(stopped.id!) : l10n.phoneFinishingTask(stopped.id!),
                subtitle: stopped.cleanupFailed
                    ? l10n.phoneTaskCleanupFailedHint
                    : stopped.retiring || stopped.draining || stopped.finishing || stopped.pendingCalls > 0
                    ? l10n.phoneTaskDrainingHint
                    : l10n.phoneResumeTaskHint,
                trailing: FixButton(
                  key: ValueKey('phone-resume-${stopped.id}'),
                  label: stopped.cleanupFailed ? l10n.phoneCleanupRetry : l10n.phoneResumeTask,
                  onPressed: !ready
                      ? null
                      : stopped.cleanupFailed
                      ? stopped.draining || stopped.settling || stopped.pendingCalls > 0
                            ? null
                            : () => _retryTaskCleanup(stopped.id!)
                      : stopped.retiring ||
                            stopped.draining ||
                            stopped.finishing ||
                            stopped.cleanupFailed ||
                            stopped.pendingCalls > 0
                      ? null
                      : () => _resumeTask(stopped.id!),
                ),
              ),
            ],
          ),
        ],
        gap,
        if (!state.loaded)
          const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 32))
        else if (ready) ...[
          if (status.enabled) ..._setup(status) else const _WhatItDoes(),
          gap,
          ..._rules(state),
          gap,
          if (status.enabled) ...[
            ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.dndMode,
                  spot: SettingsIndex.entry(SettingsPageId.phoneDnd),
                  subtitle: dndSummary(status.background),
                  onTap: () => _push(const PhoneDndPage()),
                ),
                if (PhoneSkillBanner.supported) const _SkillsRow(),
              ],
            ),
            gap,
          ],
          PhoneOptionsFold(
            key: const ValueKey('phone-more-options'),
            title: l10n.phoneControlAdvanced,
            initiallyOpen: [
              Spots.phoneA11yRestore,
              Spots.phoneAutoCollapse,
              Spots.phoneEdgeGlow,
              Spots.phoneSystemIsland,
              Spots.phoneReturn,
              Spots.phoneBackgroundGuide,
            ].any((spot) => spot.id == targetSpot),
            children: [
              if (status.enabled) ...[
                _floatingBar(),
                gap,
                ListPageCard(
                  children: [
                    ListPageRow(
                      key: const Key('phone-a11y-restore'),
                      icon: AppIcons.keepAlive,
                      spot: Spots.phoneA11yRestore,
                      subtitle: status.a11yKeeper.granted ? l10n.phoneEnabled : l10n.a11yRestoreNeedsGrant,
                      onTap: () => showA11yRestoreSheet(context),
                    ),
                    ListPageRow(
                      icon: AppIcons.keepAlive,
                      spot: SettingsIndex.entry(SettingsPageId.background),
                      subtitle: l10n.phoneControlKeepAliveHint,
                      onTap: () => _push(const BackgroundGuidePage()),
                    ),
                    ListPageRow(
                      icon: AppIcons.backgroundPrompt,
                      spot: Spots.phoneBackgroundGuide,
                      onTap: _showBackgroundGuide,
                    ),
                  ],
                ),
                gap,
              ],
              ListPageCard(
                children: [
                  ListPageRow(
                    key: const ValueKey('phone-self-check-entry'),
                    icon: AppIcons.readScreen,
                    title: l10n.phoneSelfCheckTitle,
                    onTap: () => _push(const PhoneSelfCheckPage()),
                  ),
                ],
              ),
              gap,
              _localOcr(state),
              gap,
              ListPageCard(
                children: [
                  ListPageRow(
                    key: const ValueKey('android-shell-entry'),
                    icon: AppIcons.terminal,
                    spot: SettingsIndex.entry(SettingsPageId.phoneAndroidShell),
                    onTap: () => _push(const AndroidShellPage()),
                  ),
                ],
              ),
              gap,
              _recentActions(state),
            ],
          ),
          // Said only while it is true: lifted rules are named by the tag above.
          if (state.policies?.unlocks.isEmpty ?? true) PageFootnote(l10n.phoneSensitiveActionsNote),
        ],
      ],
    );
  }

  Widget _buildIOS() {
    final l10n = context.l10n;
    final state = ref.watch(phoneProvider);
    final status = state.status;
    final link = ref.watch(phoneLinkProvider).status;
    final returnAfterDone = ref.watch(phoneReturnPrefProvider);
    Future<void> setEnabled(bool value) async {
      if (await ref.read(phoneChannelProvider).setEnabled(value)) {
        await ref.read(phoneProvider.notifier).refreshStatus();
      }
    }

    // The runner's `bridgeListening` is the XCTest route only; the on-device connection says
    // ready by its own switch and record.
    final linkSet = link != null && link.enabled && link.pairingPresent;
    final taskRow = status.task.active
        ? ListPageRow(
            icon: AppIcons.phoneControl,
            title: l10n.phoneControlWorking,
            trailing: FixButton(label: l10n.commonStop, onPressed: () => unawaited(_stopTask(status.task.id))),
          )
        : null;
    final returnRow = MergeSemantics(
      child: ListPageRow(
        icon: AppIcons.returnToApp,
        spot: Spots.phoneReturn,
        subtitle: l10n.phoneIosReturnHint,
        subtitleMaxLines: 3,
        onTap: () => unawaited(_setReturn(!returnAfterDone)),
        trailing: Switch.adaptive(value: returnAfterDone, onChanged: (value) => unawaited(_setReturn(value))),
      ),
    );

    return AppPage.list(
      title: l10n.phoneControlTitle,
      children: [
        const PhoneLinkClipboardCard(),
        OverviewCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          leading: const FeatureTile(FeatureKind.phone, size: OverviewCard.avatarSize),
          title: Text(l10n.phoneControlTitle),
          subtitle: Text(
            !status.enabled
                ? l10n.phoneControlNotEnabled
                : linkSet || status.bridgeListening
                ? l10n.phoneControlReady
                : l10n.phoneIosNeedsSetup,
          ),
          trailing: Switch.adaptive(
            value: status.enabled,
            onChanged: state.loaded ? (value) => unawaited(setEnabled(value)) : null,
          ),
        ),
        const SizedBox(height: 24),
        if (link == null) ...[
          // A build without the on-device connection: the runner alone.
          ListPageCard(
            title: l10n.phoneIosServiceTitle,
            children: [
              ListPageRow(
                icon: AppIcons.phoneControl,
                title: l10n.phoneIosServiceTitle,
                subtitle: l10n.phoneIosServiceHint,
                subtitleMaxLines: 4,
              ),
              returnRow,
              ?taskRow,
            ],
          ),
          PageFootnote(l10n.phoneIosSetupHint),
        ] else ...[
          if (taskRow != null) ...[
            ListPageCard(children: [taskRow]),
            const SizedBox(height: 24),
          ],
          const PhoneLinkSection(),
          PageFootnote(l10n.iosPhoneLinkIntro),
          const SizedBox(height: 24),
          const IosPetPipSection(),
          PageFootnote(l10n.iosPetPipHint),
          const SizedBox(height: 24),
          ListPageCard(children: [returnRow]),
          const SizedBox(height: 24),
          const PhoneLinkExtrasSection(),
        ],
      ],
    );
  }

  ValueChanged<bool>? _switchHandler(PhoneState state, PhoneBlocker? blocker) {
    if (state.toggling || !state.loaded) return null;
    if (blocker == PhoneBlocker.notReady) return null;
    // Safe mode loads no plugins: allow turning off (the plugin may be the
    // problem), not on.
    if (blocker == PhoneBlocker.safeMode && !state.status.enabled) return null;
    return (v) => unawaited(_onToggle(v));
  }

  /// The overview's one line: what state it is in, or the one thing left.
  String _statusLine(PhoneState state, RuntimeStatus runtime, PhoneBlocker? blocker) {
    final s = state.status;
    if (!state.loaded) return context.l10n.phoneControlReadingEllipsis;
    if (blocker == PhoneBlocker.notReady) return context.l10n.phoneControlNotReady;
    if (!s.enabled) return context.l10n.phoneControlNotEnabled;
    if (blocker == PhoneBlocker.safeMode) return context.l10n.phoneControlSafeModeNotLoaded;
    if (blocker == PhoneBlocker.remoteHost) return context.l10n.phoneControlLocalOnly;
    if (runtime.runtimeMissing) return context.l10n.localEnvPhoneNeedsRuntime;
    if (runtime.phase != RuntimePhase.running) return context.l10n.phoneControlAfterEngineStarts;
    if (!s.a11y.enabled) return context.l10n.phoneControlNeedsAccessibility;
    return context.l10n.phoneControlReady;
  }

  List<Widget> _setup(PhoneStatus status) {
    final a11y = status.a11y;
    final confirmationReady = status.notifications && status.confirmationNotifications != false;
    final showRestricted = !a11y.enabled && (status.device.mayNeedRestrictedSettings || _a11yAttemptFailed);
    return [
      if (!a11y.ok || !confirmationReady)
        ListPageCard(
          title: context.l10n.phoneControlSetup,
          children: [
            if (!a11y.ok)
              PhoneStepRow(
                step: 1,
                done: a11y.ok,
                title: context.l10n.phoneControlAccessibilityService,
                subtitle: a11y.ok
                    ? context.l10n.phoneControlAccessibilityReady
                    : a11y.enabled
                    ? context.l10n.phoneControlAccessibilityReconnect
                    : context.l10n.phoneControlAccessibilityHint,
                trailing: a11y.ok
                    ? const DoneMark()
                    : FixButton(
                        label: a11y.enabled ? context.l10n.phoneControlGoSettings : context.l10n.phoneControlGoEnable,
                        onPressed: _openA11y,
                      ),
              ),
            if (showRestricted)
              ListPageRow(
                icon: AppIcons.unlock,
                iconColor: _a11yAttemptFailed ? DshColors.of(context).warning : null,
                title: context.l10n.phoneControlAccessibilityBlocked,
                subtitle: _a11yAttemptFailed
                    ? context.l10n.phoneControlRestrictedAfterAttempt
                    : context.l10n.phoneControlRestrictedHint,
                subtitleMaxLines: 2,
                onTap: () => _push(const RestrictedSettingsGuidePage()),
              ),
            if (a11y.ok && !confirmationReady)
              PhoneStepRow(
                step: 2,
                done: confirmationReady,
                title: context.l10n.phoneControlNotifications,
                subtitle: status.notifications && status.confirmationNotifications == false
                    ? context.l10n.phoneBackgroundNotificationBlocked
                    : status.notifications
                    ? context.l10n.phoneControlNotificationsPairingHint
                    : context.l10n.phoneControlNotificationsHint,
                trailing: confirmationReady
                    ? DoneMark(label: context.l10n.phoneControlAllowed)
                    : FixButton(label: context.l10n.phoneControlGoEnable, onPressed: _openAppDetails),
              ),
          ],
        ),
      if (a11y.ok && confirmationReady)
        ListPageCard(
          title: context.l10n.phoneControlTry,
          children: [
            ListPageRow(
              icon: AppIcons.readScreen,
              title: context.l10n.phoneControlReadScreen,
              subtitle: a11y.enabled
                  ? context.l10n.phoneControlReadScreenHint
                  : context.l10n.phoneControlEnableAccessibilityFirst,
              trailing: _testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
                    )
                  : null,
              chevron: !_testing && a11y.enabled,
              onTap: a11y.enabled && !_testing ? _test : null,
            ),
          ],
        ),
    ];
  }

  Future<void> _setReturn(bool on) => ref.read(phoneReturnPrefProvider.notifier).set(on);

  Future<void> _setAutoCollapse(bool on) => ref.read(phoneOverlayPrefsProvider.notifier).setAutoCollapse(on);

  Future<void> _setEdgeGlow(bool on) => ref.read(phoneOverlayPrefsProvider.notifier).setEdgeGlow(on);

  Future<void> _setSystemIsland(bool on) => ref.read(phoneOverlayPrefsProvider.notifier).setSystemIsland(on);

  /// 悬浮条: 闲置时不透明度, 闲置时自动收起, 屏幕边缘光效, 用系统灵动岛显示, 完成后返回 dsh-go.
  Widget _floatingBar() {
    final overlay = ref.watch(phoneOverlayPrefsProvider);
    final returnAfterDone = ref.watch(phoneReturnPrefProvider);
    // The switch works only where the phone has its own island; elsewhere the row says why not.
    final island = ref.watch(phoneSystemIslandProvider).value ?? (vendor: false, shows: false);
    final islandOn = island.vendor && overlay.systemIsland;
    return ListPageCard(
      title: context.l10n.phoneFloatingBar,
      children: [
        OverlayOpacityRow(
          percent: overlay.percent,
          onChanged: (p) => unawaited(ref.read(phoneOverlayPrefsProvider.notifier).setIdleOpacity(p / 100)),
        ),
        MergeSemantics(
          child: ListPageRow(
            icon: AppIcons.overlayBall,
            spot: Spots.phoneAutoCollapse,
            subtitle: context.l10n.phoneAutoCollapseHint,
            onTap: () => unawaited(_setAutoCollapse(!overlay.autoCollapse)),
            trailing: Switch.adaptive(value: overlay.autoCollapse, onChanged: (v) => unawaited(_setAutoCollapse(v))),
          ),
        ),
        MergeSemantics(
          child: ListPageRow(
            icon: AppIcons.edgeGlow,
            spot: Spots.phoneEdgeGlow,
            subtitle: context.l10n.phoneEdgeGlowHint,
            onTap: () => unawaited(_setEdgeGlow(!overlay.edgeGlow)),
            trailing: Switch.adaptive(value: overlay.edgeGlow, onChanged: (v) => unawaited(_setEdgeGlow(v))),
          ),
        ),
        MergeSemantics(
          child: ListPageRow(
            icon: AppIcons.systemIsland,
            spot: Spots.phoneSystemIsland,
            subtitle: !island.vendor
                ? context.l10n.phoneSystemIslandUnsupported
                : islandOn && !island.shows
                ? context.l10n.phoneSystemIslandOff
                : context.l10n.phoneSystemIslandHint,
            subtitleMaxLines: 3,
            onTap: island.vendor ? () => unawaited(_setSystemIsland(!overlay.systemIsland)) : null,
            trailing: Switch.adaptive(
              value: islandOn,
              onChanged: island.vendor ? (v) => unawaited(_setSystemIsland(v)) : null,
            ),
          ),
        ),
        MergeSemantics(
          child: ListPageRow(
            icon: AppIcons.returnToApp,
            spot: Spots.phoneReturn,
            subtitle: context.l10n.phoneReturnAfterDoneHint,
            onTap: () => unawaited(_setReturn(!returnAfterDone)),
            trailing: Switch.adaptive(value: returnAfterDone, onChanged: (v) => unawaited(_setReturn(v))),
          ),
        ),
      ],
    );
  }

  Widget _localOcr(PhoneState state) {
    final enabled = state.policies?.localOcrEnabled;
    final l10n = context.l10n;
    return ListPageCard(
      children: [
        ListPageRow(
          title: l10n.phoneLocalOcrTitle,
          titleMaxLines: 2,
          trailing: enabled == null
              ? null
              : Switch(
                  key: const ValueKey('phone-local-ocr-switch'),
                  value: enabled,
                  onChanged: _ocrSaving ? null : (value) => unawaited(_setLocalOcr(value)),
                ),
          chevron: false,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            enabled == null ? l10n.phoneLocalOcrUnknown : l10n.phoneLocalOcrSummary,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('phone-local-ocr-privacy'),
            onPressed: () => showAppDialog<void>(
              context: context,
              builder: (dialog) => AlertDialog(
                title: Text(l10n.phoneLocalOcrPrivacyDetails),
                content: SingleChildScrollView(
                  child: Text('${l10n.phoneLocalOcrDisclosure}\n\n${l10n.phoneLocalOcrDetails}'),
                ),
                actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonClose))],
              ),
            ),
            child: Text(l10n.phoneLocalOcrPrivacyDetails),
          ),
        ),
      ],
    );
  }

  List<Widget> _rules(PhoneState state) {
    final policies = state.policies;
    final apps = policies == null
        ? context.l10n.phoneControlLoading
        : context.l10n.phoneControlPolicySummary(
            policies.denyPackages.length,
            policies.confirmEveryWritePackages.length,
          );
    return [
      ListPageCard(
        title: context.l10n.phoneControlRules,
        children: [
          ListPageRow(
            icon: AppIcons.appRules,
            spot: SettingsIndex.entry(SettingsPageId.phoneAppRules),
            subtitle: apps,
            onTap: () => _push(const PhoneAppRulesPage()),
          ),
          ListPageRow(
            icon: policies?.confirmMode.icon ?? AppIcons.askFirst,
            spot: Spots.phoneConfirm,
            subtitle: policies?.confirmMode.label ?? context.l10n.phoneControlLoading,
            chevron: policies != null,
            onTap: policies == null ? null : () => _pickConfirmMode(policies.confirmMode),
          ),
          ListPageRow(
            icon: AppIcons.unlocks,
            iconColor: policies?.unlocks.isNotEmpty ?? false ? DshColors.of(context).warning : null,
            spot: SettingsIndex.entry(SettingsPageId.phoneUnlocks),
            subtitle: phoneUnlockSummary(context.l10n, policies) ?? context.l10n.phoneControlLoading,
            onTap: () => _push(const PhoneUnlockPage()),
          ),
          ListPageRow(
            icon: AppIcons.allowed,
            spot: SettingsIndex.entry(SettingsPageId.phoneAlwaysAllow),
            subtitle: phoneAlwaysAllowSummary(context.l10n, policies) ?? context.l10n.phoneControlLoading,
            onTap: policies == null ? null : () => _push(const PhoneAlwaysAllowPage()),
          ),
        ],
      ),
    ];
  }

  Widget _recentActions(PhoneState state) {
    final recent = state.log.take(PhoneControlScreen.recentCount).toList();
    return ListPageCard(
      title: context.l10n.phoneControlRecentActions,
      children: [
        if (recent.isEmpty)
          ListPageRow(
            icon: AppIcons.history,
            iconColor: DshColors.of(context).textTertiary,
            title: context.l10n.phoneActionLogEmpty,
            subtitle: context.l10n.phoneControlRecentActionsHint,
          )
        else ...[
          for (final e in recent) ActionLogRow(e),
          ListPageRow(
            // Empty glyph slot: the words line up with the titles above.
            leading: const SizedBox.shrink(),
            title: context.l10n.phoneControlAllActions,
            titleStyle: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(fontSize: 15, height: 1.4, color: Theme.of(context).colorScheme.primary),
            onTap: () => _push(const PhoneActionLogPage()),
          ),
        ],
      ],
    );
  }
}

class _BlockerNote extends ConsumerWidget {
  const _BlockerNote(this.blocker);

  final PhoneBlocker blocker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final host = ref.watch(activeHostProvider);
    final hostName = ref.watch(hostNameProvider(host));
    return switch (blocker) {
      PhoneBlocker.notReady => PhoneNote(
        tone: NoteTone.warn,
        title: l10n.phoneControlNotReady,
        text: l10n.phoneControlModuleNotReady,
      ),
      PhoneBlocker.safeMode => PhoneNote(
        tone: NoteTone.warn,
        icon: AppIcons.safeMode,
        title: l10n.phoneControlSafeModeUnavailable,
        text: l10n.phoneControlSafeModeHint,
      ),
      PhoneBlocker.remoteHost => PhoneNote(
        icon: AppIcons.remoteHost,
        title: l10n.phoneControlRemoteHost,
        text: l10n.phoneControlRemoteHint(hostName ?? l10n.commonRemoteHost),
      ),
    };
  }
}

/// Shown while the switch is off: what turning it on gives, in three lines.
class _WhatItDoes extends StatelessWidget {
  const _WhatItDoes();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListPageCard(
      title: l10n.phoneControlCapabilities,
      children: [
        ListPageRow(
          icon: AppIcons.alarmClock,
          title: l10n.phoneControlIntents,
          subtitle: l10n.phoneControlNoExtraPermissions,
        ),
        ListPageRow(
          icon: AppIcons.readScreen,
          title: l10n.phoneControlReadToTable,
          subtitle: l10n.phoneControlNeedsAccessibilityHint,
        ),
        ListPageRow(
          icon: AppIcons.phoneControl,
          title: l10n.phoneControlTapType,
          subtitle: l10n.phoneControlSensitiveHint,
        ),
      ],
    );
  }
}

/// 确认方式's 「这些由你来操作」: the hard rules still in place (a lifted one
/// drops out), the 不碰 list, and where each is changed. The lines start where
/// the rows' titles do.
class _YoursGroup extends ConsumerWidget {
  const _YoursGroup({required this.onLink});

  final ValueChanged<_ConfirmLink> onLink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final policies = ref.watch(phoneProvider.select((s) => s.policies));
    final lifted = policies?.unlocks ?? const <PhoneUnlock>{};
    final lines = [
      for (final unlock in PhoneUnlock.values)
        if (!lifted.contains(unlock)) unlock.yours(l10n),
      l10n.phoneYoursDenyList,
    ];
    return SheetGroup(
      key: const ValueKey('confirm-yours'),
      title: l10n.phoneYoursTitle,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ListPageRow.horizontal, vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: ListPageRow.glyphSlot,
                        height: (theme.textTheme.bodyMedium?.fontSize ?? 14) * 1.5,
                        child: Center(
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: theme.colorScheme.onSurfaceVariant,
                              shape: const CircleBorder(),
                            ),
                            child: const SizedBox.square(dimension: 4),
                          ),
                        ),
                      ),
                      const SizedBox(width: ListPageRow.gap),
                      Expanded(child: Text(line, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        ListPageRow(
          icon: AppIcons.appRules,
          spot: SettingsIndex.entry(SettingsPageId.phoneAppRules),
          subtitle: policies == null
              ? l10n.phoneControlLoading
              : l10n.phoneControlPolicySummary(policies.denyPackages.length, policies.confirmEveryWritePackages.length),
          onTap: () => onLink(_ConfirmLink.appRules),
        ),
        ListPageRow(
          icon: AppIcons.unlocks,
          spot: SettingsIndex.entry(SettingsPageId.phoneUnlocks),
          subtitle: phoneUnlockSummary(l10n, policies) ?? l10n.phoneControlLoading,
          onTap: () => onLink(_ConfirmLink.unlocks),
        ),
      ],
    );
  }
}

/// 手机技能 · 已学会 6 项 · 2 份待确认 (docs/design/phone-skills.md §6.1).
class _SkillsRow extends ConsumerWidget {
  const _SkillsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final data = ref.watch(phoneSkillsProvider).value;
    final skills = data?.skills.length ?? 0;
    final drafts = data?.drafts.length ?? 0;
    return ListPageRow(
      key: const ValueKey('phone-skills'),
      icon: AppIcons.skill,
      spot: SettingsIndex.entry(SettingsPageId.phoneSkills),
      subtitle: data == null
          ? null
          : drafts > 0
          ? l10n.phoneSkillsSummaryDrafts(skills, drafts)
          : skills > 0
          ? l10n.phoneSkillsSummary(skills)
          : l10n.phoneSkillsSummaryNone,
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => PhoneSkillsPage(drafts: drafts > 0 && skills == 0))),
    );
  }
}
