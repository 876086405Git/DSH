import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../runtime/local_paths.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'account_state.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'read_list_epoch.dart';
import 'settings_state.dart';

/// The source of a *display* snapshot. No endpoint token, password, header or
/// credential value is retained. The format version separates future DTOs.
class ReadListIdentity {
  const ReadListIdentity(this.digest);

  factory ReadListIdentity.of(List<Object?> fields) =>
      ReadListIdentity(sha256.convert(utf8.encode(jsonEncode([1, ...fields]))).toString());

  final String digest;

  @override
  bool operator ==(Object other) => other is ReadListIdentity && digest == other.digest;
  @override
  int get hashCode => digest.hashCode;
}

/// Resolve the real root asynchronously. An absent/unknown root is not an
/// identity. Installation changes retry the resolution; start/stop does not.
final localReadListRootProvider = FutureProvider<String?>((ref) async {
  ref.watch(
    localRuntimeProvider.select(
      (s) => (
        s.status.installedVersion,
        s.status.phase == RuntimePhase.installing || s.status.phase == RuntimePhase.notInstalled,
      ),
    ),
  );
  try {
    final root = LocalPaths.root ?? '${(await getApplicationSupportDirectory()).path}/runtime/rootfs';
    return await Directory(root).resolveSymbolicLinks();
  } on Object {
    return null;
  }
});

class _RootEpoch {
  bool resetting = false;
  int generation = 0;

  void observe(bool next) {
    if (next && !resetting) generation++;
    resetting = next;
  }
}

final _rootEpochProvider = Provider((ref) => _RootEpoch());

class _ResolvedDirectories {
  final _digests = <String, String>{};
  String? observe(String config, HostConnection? connection) {
    if (connection != null) {
      final value = ReadListIdentity.of(['resolved-cwd', connection.workingDirectory]).digest;
      _digests.remove(config);
      _digests[config] = value;
      while (_digests.length > 32) {
        _digests.remove(_digests.keys.first);
      }
    }
    return _digests[config];
  }
}

final _resolvedDirectoriesProvider = Provider((ref) => _ResolvedDirectories());

typedef _ReadListMux = ({DshConnectionState state, MuxGeneration? generation});

final _readListMuxProvider = StreamProvider.autoDispose.family<_ReadListMux, DshClient>(
  (ref, client) => Stream.multi((controller) {
    // Subscribe and sample without an await gap; a lost state must not be
    // missed between the initial value and the following events.
    final sub = client.mux.states.listen(
      (_) => controller.addSync((state: client.mux.state, generation: client.mux.generation)),
      onError: controller.addErrorSync,
      onDone: controller.closeSync,
    );
    controller.addSync((state: client.mux.state, generation: client.mux.generation));
    controller.onCancel = sub.cancel;
  }),
);

/// A previous connection carried through AsyncLoading is not a live source.
/// In particular, an unknown SSH selection can fall back to the local engine
/// in activeConnectionProvider; that fallback never qualifies for this cache.
HostConnection? readListConnection(AsyncValue<HostConnection?> value, HostRef selected) {
  if (value.isLoading || value.hasError) return null;
  final connection = value.value;
  if (connection == null || connection.kind != selected.kind) return null;
  if (!selected.isLocal && connection.hostId != selected.id) return null;
  return connection;
}

/// RemoteConnectionController can retain its last client during reconnect.
/// Observed mux loss therefore revokes the *live display authority* too.
/// Listening to states does not open/start a client or the local engine.
final readListLiveConnectionProvider = Provider<HostConnection?>((ref) {
  final connection = readListConnection(ref.watch(activeConnectionProvider), ref.watch(activeHostProvider));
  if (connection == null) return null;
  final status = ref.watch(_readListMuxProvider(connection.client)).value?.state ?? connection.client.mux.state;
  if (status == DshConnectionState.reconnecting ||
      status == DshConnectionState.unauthorized ||
      status == DshConnectionState.closed) {
    return null;
  }
  return connection;
});

