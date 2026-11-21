import 'package:dsh_remote/dsh_remote.dart' show RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/ssh_link.dart';
import '../../state/android_features.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/plugins_state.dart' show installedPluginsProvider;
import '../../state/read_list_identity.dart';
import '../../state/remote_web_state.dart';
import '../../state/settings_state.dart';
import '../../state/ui_mode_state.dart';
import '../remote/remote_web/remote_web_page.dart';
import 'local_web_screen.dart';
import 'web_target.dart';
import 'web_view_page.dart';

/// Where the active host's DSH Web can be opened from.
sealed class DshWebAccess {
  const DshWebAccess();
}

/// 本机: the on-device engine's `dsh web` ([LocalWebScreen] handles a
/// stopped engine itself).
final class LocalDshWeb extends DshWebAccess {
  const LocalDshWeb();
}

/// An SSH host: the remote `dsh web` through the app's local forward.
///
/// DSH's browser fence accepts any loopback Host, so the WebView can talk to
/// `127.0.0.1:<forward port>` directly; the launch token logs it in.
final class SshDshWeb extends DshWebAccess {
  const SshDshWeb(this.url, this.hostName);
  final Uri url;
  final String hostName;
}

/// A DSH Remote host: its DSH Web through the Remote tunnel, on the live
/// Noise session ([RemoteWebPage]; Android and iPhone, the Host's Remote
/// plugin 0.6.6 or later with DSH Web running). It lands on the home page:
/// the page gets no JavaScript bridge, so no [DshWebTarget].
final class RelayDshWeb extends DshWebAccess {
  const RelayDshWeb(this.carrier, this.session);
  final RemoteTunnelCarrier carrier;
  final RemoteHostSession session;
}

/// No web page for this host right now; [reason] says why.
final class NoDshWeb extends DshWebAccess {
  const NoDshWeb(this.reason);
  final String reason;
}

/// The active host's DSH Web, if it has one the app can reach.
final dshWebAccessProvider = Provider.autoDispose<DshWebAccess>((ref) {
  final host = ref.watch(activeHostProvider);
  switch (host.kind) {
    case HostKind.local:
      return const LocalDshWeb();
    case HostKind.relay:
      final os = ref.watch(operatingSystemProvider);
      if (os != 'android' && os != 'ios') return NoDshWeb(appL10n.webRelayUnavailable);
      // Rebuild on session replacement and link changes; the answer itself is
      // read at once, for a tap nothing watched before (their first events
      // arrive a moment later).
      ref.watch(remoteWebSessionProvider);
      ref.watch(hostLinkStatusProvider(host));
      final connection = ref.watch(readListLiveConnectionProvider);
      if (liveDshWebSession(connection) case final session?) {
        return RelayDshWeb(connection!.client.carrier as RemoteTunnelCarrier, session);
      }
      // Connected without `dsh.web.v1`: an older Remote plugin, or DSH Web
      // not running on the Host.
      if (isLiveTunnel(connection)) return NoDshWeb(appL10n.remoteWebHostNotReady);
      return NoDshWeb(appL10n.webConnectHostFirst(ref.watch(hostNameProvider(host)) ?? appL10n.commonRemoteHost));
    case HostKind.ssh:
      // Rebuild once the link connects (or reconnects to a new process).
      ref.watch(hostLinkStatusProvider(host));
      final link = ref.watch(hostLinkProvider(host));
      final name = ref.watch(hostNameProvider(host)) ?? appL10n.webSshHost;
      final port = link is SshHostLink ? link.localPort : null;
      final token = link is SshHostLink ? link.endpoint?.token : null;
      if (port == null || token == null) {
        return NoDshWeb(appL10n.webConnectHostFirst(name));
      }
      return SshDshWeb(localWebUri('http://127.0.0.1:$port', token), name);
  }
});

/// A page that decides how it is left for DSH Web: [openDshWeb] from inside
/// it (its rows that say 「在网页版编辑此项」) hands the target to [onOpen]
/// instead, which lands it and goes there when the page can be left — a page
/// whose own edits DSH Web would otherwise race (plugin_config_page.dart).
class DshWebOpenScope extends InheritedWidget {
  const DshWebOpenScope({super.key, required this.onOpen, required super.child});

  final void Function(DshWebTarget target) onOpen;

  static DshWebOpenScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<DshWebOpenScope>();

  @override
  bool updateShouldNotify(DshWebOpenScope oldWidget) => false;
}

/// Opens the active host's official DSH Web, landing on [target]. In
/// 网页模式 the home page itself goes there (no second page on top). Inside
/// a [DshWebOpenScope] the page around decides.
void openDshWeb(BuildContext context, WidgetRef ref, {DshWebTarget target = const DshWebTarget()}) {
  if (DshWebOpenScope.maybeOf(context) case final scope?) {
    scope.onOpen(target);
    return;
  }
  // A plugin's entry id is no name its card has: name its bundle.
  if (target.pluginItem.isNotEmpty) target = target.withPluginNames(ref.read(installedPluginsProvider).value);
  if (ref.read(uiModeProvider).web) {
    ref.read(webOpenProvider.notifier).request(target);
    return;
  }
  final Widget page;
  switch (ref.read(dshWebAccessProvider)) {
    case LocalDshWeb():
      page = LocalWebScreen(target: target);
    case SshDshWeb(:final url, :final hostName):
      page = WebViewPage(
        url: url,
        title: context.l10n.webTitle,
        subtitle: hostName,
        externalDisabledReason: context.l10n.webSshAppOnly,
        // Android suspends the page in the background and its socket drops.
        reloadAfterBackground: const Duration(seconds: 60),
        dshWeb: true,
        phoneLayout: ref.read(settingsProvider).webPhoneLayout,
        openTarget: target,
      );
    case RelayDshWeb(:final carrier, :final session):
      // One page at a time: a second tap while it is up adds nothing (a
      // second open would revoke the first page's lease).
      if (_relayWebRoute?.isActive ?? false) return;
      final route = MaterialPageRoute<void>(
        builder: (_) => RemoteWebPage(carrier: carrier, session: session),
      );
      _relayWebRoute = route;
      Navigator.of(context).push(route);
      return;
    case NoDshWeb(:final reason):
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(reason)));
      return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

/// The last pushed [RemoteWebPage]'s route: no longer active once popped or
/// its navigator is gone.
Route<void>? _relayWebRoute;
