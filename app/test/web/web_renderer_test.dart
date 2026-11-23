// A WebView's renderer dying (a crash, or Android killing it in the
// background) must not take the app with it: every page of the app guards
// its WebView (WebViewGuard → the islands' platform side), says so in one
// quiet line and builds a new WebView on 重新打开.

// ignore_for_file: depend_on_referenced_packages

import 'package:dsh_app/ui/chat/render/mermaid_preview.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import 'support/fake_webview.dart';

final _url = Uri.parse('http://127.0.0.1:3080/?token=t');

late FakeWebViewPlatform _web;
late FakeIslandPlatform _islands;

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpPage(WidgetTester tester, {DshWebLink? link, Brightness brightness = Brightness.light}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      WebViewPage(url: _url, title: '网页版', dshWeb: true, link: link),
      brightness: brightness,
    ),
  );
  await _settle(tester);
}

void main() {
  late IslandPlatform realIslands;

  setUp(() {
    WebViewPlatform.instance = _web = FakeWebViewPlatform();
    realIslands = IslandPlatform.instance;
    IslandPlatform.instance = _islands = FakeIslandPlatform();
  });
  tearDown(() => IslandPlatform.instance = realIslands);

  testWidgets('the WebView is guarded once its client is set, before it loads, in the app\'s look', (tester) async {
    await _pumpPage(tester, brightness: Brightness.dark);
    final page = _web.controllers.single;
    expect(_islands.attached.single.id, page.webViewIdentifier);
    expect(_islands.attached.single.dark, isTrue);
    expect(_islands.attached.single.textZoom, 100);
    // The guard wraps the client the navigation delegate sets: after it.
    expect(page.calls.indexOf('setNavigationDelegate'), lessThan(page.calls.indexOf('loadRequest')));
    expect(page.loads, [_url]);
  });

  testWidgets('leaving the page destroys its WebView once it is out of the tree', (tester) async {
    await _pumpPage(tester);
    final page = _web.controllers.single;
    await tester.pumpWidget(const SizedBox());
    expect(_islands.destroyed, [page.webViewIdentifier]);
  });

  testWidgets('a dead renderer leaves one quiet line; 重新打开 is a new WebView', (tester) async {
    await _pumpPage(tester);
    final first = _web.controllers.single;
    first.finish();
    await tester.pump();
    expect(find.byKey(fakeWebViewKey), findsOneWidget);

    _islands.gone();
    await tester.pump();
    await tester.pump();
    expect(find.text('网页已关闭'), findsOneWidget);
    expect(find.text('重新打开'), findsOneWidget);
    // The dead WebView is out of the tree, then destroyed.
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(_islands.destroyed, [first.webViewIdentifier]);
    // The way back is still there.
    expect(find.byWidgetPredicate((w) => w is GlassIconButton && w.tooltip == '返回'), findsOneWidget);

    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    expect(_web.controllers, hasLength(2));
    final second = _web.controllers.last;
    expect(second.loads, [_url]);
    expect(_islands.attached.map((a) => a.id), [first.webViewIdentifier, second.webViewIdentifier]);
    expect(find.text('网页已关闭'), findsNothing);
    expect(find.byKey(fakeWebViewKey), findsOneWidget);
    // Nothing more is asked of the dead one.
    expect(first.loads, hasLength(1));
  });

  testWidgets('网页模式: the owner\'s link follows the new WebView', (tester) async {
    final link = DshWebLink();
    await _pumpPage(tester, link: link);
    _web.controllers.single.finish();
    _islands.gone();
    await tester.pump();
    await tester.pump();
    // Asked while the page is closed: it waits for the reopened page.
    await link.open(const DshWebTarget(sessionId: 's2'));
    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    final page = _web.controllers.last;
    page.finish();
    for (var i = 0; i < 40 && !page.scripts.any((s) => s.contains('"session":"s2"')); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(page.scripts.where((s) => s.contains('"session":"s2"')), isNotEmpty);
    expect(_web.controllers.first.scripts.where((s) => s.contains('"session":"s2"')), isEmpty);
  });

  testWidgets('an old main-frame error cannot cover the reopened page', (tester) async {
    await _pumpPage(tester);
    final first = _web.controllers.single;
    _islands.gone();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    final second = _web.controllers.last;
    second.finish();
    await _settle(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    first.fail();
    await tester.pump();
    expect(find.text('页面没有打开'), findsNothing);
    expect(find.byKey(fakeWebViewKey), findsOneWidget);

    // Failures of this page still reach its error UI and retry action.
    second.fail();
    await tester.pump();
    expect(find.text('页面没有打开'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(second.loads, [_url, _url]);
    expect(first.loads, [_url]);
    first.start();
    await tester.pump();
    expect(find.text('页面没有打开'), findsOneWidget);
    second.start();
    await tester.pump();
    expect(find.text('页面没有打开'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('an old finish cannot spend a queued target on the loading replacement', (tester) async {
    final link = DshWebLink();
    await _pumpPage(tester, link: link);
    final first = _web.controllers.single;
    _islands.gone();
    await tester.pump();
    await tester.pump();
    await link.open(const DshWebTarget(sessionId: 'pending-session'));
    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    final second = _web.controllers.last;

    first.finish();
    await _settle(tester);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(second.scripts, isEmpty);

    second.finish();
    for (var i = 0; i < 40 && !second.scripts.any((s) => s.contains('"session":"pending-session"')); i++) {
      await _settle(tester);
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(second.scripts.where((s) => s.contains('"session":"pending-session"')), hasLength(1));
    expect(first.scripts, isEmpty);
  });

  testWidgets('an old progress event cannot replace the new load progress', (tester) async {
    await _pumpPage(tester);
    final first = _web.controllers.single;
    _islands.gone();
    await tester.pump();
    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    final second = _web.controllers.last;
    second.delegate!.onProgress!(30);
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.3);

    first.delegate!.onProgress!(90);
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.3);
    second.delegate!.onProgress!(75);
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.75);
  });

  testWidgets('closed and disposed pages ignore their remaining navigation callbacks', (tester) async {
    await _pumpPage(tester);
    final page = _web.controllers.single;
    _islands.gone();
    await tester.pump();
    await tester.pump();

    page.start();
    page.delegate!.onProgress!(80);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    page.finish();
    page.fail();
    await _settle(tester);
    expect(page.scripts, isEmpty);
    expect(find.text('网页已关闭'), findsOneWidget);
    expect(find.text('重新打开'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    page.start();
    page.delegate!.onProgress!(90);
    page.finish();
    page.fail();
    await _settle(tester);
    expect(page.scripts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back on a closed page leaves it without asking the dead WebView', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WebViewPage(url: _url, title: '网页版', dshWeb: true),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    _web.controllers.single.finish();
    _islands.gone();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('a light / dark switch reaches the WebView', (tester) async {
    usePhoneView(tester);
    final mode = ValueNotifier(ThemeMode.light);
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (_, m, _) => testApp(
          WebViewPage(url: _url, title: '网页版', dshWeb: true),
          brightness: m == ThemeMode.dark ? Brightness.dark : Brightness.light,
        ),
      ),
    );
    await _settle(tester);
    expect(_islands.attached.single.dark, isFalse);
    mode.value = ThemeMode.dark;
    // Past the theme's cross-fade (the page keeps loading: no settling).
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(_islands.darkCalls.last, (_web.controllers.single.webViewIdentifier, true));
  });

  testWidgets('the chart preview survives too', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(testApp(const MermaidPreviewPage(source: 'graph LR; A-->B')));
    await _settle(tester);
    final first = _web.controllers.single;
    expect(_islands.attached.single.id, first.webViewIdentifier);
    expect(first.calls.indexOf('setNavigationDelegate'), lessThan(first.calls.indexOf('loadHtmlString')));
    _islands.gone();
    await tester.pump();
    await tester.pump();
    expect(find.text('图表已关闭'), findsOneWidget);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(_islands.destroyed, [first.webViewIdentifier]);
    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    expect(_web.controllers, hasLength(2));
    expect(_web.controllers.last.calls, contains('loadHtmlString'));
    expect(find.byKey(fakeWebViewKey), findsOneWidget);
  });
}
