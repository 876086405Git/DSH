// Real app selection/provider lifecycle, SDK, Noise and loopback WebSockets.
// Only delivery of the first raw Control socket is gated. No timer or sleep
// triggers the switch; the guard below only bounds a broken test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/relay/network_route.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart' as app_secrets;
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_remote/test/support/fake_remote.dart';
import '../../../packages/dsh_remote/test/support/fake_rtc.dart';

const _guard = Duration(seconds: 10);

// These are plain async tests. Keep their real loopback HTTP/WS instead of
// the widget binding's synthetic HTTP 400 response.
class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _NoLocalConnection extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

// Observe only frame types, never token-bearing payloads. Everything is
// delegated to the actual dart:io socket, including its close handshake.
class _ObservedSocket extends Stream<dynamic> implements WebSocket {
  _ObservedSocket(this.socket);
  final WebSocket socket;
  final frameTypes = <String>[];
  final closeInvoked = Completer<void>();
  Future<dynamic>? closing;
  int closeCalls = 0;

  @override
  Future<dynamic> close([int? code, String? reason]) {
    closeCalls++;
    final result = closing = socket.close(code, reason);
    if (!closeInvoked.isCompleted) closeInvoked.complete();
    return result;
  }

  @override
  void add(dynamic data) {
    if (data is String) {
      final frame = jsonDecode(data);
      if (frame is Map && frame['type'] is String) frameTypes.add(frame['type'] as String);
    }
    socket.add(data);
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => socket.addError(error, stackTrace);
  @override
  Future<dynamic> addStream(Stream<dynamic> stream) => socket.addStream(stream);
  @override
  void addUtf8Text(List<int> bytes) => socket.addUtf8Text(bytes);
  @override
  Future<dynamic> get done => socket.done;
  @override
  int? get closeCode => socket.closeCode;
  @override
  String? get closeReason => socket.closeReason;
  @override
  String get extensions => socket.extensions;
  @override
  String? get protocol => socket.protocol;
  @override
  int get readyState => socket.readyState;
  @override
  Duration? get pingInterval => socket.pingInterval;
  @override
  set pingInterval(Duration? value) => socket.pingInterval = value;
}

class _FirstControlGate {
  _FirstControlGate() {
    // A connector failure is still delivered to both its caller and observers.
    // Attach an early handler so teardown can await it without an unhandled gap.
    delivered.future.ignore();
  }

  final entered = Completer<void>();
  final _release = Completer<void>();
  final delivered = Completer<_ObservedSocket>();
  final sockets = <_ObservedSocket>[];
  int calls = 0;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<WebSocket> connect(Uri url, Duration timeout) async {
    final first = calls++ == 0;
    if (first) {
      entered.complete();
      await _release.future;
    }
    try {
      final socket = _ObservedSocket(await WebSocket.connect(url.toString()).timeout(timeout));
      sockets.add(socket);
      if (first) delivered.complete(socket);
      return socket;
    } on Object catch (error, stack) {
      if (first && !delivered.isCompleted) delivered.completeError(error, stack);
      rethrow;
    }
  }

  Future<void> closeSockets() async {
    // Attempt every owned socket even when one close fails. Future.wait keeps
    // the first failure while waiting for the other bounded cleanups.
    await Future.wait<void>([
      for (final observed in sockets) Future<void>.sync(() async => await observed.socket.close()).timeout(_guard),
    ]);
  }
}

class _Fixture {
  _Fixture(this.server, this.a, this.b, this.gate, this.backend, this.container);
  final FakeRemoteServer server;
  final FakeRemoteHost a;
  final FakeRemoteHost b;
  final _FirstControlGate gate;
  final DshRemoteRelayBackend backend;
  final ProviderContainer container;

  HostRef get hostA => HostRef.relay(a.deviceId, name: 'A');
  HostRef get hostB => HostRef.relay(b.deviceId, name: 'B');

