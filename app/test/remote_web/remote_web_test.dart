// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show ActiveHostController, HostKind, HostRef, activeHostProvider;
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/remote_web_state.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/remote/remote_web/remote_web_error.dart';
import 'package:dsh_app/ui/remote/remote_web/remote_web_page.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteHostSession, RemoteRpcException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import '../web/support/fake_webview.dart';
import 'support.dart';

HostConnection? _initial;

class _LiveConnection extends Notifier<HostConnection?> {
  @override
  HostConnection? build() => _initial;
  void set(HostConnection? value) => state = value;
}

final _live = NotifierProvider<_LiveConnection, HostConnection?>(_LiveConnection.new);

class _RelayActive extends ActiveHostController {
  @override
  HostRef build() => const HostRef.relay('host');
}

/// 网页版 as every native entry opens it ([openDshWeb]): nothing watches the
/// active host's DSH Web before the tap.
class _Opener extends ConsumerWidget {
  const _Opener();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: TextButton(onPressed: () => openDshWeb(context, ref), child: const Text('open')),
      ),
    );
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late WebRpc rpc;
  late RemoteHostSession session;
  late WebCarrier carrier;
  late TestWebPlatform platform;
  late FakeIslandPlatform islands;
  late IslandPlatform previousIslands;
  late HostLinkStatus linkStatus;

  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
    rpc = WebRpc();
    session = RemoteHostSession(rpc: rpc, capabilities: const ['dsh.web.v1']);
    carrier = WebCarrier(session);
    _initial = webConnection(carrier);
    linkStatus = const HostLinkStatus(HostLinkPhase.connected);
    WebViewPlatform.instance = platform = TestWebPlatform();
    previousIslands = IslandPlatform.instance;
    IslandPlatform.instance = islands = FakeIslandPlatform();
  });

  tearDown(() async {
    IslandPlatform.instance = previousIslands;
    await carrier.close();
    await rpc.close();
  });

  Future<ProviderContainer> pump(WidgetTester tester, {String os = 'android'}) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const _Opener(),
        overrides: [
          operatingSystemProvider.overrideWithValue(os),
          readListLiveConnectionProvider.overrideWith((ref) => ref.watch(_live)),
          activeHostProvider.overrideWith(_RelayActive.new),
          hostNameProvider.overrideWith((ref, host) => 'studio'),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(linkStatus)),
        ],
      ),
    );
    await _frames(tester);
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await _frames(tester);
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await _frames(tester);
  }

  testWidgets('网页版 follows the fresh session capability and its replacement', (tester) async {
    carrier.current = RemoteHostSession(rpc: rpc, capabilities: const []);
    final container = await pump(tester);
    final sub = container.listen(remoteWebSessionProvider, (_, _) {});
    expect(container.read(dshWebAccessProvider), isA<NoDshWeb>());
    carrier.replace(session);
    await _frames(tester);
    expect(container.read(remoteWebSessionProvider).value, same(session));
    expect(container.read(dshWebAccessProvider), isA<RelayDshWeb>());
    carrier.replace(RemoteHostSession(rpc: rpc, capabilities: const []));
    await _frames(tester);
    expect(container.read(dshWebAccessProvider), isA<NoDshWeb>());
    expect(rpc.calls, isEmpty);
    sub.close();
    await remove(tester);
  });

  testWidgets('connected without dsh.web.v1: 网页版 says what the Host needs', (tester) async {
    carrier.current = RemoteHostSession(rpc: rpc, capabilities: const []);
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text(appL10n.remoteWebHostNotReady), findsOneWidget);
    expect(find.byType(RemoteWebPage), findsNothing);
    expect(rpc.calls, isEmpty);
    await remove(tester);
  });

  testWidgets('not connected yet: 网页版 asks to connect the host first', (tester) async {
    _initial = null;
    linkStatus = HostLinkStatus.idle;
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text(appL10n.webConnectHostFirst('studio')), findsOneWidget);
    expect(rpc.calls, isEmpty);
    await remove(tester);
  });

  testWidgets('OHOS keeps 网页版 unavailable over DSH Remote without sending open', (tester) async {
    await pump(tester, os: 'ohos');
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text(appL10n.webRelayUnavailable), findsOneWidget);
    expect(find.byType(RemoteWebPage), findsNothing);
    expect(rpc.calls, isEmpty);
    await remove(tester);
  });

  testWidgets('disconnected or closed Noise session cannot expose 网页版', (tester) async {
    final container = await pump(tester);
    carrier.disconnect();
    await _frames(tester);
    expect(container.read(dshWebAccessProvider), isA<NoDshWeb>());
    await remove(tester);
  });

  testWidgets('Noise done retires 网页版 before the mux reconnect event', (tester) async {
    final container = await pump(tester);
    final sub = container.listen(remoteWebSessionProvider, (_, _) {});
    await _frames(tester);
    expect(container.read(remoteWebSessionProvider).value, same(session));
    await rpc.close();
    expect(session.isClosed, isTrue);
    expect(container.read(dshWebAccessProvider), isA<NoDshWeb>(), reason: 'read at once, not after an event');
    await _frames(tester);
    expect(container.read(remoteWebSessionProvider).value, isNull);
    sub.close();
    await remove(tester);
  });

  testWidgets('a failed page drops 重试 once its session goes away', (tester) async {
    rpc.handler = (method) {
      if (method == 'dsh.web.open') throw RemoteRpcException('RATE_LIMITED', 'busy');
      return {'closed': true};
    };
    await pump(tester);
    await open(tester);
    expect(find.text(appL10n.commonRetry), findsOneWidget);
    carrier.disconnect();
    await _frames(tester);
    expect(find.text(appL10n.commonRetry), findsNothing);
    expect(find.text(appL10n.remoteWebReconnect), findsOneWidget);
    await remove(tester);
  });

  testWidgets('taps merge into one open; the grant is posted by a form on the tunnel origin', (tester) async {
    await pump(tester);
    // The first tap opens: nothing watched the session before it.
    final tap = tester.widget<TextButton>(find.byType(TextButton)).onPressed!;
    tap();
    tap();
    await _frames(tester);
    expect(find.byType(RemoteWebPage), findsOneWidget);
    expect(rpc.calls, ['dsh.web.open']);
    final web = platform.last;
    final exchange = web.exchanges.single;
    expect(exchange.baseUrl, testRoot.resolve('/__remote/session-bootstrap').toString());
    expect(exchange.html, contains('<form method="post" action="/__remote/session">'));
    expect(exchange.html, contains('name="browserGrant" value="$testGrant"'));
    expect(web.requests, isEmpty, reason: 'no native POST: it can carry an opaque Origin');
    expect(web.channels, isEmpty);
    expect(find.text(appL10n.remoteWebOpening), findsOneWidget);
    // Android reports the exchange page as about:blank: not a foreign document.
    web.navigation.onPageStarted!('about:blank');
    await _frames(tester);
    expect(find.text(appL10n.remoteWebOpening), findsOneWidget);
    web.navigation.onPageFinished!(testRoot.toString());
    await _frames(tester);
    expect(find.text(appL10n.remoteWebOpening), findsNothing);
    await tester.tap(find.byTooltip(appL10n.remoteWebRefresh));
    await _frames(tester);
    expect(web.requests.single.method, LoadRequestMethod.get);
    expect(web.requests.single.uri, testRoot);
    expect(web.requests.single.body, isNull);
    expect(web.exchanges, hasLength(1));
    expect(web.reloads, 0);
    Navigator.of(tester.element(find.byType(RemoteWebPage))).pop();
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(islands.destroyed, [web.webViewIdentifier]);
    await remove(tester);
  });

  testWidgets('重试 after a failure closes the old lease, then opens once more', (tester) async {
    var opens = 0;
    rpc.handler = (method) {
      if (method != 'dsh.web.open') return {'closed': true};
      if (opens++ == 0) throw RemoteRpcException('RATE_LIMITED', 'busy');
      return webReply();
    };
    await pump(tester);
    await open(tester);
    expect(find.text(appL10n.remoteWebBusy), findsOneWidget);
    await tester.tap(find.text(appL10n.commonRetry));
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close', 'dsh.web.open']);
    expect(platform.last.exchanges, hasLength(1));
    platform.last.navigation.onPageFinished!(testRoot.toString());
    await remove(tester);
  });

  testWidgets('a session that is gone offers no 重试 on its page', (tester) async {
    await pump(tester);
    await open(tester);
    carrier.disconnect();
    await _frames(tester);
    expect(find.text(appL10n.remoteWebReconnect), findsOneWidget);
    expect(find.text(appL10n.commonRetry), findsNothing);
    await remove(tester);
  });

  testWidgets('as the home in 网页模式 the handle takes the back button\'s seat', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        RemoteWebPage(carrier: carrier, session: session, leading: const Text('handle')),
        overrides: [
          operatingSystemProvider.overrideWithValue('android'),
          readListLiveConnectionProvider.overrideWith((ref) => ref.watch(_live)),
        ],
      ),
    );
    await _frames(tester);
    expect(find.text('handle'), findsOneWidget);
    expect(find.byTooltip(appL10n.commonBack), findsNothing);
    platform.last.navigation.onPageFinished!(testRoot.toString());
    await remove(tester);
  });

  testWidgets('only tunnel-origin navigation is allowed, never local or external URLs', (tester) async {
    await pump(tester, os: 'ios');
    await open(tester);
    final web = platform.last;
    final navigate = web.navigation.navigate!;
    expect(
      await navigate(NavigationRequest(url: '${testRoot}sessions', isMainFrame: true)),
      NavigationDecision.navigate,
    );
    for (final url in [
      'https://evil.example/',
      'http://test-host.hostc.4ba.io/',
      'file:///etc/passwd',
      'content://secret',
      'javascript:alert(1)',
      'https://other.hostc.4ba.io/',
    ]) {
      expect(await navigate(NavigationRequest(url: url, isMainFrame: true)), NavigationDecision.prevent);
    }
    web.navigation.onPageFinished!(testRoot.toString());
    await remove(tester);
  });

  testWidgets('switching Host discards a late grant and closes only the original Noise session', (tester) async {
    final pending = Completer<Object?>();
    rpc.handler = (method) => method == 'dsh.web.open' ? pending.future : {'closed': true};
    final container = await pump(tester);
    await open(tester);
    final otherRpc = WebRpc();
    final other = WebCarrier(RemoteHostSession(rpc: otherRpc, capabilities: const ['dsh.web.v1']));
    container.read(_live.notifier).set(webConnection(other));
    await _frames(tester);
    expect(find.text(appL10n.remoteWebReconnect), findsOneWidget);
    pending.complete(webReply());
    await _frames(tester);
    expect(platform.last.exchanges, isEmpty);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(otherRpc.calls, isEmpty);
    await remove(tester);
    await other.close();
    await otherRpc.close();
  });

  testWidgets('renaming a Host wrapper does not revoke its unchanged Noise session', (tester) async {
    final container = await pump(tester);
    await open(tester);
    container
        .read(_live.notifier)
        .set(
          HostConnection(
            client: _initial!.client,
            isLocal: false,
            kind: HostKind.relay,
            hostId: 'host',
            name: 'renamed',
          ),
        );
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open']);
    expect(find.text(appL10n.remoteWebReconnect), findsNothing);
    platform.last.navigation.onPageFinished!(testRoot.toString());
    await remove(tester);
  });

  testWidgets('replacement Noise session on the same carrier cannot inherit the lease', (tester) async {
    await pump(tester);
    await open(tester);
    final replacementRpc = WebRpc();
    carrier.replace(RemoteHostSession(rpc: replacementRpc, capabilities: const ['dsh.web.v1']));
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(replacementRpc.calls, isEmpty);
    expect(find.text(appL10n.remoteWebReconnect), findsOneWidget);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    await remove(tester);
    await replacementRpc.close();
  });

  testWidgets('disconnect revokes the original lease once and removes the view', (tester) async {
    await pump(tester);
    await open(tester);
    final web = platform.last;
    web.navigation.onPageFinished!(testRoot.toString());
    carrier.disconnect();
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(find.text(appL10n.remoteWebReconnect), findsOneWidget);
    await rpc.close();
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    await remove(tester);
  });

  testWidgets('renderer loss destroys the view without replaying POST', (tester) async {
    await pump(tester);
    await open(tester);
    final web = platform.last;
    web.navigation.onPageFinished!(testRoot.toString());
    islands.gone();
    await _frames(tester);
    expect(web.exchanges, hasLength(1));
    expect(islands.destroyed, [web.webViewIdentifier]);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(find.text(appL10n.remoteWebTryAgain), findsOneWidget);
    await remove(tester);
  });

  testWidgets('initial RATE_LIMITED is friendly and never obtains another ticket', (tester) async {
    rpc.handler = (method) {
      if (method == 'dsh.web.open') throw RemoteRpcException('RATE_LIMITED', 'private: $testGrant');
      return {'closed': true};
    };
    await pump(tester);
    await open(tester);
    expect(find.text('人太多了，请稍后重试'), findsOneWidget);
    expect(find.textContaining(testGrant), findsNothing);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(platform.last.exchanges, isEmpty);
    await remove(tester);
  });

  testWidgets('TUNNEL_UNAVAILABLE stays generic and never leaks server details', (tester) async {
    rpc.handler = (method) {
      if (method == 'dsh.web.open') {
        throw RemoteRpcException('TUNNEL_UNAVAILABLE', 'private server response: $testGrant');
      }
      return {'closed': true};
    };
    await pump(tester);
    await open(tester);
    expect(find.text('暂时无法打开，请稍后重试'), findsOneWidget);
    expect(find.text('人太多了，请稍后重试'), findsNothing);
    expect(find.textContaining(testGrant), findsNothing);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(platform.last.exchanges, isEmpty);
    await remove(tester);
  });

  for (final path in ['/favicon.ico', '/api/session/list']) {
    testWidgets('subresource 429 at $path does not retire the Web UI', (tester) async {
      await pump(tester);
      await open(tester);
      final web = platform.last;
      web.navigation.onPageFinished!(testRoot.toString());
      web.navigation.httpError!(
        HttpResponseError(
          request: WebResourceRequest(uri: testRoot.resolve(path)),
          response: const WebResourceResponse(uri: null, statusCode: 429),
        ),
      );
      await _frames(tester);
      expect(rpc.calls, ['dsh.web.open']);
      expect(web.exchanges, hasLength(1));
      expect(islands.destroyed, isEmpty);
      expect(find.byKey(fakeWebViewKey), findsOneWidget);
      expect(find.text(appL10n.remoteWebBusy), findsNothing);
      await remove(tester);
    });
  }

  for (final withUrl in [true, false]) {
    testWidgets('HTTP 429 with URL=$withUrl is friendly and does not replay POST', (tester) async {
      await pump(tester, os: withUrl ? 'android' : 'ios');
      await open(tester);
      final web = platform.last;
      web.navigation.httpError!(
        HttpResponseError(
          request: withUrl ? WebResourceRequest(uri: testRoot.resolve('/__remote/session')) : null,
          response: const WebResourceResponse(uri: null, statusCode: 429),
        ),
      );
      await _frames(tester);
      expect(find.text('人太多了，请稍后重试'), findsOneWidget);
      expect(web.exchanges, hasLength(1));
      expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
      expect(find.byKey(fakeWebViewKey), findsNothing);
      await remove(tester);
    });
  }

  testWidgets('an ambiguous exchange failure does not replay a form or obtain another ticket', (tester) async {
    await pump(tester);
    await open(tester);
    final web = platform.last;
    web.fail();
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(web.exchanges, hasLength(1));
    expect(find.text(appL10n.remoteWebTryAgain), findsOneWidget);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    await remove(tester);
  });

  for (final status in [400, 403, 405, 401, 404, 410, 425]) {
    testWidgets('HTTP $status offers a close-and-reopen recovery, not POST replay', (tester) async {
      await pump(tester);
      await open(tester);
      final web = platform.last;
      web.navigation.httpError!(
        HttpResponseError(
          request: WebResourceRequest(uri: testRoot.resolve('/__remote/session')),
          response: WebResourceResponse(uri: null, statusCode: status),
        ),
      );
      await _frames(tester);
      expect(web.exchanges, hasLength(1));
      expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
      expect(
        find.text(
          status == 400 || status == 403 || status == 405
              ? appL10n.remoteWebExchangeRejected
              : appL10n.remoteWebSessionExpired,
        ),
        findsOneWidget,
      );
      await remove(tester);
    });
  }

  testWidgets('quick reopen waits for pending original close', (tester) async {
    final closing = Completer<Object?>();
    rpc.handler = (method) => method == 'dsh.web.close' ? closing.future : webReply();
    await pump(tester);
    await open(tester);
    platform.last.navigation.onPageFinished!(testRoot.toString());
    Navigator.of(tester.element(find.byType(RemoteWebPage))).pop();
    await _frames(tester);
    await open(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    closing.complete({'closed': true});
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close', 'dsh.web.open']);
    platform.last.navigation.onPageFinished!(testRoot.toString());
    await remove(tester);
  });

  test('error text is actionable and never displays raw server messages', () {
    expect(remoteWebErrorText(appL10n, 'RATE_LIMITED'), '人太多了，请稍后重试');
    expect(remoteWebErrorText(appL10n, 'MEMBERSHIP_REQUIRED'), appL10n.remoteWebPairingRequired);
    expect(remoteWebErrorText(appL10n, 'WEB_ENTITLEMENT_REQUIRED'), appL10n.remoteWebTryAgain);
    expect(remoteWebErrorText(appL10n, 'DSH_WEB_NOT_READY'), contains('0.6.6'));
  });

  test('retained or fallback Host connections are not authority', () {
    expect(readListConnection(AsyncData(_initial), const HostRef.relay('other')), isNull);
    expect(readListConnection(AsyncData(_initial), HostRef.local), isNull);
    expect(readListConnection(const AsyncLoading(), const HostRef.relay('host')), isNull);
  });
}
