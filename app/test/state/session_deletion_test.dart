import 'dart:async';

import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/image_snapshots.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/session_deletion_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';
import 'read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _SwitchHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  void set(HostRef host) => state = host;
}

class _Backend implements SessionDeletionBackend {
  bool support = true;
  int supportCalls = 0;
  final calls = <String>[];
  final failures = <String, Object>{};
  final gates = <String, Completer<void>>{};
  void Function(String)? afterDelete;

  @override
  Future<bool> supported(DshClient client) async {
    supportCalls++;
    return support;
  }
  @override
  Future<void> delete(DshClient client, String sessionId) async {
    calls.add(sessionId);
    if (gates[sessionId] case final gate?) await gate.future;
    if (failures[sessionId] case final error?) throw error;
    afterDelete?.call(sessionId);
  }
}

class _Snapshots extends ImageSnapshots {
  final calls = <(String, String)>[];
  Future<void>? pending;

  @override
  Future<void> removeSession(String host, String sessionId) async {
    calls.add((host, sessionId));
    await pending;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, FakeWorkspaceHost, _Backend)> start({
    bool running = false,
    ImageSnapshots? snapshots,
  }) async {
    final host = FakeWorkspaceHost();
    host.seedSession('s1', 'First', DateTime.now(), running: running);
    host.seedSession('s2', 'Second', DateTime.now());
    final connection = workspaceHost(host);
    await connection.client.mux.start();
    final backend = _Backend();
    final container = ProviderContainer(
      overrides: [
        switchConnectionProvider.overrideWith(() => SwitchConnection(connection)),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        activeHostProvider.overrideWith(_SwitchHost.new),
        readListIdentityProvider.overrideWithValue(null),
        sessionDeletionBackendProvider.overrideWithValue(backend),
        imageSnapshotsProvider.overrideWithValue(snapshots ?? _Snapshots()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await connection.client.close();
    });
    await container.read(sessionsProvider.future);
    await container.read(drawerViewProvider.notifier).ready();
    backend.afterDelete = (id) => host.sessions.removeWhere((s) => s['sessionId'] == id);
    return (container, host, backend);
  }

  SessionDeletionOwner owner(ProviderContainer container) {
    final value = SessionDeletionOwner.capture(container)!;
    addTearDown(value.close);
    return value;
  }

  test('snapshot cleanup cannot delay the deletion receipt or the next batch item', () async {
    final cleanup = Completer<void>();
    final snapshots = _Snapshots()..pending = cleanup.future;
    final (container, _, backend) = await start(snapshots: snapshots);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.deleted, ['s1', 's2']);
    expect(result.failures, isEmpty);
    expect(backend.calls, ['s1', 's2']);
    expect(container.read(sessionDeletionProvider), isFalse);
    expect(snapshots.calls, [('local:', 's1'), ('local:', 's2')]);
    cleanup.complete();
    await pumpEventQueue();
  });

  test('a snapshot cleanup failure does not turn a confirmed deletion into failure', () async {
    final cleanup = Completer<void>();
    final snapshots = _Snapshots()..pending = cleanup.future;
    final (container, _, _) = await start(snapshots: snapshots);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    cleanup.completeError(StateError('controlled cleanup failure'));
    await pumpEventQueue();
    expect(result.deleted, ['s1']);
    expect(result.failures, isEmpty);
    expect(container.read(sessionDeletionProvider), isFalse);
  });

