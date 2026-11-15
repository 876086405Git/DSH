// 设置 › 主题: the palette follows the pick app-wide and is stored; custom
// colours are guarded; the wallpaper row only exists when the system has a
// wallpaper colour; the swatch row and the mode tiles are measured. Goldens:
//
//   flutter test --update-goldens test/settings/appearance_page_test.dart
//
// The goldens show the whole page, tile styles, launcher icons and launch screen included.

import 'package:dsh_app/app.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/tile_style_state.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/settings/appearance/tile_style_picker.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../tiles/support.dart' show decodeImages;
import '../support/english_preview.dart';
import '../support/test_fonts.dart';

class _Wallpaper extends DynamicColorChannel {
  const _Wallpaper(this.color);

  final Color? color;

  @override
  Future<Color?> wallpaperAccent() async => color;
}

class _FixedAppearance extends AppearanceController {
  _FixedAppearance(this.initial);

  final AppearanceSettings initial;

  @override
  AppearanceSettings build() => initial;
}

/// The launcher shows the default icon.
class _Launcher extends LauncherIconChannel {
  const _Launcher();

  @override
  Future<AppIconState?> state() async => const AppIconState(current: AppIcon.mist);
}

const _wallpaperBlue = Color(0xFF3F6FB5);

List<Override> _overrides({Color? wallpaper, AppSettings settings = const AppSettings(loaded: true)}) => [
  settingsProvider.overrideWith(() => FakeSettings(settings)),
  dynamicColorChannelProvider.overrideWithValue(_Wallpaper(wallpaper)),
];

