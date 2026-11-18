// IslandView and IslandHost with a fake WebView: hidden until `ready`, the
// three forms (page / panel height / overlay hit regions), falling back,
// renderer loss, the memory budget, warm reuse and the background rule, and
// the bridge's link confirmation.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/plugins/seams/seat_models.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/islands/islands.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fakes.dart';

final _url = Uri.parse('http://127.0.0.1:3080/?token=t');

IslandSpec _spec(String slot, {String? cell, IslandForm form = IslandForm.page, String? session, String? package}) =>
    IslandSpec(host: HostRef.local, form: form, slot: slot, cell: cell, sessionId: session, package: package);

final _models = _spec('settings.section', cell: 'models');
final _schedules = _spec('main', cell: 'schedules');

late FakeWebViewPlatform _web;
late FakeIslandPlatform _platform;
late IslandHost _host;

Widget _fallback(BuildContext context) => const Text('在网页版打开');

Widget _app(Widget child, {Brightness brightness = Brightness.light}) => ProviderScope(
  overrides: [islandHostProvider.overrideWith((ref) => _host), islandHostUrlProvider.overrideWith((ref, host) => _url)],
  child: MaterialApp(
    theme: brightness == Brightness.light ? buildLightTheme() : buildDarkTheme(),
    home: Scaffold(body: child),
  ),
);

/// Lets the async acquire (recipes, controller setup, load) run.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

FakeWebViewController get _page => _web.controllers.last;

Future<void> _ready(WidgetTester tester, {FakeWebViewController? page}) async {
  final p = page ?? _page;
  await p.finish();
  await _settle(tester);
  p.post(jsonEncode({'t': 'ready', 'slot': 'x', 'release': '0.2.1-rc.2', 'found': 1}));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

double _webOpacity(WidgetTester tester) =>
    tester.widget<Opacity>(find.ancestor(of: find.byKey(fakeWebViewKey), matching: find.byType(Opacity)).first).opacity;

/// Every test ends by taking the islands down, so no grace timer outlives it.
void _testIsland(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox());
    _host.dispose();
    await tester.pump();
  });
}

