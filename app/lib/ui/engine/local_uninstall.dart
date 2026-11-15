// 「卸载运行环境」: frees the room the on-device runtime
// takes, for a phone that runs DSH on a remote host. Installing again is one
// tap away wherever 本机 shows as 未安装.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/android_features.dart';
import '../../state/hosts_state.dart';
import '../../state/onboarding_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_dialog.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Deletes the runtime and everything in it (a reset that keeps nothing and
/// does not reinstall): the app then runs without it until the next install.
abstract final class LocalUninstall {
  static Future<void> run(ProviderContainer container) async {
    final prefs = container.read(onboardingPrefsProvider.notifier);
    final restoreDeclined =
        container.read(operatingSystemProvider) == 'ios' && container.read(onboardingPrefsProvider).localDeclined;
    // Before the phase reads 未安装, so the root gate stays home.
    await prefs.setLocalDeclined(true);
    try {
      await container.read(localRuntimeProvider.notifier).resetKeeping(const ResetKeep());
    } catch (_) {
      await prefs.setLocalDeclined(restoreDeclined);
      rethrow;
    }
    // Its conversations went with it: don't reopen one of them.
    if (container.read(activeHostProvider).isLocal) container.read(currentSessionProvider.notifier).select(null);
  }
}

/// The engine page's row under 「重置运行环境」.
class LocalUninstallRow extends ConsumerWidget {
  const LocalUninstallRow({super.key, required this.enabled});

  final bool enabled;

  Future<void> _confirm(BuildContext context) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.localEnvUninstallTitle),
        content: Text(l10n.localEnvUninstallBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.localEnvUninstallConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      // The page stays: it turns into 未安装 with 「安装运行环境」.
      await LocalUninstall.run(container);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.localEnvUninstallFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return SettingsTile(
      icon: AppIcons.delete,
      tinted: false,
      danger: enabled,
      spot: Spots.engineUninstall,
      subtitle: l10n.localEnvUninstallHint,
      chevron: false,
      onTap: enabled ? () => unawaited(_confirm(context)) : null,
    );
  }
}
