// Where an open lands in DSH Web: the names a plugin card target carries
// (web_target.dart), and that the landing waits out a load that failed
// (web_view_page.dart): the WebView finishes its own error page too, and the
// one landing an open gets was spent there, so 重试 came back on the home page.

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import 'support/fake_webview.dart';

PluginBundle _bundle(String name, Map<String, String> title, List<String> rows) => PluginBundle.fromJson({
  'name': name,
  'meta': {'title': title},
  'enabled': true,
  'installed': true,
  'source': 'npm',
  'rows': [
    for (final id in rows) {'rowId': id, 'moduleName': name},
  ],
});

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('new conversation binding option $platform', () {
      debugDefaultTargetPlatformOverride = platform;
      try {
        const target = DshWebTarget(newSession: true);
        final script = target.openScript;
        final wire = jsonDecode(script.substring(script.indexOf('({') + 1, script.length - 2)) as Map;
        expect(wire.containsKey('confirmNewSession'), platform == TargetPlatform.iOS);
        if (platform == TargetPlatform.iOS) expect(wire['confirmNewSession'], isTrue);
        expect(target.toJson(), {'newSession': true});
        expect(const DshWebTarget(settings: DshWebSettings.general).openScript, isNot(contains('confirmNewSession')));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
  group('a plugin card target', () {
    test('names are trimmed, none empty, each once; only empty names open nothing', () {
      const target = DshWebTarget(pluginItem: [' 天气 ', '', '天气', 'Weather  app', '  ']);
      expect(target.toJson()['pluginItem'], ['天气', 'Weather app']);
      expect(const DshWebTarget(pluginItem: ['', ' ']).isHome, isTrue);
      expect(const DshWebTarget(pluginItem: ['', ' ']).toJson(), isEmpty);
    });

    test('an entry id names its bundle: titles and package, after what was asked', () {
      final bundles = [
        _bundle('@acme/dsh-weather', {'zh': '天气', 'en': 'Weather'}, ['weather', 'weather-alerts']),
        _bundle('@acme/dsh-clock', {'zh': '时钟', 'en': 'Clock'}, ['clock']),
      ];
      final target = const DshWebTarget(pluginItem: ['weather-alerts']).withPluginNames(bundles);
      expect(target.pluginItem, ['weather-alerts', '天气', 'Weather', '@acme/dsh-weather']);
      // The open script carries them.
      final script = target.openScript;
      final json = jsonDecode(script.substring(script.indexOf('(', script.indexOf('__dshAppOpen(')) + 1, script.length - 2));
      expect((json as Map)['pluginItem'], target.pluginItem);
    });

    test('names a card already has, or nothing installed knows, stay as they are', () {
      final bundles = [
        _bundle('@acme/dsh-weather', {'zh': '天气'}, ['weather']),
      ];
      const titled = DshWebTarget(pluginItem: ['天气', '@acme/dsh-weather']);
      expect(identical(titled.withPluginNames(bundles), titled), isTrue);
      const unknown = DshWebTarget(pluginItem: ['agent-loop']);
      expect(identical(unknown.withPluginNames(bundles), unknown), isTrue);
      expect(identical(unknown.withPluginNames(null), unknown), isTrue);
      // The session and the rest of the destination are kept.
      final inSession = const DshWebTarget(sessionId: 's1', pluginItem: ['weather']).withPluginNames(bundles);
      expect(inSession.sessionId, 's1');
    });
  });

  group('landing after a failed load', () {
    late FakeWebViewPlatform platform;
    setUp(() => WebViewPlatform.instance = platform = FakeWebViewPlatform());

    Iterable<String> opens() =>
        platform.controller.scripts.where((s) => s.startsWith('window.__dshAppOpen && window.__dshAppOpen('));

    /// Lets the bridges load from the asset bundle (real time), then frames.
    Future<void> injected(WidgetTester tester, int backBridges) async {
      for (var i = 0; i < 40 && platform.controller.scripts.where((s) => s.contains('__dshAppBack =')).length < backBridges; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    testWidgets('the target waits for the load that works, and lands once', (tester) async {
      await tester.pumpWidget(
        testApp(
          WebViewPage(
            url: Uri.parse('http://127.0.0.1:3080/?token=t'),
            title: '网页版',
            dshWeb: true,
            openTarget: const DshWebTarget(pluginItem: ['天气', '@acme/dsh-weather']),
          ),
        ),
      );
      for (var i = 0; i < 20 && platform.controller.loads.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      // The engine isn't answering yet: Android finishes its error page too.
      platform.controller
        ..start()
        ..fail()
        ..finish();
      await injected(tester, 1);
      expect(find.text('页面没有打开'), findsOneWidget);
      expect(opens(), isEmpty, reason: 'not spent on the error page');
      expect(platform.controller.scripts.where((s) => s.contains('window.__dshAppOpen = function')), isEmpty);

      await tester.tap(find.text('重试'));
      await tester.pump();
      platform.controller
        ..start()
        ..finish();
      await injected(tester, 2);
      expect(find.text('页面没有打开'), findsNothing);
      expect(opens(), hasLength(1));
      expect(opens().single, contains('"pluginItem":["天气","@acme/dsh-weather"]'));

      // A later load (a conversation hop) is the bridge's to finish.
      platform.controller
        ..start()
        ..finish();
      await injected(tester, 3);
      expect(opens(), hasLength(1));
    });
  });
}
