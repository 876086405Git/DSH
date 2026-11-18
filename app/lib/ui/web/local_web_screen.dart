import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/local_footprint.dart';
import '../../state/engine_control.dart';
import '../../state/settings_state.dart';
import '../common/empty_view.dart';
import '../common/progress_halo.dart';
import '../engine/engine_screen.dart';
import '../engine/engine_status.dart';
import '../onboarding/local_install.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'web_target.dart';
import 'web_view_page.dart';

/// `http://127.0.0.1:3080/?token=…` — the official DSH Web UI's launch URL.
Uri localWebUri(String baseUrl, String token) =>
    Uri.parse(baseUrl).replace(path: '/', queryParameters: {'token': token});

/// The official DSH Web UI served by the local engine: the fallback for anything
/// the native UI doesn't do yet (plugins, advanced settings…).
class LocalWebScreen extends ConsumerWidget {
  const LocalWebScreen({super.key, this.target, this.handle, this.link, this.onSession});

  /// Page to land on (a session, a panel, a settings section…).
  final DshWebTarget? target;

  /// 网页模式: the page is the app's home; [handle] takes the back button's
  /// seat (and a place in the engine page's bar while the engine is down).
  final Widget Function(double size)? handle;

  /// See [WebViewPage.link] and [WebViewPage.onSession].
  final DshWebLink? link;
  final ValueChanged<String?>? onSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    final phoneLayout = ref.watch(settingsProvider.select((s) => s.webPhoneLayout));
    if (status.isRunning) {
      return WebViewPage(
        // A restart issues a new token, and the layout switch applies on
        // load: rebuild the WebView for either.
        key: ValueKey((status.token, phoneLayout)),
        url: localWebUri(status.baseUrl!, status.token!),
        title: context.l10n.webTitle,
        subtitle: context.l10n.commonThisPhone,
        externalDisabledReason: context.l10n.webLocalAppOnly,
        dshWeb: true,
        phoneLayout: phoneLayout,
        openTarget: target,
        leading: handle,
        root: handle != null,
        link: link,
        onSession: onSession,
      );
    }
    return _NotRunning(handle: handle);
  }
}

class _NotRunning extends ConsumerWidget {
  const _NotRunning({this.handle});

  final Widget Function(double size)? handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localRuntimeProvider);
    final phase = state.status.phase;
    final busy = phase == RuntimePhase.starting || phase == RuntimePhase.installing;
    final canStart = phase == RuntimePhase.installed || phase == RuntimePhase.error;
    final failed = phase == RuntimePhase.error;
    // Nothing on this phone: the one way forward is installing it (or, on a
    // build without the runtime, a remote host).
    final missing = state.status.runtimeMissing;
    final missingCopy = localMissingCopy(context.l10n, available: state.available);
    return AppPage(
      title: context.l10n.commonWeb,
      showLargeTitle: false,
      actions: [
        ?handle?.call(44),
        GlassIconButton(
          icon: AppIcons.engine,
          tooltip: context.l10n.webEngineStatus,
          // As the home (网页模式) it stays underneath; as a page it gives way.
          onPressed: () {
            final route = MaterialPageRoute<void>(builder: (_) => const EngineScreen());
            final navigator = Navigator.of(context);
            unawaited(handle != null ? navigator.push(route) : navigator.pushReplacement(route));
          },
        ),
      ],
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 80),
            child: Center(
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.standard),
                switchInCurve: AppMotion.std,
                switchOutCurve: AppMotion.std,
                child: EmptyView(
                  key: ValueKey(phase),
                  art: busy ? const ProgressHalo(size: 96, strokeWidth: 3) : null,
                  icon: failed
                      ? AppIcons.error
                      : missing
                      ? AppIcons.thisPhone
                      : AppIcons.webApp,
                  title: phase == RuntimePhase.installing
                      ? context.l10n.shellRuntimePreparing
                      : busy
                      ? context.l10n.webEngineStarting
                      : failed
                      ? context.l10n.webEngineStartFailed
                      : missing
                      ? missingCopy.title
                      : context.l10n.webEngineNotRunning,
                  message: failed
                      ? (humanizeRuntimeError(state.status.error) ?? context.l10n.webEngineProblem)
                      : busy
                      ? context.l10n.webStartingSoon
                      : missing
                      ? null
                      : context.l10n.webStartToOpen,
                  action: missing
                      ? FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
                          onPressed: () => unawaited(openLocalInstall(context)),
                          child: Text(missingCopy.action),
                        )
                      : canStart
                      ? FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
                          onPressed: () => unawaited(EngineControl.ensureStarted(ProviderScope.containerOf(context))),
                          child: Text(failed ? context.l10n.webRestart : context.l10n.webStartEngine),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
