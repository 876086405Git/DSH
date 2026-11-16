import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../../state/engine_control.dart';
import '../../state/safe_mode_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../engine/log_view.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// "今天" is decided against this clock; tests pin it.
DateTime Function() safeModeClock = DateTime.now;

/// The safe-mode flows behind the buttons. Each takes a [BuildContext] for its dialogs
/// and works on the app's [ProviderContainer], so the engine keeps going if the screen
/// that started it is popped.
abstract final class SafeModeActions {
  static ProviderContainer _container(BuildContext context) => ProviderScope.containerOf(context, listen: false);

  static bool _harmony(ProviderContainer container) => container.read(operatingSystemProvider) == 'ohos';

  /// HarmonyOS, once this process has used its one engine start: what a change of
  /// mode or configuration costs, for the dialog that asks. Null where it costs a
  /// restart and no more, or the engine hasn't started yet.
  static String? _reopenNote(ProviderContainer container) =>
      _harmony(container) && container.read(localRuntimeProvider).status.launchSpawned
      ? appL10n.harmonySafeReopenNote
      : null;

  /// Checks the home-level files that would also break safe mode, offers to move them
  /// aside, then restarts in safe mode. On HarmonyOS it asks first: there is nothing
  /// to move aside there, and it can mean reopening the app.
  static Future<void> enter(BuildContext context) async {
    final container = _container(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_harmony(container)) {
      final l10n = context.l10n;
      final note = _reopenNote(container);
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.harmonySafeEnterTitle),
          content: Text([l10n.harmonySafeEnterBody, ?note].join('\n\n')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.phoneFailureEnterSafe)),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    List<SafeHazard> hazards;
    try {
      hazards = await container.read(runtimeBridgeProvider).safePreflight();
    } catch (_) {
      hazards = const [];
    }
    if (!context.mounted) return;
    var moveAside = const <String>[];
    if (hazards.isNotEmpty) {
      final move = await confirmMoveAside(context, hazards);
      if (move == null) return;
      if (move) moveAside = [for (final h in hazards) h.path];
    }
    await _enterSafeMode(container, messenger, moveAside: moveAside);
  }

  /// true = move aside, false = start anyway, null = cancel.
  static Future<bool?> confirmMoveAside(BuildContext context, List<SafeHazard> hazards) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.phoneSafeMoveAsideTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.phoneSafeMoveAsideIntro),
              const SizedBox(height: 10),
              for (final h in hazards) ...[
                Text(h.path, style: theme.textTheme.labelLarge),
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Text(h.detail, style: theme.textTheme.bodySmall),
                ),
              ],
              Text(l10n.phoneSafeMoveAsideNote),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.phoneSafeStartDirectly)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.phoneSafeMoveAsideStart)),
        ],
      ),
    );
  }

  /// Confirms, puts the main profile back to its last good plugin set and starts normally.
  static Future<void> restoreLastKnownGood(BuildContext context) async {
    final l10n = context.l10n;
    final container = _container(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    LastKnownGood lkg;
    try {
      lkg = await container.read(runtimeBridgeProvider).lastKnownGood();
    } catch (_) {
      lkg = const LastKnownGood.none();
    }
    if (!context.mounted) return;
    final note = _reopenNote(container);
    if (!lkg.useful) {
      messenger?.showSnackBar(
        SnackBar(content: Text(lkg.available ? l10n.phoneSafeNoRestoreNeeded : l10n.phoneSafeNoRestoreRecord)),
      );
      return;
    }
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.phoneSafeRestoreTitle),
        content: SingleChildScrollView(child: Text([describeRestore(lkg), ?note].join('\n\n'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.phoneSafeRestoreStart)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await EngineControl.restoreLastKnownGood(container);
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(note == null ? l10n.phoneSafeRestoredStarting : l10n.harmonyRestoredReopening)),
        );
      }
    } catch (error) {
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_recoveryError(error, l10n.phoneSafeRestoreFailed))));
      }
    }
  }

  /// The confirmation text for [restoreLastKnownGood].
  static String describeRestore(LastKnownGood lkg) {
    final lines = <String>[
      lkg.at == null ? appL10n.phoneSafeRestoreIntro : appL10n.phoneSafeRestoreAt(formatWhen(lkg.at!)),
    ];
    if (lkg.disable.isNotEmpty) {
      lines.add(appL10n.phoneSafeRestoreDisable(lkg.disable.join(appL10n.phoneListSeparator)));
      if (lkg.changed.isNotEmpty) {
        lines.add(appL10n.phoneSafeRestoreChanged(lkg.changed.join(appL10n.phoneListSeparator)));
      }
    }
    if (lkg.enable.isNotEmpty) {
      lines.add(appL10n.phoneSafeRestoreEnable(lkg.enable.join(appL10n.phoneListSeparator)));
    }
    if (lkg.patchChanged) lines.add(appL10n.phoneSafeRestoreSettings);
    lines.add('');
    lines.add(appL10n.phoneSafeRestoreNote);
    return lines.join('\n');
  }

  /// Leaves safe mode; a failure within two minutes brings it back.
  static Future<void> leave(BuildContext context) async {
    final l10n = context.l10n;
    final container = _container(context);
    final note = _reopenNote(container);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.phoneSafeLeaveTitle),
        content: Text([l10n.phoneSafeLeaveBody, ?note].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.phoneSafeLeave)),
        ],
      ),
    );
    if (ok == true) await EngineControl.leaveSafeMode(container);
  }

  /// Starts again in the current mode.
  static Future<void> retry(BuildContext context) => EngineControl.restart(_container(context));

  /// Starts normally from a failed safe mode (the two-minute trial applies).
  static Future<void> startNormal(BuildContext context) {
    final container = _container(context);
    // HarmonyOS can't change mode without reopening the app, so it asks.
    if (_harmony(container)) return leave(context);
    return EngineControl.restart(container, mode: EngineMode.normal);
  }

  /// The button for [moveAsideAndRetry]: names what it moves.
  static String moveAsideLabel(List<SafeHazard> hazards) =>
      hazards.every((h) => h.kind == 'homePatch') ? appL10n.phoneSafeMovePatch : appL10n.phoneSafeMoveFiles;

  /// Moves the given files aside and starts safe mode again.
  static Future<void> moveAsideAndRetry(BuildContext context, List<SafeHazard> hazards) => _enterSafeMode(
    _container(context),
    ScaffoldMessenger.maybeOf(context),
    moveAside: [for (final h in hazards) h.path],
  );

  static Future<void> _enterSafeMode(
    ProviderContainer container,
    ScaffoldMessengerState? messenger, {
    required List<String> moveAside,
  }) async {
    try {
      await EngineControl.enterSafeMode(container, moveAside: moveAside);
    } catch (error) {
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_recoveryError(error, appL10n.commonFailedTryAgain))));
      }
    }
  }

  static String _recoveryError(Object error, String fallback) => switch (error) {
    PlatformException(code: 'runtime_not_stopped') => appL10n.phoneSafeStopIncomplete,
    PlatformException(code: 'runtime_not_stopped_after_recovery') => appL10n.phoneSafeRestartIncomplete,
    _ => fallback,
  };

  static Future<void> dismissFailure(BuildContext context) =>
      _container(context).read(runtimeBridgeProvider).clearFailure();

  /// Queues the repair prompt for the chat composer (not sent) and goes back to the chat.
  static void requestRepair(BuildContext context, {bool popToRoot = true}) {
    final container = _container(context);
    final status = container.read(localRuntimeProvider).status;
    container.read(repairDraftProvider.notifier).request(repairPrompt(status, harmony: _harmony(container)));
    if (popToRoot) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// The output around the last failure (tokens masked), with copy / share.
  static Future<void> showFailureLog(BuildContext context, {String? summary}) async {
    final l10n = context.l10n;
    final container = _container(context);
    var lines = const <String>[];
    try {
      lines = await container.read(runtimeBridgeProvider).failureLog();
    } catch (_) {}
    if (lines.isEmpty) {
      final logs = container.read(localRuntimeLogsProvider);
      lines = logs.length > 300 ? logs.sublist(logs.length - 300) : logs;
    }
    if (!context.mounted) return;
    await showAppSheet<void>(
      context,
      heightFactor: 0.75,
      builder: (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            l10n.phoneSafeFailureLog,
            actions: [
              IconButton(
                tooltip: l10n.phoneLogCopyAll,
                icon: const Icon(AppIcons.copy, size: 20),
                onPressed: lines.isEmpty ? null : () => LogActions.copy(sheet, lines),
              ),
              IconButton(
                tooltip: l10n.commonShare,
                icon: const Icon(AppIcons.share, size: 20),
                onPressed: lines.isEmpty ? null : () => unawaited(LogActions.share(lines)),
              ),
            ],
          ),
          if (summary != null && summary.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(summary, style: AppType.monoSmall(color: DshColors.of(sheet).textTertiary)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: LogView(lines: lines, emptyText: l10n.phoneSafeFailureLogEmpty),
            ),
          ),
        ],
      ),
    );
  }

  /// `10月23日 15:30`, or `今天 15:30`.
  static String formatWhen(DateTime at, {DateTime? now}) {
    final today = now ?? safeModeClock();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    if (at.year == today.year && at.month == today.month && at.day == today.day) {
      return appL10n.phoneSafeTodayTime(time);
    }
    return '${appL10n.monthDay(at)} $time';
  }
}
