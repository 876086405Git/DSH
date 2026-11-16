// The chat page's 「插件」 sheet (docs/design/plugin-ui-v3.md §3.4): the
// entry is the last capsule above the composer (outside the eight), there
// only while the conversation has native chat.panel panels or web plugins'
// chat-page parts. Native panels come first, by plugin name; the web parts
// are one panel island under a line naming whose they are. Every way the
// island can't come up — the route guard off, no room, a part ui.json sends
// to the web, no ready within 8 s, the page giving up — is one 「在网页版打开」
// row, never an error. Geometry measured; goldens light and dark.
// Regenerate with
// `flutter test --update-goldens test/plugins/native/chat_plugins_sheet_test.dart`.

import 'dart:io';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/islands/islands.dart';
import 'package:dsh_app/ui/plugins/native/chat_plugins_sheet.dart';
import 'package:dsh_app/ui/plugins/native/composer_capsules.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_app/ui/plugins/seats/seat_links.dart' show seatWebOpenerProvider;
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/glass.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import '../seats/support.dart' as seats;
import 'support.dart';

/// The usage plugin with its panel on the chat page, and a notes plugin
/// whose panel is for 对话详情 only.
FakeBridge _bridge({bool panels = true, int capsules = 0}) {
  final bridge = FakeBridge(
    contributions([
      plugin(
        'dsh-go-example-usage',
        title: '用量',
        icon: 'chart',
        panels: [
          if (panels)
            {
              'id': 'usage',
              'title': '用量',
              'icon': 'chart',
              'placement': ['chat.panel'],
            },
        ],
      ),
      plugin(
        'dsh-go-example-album',
        title: '相册',
        icon: 'gallery',
        panels: [
          if (panels)
            {
              'id': 'album',
              'title': '相册',
              'icon': 'gallery',
              'placement': ['chat.panel', 'features'],
            },
          {
            'id': 'notes',
            'title': '笔记',
            'placement': ['session.tab'],
          },
        ],
      ),
      for (var i = 0; i < capsules; i++)
        plugin(
          'cap$i',
          composer: [
            {'id': 'a', 'label': '按钮$i'},
          ],
        ),
    ]),
  );
  for (final (pkg, id, label, value) in [
    ('dsh-go-example-usage', 'usage', '本对话', '¥0.42'),
    ('dsh-go-example-album', 'album', '今日', '12 张'),
  ]) {
    bridge.views['$pkg/$id'] = DshGoView(
      pkg: pkg,
      id: id,
      title: label,
      view: {'type': 'metric', 'label': label, 'value': value},
      data: const {},
      rev: 'r1',
    );
  }
  return bridge;
}

/// The probe's button beside the composer and the pet's bell in the header.
final _web = <String, List<SlotOccupant>>{
  Slots.inputLeft: [seats.occupant(Slots.inputLeft, seats.probe, 'k4-button')],
  Slots.headerActions: [seats.occupant(Slots.headerActions, seats.pet, 'pet-bell')],
};

/// Islands for everything but the sheet's one island.
class _NoSheetRoom implements IslandBudget {
  const _NoSheetRoom();

  @override
  bool canOpen(IslandSpec spec) => spec.slot != Slots.chatSheet;
}

List<Override> _overrides(
  FakeBridge bridge, {
  Map<String, List<SlotOccupant>> web = const {},
  bool routeGuard = true,
  IslandBudget budget = const OpenIslandBudget(),
  SeatRenderers? renderers,
  SeatOverrides seatOverrides = SeatOverrides.none,
}) => [
  ...nativeOverrides(bridge, bundles: [seats.probeBundle, seats.petBundle]),
  seatInventoryProvider.overrideWith((ref) => seats.seatInventory(occupancy: web, routeGuard: routeGuard)),
  islandBudgetProvider.overrideWithValue(budget),
  seatRenderersProvider.overrideWithValue(renderers ?? seats.testRenderers()),
  seatWebOpenerProvider.overrideWithValue((context, ref, target) => seats.openedWeb.add(target)),
  seatOverridesProvider.overrideWithValue(seatOverrides),
];

