// 本机引擎 → Linux 环境 (iOS only): install, follow, cancel, measure and remove the Linux root
// file system that commands the virtual shell can't run go to (lib/state/ios_guest_state.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/ios_guest_state.dart';
import '../common/app_dialog.dart';
import '../session/workspace_files.dart' show formatBytes;
import '../settings/settings_widgets.dart';
import '../theme/theme.dart';

class LinuxSection extends ConsumerWidget {
  const LinuxSection({super.key});

  static String stepLabel(L10n l10n, GuestStep? step) => switch (step) {
    GuestStep.verify => l10n.iosLinuxVerifying,
    GuestStep.extract => l10n.iosLinuxExtracting,
    GuestStep.publish => l10n.iosLinuxFinishing,
    GuestStep.download || null => l10n.iosLinuxDownloading,
  };

  static String failureText(L10n l10n, String code) => switch (code) {
    'network' => l10n.iosLinuxErrorNetwork,
    'checksum' || 'archive' => l10n.iosLinuxErrorDamaged,
    'no_space' => l10n.iosLinuxErrorNoSpace,
    'restart_required' => l10n.iosLinuxErrorInUse,
    'busy' => l10n.iosLinuxErrorBusy,
    _ => l10n.iosLinuxErrorOther,
  };

  Future<void> _confirmUninstall(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.iosLinuxUninstall),
        content: Text(l10n.iosLinuxUninstallBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.iosLinuxUninstallConfirm),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(iosGuestProvider.notifier).uninstall();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = ref.watch(iosGuestProvider);
    final status = view.status;
    // An app built without it, or not known yet: nothing to offer.
    if (status == null || !status.available) return const SizedBox.shrink();
    final guest = ref.read(iosGuestProvider.notifier);
    final colors = DshColors.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final running = ref.watch(localRuntimeProvider.select((s) => s.status.phase == RuntimePhase.running));

    final String? note = switch (view) {
      GuestView(failure: final code?) => failureText(l10n, code),
      GuestView(justResumed: true) when running => l10n.iosLinuxResumed,
      _ when status.installed && status.suspended => l10n.iosLinuxSuspendedBody,
      GuestView(justInstalled: true) when running => l10n.iosLinuxRestartEngine,
      _ => null,
    };

    return SettingsSection(
      title: l10n.iosLinuxTitle,
      footer: note == null
          ? (status.installed ? null : Text(l10n.iosLinuxIntro, style: small))
          : Text(note, style: small?.copyWith(color: view.failure == null ? null : colors.danger)),
      children: [
        if (view.installing)
          _Progress(
            label: stepLabel(l10n, view.step),
            fraction: view.fraction,
            onCancel: view.step == GuestStep.publish ? null : guest.cancel,
          )
        else if (status.phase == 'uninstalling')
          SettingsTile(
            title: l10n.iosLinuxUninstalling,
            trailing: const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (!status.installed)
          SettingsTile(title: l10n.iosLinuxInstall, value: Text(l10n.iosLinuxDownloadSize), onTap: guest.install)
        else ...[
          InfoRow(label: l10n.iosLinuxSystem, value: 'Alpine ${status.version ?? ''}'.trim()),
          if (status.suspended) InfoRow(label: l10n.iosLinuxState, value: l10n.iosLinuxStatePaused),
          InfoRow(label: l10n.iosLinuxStorage, value: view.bytes == null ? '—' : formatBytes(view.bytes!)),
          if (status.suspended) SettingsTile(title: l10n.iosLinuxResume, onTap: status.busy ? null : guest.resume),
          SettingsTile(
            title: l10n.iosLinuxUninstall,
            danger: true,
            onTap: status.busy ? null : () => unawaited(_confirmUninstall(context, ref)),
          ),
        ],
      ],
    );
  }
}

/// The step, how far it has got, and a way to stop while it still can.
class _Progress extends StatelessWidget {
  const _Progress({required this.label, required this.fraction, required this.onCancel});

  final String label;
  final double? fraction;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final percent = fraction == null ? null : '${(fraction! * 100).floor()}%';
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 10, SettingsMetrics.inset - 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(percent == null ? label : '$label · $percent', style: settingsTitleStyle(context)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: fraction, minHeight: 4),
                ),
              ],
            ),
          ),
          if (onCancel != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onCancel, child: Text(context.l10n.commonCancel)),
          ],
        ],
      ),
    );
  }
}
