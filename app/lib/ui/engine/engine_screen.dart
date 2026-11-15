import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/local_footprint.dart';
import '../../state/android_features.dart';
import '../../state/engine_control.dart';
import '../../state/runtime_capabilities_state.dart';
import '../../state/safe_mode_state.dart';
import '../../state/settings_state.dart';
import '../common/app_dialog.dart';
import '../common/page_hero.dart';
import '../onboarding/local_install.dart';
import '../safe_mode/engine_failure_card.dart';
import '../safe_mode/safe_mode_card.dart';
import '../safe_mode/safe_mode_settings.dart';
import '../settings/background_guide_page.dart';
import '../settings/diagnostics_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/local_web_screen.dart';
import 'engine_status.dart';
import 'engine_capabilities.dart';
import 'linux_section.dart';
import 'local_uninstall.dart';
import 'log_view.dart';
import 'workspace_recovery_settings.dart';

/// `rN-dsh…-HASH` → `rN · HASH8`; anything else is shown as is.
String shortRuntimeVersion(String? v) {
  if (v == null || v.isEmpty) return '—';
  final m = RegExp(r'^(r\d+)-.*-([0-9a-f]{8,})$').firstMatch(v);
  return m == null ? v : '${m.group(1)} · ${m.group(2)!.substring(0, 8)}';
}

/// One line under the engine's name: what it is doing right now.
String engineDetail(RuntimeStatus status) => switch (status.phase) {
  RuntimePhase.running =>
    status.inSafeMode
        ? appL10n.phoneEngineSafeAt(Uri.tryParse(status.baseUrl ?? '')?.authority ?? appL10n.commonThisPhone)
        : appL10n.phoneEngineRunningAt(Uri.tryParse(status.baseUrl ?? '')?.authority ?? appL10n.commonThisPhone),
  RuntimePhase.starting =>
    status.inSafeMode
        ? appL10n.phoneEngineStartingSafeEllipsis
        : status.tidyingFiles
        ? appL10n.phoneEngineTidyingFilesEllipsis
        : appL10n.phoneEngineStartingEllipsis,
  RuntimePhase.stopping =>
    isLocalStartupFailure(status)
        ? appL10n.phoneStartupFailureStoppingDetail(
            humanizeRuntimeError(status.error) ?? appL10n.phoneEngineErrorSeeLogs,
          )
        : appL10n.phoneEngineStoppingEllipsis,
  RuntimePhase.installed => status.inSafeMode ? appL10n.phoneEngineStoppedNextSafe : appL10n.commonStopped,
  RuntimePhase.installing => appL10n.phoneEngineInstallingRuntime,
  RuntimePhase.notInstalled => appL10n.phoneEngineRuntimeNotInstalled,
  RuntimePhase.error =>
    isLocalStartupFailure(status)
        ? humanizeRuntimeError(status.error) ?? appL10n.phoneEngineErrorSeeLogs
        : status.failure != null
        ? failureOneLiner(status.failure!)
        : humanizeRuntimeError(status.error) ?? appL10n.phoneEngineErrorSeeLogs,
};

