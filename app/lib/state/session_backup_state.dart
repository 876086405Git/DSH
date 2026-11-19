import 'dart:async';
import 'dart:io';

import 'package:dsh_remote/dsh_remote.dart' show RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../remote/session_backup/backup_store.dart';
import 'hosts_state.dart';
import 'read_list_identity.dart';

final sessionBackupStoreProvider = FutureProvider<SessionBackupStore>((ref) async {
  final secrets = ref.watch(secretStoreProvider);
  final root = await getApplicationSupportDirectory();
  return SessionBackupStore.open(Directory('${root.path}/session-backups'), secrets);
});

final sessionBackupSessionProvider = StreamProvider.autoDispose<RemoteHostSession?>((ref) {
  final carrier = ref.watch(readListLiveConnectionProvider)?.client.carrier;
  if (carrier is! RemoteTunnelCarrier) return Stream.value(null);
  final controller = StreamController<RemoteHostSession?>();
  void publish() {
    final session = carrier.session;
    controller.add(session?.isClosed == false ? session : null);
  }

  final sessions = carrier.sessions.listen((_) => publish());
  final states = carrier.states.listen((_) => publish());
  publish();
  ref.onDispose(() {
    unawaited(sessions.cancel());
    unawaited(states.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
});
