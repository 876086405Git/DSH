import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart'
    show RemoteHostSession, RemoteRpcClient, RemoteRpcException, SecureChannelClosed;
import 'package:dsh_remote/src/dsh_web.dart';
import 'package:test/test.dart';

const _url = 'https://test-host.hostc.4ba.io/';
final _grant = List.filled(43, 'g').join();
final _now = DateTime.utc(2026, 11, 19);

Map<String, Object?> _response() => {
  'url': _url,
  'browserGrant': _grant,
  'expiresAt': _now.millisecondsSinceEpoch + 30000,
};

Matcher _code(String code) => isA<RemoteDshWebException>().having((error) => error.code, 'code', code);

class _Rpc implements RemoteRpcClient {
  final calls = <({String method, Object? params, Duration? timeout})>[];
  FutureOr<Object?> Function(String)? handler;
  final _done = Completer<SecureChannelClosed>();

  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<SecureChannelClosed> get done => _done.future;
  @override
  Future<Object?> call(String method, Object? params, {Duration? timeout}) async {
    calls.add((method: method, params: params, timeout: timeout));
    if (handler != null) return await handler!(method);
    return method == 'dsh.web.close' ? {'closed': true} : _response();
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete(const SecureChannelClosed('CLIENT_CLOSED', 'test'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Rpc rpc;
  late RemoteHostSession session;
  late RemoteDshWeb web;

  setUp(() {
    rpc = _Rpc();
    session = RemoteHostSession(rpc: rpc, capabilities: const ['dsh.web.v1']);
    web = RemoteDshWeb(session, now: () => _now);
  });

  test('open sends only an empty object over the original session with a 25 second budget', () async {
    final grant = await web.open();
    expect(grant.url.toString(), _url);
    expect(grant.exchangeUrl.toString(), '${_url}__remote/session');
    expect(rpc.calls.single.method, 'dsh.web.open');
    expect(rpc.calls.single.params, isEmpty);
    expect(rpc.calls.single.timeout, const Duration(seconds: 25));
    expect(grant.toString(), isNot(contains(_grant)));
    expect(grant.exchangeBase.toString(), '${_url}__remote/session-bootstrap');
    final page = grant.takeExchangePage();
    expect(page, contains('<form method="post" action="/__remote/session">'));
    expect(page, contains('name="browserGrant" value="$_grant"'));
    expect(page, contains("form-action 'self'"));
    expect(page, contains('document.forms[0].submit()'));
    expect(() => grant.takeExchangePage(), throwsA(_code('GRANT_CONSUMED')));
  });

  test('the current tun.4ba.io parent and the compatible hostc.4ba.io are both trusted', () async {
    for (final url in ['https://tabcdefghijk.tun.4ba.io/', 'https://pabcdefghijk.hostc.4ba.io/']) {
      rpc.handler = (_) => {..._response(), 'url': url};
      expect((await web.open()).url.toString(), url);
    }
    expect(isTrustedDshWebRoot(Uri.parse('https://x.tun-test.4ba.io/')), isFalse);
  });

  test('close checks the authoritative closed flag', () async {
    expect(await web.close(), isTrue);
    expect(rpc.calls.single.method, 'dsh.web.close');
    expect(rpc.calls.single.params, isEmpty);
    rpc.handler = (_) => {'closed': false};
    await expectLater(web.close(), throwsA(_code('INVALID_WEB_RESPONSE')));
  });

  test('unsupported and disconnected sessions make no RPC and never reconnect', () async {
    final old = RemoteDshWeb(RemoteHostSession(rpc: rpc, capabilities: const []));
    expect(old.supported, isFalse);
    await expectLater(old.open(), throwsA(_code('FEATURE_NOT_SUPPORTED')));
    await rpc.close();
    expect(web.supported, isFalse);
    await expectLater(web.open(), throwsA(_code('CONNECTION_NOT_FOUND')));
    expect(await web.close(), isFalse);
    expect(rpc.calls, isEmpty);
  });

  for (final url in [
    'http://test-host.hostc.4ba.io/',
    'https://hostc.4ba.io/',
    'https://nested.test-host.hostc.4ba.io/',
    'https://test-host.hostc.4ba.io.evil.test/',
    'https://test-host.hostc.4ba.io:443/',
    'https://test-host.hostc.4ba.io:/',
    'https://user@test-host.hostc.4ba.io/',
    'https://test-host.hostc.4ba.io/?',
    'https://test-host.hostc.4ba.io/#',
    'https://test-host.hostc.4ba.io/path',
    'https://-test.hostc.4ba.io/',
    'https://test_.hostc.4ba.io/',
    'https://test-host.hostc.4ba.io',
    'https://127.0.0.1/',
    'https://custom.tunnels.example/',
    'file:///etc/passwd',
  ]) {
    test('rejects an untrusted or non-root URL: $url', () async {
      rpc.handler = (_) => {..._response(), 'url': url};
      await expectLater(web.open(), throwsA(_code('UNTRUSTED_WEB_URL')));
    });
  }

  test('custom trusted configuration is injected, never learned from a response', () async {
    rpc.handler = (_) => {..._response(), 'url': 'https://host.tunnels.example/'};
    await expectLater(web.open(), throwsA(_code('UNTRUSTED_WEB_URL')));
    final custom = RemoteDshWeb(session, trustedTunnelDomains: const {'tunnels.example'}, now: () => _now);
    expect((await custom.open()).url.host, 'host.tunnels.example');
  });

  for (final invalid in [
    null,
    true,
    12,
    '',
    List.filled(42, 'a').join(),
    List.filled(44, 'a').join(),
    '${List.filled(42, 'a').join()}=',
  ]) {
    test('rejects invalid grant: $invalid', () async {
      rpc.handler = (_) => {..._response(), 'browserGrant': invalid};
      await expectLater(web.open(), throwsA(_code('INVALID_WEB_RESPONSE')));
    });
  }

  for (final expires in [
    null,
    '1790000000000',
    1790000000000.0,
    _now.millisecondsSinceEpoch - dshWebClockSkew.inMilliseconds,
    _now.millisecondsSinceEpoch - dshWebClockSkew.inMilliseconds - 1,
  ]) {
    test('expiry must be a Unix millisecond integer within the clock skew: $expires', () async {
      rpc.handler = (_) => {..._response(), 'expiresAt': expires};
      await expectLater(web.open(), throwsA(_code(expires is int ? 'GRANT_EXPIRED' : 'INVALID_WEB_RESPONSE')));
    });
  }

  test('a phone clock running up to a minute ahead still opens', () async {
    final ahead = RemoteDshWeb(session, now: () => _now.add(const Duration(seconds: 80)));
    final grant = await ahead.open();
    expect(grant.takeExchangePage(), contains(_grant));
  });

  test('rechecks expiry when taking the page and retires expired grants', () async {
    var now = _now;
    final grant = await RemoteDshWeb(session, now: () => now).open();
    now = now.add(const Duration(seconds: 30)).add(dshWebClockSkew);
    expect(() => grant.takeExchangePage(), throwsA(_code('GRANT_EXPIRED')));
    expect(() => grant.takeExchangePage(), throwsA(_code('GRANT_CONSUMED')));
  });

  test('discard retires a grant without building a page', () async {
    final grant = await web.open();
    grant.discard();
    expect(() => grant.takeExchangePage(), throwsA(_code('GRANT_CONSUMED')));
  });

  test('close and reopen serialize across API instances for one session', () async {
    final opening = Completer<Object?>();
    final closing = Completer<Object?>();
    var opens = 0;
    rpc.handler = (method) {
      if (method == 'dsh.web.close') return closing.future;
      return opens++ == 0 ? opening.future : _response();
    };
    final first = web.open();
    final close = web.close();
    final second = RemoteDshWeb(session, now: () => _now).open();
    await Future<void>.delayed(Duration.zero);
    expect(rpc.calls.map((call) => call.method), ['dsh.web.open']);
    opening.complete(_response());
    (await first).discard();
    await Future<void>.delayed(Duration.zero);
    expect(rpc.calls.map((call) => call.method), ['dsh.web.open', 'dsh.web.close']);
    closing.complete({'closed': true});
    expect(await close, isTrue);
    (await second).discard();
    expect(rpc.calls.map((call) => call.method), ['dsh.web.open', 'dsh.web.close', 'dsh.web.open']);
  });

  for (final code in ['RATE_LIMITED', 'RPC_TIMEOUT', 'TUNNEL_UNAVAILABLE']) {
    test('$code never replays open and still permits original-session cleanup', () async {
      rpc.handler = (method) {
        if (method == 'dsh.web.open') throw RemoteRpcException(code, 'test');
        return {'closed': true};
      };
      await expectLater(web.open(), throwsA(isA<RemoteRpcException>().having((e) => e.code, 'code', code)));
      expect(await web.close(), isTrue);
      expect(rpc.calls.map((call) => call.method), ['dsh.web.open', 'dsh.web.close']);
    });
  }
}
