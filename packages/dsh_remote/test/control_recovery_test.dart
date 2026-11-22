import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:dsh_remote/src/protocol/control.dart' show encodeRelayDataFrame;
import 'package:test/test.dart';

import 'support/fake_remote.dart';
import 'support/fake_rtc.dart';

const _fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

// Speed up only RelayTransport's recovery-jitter call site. Socket, RPC, mux,
// lease and the independent 15s recovery-handshake deadlines remain real.
Future<void> _fastRecovery(Future<void> Function() body, {List<Timer>? helloDeadlines}) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      final caller = StackTrace.current
          .toString()
          .split('\n')
          .firstWhere((line) => line.contains('RelayTransport.'), orElse: () => '');
      final jitter = duration < const Duration(seconds: 15) && caller.contains('RelayTransport._controlLost');
      final timer = parent.createTimer(zone, jitter ? Duration.zero : duration, callback);
      if (duration == const Duration(seconds: 15) && caller.contains('RelayTransport._reopenControl')) {
        helloDeadlines?.add(timer);
      }
      return timer;
    },
  ),
);

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within 5s');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// Keep the real socket behavior, but retain its registered receive callback to
// deliver one old-generation frame after a replacement socket is established.
class _LateControlSocket extends Stream<dynamic> implements WebSocket {
  _LateControlSocket(this.socket);
  final WebSocket socket;
  void Function(dynamic)? _receive;

  void inject(String frame) => _receive!(frame);

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _receive = onData;
    return socket.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<dynamic> close([int? code, String? reason]) => socket.close(code, reason);
  @override
  void add(dynamic data) => socket.add(data);
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

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;
  late MemorySecretStore secrets;
  final states = <RemoteConnectionPhase>[];
  final failures = <String>[];
  final traced = <({String direction, Map<String, Object?> frame})>[];

  setUp(() async {
    server = await FakeRemoteServer.start();
    server.relayAttach = true;
    server.controlResume = true;
    host = await FakeRemoteHost.start(server);
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    host.onOpen = (stream) => stream.push(followSnapshot('session-1'));
    states.clear();
    failures.clear();
    traced.clear();
    secrets = MemorySecretStore();
    account = RemoteAccount(
      secrets: secrets,
      serverUrl: server.url,
      controlTracer: (direction, frame) => traced.add((direction: direction, frame: frame)),
    );
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
  });

  tearDown(() async {
    await account.close();
    await host.close();
    await server.close();
    expect(server.protocolErrors, isEmpty, reason: 'no lease before hello/Noise or other protocol violation');
  });

  Future<DshClient> connect() async => account.connectHost(
    (await account.listHosts()).single,
    onState: (state) {
      states.add(state.phase);
      if (state.failure != null) failures.add(state.failure!.code);
    },
    muxOptions: _fastMux,
  );

  Future<String> clientId() async => (await account.currentUser())!.deviceId;

  int acknowledgements() =>
      traced.where((entry) => entry.direction == 'in' && entry.frame['type'] == 'connection.lease.ack').length;

  List<Map<String, Object?>> recoveryHellos() => [
    for (final hello in server.clientHellos)
      if (hello.containsKey('recoveryTickets')) hello,
  ];