/// The real app shell (themes follow [accentProvider]) around the page; tall
/// enough that every group is laid out.
Future<ProviderContainer> _pumpApp(WidgetTester tester, {Color? wallpaper}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 1700 * 2);
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: _overrides(wallpaper: wallpaper));
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const DshApp(home: AppearancePage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

ColorScheme _scheme(WidgetTester tester) => Theme.of(tester.element(find.byType(AppearancePage))).colorScheme;

/// Golden app: real fonts, the theme of [accent].
Widget _goldenApp(Widget home, Brightness brightness, AppAccent accent, List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme(accent: accent)),
    darkTheme: withTestFonts(buildDarkTheme(accent: accent)),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
    home: home,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a preset swatch switches the whole app and is stored', (tester) async {
    final container = await _pumpApp(tester);
    expect(_scheme(tester).primary, AppAccent.mist.seed);

    await tester.tap(find.bySemanticsLabel('配色：琥珀'));
    await tester.pumpAndSettle();
    expect(container.read(accentProvider), AppAccent.amber);
    expect(_scheme(tester).primary, AppAccent.amber.seed);
    expect(_scheme(tester).surface, NeutralTones.forAccent(AppAccent.amber).mist);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('appearance.preset'), 'amber');
    expect(prefs.getString('appearance.accent_source'), 'preset');
    expect(prefs.getInt(AppearanceController.notifyColorKey), AppAccent.amber.seed.toARGB32());
  });

  testWidgets('the stored palette comes back at launch', (tester) async {
    SharedPreferences.setMockInitialValues({'appearance.accent_source': 'preset', 'appearance.preset': 'dusk'});
    final container = await _pumpApp(tester);
    expect(container.read(accentProvider), AppAccent.dusk);
    expect(_scheme(tester).primary, AppAccent.dusk.seed);
  });

  testWidgets('custom: the hue panel opens; picks are guarded before they are used', (tester) async {
    final container = await _pumpApp(tester);
    expect(find.byType(HueSlider), findsNothing);

    await tester.tap(find.bySemanticsLabel('配色：自定义'));
    await tester.pumpAndSettle();
    expect(find.byType(HueSlider), findsOneWidget);
    expect(container.read(appearanceProvider).source, AccentSource.custom);

    await tester.tap(find.bySemanticsLabel('湖蓝'));
    await tester.pumpAndSettle();
    final pick = AppAccent.hueColor(215, chroma: 0.09);
    expect(container.read(appearanceProvider).customColor, pick.toARGB32());
    final primary = _scheme(tester).primary;
    expect(primary, AppAccent.guardedSeed(pick, Brightness.light));
    expect(contrastRatio(Colors.white, primary), greaterThanOrEqualTo(4.5));

    // Dragging the hue track lands on the hue under the finger.
    final track = tester.getRect(find.byType(HueSlider));
    await tester.tapAt(Offset(track.left + HueSlider.knob / 2 + (track.width - HueSlider.knob) * 0.5, track.center.dy));
    await tester.pumpAndSettle();
    final hue = Oklch.fromColor(Color(container.read(appearanceProvider).customColor)).h;
    expect(hue, closeTo(180, 2));

    // Back to a preset: the panel folds away, the custom colour is kept.
    await tester.tap(find.bySemanticsLabel('配色：雾蓝'));
    await tester.pumpAndSettle();
    expect(find.byType(HueSlider), findsNothing);
    expect(container.read(appearanceProvider).customColor, isNot(AppearanceSettings.defaultCustom));
  });

  testWidgets('no wallpaper colour (before Android 12): no wallpaper row', (tester) async {
    await _pumpApp(tester);
    expect(find.text('跟随壁纸'), findsNothing);
  });

  testWidgets('wallpaper: the row follows the system colour and leaves to the last preset', (tester) async {
    final container = await _pumpApp(tester, wallpaper: _wallpaperBlue);
    await tester.tap(find.bySemanticsLabel('配色：松石'));
    await tester.pumpAndSettle();
    expect(find.text('跟随壁纸'), findsOneWidget);

    await tester.tap(find.text('跟随壁纸'));
    await tester.pumpAndSettle();
    final derived = AppAccent.derive(_wallpaperBlue, id: AppAccent.wallpaperId, label: '壁纸');
    expect(container.read(accentProvider), derived);
    expect(_scheme(tester).primary, derived.seed);

    await tester.tap(find.text('跟随壁纸'));
    await tester.pumpAndSettle();
    expect(container.read(accentProvider), AppAccent.turquoise);
  });

  testWidgets('mode tiles set light / dark / system', (tester) async {
    final container = await _pumpApp(tester);
    await tester.tap(find.bySemanticsLabel('深色'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(_scheme(tester).brightness, Brightness.dark);
    await tester.tap(find.bySemanticsLabel('跟随系统'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.system);
  });

  testWidgets('a screen reader can pick the mode and the colour (#157)', (tester) async {
    final container = await _pumpApp(tester);
    final semantics = tester.ensureSemantics();
    tester.semantics.tap(find.semantics.byLabel('深色'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    tester.semantics.tap(find.semantics.byLabel('配色：琥珀'));
    await tester.pumpAndSettle();
    expect(container.read(accentProvider), AppAccent.amber);
    semantics.dispose();
  });

  testWidgets('every picker sits on one grid: 16 from the card, 12 apart, columns aligned', (tester) async {
    await _pumpApp(tester);
    Rect cardOf(Type picker) =>
        tester.getRect(find.ancestor(of: find.byType(picker), matching: find.byType(GlassSurface)).first);

    // Mode previews and tile-style previews: same three columns.
    final modeCard = cardOf(ThemeModePicker);
    final modes = [
      for (final m in ['浅色', '深色', '跟随系统']) tester.getRect(find.byKey(ValueKey('theme-mode-$m'))),
    ];
    final styles = [for (final s in TileStyle.values) tester.getRect(find.byKey(ValueKey('tile-style-${s.name}')))];
    expect(modes.first.left - modeCard.left, moreOrLessEquals(PickerGrid.inset, epsilon: 0.6));
    expect(modeCard.right - modes.last.right, moreOrLessEquals(PickerGrid.inset, epsilon: 0.6));
    // Top: the same as the tile styles' (the card adds 4 above every group).
    expect(
      modes.first.top - modeCard.top,
      moreOrLessEquals(styles.first.top - cardOf(TileStylePicker).top, epsilon: 0.6),
    );
    for (var i = 0; i < 3; i++) {
      expect(modes[i].left, moreOrLessEquals(styles[i].left, epsilon: 0.6), reason: 'column $i');
      expect(modes[i].width, moreOrLessEquals(styles[i].width, epsilon: 0.6), reason: 'column $i');
      if (i > 0) expect(modes[i].left - modes[i - 1].right, moreOrLessEquals(PickerGrid.gap, epsilon: 0.6));
    }
    // The name sits as far under its preview as the tile styles' do.
    final modeLabel = tester.getRect(find.text('浅色'));
    final styleLabel = tester.getRect(find.text(TileStyle.values.first.label));
    expect(modeLabel.top - modes.first.bottom, moreOrLessEquals(styleLabel.top - styles.first.bottom, epsilon: 0.6));
    expect(
      modeCard.bottom - modeLabel.bottom,
      moreOrLessEquals(cardOf(TileStylePicker).bottom - styleLabel.bottom, epsilon: 0.6),
    );
  });

  testWidgets('swatch row and mode tiles are symmetric in their card', (tester) async {
    await _pumpApp(tester);
    final card = tester.getRect(
      find.ancestor(of: find.byType(PalettePicker), matching: find.byType(GlassSurface)).first,
    );
    final discs = [
      for (final p in [...AppAccent.presets.map((p) => p.label), '自定义'])
        tester.getRect(find.descendant(of: find.bySemanticsLabel('配色：$p'), matching: find.byType(CustomPaint)).first),
    ];
    expect(discs.first.left - card.left, moreOrLessEquals(PickerGrid.inset, epsilon: 0.6));
    expect(card.right - discs.last.right, moreOrLessEquals(PickerGrid.inset, epsilon: 0.6));
    // 16 under the card's own 4 at the top, like every other picker.
    expect(discs.first.top - card.top, moreOrLessEquals(PickerGrid.inset + 4, epsilon: 0.6));
    final gaps = [for (var i = 1; i < discs.length; i++) discs[i].center.dx - discs[i - 1].center.dx];
    for (final g in gaps) {
      expect(g, moreOrLessEquals(gaps.first, epsilon: 0.6));
    }
    for (final d in discs) {
      expect(d.center.dy, moreOrLessEquals(discs.first.center.dy, epsilon: 0.01));
    }

    final modeCard = tester.getRect(
      find.ancestor(of: find.byType(ThemeModePicker), matching: find.byType(GlassSurface)).first,
    );
    final tiles = [
      for (final m in ['浅色', '深色', '跟随系统']) tester.getRect(find.bySemanticsLabel(m)),
    ];
    expect(tiles.first.left - modeCard.left, moreOrLessEquals(modeCard.right - tiles.last.right, epsilon: 0.6));
    expect(tiles[1].center.dx, moreOrLessEquals(modeCard.center.dx, epsilon: 0.6));
    for (final t in tiles) {
      expect(t.width, moreOrLessEquals(tiles.first.width, epsilon: 0.01));
    }
  });

  testWidgets('narrow phone, large text: nothing overflows', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(360 * 2, 780 * 2);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._overrides(wallpaper: _wallpaperBlue),
          appearanceProvider.overrideWith(
            () => _FixedAppearance(const AppearanceSettings(source: AccentSource.custom, loaded: true)),
          ),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: 1.6,
            maxScaleFactor: 1.6,
            child: const AppearancePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(HueSlider), findsOneWidget);
  });

  // ── Goldens ────────────────────────────────────────────────────────────

  for (final (name, accent, state) in [
    ('appearance', AppAccent.mist, const AppearanceSettings(loaded: true)),
    (
      'appearance_custom',
      AppAccent.derive(Color(AppearanceSettings.defaultCustom)),
      const AppearanceSettings(source: AccentSource.custom, loaded: true),
    ),
  ]) {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('golden $name ($mode)', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        usePhoneSurface(tester);
        // The whole page, down to the wallpaper.
        tester.view.physicalSize = const Size(390 * 2, 2060 * 2);
        await tester.pumpWidget(
          _goldenApp(const AppearancePage(), brightness, accent, [
            ..._overrides(wallpaper: _wallpaperBlue),
            appearanceProvider.overrideWith(() => _FixedAppearance(state)),
            launcherIconChannelProvider.overrideWithValue(const _Launcher()),
          ]),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await decodeImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
      });
    }
  }

  // English smoke golden (i18n), light.
  testWidgets('golden appearance (en)', (tester) async {
    useEnglish();
    await tester.runAsync(loadGoldenFonts);
    usePhoneSurface(tester);
    tester.view.physicalSize = const Size(390 * 2, 2060 * 2);
    await tester.pumpWidget(
      _goldenApp(inEnglish(const AppearancePage()), Brightness.light, AppAccent.mist, [
        ..._overrides(wallpaper: _wallpaperBlue),
        appearanceProvider.overrideWith(() => _FixedAppearance(const AppearanceSettings(loaded: true))),
        launcherIconChannelProvider.overrideWithValue(const _Launcher()),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await decodeImages(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_appearance_light.png'));
  });
}