  static Future<_Fixture> start({required bool attach}) async {
    final server = await FakeRemoteServer.start();
    // Register ownership immediately. The test runner executes every teardown
    // in reverse order even after setup, assertions or an earlier cleanup fail.
    addTearDown(() => server.close().timeout(_guard));
    server.relayAttach = attach;
    final a = await FakeRemoteHost.start(server, name: 'A');
    addTearDown(() => a.close().timeout(_guard));
    final b = await FakeRemoteHost.start(server, name: 'B');
    addTearDown(() => b.close().timeout(_guard));
    for (final (host, label) in [(a, 'a'), (b, 'b')]) {
      host.handlers['session/list'] = (args) => {
        'ok': true,
        'value': {
          'items': [
            {'sessionId': 'session-$label', 'title': label, 'createdAt': 1786000000000, 'updatedAt': 1786000000000},
          ],
        },
      };
    }
    final gate = _FirstControlGate();
    addTearDown(gate.closeSockets);
    addTearDown(() async {
      gate.release();
      if (gate.entered.isCompleted) await gate.delivered.future.timeout(_guard);
    });
    final account = remote.RemoteAccount(
      secrets: remote.MemorySecretStore(),
      serverUrl: server.url,
      socketConnector: gate.connect,
    );
    final secrets = app_secrets.MemorySecretStore();
    final backend = DshRemoteRelayBackend(secrets: secrets, account: account, direct: false);
    // The override below does not run the production provider's disposer.
    addTearDown(() => backend.close().timeout(_guard));
    await backend.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    for (final host in await backend.listHosts()) {
      backend.approveHost(host);
    }
    final container = ProviderContainer(
      overrides: [
        relayBackendProvider.overrideWithValue(backend),
        secretStoreProvider.overrideWithValue(secrets),
        localConnectionProvider.overrideWith(_NoLocalConnection.new),
        networkKicksProvider.overrideWithValue(const Stream<void>.empty()),
      ],
    );
    addTearDown(container.dispose);
    final observer = container.listen(activeConnectionProvider, (_, _) {}, fireImmediately: true);
    addTearDown(observer.close);
    await container.read(activeHostProvider.notifier).ready;
    return _Fixture(server, a, b, gate, backend, container);
  }

  Future<void> select(HostRef host) async {
    container.read(activeHostProvider.notifier).select(host);
    await container.pump();
  }