  test('control recovery preserves in-flight mutation, Noise, nonces, RPC and event subscriptions', () {
    final helloDeadlines = <Timer>[];
    return _fastRecovery(() async {
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final link = server.links.values.single;
      final connection = host.connections[link.id]!;
      final noise = connection.noise;
      final generation = client.mux.generation!;
      final eventStream = host.eventStreams[link.id]!;
      final attached = server.relayAttachments['${link.id}:$me']!;
      final firstTicket = link.leases[me]!;
      final received = noise.receivingCounter;
      final sent = noise.sendingCounter;
      final events = <DshEvent>[];
      final sub = client.watch('session-1').listen(events.add);
      addTearDown(sub.cancel);
      await _eventually(() => events.whereType<SessionSnapshotEvent>().length == 1);
      final follow = connection.streams.values.singleWhere((stream) => stream.endpoint == 'session/follow');
      final streamCount = host.openedStreamParams.length;

      final executed = Completer<void>();
      final reply = Completer<void>();
      final recoveryHello = Completer<void>();
      final helloReply = Completer<void>();
      final leaseRequest = Completer<void>();
      final leaseReply = Completer<void>();
      var mutations = 0;
      host.handlers['session/create'] = (_) {
        mutations++;
        return {
          'ok': true,
          'value': {'sessionId': 'session-new', 'agentPreset': 'standard'},
        };
      };
      host.beforeUnaryResponse = (endpoint) async {
        if (endpoint == 'session/create') {
          executed.complete();
          await reply.future;
        }
      };
      server.beforeRecoveryHelloAck = () async {
        recoveryHello.complete();
        await helloReply.future;
      };
      try {
        final creating = client.createSession(cwd: '/home/host/ws');
        await executed.future.timeout(const Duration(seconds: 5));
        await server.dropControl(me);
        await recoveryHello.future.timeout(const Duration(seconds: 5));

        // The RPC was executed before Control went away. Its encrypted reply and
        // existing logical streams still cross the original live data socket.
        reply.complete();
        expect((await creating).sessionId, 'session-new');
        expect(await client.listSessions(), isEmpty);
        follow.push(logRecord(0, 'turn/start', {'turn': 1}));
        host.emitHostEvent({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'during-recovery',
          'agentId': 'session-1',
          'request': {'toolName': 'bash', 'callId': 'call-1', 'reason': 'escalate'},
        });
        await _eventually(
          () =>
              events.whereType<ApprovalRequestedEvent>().length == 1 && events.whereType<SessionLogEvent>().length == 1,
        );
        expect(acknowledgements(), 1, reason: 'business traffic does not fake a lease acknowledgement');
        expect(states.where((state) => state == RemoteConnectionPhase.reconnecting), isEmpty);
        expect(recoveryHellos().single['recoveryTickets'], [firstTicket]);

        expect(helloDeadlines.single.isActive, isTrue);
        expect(server.leaseRequests, hasLength(1), reason: 'no lease before the recovery hello.ack');
        server.beforeLeaseAck = () async {
          leaseRequest.complete();
          await leaseReply.future;
        };
        helloReply.complete();
        await leaseRequest.future.timeout(const Duration(seconds: 5));
        expect(helloDeadlines.single.isActive, isFalse, reason: 'hello budget ends before the lease ack arrives');
        expect(acknowledgements(), 1);
        expect(await client.listSessions(), isEmpty);
        leaseReply.complete();
        await _eventually(() => acknowledgements() == 2);
        final rotated = link.leases[me]!;
        expect(rotated, isNot(firstTicket));
        await server.dropControl(me, code: 4009, reason: 'heartbeat timeout');
        await _eventually(() => acknowledgements() == 3);
        expect(recoveryHellos().last['recoveryTickets'], [rotated]);
        expect(await client.listSessions(), isEmpty);

        expect(mutations, 1, reason: 'control recovery must never replay a mutation');
        expect(server.links.values.single, same(link));
        expect(host.connections[link.id], same(connection));
        expect(noise.receivingCounter, greaterThan(received));
        expect(noise.sendingCounter, greaterThan(sent));
        expect(client.mux.generation, same(generation));
        expect(host.eventStreams[link.id], same(eventStream));
        expect(host.openedStreamParams, hasLength(streamCount));
        expect(events.whereType<SessionSnapshotEvent>(), hasLength(1));
        expect(server.relayAttachments['${link.id}:$me'], same(attached));
        expect(host.handshakes, [link.id]);
        expect(host.rpcMethods.where((method) => method == 'harness.transport.describe'), hasLength(1));
        expect(states.last, RemoteConnectionPhase.connected);
        expect(server.clientHellos, hasLength(3));
        expect(server.leaseRequests, hasLength(3));
        final types = [for (final raw in server.clientControlFrames) (jsonDecode(raw) as Map<String, Object?>)['type']];
        expect(types.where((type) => type == 'connect.request'), hasLength(1));
        expect(types.where((type) => type == 'secure.handshake'), hasLength(1));
      } finally {
        if (!reply.isCompleted) reply.complete();
        if (!helloReply.isCompleted) helloReply.complete();
        if (!leaseReply.isCompleted) leaseReply.complete();
      }
    }, helloDeadlines: helloDeadlines);
  });

