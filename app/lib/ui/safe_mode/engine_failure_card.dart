import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/engine_control.dart';
import '../../state/safe_mode_state.dart';
import '../common/status_chip.dart';
import '../engine/diagnostics_export_card.dart';
import '../engine/engine_status.dart';
import '../remote/remote_screen.dart';
import '../settings/background_guide_page.dart';
import '../theme/theme.dart';
import 'recovery_actions.dart';
import 'safe_mode_actions.dart';

/// What the failure card says and which buttons it offers, derived from the native
/// classification. Pure, for tests.
class FailureCardModel {
  const FailureCardModel({
    required this.title,
    required this.body,
    required this.primary,
    required this.secondary,
    this.culprits = const [],
    this.detail,
    this.tone = StatusTone.error,
  });

  final String title;
  final String body;

  /// Plugin names worth suspecting.
  final List<String> culprits;

  /// The fatal or launch error line, displayed only in the log sheet.
  final String? detail;
  final FailureAction primary;
  final List<FailureAction> secondary;
  final StatusTone tone;

  /// [held]: the engine won't start by itself until someone says so ([EngineControl.shouldAutoStart]).
  static FailureCardModel of(RuntimeFailure f, {required bool lkgUseful, bool held = false}) {
    if (f.safeMode && f.kind.isFatal) {
      return FailureCardModel(
        title: appL10n.phoneFailureSafeStartup,
        body: appL10n.phoneFailureSafeStartupHint,
        detail: f.summary,
        primary: FailureAction.retry,
        secondary: const [FailureAction.startNormal, FailureAction.showLog],
      );
    }
    switch (f.kind) {
      case FailureKind.launchFailed:
        return FailureCardModel(
          title: appL10n.phoneFailureLaunch,
          body: appL10n.phoneFailureLaunchHint,
          detail: f.causeUnknown ? null : f.summary,
          primary: FailureAction.retry,
          secondary: [
            // HarmonyOS: a safe run that couldn't launch can still go back to the person's own configuration.
            if (f.safeMode && f.causeUnknown) FailureAction.startNormal,
            FailureAction.remote,
            FailureAction.showLog,
          ],
        );
      case FailureKind.killed:
        if (f.causeUnknown) return _unclean(f, lkgUseful: lkgUseful, held: held);
        return FailureCardModel(
          title: appL10n.phoneFailureKilled,
          body: appL10n.phoneFailureKilledHint,
          primary: FailureAction.retry,
          secondary: const [FailureAction.background, FailureAction.showLog],
          tone: StatusTone.warn,
        );
      case FailureKind.noSpace:
        return FailureCardModel(
          title: appL10n.commonStorageFull,
          body: appL10n.phoneFailureNoSpaceHint,
          primary: FailureAction.retry,
          secondary: const [FailureAction.showLog],
        );
      case FailureKind.startupFailed:
      case FailureKind.crashedEarly:
      case FailureKind.crashedLate:
        final culprits = f.culprits;
        final title = switch (f.kind) {
          FailureKind.startupFailed => appL10n.phoneFailureStartup,
          FailureKind.crashedEarly => appL10n.phoneFailureCrashedEarly,
          _ => appL10n.phoneFailureCrashedLate,
        };
        final cause = culprits.isNotEmpty
            ? appL10n.phoneFailurePlugins(culprits.take(2).join(appL10n.phonePluginQuoteSeparator))
            : f.requiredRows.isNotEmpty
            ? appL10n.phoneFailureRequired(f.requiredRows.take(3).join(appL10n.phoneListSeparator))
            : appL10n.phoneFailureFatal;
        return FailureCardModel(
          title: title,
          body: cause,
          culprits: culprits,
          detail: f.summary,
          primary: lkgUseful ? FailureAction.restoreLkg : FailureAction.enterSafe,
          secondary: lkgUseful
              ? const [FailureAction.enterSafe, FailureAction.showLog, FailureAction.retry]
              : const [FailureAction.retry, FailureAction.showLog],
        );
    }
  }

  /// HarmonyOS's engine runs in the app's process, so a configuration that breaks it
  /// reads the same as the system reclaiming the app, and its failures are only
  /// ever this or [FailureKind.launchFailed]. The ways out are on offer either way;
  /// they come first once it has happened enough that the engine waits.
  static FailureCardModel _unclean(RuntimeFailure f, {required bool lkgUseful, required bool held}) {
    final rescue = [if (lkgUseful) FailureAction.restoreLkg, FailureAction.enterSafe];
    final (primary, rest) = f.safeMode
        ? (FailureAction.retry, const [FailureAction.startNormal])
        : held
        ? (rescue.first, [...rescue.skip(1), FailureAction.retry])
        : (FailureAction.retry, rescue);
    return FailureCardModel(
      title: appL10n.harmonyFailureUnclean,
      body: appL10n.harmonyFailureUncleanHint,
      primary: primary,
      secondary: [...rest, FailureAction.background, FailureAction.showLog],
      tone: StatusTone.warn,
    );
  }
}

