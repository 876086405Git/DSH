// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show HostKind, HostRef;
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/remote_web_state.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/remote/remote_web/remote_web_entry.dart';
import 'package:dsh_app/ui/remote/remote_web/remote_web_error.dart';
import 'package:dsh_app/ui/remote/remote_web/remote_web_page.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteHostSession, RemoteRpcException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    rpc = WebRpc();
    session = RemoteHostSession(rpc: rpc, capabilities: const ['dsh.web.v1']);
    carrier = WebCarrier(session);
    _initial = webConnection(carrier);
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
        const Scaffold(body: RemoteWebEntry()),
        overrides: [
          operatingSystemProvider.overrideWithValue(os),
          readListLiveConnectionProvider.overrideWith((ref) => ref.watch(_live)),
        ],
      ),
    );
    await _frames(tester);
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text(appL10n.remoteWebOpen));
    await _frames(tester);
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await _frames(tester);
  }

  testWidgets('entry uses fresh session capability and refreshes on replacement', (tester) async {
    carrier.current = RemoteHostSession(rpc: rpc, capabilities: const []);
    final container = await pump(tester);
    expect(find.text(appL10n.remoteWebOpen), findsNothing);
    carrier.replace(session);
    await _frames(tester);
    expect(container.read(remoteWebSessionProvider).value, same(session));
    expect(find.text(appL10n.remoteWebOpen), findsOneWidget);
    carrier.replace(RemoteHostSession(rpc: rpc, capabilities: const []));
    await _frames(tester);
    expect(find.text(appL10n.remoteWebOpen), findsNothing);
    expect(rpc.calls, isEmpty);
    await remove(tester);
  });

  testWidgets('OHOS entry is hidden without sending open', (tester) async {
    await pump(tester, os: 'ohos');
    expect(find.text(appL10n.remoteWebOpen), findsNothing);
    expect(rpc.calls, isEmpty);
    await remove(tester);
  });

  testWidgets('disconnected or closed Noise session cannot expose an entry', (tester) async {
    await pump(tester);
    carrier.disconnect();
    await _frames(tester);
    expect(find.text(appL10n.remoteWebOpen), findsNothing);
    await remove(tester);
  });

  testWidgets('Noise done retires entry before the mux reconnect event', (tester) async {
    final container = await pump(tester);
    expect(container.read(remoteWebSessionProvider).value, same(session));
    await rpc.close();
    expect(session.isClosed, isTrue);
    await _frames(tester);
    expect(container.read(remoteWebSessionProvider).value, isNull);
    expect(find.text(appL10n.remoteWebOpen), findsNothing);
    await remove(tester);
  });

  testWidgets('taps merge into one POST and ordinary refresh GETs the clean root', (tester) async {
    await pump(tester);
    final tap = tester.widget<TextButton>(find.byWidgetPredicate((widget) => widget is TextButton)).onPressed!;
    tap();
    tap();
    await _frames(tester);
    expect(find.byType(RemoteWebPage), findsOneWidget);
    expect(rpc.calls, ['dsh.web.open']);
    final web = platform.last;
    final post = web.requests.single;
    expect(post.method, LoadRequestMethod.post);
    expect(post.uri, testRoot.resolve('/__remote/session'));
    expect(post.uri.toString(), isNot(contains(testGrant)));
    expect(post.headers['Content-Type'], 'application/x-www-form-urlencoded');
    expect(utf8.decode(post.body!), 'browserGrant=$testGrant');
    expect(web.channels, isEmpty);
    expect(find.text(appL10n.remoteWebOpening), findsOneWidget);
    web.navigation.onPageFinished!(testRoot.toString());
    await _frames(tester);
    expect(find.text(appL10n.remoteWebOpening), findsNothing);
    await tester.tap(find.byTooltip(appL10n.remoteWebRefresh));
    await _frames(tester);
    expect(web.requests.last.method, LoadRequestMethod.get);
    expect(web.requests.last.uri, testRoot);
    expect(web.requests.last.body, isNull);
    expect(web.reloads, 0);
    Navigator.of(tester.element(find.byType(RemoteWebPage))).pop();
    await _frames(tester);
    expect(rpc.calls, ['dsh.web.open', 'dsh.web.close']);
    expect(islands.destroyed, [web.webViewIdentifier]);
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
    expect(platform.last.requests, isEmpty);
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
    expect(web.requests, hasLength(1));
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
    expect(platform.last.requests, isEmpty);
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
    expect(platform.last.requests, isEmpty);
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
      expect(web.requests, hasLength(1));
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
      expect(web.requests, hasLength(1));
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
    expect(web.requests, hasLength(1));
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
      expect(web.requests, hasLength(1));
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
