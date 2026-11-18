// What the connected engine says about itself. This describes the engine behind
// this connection, not the phone: a remote host may answer too, Android's engine
// doesn't, and an engine that doesn't answer changes nothing.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// Read again whenever the connection changes. Null when there's no answer.
final runtimeCapabilitiesProvider = FutureProvider.autoDispose<RuntimeCapabilities?>((ref) async {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null || !client.canReadRuntimeCapabilities) return null;
  try {
    return await client.readRuntimeCapabilities();
  } on Object {
    return null;
  }
});

/// The engine said it refuses market installs, so don't offer one to fail.
final marketInstallRefusedProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(runtimeCapabilitiesProvider).value?.plugins.marketInstall == RuntimeSupport.unsupported,
);