ProviderContainer _container(List<Override> overrides) {
  final c = ProviderContainer(overrides: overrides);
  addTearDown(c.dispose);
  return c;
}

/// The capsule bar over a stand-in composer, at the bottom of a phone.
Widget _bar(List<Override> overrides, {bool visible = true, String? sessionId = 's1'}) {
  final host = FakeComposer(sessionId: sessionId);
  return testApp(
    Scaffold(
      body: withComposer(
        host,
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NativeComposerBar(sessionId: sessionId, visible: visible),
                const SizedBox(height: 56),
              ],
            ),
          ),
        ),
      ),
    ),
    overrides: overrides,
  );
}

List<String> _capsules(WidgetTester tester) => [
  for (final c in tester.widgetList<ComposerCapsule>(find.byType(ComposerCapsule))) c.item.label,
];

Future<void> _openSheet(WidgetTester tester, List<Override> overrides) async {
  usePhoneView(tester);
  await tester.pumpWidget(_bar(overrides));
  await pumpFrames(tester);
  await tester.tap(find.widgetWithText(ComposerCapsule, '插件'));
  await pumpFrames(tester, 12);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    seats.openedWeb.clear();
  });

  group('content', () {
    test('nothing on the chat page: no entry', () async {
      final c = _container(_overrides(_bridge(panels: false)));
      expect(c.read(chatPluginsHaveContentProvider('s1')), isFalse);
      expect(c.read(chatWebPluginsProvider('s1')).isEmpty, isTrue);
    });

    test('the web parts: one panel island for all seven slots, official entries masked', () {
      final web = _container(_overrides(_bridge(panels: false), web: _web)).read(chatWebPluginsProvider('s1'));
      expect(web.packages, [seats.pet, seats.probe], reason: 'the header\'s first, as on the page');
      final spec = web.island!;
      expect(spec.slot, Slots.chatSheet);
      expect(spec.form, IslandForm.panel);
      expect(spec.sessionId, 's1');
      expect(spec.maskOfficial, isTrue);
    });

    test('no route guard on this phone\'s engine: 在网页版打开', () {
      final web = _container(_overrides(_bridge(panels: false), web: _web, routeGuard: false))
          .read(chatWebPluginsProvider('s1'));
      expect(web.isEmpty, isFalse);
      expect(web.island, isNull);
    });

    test('no room for the sheet\'s island: 在网页版打开', () {
      final web = _container(_overrides(_bridge(panels: false), web: _web, budget: const _NoSheetRoom()))
          .read(chatWebPluginsProvider('s1'));
      expect(web.island, isNull);
    });

    test('a part ui.json sends to the web or hides: no island (it would show there all the same)', () {
      for (final override in [SeatOverride.web, SeatOverride.hidden]) {
        final web = _container(
          _overrides(
            _bridge(panels: false),
            web: _web,
            seatOverrides: SeatOverrides({
              Slots.inputLeft: {seats.probe: override},
            }),
          ),
        ).read(chatWebPluginsProvider('s1'));
        expect(web.island, isNull, reason: override.name);
      }
    });
  });

  group('recipe', () {
    final book = IslandRecipeBook.parse(File('assets/islands/recipes.json').readAsStringSync());

    test('the sheet\'s island: the seven slots together, in the conversation, 8 s to show', () {
      final recipe = book.recipeFor(Slots.chatSheet)!;
      expect(recipe.slots, chatSheetSlots, reason: 'page order');
      expect(recipe.slots, unorderedEquals(Slots.chatPanel));
      expect(recipe.forms, {IslandForm.panel});
      expect(recipe.stretch, IslandStretch.common);
      expect(recipe.ready, IslandTiming.sheetReady);
      expect(IslandTiming.sheetReady, const Duration(seconds: 8));
      const spec = IslandSpec(host: HostRef.local, form: IslandForm.panel, slot: Slots.chatSheet, sessionId: 's1');
      expect(book.targetFor(spec), {'session': 's1'});
      expect(
        book.targetFor(const IslandSpec(host: HostRef.local, form: IslandForm.panel, slot: Slots.chatSheet)),
        isNull,
      );
    });
  });

  group('entry', () {
    for (final nativePanels in [false, true]) {
      testWidgets('hide.pluginCapsule hides only the built-in entry and can be restored: native=$nativePanels', (
        tester,
      ) async {
        usePhoneView(tester);
        var hidden = false;
        await tester.pumpWidget(
          _bar([
            ..._overrides(_bridge(panels: nativePanels, capsules: 1), web: _web),
            uiHiddenProvider(UiHideItem.pluginCapsule).overrideWith((ref) => hidden),
          ]),
        );
        await pumpFrames(tester);
        expect(_capsules(tester), ['按钮0', '插件']);
        final c = ProviderScope.containerOf(tester.element(find.byType(NativeComposerBar)));
        hidden = true;
        c.invalidate(uiHiddenProvider(UiHideItem.pluginCapsule));
        await pumpFrames(tester, 12);
        expect(_capsules(tester), ['按钮0']);
        expect(
          c.read(chatPluginsHaveContentProvider('s1')),
          isTrue,
          reason: 'hiding an entry does not disable plugins',
        );
        expect(c.read(chatWebPluginsProvider('s1')).packages, isNotEmpty);
        hidden = false;
        c.invalidate(uiHiddenProvider(UiHideItem.pluginCapsule));
        await pumpFrames(tester);
        expect(_capsules(tester), ['按钮0', '插件']);
      });
    }

    testWidgets('the last capsule, outside the eight; not without content; away while a reply generates', (
      tester,
    ) async {
      usePhoneView(tester);
      await tester.pumpWidget(_bar(_overrides(_bridge(capsules: 9))));
      await pumpFrames(tester);
      // Native chat.panel panels by plugin name (用量 before 相册); the
      // 对话详情-only one is not here.
      final container = ProviderScope.containerOf(tester.element(find.byType(NativeComposerBar)));
      expect(container.read(chatNativePanelsProvider).map((p) => p.id), ['usage', 'album']);
      final labels = _capsules(tester);
      expect(labels, hasLength(9));
      expect(labels.last, '插件');
      expect(labels.where((l) => l.startsWith('按钮')), hasLength(8));

      await tester.pumpWidget(_bar(_overrides(_bridge(panels: false, capsules: 1))));
      await pumpFrames(tester);
      expect(_capsules(tester), ['按钮0']);

      await tester.pumpWidget(_bar(_overrides(_bridge()), sessionId: null));
      await pumpFrames(tester);
      expect(_capsules(tester), isEmpty, reason: 'a new chat has no conversation yet');

      await tester.pumpWidget(_bar(_overrides(_bridge()), visible: false));
      await pumpFrames(tester);
      expect(tester.getSize(find.byType(NativeComposerBar)).height, 0);
    });

    testWidgets('web parts alone bring the entry too', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(_bar(_overrides(_bridge(panels: false), web: _web)));
      await pumpFrames(tester);
      expect(_capsules(tester), ['插件']);
    });
  });

  group('the side panel\'s pane', () {
    Finder otherPages() => find.widgetWithText(ListPageRow, '插件');

    Future<void> pane(WidgetTester tester, Map<String, List<SlotOccupant>> web, {VoidCallback? onOtherPages}) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ChatWebPluginsPane(sessionId: 's1', onOtherPages: onOtherPages ?? () {}),
          ),
          overrides: _overrides(_bridge(panels: false), web: web),
        ),
      );
      await pumpFrames(tester);
    }

    testWidgets('no pages, no way on', (tester) async {
      await pane(tester, _web);
      expect(otherPages(), findsNothing);
    });

    testWidgets('global pages have a way on, even of a plugin with parts here', (tester) async {
      await pane(tester, {
        ..._web,
        Slots.main: [seats.occupant(Slots.main, seats.probe, 'k4-panel')],
      });
      expect(otherPages(), findsOneWidget);
      // Same width as the card above it, one card gap below (#1389).
      Rect glass(String key) =>
          tester.getRect(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(GlassSurface)).first);
      final above = glass('chat-plugins-ways-in');
      final card = glass('chat-plugins-other-pages');
      expect(card.left, moreOrLessEquals(above.left, epsilon: 0.5));
      expect(card.right, moreOrLessEquals(above.right, epsilon: 0.5));
      expect(card.top - above.bottom, moreOrLessEquals(ChatPluginsMetrics.gap, epsilon: 0.5));
    });

    testWidgets('global pages keep a way on beside a conversation view from the same web plugin', (tester) async {
      var opened = false;
      await pane(tester, {
        ..._web,
        Slots.main: [seats.occupant(Slots.main, seats.probe, 'k4-panel')],
        Slots.conversationView: [seats.occupant(Slots.conversationView, seats.probe, 'memory', label: '记忆')],
      }, onOtherPages: () => opened = true);
      expect(find.text('记忆'), findsOneWidget);
      expect(otherPages(), findsOneWidget);
      await tester.tap(otherPages());
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a conversation page of a plugin with parts is its own row, not the way on', (tester) async {
      await pane(tester, {
        ..._web,
        Slots.rightPaneTab: [seats.occupant(Slots.rightPaneTab, seats.probe, 'k4-tab')],
      });
      expect(find.byKey(ValueKey('chat-plugins-page|${seats.probe}|k4-tab')), findsOneWidget);
      expect(otherPages(), findsNothing);
    });
  });

  group('sheet', () {
    testWidgets('native panels first, then whose the web parts are, then their island; 20 on both sides', (
      tester,
    ) async {
      await _openSheet(tester, _overrides(_bridge(), web: _web));
      expect(find.text('插件'), findsWidgets);
      final frames = find.byType(PluginFrame);
      expect(frames, findsNWidgets(2));
      final names = [for (final f in tester.widgetList<PluginFrame>(frames)) f.pluginName];
      expect(names, ['用量', '相册']);
      final sources = tester.getRect(find.byKey(const ValueKey('chat-plugins-sources')));
      final island = tester.getRect(find.byKey(const ValueKey('chat-plugins-island')));
      final last = tester.getRect(frames.last);
      expect(sources.top, greaterThan(last.bottom));
      expect(island.top - sources.bottom, moreOrLessEquals(ChatPluginsMetrics.sourcesGap, epsilon: 0.5));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      for (final r in [tester.getRect(frames.first), last, island]) {
        expect(r.left, moreOrLessEquals(ChatPluginsMetrics.side, epsilon: 0.5));
        expect(width - r.right, moreOrLessEquals(ChatPluginsMetrics.side, epsilon: 0.5));
      }
      final spec = tester.widget<seats.FakeIsland>(find.byType(seats.FakeIsland)).spec;
      expect(spec.slot, Slots.chatSheet);
      expect(find.textContaining('网页插件'), findsOneWidget);
      // The ways in sit under the island, DSH Web always last: a part that
      // opens something the island never shows still has a way in.
      expect(find.byKey(const ValueKey('chat-plugins-ways-in')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-plugins-web-link')), findsOneWidget);
    });

    testWidgets('an island that can\'t come up is one 在网页版打开 row into the conversation', (tester) async {
      await _openSheet(
        tester,
        _overrides(
          _bridge(panels: false),
          web: _web,
          renderers: seats.testRenderers(island: (context, spec, items, fallback) => fallback(context)),
        ),
      );
      await pumpFrames(tester);
      expect(find.byType(seats.FakeIsland), findsNothing);
      expect(find.byKey(const ValueKey('chat-plugins-web-link')), findsOneWidget);
      await tester.tap(find.text('在网页版打开'));
      expect(seats.openedWeb.single, const DshWebTarget(sessionId: 's1'));
      expect(tester.takeException(), isNull);
    });

    for (final brightness in Brightness.values) {
      testWidgets('golden ${brightness.name}', (tester) async {
        usePhoneView(tester);
        await tester.pumpWidget(
          testApp(
            Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showChatPluginsSheet(context, sessionId: 's1'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
            brightness: brightness,
            overrides: _overrides(_bridge(), web: _web),
          ),
        );
        await pumpFrames(tester);
        await tester.tap(find.text('open'));
        await pumpFrames(tester, 12);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/chat_plugins_sheet_${brightness.name}.png'),
        );
      });
    }
  });
}
