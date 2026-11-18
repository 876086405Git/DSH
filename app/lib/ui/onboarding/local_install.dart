// 「安装运行环境」 after first run — for a phone that started on a remote host, or
// after an uninstall. Every install entry (the engine page, the host switcher,
// the empty chat and drawer, the web page) opens this one page; a build without
// the runtime (LocalRuntimeState.available) opens the host list instead.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/onboarding_state.dart';
import '../../state/settings_state.dart';
import '../remote/remote_screen.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'connect_page.dart';
import 'onboarding_scaffold.dart';
import 'runtime_setup_page.dart';

/// Opens the install page over whatever is showing; the host list on a build
/// without the runtime.
Future<void> openLocalInstall(BuildContext context, {bool useWhenDone = false}) {
  final available = ProviderScope.containerOf(context, listen: false).read(localRuntimeProvider).available;
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => available ? LocalInstallPage(useWhenDone: useWhenDone) : const RemoteScreen(),
    ),
  );
}

/// What a 本机 entry says with no runtime: install it, or on a build without
/// one, use a remote host. Both actions go through [openLocalInstall].
({String title, String action}) localMissingCopy(L10n l10n, {required bool available}) => available
    ? (title: l10n.localEnvNotInstalled, action: l10n.phoneEngineInstallRuntime)
    : (title: l10n.localEnvUnavailable, action: l10n.localEnvUseRemote);

/// What installing costs and one 「安装」; then the same progress as first
/// run. Once installed the engine starts, and a phone with no model yet goes
/// on to 「连接 DeepSeek」.
///
/// The back key leaves at any point: an install already running carries on
/// in the background (its notification shows the progress) and this page
/// picks it up again when reopened.
class LocalInstallPage extends ConsumerStatefulWidget {
  const LocalInstallPage({super.key, this.useWhenDone = false});

  /// Make 本机 the active host once installed (opened from the host list).
  final bool useWhenDone;

  @override
  ConsumerState<LocalInstallPage> createState() => _LocalInstallPageState();
}

class _LocalInstallPageState extends ConsumerState<LocalInstallPage> {
  bool _confirmed = false;

  Future<void> _done() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context);
    unawaited(EngineControl.ensureStarted(container));
    if (widget.useWhenDone) container.read(activeHostProvider.notifier).select(HostRef.local);
    if (container.read(settingsProvider).hasModelAccess || container.read(onboardingPrefsProvider).keySkipped) {
      navigator.pop();
      return;
    }
    await navigator.pushReplacement<void, void>(
      MaterialPageRoute(builder: (context) => ConnectPage(onDone: () => Navigator.of(context).pop())),
    );
    // Left without a key or a sign-in: don't bring the step back at launch.
    if (!container.read(settingsProvider).hasModelAccess) {
      await container.read(onboardingPrefsProvider.notifier).setKeySkipped(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(localRuntimeProvider.select((s) => s.status.phase));
    final back = GlassIconButton(
      icon: AppIcons.back,
      tooltip: context.l10n.commonBack,
      grouped: false,
      onPressed: () => Navigator.of(context).maybePop(),
    );
    final ask = !_confirmed && phase == RuntimePhase.notInstalled;
    return OnboardingSwitcher(
      child: ask
          ? _Confirm(key: const ValueKey('confirm'), leading: back, onInstall: () => setState(() => _confirmed = true))
          : KeyedSubtree(
              key: const ValueKey('install'),
              child: RuntimeSetupPage(onDone: () => unawaited(_done()), leading: back),
            ),
    );
  }
}

class _Confirm extends ConsumerWidget {
  const _Confirm({super.key, required this.leading, required this.onInstall});

  final Widget leading;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final footprint = ref.watch(localFootprintProvider).value;
    final colors = DshColors.of(context);
    final unpacked = footprint?.unpackedMb;
    return OnboardingScaffold(
      leading: leading,
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: AppIcons.thisPhone,
          title: l10n.localEnvInstallTitle,
          message: l10n.localEnvInstallMessage,
        ),
        const SizedBox(height: 28),
        if (footprint != null && footprint.lowStorage)
          OnboardingFact(
            icon: AppIcons.artifacts,
            text: l10n.localEnvLowStorage(footprint.requiredRoundedMb!),
            color: colors.warning,
          )
        else if (unpacked != null)
          OnboardingFact(icon: AppIcons.artifacts, text: l10n.localEnvFactStorage(LocalFootprint.round(unpacked))),
        OnboardingFact(icon: AppIcons.engine, text: l10n.localEnvFactMemory(LocalFootprint.engineMemoryMb)),
        OnboardingFact(icon: AppIcons.localOnly, text: l10n.shellRuntimeLocalOnly),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        FilledButton(onPressed: onInstall, child: Text(l10n.commonInstall)),
      ],
    );
  }
}
