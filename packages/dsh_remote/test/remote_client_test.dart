import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late MemorySecretStore secrets;
  late RemoteAccount account;

  RemoteAccount newAccount([MemorySecretStore? store]) => RemoteAccount(
    secrets: store ?? secrets,
    serverUrl: server.url,
    loginPollInterval: const Duration(milliseconds: 20),
  );

  setUp(() async {
    server = await FakeRemoteServer.start();
    host = await FakeRemoteHost.start(server);
    host.handlers['session/list'] = (args) {
      expect(args, {'_request': <String, Object?>{}});
      return {
        'ok': true,
        'value': {
          'items': [
            {'sessionId': 'session-1', 'title': 'Remote hello', 'createdAt': 1786000000000, 'updatedAt': 1786000000000},
          ],
        },
      };
    };
    host.handlers['session/create'] = (args) => {
      'ok': true,
      'value': {'sessionId': 'session-new', 'agentPreset': 'standard'},
    };
    secrets = MemorySecretStore();
    account = newAccount();
  });

  tearDown(() async {
    expect(server.protocolErrors, isEmpty, reason: 'the client never violated the Control protocol');
    await account.close();
    await host.close();
    await server.close();
  });

  Future<RemoteHost> signInAndFindHost() async {
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    return (await account.listHosts()).single;
  }

  group('account', () {
    test('separate presence works when both device responses omit online', () async {
      server.separatePresence = true;
      final target = await signInAndFindHost();
      expect(target.online, isTrue);
      expect(server.presenceRequests, 1);
      final client = await account.connectHost(target, muxOptions: fastMux);
      expect(await client.listSessions(), hasLength(1));
      expect(server.presenceRequests, 2);
      await host.goOffline();
      expect((await account.listHosts()).single.online, isFalse);
    });

    test('inline presence keeps the legacy path without another endpoint', () async {
      final target = await signInAndFindHost();
      expect(target.online, isTrue);
      await account.connectHost(target, muxOptions: fastMux);
      expect(server.presenceRequests, 0);
    });

    test('presence outage reports its cause instead of a false offline listing', () async {
      server.separatePresence = true;
      server.presenceError = 'CONNECTION_FAILED';
      await expectLater(
        signInAndFindHost(),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'CONNECTION_FAILED')),
      );
    });

    test('password sign-in registers a client device and stores only device secrets', () async {
      expect(await account.currentUser(), isNull);
      final user = await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
      expect(user.account, FakeRemoteServer.account);
      final device = server.devices[user.deviceId]!.descriptor;
      expect(device['role'], 'client');
      expect(device['platform'], 'dsh-app-android');
      expect(device['identityKey'], hasLength(43));
      expect(device.containsKey('harnessVersion'), isFalse);
      expect(secrets.values.keys, everyElement(startsWith('dsh_remote.v1.')));
      final stored = secrets.values.values.join();
      expect(stored, isNot(contains(FakeRemoteServer.password)));

      // A fresh account object restores the session from the store.
      final restored = newAccount();
      addTearDown(restored.close);
      expect((await restored.currentUser())!.deviceId, user.deviceId);
    });

    test('QR sign-in exposes a same-origin login URL and completes by polling', () async {
      final login = await account.startLogin();
      expect(login.providerId, 'github');
      expect(login.loginUrl.origin, server.url.origin);
      final qrId = login.loginUrl.pathSegments.last;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      server.approveQr(qrId);
      final user = await login.result.timeout(const Duration(seconds: 5));
      expect(user.account, FakeRemoteServer.account);
      expect(await account.currentUser(), isNotNull);
    });

    test('a cancelled QR sign-in fails with LOGIN_CANCELLED', () async {
      final login = await account.startLogin();
      login.cancel();
      await expectLater(
        login.result,
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'LOGIN_CANCELLED')),
      );
    });

    test('expired access tokens are refreshed once, single-flight, and rotated', () async {
      await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
      server.expireAccessTokens();
      final first = await account.accessToken(forceRefresh: true);
      expect(server.refreshCount, 1);
      final results = await Future.wait([
        account.accessToken(forceRefresh: true),
        account.accessToken(forceRefresh: true),
      ]);
      expect(results[0], results[1]);
      expect(results[0], isNot(first));
      expect(server.refreshCount, 2);
    });

    test('logout revokes the device and forgets its identity', () async {
      final user = await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
      await account.logout();
      expect(server.devices[user.deviceId]!.revoked, isTrue);
      expect(await account.currentUser(), isNull);
      expect(secrets.values, isEmpty);
      // Signing in again registers a new identity.
      final again = await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
      expect(again.deviceId, isNot(user.deviceId));
    });

    test('listing Hosts reports versions, fingerprint and pin status', () async {
      final listed = await signInAndFindHost();
      expect(listed.id, host.deviceId);
      expect(listed.online, isTrue);
      expect(listed.harnessVersion, '0.2.1-rc.2');
      expect(listed.pluginVersion, '0.5.17');
      expect(listed.identityKey, host.keys.publicKeyBase64Url);
      expect(listed.fingerprint, formatFingerprint(identityFingerprint(host.keys.publicKeyBase64Url)));
      expect(listed.trust, RemoteHostTrust.unpinned);
    });
  });

  group('connectHost + DshClient over the tunnel', () {
    for (final version in ['0.2.2-alpha.2', '0.2.1-rc.4', null]) {
      test('activation uses fresh descriptor $version, never stale host listing', () async {
        server.devices[host.deviceId]!.descriptor['harnessVersion'] = '0.2.2-alpha.2';
        final target = await signInAndFindHost();
        expect(target.harnessVersion, '0.2.2-alpha.2');
        if (version == null) {
          server.devices[host.deviceId]!.descriptor.remove('harnessVersion');
        } else {
          server.devices[host.deviceId]!.descriptor['harnessVersion'] = version;
        }
        final client = await account.connectHost(target, muxOptions: fastMux);
        expect(client.carrier.hostVersion, version);
        final opened = Completer<Map<Object?, Object?>>();
        host.onOpen = (stream) {
          if (stream.endpoint == 'session/follow') {
            final request = stream.args['request'] as Map<Object?, Object?>;
            if (version != '0.2.2-alpha.2' || request['activate'] == true) opened.complete(request);
            stream.push(followSnapshot('session-1'));
          }
        };
        final sub = client.watch('session-1', options: const WatchOptions(activate: true)).listen((_) {});
        final request = await opened.future.timeout(const Duration(seconds: 5));
        expect(request['activate'], version == '0.2.2-alpha.2' ? true : null);
        await sub.cancel();
        await client.close();
        expect(client.carrier.hostVersion, isNull);
      });
    }

    test('describe first, then the same DshClient API (list, create, watch)', () async {
      final target = await signInAndFindHost();
      final states = <RemoteConnectionState>[];
      final client = await account.connectHost(target, onState: states.add, muxOptions: fastMux);
      expect(host.rpcMethods.first, 'harness.transport.describe');
      expect(host.rpcMethods[1], 'harness.remote.stream.open'); // $events
      expect(client.mux.generation!.clientId, 'remote-client-1');
      expect(client.isRemote, isTrue);
      expect(client.remoteCarrier!.capabilities, contains('harness.remote.v3'));
      expect(states.last.phase, RemoteConnectionPhase.connected);
      expect(states.last.transport, 'relay');
      expect(() => client.connection, throwsStateError);

      final sessions = await client.listSessions();
      expect(sessions.single.sessionId, 'session-1');
      final created = await client.createSession(cwd: '/home/host/ws');
      expect(created.sessionId, 'session-new');
      expect(host.calls.last.$2, {
        'request': {'cwd': '/home/host/ws'},
      });
      expect((await account.listHosts()).single.trust, RemoteHostTrust.pinned);

      host.onOpen = (stream) {
        expect(stream.endpoint, 'session/follow');
        expect((stream.args['request']! as Map)['address'], {'kind': 'session', 'sessionId': 'session-1'});
        stream.push(
          followSnapshot(
            'session-1',
            cursor: 0,
            records: [
              logRecord(0, 'turn/start', {'turn': 1}),
            ],
          ),
        );
        stream.push(
          logRecord(1, 'turn/end', {
            'turn': 1,
            'reason': {'kind': 'completed'},
          }),
        );
      };
      final events = <DshEvent>[];
      final sub = client.watch('session-1').listen(events.add);
      await _eventually(() => events.whereType<SessionLogEvent>().isNotEmpty);
      expect(events.first, isA<SessionSnapshotEvent>());
      expect(events.whereType<SessionLogEvent>().single.seq, 1);
      await sub.cancel();
      await _eventually(() => host.rpcMethods.last == 'harness.remote.stream.close');
    });

    test(r'approvals arrive on $events and are answered with the tunnel clientId', () async {
      final target = await signInAndFindHost();
      Map<String, Object?>? answered;
      host.handlers[r'$events/result'] = (args) {
        answered = args;
        return {'ok': true};
      };
      host.pendingWaterfalls.add({
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'evt-1',
        'agentId': 'session-1',
        'request': {'toolName': 'bash', 'callId': 'call-1', 'reason': 'escalate'},
      });
      host.onOpen = (stream) => stream.push(followSnapshot('session-1'));
      final client = await account.connectHost(target, muxOptions: fastMux);
      final approvals = <ApprovalRequestedEvent>[];
      final sub = client.watch('session-1').listen((e) {
        if (e is ApprovalRequestedEvent) approvals.add(e);
      });
      await _eventually(() => approvals.isNotEmpty);
      await client.respondApproval(approvals.single.request, ApprovalDecision.allowOnce);
      expect(answered, {
        'clientId': 'remote-client-1',
        'eventId': 'evt-1',
        'outcome': {'kind': 'result', 'value': 'allowed-once'},
      });
      await sub.cancel();
    });

    test('allow-list, missing uplink and stream failures', () async {
      final target = await signInAndFindHost();
      final client = await account.connectHost(target, muxOptions: fastMux);
      final before = host.calls.length;
      expect(client.supportsEndpoint('fileUploads/upload'), isFalse);
      await expectLater(
        client.uploadFile('session-1', [1, 2, 3]),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
      );
      expect(host.calls.length, before, reason: 'refused locally, never sent');

      final refused = client.mux.open('dynamicCordisRunner/run', const {});
      await expectLater(
        refused.items.drain<void>(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
      );

      host.onOpen = (stream) {};
      final wait = client.claimQuestionWait('session-1', 'call-1');
      expect(wait.supportsUplink, isFalse);
      expect(() => wait.send({'x': 1}), throwsUnsupportedError);
      await wait.cancel();

      host.onOpen = (stream) => stream.fail('session/not-found', 'No such session');
      await expectLater(
        client.watch('missing').drain<void>(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session/not-found')),
      );
      host.handlers['session/selectModel'] = (_) => {
        'ok': false,
        'error': {
          'code': 'session/model-unavailable',
          'message': 'nope',
          'details': {'model': 'm'},
        },
      };
      await expectLater(
        client.setModel('s', provider: 'p', model: 'm'),
        throwsA(isA<DshRemoteException>().having((e) => e.details['model'], 'details', 'm')),
      );
    });

    test('DS Bot discovers the tunnel transport and receives live feed events', () async {
      final target = await signInAndFindHost();
      host.handlers['dsBot/call'] = (args) {
        expect(args, {
          'endpoint': 'hello',
          'payload': {
            'client': {'name': 'dsh-go', 'platform': 'android'},
            'api': [1],
          },
        });
        return {
          'ok': true,
          'value': {
            'ok': true,
            'value': {
              'api': 1,
              'boot': 'bot-boot',
              'capabilities': ['rpc'],
            },
          },
        };
      };
      host.onOpen = (stream) {
        expect(stream.endpoint, 'dsBot/feed');
        stream.push({
          'event': 'hello',
          'data': {'revision': 42, 'api': 1, 'boot': 'bot-boot', 'seq': 7},
        });
        stream.push({
          'event': 'revision',
          'data': {'revision': 43},
        });
      };
      final client = await account.connectHost(target, muxOptions: fastMux);
      final bot = DsBotApi.of(client)!;
      expect(bot.transport, isA<DsBotRpcTransport>());
      expect((await bot.hello()).boot, 'bot-boot');

      final feed = bot.feed();
      addTearDown(feed.close);
      final events = feed.events.take(2).toList().timeout(const Duration(seconds: 5));
      feed.start();
      expect(await events, [
        isA<DsBotFeedHello>().having((e) => e.seq, 'sequence', 7),
        isA<DsBotFeedRevision>().having((e) => e.revision, 'revision', 43),
      ]);
    });

    test('DS Bot state transfers a large result without dispatching twice', () async {
      final target = await signInAndFindHost();
      host.directResponseLimit = maxSecureMessageBytes;
      final largeField = 'x' * maxSecureMessageBytes;
      host.handlers['dsBot/call'] = (args) {
        expect(args['endpoint'], 'state');
        return {
          'ok': true,
          'value': {
            'ok': true,
            'value': {'revision': 3, 'largeField': largeField},
          },
        };
      };
      final client = await account.connectHost(target, muxOptions: fastMux);
      final bot = DsBotApi.of(client)!;
      expect(await bot.call('state'), allOf(containsPair('revision', 3), containsPair('largeField', largeField)));
      expect(host.calls.where((call) => call.$1 == 'dsBot/call'), hasLength(1));
      expect(host.rpcMethods, isNot(contains('harness.remote.call')));
      expect(host.rpcMethods.where((method) => method == 'harness.remote.transfer.read').length, greaterThan(1));
    });

    for (final (operation, payload) in <(String, Map<String, Object?>)>[
      ('delete-bot', {'id': 'bot-1'}),
      ('memory-view', {'botId': 'bot-1', 'regenerate': true}),
      ('future-operation', <String, Object?>{}),
    ]) {
      test('DS Bot does not replay $operation after an oversized result', () async {
        final target = await signInAndFindHost();
        host.directResponseLimit = 1024;
        host.handlers['dsBot/call'] = (args) {
          expect(args['endpoint'], operation);
          return {
            'ok': true,
            'value': {'ok': true, 'value': 'x' * 4096},
          };
        };
        final client = await account.connectHost(target, muxOptions: fastMux);
        final bot = DsBotApi.of(client)!;
        await expectLater(
          bot.call(operation, payload),
          throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'RESPONSE_TOO_LARGE')),
        );
        expect(host.calls.where((call) => call.$1 == 'dsBot/call'), hasLength(1));
        expect(host.rpcMethods, isNot(contains('harness.remote.transfer.open')));
      });
    }

    test('large prompts and responses use chunked transfers', () async {
      final target = await signInAndFindHost();
      String? receivedImage;
      host.handlers['session/prompt'] = (args) {
        final content = ((args['request']! as Map)['content']! as List).cast<Map<Object?, Object?>>();
        receivedImage = content.last['data'] as String?;
        return {
          'ok': true,
          'value': {'accepted': true},
        };
      };
      final client = await account.connectHost(target, muxOptions: fastMux);
      final image = List<int>.generate(3 * 1024 * 1024, (i) => i & 0xff);
      await client.prompt('session-1', 'look', images: [PromptImage.fromBytes(image, mediaType: 'image/png')]);
      expect(receivedImage, base64Encode(image));
      expect(host.rpcMethods, contains('harness.remote.transfer.commit'));

      // A response the Host refuses to send directly is fetched in chunks.
      host.directResponseLimit = 1024;
      final big = 'x' * (3 * 1024 * 1024);
      host.handlers['session/search'] = (_) => {
        'ok': true,
        'value': {
          'items': [
            {'sessionId': 's', 'snippet': big},
          ],
          'hasMore': false,
        },
      };
      final found = await client.searchSessions('x');
      expect(found.single.snippet.length, big.length);
      expect(host.rpcMethods, contains('harness.remote.transfer.read'));
    });

    test('an oversized command result does not execute the command again', () async {
      final target = await signInAndFindHost();
      host.directResponseLimit = 4 * 1024 * 1024;
      var executions = 0;
      host.handlers['commands/execute'] = (args) {
        expect(args['line'], '/report');
        executions++;
        return {
          'ok': true,
          'value': {
            'commandId': 'cmd-$executions',
            'result': {'kind': 'success', 'text': 'x' * (5 * 1024 * 1024)},
          },
        };
      };
      final client = await account.connectHost(target, muxOptions: fastMux);
      // The Host has executed the command before its direct-response size check.
      // The original error must remain visible, with no second submission.
      Object? outcome;
      try {
        outcome = await client.executeCommand('session-1', '/report');
      } catch (error) {
        outcome = error;
      }
      expect(executions, 1);
      expect(outcome, isA<DshRemoteException>().having((e) => e.code, 'code', 'RESPONSE_TOO_LARGE'));
      expect(host.rpcMethods.where((m) => m.startsWith('harness.remote.transfer.')), isEmpty);
    });

    test('a normal command result still uses one direct call', () async {
      final target = await signInAndFindHost();
      host.directResponseLimit = 4 * 1024 * 1024;
      var executions = 0;
      host.handlers['commands/execute'] = (_) {
        executions++;
        return {
          'ok': true,
          'value': {
            'commandId': 'cmd-$executions',
            'result': {'kind': 'success', 'text': 'done'},
          },
        };
      };
      final client = await account.connectHost(target, muxOptions: fastMux);
      final result = await client.executeCommand('session-1', '/report');
      expect(result.success, isTrue);
      expect(result.text, 'done');
      expect(executions, 1);
      expect(host.rpcMethods.where((m) => m.startsWith('harness.remote.transfer.')), isEmpty);
    });

    test('an initially large command request transfers and executes once', () async {
      final target = await signInAndFindHost();
      var executions = 0;
      final line = '/report ${'x' * (3 * 1024 * 1024)}';
      host.handlers['commands/execute'] = (args) {
        expect(args['line'], line);
        executions++;
        return {
          'ok': true,
          'value': {
            'commandId': 'cmd-$executions',
            'result': {'kind': 'success', 'text': 'done'},
          },
        };
      };
      final client = await account.connectHost(target, muxOptions: fastMux);
      final result = await client.executeCommand('session-1', line);
      expect(result.success, isTrue);
      expect(executions, 1);
      expect(host.rpcMethods.where((m) => m == 'harness.remote.transfer.commit'), hasLength(1));
      expect(host.rpcMethods.where((m) => m == 'harness.remote.call'), isEmpty);
    });

    test('a dropped connection reconnects with a new generation and resyncs watch()', () async {
      final target = await signInAndFindHost();
      final states = <RemoteConnectionPhase>[];
      var opens = 0;
      host.onOpen = (stream) {
        opens++;
        stream.push(
          followSnapshot(
            'session-1',
            cursor: 0,
            records: [
              logRecord(0, 'turn/start', {'turn': 1}),
            ],
          ),
        );
      };
      final client = await account.connectHost(target, onState: (s) => states.add(s.phase), muxOptions: fastMux);
      final snapshots = <SessionSnapshotEvent>[];
      final sub = client.watch('session-1').listen((e) {
        if (e is SessionSnapshotEvent) snapshots.add(e);
      });
      await _eventually(() => snapshots.length == 1);
      host.dropClients();
      await _eventually(() => snapshots.length == 2);
      expect(snapshots.last.isResync, isTrue);
      expect(opens, 2);
      expect(client.mux.generation!.clientId, 'remote-client-2');
      expect(
        states,
        containsAllInOrder([
          RemoteConnectionPhase.connected,
          RemoteConnectionPhase.reconnecting,
          RemoteConnectionPhase.connected,
        ]),
      );
      expect(account.connectionState!.phase, RemoteConnectionPhase.connected);
      await sub.cancel();
    });

    test('a changed Host key fails closed until the pin is forgotten', () async {
      final target = await signInAndFindHost();
      final client = await account.connectHost(target, muxOptions: fastMux);
      await client.close();

      // A compromised Server swaps the descriptor key.
      final rogue = X25519KeyPair.generate();
      server.devices[host.deviceId]!.descriptor['identityKey'] = rogue.publicKeyBase64Url;
      expect((await account.listHosts()).single.trust, RemoteHostTrust.keyChanged);
      await expectLater(
        account.connectHost(target, muxOptions: fastMux),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'PEER_IDENTITY_MISMATCH')),
      );
      expect(server.controlConnects, 2, reason: 'refused before opening a Control socket');

      // The user re-trusts after a legitimate Host reinstall.
      server.devices[host.deviceId]!.descriptor['identityKey'] = host.keys.publicKeyBase64Url;
      await account.forgetHost(host.deviceId);
      final again = await account.connectHost(target, muxOptions: fastMux);
      expect(await again.listSessions(), hasLength(1));
    });

    test('first-use confirmation can refuse a new Host', () async {
      final target = await signInAndFindHost();
      RemoteHost? asked;
      await expectLater(
        account.connectHost(
          target,
          muxOptions: fastMux,
          confirmNewHost: (h) async {
            asked = h;
            return false;
          },
        ),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'HOST_NOT_TRUSTED')),
      );
      expect(asked!.fingerprint, target.fingerprint);
      expect((await account.listHosts()).single.trust, RemoteHostTrust.unpinned);
    });

    test('an explicitly offline descriptor fails before WSS or trust confirmation', () async {
      final target = await signInAndFindHost();
      await host.goOffline();
      final connects = server.controlConnects;
      var asked = false;
      await expectLater(
        account.connectHost(
          target,
          muxOptions: fastMux,
          confirmNewHost: (_) async {
            asked = true;
            return true;
          },
        ),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'HOST_OFFLINE')),
      );
      expect(server.controlConnects, connects);
      expect(asked, isFalse);
    });

    test('probe detects a stalled tunnel, shares its RPC, and reconnects', () async {
      final target = await signInAndFindHost();
      final client = await account.connectHost(target, muxOptions: fastMux);
      final before = host.rpcMethods.where((m) => m == 'harness.transport.describe').length;
      host.stallDescribe = true;
      final states = <DshConnectionState>[];
      final sub = client.mux.states.listen(states.add);
      addTearDown(sub.cancel);
      final recovered = client.mux.generations.firstWhere((g) => g.number > 1);
      final first = client.remoteCarrier!.probe(timeout: const Duration(milliseconds: 200));
      final second = client.remoteCarrier!.probe(timeout: const Duration(milliseconds: 200));
      expect(identical(first, second), isTrue);
      expect(await first, isFalse);
      host.stallDescribe = false;
      await recovered.timeout(const Duration(seconds: 5));
      expect(states, containsAllInOrder([DshConnectionState.reconnecting, DshConnectionState.connected]));
      expect(host.rpcMethods.where((m) => m == 'harness.transport.describe').length, before + 2);
    });

    test('the periodic probe waits while the Host keeps sending, and runs once it goes quiet', () async {
      final target = await signInAndFindHost();
      await account.connectHost(target, muxOptions: fastMux, healthInterval: const Duration(milliseconds: 150));
      int describes() => host.rpcMethods.where((m) => m == 'harness.transport.describe').length;
      final before = describes();
      final busy = Timer.periodic(const Duration(milliseconds: 40), (_) {
        for (final c in host.connections.values) {
          c.event('session/updated', const {'sessionId': 's1'});
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      busy.cancel();
      expect(describes(), before);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(describes(), greaterThan(before));
    });

    test('a Host METHOD_NOT_FOUND response still proves probe liveness', () async {
      final target = await signInAndFindHost();
      final client = await account.connectHost(target, muxOptions: fastMux);
      final generation = client.mux.generation!.number;
      host.describeUnsupported = true;
      expect(await client.remoteCarrier!.probe(timeout: const Duration(milliseconds: 200)), isTrue);
      expect(client.mux.generation!.number, generation);
      expect(client.mux.state, DshConnectionState.connected);
    });

    test('an offline Host fails fast; a stale access token is refreshed once', () async {
      final target = await signInAndFindHost();
      await host.goOffline();
      await expectLater(
        account.connectHost(target, muxOptions: fastMux),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'HOST_OFFLINE')),
      );
      await host.goOnline();
      // The client still believes its token is valid.
      server.expireAccessTokens(deviceId: (await account.currentUser())!.deviceId);
      final client = await account.connectHost(target, muxOptions: fastMux);
      expect(server.refreshCount, greaterThanOrEqualTo(1));
      expect(await client.listSessions(), hasLength(1));
    });

    for (final malformed in <String, List<String>>{
      'empty capability': ['harness.remote.v3', ''],
      'duplicate capability': ['harness.remote.v3', 'harness.remote.v3'],
    }.entries) {
      test('transport description rejects ${malformed.key}', () async {
        final target = await signInAndFindHost();
        host.capabilities = malformed.value;
        await expectLater(
          account.connectHost(target, muxOptions: fastMux),
          throwsA(
            isA<RemoteConnectException>()
                .having((e) => e.code, 'code', 'INVALID_MESSAGE')
                .having((e) => e.failure.retryable, 'retryable', isFalse),
          ),
        );
        expect(host.rpcMethods, ['harness.transport.describe']);
      });
    }

    test('transport description accepts empty list syntax but requires V3', () async {
      final target = await signInAndFindHost();
      host.capabilities = [];
      await expectLater(
        account.connectHost(target, muxOptions: fastMux),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'HARNESS_VERSION_INCOMPATIBLE')),
      );
    });

    test('transport description retains unknown nonempty capabilities', () async {
      final target = await signInAndFindHost();
      host.capabilities = ['harness.remote.v3', 'future.extension.v1'];
      final client = await account.connectHost(target, muxOptions: fastMux);
      expect(client.remoteCarrier!.capabilities, contains('future.extension.v1'));
      expect(await client.listSessions(), hasLength(1));
    });

    test('Hosts without the Typert Remote carrier are refused', () async {
      final target = await signInAndFindHost();
      host.describeUnsupported = true;
      await expectLater(
        account.connectHost(target, muxOptions: fastMux),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'HARNESS_VERSION_INCOMPATIBLE')),
      );
      host.describeUnsupported = false;
      host.capabilities = ['transport.relay', 'harness.api.v1'];
      await expectLater(
        account.connectHost(target, muxOptions: fastMux),
        throwsA(isA<RemoteConnectException>().having((e) => e.code, 'code', 'HARNESS_VERSION_INCOMPATIBLE')),
      );
    });

    test('being replaced by another client of the same device stops the reconnect loop', () async {
      final target = await signInAndFindHost();
      final client = await account.connectHost(target, muxOptions: fastMux);
      final failed = Completer<RemoteConnectionState>();
      client.remoteStates!.listen((s) {
        if (s.phase == RemoteConnectionPhase.failed && !failed.isCompleted) failed.complete(s);
      });
      // Same identity in a second process (e.g. a restored backup).
      final twin = newAccount(MemorySecretStore({...secrets.values}));
      addTearDown(twin.close);
      final other = await twin.connectHost((await twin.listHosts()).single, muxOptions: fastMux);
      final state = await failed.future.timeout(const Duration(seconds: 5));
      expect(state.failure!.code, 'CONNECTION_REPLACED');
      expect(client.mux.state, DshConnectionState.unauthorized);
      expect(await other.listSessions(), hasLength(1), reason: 'the winner keeps working');
    });

    test('connecting another Host closes the previous client', () async {
      final target = await signInAndFindHost();
      final second = await FakeRemoteHost.start(server, name: 'Second');
      addTearDown(second.close);
      second.handlers.addAll(host.handlers);
      final first = await account.connectHost(target, muxOptions: fastMux);
      final hosts = await account.listHosts();
      final client = await account.connectHost(hosts.firstWhere((h) => h.id == second.deviceId), muxOptions: fastMux);
      expect(first.mux.state, DshConnectionState.closed);
      expect(account.activeClient, same(client));
      expect(await client.listSessions(), hasLength(1));
      await client.close();
      await _eventually(() => account.activeClient == null);
    });
  });
}

Future<void> _eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