final readListIdentityProvider = Provider<ReadListIdentity?>((ref) {
  final selected = ref.watch(activeHostProvider);
  final epoch = ref.watch(readListCredentialEpochProvider);
  final connection = readListConnection(ref.watch(activeConnectionProvider), selected);
  // Host credential events cover writes from other clients while connected.
  // Offline external changes are unknowable: cached rows remain explicitly
  // stale/read-only and expire, rather than claiming current authorization.
  if (connection != null) {
    // A ready generation can change without changing the client/API object or
    // retained account display fields. Its identity proof must recompute now,
    // before a model response can be stamped with the old account's key.
    ref.watch(_readListMuxProvider(connection.client));
    final sub = connection.client.hostEvents.listen((event) {
      if (event is CredentialUpdatedEvent || event is UnknownHostEvent && event.event == 'credentials/record-updated') {
        if (ref.mounted) ref.read(readListCredentialEpochProvider.notifier).advance();
      }
    });
    ref.onDispose(() => unawaited(sub.cancel()));
  }

  switch (selected.kind) {
    case HostKind.local:
      final runtime = ref.watch(localRuntimeProvider);
      final rootEpoch = ref.watch(_rootEpochProvider);
      final resetting =
          runtime.loaded &&
          (runtime.status.phase == RuntimePhase.installing || runtime.status.phase == RuntimePhase.notInstalled);
      rootEpoch.observe(resetting);
      final root = ref.watch(localReadListRootProvider).value;
      final version = runtime.status.installedVersion;
      if (resetting || !runtime.loaded || root == null || version == null || version.isEmpty) return null;
      if (!ref.watch(settingsProvider.select((s) => s.loaded))) return null;
      // AccountController deliberately keeps the last known login across a
      // process disconnect. Unknown identities are never inferred as signed out.
      final account = ref.watch(accountProvider);
      final accountController = ref.read(accountProvider.notifier);
      if (connection == null
          ? !accountController.readListIdentityKnown
          : !accountController.readListIdentityFor(connection.client)) {
        return null;
      }
      final accountId = switch (account.phase) {
        AccountPhase.signedIn => account.profile?.id,
        AccountPhase.signedOut => 'signed-out',
        AccountPhase.unsupported => 'unsupported',
        _ => null,
      };
      if (accountId == null || accountId.length > 256 || root.length > 4096 || version.length > 256) return null;
      return ReadListIdentity.of([
        'local',
        root,
        version,
        runtime.status.mode.name,
        rootEpoch.generation,
        account.phase.name,
        accountId,
        epoch,
      ]);
    case HostKind.ssh:
      final hosts = ref.watch(hostsProvider);
      final host = hosts.sshById(selected.id);
      if (!hosts.loaded ||
          host == null ||
          host.hostKeyType?.trim().isNotEmpty != true ||
          host.hostKeyFingerprint?.trim().isNotEmpty != true) {
        return null;
      }
      if (host.id.length > 256 ||
          host.connectionKey.length > 8192 ||
          (host.workingDirectory?.length ?? 0) > 4096 ||
          host.hostKeyType!.length > 128 ||
          host.hostKeyFingerprint!.length > 512) {
        return null;
      }
      final config = ReadListIdentity.of([
        'ssh',
        host.id,
        host.connectionKey,
        host.workingDirectory,
        host.hostKeyType,
        host.hostKeyFingerprint,
        epoch,
      ]);
      if (connection != null &&
          (host.workingDirectory?.trim().isNotEmpty ?? false) &&
          connection.workingDirectory == null) {
        return null;
      }
      if ((connection?.workingDirectory?.length ?? 0) > 4096) return null;
      final resolved = ref.watch(_resolvedDirectoriesProvider).observe(config.digest, connection);
      return ReadListIdentity.of([config.digest, resolved]);
    case HostKind.relay:
      final account = ref.watch(relayAccountProvider);
      if (account.isLoading || account.hasError) return null;
      final state = account.value;
      final host = state?.hostById(selected.id);
      if (state == null ||
          state.loggingIn ||
          state.user == null ||
          host == null ||
          host.trust != RelayTrust.pinned ||
          host.fingerprint == null ||
          host.fingerprint!.trim().isEmpty) {
        return null;
      }
      final server = ref.watch(relayServerProvider) ?? defaultRelayServer;
      if (server.length > 4096 ||
          state.user!.id.length > 256 ||
          host.id.length > 256 ||
          host.fingerprint!.length > 512 ||
          (host.harnessVersion?.length ?? 0) > 256) {
        return null;
      }
      return ReadListIdentity.of([
        'relay',
        server,
        state.user!.id,
        state.user!.provider,
        host.id,
        host.fingerprint,
        host.harnessVersion,
        epoch,
      ]);
  }
});
