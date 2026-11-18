import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/update_state.dart';
import '../fx/metal/metal_badge.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'update_sheet.dart';

/// 设置 → 关于: 「检查更新」 (marked when a new version is waiting) and the
/// daily automatic check switch. Plain rows, lined up with the [InfoRow]s.
class AppUpdateTiles extends ConsumerWidget {
  const AppUpdateTiles({super.key, this.tint});

  /// The group hue on the settings hub (rows get icons); null for plain rows.
  final int? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider);
    // No way to check at all; HarmonyOS checks, and its sheet only offers a page.
    if (!update.checkable) return const SizedBox.shrink();
    final controller = ref.read(appUpdateProvider.notifier);
    final tint = this.tint;
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsTile(
          icon: tint == null ? null : AppIcons.checkUpdate,
          tint: tint ?? 0,
          spot: Spots.updateCheck,
          value: _value(context, update),
          onTap: update.check == UpdateCheckPhase.checking ? null : () => unawaited(checkForUpdates(context, ref)),
          chevron: update.check != UpdateCheckPhase.checking,
        ),
        const SizedBox(height: 2),
        SettingsSwitchTile(
          icon: tint == null ? null : AppIcons.autoUpdate,
          tint: tint ?? 0,
          spot: Spots.updateAuto,
          subtitle: l10n.updateAutoCheckDaily,
          value: update.autoCheck,
          onChanged: (v) => unawaited(controller.setAutoCheck(v)),
        ),
      ],
    );
  }

  Widget? _value(BuildContext context, AppUpdateState update) {
    final colors = DshColors.of(context);
    final l10n = context.l10n;
    if (update.check == UpdateCheckPhase.checking) {
      return const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (update.hasUpdate) {
      return switch (update.task) {
        UpdateTaskPhase.downloading => Text(
          update.progress == null
              ? l10n.updateTileDownloading
              : l10n.updateTileDownloadingPercent((update.progress! * 100).floor()),
        ),
        UpdateTaskPhase.verifying => Text(l10n.updateTileVerifying),
        UpdateTaskPhase.ready || UpdateTaskPhase.needsPermission => UpdateBadge(l10n.updateTileReady),
        UpdateTaskPhase.installing => Text(l10n.updateTileInstalling),
        _ when update.isSkipped => Text(
          l10n.updateTileSkipped(update.latest!.version.name),
          style: TextStyle(color: colors.textTertiary),
        ),
        _ => UpdateBadge(l10n.updateTileNewVersion(update.latest!.version.name)),
      };
    }
    return switch (update.check) {
      UpdateCheckPhase.upToDate => Text(l10n.updateTileUpToDate),
      UpdateCheckPhase.unavailable => Text(l10n.updateTileUnavailable, style: TextStyle(color: colors.textTertiary)),
      _ => null,
    };
  }
}

/// The "new version" mark: a dot and a short label on a tinted pill.
/// 「新版本」: a small pill of liquid metal (Libraries.dev Metal), the one on the page.
class UpdateBadge extends StatelessWidget {
  const UpdateBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => MetalBadge(text: text);
}