  test('only acknowledged rows, selection and drafts are cleared; failed row stays', () async {
    final (container, _, backend) = await start();
    final drafts = container.read(draftStoreProvider.notifier);
    drafts.save('s1', 'private draft', const []);
    drafts.save('s2', 'keep draft', const []);
    container.read(composerQuoteProvider.notifier).set('s1', 'quote');
    container.read(currentSessionProvider.notifier).select('s1');
    await container.read(drawerViewProvider.notifier).createFolder('Folder', sessionIds: ['s1', 's2']);
    backend.failures['s2'] = const DshRemoteException('writer-held', 'private details');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.deleted, ['s1']);
    expect(result.failures, {'s2': 'writer-held'});
    expect(result.retired, isFalse);
    // The delete path is intent -> request: no extra capability roundtrip.
    expect(backend.supportCalls, 0);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(draftStoreProvider).drafts.containsKey('s1'), isFalse);
    expect(container.read(draftStoreProvider).drafts['s2']?.text, 'keep draft');
    expect(container.read(composerQuoteProvider).containsKey('s1'), isFalse);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, ['s2']);
    expect(container.read(sessionDeletionBusyProvider), isFalse);
  });

  test('running row and pending archive never reach destructive backend', () async {
    final (container, _, backend) = await start(running: true);
    final pending = container.read(sessionsProvider.notifier).scheduleArchive(['s2']);
    addTearDown(pending.release);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.failures, {'s1': 'session-active', 's2': 'archive-pending'});
    expect(backend.calls, isEmpty);
    pending.cancel();
  });

  test('a Host without the route keeps every row and reports unavailable per row', () async {
    final (container, _, backend) = await start();
    // A Host that has no deletion route answers the POST with 404, which the
    // client surfaces as a stable `unavailable` refusal. There is no separate
    // pre-flight capability call in the delete path.
    backend.failures['s1'] = const DshRemoteException('unavailable', 'controlled fake refusal');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.failures, {'s1': 'unavailable'});
    expect(backend.calls, ['s1']);
    expect(backend.supportCalls, 0);
    expect(container.read(sessionsProvider).value, hasLength(2));
  });

  test('host A -> B -> A irrevocably retires an old deletion authority', () async {
    final (container, _, backend) = await start();
    final captured = owner(container);
    expect(captured.current, isTrue);
    final hosts = container.read(activeHostProvider.notifier) as _SwitchHost;
    hosts.set(HostRef.ssh('pc'));
    hosts.set(HostRef.local);
    expect(captured.current, isFalse);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    expect(result.retired, isTrue);
    expect(backend.calls, isEmpty);
  });

  test('late response after owner departure cannot clear new selection or send next item', () async {
    final (container, _, backend) = await start();
    backend.gates['s1'] = Completer<void>();
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls, ['s1']);
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(HostRef.ssh('pc'));
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(HostRef.local);
    container.read(currentSessionProvider.notifier).select('s2');
    backend.gates['s1']!.complete();
    final result = await operation;
    expect(result.retired, isTrue);
    expect(backend.calls, ['s1']);
    expect(container.read(currentSessionProvider), 's2');
  });

  test('duplicate intent is busy and does not send twice', () async {
    final (container, _, backend) = await start();
    backend.gates['s1'] = Completer<void>();
    final captured = owner(container);
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    await Future<void>.delayed(Duration.zero);
    final duplicate = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    expect(duplicate.failures, {'s1': 'busy'});
    expect(backend.calls, ['s1']);
    backend.gates['s1']!.complete();
    await operation;
  });

  test('lost or invalid response stops batch without retry; remaining items not attempted', () async {
    final (container, _, backend) = await start();
    backend.failures['s1'] = const DshTransportException('reply lost');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(backend.calls, ['s1']);
    expect(result.failures, {'s1': 'connection-lost', 's2': 'not-attempted'});
    expect(container.read(sessionsProvider).value, hasLength(2));
  });

  test('late old inventory cannot resurrect a confirmed deletion', () async {
    final (container, _, backend) = await start();
    backend.afterDelete = null; // Fake stale session/list continues serving the old row.
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.deleted, ['s1']);
    await container.read(sessionsProvider.notifier).refresh();
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
  });

  test('deleted final folder member is removed even with empty remaining inventory', () async {
    final (container, _, _) = await start();
    await container.read(drawerViewProvider.notifier).createFolder('Last', sessionIds: ['s1', 's2']);
    await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(container.read(sessionsProvider).value, isEmpty);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, isEmpty);
  });

  test('late restore and outgoing screen saves cannot resurrect a forgotten draft', () async {
    SharedPreferences.setMockInitialValues({DraftStore.preferenceKey: '{"s1":{"t":"saved","at":1}}'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    store.forget('s1');
    store.save('s1', 'outgoing screen', const []);
    await store.flush();
    expect(container.read(draftStoreProvider).drafts.containsKey('s1'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DraftStore.preferenceKey), '{}');
  });

  test('no live connection answers unknown, not unsupported, and asks nobody', () async {
    final backend = _Backend();
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        activeHostProvider.overrideWith(_SwitchHost.new),
        sessionDeletionBackendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(sessionDeletionAvailableProvider, (previous, next) {});
    addTearDown(sub.close);

    await pumpEventQueue();
    expect(container.read(sessionDeletionAvailableProvider).value, SessionDeletionSupport.unknown);
    expect(backend.supportCalls, 0);
  });

  test('a mux without a ready generation is re-probed when one arrives', () async {
    final host = FakeWorkspaceHost();
    final connection = workspaceHost(host);
    addTearDown(connection.client.close);
    final backend = _Backend();
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection)),
        activeHostProvider.overrideWith(_SwitchHost.new),
        sessionDeletionBackendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(container.dispose);
    final answered = Completer<SessionDeletionSupport>();
    final sub = container.listen(sessionDeletionAvailableProvider, (previous, next) {
      final value = next.value;
      if (value != null && value != SessionDeletionSupport.unknown && !answered.isCompleted) {
        answered.complete(value);
      }
    });
    addTearDown(sub.close);

    // The connection exists but its mux has no ready generation: nothing is
    // asked yet, and the answer must stay "unknown" (the UI says "temporarily
    // unavailable"), never "this host does not support it".
    await pumpEventQueue();
    expect(container.read(sessionDeletionAvailableProvider).value, SessionDeletionSupport.unknown);
    expect(backend.supportCalls, 0);

    // Once the mux is ready the probe runs by itself: the connection object
    // did not change, so only the generation listener can trigger it.
    await connection.client.mux.start();
    await pumpEventQueue(times: 5);
    expect(await answered.future.timeout(const Duration(seconds: 5)), SessionDeletionSupport.supported);
    expect(backend.supportCalls, 1);
  });
}