  Future<HostConnection> ready(HostRef host) async {
    final connection = await container.read(remoteConnectionProvider(host).future).timeout(_guard);
    expect(connection, isNotNull);
    expect(connection!.hostId, host.id);
    return connection;
  }
}

void main() {
  _LoopbackBinding();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('network kicks probe a healthy data plane instead of replacing it on route changes', () async {
    final server = await FakeRemoteServer.start();
    addTearDown(() => server.close().timeout(_guard));
    server.webrtc = true;
    final network = FakeRtcNetwork();
    final host = await FakeRemoteHost.start(server)
      ..webrtc = true
      ..rtcNetwork = network;
    addTearDown(() => host.close().timeout(_guard));
    await host.goOffline();
    await host.goOnline();
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    var route = RemoteNetworkRoute.local;
    var routeReads = 0;
    final backend = DshRemoteRelayBackend(
      secrets: app_secrets.MemorySecretStore(),
      serverUrl: server.url,
      peerConnector: network.connector,
      resolveNetworkRoute: () async {
        routeReads++;
        return route;
      },
    );
    addTearDown(() => backend.close().timeout(_guard));
    await backend.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final target = (await backend.listHosts()).single;
    backend.approveHost(target);
    final link = RelayHostLink(backend: backend, hostId: target.id, resolveHost: () async => target);
    addTearDown(() => link.close().timeout(_guard));
    final client = await link.open().timeout(_guard);
    final carrier = client.remoteCarrier!;
    final session = carrier.session!;
    final connectionId = server.links.keys.single;
    final initialRouteReads = routeReads;
    expect(initialRouteReads, greaterThan(0));
    var describes = host.rpcMethods.where((method) => method == 'harness.transport.describe').length;

    for (final next in [RemoteNetworkRoute.remote, RemoteNetworkRoute.local]) {
      route = next;
      link.kick();
      expect(await backend.probe(client).timeout(_guard), isTrue);
      expect(host.rpcMethods.where((method) => method == 'harness.transport.describe'), hasLength(++describes));
      expect(routeReads, initialRouteReads, reason: 'interface hints are read only for a new transport selection');
      expect(link.status.isConnected, isTrue);
      expect(link.currentClient, same(client));
      expect(carrier.session, same(session));
      expect(server.links.keys.single, connectionId);
      expect(host.handshakes, [connectionId]);
      expect(network.clients, hasLength(1));
      expect(network.clients.single.closed, isFalse);
      expect(await client.listSessions().timeout(_guard), isEmpty);
    }
    expect(server.protocolErrors, isEmpty);
  });

  for (final attach in [false, true]) {
    final mode = attach ? 'relay.attach' : 'control relay';
    test('$mode: switching A to B retires the late A socket before hello', () async {
      final fixture = await _Fixture.start(attach: attach);
      await fixture.select(fixture.hostA);
      await fixture.gate.entered.future.timeout(_guard);
      final oldLink = fixture.container.read(hostLinkProvider(fixture.hostA))!;
      final oldCarrier = fixture.backend.account.activeClient!.remoteCarrier!;

      // This is the real selection/disposal path, not concurrent direct
      // calls to RemoteAccount.connectHost.
      await fixture.select(fixture.hostB);
      final current = await fixture.ready(fixture.hostB);
      await fixture.container.pump();
      expect(oldCarrier.isClosed, isTrue);
      await expectLater(oldLink.open(), throwsStateError);
      expect(fixture.backend.account.activeClient, same(current.client));

      fixture.gate.release();
      final late = await fixture.gate.delivered.future.timeout(_guard);
      await late.closeInvoked.future.timeout(_guard);
      await late.closing!.timeout(_guard);

      List<SessionSummary>? sessions;
      Object? rpcError;
      try {
        sessions = await current.client.listSessions().timeout(_guard);
      } on Object catch (error) {
        rpcError = error;
      }
      // All observations are collected before the first behavioral
      // assertion, so a red hello assertion does not hide B's RPC result.
      debugPrint(
        'RELAY_OWNER ${jsonEncode({'mode': mode, 'retiredClosed': oldCarrier.isClosed, 'lateFrameTypes': late.frameTypes, 'lateCloseCalls': late.closeCalls, 'currentPhase': current.client.remoteCarrier?.state?.phase.name, 'currentFailureCode': current.client.remoteCarrier?.lastFailure?.code, 'rpcSucceeded': rpcError == null})}',
      );
      expect(
        late.frameTypes,
        isNot(contains('hello')),
        reason: 'an obsolete owner must not replace the current device Control',
      );
      expect(late.closeCalls, 1);
      expect(fixture.backend.account.activeClient, same(current.client));
      expect(current.client.mux.state, DshConnectionState.connected);
      expect(rpcError, isNull, reason: 'B remains usable after late A is retired');
      expect(sessions!.map((session) => session.sessionId), ['session-b']);
      expect(fixture.container.read(activeHostProvider), fixture.hostB);
      expect(fixture.server.protocolErrors, isEmpty);
    });

    test('$mode: a current pending socket still sends hello and becomes usable', () async {
      final fixture = await _Fixture.start(attach: attach);
      await fixture.select(fixture.hostA);
      await fixture.gate.entered.future.timeout(_guard);
      fixture.gate.release();
      final current = await fixture.ready(fixture.hostA);
      final socket = await fixture.gate.delivered.future.timeout(_guard);
      expect(socket.frameTypes.where((type) => type == 'hello'), hasLength(1));
      expect(socket.closeCalls, 0);
      expect(fixture.backend.account.activeClient, same(current.client));
      expect(current.client.mux.state, DshConnectionState.connected);
      expect((await current.client.listSessions()).map((session) => session.sessionId), ['session-a']);
      expect(fixture.server.protocolErrors, isEmpty);
    });
  }
}
