import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/ohos_linux_runtime.dart';
import '../../runtime/runtime_state.dart' show runtimeBridgeProvider;
import '../../state/ohos_linux_state.dart';
import '../common/app_dialog.dart';
import '../common/status_chip.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/text_prompt.dart';
import 'settings_widgets.dart';

(StatusTone, String) linuxStatus(L10n l10n, OhosLinuxView view) => switch (view.state) {
  OhosLinuxState.enabled => (StatusTone.ok, l10n.linuxStateOn),
  OhosLinuxState.installing => (StatusTone.busy, l10n.linuxStateInstalling),
  OhosLinuxState.disabling || OhosLinuxState.stopping => (StatusTone.busy, l10n.linuxStateStopping),
  OhosLinuxState.failed => (StatusTone.error, l10n.linuxStateFailed),
  OhosLinuxState.unavailable => (StatusTone.warn, l10n.linuxStateUnavailable),
  OhosLinuxState.disabled || OhosLinuxState.stopped || OhosLinuxState.unknown => (StatusTone.idle, l10n.linuxStateOff),
};

/// The engine's refusals to resume the Linux kept from before (an app update
/// changed its system, an unclean stop, damaged or ambiguous files). Nothing
/// overwrites that data by itself; 重新安装 Linux is the way out.
const _retainedRefusals = {
  'ERR_OHOS_LINUX_ASSET_GENERATION',
  'ERR_OHOS_LINUX_RECOVERY_REQUIRED',
  'ERR_OHOS_LINUX_RETAINED_INSTANCE',
  'ERR_OHOS_LINUX_INSTANCE_CORRUPT',
  'ERR_OHOS_LINUX_IMAGE_INTEGRITY',
  'ERR_OHOS_LINUX_TARGET_IDENTITY',
  'ERR_OHOS_LINUX_DIRECTORY_IDENTITY',
};

/// 「重新安装 Linux？」: what goes, what stays; the confirm key is red.
Future<bool> confirmLinuxReinstall(BuildContext context) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.linuxReinstallTitle),
      content: Text(l10n.linuxReinstallBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          key: const ValueKey('linux-reinstall-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.commonDelete),
        ),
      ],
    ),
  );
  return ok == true;
}

/// The row in 设置 · 能力 that opens [LinuxEnvironmentPage] (HarmonyOS only).
class LinuxEnvironmentTile extends ConsumerWidget {
  const LinuxEnvironmentTile({super.key, this.tint = 0});
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final (tone, label) = linuxStatus(l10n, ref.watch(ohosLinuxProvider));
    return SettingsTile(
      key: const ValueKey('settings-linux'),
      spot: SettingsIndex.entry(SettingsPageId.linuxEnvironment),
      icon: AppIcons.command,
      tint: tint,
      title: l10n.linuxTitle,
      value: StatusChip(tone: tone, label: label),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LinuxEnvironmentPage())),
    );
  }
}

class LinuxEnvironmentPage extends ConsumerStatefulWidget {
  const LinuxEnvironmentPage({super.key});

  @override
  ConsumerState<LinuxEnvironmentPage> createState() => _LinuxEnvironmentPageState();
}