/// The local engine: a status ring with the
/// versions, start / stop / restart, the live log in a dark terminal card, and
/// the engine's own settings.
class EngineScreen extends ConsumerWidget {
  const EngineScreen({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(localRuntimeProvider);
    final status = state.status;
    final guest = ref.watch(androidSystemFeaturesProvider);
    final view = EngineStatusView.of(state);
    final settings = ref.watch(settingsProvider);
    final colors = DshColors.of(context);
    final logHeight = (MediaQuery.sizeOf(context).height * 0.42).clamp(260.0, 520.0);
    final failureCard = EngineFailureCard.visibleFor(status);
    final error = status.phase == RuntimePhase.error;
    // Nothing on this phone yet: no log to show, nothing to reset.
    final missing = status.runtimeMissing;

    return AppPage(
      title: l10n.phoneEngineTitle,
      actions: [
        GlassIconButton(
          icon: AppIcons.webApp,
          tooltip: l10n.commonWeb,
          onPressed: status.phase == RuntimePhase.running ? () => _push(context, const LocalWebScreen()) : null,
        ),
      ],
      hero: PageHero(
        leading: EngineRing(tone: view.tone),
        title: l10n.phoneEngineLocal,
        subtitle: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.standard),
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
          child: Text(
            engineDetail(status),
            key: ValueKey(engineDetail(status)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: error ? TextStyle(color: colors.danger) : null,
          ),
        ),
        // Leading letters keep the figures whole (a bare number would be read
        // as "number + unit").
        stats: [
          (status.dshVersion == null ? '—' : 'v${status.dshVersion}', 'DSH'),
          (status.nodeVersion == null ? '—' : 'v${status.nodeVersion}', 'Node.js'),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            if (!failureCard)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: EngineActions(phase: status.phase),
              ),
            // iOS gives each run a new Environment, so only HarmonyOS has this limit.
            if (ref.watch(operatingSystemProvider) == 'ohos' && !missing)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(l10n.engineStartReopensApp, style: Theme.of(context).textTheme.bodySmall),
              ),
            const EngineFailureCard(padding: EdgeInsets.fromLTRB(16, 0, 16, 16)),
            for (final issue in state.relocation)
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: _RelocationNote(issue.text)),
            const SafeModeCard(padding: EdgeInsets.fromLTRB(16, 0, 16, 16)),
            SettingsSection(
              title: l10n.hubEngineStartup,
              children: [
                SettingsSwitchTile(
                  spot: Spots.autoStart,
                  value: settings.autoStartLocal,
                  onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).setAutoStartLocal(v)),
                ),
                if (guest) ...[
                  const SafeModeAutoSwitch(icon: null),
                  const SafeModeSettingsTiles(showAutoSwitch: false, icon: false),
                ],
              ],
            ),
            if (!missing)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: TerminalCard(
                  title: l10n.phoneEngineLogs,
                  lines: ref.watch(localRuntimeLogsProvider),
                  height: logHeight,
                ),
              ),
            // Their home is 设置; the way in from here keeps the name.
            SettingsSection(
              title: l10n.commonMore,
              children: [
                SettingsTile(
                  spot: SettingsIndex.entry(SettingsPageId.background),
                  subtitle: guest ? l10n.phoneEngineKeepAliveHint : l10n.harmonyEngineBackgroundHint,
                  onTap: () => _push(context, const BackgroundGuidePage()),
                ),
                SettingsTile(
                  spot: SettingsIndex.entry(SettingsPageId.diagnostics),
                  subtitle: l10n.phoneEngineDiagnosticsHint,
                  onTap: () => _push(context, const DiagnosticsPage()),
                ),
              ],
            ),
            // iOS runs what the virtual shell can't in Linux, installed here on demand.
            if (Theme.of(context).platform == TargetPlatform.iOS) const LinuxSection(),
            SettingsSection(
              title: l10n.phoneEngineRuntime,
              children: [
                InfoRow(
                  label: l10n.commonVersion,
                  value: shortRuntimeVersion(status.installedVersion ?? status.bundledVersion),
                  mono: true,
                ),
                InfoRow(label: l10n.phoneEngineArchitecture, value: status.abi ?? '—', mono: true),
                ...engineCapabilityRows(l10n, ref.watch(runtimeCapabilitiesProvider).value),
              ],
            ),
            // A way around a broken index, next to the other ways out of trouble.
            if (!missing) const WorkspaceRecoverySettings(),
            if (!missing && ref.watch(engineResetProvider))
              SettingsSection(
                children: [
                  _ResetRow(enabled: !status.phase.isBusy),
                  LocalUninstallRow(enabled: !status.phase.isBusy),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// 「启动 · 停止 · 重启」: three equal-width capsules. Starting is the one
/// primary action when the engine is down; while it runs all three are quiet.
class EngineActions extends ConsumerWidget {
  const EngineActions({super.key, required this.phase});

  final RuntimePhase phase;

  /// Capsule height.
  static const height = 44.0;
  static const gap = 10.0;

  Future<void> _confirmStop(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.phoneEngineStopTitle),
        content: Text(context.l10n.phoneEngineStopBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonStop),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(localRuntimeProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final container = ProviderScope.containerOf(context, listen: false);
    // iOS can retain a native/reset error after the installed runtime is gone.
    // Keep the error visible, but offer installation instead of another start.
    final iosNeedsInstall =
        phase == RuntimePhase.error &&
        ref.watch(operatingSystemProvider) == 'ios' &&
        ref.watch(localRuntimeProvider.select((s) => s.status.installedVersion)) == null;
    if (phase == RuntimePhase.notInstalled || iosNeedsInstall) {
      final available = ref.watch(localRuntimeProvider.select((s) => s.available));
      return _Capsule(
        icon: available ? AppIcons.download : AppIcons.computer,
        label: localMissingCopy(l10n, available: available).action,
        primary: true,
        onTap: () => unawaited(openLocalInstall(context)),
      );
    }
    final running = phase == RuntimePhase.running;
    final down = phase == RuntimePhase.installed || phase == RuntimePhase.error;
    return Row(
      children: [
        Expanded(
          child: _Capsule(
            icon: AppIcons.play,
            label: phase == RuntimePhase.error ? l10n.phoneEngineStartAgain : l10n.phoneEngineStart,
            busy: phase == RuntimePhase.starting || phase == RuntimePhase.installing,
            primary: down,
            onTap: down ? () => unawaited(EngineControl.restart(container)) : null,
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: _Capsule(
            icon: AppIcons.stop,
            label: l10n.commonStop,
            busy: phase == RuntimePhase.stopping,
            onTap: running ? () => _confirmStop(context, ref) : null,
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: _Capsule(
            icon: AppIcons.restart,
            label: l10n.phoneEngineRestart,
            onTap: running ? () => unawaited(EngineControl.restart(container)) : null,
          ),
        ),
      ],
    );
  }
}

/// One engine action: a stadium with an icon and a short label. Quiet (a soft
/// neutral fill) unless [primary]; dims when disabled; [busy] swaps the icon
/// for a small ring.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.icon, required this.label, this.onTap, this.primary = false, this.busy = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enabled = onTap != null;
    final bg = primary && enabled
        ? scheme.primary
        : (dark ? Colors.white.withValues(alpha: 0.08) : scheme.onSurface.withValues(alpha: 0.06));
    final fg = primary && enabled ? scheme.onPrimary : scheme.onSurface;
    final duration = AppMotion.of(context, AppMotion.standard);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: enabled || busy ? 1 : 0.42,
        duration: duration,
        child: Material(
          color: Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: AnimatedContainer(
            duration: duration,
            curve: AppMotion.std,
            constraints: const BoxConstraints(minHeight: EngineActions.height),
            decoration: ShapeDecoration(color: bg, shape: const StadiumBorder()),
            child: InkWell(
              onTap: onTap,
              splashFactory: rowSplash(context),
              highlightColor: fg.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 20,
                      child: busy
                          ? Padding(
                              padding: const EdgeInsets.all(2.5),
                              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                            )
                          : Icon(icon, size: 20, color: fg),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「重置运行环境」: the dialog says what goes and offers to keep the parts
/// the user wrote (界面配置和技能, on by default) or installed (插件和设置).
class _ResetRow extends ConsumerWidget {
  const _ResetRow({required this.enabled});

  final bool enabled;

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final keep = await showAppDialog<ResetKeep>(context: context, builder: (_) => const _ResetDialog());
    if (keep == null || !context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(localRuntimeProvider.notifier).resetKeeping(keep);
      // The root gate shows setup again once the phase reads notInstalled.
      navigator.popUntil((r) => r.isFirst);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.phoneEngineResetFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return SettingsTile(
      icon: AppIcons.clearAll,
      tinted: false,
      danger: enabled,
      spot: Spots.engineReset,
      subtitle: l10n.phoneEngineResetHint,
      chevron: false,
      onTap: enabled ? () => _reset(context, ref) : null,
    );
  }
}

/// What a reset with [keep] deletes, as one phrase: 「对话、工作区、插件和设置」.
@visibleForTesting
String resetDeletes(ResetKeep keep) {
  return switch ((keep.uiAndSkills, keep.pluginsAndSettings)) {
    (true, true) => appL10n.phoneResetDeletesChatsWorkspaces,
    (true, false) => appL10n.phoneResetDeletesWithPlugins,
    (false, true) => appL10n.phoneResetDeletesWithUi,
    (false, false) => appL10n.phoneResetDeletesEverything,
  };
}

/// Pops the chosen [ResetKeep], or null on 取消.
class _ResetDialog extends StatefulWidget {
  const _ResetDialog();

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  ResetKeep _keep = ResetKeep.suggested;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return AlertDialog(
      title: Text(l10n.phoneEngineResetTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch ((_keep.uiAndSkills, _keep.pluginsAndSettings)) {
            (true, true) => l10n.phoneResetBodyChatsWorkspaces,
            (true, false) => l10n.phoneResetBodyWithPlugins,
            (false, true) => l10n.phoneResetBodyWithUi,
            (false, false) => l10n.phoneResetBodyEverything,
          }),
          const SizedBox(height: 8),
          Text(l10n.phoneResetAlsoDeletes),
          const SizedBox(height: 12),
          _KeepOption(
            label: l10n.phoneEngineKeepUiSkills,
            value: _keep.uiAndSkills,
            onChanged: (v) => setState(() => _keep = _keep.copyWith(uiAndSkills: v)),
          ),
          _KeepOption(
            label: l10n.phoneEngineKeepPluginsSettings,
            value: _keep.pluginsAndSettings,
            onChanged: (v) => setState(() => _keep = _keep.copyWith(pluginsAndSettings: v)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
          onPressed: () => Navigator.pop(context, _keep),
          child: Text(l10n.phoneEngineDeleteReset),
        ),
      ],
    );
  }
}

/// A whole-row checkbox: the box's edge lines up with the text above it, and
/// it stays neutral so the danger button is the dialog's one colour.
class _KeepOption extends StatelessWidget {
  const _KeepOption({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  static const box = 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: AppShape.radiusXs,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              // The box paints centred in its own tap area: lay out just the box.
              SizedBox.square(
                dimension: box,
                child: OverflowBox(
                  maxWidth: kMinInteractiveDimension,
                  maxHeight: kMinInteractiveDimension,
                  child: Checkbox(
                    value: value,
                    onChanged: (v) => onChanged(v ?? false),
                    fillColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected) ? scheme.onSurface : Colors.transparent,
                    ),
                    checkColor: scheme.surface,
                    side: BorderSide(color: colors.textTertiary, width: 1.5),
                    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A lasting note beside the engine's controls: the toast is gone by the time someone comes
/// looking for old conversations here. It offers nothing to press, since the data is safe as it is.
class _RelocationNote extends StatelessWidget {
  const _RelocationNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(color: colors.warningContainer, shape: AppShape.card),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warning, size: 20, color: colors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onWarningContainer, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
