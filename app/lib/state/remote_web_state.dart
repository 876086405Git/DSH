import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart' show DshConnectionState, RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'read_list_identity.dart';

/// Each Noise session already holds its fresh harness.transport.describe.
/// Observe session replacement, not the carrier's cached capabilities.
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
      final connected = carrier.state?.isConnected ?? connection!.client.mux.state == DshConnectionState.connected;
      output.addSync(
        connected && session != null && !session.isClosed && session.capabilities.contains('dsh.web.v1')
            ? session
            : null,
      );
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
