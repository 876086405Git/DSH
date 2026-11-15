// `dshgo://open/<page>`: only pages from the fixed list open, pushed over the
// home route; anything else gets the router's toast and nothing else happens,
// and a page HarmonyOS doesn't have yet says that.

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui/settings/index/spot_anchor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pageLinkId', () {
    test('accepts exactly dshgo://open/<known page>', () {
      expect(pageLinkId(Uri.parse('dshgo://open/engine')), 'engine');
      expect(pageLinkId(Uri.parse('dshgo://open/engine/')), 'engine');
      expect(pageLinkId(Uri.parse('DSHGO://OPEN/phone')), 'phone');
      expect(pageLinkId(Uri.parse('dshgo://open/appearance')), 'appearance');
    });

    test('rejects other schemes, extra parts and unknown pages', () {
      for (final link in [
        'https://open/engine',
        'dshgo://share/engine',
        'dshgo://open',
        'dshgo://open/',
        'dshgo://open/engine/logs',
        'dshgo://open/engine?x=1',
        'dshgo://open/engine#top',
        'dshgo://me@open/engine',
        'dshgo://open:8080/engine',
        'dshgo://open/Engine',
        'dshgo://open/nope',
        // 全部功能 entries that are actions, web pages or need a conversation.
        'dshgo://open/search',
        'dshgo://open/share-profile',
        'dshgo://open/cot-translation',
        'dshgo://open/reference',
        'dshgo://open/voice-input',
        'dshgo://open/web',
        'dshgo://open/files',
        'dshgo://open/session-detail',
        'dshgo://open/plugin-panel:pkg%23main',
      ]) {
        expect(pageLinkId(Uri.parse(link)), isNull, reason: link);
      }
    });
  });

  test('every link id resolves: settings through the index, the rest through 全部功能', () {
    final items = {
      for (final s in featureSections)
        for (final i in s.items) i.id: i,
    };
    for (final id in catalogPageLinks) {
      final item = items[id];
      expect(item, isNotNull, reason: '$id is not in 全部功能');
      expect(item!.native, isNotNull, reason: '$id is not a page');
      expect(item.action, isNull, reason: id);
      expect(item.needsSession, isFalse, reason: id);
    }
    expect(SettingsIndex.linkIds.intersection(catalogPageLinks), isEmpty);
    for (final id in pageLinkIds) {
      expect(pageForId(id, null), isNotNull, reason: id);
    }
    expect(pageForId('search', null), isNull);
  });

  test('every id the guide or a reply may already use still opens', () {
    // The ids before the settings index (0.9.6): none may stop working.
    const before = {
      'schedules', 'permission', 'agent-presets', 'models', 'subagent-settings', 'agent-loop', //
      'shell-settings', 'web-search', 'plugins', 'plugin-inventory', 'cordis', 'agent-team', 'forum', //
      'community', 'ds-bot', 'notifications', 'workspaces', 'general', 'account', 'remote', 'phone', //
      'engine', 'diagnostics', 'settings', 'appearance', 'pets', 'shared-links', 'engine-settings', //
      'all-features', 'background',
    };
    expect(pageLinkIds, containsAll(before));
  });

  test('a row link opens the page the row is on, at the row', () {
    for (final spot in SettingsIndex.rows.where((s) => s.link != null)) {
      final page = pageForId(spot.link!, null);
      expect(page, isA<SpotFocus>(), reason: spot.link);
      page as SpotFocus;
      expect(page.target, spot.id);
      expect(page.child.runtimeType, settingsPage(spot.page).runtimeType, reason: spot.link);
    }
    expect((pageForId('phone-confirm', null)! as SpotFocus).child, isA<PhoneControlScreen>());
  });

  group('routing', () {
    late AppLinks links;
    late LinkRouter router;
    late List<(String, String?)> opened;

    setUp(() {
      links = AppLinks();
      router = LinkRouter(links.links, grace: Duration.zero);
      opened = [];
    });
    tearDown(() {
      router.dispose();
      links.dispose();
    });

    // The real LinkHost wiring, with light pages and a fixed open conversation.
    Future<void> pumpHome(WidgetTester tester, {String? session = 's1'}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            linkRouterProvider.overrideWithValue(router),
            currentSessionProvider.overrideWithBuild((ref, _) => session),
            pageLinkResolverProvider.overrideWithValue((id, sessionId) {
              opened.add((id, sessionId));
              return Scaffold(body: Text('page $id'));
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  const LinkHost(),
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => openReplyPageLink(context, 'dshgo://open/phone'),
                      child: const Text('reply link'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a known page opens over the home route with the open conversation', (tester) async {
      await pumpHome(tester);
      expect(await router.open(Uri.parse('dshgo://open/engine')), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('page engine'), findsOneWidget);
      expect(opened, [('engine', 's1')]);
    });

    testWidgets('an unknown page shows one line and opens nothing', (tester) async {
      await pumpHome(tester);
      expect(await router.open(Uri.parse('dshgo://open/nope')), isFalse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('无法打开这个链接'), findsOneWidget);
      expect(opened, isEmpty);
    });

    group('on HarmonyOS', () {
      final zh = lookupL10n(AppLocale.zhCN);

      Future<void> pumpHarmony(WidgetTester tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              linkRouterProvider.overrideWithValue(router),
              currentSessionProvider.overrideWithBuild((ref, _) => null),
              operatingSystemProvider.overrideWithValue('ohos'),
            ],
            child: const MaterialApp(home: Scaffold(body: LinkHost())),
          ),
        );
        await tester.pump();
      }

      testWidgets('a page only Android has says it isn\'t available here', (tester) async {
        await pumpHarmony(tester);
        expect(await router.open(Uri.parse('dshgo://open/phone')), isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text(zh.harmonyPageUnavailable), findsOneWidget);
        expect(find.byType(PhoneControlScreen), findsNothing);
      });

      testWidgets('a page nobody has is still the router\'s to say', (tester) async {
        await pumpHarmony(tester);
        expect(await router.open(Uri.parse('dshgo://open/nope')), isFalse);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('无法打开这个链接'), findsOneWidget);
        expect(find.text(zh.harmonyPageUnavailable), findsNothing);
      });
    });

    testWidgets('a link that arrives from outside opens the page too', (tester) async {
      await pumpHome(tester, session: null);
      links.add(Uri.parse('dshgo://open/models'));
      await tester.pumpAndSettle();
      expect(find.text('page models'), findsOneWidget);
      expect(opened, [('models', null)]);
    });

    testWidgets('a reply link goes through the router; other links are left alone', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('reply link'));
      await tester.pumpAndSettle();
      expect(find.text('page phone'), findsOneWidget);

      final context = tester.element(find.byType(LinkHost, skipOffstage: false));
      expect(openReplyPageLink(context, 'https://example.com'), isFalse);
      expect(openReplyPageLink(context, 'dshgo://share/abc'), isFalse);
      expect(openReplyPageLink(context, 'not a link'), isFalse);
      expect(opened, [('phone', 's1')]);
    });
  });
}
