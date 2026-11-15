// 设置 › 权限: the native mirror of the official permission surfaces
// (`dsh-client-ui-permission-presets`) — the current session's preset (the
// `/permission` popup) and the default for new sessions, where 完全权限 on
// this phone is the app's own switch (it was 「自动执行命令」) — and what AI may
// do on the phone: its files, and how phone control confirms.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/android_features.dart';
import '../../state/connection_state.dart';
import '../../state/engine_settings_state.dart' show describeSettingsError;
import '../../state/features_state.dart';
import '../../state/settings_state.dart';
import '../../runtime/runtime_bridge.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/phone_state.dart';
import '../common/ask_ai.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../phone/phone_control_screen.dart' show PhoneConfirmModeText;
import '../settings/index/settings_pages.dart' show openSpot;
import '../settings/index/spots.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'feature_format.dart';
import 'feature_widgets.dart';

/// Writes [value] as the preset new conversations start with (the risk
/// notice, if any, was shown already). On the phone outside safe mode full
/// access is the app's 「自动执行命令」 switch; any other default turns it
/// off. Null when it worked, else the toast to show.
Future<String?> writePermissionDefault(WidgetRef ref, DshClient client, String value, int revision) async {
  final localNormal =
      ref.read(activeConnectionProvider).value?.isLocal == true && !ref.read(localRuntimeProvider).status.inSafeMode;
  final settings = ref.read(settingsProvider.notifier);
  try {
    if (localNormal && value == 'danger-full-access') {
      await settings.setAutoApproveCommands(true);
    } else {
      await client.setSetting('permission', ['defaultPreset'], value, expectedRevision: revision);
      if (localNormal) await settings.setAutoApproveCommands(false);
    }
    return null;
  } catch (e) {
    debugPrint('Permission default failed: $e');
    return describeSettingsError(e);
  }
}

/// Full access and auto review skip confirmations: they ask first, like the
/// official picker.
Future<bool> confirmPermission(BuildContext context, String value) => switch (value) {
  'danger-full-access' => confirmRisk(context, RiskNotices.fullAccess),
  'auto' => confirmRisk(context, RiskNotices.autoReview),
  _ => Future.value(true),
};

class PermissionPage extends ConsumerStatefulWidget {
  const PermissionPage({super.key, this.sessionId});

  /// The conversation whose preset the first group switches; null shows
  /// only the default for new conversations.
  final String? sessionId;

  @override
  ConsumerState<PermissionPage> createState() => _PermissionPageState();
}

class _PermissionPageState extends ConsumerState<PermissionPage> {
  bool _busy = false;

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Full access (and auto review) skip confirmations: ask first, like the
  /// official picker.
  Future<bool> _confirm(String value) => confirmPermission(context, value);

