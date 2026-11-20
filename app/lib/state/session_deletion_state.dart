import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'artifact_files.dart' show imageSnapshotHost;
import 'composer_quote.dart';
import 'connection_state.dart';
import 'draft_store.dart';
import 'drawer_view_state.dart';
import 'hosts_state.dart';
import 'image_snapshots.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'sessions_state.dart';

/// Test seam; production always uses the authenticated Host bridge, never
/// direct phone filesystem access or archive as a substitute for deletion.
abstract interface class SessionDeletionBackend {
  Future<bool> supported(DshClient client);
  Future<void> delete(DshClient client, String sessionId);
}

class _HostSessionDeletion implements SessionDeletionBackend {
  const _HostSessionDeletion();
  @override
  Future<bool> supported(DshClient client) => client.supportsSessionDeletion();
  @override
  Future<void> delete(DshClient client, String sessionId) => client.deleteSessionPermanently(sessionId);
}

final sessionDeletionBackendProvider = Provider<SessionDeletionBackend>((ref) => const _HostSessionDeletion());

/// What this App knows about the Host's permanent-deletion capability.
///
/// [unknown] is a real answer and is not a refusal: the App may simply not have
/// a live connection yet, or the mux may not have a ready generation. Only a
/// Host that answered is [supported] or [unsupported]; the UI must never turn
/// "not asked yet" into "this host does not support it".
enum SessionDeletionSupport { unknown, supported, unsupported }

final sessionDeletionAvailableProvider = FutureProvider.autoDispose<SessionDeletionSupport>((ref) async {
  final connection = ref.watch(readListLiveConnectionProvider);
  if (connection == null) return SessionDeletionSupport.unknown;
  // A new ready generation may answer differently (reconnect, Host restart).
  // This listener is registered before the readiness check on purpose: the
  // "not ready yet" answer below must be re-probed as soon as the mux is up,
  // even though the connection object itself does not change.
  final ready = connection.client.mux.generations.listen((_) => ref.invalidateSelf());
  ref.onDispose(() => unawaited(ready.cancel()));
  if (connection.client.mux.generation == null) return SessionDeletionSupport.unknown;
  final backend = ref.watch(sessionDeletionBackendProvider);
  final supported = await backend.supported(connection.client);
  return supported ? SessionDeletionSupport.supported : SessionDeletionSupport.unsupported;
});

/// Consent captured before an action sheet/confirmation, re-checked at every
/// destructive step.
///
/// It survives a mux reconnect: deleting is one HTTP request, not an operation
/// on the event stream, so a network blip must not turn into "host changed".
/// A real departure still retires it for good, so A -> B -> A cannot revive an
/// old confirmation: a host switch or a replaced connection is remembered.
class SessionDeletionOwner {
  SessionDeletionOwner._(this.container, this.connection, this.host);

  static SessionDeletionOwner? capture(ProviderContainer container) {
    final connection = container.read(readListLiveConnectionProvider);
    if (connection == null) return null;
    final owner = SessionDeletionOwner._(container, connection, container.read(activeHostProvider));
    final host = container.listen(activeHostProvider, (_, next) {
      if (next != owner.host) owner._retired = true;
    });
    final active = container.listen(activeConnectionProvider, (_, next) {
      if (next.isLoading || next.hasError || !identical(next.value, connection)) owner._retired = true;
    });
    owner._close = () {
      host.close();
      active.close();
    };
    return owner;
  }

  final ProviderContainer container;
  final HostConnection connection;
  final HostRef host;
  bool _retired = false;
  bool _closed = false;
  late final void Function() _close;

  bool get current {
    if (_retired || _closed) return false;
    try {
      final active = container.read(activeConnectionProvider);
      return !active.isLoading &&
          !active.hasError &&
          identical(active.value, connection) &&
          container.read(activeHostProvider) == host;
    } on StateError {
      return false;
    }
  }

  bool isCurrent(WidgetRef ref) =>
      current && identical(ProviderScope.containerOf(ref.context, listen: false), container);

  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}

SessionDeletionOwner? captureSessionDeletionOwner(WidgetRef ref) =>
    SessionDeletionOwner.capture(ProviderScope.containerOf(ref.context, listen: false));

