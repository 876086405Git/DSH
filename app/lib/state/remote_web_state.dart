import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart' show DshConnectionState, RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart' show HostConnection;
import 'read_list_identity.dart';

/// [connection]'s live Noise session, when it can open the Host's DSH Web
/// (`dsh.web.v1`, from that session's own fresh harness.transport.describe).
/// Readable at once: a tap that nothing watched before must not wait for
/// [remoteWebSessionProvider]'s first event.
RemoteHostSession? liveDshWebSession(HostConnection? connection) {
  if (!isLiveTunnel(connection)) return null;
  final session = (connection!.client.carrier as RemoteTunnelCarrier).session;
  return session != null && !session.isClosed && session.capabilities.contains('dsh.web.v1') ? session : null;
}

/// [connection] is a DSH Remote tunnel, connected right now.
bool isLiveTunnel(HostConnection? connection) {
  final carrier = connection?.client.carrier;
  return carrier is RemoteTunnelCarrier &&
      (carrier.state?.isConnected ?? connection!.client.mux.state == DshConnectionState.connected);
}

/// [liveDshWebSession] as it changes. Each Noise session already holds its
/// fresh harness.transport.describe: observe session replacement, not the
/// carrier's cached capabilities.
final remoteWebSessionProvider = StreamProvider.autoDispose<RemoteHostSession?>((ref) {
  final connection = ref.watch(readListLiveConnectionProvider);
  final carrier = connection?.client.carrier;
  if (carrier is! RemoteTunnelCarrier) return Stream.value(null);
  return Stream.multi((output) {
    var cancelled = false;
    RemoteHostSession? observed;
    void sample() {
      if (cancelled) return;
      final session = carrier.session;
      if (!identical(observed, session)) {
        observed = session;
        if (session != null) {
          unawaited(
            session.rpc.done.then((_) {
              if (!cancelled && identical(observed, session)) sample();
            }),
          );
        }
      }
      output.addSync(liveDshWebSession(connection));
    }

    final sessions = carrier.sessions.listen((_) => sample());
    final states = carrier.states.listen((_) => sample());
    sample();
    output.onCancel = () async {
      cancelled = true;
      await sessions.cancel();
      await states.cancel();
    };
  });
});
