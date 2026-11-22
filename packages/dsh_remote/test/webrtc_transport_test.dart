// Direct path (LAN / P2P / TURN) over a fake WebRTC stack: signaling order,
// transport.selected before Noise, ciphertext on the DataChannel only, and
// RTC-to-Relay fallback on the same tunnel; TURN retries use a fresh one. Upstream:
// packages/webrtc/src/adaptive-transport.ts, rtc-data-channel.ts,
// rtc-chunking.ts; Host side packages/plugin/src/server-connection.ts.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:dsh_remote/src/transport/rtc_chunking.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';
import 'support/fake_rtc.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

void main() {
  group('RTCH chunking', () {
    test('passes small messages through and splits large ones like upstream', () {
      final codec = RtcChunkCodec();
      final small = Uint8List.fromList(List.generate(rtcChunkPayloadBytes, (i) => i % 251));
      expect(codec.encode(small), [same(small)]);

      final large = Uint8List.fromList(List.generate(20000, (i) => i % 253));
      final frames = codec.encode(large);
      expect([for (final f in frames) f.length], [12 + 8192, 12 + 8192, 12 + 20000 - 16384]);
      // "RTCH", messageId 1, index 1, total 3 (big-endian).
      expect(frames[1].sublist(0, 12), [0x52, 0x54, 0x43, 0x48, 0, 0, 0, 1, 0, 1, 0, 3]);

      final decoder = RtcChunkCodec();
      expect(decoder.decode(frames[0]), isNull);
      expect(decoder.decode(frames[1]), isNull);
      expect(decoder.decode(frames[2]), large);
      expect(decoder.decode(small), small);
    });

    test('fails closed on reordered, duplicated or malformed chunks', () {
      final frames = RtcChunkCodec().encode(Uint8List(3 * rtcChunkPayloadBytes));
      expect(() => RtcChunkCodec().decode(frames[1]), throwsA(isA<RtcChunkError>()));
      final duplicate = RtcChunkCodec()..decode(frames[0]);
      expect(() => duplicate.decode(frames[0]), throwsA(isA<RtcChunkError>()));
      final truncated = Uint8List.fromList(frames[0].sublist(0, 100));
      expect(() => RtcChunkCodec().decode(truncated), throwsA(isA<RtcChunkError>()));
      expect(() => RtcChunkCodec().encode(Uint8List(rtcChunkMaxMessageBytes + 1)), throwsA(isA<RtcChunkError>()));
    });
  });

  group('selected path', () {
    test('reads the selected pair like upstream inspectSelectedPath', () {
      expect(selectedPeerPath(pairStats('host', '192.168.1.20', 'host', '10.0.0.5')), RemoteTransportMode.lan);
      expect(selectedPeerPath(pairStats('srflx', '203.0.113.7', 'srflx', '198.51.100.9')), RemoteTransportMode.p2p);
      expect(selectedPeerPath(pairStats('host', '192.168.1.20', 'relay', '198.51.100.9')), RemoteTransportMode.turn);
      // Tailscale shows up as host candidates but is not a physical LAN.
      expect(selectedPeerPath(pairStats('host', '100.101.1.2', 'host', '100.88.3.4')), RemoteTransportMode.p2p);
      // Android reports an mDNS-hidden LAN peer as prflx without an address.
      expect(
        selectedPeerPath(
          [...pairStats('host', '192.168.1.20', 'prflx', '')]
            ..[1] = {'type': 'remote-candidate', 'id': 'R1', 'candidateType': 'prflx'},
        ),
        RemoteTransportMode.lan,
      );
      final withoutTransport = pairStats('host', '192.168.1.20', 'host', '192.168.1.30').take(3).toList();
      expect(selectedPeerPath(withoutTransport), isNull, reason: 'nomination alone does not confirm a successful pair');
      withoutTransport[2]['state'] = 'succeeded';
      expect(selectedPeerPath(withoutTransport), RemoteTransportMode.lan);
      expect(selectedPeerPath(const []), isNull);
    });

    test('STUN-only keeps direct servers', () {
      final servers = stunOnlyIceServers(const [
        RemoteIceServer(['stun:stun.example:3478', 'turn:turn.example:3478'], username: 'u', credential: 'c'),
        RemoteIceServer(['turns:turn.example:5349']),
      ]);
      expect(servers, hasLength(1));
      expect(servers.single.urls, ['stun:stun.example:3478']);
      expect(servers.single.username, isNull);
    });

    test('RTT uses the current selected pair and rejects stale or invalid measurements', () {
      final stats = pairStats('host', '192.168.1.20', 'host', '192.168.1.30');
      stats[2]['currentRoundTripTime'] = 0.0125;
      expect(selectedPeerRoundTripTime(stats), const Duration(microseconds: 12500));
      for (final invalid in [-1, double.nan, double.infinity, '0.1']) {
        stats[2]['currentRoundTripTime'] = invalid;
        expect(selectedPeerRoundTripTime(stats), isNull, reason: '$invalid');
      }
      stats[2]['currentRoundTripTime'] = 0.05;
      stats.last['selectedCandidatePairId'] = 'missing-new-pair';
      expect(selectedPeerRoundTripTime(stats), isNull);
      expect(selectedPeerPath(stats), isNull, reason: 'old nominated pairs must not replace a missing current pair');
    });
  });

  group('native trickle ICE failures', () {
    for (final opened in [false, true]) {
      test('Control failure with DataChannel opened=$opened never escapes the callback', () async {
        final control = _SignalControl();
        final network = FakeRtcNetwork();
        final stats = Completer<void>();
        network.statsGate = stats.future;
        addTearDown(() {
          if (!stats.isCompleted) stats.complete();
        });
        _ClosingPeer? peer;
        final opening = WebRtcTransport.negotiate(
          control: control,
          connector: (servers, handlers) async => peer = _ClosingPeer(await network.connector(servers, handlers)),
          iceServers: (_) async => [],
          timeout: const Duration(seconds: 5),
        );
        const failure = RemoteTransportException(
          'AUTH_INVALID',
          'Control authorization failed.',
          retryable: false,
          closeCode: 4001,
        );
        final rejected = expectLater(
          opening,
          throwsA(
            isA<RemoteTransportException>()
                .having((e) => e.code, 'code', failure.code)
                .having((e) => e.message, 'message', failure.message)
                .having((e) => e.retryable, 'retryable', failure.retryable)
                .having((e) => e.closeCode, 'closeCode', failure.closeCode),
          ),
        );
        await _eventually(() => control.signals.contains('signal.ice'));
        final handlers = network.clients.single.handlers;
        if (opened) {
          handlers.onOpen();
          await _eventually(() => peer?.inspecting ?? false);
        }
        control.signalError = failure;

        expect(
          () => handlers.onIceCandidate({'candidate': 'candidate:late 1 udp 1234 192.168.1.20 5000 typ host'}),
          returnsNormally,
        );
        stats.complete();
        await rejected;

        expect(control.closed, isTrue);
        expect(network.clients.single.closed, isTrue);
        expect(control.signals, ['signal.offer', 'signal.ice']);
      });
    }

    test('selected data plane ignores late ICE but an active DataChannel close still ends Control', () async {
      final control = _SignalControl();
      final network = FakeRtcNetwork();
      final opening = WebRtcTransport.negotiate(
        control: control,
        connector: network.connector,
        iceServers: (_) async => [],
      );
      await _eventually(() => control.signals.contains('signal.ice'));
      final handlers = network.clients.single.handlers;
      handlers.onOpen();
      final transport = await opening;
      addTearDown(transport.close);
      final closed = <RemoteTransportClosed>[];
      transport.listen(onData: (_, _) {}, onHandshake: (_, _) {}, onClosed: closed.add);
      control.signalError = const RemoteTransportException('CONNECTION_FAILED', 'Control is recovering.');
      final signals = [...control.signals];

      expect(
        () => handlers.onIceCandidate({'candidate': 'candidate:late 1 udp 1234 192.168.1.20 5000 typ host'}),
        returnsNormally,
      );

      expect(control.signals, signals);
      expect(control.closed, isFalse);
      expect(network.clients.single.closed, isFalse);
      expect(closed, isEmpty);
      handlers.onClosed('active DataChannel failed');
      expect(control.closed, isTrue);
      expect(network.clients.single.closed, isTrue);
      expect(closed.single.code, 'CONNECTION_FAILED');
    });
  });

  group('connectHost', () {
    late FakeRemoteServer server;
    late FakeRemoteHost host;
    late FakeRtcNetwork network;
    late RemoteAccount account;
    final fallbacks = <String>[];

    setUp(() async {
      server = await FakeRemoteServer.start();
      server.webrtc = true;
      network = FakeRtcNetwork();
      host = await FakeRemoteHost.start(server)
        ..webrtc = true
        ..rtcNetwork = network;
      await host.goOffline();
      await host.goOnline();
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': <Object?>[]},
      };
      host.handlers['session/search'] = (args) => {'ok': true, 'value': args};
      fallbacks.clear();
      account = RemoteAccount(
        secrets: MemorySecretStore(),
        serverUrl: server.url,
        peerConnector: network.connector,
        onDirectFallback: fallbacks.add,
        directTimeout: const Duration(milliseconds: 300),
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

    List<Map<String, Object?>> clientFrames() => [
      for (final raw in server.clientControlFrames) (jsonDecode(raw) as Map).cast<String, Object?>(),
    ];

    List<String> types() => [for (final f in clientFrames()) f['type']! as String];

    test('offer, ICE both ways, transport.selected, then Noise; traffic on the DataChannel only', () async {
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478', 'turn:turn.example:3478?transport=udp'],
          'username': 'u',
          'credential': 'c',
        },
      ];
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      final link = server.links.values.single;

      expect(server.peers[await clientId()]!.capabilities, [
        'transport.webrtc.resume.v1',
        'transport.relay.resume.v1',
        'transport.lan',
        'transport.p2p',
        'transport.turn',
        'transport.relay',
        'transport.relay.attach',
      ]);
      final request = clientFrames().firstWhere((f) => f['type'] == 'connect.request');
      expect((request['payload']! as Map)['preferredTransports'], ['lan', 'p2p', 'turn', 'relay']);
      final seen = types();
      expect(seen.first, 'connect.request');
      // The candidate the stack reported before createOffer returned waits
      // for the offer: the Host has nothing to add it to before that.
      expect(seen.indexOf('signal.offer'), lessThan(seen.indexOf('signal.ice')));
      expect(seen.indexOf('signal.ice'), lessThan(seen.indexOf('transport.selected')));
      expect(seen.indexOf('transport.selected'), lessThan(seen.indexOf('secure.handshake')));
      final selected = clientFrames().singleWhere((f) => f['type'] == 'transport.selected')['payload']! as Map;
      expect(selected, {'connectionId': link.id, 'targetDeviceId': host.deviceId, 'transport': 'lan'});

      expect(server.turnRequests, [link.id]);
      expect(network.iceServers.single.single.urls, ['stun:stun.example:3478']);
      expect(network.clients.single.channelLabel, 'dsh');
      expect(host.rtcCandidates[link.id], 1);
      expect(host.handshakes, [link.id]);
      expect(client.remoteCarrier!.state!.transport, 'lan');

      // A response over 8 KiB crosses as RTCH chunks, one over 48 KiB also
      // as DSHF fragments; neither touches the Relay.
      final big = 'x' * (200 * 1024);
      final echoed = await client.rpc.call('session/search', {'big': big});
      expect((echoed! as Map)['big'], big);
      expect(server.controlRelayFrames, 0);
      expect(server.relayFrames, 0);
      expect(seen, isNot(contains('relay')));
      expect(network.clients.single.sent, greaterThan(25), reason: 'the 200 KiB request went out in 8 KiB chunks');
      expect(fallbacks, isEmpty);
    });

    test('ICE failure selects Relay on the same tunnel before its only Noise handshake', () async {
      server.webrtcTransports.remove('transport.turn');
      network.outcome = FakeRtcOutcome.fail;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(fallbacks, ['directFailed']);
      expect(network.clients.single.closed, isTrue);

      final requests = [
        for (final f in clientFrames())
          if (f['type'] == 'connect.request') (f['payload']! as Map)['preferredTransports'],
      ];
      expect(requests, [
        ['lan', 'p2p', 'relay'],
      ]);
      expect(server.turnRequests, hasLength(1));
      expect(host.rtcOffers, hasLength(1));
      final relayConnection = server.links.values.single.id;
      expect(host.rtcOffers.single, relayConnection);
      expect(host.handshakes, [relayConnection], reason: 'Noise starts only after selecting Relay');
      final selected = clientFrames().singleWhere((f) => f['type'] == 'transport.selected')['payload']! as Map;
      expect(selected, {'connectionId': relayConnection, 'targetDeviceId': host.deviceId, 'transport': 'relay'});
      expect(types().where((t) => t == 'secure.handshake'), hasLength(1));
      expect(server.controlRelayFrames, greaterThan(0));
    });

    test('a DataChannel that never opens times out to the Relay', () async {
      server.webrtcTransports.remove('transport.turn');
      network.outcome = FakeRtcOutcome.silent;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(fallbacks.single, 'directTimeout');
      expect(host.handshakes, hasLength(1));
      expect(host.handshakes.single, host.rtcOffers.single);
    });

    test('the Server negotiation budget overrides a longer local deadline', () async {
      server.webrtcTransports.remove('transport.turn');
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      network.creationGate = gate.future;
      server.webrtcFallbackTimeoutMs = 50;
      await account.close();
      account = RemoteAccount(
        secrets: MemorySecretStore(),
        serverUrl: server.url,
        peerConnector: network.connector,
        onDirectFallback: fallbacks.add,
        directTimeout: const Duration(seconds: 8),
      );

      final client = await connect().timeout(const Duration(seconds: 3));

      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(fallbacks, ['directTimeout']);
      expect(types().where((t) => t == 'connect.request'), hasLength(1));
      gate.complete();
      await _eventually(() => network.clients.single.closed);
      expect(await client.listSessions(), isEmpty);
    });

    test('a late native creation falls back and disposes its peer without sending an offer', () async {
      server.webrtcTransports.remove('transport.turn');
      final gate = Completer<void>();
      network.creationGate = gate.future;
      final client = await connect();
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(await client.listSessions(), isEmpty);
      expect(fallbacks.single, 'directTimeout');
      expect(network.clients.single.closed, isFalse);
      gate.complete();
      await _eventually(() => network.clients.single.closed);
      final handlers = network.clients.single.handlers;
      handlers.onOpen();
      handlers.onIceCandidate({'candidate': 'candidate:late 1 udp 1234 192.168.1.20 5000 typ host'});
      handlers.onMessage(Uint8List.fromList([0x52, 0x54, 0x43, 0x48]));
      handlers.onClosed('late native close');
      expect(types(), isNot(contains('signal.offer')));
      expect(types(), isNot(contains('signal.ice')));
      expect(types().where((t) => t == 'connect.request'), hasLength(1));
      expect(host.handshakes, hasLength(1));
      expect(await client.listSessions(), isEmpty);
    });

    test('a stalled native offer and teardown cannot hold up the Relay fallback', () async {
      final gate = Completer<void>();
      network
        ..offerGate = gate.future
        ..closeGate = Completer<void>().future;
      final client = await connect();
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(await client.listSessions(), isEmpty);
      expect(fallbacks.single, 'directTimeout');
      expect(network.clients.single.closed, isTrue);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(types(), isNot(contains('signal.offer')));
      expect(host.handshakes, hasLength(1));
    });

    test('native failure followed by negotiation abort releases the peer only once', () async {
      final gate = Completer<void>();
      network.offerGate = gate.future;
      late RemotePeerHandlers handlers;
      _ClosingPeer? peer;
      account.peerConnector = (servers, callbacks) async {
        handlers = callbacks;
        return peer = _ClosingPeer(await network.connector(servers, callbacks));
      };
      final connecting = connect();
      await _eventually(() => peer?.offering ?? false);
      handlers.onOpen();
      handlers.onClosed('ICE failed immediately after opening');
      gate.complete();
      final client = await connecting;

      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(await client.listSessions(), isEmpty);
      expect(peer!.closes, 1, reason: 'the native failure and abort share ownership of one peer');
      expect(types(), isNot(contains('signal.offer')));
    });

    test('a DataChannel closing during stats uses fresh Relay before Noise', () async {
      server.webrtcTransports.remove('transport.turn');
      final stats = Completer<void>();
      addTearDown(() {
        if (!stats.isCompleted) stats.complete();
      });
      network.statsGate = stats.future;
      final connecting = connect();
      await _eventually(() => network.clients.isNotEmpty && network.clients.single.open);
      network.clients.single.handlers.onClosed('closed before transport.selected');
      stats.complete();

      final client = await connecting;

      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(network.clients.single.closed, isTrue);
      expect(types().where((t) => t == 'connect.request'), hasLength(2));
      expect(host.handshakes, hasLength(1));
      expect(host.handshakes.single, isNot(host.rtcOffers.single));
      expect(await client.listSessions(), isEmpty);
    });

    test('a synchronous provisional peer close failure cannot interrupt same-tunnel Relay fallback', () async {
      server.webrtcTransports.remove('transport.turn');
      network.outcome = FakeRtcOutcome.fail;
      late _ClosingPeer peer;
      account.peerConnector = (servers, callbacks) async =>
          peer = _ClosingPeer(await network.connector(servers, callbacks), throwOnClose: true);

      final client = await connect();

      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(await client.listSessions(), isEmpty);
      expect(peer.closes, 1);
      await _eventually(() => server.links.length == 1);
      expect(host.handshakes, hasLength(1));
      expect(fallbacks, ['directFailed']);
    });

    test('stalled stats are bounded and do not discard a working DataChannel', () async {
      network.statsGate = Completer<void>().future;
      final client = await connect();
      expect(client.remoteCarrier!.state!.transport, 'p2p');
      expect(await client.listSessions(), isEmpty);
      expect(fallbacks, isEmpty);
      expect(server.controlRelayFrames, 0);
    });

    test('a failing diagnostic callback cannot prevent the Relay fallback', () async {
      network.outcome = FakeRtcOutcome.fail;
      account.onDirectFallback = (_) => throw StateError('diagnostics unavailable');
      final client = await connect();
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(await client.listSessions(), isEmpty);
      expect(host.handshakes, hasLength(1));
    });

    test('a closed DataChannel reconnects over Relay instead of retrying the recently failed direct path', () async {
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      final first = server.links.values.single.id;
      host.closeRtc();
      await _eventually(() => host.handshakes.length == 2 && client.remoteCarrier!.state!.transport == 'relay');
      expect(await client.listSessions(), isEmpty);
      final second = server.links.values.single.id;
      expect(second, isNot(first));
      expect(host.handshakes, [first, second]);
      expect(host.rtcOffers, [first]);
      expect(network.clients, hasLength(1));
      expect(network.clients.first.closed, isTrue);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(
        client.remoteCarrier!.session!.networkDiagnostics!.fallbackReason,
        RemoteNetworkFallbackReason.directRecentlyFailed,
      );
      expect(server.controlRelayFrames, greaterThan(0));
    });

    test('after an established direct path fails, Relay attach gets a fresh Noise session', () async {
      server.relayAttach = true;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      final directConnection = host.handshakes.single;
      expect(server.relayAttaches, isEmpty, reason: 'a working direct path never attaches to Relay');
      network.outcome = FakeRtcOutcome.fail;
      host.closeRtc();
      await _eventually(() => client.remoteCarrier!.state!.transport == 'relay' && host.handshakes.length == 2);
      expect(await client.listSessions(), isEmpty);
      final relayConnection = host.handshakes.last;
      expect(relayConnection, isNot(directConnection));
      expect(host.rtcOffers, hasLength(1));
      expect(host.rtcOffers, isNot(contains(relayConnection)));
      expect(server.relayAttaches, hasLength(2));
      expect(server.relayFrames, greaterThan(0));
      expect(server.controlRelayFrames, 0);
      expect(fallbacks, ['directRecentlyFailed']);
    });

    test('TURN servers are dropped unless transport.turn was negotiated', () async {
      server
        ..webrtcTransports = {'transport.p2p'}
        ..iceServers = [
          {
            'urls': ['stun:stun.example:3478', 'turn:turn.example:3478'],
            'username': 'u',
            'credential': 'c',
          },
        ];
      network.stats = pairStats('srflx', '203.0.113.7', 'srflx', '198.51.100.9');
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(network.iceServers.single.single.urls, ['stun:stun.example:3478']);
      final request = clientFrames().firstWhere((f) => f['type'] == 'connect.request');
      expect((request['payload']! as Map)['preferredTransports'], ['p2p', 'relay']);
      expect(client.remoteCarrier!.state!.transport, 'p2p');
    });

    test('a selected remote relay cannot bypass direct ICE and TURN uses a fresh tunnel', () async {
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478', 'turn:turn.example:3478'],
        },
      ];
      network.stats = pairStats('host', '192.168.1.20', 'relay', '198.51.100.9');
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      final selected = clientFrames().singleWhere((f) => f['type'] == 'transport.selected')['payload']! as Map;
      expect(selected['transport'], 'turn');
      expect(client.remoteCarrier!.state!.transport, 'turn');
      expect(server.controlRelayFrames, 0);
      expect(fallbacks, ['directFailed']);
      expect(network.policies, [RemoteIceTransportPolicy.all, RemoteIceTransportPolicy.relay]);
      expect(host.handshakes, hasLength(1));
      expect(host.rtcOffers, hasLength(2));
      expect(host.rtcOffers.toSet(), hasLength(2));
      expect(host.handshakes, [host.rtcOffers.last]);
      expect(
        [
          for (final frame in clientFrames())
            if (frame['type'] == 'connect.request') (frame['payload']! as Map)['preferredTransports'],
        ],
        [
          ['lan', 'p2p', 'turn', 'relay'],
          ['turn', 'relay'],
        ],
      );
    });

    test('direct ICE gets its own window before TURN, and a failed live TURN goes straight to Relay', () async {
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478', 'turn:turn.example:3478'],
        },
      ];
      network.policyOutcomes[RemoteIceTransportPolicy.all] = FakeRtcOutcome.fail;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(network.policies, [RemoteIceTransportPolicy.all, RemoteIceTransportPolicy.relay]);
      expect(network.iceServers.first.single.urls, ['stun:stun.example:3478']);
      expect(network.iceServers.last.single.urls, contains('turn:turn.example:3478'));
      expect(client.remoteCarrier!.session!.networkDiagnostics!.transportMode, RemoteTransportMode.turn);
      expect(host.handshakes, [host.rtcOffers.last], reason: 'Noise starts only on the selected final connection');
      final offers = host.rtcOffers.length;
      host.closeRtc();
      await _eventually(() => client.remoteCarrier!.state!.transport == 'relay' && host.handshakes.length == 2);
      expect(await client.listSessions(), isEmpty);
      expect(host.rtcOffers, hasLength(offers), reason: 'neither failed path is renegotiated during cooldown');
      expect(
        client.remoteCarrier!.session!.networkDiagnostics!.fallbackReason,
        RemoteNetworkFallbackReason.directRecentlyFailed,
      );
    });

    test('retired direct callbacks cannot close or signal into the fresh TURN successor', () async {
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478', 'turn:turn.example:3478'],
        },
      ];
      network.policyOutcomes[RemoteIceTransportPolicy.all] = FakeRtcOutcome.fail;
      final client = await connect();
      final signals = types().where((t) => t.startsWith('signal.')).length;
      final retired = network.clients.first.handlers;

      retired.onOpen();
      retired.onIceCandidate({'candidate': 'candidate:late 1 udp 1234 192.168.1.20 5000 typ host'});
      retired.onMessage(Uint8List.fromList([0x52, 0x54, 0x43, 0x48]));
      retired.onClosed('late direct close');

      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'turn');
      expect(network.clients.first.closed, isTrue);
      expect(network.clients.last.closed, isFalse);
      expect(types().where((t) => t.startsWith('signal.')), hasLength(signals));
      expect(types().where((t) => t == 'connect.request'), hasLength(2));
      expect(host.rtcOffers.toSet(), hasLength(2));
      expect(host.handshakes, [host.rtcOffers.last]);
    });

    for (final firstFetchTimesOut in [false, true]) {
      test(
        'fresh TURN credentials succeed after direct credentials ${firstFetchTimesOut ? 'time out' : 'are empty'}',
        () async {
          await account.close();
          account = RemoteAccount(
            secrets: MemorySecretStore(),
            serverUrl: server.url,
            peerConnector: network.connector,
            onDirectFallback: fallbacks.add,
            directTimeout: const Duration(milliseconds: 300),
            iceServersTimeout: const Duration(milliseconds: 50),
          );
          final firstResponse = Completer<List<Map<String, Object?>>>();
          addTearDown(() {
            if (!firstResponse.isCompleted) firstResponse.complete([]);
          });
          server.iceServersForRequest = (_) async {
            if (server.turnRequests.length == 1) {
              return firstFetchTimesOut ? firstResponse.future : [];
            }
            return [
              {
                'urls': ['turn:turn.example:3478'],
                'username': 'fresh-user',
                'credential': 'fresh-credential',
              },
            ];
          };
          network.policyOutcomes[RemoteIceTransportPolicy.all] = FakeRtcOutcome.fail;
          final client = await connect();
          expect(await client.listSessions(), isEmpty);
          expect(server.turnRequests, hasLength(2));
          expect(server.turnRequests.toSet(), hasLength(2), reason: 'TURN credentials belong to its fresh tunnel');
          expect(host.rtcOffers, server.turnRequests);
          expect(network.policies, [RemoteIceTransportPolicy.all, RemoteIceTransportPolicy.relay]);
          expect(network.iceServers.first, isEmpty);
          final turnServer = network.iceServers.last.single;
          expect(turnServer.urls, ['turn:turn.example:3478']);
          expect(turnServer.username, 'fresh-user');
          expect(turnServer.credential, 'fresh-credential');
          expect(network.clients.first.closed, isTrue);
          expect(client.remoteCarrier!.state!.transport, 'turn');
          expect(host.handshakes, [server.turnRequests.last]);
          expect(server.controlRelayFrames, 0);
          expect(fallbacks, ['directFailed']);
          if (firstFetchTimesOut) {
            expect(firstResponse.isCompleted, isFalse, reason: 'fresh TURN does not await the timed-out request');
            firstResponse.complete([]);
            await Future<void>.delayed(const Duration(milliseconds: 20));
            expect(client.remoteCarrier!.state!.transport, 'turn');
          }
        },
      );
    }

    test('default credential timeout accepts a response taking six seconds', () async {
      server.iceServersForRequest = (_) async {
        await Future<void>.delayed(const Duration(seconds: 6));
        return [
          {
            'urls': ['stun:stun.example:3478'],
          },
        ];
      };
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(server.turnRequests, hasLength(1));
      expect(network.iceServers.single.single.urls, ['stun:stun.example:3478']);
      expect(client.remoteCarrier!.state!.transport, 'lan');
      expect(fallbacks, isEmpty);
    });

    test('when the fresh TURN attempt negotiates Relay only, it attaches once', () async {
      server.relayAttach = true;
      server.iceServersForRequest = (_) async {
        server.webrtcTransports = const {'p2p'};
        return [];
      };
      network.outcome = FakeRtcOutcome.fail;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(host.rtcOffers, hasLength(1));
      expect(types().where((t) => t == 'connect.request'), hasLength(2));
      expect(types().where((t) => t == 'transport.selected'), hasLength(1));
      expect(server.relayAttaches, hasLength(2));
      expect(host.handshakes, [server.links.keys.single]);
    });

    test('failed direct and TURN attempts reach Relay with exactly one Noise handshake', () async {
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478', 'turn:turn.example:3478'],
        },
      ];
      network.outcome = FakeRtcOutcome.fail;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(network.policies, [RemoteIceTransportPolicy.all, RemoteIceTransportPolicy.relay]);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(fallbacks, ['directFailed', 'turnFailed']);
      expect(client.remoteCarrier!.session!.networkDiagnostics!.fallbackReason, RemoteNetworkFallbackReason.turnFailed);
      expect(host.handshakes, hasLength(1));
      expect(host.rtcOffers, hasLength(2));
      expect(host.rtcOffers.toSet(), hasLength(2));
      expect(host.handshakes, [host.rtcOffers.last]);
      expect(types().where((t) => t == 'connect.request'), hasLength(2));
      expect(network.clients.every((p) => p.closed), isTrue);
    });

    test('direct negotiation filters remote SDP and trickled relay candidates and local relay trickle', () async {
      final relay = <String, Object?>{
        'candidate': 'candidate:3 1 udp 1234 198.51.100.9 50000 typ relay raddr 192.168.1.30 rport 40000',
        'sdpMid': '0',
      };
      host.rtcAnswerSdp = 'v=0 fake-answer\r\na=candidate:3 1 udp 1234 198.51.100.9 50000 typ relay\r\n';
      host.extraRtcCandidates.add(relay);
      network.extraLocalCandidates.add(relay);
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      final peer = network.clients.single;
      expect(peer.answer, isNot(contains('typ relay')));
      expect(peer.remoteCandidates.every((c) => !(c['candidate']! as String).contains('typ relay')), isTrue);
      final candidates = clientFrames().where((f) => f['type'] == 'signal.ice');
      expect(candidates, hasLength(1));
      expect(jsonEncode(candidates.toList()), isNot(contains('typ relay')));
      expect(network.policies, [RemoteIceTransportPolicy.all]);
    });

    test('on-demand diagnostics follow the actual current pair and RTT without sending a probe', () async {
      server.iceServers = [
        {
          'urls': ['stun:stun.example:3478', 'turn:turn.example:3478'],
        },
      ];
      network.stats[2]['currentRoundTripTime'] = 0.023;
      final client = await connect();
      final session = client.remoteCarrier!.session!;
      final initial = session.networkDiagnostics!;
      expect(initial.transportMode, RemoteTransportMode.lan);
      expect(initial.connectionDuration!.inMicroseconds, greaterThan(0));
      expect(initial.roundTripTime, const Duration(milliseconds: 23));
      expect(initial.peerNetwork?.localIpVersion, RemoteIpVersion.ipv4);
      expect(initial.peerNetwork?.remoteIpVersion, RemoteIpVersion.ipv4);
      final framesBefore = server.clientControlFrames.length;
      network.stats = pairStats('host', '2001:db8::1', 'relay', '2001:db8::2');
      network.stats[0]['protocol'] = 'udp';
      network.stats[1]['protocol'] = 'udp';
      network.stats[2]['currentRoundTripTime'] = 0.087;
      final observed = await session.inspectNetwork!();
      expect(observed.transportMode, RemoteTransportMode.turn);
      expect(observed.roundTripTime, const Duration(milliseconds: 87));
      expect(observed.peerNetwork?.localIpVersion, RemoteIpVersion.ipv6);
      expect(observed.peerNetwork?.remoteIpVersion, RemoteIpVersion.ipv6);
      expect(observed.peerNetwork?.protocol, RemoteIceProtocol.udp);
      expect(observed.connectionDuration, initial.connectionDuration);
      expect(observed.observedAt.isBefore(initial.observedAt), isFalse);
      expect(session.transport, 'lan', reason: 'wire selection is separate from the currently observed pair');
      expect(server.clientControlFrames, hasLength(framesBefore));
      network.stats = [];
      final unknown = await session.inspectNetwork!();
      expect(unknown.transportMode, isNull);
      expect(unknown.roundTripTime, isNull);
      expect(unknown.peerNetwork, isNull);
      expect(unknown.fallbackReason, RemoteNetworkFallbackReason.pathUnverified);
      network.stats = pairStats('host', '192.168.1.20', 'relay', '198.51.100.9');
      await session.inspectNetwork!();
      host.closeRtc();
      await _eventually(() => client.remoteCarrier!.state!.transport == 'relay' && host.handshakes.length == 2);
      expect(network.clients, hasLength(1), reason: 'the actually failed TURN pair must not be retried as initial LAN');
    });

    test('a known native network-route change clears the failed direct-path cooldown', () async {
      var nativeRoute = [
        RemoteTransportMode.lan,
        RemoteTransportMode.p2p,
        RemoteTransportMode.turn,
        RemoteTransportMode.relay,
      ];
      account.preferredTransports = () async => nativeRoute;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      nativeRoute = [RemoteTransportMode.p2p, RemoteTransportMode.turn, RemoteTransportMode.relay];
      host.closeRtc();
      await _eventually(() => host.handshakes.length == 2);
      expect(await client.listSessions(), isEmpty);
      expect(network.policies, [RemoteIceTransportPolicy.all, RemoteIceTransportPolicy.all]);
      expect(client.remoteCarrier!.state!.transport, 'p2p');
      expect(client.remoteCarrier!.session!.networkDiagnostics!.transportMode, RemoteTransportMode.lan);
      final lastRequest = clientFrames().lastWhere((f) => f['type'] == 'connect.request');
      expect((lastRequest['payload']! as Map)['preferredTransports'], ['p2p', 'turn', 'relay']);
    });

    for (final code in ['CONNECTION_REPLACED', 'PROTOCOL_MISMATCH']) {
      test('a pending capability probe preserves terminal $code without reconnecting', () async {
        host.stallDescribe = true;
        final rejected = expectLater(
          connect(),
          throwsA(
            isA<RemoteConnectException>()
                .having((error) => error.code, 'code', code)
                .having((error) => error.failure.retryable, 'retryable', isFalse),
          ),
        );
        await _eventually(() => host.rpcMethods.contains('harness.transport.describe'));
        final id = await clientId();
        // Keep the data plane alive so this exercises the Control failure,
        // not a race with a separate Host DataChannel close.
        server.peers[id]!.ws.add(
          code == 'CONNECTION_REPLACED'
              ? jsonEncode(ControlFrame('error', {'code': code, 'message': code, 'retryable': false}).toJson())
              : '{',
        );
        await rejected.timeout(const Duration(seconds: 5));
        expect(host.rpcMethods, ['harness.transport.describe']);
        expect(host.handshakes, hasLength(1));
        expect(network.clients, hasLength(1));
        expect(network.clients.single.closed, isTrue);
        expect(types().where((type) => type == 'connect.request'), hasLength(1));
        expect(fallbacks, isEmpty);
      });
    }

    test('authorization revocation during negotiation ends the attempt without transport fallback', () async {
      network.offerGate = Completer<void>().future;
      final rejected = expectLater(
        connect(),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'DEVICE_REVOKED')),
      );
      await _eventually(() => network.clients.isNotEmpty);
      server.disconnectPeer(await clientId(), 'DEVICE_REVOKED');
      await rejected;
      expect(network.clients, hasLength(1));
      expect(network.clients.single.closed, isTrue);
      expect(fallbacks, isEmpty);
      expect(types().where((t) => t == 'connect.request'), hasLength(1));
      expect(host.handshakes, isEmpty);
    });

    test('an unnegotiated selected path falls back before Noise begins', () async {
      server.webrtcTransports = {'transport.lan'};
      network.stats = pairStats('srflx', '203.0.113.7', 'srflx', '198.51.100.9');
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(fallbacks.single, 'directFailed');
      expect(host.handshakes, hasLength(1));
      expect(host.handshakes.single, isNot(host.rtcOffers.single));
      expect(types().where((type) => type == 'connect.request'), hasLength(2));
    });

    test('a LAN pair is announced as p2p when the Server does not know lan', () async {
      server.webrtcTransports = {'transport.p2p', 'transport.turn'};
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      final selected = clientFrames().singleWhere((f) => f['type'] == 'transport.selected')['payload']! as Map;
      expect(selected['transport'], 'p2p');
      expect(client.remoteCarrier!.state!.transport, 'p2p');
    });

    test('a Server with WebRTC off keeps the same connection on the Relay', () async {
      server.webrtc = false;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
      expect(network.clients, isEmpty);
      expect(server.turnRequests, isEmpty);
      expect(types().where((t) => t == 'connect.request'), hasLength(1));
      expect(types().where((t) => t.startsWith('signal.')), isEmpty);
      expect(fallbacks, isEmpty);
    });

    test('without a peer connector the client selects Relay without RTC signaling', () async {
      account.peerConnector = null;
      final client = await connect();
      expect(await client.listSessions(), isEmpty);
      expect(server.peers[await clientId()]!.capabilities, [
        'transport.relay.resume.v1',
        'transport.relay',
        'transport.relay.attach',
      ]);
      final request = clientFrames().firstWhere((f) => f['type'] == 'connect.request');
      expect((request['payload']! as Map)['preferredTransports'], ['relay']);
      expect(types().take(3), ['connect.request', 'transport.selected', 'secure.handshake']);
      expect(types().skip(3).toSet(), {'relay'});
      expect(network.clients, isEmpty);
      expect(server.turnRequests, isEmpty);
      expect(host.rtcOffers, isEmpty);
      expect(client.remoteCarrier!.state!.transport, 'relay');
    });

    test('traces redact SDP and candidates', () async {
      final traced = <String>[];
      await account.close();
      account = RemoteAccount(
        secrets: MemorySecretStore(),
        serverUrl: server.url,
        peerConnector: network.connector,
        controlTracer: (direction, frame) => traced.add('$direction ${jsonEncode(frame)}'),
      );
      final client = await connect();
      await client.listSessions();
      final trace = traced.join('\n');
      expect(trace, contains('signal.offer'));
      expect(trace, contains('signal.ice'));
      expect(trace, isNot(contains('fake-offer')));
      expect(trace, isNot(contains('192.168.1.')));
    });
  });
}