  Future<void> _setCurrent(String value) async {
    final sessionId = widget.sessionId;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (sessionId == null || client == null || _busy) return;
    if (!await _confirm(value) || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await client.setPermissionPreset(sessionId, value);
      if (!result.success && mounted) _toast(context.l10n.featuresSwitchFailed);
    } catch (e) {
      if (mounted) _toast(featureErrorText(context.l10n.featuresSwitchFailed, e));
    } finally {
      ref.invalidate(permissionStateProvider(sessionId));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setDefault(String value, int? revision) async {
    final owner = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final state = ref.read(permissionStateProvider(widget.sessionId)).value;
    final allowed = state?.defaultOptions ?? state?.options.where((o) => o.value != 'auto');
    if (client == null || _busy || revision == null || allowed?.any((o) => o.value == value) != true) return;
    if (!await _confirm(value) || !mounted || ref.read(activeHostProvider) != owner) return;
    setState(() => _busy = true);
    try {
      final problem = await writePermissionDefault(ref, client, value, revision);
      if (problem != null && mounted) _toast(problem);
    } finally {
      ref.invalidate(permissionStateProvider(widget.sessionId));
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 访问手机文件: what AI may touch first, then the system's own grant; the
  /// engine restarts so its mounts follow.
  Future<void> _onPhoneFiles(bool next) async {
    final l10n = context.l10n;
    final notifier = ref.read(settingsProvider.notifier);
    if (next) {
      final ok = await confirmRisk(context, RiskNotices.phoneFiles);
      if (!ok || !mounted) return;
      final bridge = ref.read(runtimeBridgeProvider);
      var access = await bridge.requestStorage();
      if (!access.granted && access.permission && !access.legacy) {
        // Device ignores legacy storage: fall back to the "All files access" page.
        await bridge.openAllFilesAccess();
        access = await bridge.storageStatus();
      }
      if (!access.granted) {
        if (mounted) _toast(l10n.hubSettingsStorageDenied);
        return;
      }
    }
    await notifier.setPhoneStorage(next);
    // Binds are fixed at launch: restart a running engine so the change applies.
    if (ref.read(localRuntimeProvider).status.phase == RuntimePhase.running && mounted) {
      unawaited(EngineControl.restart(ProviderScope.containerOf(context, listen: false)));
    }
  }

  Future<void> _resetDefault(int revision) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null || _busy) return;
    setState(() => _busy = true);
    try {
      await client.mutateSettings('permission', const [
        SettingsOp.unset(['defaultPreset']),
      ], expectedRevision: revision);
    } catch (error) {
      if (mounted) _toast(describeSettingsError(error));
    } finally {
      if (mounted) {
        ref.invalidate(permissionStateProvider(widget.sessionId));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connected = ref.watch(activeConnectionProvider).value != null;
    final state = ref.watch(permissionStateProvider(widget.sessionId));
    final value = state.value;
    final autoApprove = ref.watch(settingsProvider.select((s) => s.autoApproveCommands));
    final isLocal = ref.watch(activeConnectionProvider).value?.isLocal ?? true;
    // 「自动执行命令」 opens every new conversation on the phone with full access.
    final forced = isLocal && autoApprove && !ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode));

    List<Widget> options(List<PermissionOption> choices, String? selected, ValueChanged<String>? onPick) => [
      for (final o in choices)
        _PresetTile(
          title: permissionName(o.value, o.name),
          subtitle: permissionHint(o.value, o.description),
          selected: o.value == selected,
          onTap: _busy || onPick == null ? null : () => onPick(o.value),
        ),
    ];

    final phoneFiles = ref.watch(settingsProvider.select((s) => s.phoneStorage));
    final android = ref.watch(androidSystemFeaturesProvider);
    final confirm = android ? ref.watch(phoneProvider.select((s) => s.policies?.confirmMode)) : null;
    final phone = ListPageCard(
      title: l10n.hubPermissionPhone,
      children: [
        // The phone's storage is this phone's engine's to mount.
        if (ref.watch(activeHostProvider).isLocal)
          MergeSemantics(
            child: ListPageRow(
              spot: Spots.phoneFiles,
              subtitle: l10n.hubSettingsPhoneFilesHint,
              onTap: () => unawaited(_onPhoneFiles(!phoneFiles)),
              trailing: Switch.adaptive(value: phoneFiles, onChanged: (v) => unawaited(_onPhoneFiles(v))),
            ),
          ),
        // The control itself stays on 手机操控: this opens it at that row.
        ListPageRow(
          spot: Spots.permissionPhoneConfirm,
          value: confirm?.label,
          onTap: () => unawaited(openSpot(context, Spots.phoneConfirm)),
        ),
      ],
    );

    return AppPage.list(
      title: l10n.featuresPermissions,
      subtitle: Text(l10n.featuresPermissionsSubtitle),
      actions: const [AskAiButton(AskAiTopic.fullAccess)],
      children: [
        if (!connected)
          const FeatureOffline()
        else if (value == null && state.hasError)
          FeatureMessage.error(
            title: l10n.featuresPermissionsReadFailed,
            error: state.error!,
            onRetry: () => ref.invalidate(permissionStateProvider(widget.sessionId)),
          )
        else if (value == null)
          const FeatureLoading()
        else ...[
          if (widget.sessionId != null && !value.invalidDefault) ...[
            ListPageCard(
              title: l10n.featuresCurrentChat,
              spot: Spots.permissionCurrent,
              children: options(value.options, value.current, (v) => unawaited(_setCurrent(v))),
            ),
            if (value.current == 'custom') FeatureNote(l10n.featuresPermissionCustomHint),
            const SizedBox(height: 24),
          ],
          if (value.invalidDefault)
            FeatureMessage(
              icon: AppIcons.permissions,
              title: l10n.featuresPermissionResetHint,
              action: switch (value.defaultRevision) {
                final revision? => (l10n.featuresPermissionResetDefault, () => unawaited(_resetDefault(revision))),
                null => null,
              },
            )
          else
            ListPageCard(
              title: l10n.featuresNewChatDefault,
              spot: Spots.permissionDefault,
              children: options(
                value.defaultOptions ?? value.options.where((o) => o.value != 'auto').toList(),
                forced ? 'danger-full-access' : value.hostDefault,
                value.defaultRevision == null ? null : (v) => unawaited(_setDefault(v, value.defaultRevision)),
              ),
            ),
        ],
        if (android) ...[const SizedBox(height: 24), phone],
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({required this.title, required this.selected, required this.onTap, this.subtitle});

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: ListPageRow(
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 2,
        onTap: onTap,
        trailing: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.quick),
          child: selected
              ? Icon(AppIcons.selected, key: const ValueKey(true), size: 22, color: scheme.primary)
              : const SizedBox.square(dimension: 22, key: ValueKey(false)),
        ),
      ),
    );
  }
}
