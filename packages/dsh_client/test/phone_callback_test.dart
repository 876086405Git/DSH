import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _ownerSecret = '1111111111111111111111111111111111111111111111111111111111111111';
const _requestId = '22222222-2222-4222-8222-222222222222';
const _nonce = '33333333-3333-4333-8333-333333333333';

Map<String, Object?> _bootstrap(Uri uri) => {
  'v': 1,
  'engineId': 'engine-a',
  'bridgeGeneration': 3,
  'baseUrl': uri.toString(),
  'owner': _ownerSecret,
};

Map<String, Object?> _request({String tool = 'mcp__phone__clipboard'}) => {
  'v': 1,
  'engineId': 'engine-a',
  'bridgeGeneration': 3,
  'requestId': _requestId,
  'sessionId': 'session-a',
  'callId': 'call-a',
  'tool': tool,
  'args': tool == 'mcp__phone__handoff' ? {'reason': '请检查页面'} : {'set': ''},
  'timeoutMs': tool == 'mcp__phone__handoff' ? 600000 : 30000,
  'deadlineMs': tool == 'mcp__phone__handoff' ? 601000 : 31000,
};

const _written = DshPhoneResult(
  status: DshPhoneStatus.succeeded,
  effect: DshPhoneEffect.clipboardWritten,
  evidence: DshPhoneEvidence.unknown,
  dispatched: true,
  code: 'clipboard_written',
  message: '已写入剪贴板',
);

class _Host {
  _Host(this.server) {
    server.listen((request) async {
      if (request.method == 'GET') {
        request.response.statusCode = 200;
        await request.response.close();
        return;
      }
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>;
      bodies.add(body);
      cookies.add(request.headers.value('cookie'));
      origins.add(request.headers.value('origin'));
      paths.add(request.uri.toString());
      await answer(request, body);
    });
  }
  static Future<_Host> start() async => _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  final bodies = <Map<String, Object?>>[];
  final cookies = <String?>[];
  final origins = <String?>[];
  final paths = <String>[];
  Future<void> Function(HttpRequest, Map<String, Object?>) answer = (request, body) =>
      _json(request, {'v': 1, 'request': null});
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');
  DshPhoneOwner get owner => DshPhoneOwner.fromNative(_bootstrap(uri));
  DshConnection authenticated() => DshConnection(
    uri,
    cookie: DshCookie(name: 'dsh-auth-test', value: 'signed-cookie', authority: uri.authority),
  );
  Future<void> close() async {
    await server.close(force: true);
  }
}

Future<void> _json(HttpRequest request, Object? body) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<(_Host, DshConnection, DshPhoneClient)> _fixture() async {
  final host = await _Host.start();
  final authenticated = host.authenticated();
  final client = DshPhoneClient(authenticated, host.owner);
  addTearDown(() async {
    client.close();
    authenticated.close(force: true);
    await host.close();
  });
  return (host, authenticated, client);
}