  for (final losesCapability in [false, true]) {
    test(
      '${losesCapability ? 'missing resume capability' : '4012 rejection'} retires the ticket and starts fresh Noise',
      () => _fastRecovery(() async {
        final client = await connect();
        await _eventually(() => acknowledgements() == 1);
        final me = await clientId();
        final first = server.links.values.single;
        final noise = host.connections[first.id]!.noise;
        final ticket = first.leases[me]!;
        final generation = client.mux.generation!;
        if (losesCapability) {
          server.beforeRecoveryHelloAck = () async {
            server.controlResume = false;
          };
        } else {
          server.rejectNextRecovery = true;
        }
        await server.dropControl(me);
        await _eventually(
          () => host.handshakes.length == 2 && client.remoteCarrier!.state?.phase == RemoteConnectionPhase.connected,
        );
        expect(await client.listSessions(), isEmpty);
        final current = server.links.values.single;
        expect(current.id, isNot(first.id));
        expect(host.connections[current.id]!.noise, isNot(same(noise)));
        expect(client.mux.generation, isNot(same(generation)));
        expect(recoveryHellos().single['recoveryTickets'], [ticket]);
        expect(server.clientHellos.last, isNot(contains('recoveryTickets')));
        expect(failures, contains('RECOVERY_REJECTED'));
        if (losesCapability) {
          expect(
            traced.where(
              (entry) =>
                  entry.direction == 'out' &&
                  entry.frame['type'] == 'connection.lease.close' &&
                  (entry.frame['payload']! as Map<String, Object?>)['connectionId'] == first.id,
            ),
            isEmpty,
            reason: 'a recovery ACK without resume cannot authorize a lease.close on that socket',
          );
        }
        expect(host.handshakes, [first.id, current.id]);
        expect(
          states,
          containsAllInOrder([
            RemoteConnectionPhase.connected,
            RemoteConnectionPhase.reconnecting,
            RemoteConnectionPhase.connected,
          ]),
        );
      }),
    );
  }

