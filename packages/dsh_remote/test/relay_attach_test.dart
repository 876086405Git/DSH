// `transport.relay.attach` (upstream aae3125, 7dd2e2c): with a Relay
// assignment the ciphertext moves to the node's data socket; an older Server
// or Host keeps the Control-socket path.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;
  final traced = <String>[];

  setUp(() async {
    server = await FakeRemoteServer.start();
    server.relayAttach = true;
    host = await FakeRemoteHost.start(server);
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    traced.clear();
    account = RemoteAccount(
      secrets: MemorySecretStore(),
      serverUrl: server.url,
      controlTracer: (direction, frame) => traced.add('$direction ${jsonEncode(frame)}'),
    );
  });

  tearDown(() async {
    expect(server.protocolErrors, isEmpty, reason: 'the client never violated the Control protocol');
    await account.close();
    await host.close();
    await server.close();
  });

  Future<DshClient> connect({void Function(RemoteConnectionState state)? onState}) async {
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    return account.connectHost((await account.listHosts()).single, onState: onState, muxOptions: fastMux);
  }

  Future<String> clientId() async => (await account.currentUser())!.deviceId;

  List<String> controlTypes() => [
    for (final raw in server.clientControlFrames) (jsonDecode(raw) as Map<String, Object?>)['type']! as String,
  ];

  test('attaches to the assigned node, then ciphertext and heartbeats use only its socket', () async {
    final client = await connect();
    expect(await client.listSessions(), isEmpty);
    final me = await clientId();
    final link = server.links.values.single;
    expect(server.peers[me]!.capabilities, ['transport.relay.resume.v1', 'transport.relay', 'transport.relay.attach']);
    expect(server.relayAttaches, [
      {
        'connectionId': link.id,
        'deviceId': me,
        'peerDeviceId': host.deviceId,
        'ticket': link.assignments[me]!['relayTicket'],
      },
      // The Host attaches after the client's transport.selected (plugin 0.6.0).
      {
        'connectionId': link.id,
        'deviceId': host.deviceId,
        'peerDeviceId': me,
        'ticket': link.assignments[host.deviceId]!['relayTicket'],
      },
    ]);
    final types = controlTypes();
    expect(types, ['connect.request', 'transport.selected', 'secure.handshake']);
    expect(server.relayFrames, greaterThanOrEqualTo(4), reason: 'describe, \$events open and list, both ways');
    await _eventually(() => server.relayPongs.any((pong) => pong.startsWith('$me node-')));
    expect(client.remoteCarrier!.state!.transport, 'relay');
  });

  test('the ticket never goes on the Control socket, and traces redact it', () async {
    final client = await connect();
    await client.listSessions();
    final tickets = [for (final a in server.links.values.single.assignments.values) a['relayTicket']! as String];
    expect(tickets, hasLength(2));
    for (final raw in server.clientControlFrames) {
      expect(raw, isNot(contains('icket')));
      for (final ticket in tickets) {
        expect(raw, isNot(contains(ticket)));
      }
    }
    final trace = traced.join('\n');
    expect(trace, contains('data-out'));
    expect(trace, contains('relay.attach'));
    for (final ticket in tickets) {
      expect(trace, isNot(contains(ticket)));
    }
  });

  test('relay.detach or a dropped data socket ends the connection; the next one is fresh', () async {
    final states = <RemoteConnectionPhase>[];
    final client = await connect(onState: (s) => states.add(s.phase));
    await client.listSessions();
    final me = await clientId();
    final first = server.links.values.single.id;

    // The Host leaves the node: the node sends relay.detach to the client.
    await host.detachClients();
    await _eventually(() => host.handshakes.length == 2);
    expect(await client.listSessions(), isEmpty);
    final second = server.links.values.single.id;

    // The node drops the client's data socket.
    await server.relayAttachments['$second:$me']!.ws.close();
    await _eventually(() => host.handshakes.length == 3);
    expect(await client.listSessions(), isEmpty);
    final third = server.links.values.single.id;

    expect({first, second, third}, hasLength(3), reason: 'every reconnect is a new Server connection');
    expect(host.handshakes, [first, second, third], reason: 'and a new Noise handshake');
    final mine = server.relayAttaches.where((a) => a['deviceId'] == me).toList();
    expect([for (final a in mine) a['connectionId']], [first, second, third]);
    expect({for (final a in mine) a['ticket']}, hasLength(3));
    await _eventually(() => states.last == RemoteConnectionPhase.connected);
    expect(
      states,
      containsAllInOrder([
        RemoteConnectionPhase.connected,
        RemoteConnectionPhase.reconnecting,
        RemoteConnectionPhase.connected,
        RemoteConnectionPhase.reconnecting,
        RemoteConnectionPhase.connected,
      ]),
    );
  });

  test('an older Server without attach keeps ciphertext on the Control socket', () async {
    server.relayAttach = false;
    await host.goOffline();
    await host.goOnline();
    final client = await connect();
    expect(await client.listSessions(), isEmpty);
    expect(server.peers[await clientId()]!.capabilities, contains('transport.relay.attach'));
    expect(server.relayAttaches, isEmpty);
    final types = controlTypes();
    expect(types, containsAllInOrder(['connect.request', 'transport.selected', 'secure.handshake', 'relay']));
  });

  test('an older Host gets no assignment, so the client stays on the Control socket', () async {
    host.relayAttach = false;
    await host.goOffline();
    await host.goOnline();
    final client = await connect();
    expect(await client.listSessions(), isEmpty);
    expect(server.links.values.single.assignments, isEmpty);
    expect(server.relayAttaches, isEmpty);
    expect(controlTypes(), containsAllInOrder(['connect.request', 'transport.selected', 'secure.handshake', 'relay']));
  });
}

Future<void> _eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
