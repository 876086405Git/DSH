import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _RelayOnly extends DshCarrier {
  @override
  String get kind => 'relay-fixture';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw StateError('Lifecycle must not substitute relay RPC');
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw StateError('unexpected link');
  @override
  Future<void> close() async {}
}

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/lifecycle-real-unknown.json').readAsStringSync()) as Map<String, dynamic>;
  final session = fixture['sessionId'] as String;
  Map<String, dynamic> copy(String key) => jsonDecode(jsonEncode(fixture[key])) as Map<String, dynamic>;
  late HttpServer server;
  late DshClient client;
  late Future<void> Function(HttpRequest) handler;
  final requests = <String>[];
  Future<void> reply(HttpRequest req, int status, Object body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (req) => reply(req, 404, {});
    server.listen((req) async {
      requests.add('${req.method} ${req.uri.path}');
      expect(req.headers.value(HttpHeaders.cookieHeader), 'dsh-fixture=fixture');
      expect(req.headers.value('origin'), isNull);
      await handler(req);
    });
    client = DshClient(
      DshConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        cookie: DshCookie(name: 'dsh-fixture', value: 'fixture', authority: '127.0.0.1:${server.port}'),
      ),
    );
  });
  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  test('real interrupted bash remains unknown even without a reconciliation object', () async {
    handler = (req) async {
      expect(req.uri.queryParameters, {'sessionId': session});
      await reply(req, 200, copy('unknown'));
    };
    final state = await client.getLifecycleStatus(session);
    expect(state.state, LifecycleState.resultUnknown);
    expect(state.blocked, isFalse);
    expect(state.calls, hasLength(5));
    final call = state.unresolvedCalls.single;
    expect(call.identity.callSeq, 37);
    expect(call.identity.name, 'bash');
    expect(call.phase, 'dispatch');
    expect(call.reconciliationBlocking, isNull);
    expect(call.hasFinalOutcome, isFalse);
    // Repeated reads never POST, resume, prompt, or acknowledge.
    await client.getLifecycleStatus(session);
    expect(requests, ['GET $lifecyclePath', 'GET $lifecyclePath']);
  });

  test('actual result-absent is distinct from unavailable route and authentication failure', () async {
    handler = (req) async {
      expect(req.uri.queryParameters, {'sessionId': session, 'callSeq': '37'});
      await reply(req, 404, fixture['resultAbsent']['body'] as Object);
    };
    expect(await client.getLifecycleResult(session, 37), isNull);
    handler = (req) => reply(req, 404, {});
    await expectLater(
      client.getLifecycleResult(session, 37),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'unavailable')),
    );
    for (final status in [401, 403]) {
      handler = (req) => reply(req, status, {'error': 'Unauthorized'});
      await expectLater(
        client.getLifecycleStatus(session),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', status)),
      );
    }
    expect(requests.every((r) => r.startsWith('GET ')), isTrue);
  });

  test('explicit session acknowledgement keeps original unknown history and does not replay', () async {
    await expectLater(client.acknowledgeLifecycleUnknown(session, userConfirmed: false), throwsArgumentError);
    expect(requests, isEmpty);
    handler = (req) async {
      expect(req.method, 'POST');
      expect(req.uri.query, isEmpty);
      expect(req.headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(await utf8.decoder.bind(req).join()), {
        'operation': 'acknowledgeUnknown',
        'sessionId': session,
      });
      await reply(req, 200, copy('acknowledged'));
    };
    final state = await client.acknowledgeLifecycleUnknown(session, userConfirmed: true);
    expect(state.state, LifecycleState.completed);
    expect(state.unresolvedCalls, isEmpty);
    final call = state.calls.last;
    expect(call.phase, 'dispatch');
    expect(call.hasFinalOutcome, isFalse);
    expect(call.reconciliationBasis, 'explicit-abandon-unknown-without-replay');
    expect(requests, ['POST $lifecyclePath']);
  });

  test('still-running refusal preserves stable code, no server detail, no retry', () async {
    handler = (req) => reply(req, 409, {
      'error': {'code': 'ERR_OHOS_LIFECYCLE_STILL_RUNNING', 'message': 'private detail'},
    });
    await expectLater(
      client.acknowledgeLifecycleUnknown(session, userConfirmed: true),
      throwsA(
        isA<DshRemoteException>()
            .having((e) => e.code, 'code', 'ERR_OHOS_LIFECYCLE_STILL_RUNNING')
            .having((e) => e.message, 'message', isNot(contains('private'))),
      ),
    );
    expect(requests, ['POST $lifecyclePath']);
  });

  test('final and raw results remain evidence; response identity must match', () async {
    final identity = Map<String, dynamic>.from(copy('unknown')['calls'][4] as Map);
    for (final isFinal in [false, true]) {
      handler = (req) => reply(req, 200, {
        'identity': identity,
        'final': isFinal,
        'result': {'content': [], 'isError': false},
        if (isFinal)
          'sessionData': {
            'message': {'id': 'saved-id'},
          },
        if (isFinal)
          'resources': [
            {'kind': 'spill-reference'},
          ],
      });
      final result = await client.getLifecycleResult(session, 37);
      expect(result!.isFinal, isFinal);
      expect(result.identity.callSeq, 37);
    }
    identity['callSeq'] = 38;
    await expectLater(client.getLifecycleResult(session, 37), throwsA(isA<DshProtocolException>()));
    expect(requests.every((r) => r == 'GET $lifecycleResultPath'), isTrue);
  });

  test('v1 unknown states, malformed calls, duplicate sequences and wrong sessions fail closed', () async {
    final variants = <Map<String, dynamic>>[];
    variants.add(copy('unknown')..['v'] = 2);
    variants.add(copy('unknown')..['state'] = 'future-state');
    variants.add(copy('unknown')..['calls'] = null);
    variants.add(copy('unknown')..['blocked'] = 'false');
    final wrongSession = copy('unknown');
    wrongSession['calls'][0]['sessionId'] = 'other';
    variants.add(wrongSession);
    final duplicate = copy('unknown');
    duplicate['calls'].add(duplicate['calls'][0]);
    variants.add(duplicate);
    final malformed = copy('unknown');
    malformed['calls'][4]['active'] = null;
    variants.add(malformed);
    for (final body in variants) {
      handler = (req) => reply(req, 200, body);
      await expectLater(client.getLifecycleStatus(session), throwsA(isA<DshProtocolException>()));
    }
  });

  test('global blocked state is not a successful resolution even with no call rows', () async {
    handler = (req) => reply(
      req,
      200,
      copy('unknown')
        ..['blocked'] = true
        ..['calls'] = [],
    );
    final state = await client.getLifecycleStatus(session);
    expect(state.hasUnknownResult, isTrue);
    expect(state.blocked, isTrue);
    expect(state.unresolvedCalls, isEmpty);
  });

  test('redirects, invalid JSON and HTML do not become a valid status or trigger replay', () async {
    handler = (req) async {
      req.response
        ..statusCode = 307
        ..headers.set('location', '/elsewhere');
      await req.response.close();
    };
    await expectLater(
      client.acknowledgeLifecycleUnknown(session, userConfirmed: true),
      throwsA(isA<DshHttpException>()),
    );
    expect(requests, ['POST $lifecyclePath']);
    for (final contentType in [ContentType.html, ContentType.json]) {
      handler = (req) async {
        req.response.headers.contentType = contentType;
        req.response.write('not JSON');
        await req.response.close();
      };
      await expectLater(client.getLifecycleStatus(session), throwsA(isA<DshProtocolException>()));
    }
  });

  test('lost acknowledgement response is never retried', () async {
    handler = (req) async {
      await req.drain<void>();
      final socket = await req.response.detachSocket(writeHeaders: false);
      socket.destroy();
    };
    await expectLater(
      client.acknowledgeLifecycleUnknown(session, userConfirmed: true),
      throwsA(isA<DshTransportException>()),
    );
    expect(requests, ['POST $lifecyclePath']);
  });

  test('invalid identity and oversized encoded control send nothing', () async {
    for (final id in ['', 'a\u0000b', 'a' * 4097]) {
      await expectLater(client.getLifecycleStatus(id), throwsArgumentError);
    }
    for (final seq in [-1, 9007199254740992]) {
      await expectLater(client.getLifecycleResult(session, seq), throwsArgumentError);
    }
    await expectLater(client.acknowledgeLifecycleUnknown('中' * 3000, userConfirmed: true), throwsArgumentError);
    expect(requests, isEmpty);
  });

  test('relay-only clients cannot replace lifecycle with RPC or another route', () async {
    final relay = DshClient.withCarrier(_RelayOnly());
    addTearDown(relay.close);
    await expectLater(relay.getLifecycleStatus(session), throwsA(isA<DshRemoteException>()));
    await expectLater(
      relay.acknowledgeLifecycleUnknown(session, userConfirmed: true),
      throwsA(isA<DshRemoteException>()),
    );
    expect(requests, isEmpty);
  });
}