void main() {
  test('native owner accepts only an exact local endpoint and never formats its secret', () {
    final valid = _bootstrap(Uri.parse('http://127.0.0.1:3080'));
    expect(DshPhoneOwner.fromNative(valid).toString(), isNot(contains(_ownerSecret)));
    for (final url in [
      'http://example.invalid:3080',
      'https://127.0.0.1:3080',
      'http://localhost:3080',
      'http://[::1]:3080',
      'http://127.0.0.1:3080/?token=x',
      'http://user@127.0.0.1:3080',
      'http://127.0.0.1:3080/mount',
      'http://127.0.0.1:65536',
      'http://127.0.0.1:0',
    ]) {
      expect(
        () => DshPhoneOwner.fromNative({...valid, 'baseUrl': url}),
        throwsA(isA<DshProtocolException>()),
        reason: url,
      );
    }
    expect(() => DshPhoneOwner.fromNative({...valid, 'unexpected': 1}), throwsA(isA<DshProtocolException>()));
    expect(() => DshPhoneOwner.fromNative({...valid, 'bridgeGeneration': 0}), throwsA(isA<DshProtocolException>()));
    expect(
      () => DshPhoneOwner.fromNative({...valid, 'owner': 'not a capability'}),
      throwsA(isA<DshProtocolException>()),
    );
  });

  test('a remote or mismatched cookie connection is rejected before a request', () async {
    final (host, auth, client) = await _fixture();
    final remote = DshConnection(Uri.parse('https://example.invalid'), cookie: auth.cookie);
    addTearDown(() => remote.close(force: true));
    expect(() => DshPhoneClient(remote, host.owner), throwsA(isA<DshPhoneException>()));
    final overridden = DshConnection(host.uri, hostHeader: 'localhost:${host.uri.port}', cookie: auth.cookie);
    addTearDown(() => overridden.close(force: true));
    expect(() => DshPhoneClient(overridden, host.owner), throwsA(isA<DshPhoneException>()));
    auth.cookie = DshCookie(name: 'dsh-auth-test', value: 'other', authority: '127.0.0.1:1');
    await expectLater(client.next(), throwsA(isA<DshPhoneException>()));
    expect(host.bodies, isEmpty);
  });

  test('real HTTP next claim and result retain exact scope, cookie and empty clipboard text', () async {
    final (host, _, client) = await _fixture();
    host.answer = (request, body) async {
      expect(body['owner'], _ownerSecret);
      expect((body['engineId'], body['bridgeGeneration']), ('engine-a', 3));
      switch (request.uri.path.split('/').last) {
        case 'next':
          await _json(request, {'v': 1, 'request': _request()});
        case 'claim':
          await _json(request, {'request': _request(), 'executionNonce': _nonce});
        case 'result':
          await _json(request, {'accepted': true, 'result': body['result']});
      }
    };
    final request = (await client.next())!;
    expect(request.args['set'], '');
    expect(() => request.args['set'] = 'changed', throwsUnsupportedError);
    final claim = await client.claim(request);
    expect(claim.nativeIdentity.keys, unorderedEquals(['engineId', 'bridgeGeneration', 'requestId', 'executionNonce']));
    expect(claim.toString(), isNot(contains(_nonce)));
    final receipt = await client.report(claim, _written);
    expect(receipt.accepted, isTrue);
    expect(receipt.result.toJson(), _written.toJson());
    expect(host.cookies, everyElement('dsh-auth-test=signed-cookie'));
    expect(host.origins, everyElement(isNull));
    expect(host.paths, everyElement(isNot(contains('?'))));
  });

  test('redirects never send owner or cookie to the redirect target', () async {
    final (host, _, client) = await _fixture();
    final other = await _Host.start();
    addTearDown(other.close);
    host.answer = (request, body) async {
      request.response.statusCode = 307;
      request.response.headers.set('location', '${other.uri}/dsh-go/v1/phone/next');
      request.response.write(_ownerSecret);
      await request.response.close();
    };
    await expectLater(
      client.next(),
      throwsA(
        isA<DshPhoneException>()
            .having((error) => error.httpStatus, 'status', 307)
            .having((error) => error.toString().contains(_ownerSecret), 'no raw body', isFalse),
      ),
    );
    expect(other.bodies, isEmpty);
  });

  test('closing a pending real socket poll does not close the application connection', () async {
    final (host, authenticated, client) = await _fixture();
    final received = Completer<void>();
    host.answer = (request, body) async {
      received.complete();
    };
    final pending = client.next();
    final closed = expectLater(pending, throwsA(isA<DshClosedException>()));
    await received.future.timeout(const Duration(seconds: 2));
    client.close();
    await closed.timeout(const Duration(seconds: 2));
    expect(await authenticated.checkHealth(), DshHealth.ok);
    await expectLater(client.next(), throwsA(isA<DshClosedException>()));
    client.close();
    expect(host.bodies.length, 1);
  });

  test('only one next is pending, and replacing the signed cookie is used on the next read', () async {
    final (host, authenticated, client) = await _fixture();
    final received = Completer<void>();
    final release = Completer<void>();
    host.answer = (request, body) async {
      if (!received.isCompleted) {
        received.complete();
        await release.future;
      }
      await _json(request, {'v': 1, 'request': null});
    };
    final first = client.next();
    await received.future;
    await expectLater(
      client.next(),
      throwsA(isA<DshPhoneException>().having((e) => e.code, 'code', 'read_in_progress')),
    );
    release.complete();
    expect(await first, isNull);
    authenticated.cookie = DshCookie(name: 'dsh-auth-test', value: 'replacement', authority: host.uri.authority);
    expect(await client.next(), isNull);
    expect(host.cookies, ['dsh-auth-test=signed-cookie', 'dsh-auth-test=replacement']);
    authenticated.cookie = DshCookie(
      name: 'dsh-auth-test',
      value: 'expired',
      authority: host.uri.authority,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    await expectLater(client.next(), throwsA(isA<DshPhoneException>()));
    expect(host.bodies.length, 2);
  });

  test('wrong generation, changed claim arguments and forged result evidence are refused', () async {
    final (host, _, client) = await _fixture();
    host.answer = (request, body) => _json(request, {
      'v': 1,
      'request': {..._request(), 'bridgeGeneration': 4},
    });
    await expectLater(client.next(), throwsA(isA<DshPhoneException>()));
    final request = DshPhoneRequest.fromJson(_request());
    host.answer = (request, body) => _json(request, {
      'request': {
        ..._request(),
        'args': {'set': 'swapped'},
      },
      'executionNonce': _nonce,
    });
    await expectLater(client.claim(request), throwsA(isA<DshProtocolException>()));
    host.answer = (request, body) => _json(request, {'request': _request(), 'executionNonce': _nonce});
    final claim = await client.claim(request);
    final calls = host.bodies.length;
    const forged = DshPhoneResult(
      status: DshPhoneStatus.succeeded,
      effect: DshPhoneEffect.clipboardWritten,
      evidence: DshPhoneEvidence.userConfirmed,
      dispatched: true,
      code: 'ok',
      message: '',
    );
    await expectLater(client.report(claim, forged), throwsA(isA<DshProtocolException>()));
    expect(host.bodies.length, calls);
  });

  test('waiting user is progress; cancellation and a late nonaccepted receipt stay explicit', () async {
    final (host, _, client) = await _fixture();
    final request = DshPhoneRequest.fromJson(_request(tool: 'mcp__phone__handoff'));
    host.answer = (req, body) async {
      if (req.uri.path.endsWith('/claim')) return _json(req, {'request': request.toJson(), 'executionNonce': _nonce});
      if (body['phase'] == 'waiting_user') return _json(req, {'accepted': true, 'phase': 'waiting_user'});
      if (req.uri.path.endsWith('/cancel')) return _json(req, {'accepted': true});
      return _json(req, {
        'accepted': false,
        'result': {
          'status': 'cancelled',
          'effect': 'none',
          'evidence': 'unknown',
          'dispatched': false,
          'code': 'user_stopped',
          'message': '已停止',
        },
      });
    };
    final claim = await client.claim(request);
    await client.waiting(claim);
    expect(host.bodies.last.containsKey('result'), isFalse);
    expect(await client.cancel(request), isTrue);
    const confirmation = DshPhoneResult(
      status: DshPhoneStatus.succeeded,
      effect: DshPhoneEffect.none,
      evidence: DshPhoneEvidence.userConfirmed,
      dispatched: true,
      code: 'user_confirmed',
      message: '已继续',
    );
    final receipt = await client.report(claim, confirmation);
    expect(receipt.accepted, isFalse);
    expect(receipt.result.status, DshPhoneStatus.cancelled);
  });

  test('malformed UTF8 and unknown fields never become a request', () async {
    final (host, _, client) = await _fixture();
    host.answer = (request, body) async {
      request.response.headers.contentType = ContentType.json;
      request.response.add([0xff]);
      await request.response.close();
    };
    await expectLater(client.next(), throwsA(isA<DshProtocolException>()));
    host.answer = (request, body) => _json(request, {'v': 1, 'request': null, 'extra': 1});
    await expectLater(client.next(), throwsA(isA<DshProtocolException>()));
  });

  test('the real HTTP response limit closes an oversized reply', () async {
    final (host, _, client) = await _fixture();
    host.answer = (request, body) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(' ' * (4 * 1024 * 1024 + 1));
      try {
        await request.response.close();
      } catch (_) {
        /* Bounded receiver aborted. */
      }
    };
    await expectLater(client.next(), throwsA(isA<DshProtocolException>()));
  });

  test('ambient transport overrides cannot observe the native capability', () async {
    final (host, auth, _) = await _fixture();
    var overridesCalled = 0;
    await HttpOverrides.runZoned(
      () async {
        expect(() => DshPhoneClient(auth, host.owner), throwsA(isA<DshPhoneException>()));
      },
      createHttpClient: (_) {
        overridesCalled++;
        throw StateError('must not construct a proxy client');
      },
    );
    expect(overridesCalled, 0);
    expect(host.bodies, isEmpty);
  });
}