  test(
    'a mutation executed before rejected recovery has an unknown outcome and is never replayed',
    () => _fastRecovery(() async {
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final first = server.links.values.single.id;
      final entered = Completer<void>();
      final release = Completer<void>();
      var mutations = 0;
      host.handlers['session/create'] = (_) {
        mutations++;
        return {
          'ok': true,
          'value': {'sessionId': 'executed-but-unacknowledged', 'agentPreset': 'standard'},
        };
      };
      host.beforeUnaryResponse = (endpoint) async {
        if (endpoint == 'session/create') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
      };
      try {
        final creating = client.createSession(cwd: '/home/host/ws');
        final unknown = expectLater(creating, throwsA(isA<DshTransportException>()));
        await entered.future.timeout(const Duration(seconds: 5));
        expect(mutations, 1);
        server.rejectNextRecovery = true;
        await server.dropControl(me);
        await unknown.timeout(const Duration(seconds: 5));
        await _eventually(
          () => host.handshakes.length == 2 && client.remoteCarrier!.state?.phase == RemoteConnectionPhase.connected,
        );
        expect(await client.listSessions(), isEmpty);
        final current = server.links.values.single.id;
        final generation = client.mux.generation!;
        final noise = host.connections[current]!.noise;
        expect(current, isNot(first));
        expect(mutations, 1);
        release.complete();
        expect(await client.listSessions(), isEmpty);
        expect(client.mux.generation, same(generation));
        expect(host.connections[current]!.noise, same(noise));
        expect(host.calls.where((call) => call.$1 == 'session/create'), hasLength(1));
        expect(mutations, 1, reason: 'neither recovery nor the fresh tunnel retries the uncertain mutation');
        expect(failures, contains('RECOVERY_REJECTED'));
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }),
  );

  for (final acknowledged in [false, true]) {
    test(
      'control loss without ${acknowledged ? 'negotiated resume' : 'a confirmed lease'} uses a fresh tunnel',
      () => _fastRecovery(() async {
        server.controlResume = !acknowledged;
        server.acknowledgeLeases = acknowledged;
        final client = await connect();
        expect(await client.listSessions(), isEmpty);
        final me = await clientId();
        final first = server.links.values.single.id;
        if (!acknowledged) await _eventually(() => server.leaseRequests.isNotEmpty);
        expect(acknowledgements(), 0);
        await server.dropControl(me);
        await _eventually(
          () => host.handshakes.length == 2 && client.remoteCarrier!.state?.phase == RemoteConnectionPhase.connected,
        );
        expect(await client.listSessions(), isEmpty);
        expect(server.links.values.single.id, isNot(first));
        expect(recoveryHellos(), isEmpty);
        if (acknowledged) expect(server.leaseRequests, isEmpty);
      }),
    );
  }

  for (final failure in ['socket', 'epoch']) {
    test(
      'leased Relay $failure loss still rebuilds the data plane and Noise',
      () => _fastRecovery(() async {
        final client = await connect();
        await _eventually(() => acknowledgements() == 1);
        final me = await clientId();
        final first = server.links.values.single.id;
        final generation = client.mux.generation!;
        final noise = host.connections[first]!.noise;
        switch (failure) {
          case 'socket':
            await server.relayAttachments['$first:$me']!.ws.close();
          case 'epoch':
            server.relayAttachments['$first:$me']!.ws.add(
              encodeRelayDataFrame(
                ControlFrame('relay.ready', {'connectionId': first, 'epoch': server.relayEpoch + 1}),
              ),
            );
        }
        await _eventually(
          () => host.handshakes.length == 2 && client.remoteCarrier!.state?.phase == RemoteConnectionPhase.connected,
        );
        expect(await client.listSessions(), isEmpty);
        final next = server.links.values.single.id;
        expect(next, isNot(first));
        expect(host.handshakes, [first, next]);
        expect(host.connections[next]!.noise, isNot(same(noise)));
        expect(client.mux.generation, isNot(same(generation)));
        expect(client.mux.generation!.clientId, 'remote-client-2');
        expect(recoveryHellos(), isEmpty);
      }),
    );
  }

  test(
    'WebRTC control recovery keeps the DataChannel until active loss reconnects over Relay',
    () => _fastRecovery(() async {
      final network = FakeRtcNetwork();
      server.webrtc = true;
      host.webrtc = true;
      host.rtcNetwork = network;
      await host.goOffline();
      await host.goOnline();
      account.peerConnector = network.connector;
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final first = server.links.values.single;
      final connection = host.connections[first.id]!;
      final rtc = connection.rtc;
      final peer = network.clients.single;
      final noise = connection.noise;
      final received = noise.receivingCounter;
      final generation = client.mux.generation!;
      final events = host.eventStreams[first.id];
      final entered = Completer<void>();
      final release = Completer<void>();
      server.beforeRecoveryHelloAck = () async {
        entered.complete();
        await release.future;
      };
      try {
        await server.dropControl(me);
        await entered.future.timeout(const Duration(seconds: 5));
        expect(await client.listSessions(), isEmpty);
        expect(peer.closed, isFalse);
        expect(states.where((state) => state == RemoteConnectionPhase.reconnecting), isEmpty);
        release.complete();
        await _eventually(() => acknowledgements() == 2);
        expect(await client.listSessions(), isEmpty);
        expect(network.clients, [same(peer)]);
        expect(connection.rtc, same(rtc));
        expect(noise.receivingCounter, greaterThan(received));
        expect(client.mux.generation, same(generation));
        expect(host.eventStreams[first.id], same(events));
        expect(host.handshakes, [first.id]);
        expect(server.relayAttaches, isEmpty);
        expect(server.controlRelayFrames, 0);

        host.closeRtc();
        await _eventually(() => host.handshakes.length == 2 && client.remoteCarrier!.state?.transport == 'relay');
        expect(await client.listSessions(), isEmpty);
        final next = server.links.values.single.id;
        expect(next, isNot(first.id));
        expect(host.connections[next]!.noise, isNot(same(noise)));
        expect(client.mux.generation, isNot(same(generation)));
        expect(network.clients, [same(peer)]);
        expect(peer.closed, isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }),
  );

  test(
    'expired recovery credentials survive a refresh 503 without replacing the leased tunnel',
    () => _fastRecovery(() async {
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final first = server.links.values.single;
      final noise = host.connections[first.id]!.noise;
      server.expireAccessTokens(deviceId: me);
      server.failNextRefresh = true;
      await server.dropControl(me);
      await _eventually(() => acknowledgements() == 2);
      expect(await client.listSessions(), isEmpty);
      expect(server.requests.where((request) => request == 'POST /api/v1/auth/refresh'), hasLength(2));
      expect(server.refreshCount, 1);
      expect(server.links.values.single, same(first));
      expect(host.connections[first.id]!.noise, same(noise));
      expect(host.handshakes, [first.id]);
      expect(recoveryHellos(), hasLength(2), reason: 'one rejected token and one forced-refresh hello');
      expect(states.where((state) => state == RemoteConnectionPhase.reconnecting), isEmpty);
    }),
  );

  test(
    'a queued frame from the old Control socket cannot replace the recovered channel',
    () => _fastRecovery(() async {
      await account.close();
      final controls = <_LateControlSocket>[];
      account = RemoteAccount(
        secrets: secrets,
        serverUrl: server.url,
        controlTracer: (direction, frame) => traced.add((direction: direction, frame: frame)),
        socketConnector: (url, timeout) async {
          final socket = await WebSocket.connect(url.toString()).timeout(timeout);
          if (url.path != '/ws/v1/connect') return socket;
          final control = _LateControlSocket(socket);
          controls.add(control);
          return control;
        },
      );
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final first = server.links.values.single.id;
      final noise = host.connections[first]!.noise;
      final generation = client.mux.generation!;
      final old = controls.single;
      await server.dropControl(me);
      await _eventually(() => acknowledgements() == 2);
      expect(controls, hasLength(2));
      old.inject(
        jsonEncode(
          ControlFrame('error', {
            'connectionId': first,
            'code': 'CONNECTION_REPLACED',
            'message': 'late old socket frame',
            'retryable': false,
          }).toJson(),
        ),
      );
      expect(await client.listSessions(), isEmpty);
      expect(host.connections[first]!.noise, same(noise));
      expect(client.mux.generation, same(generation));
      expect(host.handshakes, [first]);
      expect(server.clientHellos, hasLength(2));
      expect(failures, isNot(contains('CONNECTION_REPLACED')));
      expect(states.where((state) => state == RemoteConnectionPhase.reconnecting), isEmpty);
    }),
  );

  test('no lease is requested before the Noise/RPC receiver is installed', () async {
    final target = (await account.listHosts()).single;
    final transport = await RelayTransport.connect(
      url: controlSocketUrl(server.url),
      deviceId: await clientId(),
      accessToken: await account.accessToken(),
      hostDeviceId: target.id,
    );
    addTearDown(transport.close);
    expect(server.clientHellos.single, isNot(contains('recoveryTickets')));
    expect(host.handshakes, isEmpty);
    expect(server.leaseRequests, isEmpty);
  });

  test(
    'device tokens, initial and rotated recovery tickets never appear in traces',
    () => _fastRecovery(() async {
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final link = server.links.values.single;
      final tickets = <String>{
        ...link.recoveryTickets.values,
        ...link.relayRecoveryTickets.values,
        ...link.leases.values,
      };
      await server.dropControl(me);
      await _eventually(() => acknowledgements() == 2);
      await client.listSessions();
      tickets.addAll(link.leases.values);
      tickets.addAll(server.leaseRequests.map((request) => request['ticket']! as String));
      tickets.addAll(server.relayAttaches.map((side) => side['ticket']! as String));
      tickets.addAll(server.clientHellos.map((hello) => hello['accessToken']! as String));
      final trace = traced.map((entry) => '${entry.direction} ${jsonEncode(entry.frame)}').join('\n');
      expect(trace, contains('connection.lease.request'));
      expect(trace, contains('connection.lease.ack'));
      expect(trace, contains('recoveryTickets'));
      expect(trace, contains('<redacted>'));
      for (final ticket in tickets) {
        expect(trace, isNot(contains(ticket)));
      }
    }),
  );

  test(
    'closing the account during describe immediately retires its confirmed lease',
    () => _fastRecovery(() async {
      host.stallDescribe = true;
      final opening = connect();
      final cancelled = expectLater(opening, throwsA(isA<RemoteConnectException>()));
      await _eventually(() => acknowledgements() == 1 && host.rpcMethods.contains('harness.transport.describe'));
      final me = await clientId();
      final link = server.links.values.single;
      final opens = server.controlConnects;
      final control = server.peers[me]!.ws;
      await account.close().timeout(const Duration(seconds: 5));
      expect(
        traced.any(
          (entry) =>
              entry.direction == 'out' &&
              entry.frame['type'] == 'connection.lease.close' &&
              (entry.frame['payload']! as Map<String, Object?>)['connectionId'] == link.id,
        ),
        isTrue,
        reason: 'lease.close was sent before account.close completed, not after the 10s RPC deadline',
      );
      await _eventually(
        () => server.clientControlFrames.any(
          (raw) => (jsonDecode(raw) as Map<String, Object?>)['type'] == 'connection.lease.close',
        ),
      );
      await control.done.timeout(const Duration(seconds: 5));
      await cancelled.timeout(const Duration(seconds: 5));
      expect(server.controlConnects, opens);
      expect(server.leaseRequests, hasLength(1));
      expect(recoveryHellos(), isEmpty);
      expect(host.handshakes, [link.id]);
      expect(host.openedStreamParams, isEmpty, reason: 'describe never reached mux events setup');
    }),
  );

  test(
    'closing the owner retires a recovery hello waiting for its ack',
    () => _fastRecovery(() async {
      final client = await connect();
      await _eventually(() => acknowledgements() == 1);
      final me = await clientId();
      final entered = Completer<void>();
      final release = Completer<void>();
      server.beforeRecoveryHelloAck = () async {
        entered.complete();
        await release.future;
      };
      try {
        await server.dropControl(me);
        await entered.future.timeout(const Duration(seconds: 5));
        await client.close();
        await _eventually(() => !server.peers.containsKey(me));
        final opens = server.controlConnects;
        release.complete();
        await Future<void>.delayed(Duration.zero);
        expect(server.controlConnects, opens);
        expect(acknowledgements(), 1);
        expect(host.handshakes, hasLength(1));
        expect(client.remoteCarrier!.state?.phase, RemoteConnectionPhase.closed);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }),
  );
}
