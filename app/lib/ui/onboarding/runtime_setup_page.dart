import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/android_features.dart';
import '../../state/notify_state.dart';
import '../common/app_sheet.dart';
import '../common/progress_halo.dart';
import '../engine/diagnostics_export_card.dart';
import '../engine/engine_status.dart';
import '../engine/log_view.dart';
import '../shell/adaptive/adaptive_layout.dart' show WindowClass;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'onboarding_scaffold.dart';
import 'runtime_choice.dart';
import 'setup_progress.dart';

enum _SetupView { choose, waiting, installing, done, failed }

/// Unpacks the bundled Linux runtime (about 150 MB of xz into about 750 MB;
/// the exact figures are in its manifest, see `local_footprint.dart`).
///
/// The screen is meant to be calm: one slowly filling halo, a percentage, one
/// short line about what is happening, and a rough time estimate. Logs are one
/// tap away but never on screen by default. On failure the halo turns the danger
/// colour and the page offers retry, logs and a diagnostics export.
///
/// With [choose], a runtime that is not there yet is not installed at once:
/// the page first asks where DSH runs, on this phone or on a remote host
/// ([RuntimeChoiceView]).
///
/// With [waiting], it is first run's last stop: everything else is set and
/// only the unpack is left (docs/design/onboarding-parallel-setup.md).
class RuntimeSetupPage extends ConsumerStatefulWidget {
  const RuntimeSetupPage({
    super.key,
    required this.onDone,
    this.choose = false,
    this.onRemote,
    this.onLocal,
    this.waiting = false,
    this.leading,
  });

  /// Called once, shortly after the runtime is installed.
  final VoidCallback onDone;

  /// Ask first (first run): this phone or a remote host.
  final bool choose;

  /// The way to a remote host instead of installing: the second choice
  /// ([choose]) and, after a failed install, a quiet 「改用远程主机」.
  final VoidCallback? onRemote;

  /// Picked 「本机」 in the choice: the caller starts the unpack and moves on
  /// while it runs. Null: this page installs and shows the progress.
  final VoidCallback? onLocal;

  /// Set up while unpacking and done with it: the progress says it will go
  /// on by itself (and, when it can, that a notification will say so).
  final bool waiting;

  /// Top-left key (the back key when opened from settings).
  final Widget? leading;

  @override
  ConsumerState<RuntimeSetupPage> createState() => _RuntimeSetupPageState();
}

class _RuntimeSetupPageState extends ConsumerState<RuntimeSetupPage> {
  bool _upgrade = false;
  bool _finishing = false;
  Timer? _finishTimer;
  bool _notifyPrimed = false;

  /// The person picked 「本机」 (or nothing was asked): leaves the choice.
  bool _installRequested = false;

  /// Asks where DSH runs before installing.
  bool get _asks => widget.choose && widget.onRemote != null;