// Injects a typed Control write failure without changing the RTC test stack.
class _SignalControl implements RelayTransport {
  final List<String> signals = [];
  RemoteTransportException? signalError;
  bool closed = false;

  @override
  void Function(ControlFrame frame)? onSignal;

  @override
  RemoteConnectionInfo get info =>
      const RemoteConnectionInfo(connectionId: 'trickle-connection', localDeviceId: 'phone', remoteDeviceId: 'host');

  @override
  List<String> get directTransports => const ['p2p'];

  @override
  Duration? get webrtcFallbackTimeout => null;

  @override
  void listen({
    required TransportDataHandler onData,
    required TransportHandshakeHandler onHandshake,
    required TransportClosedHandler onClosed,
  }) {}

  @override
  void sendSignal(String type, Map<String, Object?> payload) {
    final error = signalError;
    if (type == 'signal.ice' && error != null) throw error;
    signals.add(type);
  }

  @override
  void checkControlHealth() {}

  @override
  void confirmWebRtcDataPlane(bool Function() isAlive) {}

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClosingPeer implements RemotePeerConnection {
  _ClosingPeer(this.delegate, {this.throwOnClose = false});

  final RemotePeerConnection delegate;
  final bool throwOnClose;
  int closes = 0;
  bool offering = false;
  bool inspecting = false;

  @override
  Future<String> createOffer(String channelLabel) {
    offering = true;
    return delegate.createOffer(channelLabel);
  }

  @override
  Future<void> setAnswer(String sdp) => delegate.setAnswer(sdp);

  @override
  Future<void> addIceCandidate(Map<String, Object?> candidate) => delegate.addIceCandidate(candidate);

  @override
  Future<void> send(Uint8List data) => delegate.send(data);

  @override
  Future<List<Map<String, Object?>>> stats() {
    inspecting = true;
    return delegate.stats();
  }

  @override
  Future<void> close() {
    closes++;
    if (throwOnClose) throw StateError('native close failed synchronously');
    return delegate.close();
  }
}

Future<void> _eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