enum FailureAction {
  restoreLkg,
  enterSafe,
  retry,
  startNormal,
  background,
  remote,
  showLog;

  String get label => switch (this) {
    FailureAction.restoreLkg => appL10n.phoneFailureRestore,
    FailureAction.enterSafe => appL10n.phoneFailureEnterSafe,
    FailureAction.retry => appL10n.commonRetry,
    FailureAction.startNormal => appL10n.phoneFailureStartNormal,
    FailureAction.background => appL10n.phoneEngineKeepAlive,
    FailureAction.remote => appL10n.commonRemoteHost,
    FailureAction.showLog => appL10n.commonViewLogs,
  };
}

/// Card for an engine that stopped on its own: why, and what to do about it. Renders
/// nothing unless there is a failure and the engine is idle, so it can be dropped into
/// any screen (engine page, sessions drawer empty state, chat).
class EngineFailureCard extends ConsumerWidget {
  const EngineFailureCard({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  static bool visibleFor(RuntimeStatus status) =>
      status.failure != null &&
      !isLocalStartupFailure(status) &&
      (status.phase == RuntimePhase.error || status.phase == RuntimePhase.installed);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    final failure = status.failure;
    if (failure == null || !visibleFor(status)) return const SizedBox.shrink();
    final held = !EngineControl.shouldAutoStart(status);
    final lkg = (failure.kind.isFatal || failure.causeUnknown) && !failure.safeMode
        ? ref.watch(lastKnownGoodProvider).value
        : null;
    final model = FailureCardModel.of(failure, lkgUseful: lkg?.useful ?? false, held: held);
    final hazards = failure.safeMode && failure.kind.isFatal
        ? ref.watch(safePreflightProvider).value ?? const <SafeHazard>[]
        : const <SafeHazard>[];
    final theme = Theme.of(context);
    final colors = DshColors.of(context);

    void run(FailureAction action) {
      switch (action) {
        case FailureAction.restoreLkg:
          unawaited(SafeModeActions.restoreLastKnownGood(context));
        case FailureAction.enterSafe:
          unawaited(SafeModeActions.enter(context));
        case FailureAction.retry:
          unawaited(SafeModeActions.retry(context));
        case FailureAction.startNormal:
          unawaited(SafeModeActions.startNormal(context));
        case FailureAction.showLog:
          unawaited(SafeModeActions.showFailureLog(context, summary: model.detail));
        case FailureAction.background:
          unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const BackgroundGuidePage())));
        case FailureAction.remote:
          unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const RemoteScreen())));
      }
    }

    return Padding(
      padding: padding,
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedStatusDot(tone: model.tone, size: 8),
                const SizedBox(width: 10),
                Expanded(child: Text(model.title, style: theme.textTheme.titleMedium)),
                Text(
                  SafeModeActions.formatWhen(failure.at),
                  style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: colors.textTertiary)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(model.body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            // Where there is no safe mode to fall back on, this is what two in a row do.
            if (failure.causeUnknown && held) ...[
              const SizedBox(height: 8),
              Text(
                l10n.harmonyFailureHeld,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            for (final h in hazards) ...[
              const SizedBox(height: 10),
              Text(h.path, style: AppType.monoLabel(color: colors.textTertiary)),
              Text(
                h.kind == 'homePatch' ? l10n.phoneFailureGlobalPatch : l10n.phoneFailureEnvironment,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 14),
            RecoveryActions(
              primaryLabel: hazards.isNotEmpty ? SafeModeActions.moveAsideLabel(hazards) : model.primary.label,
              onPrimary: hazards.isNotEmpty
                  ? () => unawaited(SafeModeActions.moveAsideAndRetry(context, hazards))
                  : () => run(model.primary),
              secondary: [
                for (final action in model.secondary)
                  if (action != FailureAction.showLog) (label: action.label, onPressed: () => run(action)),
              ],
              onLog: () => run(FailureAction.showLog),
              onExport: () => unawaited(showDiagnosticsExportSheet(context)),
            ),
          ],
        ),
      ),
    );
  }
}