class SessionDeletionResult {
  const SessionDeletionResult({this.deleted = const [], this.failures = const {}, this.retired = false});
  final List<String> deleted;

  /// Session id -> stable, localizable reason; never raw Host messages/paths.
  final Map<String, String> failures;
  final bool retired;
}

class SessionDeletionController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<SessionDeletionResult> delete(List<String> sessionIds, {required SessionDeletionOwner owner}) async {
    final ids = sessionIds.toSet().toList();
    bool owned() => ref.mounted && identical(ref.container, owner.container) && owner.current;
    if (!owned()) return const SessionDeletionResult(retired: true);
    if (state) return SessionDeletionResult(failures: {for (final id in ids) id: 'busy'});
    if (ids.isEmpty) return const SessionDeletionResult();
    final deleted = <String>[];
    final failures = <String, String>{};
    final backend = ref.read(sessionDeletionBackendProvider);
    final client = owner.connection.client;
    final identity = ref.read(readListIdentityProvider);
    final snapshots = ref.read(imageSnapshotsProvider);
    final snapshotHost = imageSnapshotHost(owner.connection);
    state = true;
    try {
      if (!owned()) return const SessionDeletionResult(retired: true);
      // No pre-flight capability call: the delete request itself answers
      // `unavailable` on a Host without the route, and that is the only place
      // that answer is needed. One intent, one request.
      for (final id in ids) {
        if (!owned()) break;
        final sessions = ref.read(sessionsProvider.notifier);
        final rejection = sessions.beginDeletion(id);
        if (rejection != null) {
          failures[id] = rejection;
          continue;
        }
        try {
          if (!owned()) break;
          await backend.delete(client, id);
          // Disk cleanup must not delay an acknowledged deletion or the next
          // item in the batch. It belongs to the captured Host, even if retired.
          unawaited(
            snapshots.removeSession(snapshotHost, id).catchError((Object error) {
              debugPrint('Image snapshot cleanup failed: ${error.runtimeType}');
            }),
          );
          // A late response belongs to its old Host, never to a new screen.
          if (!owned()) break;
          deleted.add(id);
          ref.read(readListCacheProvider).invalidateKind(ReadListKind.sessions, identity);
          ref.read(draftStoreProvider.notifier).forget(id);
          if (!owned()) break;
          ref.read(composerQuoteProvider.notifier).clear(id);
          if (!owned()) break;
          sessions.confirmDeleted(id);
          if (!owned()) break;
          if (ref.read(currentSessionProvider) == id) ref.read(currentSessionProvider.notifier).select(null);
          if (!owned()) break;
          await ref.read(drawerViewProvider.notifier).forgetSessions({id}, isCurrent: owned);
        } catch (error) {
          if (!owned()) break;
          // A cleanup failure must not relabel an acknowledged deletion as a
          // failed destructive request. UI refresh can recover local metadata.
          if (!deleted.contains(id)) {
            final code = _failureCode(error);
            failures[id] = code;
            if (code == 'connection-lost' || code == 'protocol-error') {
              // The server may have committed before its reply was lost. Stop
              // the batch; further deletes require another explicit intent.
              for (final remaining in ids.skip(ids.indexOf(id) + 1)) {
                failures[remaining] = 'not-attempted';
              }
              break;
            }
          }
        } finally {
          if (owned()) sessions.endDeletion(id);
        }
      }
      return SessionDeletionResult(
        deleted: List.unmodifiable(deleted),
        failures: Map.unmodifiable(failures),
        retired: !owned(),
      );
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

String _failureCode(Object error) => switch (error) {
  DshRemoteException(:final code) =>
    const {'session-active', 'session-related', 'writer-held', 'not-found', 'unavailable', 'busy'}.contains(code)
        ? code
        : 'failed',
  DshProtocolException() => 'protocol-error',
  DshHttpException() ||
  DshTransportException() ||
  DshCarrierLostException() ||
  DshClosedException() => 'connection-lost',
  _ => 'failed',
};

final sessionDeletionProvider = NotifierProvider<SessionDeletionController, bool>(SessionDeletionController.new);
final sessionDeletionBusyProvider = Provider<bool>((ref) => ref.watch(sessionDeletionProvider));
