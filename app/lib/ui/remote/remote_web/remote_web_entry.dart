import 'package:dsh_remote/dsh_remote.dart' show RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/android_features.dart';
import '../../../state/read_list_identity.dart';
import '../../../state/remote_web_state.dart';
import '../../theme/app_icons.dart';
import 'remote_web_page.dart';

final _launchers = Provider.autoDispose.family<_RemoteWebLauncher, RemoteHostSession>(
  (ref, session) => _RemoteWebLauncher(),
);

class _RemoteWebLauncher {
  Future<void>? _shown;

  void open(BuildContext context, RemoteTunnelCarrier carrier, RemoteHostSession session, Set<String> domains) {
    if (_shown != null) return;
    _shown = Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => RemoteWebPage(carrier: carrier, session: session, trustedTunnelDomains: domains),
          ),
        )
        .whenComplete(() => _shown = null);
  }
}

/// The current Remote Host's DSH Web, not the Remote account console.
class RemoteWebEntry extends ConsumerWidget {
  const RemoteWebEntry({super.key, this.trustedTunnelDomains = const {'hostc.4ba.io'}});

  /// Trusted application configuration only; never learn domains from open RPC.
  final Set<String> trustedTunnelDomains;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final os = ref.watch(operatingSystemProvider);
    if (os != 'android' && os != 'ios') return const SizedBox.shrink();
    final session = ref.watch(remoteWebSessionProvider).value;
    final carrier = ref.watch(readListLiveConnectionProvider)?.client.carrier;
    if (session == null ||
        carrier is! RemoteTunnelCarrier ||
        !identical(carrier.session, session) ||
        session.isClosed) {
      return const SizedBox.shrink();
    }
    final launcher = ref.watch(_launchers(session));
    return TextButton.icon(
      icon: const Icon(AppIcons.browser),
      label: Text(context.l10n.remoteWebOpen),
      onPressed: () => launcher.open(context, carrier, session, Set.unmodifiable(trustedTunnelDomains)),
    );
  }
}
