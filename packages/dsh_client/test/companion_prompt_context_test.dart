import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late DshClient client;
  late Future<void> Function(HttpRequest) handler;
  final requests = <String>[];
  const session = '会话 &?';
  Map<String, Object?> capability({String id = session}) => {
    'v': 1,
    'supported': true,
    'instanceId': 'boot',
    'sessionId': id,
    'profileRevision': 3,
  };
  Future<void> reply(HttpRequest request, int status, Object body) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (req) => reply(req, 404, {});
    server.listen((req) async {
      requests.add(req.method);
      await handler(req);
    });
    client = DshClient(
      DshConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        cookie: DshCookie(name: 'dsh-auth-fixture', value: 'synthetic', authority: '127.0.0.1:${server.port}'),
      ),
    );
  });
  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  test('capability uses an encoded session id and authenticated read only', () async {
    handler = (req) async {
      expect(req.uri.path, '$dshGoCompanionPath/prompt-context');
      expect(req.uri.queryParameters['sessionId'], session);
      expect(req.headers.value('cookie'), 'dsh-auth-fixture=synthetic');
      await reply(req, 200, capability());
    };
    final value = (await client.companionPromptCapability(session))!;
    expect(value.instanceId, 'boot');
    expect(value.profileRevision, 3);
    expect(value.memoryMode, 'query');
    expect(value.memoryEpoch, isNull);
    expect(value.phoneMemory, isFalse);
    expect(value.chatUsage, isFalse);
    expect(requests, ['GET']);
  });
  test('phone selection and chat usage are explicit typed capabilities', () async {
    handler = (req) =>
        reply(req, 200, {...capability(), 'memoryMode': 'phone', 'phoneMemory': true, 'chatUsage': true});
    final value = (await client.companionPromptCapability(session))!;
    expect(value.phoneMemory, isTrue);
    expect(value.chatUsage, isTrue);
    expect(value.memoryMode, 'phone');
    for (final changes in [
      {'memoryMode': 'phone'},
      {'memoryMode': 'phone', 'phoneMemory': false},
      {'phoneMemory': 'true'},
      {'phoneMemory': null},
      {'chatUsage': 'true'},
      {'chatUsage': null},
    ]) {
      handler = (req) => reply(req, 200, {...capability(), ...changes});
      await expectLater(client.companionPromptCapability(session), throwsA(isA<DshProtocolException>()));
    }
  });
  test('memory authority capability is advisory, typed and backwards compatible', () async {
    handler = (req) => reply(req, 200, {...capability(), 'memoryMode': 'automatic', 'memoryEpoch': 7});
    final value = (await client.companionPromptCapability(session))!;
    expect(value.memoryMode, 'automatic');
    expect(value.memoryEpoch, 7);
    // This field does not assert that a C902 binding is currently ready.
    for (final changes in [
      {'memoryMode': 'unknown'},
      {'memoryMode': null},
      {'memoryMode': true},
      {'memoryEpoch': null},
      {'memoryEpoch': '7'},
      {'memoryEpoch': 0.5},
      {'memoryEpoch': -1},
      {'memoryEpoch': 9007199254740992},
    ]) {
      handler = (req) => reply(req, 200, {...capability(), ...changes});
      await expectLater(client.companionPromptCapability(session), throwsA(isA<DshProtocolException>()));
    }
  });
  test('only absent old routes degrade; auth and session failures remain errors', () async {
    for (final body in [
      {},
      {
        'error': {'code': 'companion/not-found'},
      },
    ]) {
      handler = (req) => reply(req, 404, body);
      expect(await client.companionPromptCapability(session), isNull);
    }
    for (final status in [401, 403, 404, 409, 503]) {
      handler = (req) => reply(req, status, {
        'error': {'code': 'companion/session-unavailable'},
      });
      await expectLater(client.companionPromptCapability(session), throwsA(isA<DshRemoteException>()));
    }
    expect(requests.every((m) => m == 'GET'), isTrue);
  });
  test('wrong session, malformed capability and HTML are never successful probes', () async {
    for (final body in [
      capability(id: 'other'),
      {...capability(), 'profileRevision': -1},
      {...capability(), 'profileAccepted': 'true'},
      {...capability(), 'v': 2},
      <String, Object?>{},
    ]) {
      handler = (req) => reply(req, 200, body);
      await expectLater(client.companionPromptCapability(session), throwsA(isA<DshProtocolException>()));
    }
    handler = (req) async {
      req.response
        ..headers.contentType = ContentType.html
        ..write(jsonEncode(capability()));
      await req.response.close();
    };
    await expectLater(client.companionPromptCapability(session), throwsA(isA<DshProtocolException>()));
  });
  test('prepare preserves the exact request id/body; never retries a conflict itself', () async {
    final update = {'v': 1, 'sessionId': session, 'requestId': 'turn-id', 'instanceId': 'boot', 'events': []};
    handler = (req) async {
      expect(req.headers.contentType?.mimeType, 'application/json');
      expect(jsonDecode(await utf8.decoder.bind(req).join()), update);
      await reply(req, 200, {...capability(), 'profileAccepted': false});
    };
    expect((await client.prepareCompanionPromptContext(update)).profileAccepted, isFalse);
    handler = (req) => reply(req, 200, {...capability(), 'instanceId': 'different-boot'});
    await expectLater(client.prepareCompanionPromptContext(update), throwsA(isA<DshProtocolException>()));
    handler = (req) => reply(req, 409, {
      'error': {'code': 'companion/profile-conflict'},
    });
    await expectLater(client.prepareCompanionPromptContext(update), throwsA(isA<DshRemoteException>()));
    expect(requests, ['POST', 'POST', 'POST']);
  });
}