  @override
  void initState() {
    super.initState();
    final status = ref.read(localRuntimeProvider).status;
    _upgrade = status.phase == RuntimePhase.notInstalled && status.installedVersion != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final phase = ref.read(localRuntimeProvider).status.phase;
      if (phase == RuntimePhase.notInstalled && !_asks) _install();
    });
  }

  /// Through the one entry ([runtimeInstallProvider]): a request while an
  /// unpack is on its way is that same unpack.
  void _install({bool dropKept = false}) {
    setState(() => _installRequested = true);
    // Sample the time left from the start.
    ref.read(installEtaProvider);
    unawaited(ref.read(runtimeInstallProvider.notifier).install(dropKept: dropKept));
  }

  _SetupView _viewFor(LocalRuntimeState state, {required bool launchFailed}) {
    final status = state.status;
    final installedCurrent = status.installedVersion != null && status.installedVersion == status.bundledVersion;
    return switch (status.phase) {
      RuntimePhase.installing => _SetupView.installing,
      RuntimePhase.installed ||
      RuntimePhase.starting ||
      RuntimePhase.running ||
      RuntimePhase.stopping => _SetupView.done,
      RuntimePhase.error => installedCurrent ? _SetupView.done : _SetupView.failed,
      RuntimePhase.notInstalled =>
        launchFailed
            ? _SetupView.failed
            : _asks && !_installRequested
            ? _SetupView.choose
            : _SetupView.waiting,
    };
  }

  void _primeNotifications(RuntimeProgressEvent? progress) {
    if (progress == null || _notifyPrimed) return;
    // Reading the status creates the notification channels, which is what
    // raises Android 13's permission prompt: let it come while this page
    // waits rather than over the connect step.
    _notifyPrimed = true;
    unawaited(ref.read(notifyChannelProvider).status());
  }

  void _scheduleFinish() {
    if (_finishing) return;
    _finishing = true;
    // Let the ring fill and the check land before moving on.
    _finishTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _finishTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(localRuntimeProvider.select((s) => s.progress), (_, next) => _primeNotifications(next));
    final state = ref.watch(localRuntimeProvider);
    final view = _viewFor(state, launchFailed: ref.watch(runtimeInstallProvider));
    if (view == _SetupView.done) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleFinish());
    }
    // Choosing → installing slides forward like a step of its own.
    return OnboardingSwitcher(
      child: view == _SetupView.choose
          ? RuntimeChoiceView(
              key: const ValueKey('choose'),
              leading: widget.leading,
              onLocal: widget.onLocal ?? () => _install(),
              onRemote: widget.onRemote!,
            )
          : KeyedSubtree(key: const ValueKey('progress'), child: _progress(context, state, view)),
    );
  }

  Widget _progress(BuildContext context, LocalRuntimeState state, _SetupView view) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final progress = state.progress;
    final fraction = switch (view) {
      _SetupView.done => 1.0,
      _SetupView.installing => progress?.fraction,
      _SetupView.failed => 0.0,
      _SetupView.waiting || _SetupView.choose => null,
    };

    final title = switch (view) {
      _SetupView.waiting ||
      _SetupView.installing ||
      _SetupView.choose => _upgrade ? l10n.shellRuntimeUpdating : l10n.shellRuntimePreparing,
      _SetupView.done => l10n.shellRuntimeReady,
      _SetupView.failed => l10n.shellRuntimeIncomplete,
    };
    final body = switch (view) {
      _SetupView.waiting || _SetupView.installing || _SetupView.choose when widget.waiting => l10n.setupWaitingBody,
      _SetupView.waiting ||
      _SetupView.installing ||
      _SetupView.choose => _upgrade ? l10n.shellRuntimeFilesKept : l10n.shellRuntimeFirstSetup,
      _SetupView.done => l10n.shellRuntimeContinuing,
      _SetupView.failed when state.status.keepFailed => l10n.shellRuntimeRestoreFailed,
      _SetupView.failed => humanizeRuntimeError(state.status.error) ?? l10n.shellRuntimeExtractFailed,
    };
    final meta = view == _SetupView.installing ? installMetaLine(l10n, progress, ref.watch(installEtaProvider)) : null;
    // Set up and waiting: when a notification can say it's done, say so. HarmonyOS
    // has none for it, and suspends the app if it leaves the screen.
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final notifies =
        !ohos &&
        widget.waiting &&
        ref.watch(notifySystemStatusProvider.select((s) => s.value?.native == true && s.value?.enabled == true));

    // A phone on its side: a smaller ring, so the page fits without scrolling.
    final short = MediaQuery.sizeOf(context).height < WindowClass.compactHeight;
    return OnboardingScaffold(
      leading: widget.leading,
      children: [
        const Spacer(flex: 3),
        Center(
          child: ProgressHalo(
            value: fraction,
            size: short ? 128 : 184,
            strokeWidth: 4,
            color: view == _SetupView.failed ? colors.danger : null,
            child: AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.emphasized),
              switchInCurve: AppMotion.enter,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(animation), child: child),
              ),
              child: switch (view) {
                _SetupView.done => Icon(AppIcons.done, key: const ValueKey('done'), size: 48, color: scheme.primary),
                _SetupView.failed => Icon(
                  AppIcons.attention,
                  key: const ValueKey('failed'),
                  size: 44,
                  color: colors.danger,
                ),
                _SetupView.waiting || _SetupView.choose => const SizedBox.shrink(key: ValueKey('waiting')),
                _SetupView.installing => SetupPercent(key: const ValueKey('pct'), value: fraction ?? 0),
              },
            ),
          ),
        ),
        SizedBox(height: short ? 20 : 36),
        AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.standard),
          child: Text(title, key: ValueKey(title), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.standard),
          child: Text(
            body,
            key: ValueKey(body),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: math.max(20, MediaQuery.textScalerOf(context).scale(12) * 1.5),
          child: meta == null
              ? null
              : Text(
                  meta,
                  textAlign: TextAlign.center,
                  style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                ),
        ),
        const Spacer(flex: 2),
        if (view == _SetupView.failed) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => showRuntimeLogSheet(context, title: l10n.shellInstallLogs),
                  child: Text(l10n.commonViewLogs),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(onPressed: () => _install(), child: Text(l10n.commonRetry)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            // Quiet like the links below it: a way to get help, not the next step.
            child: TextButton(
              onPressed: () => unawaited(showDiagnosticsExportSheet(context)),
              style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
              child: Text(l10n.phoneDiagnosticsExport),
            ),
          ),
        ] else
          // One quiet line instead of a card: what matters while it runs.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(notifies ? AppIcons.notifications : AppIcons.localOnly, size: 16, color: colors.textTertiary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  notifies
                      ? l10n.setupNotifyWhenDone
                      : ohos && view == _SetupView.installing
                      ? l10n.harmonySetupStay
                      : l10n.shellRuntimeLocalOnly,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ),
            ],
          ),
        const SizedBox(height: 8),
        if (view != _SetupView.failed)
          Center(
            child: TextButton(
              onPressed: () => showRuntimeLogSheet(context, title: l10n.shellInstallLogs),
              style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
              child: Text(l10n.commonViewLogs),
            ),
          )
        else if (state.status.keepFailed)
          // The way out when kept files cannot go back: quiet, in the log link's place.
          Center(
            child: TextButton(
              onPressed: () => _install(dropKept: true),
              style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
              child: Text(l10n.shellRuntimeContinueWithoutKept),
            ),
          )
        else if (widget.onRemote case final onRemote?)
          // Storage full, a broken package…: the other way in, just as quiet.
          Center(
            child: TextButton(
              onPressed: onRemote,
              style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
              child: Text(l10n.localEnvUseRemote),
            ),
          ),
      ],
    );
  }
}

/// Glass sheet with the live runtime log (setup and engine screens).
Future<void> showRuntimeLogSheet(BuildContext context, {String? title}) {
  return showAppSheet<void>(
    context,
    heightFactor: 0.72,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final logs = ref.watch(localRuntimeLogsProvider);
        return Column(
          children: [
            SheetHeader(
              title ?? context.l10n.shellEngineLogs,
              actions: [
                IconButton(
                  tooltip: context.l10n.commonCopy,
                  icon: const Icon(AppIcons.copy, size: 20),
                  onPressed: logs.isEmpty ? null : () => LogActions.copy(context, logs),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
                child: LogView(lines: logs),
              ),
            ),
          ],
        );
      },
    ),
  );
}