class _LinuxEnvironmentPageState extends ConsumerState<LinuxEnvironmentPage> {
  @override
  void initState() {
    super.initState();
    // After the first frame: refreshing marks the provider busy at once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(ohosLinuxProvider.notifier).refresh());
    });
  }

  OhosLinuxController get _linux => ref.read(ohosLinuxProvider.notifier);

  Future<void> _reopen() async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = context.l10n.linuxReopenFailed;
    try {
      await ref.read(runtimeBridgeProvider).reopenApp();
    } catch (_) {
      // The system says no while the app isn't on top, or within 3 s of the last time.
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  Future<void> _reinstall() async {
    if (!await confirmLinuxReinstall(context) || !mounted) return;
    await _linux.reinstall();
  }

  String _stage(L10n l10n, String stage) => switch (stage) {
    'archive' || 'download' => l10n.linuxStageDownload,
    'bootstrap' || 'target' => l10n.linuxStageDisk,
    'boot-start' => l10n.linuxStageBoot,
    'guest-install' => l10n.linuxStageTools,
    _ => l10n.linuxStateInstalling,
  };

  String? _proxyUrlProblem(L10n l10n, String text) {
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    final ok = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty &&
        (uri.path.isEmpty || uri.path == '/') && !uri.hasQuery && !uri.hasFragment;
    return ok ? null : l10n.linuxProxyUrlInvalid;
  }

  Future<void> _editManual(OhosLinuxProxyConfiguration current, {required String field}) async {
    final l10n = context.l10n;
    final initial = switch (field) {
      'http' => current.httpProxy,
      'https' => current.httpsProxy,
      _ => current.noProxy,
    } ?? '';
    final text = await showTextPrompt(
      context,
      title: switch (field) {
        'http' => l10n.linuxProxyHttp,
        'https' => l10n.linuxProxyHttps,
        _ => l10n.linuxProxyNoProxy,
      },
      initial: initial,
      hint: field == 'no' ? 'example.com,10.0.0.0/8' : 'http://127.0.0.1:7890',
      caption: field == 'no' ? null : l10n.linuxProxyLoopbackNote,
      mono: true,
      keyboardType: TextInputType.url,
      validate: field == 'no' ? null : (text) => _proxyUrlProblem(l10n, text),
    );
    if (text == null || !mounted) return;
    String? value(String key) => key == field ? (text.isEmpty ? null : text) : switch (key) {
      'http' => current.httpProxy,
      'https' => current.httpsProxy,
      _ => current.noProxy,
    };
    final http = value('http'), https = value('https');
    if (http == null && https == null) {
      await _linux.setProxy(const OhosLinuxProxyConfiguration.direct());
      return;
    }
    await _linux.setProxy(OhosLinuxProxyConfiguration.manual(httpProxy: http, httpsProxy: https, noProxy: value('no')));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final view = ref.watch(ohosLinuxProvider);
    final snapshot = view.snapshot;
    final (tone, label) = linuxStatus(l10n, view);
    final progress = view.state == OhosLinuxState.installing ? snapshot?.progress : null;
    final fraction = progress?.done != null && (progress?.total ?? 0) > 0 ? progress!.done! / progress.total! : null;
    final on = snapshot?.enabled ?? false;
    final restart = snapshot?.restartRequired ?? false;
    final proxy = view.proxy;

    final code = snapshot?.lastErrorCode;
    final error = view.error;
    final String? problem = error is OhosLinuxReinstallFailure
        ? (error.needsRestart ? l10n.linuxReinstallRestart : l10n.linuxReinstallFailed(error.code))
        : error != null
        ? (snapshot == null ? l10n.linuxEngineOffline : l10n.linuxRequestFailed)
        : code != null && _retainedRefusals.contains(code)
        ? l10n.linuxRetainedRefused(code)
        : restart
        ? l10n.linuxRestartRequired
        : code != null
        ? l10n.linuxErrorWithCode(code)
        : null;
    // A VM started in this app process may hold the data until the app quits.
    final vmHeld = snapshot?.nativeMemoryRelease != null;
    final canReinstall = snapshot != null && !view.busy && !view.moving && !vmHeld &&
        (view.state == OhosLinuxState.disabled || view.state == OhosLinuxState.failed);

    return AppPage.list(
      title: l10n.linuxTitle,
      subtitle: Text(l10n.linuxSubtitle),
      children: [
        SettingsSection(
          footer: Text(
            problem ?? (on ? l10n.linuxMemoryNote : l10n.linuxFirstHint),
            style: problem == null ? null : TextStyle(color: theme.colorScheme.error),
          ),
          children: [
            SettingsSwitchTile(
              key: const ValueKey('linux-switch'),
              title: l10n.linuxSwitch,
              subtitle: progress == null ? null : _stage(l10n, progress.stage),
              value: on,
              onChanged: view.busy || view.moving || restart || snapshot == null
                  ? null
                  : (value) => unawaited(_linux.setEnabled(value)),
            ),
            SettingsTile(title: l10n.linuxStatus, value: StatusChip(tone: tone, label: label), chevron: false),
            if (restart)
              SettingsTile(
                key: const ValueKey('linux-reopen'),
                title: l10n.linuxReopenApp,
                onTap: () => unawaited(_reopen()),
              ),
            if (progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: LinearProgressIndicator(value: fraction),
              ),
            SettingsTile(
              key: const ValueKey('linux-reinstall'),
              title: l10n.linuxReinstall,
              subtitle: vmHeld && !on ? l10n.linuxReinstallAfterRestart : l10n.linuxReinstallHint,
              danger: canReinstall,
              chevron: false,
              onTap: canReinstall ? () => unawaited(_reinstall()) : null,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.linuxProxyTitle,
          footer: Text(l10n.linuxProxyFooter),
          children: [
            SettingsSegmentTile<OhosLinuxProxyMode>(
              key: const ValueKey('linux-proxy-mode'),
              title: l10n.linuxProxyMode,
              segments: [
                PillSegment(OhosLinuxProxyMode.inherit, l10n.linuxProxyInherit),
                PillSegment(OhosLinuxProxyMode.direct, l10n.linuxProxyDirect),
                PillSegment(OhosLinuxProxyMode.manual, l10n.linuxProxyManual),
              ],
              selected: proxy.mode,
              onChanged: view.busy
                  ? null
                  : (mode) => unawaited(switch (mode) {
                      OhosLinuxProxyMode.inherit => _linux.setProxy(const OhosLinuxProxyConfiguration.inherit()),
                      OhosLinuxProxyMode.direct => _linux.setProxy(const OhosLinuxProxyConfiguration.direct()),
                      OhosLinuxProxyMode.manual => _editManual(proxy, field: 'http'),
                    }),
            ),
            if (proxy.mode == OhosLinuxProxyMode.manual) ...[
              SettingsTile(
                key: const ValueKey('linux-proxy-http'),
                title: l10n.linuxProxyHttp,
                value: Text(proxy.httpProxy ?? l10n.linuxProxyUnset),
                onTap: () => unawaited(_editManual(proxy, field: 'http')),
              ),
              SettingsTile(
                key: const ValueKey('linux-proxy-https'),
                title: l10n.linuxProxyHttps,
                value: Text(proxy.httpsProxy ?? l10n.linuxProxySameAsHttp),
                onTap: () => unawaited(_editManual(proxy, field: 'https')),
              ),
              SettingsTile(
                key: const ValueKey('linux-proxy-no'),
                title: l10n.linuxProxyNoProxy,
                value: Text(proxy.noProxy ?? l10n.linuxProxyUnset),
                onTap: () => unawaited(_editManual(proxy, field: 'no')),
              ),
            ],
          ],
        ),
        const SizedBox(height: 72),
      ],
    );
  }
}