void main() {
  setUp(() {
    _web = FakeWebViewPlatform();
    WebViewPlatform.instance = _web;
    _platform = FakeIslandPlatform();
    _host = IslandHost(platform: _platform, assets: TestIslandAssets());
  });

  // A platform view that isn't drawn has no window and no size on iOS.
  _testIsland('on iOS a WebView not ready yet is still drawn, then shown', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    final hidden = _webOpacity(tester);
    await _ready(tester);
    final shown = _webOpacity(tester);
    debugDefaultTargetPlatformOverride = null;
    expect(hidden, allOf(greaterThan(0), lessThan(0.02)));
    expect(shown, 1);
  });

  _testIsland('page: hidden behind a skeleton until ready, then shown', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    expect(find.byType(IslandSkeleton), findsOneWidget);
    expect(_page.loads.single, _url);
    expect(_page.background, const Color(0x00000000));
    expect(_webOpacity(tester), 0);

    await _page.finish();
    await _settle(tester);
    // The open bridge, the runtime, then init with the recipe's target.
    expect(_page.scripts.take(2), ['/* open bridge */', '/* island runtime */']);
    final init = _page.scripts[2];
    expect(init, contains('"slot":"settings.section"'));
    expect(init, contains('"target":{"web":{"settings":"models"}}'));
    expect(init, contains('"stretch":"scroller"'));
    expect(init, contains('"--dsw-alias-bg-base":"transparent"'));

    _page.post('{"t":"ready","slot":"settings.section","found":1}');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_webOpacity(tester), 1);
    expect(_host.live.single.phase, IslandPhase.ready);
  });

  _testIsland('a missing slot falls back and is remembered', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _page.finish();
    await _settle(tester);
    _page.post('{"t":"empty","slot":"settings.section","code":"slot-missing"}');
    await _settle(tester);
    expect(find.text('在网页版打开'), findsOneWidget);
    expect(_host.live, isEmpty);
    final budget = _host.snapshot(allowHost: (_) => true);
    expect(budget.canOpen(_models), isFalse, reason: 'the planner plans a web link next');
    expect(budget.canOpen(_schedules), isTrue);
  });

  _testIsland('no ready in time falls back; so does a failed load', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _page.finish();
    await tester.pump(IslandTiming.ready);
    await _settle(tester);
    expect(find.text('在网页版打开'), findsOneWidget);

    await tester.pumpWidget(_app(IslandView(key: const ValueKey(2), spec: _schedules, fallback: _fallback)));
    await _settle(tester);
    _page.fail();
    await _settle(tester);
    expect(find.text('在网页版打开'), findsOneWidget);
  });

  _testIsland(
    'a conversation view gets 12 s under the skeleton, then falls back; so does a view the page could not open',
    (tester) async {
      final view = _spec('conversation.view', cell: 'memory', session: 's1');
      await tester.pumpWidget(_app(IslandView(spec: view, labels: const ['记忆'], fallback: _fallback)));
      await _settle(tester);
      await _page.finish();
      await _settle(tester);
      expect(_page.scripts[2], contains('"then":{"view":{"id":"memory","names":["记忆"]}}'));
      await tester.pump(IslandTiming.viewReady - const Duration(milliseconds: 200));
      expect(find.text('在网页版打开'), findsNothing);
      expect(find.byType(IslandSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester);
      expect(find.text('在网页版打开'), findsOneWidget);

      // island.js found Chat in the slot but not the view: it says so.
      final other = _spec('conversation.view', cell: 'board', session: 's1');
      await tester.pumpWidget(
        _app(IslandView(key: const ValueKey(2), spec: other, labels: const ['看板'], fallback: _fallback)),
      );
      await _settle(tester);
      await _page.finish();
      await _settle(tester);
      _page.post('{"t":"empty","slot":"conversation.view","code":"empty","detail":"navigation"}');
      await _settle(tester);
      expect(find.text('在网页版打开'), findsOneWidget);
      expect(_host.live, isEmpty);
    },
  );

  _testIsland('a conversation view without a name to find it by never loads', (tester) async {
    final view = _spec('conversation.view', cell: 'memory', session: 's1');
    await tester.pumpWidget(_app(IslandView(spec: view, fallback: _fallback)));
    await _settle(tester);
    expect(find.text('在网页版打开'), findsOneWidget);
    expect(_web.controllers, isEmpty);
  });

  _testIsland('the chat sheet\'s island masks all seven slots, shows them together, gets 8 s', (tester) async {
    const sheet = IslandSpec(
      host: HostRef.local,
      form: IslandForm.panel,
      slot: 'dsh-go.chat',
      sessionId: 's1',
      maskOfficial: true,
    );
    await tester.pumpWidget(_app(IslandView(spec: sheet, fallback: _fallback)));
    await _settle(tester);
    expect(
      _page.loads.single.fragment,
      'dsh-go-island=conversation.session.header.actions,conversation.session.header.utilities,'
      'conversation.input.dock,conversation.input.left,conversation.input.right,conversation.input.overlay,'
      'conversation.composer.dock',
    );
    await _page.finish();
    await _settle(tester);
    final init = _page.scripts[2];
    expect(init, contains('"slots":["conversation.session.header.actions",'));
    expect(init, contains('"stretch":"common"'));
    expect(init, contains('"mask":true'));
    await tester.pump(IslandTiming.sheetReady - const Duration(milliseconds: 200));
    expect(find.text('在网页版打开'), findsNothing);
    expect(find.byType(IslandSkeleton), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    expect(find.text('在网页版打开'), findsOneWidget);
  });

  _testIsland('a timeout is tried again 30 s later; a missing slot is not', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _page.finish();
    await tester.pump(IslandTiming.ready);
    await _settle(tester);
    expect(_host.snapshot(allowHost: (_) => true).canOpen(_models), isFalse);
    var notified = 0;
    _host.addListener(() => notified++);
    await tester.pump(IslandBudgetRules.transientFailureMemory);
    expect(_host.snapshot(allowHost: (_) => true).canOpen(_models), isTrue);
    expect(notified, greaterThan(0), reason: 'the planner re-plans');

    await tester.pumpWidget(_app(IslandView(key: const ValueKey(2), spec: _schedules, fallback: _fallback)));
    await _settle(tester);
    await _page.finish();
    await _settle(tester);
    _page.post('{"t":"empty","slot":"main","code":"slot-missing"}');
    await _settle(tester);
    await tester.pump(IslandBudgetRules.transientFailureMemory);
    expect(_host.snapshot(allowHost: (_) => true).canOpen(_schedules), isFalse);
  });

  _testIsland('no recipe or no way there: straight to the fallback', (tester) async {
    await tester.pumpWidget(
      _app(
        IslandView(
          spec: _spec('conversation.chat.turnTail', session: 's'),
          fallback: _fallback,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('在网页版打开'), findsOneWidget);
    expect(_web.controllers, isEmpty);
  });

  _testIsland('panel: as tall as its content, within the panel range', (tester) async {
    final spec = _spec('conversation.input.dock', form: IslandForm.panel, session: 's1');
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.bottomCenter,
          child: IslandView(spec: spec, fallback: _fallback),
        ),
      ),
    );
    await _settle(tester);
    expect(_page.scripts, isEmpty);
    await _ready(tester);
    double height() => tester.getSize(find.byType(IslandView)).height;
    for (final (reported, shown) in [
      (200.0, 200.0),
      (900.0, IslandPanelMetrics.maxHeight),
      (10.0, IslandPanelMetrics.minHeight),
    ]) {
      _page.post('{"t":"size","h":$reported}');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(height(), shown);
    }
    expect(_page.scripts[2], contains('"target":{"session":"s1"}'));
    expect(_page.scripts[2], contains('"mode":"panel"'));
  });

  _testIsland('overlay: touches outside the reported regions reach the app underneath', (tester) async {
    var taps = 0;
    final spec = _spec('shell.overlay', form: IslandForm.overlay);
    await tester.pumpWidget(
      _app(
        Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++),
            IslandView(spec: spec, fallback: _fallback),
          ],
        ),
      ),
    );
    await _settle(tester);
    await tester.tapAt(const Offset(40, 40));
    expect(taps, 1, reason: 'not ready: nothing is taken');
    await _ready(tester);
    _page.post('{"t":"hit","rects":[[0,0,100,100]],"dpr":2}');
    await tester.pump();
    await tester.tapAt(const Offset(40, 40));
    expect(taps, 1, reason: 'inside a region: the island takes it');
    await tester.tapAt(const Offset(300, 400));
    expect(taps, 2, reason: 'elsewhere: falls through');
  });

  _testIsland('a dead renderer closes every island until reopened', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    _platform.emit(const IslandRendererGone(webViewId: 1, crashed: false));
    await _settle(tester);
    expect(find.text('插件界面已关闭'), findsOneWidget);
    expect(_host.live, isEmpty);
    expect(_host.snapshot(allowHost: (_) => true).canOpen(_models), isFalse);

    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    expect(_web.controllers, hasLength(2), reason: 'a fresh island');
    expect(_host.rendererLost, isFalse);
  });

  _testIsland('budget: one island on a small phone; the one on screen wins', (tester) async {
    _platform.deviceInfo = const IslandDevice(totalMem: 3 << 30);
    _host = IslandHost(platform: _platform, assets: TestIslandAssets());
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            Expanded(
              child: IslandView(spec: _models, fallback: _fallback),
            ),
            Expanded(
              child: IslandView(spec: _schedules, fallback: _fallback),
            ),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(_host.max, 1);
    expect(_web.controllers, hasLength(1));
    expect(find.text('在网页版打开'), findsOneWidget);
  });

  _testIsland('budget: an island under another page gives way to the one on top', (tester) async {
    _platform.deviceInfo = const IslandDevice(totalMem: 3 << 30);
    _host = IslandHost(platform: _platform, assets: TestIslandAssets());
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          islandHostProvider.overrideWith((ref) => _host),
          islandHostUrlProvider.overrideWith((ref, host) => _url),
        ],
        child: MaterialApp(
          navigatorKey: nav,
          theme: buildLightTheme(),
          home: Scaffold(
            body: IslandView(spec: _models, fallback: _fallback),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _ready(tester);
    final first = _host.live.single;
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: IslandView(spec: _schedules, fallback: _fallback),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await _settle(tester);
    expect(_host.live.single.spec, _schedules);
    expect(first.phase, IslandPhase.closed);

    // Back: the first page's island comes back cold (it was evicted), as
    // soon as the page on top is gone and its island off screen.
    nav.currentState!.pop();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await _settle(tester);
    await _settle(tester);
    expect(_web.controllers, hasLength(3));
    expect(_host.live.map((h) => h.spec), [_models]);
  });

  _testIsland('overlay is destroyed on removal without the page warm grace', (tester) async {
    final spec = _spec('shell.overlay', form: IslandForm.overlay, package: 'pet-plugin', cell: 'pet');
    await tester.pumpWidget(_app(IslandView(spec: spec, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    final handle = _host.live.single;
    expect(_page.scripts[2], contains('"package":"pet-plugin"'));
    expect(_page.scripts[2], contains('"cell":"pet"'));
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump(const Duration(milliseconds: 10));
    expect(_host.live, isEmpty);
    expect(handle.phase, IslandPhase.closed);
  });

  _testIsland('warm for 30 s after leaving, then destroyed', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    final handle = _host.live.single;
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump(const Duration(seconds: 10));
    // Back within the grace period: the same WebView, no reload.
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    expect(_web.controllers, hasLength(1));
    expect(_host.live.single, same(handle));
    expect(_webOpacity(tester), 1);

    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump(IslandBudgetRules.hiddenGrace + const Duration(seconds: 1));
    expect(_host.live, isEmpty);
    expect(handle.phase, IslandPhase.closed);
  });

  _testIsland('background: islands go after a minute away', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 30));
    expect(_host.live, hasLength(1), reason: 'a quick look elsewhere keeps it');
    await tester.pump(IslandBudgetRules.backgroundGrace);
    expect(_host.live, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(_web.controllers, hasLength(2), reason: 'reopened cold on return');
  });

  _testIsland('memory pressure drops islands that are off screen', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    _platform.emit(const IslandTrimMemory(10));
    await _settle(tester);
    expect(_host.live, hasLength(1), reason: 'on screen');
    await tester.pumpWidget(_app(const SizedBox()));
    _platform.emit(const IslandTrimMemory(15));
    await _settle(tester);
    expect(_host.live, isEmpty);
  });

  _testIsland('links ask first, with the domain; other origins never load inside', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    _page.post('{"t":"link","url":"https://github.com/deepseek-ai"}');
    await tester.pumpAndSettle();
    expect(find.text('在浏览器打开 github.com？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await _page.navigate('http://127.0.0.1:3080/'), NavigationDecision.navigate);
    expect(await _page.navigate('http://evil.example/'), NavigationDecision.prevent);
    await tester.pump(const Duration(seconds: 2));
    expect(await _page.navigate('https://example.org/x'), NavigationDecision.prevent);
    await tester.pumpAndSettle();
    expect(find.text('在浏览器打开 example.org？'), findsOneWidget);
  });

  _testIsland('the App theme reaches the page without a reload', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _ready(tester);
    final before = _page.scripts.length;
    await tester.pumpWidget(
      _app(
        IslandView(spec: _models, fallback: _fallback),
        brightness: Brightness.dark,
      ),
    );
    // The theme cross-fades; the page gets its last frame only.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(IslandTiming.themeSettle);
    final themed = _page.scripts.skip(before).where((s) => s.contains('setTheme')).toList();
    expect(themed, hasLength(1));
    expect(themed.single, contains('"dark":true'));
    expect(_page.loads, hasLength(1));
  });

  _testIsland('a list slot with official entries masked loads in island mode', (tester) async {
    const spec = IslandSpec(
      host: HostRef.local,
      form: IslandForm.panel,
      slot: 'conversation.input.dock',
      sessionId: 's1',
      maskOfficial: true,
    );
    await tester.pumpWidget(_app(IslandView(spec: spec, fallback: _fallback)));
    await _settle(tester);
    expect(_page.loads.single.fragment, 'dsh-go-island=conversation.input.dock');
  });

  _testIsland('what a document the page already left says is dropped', (tester) async {
    await tester.pumpWidget(_app(IslandView(spec: _models, fallback: _fallback)));
    await _settle(tester);
    await _page.finish(); // injection 1
    await _settle(tester);
    await _page.finish(); // the page reported finished again: injection 2
    await _settle(tester);
    expect(_page.scripts.where((s) => s.contains('"load":2')), hasLength(1));
    _page.post('{"t":"empty","slot":"settings.section","code":"slot-missing","load":1}');
    await _settle(tester);
    expect(_host.live.single.phase, IslandPhase.loading, reason: 'stale');
    _page.post('{"t":"ready","slot":"settings.section","found":1,"load":2}');
    await _settle(tester);
    expect(_host.live.single.phase, IslandPhase.ready);
  });

  _testIsland('a third-party right-pane tab loads with the bridge told to open it', (tester) async {
    const spec = IslandSpec(
      host: HostRef.local,
      form: IslandForm.page,
      slot: 'sidebar.right.pane.tab',
      cell: 'k4-tab',
      sessionId: 's1',
      maskOfficial: true,
    );
    await tester.pumpWidget(_app(IslandView(spec: spec, fallback: _fallback)));
    await _settle(tester);
    expect(_page.loads.single.fragment, 'dsh-go-tab=k4-tab', reason: 'never island mode for this slot');
  });
}
