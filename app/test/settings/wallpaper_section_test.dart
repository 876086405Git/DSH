// 设置 › 主题 › 壁纸: the two phones are measured (a symmetric pair on the page's picker grid,
// column for column with the launch screen's), the rows and sliders sit 16 from the card on both
// sides, choosing / switching / sliding work through the stored state, a refused file says why,
// and the card is drawn light and dark with and without a picture. Goldens:
//
//   flutter test --update-goldens test/settings/wallpaper_section_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/state/wallpaper_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/settings/appearance/launch_screen_section.dart';
import 'package:dsh_app/ui/settings/appearance/wallpaper_section.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/wallpaper/wallpaper_editor_page.dart';
import 'package:dsh_app/ui/wallpaper/wallpaper_preview_page.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../wallpaper/support.dart';

class _Import extends WallpaperImport {
  _Import(this.next) : super(directory: () async => Directory.systemTemp);

  (CustomWallpaper?, LaunchImportProblem?) next;
  int picks = 0;

  @override
  Future<(CustomWallpaper?, LaunchImportProblem?)> pick({CustomWallpaper? previous}) async {
    picks++;
    return next;
  }
}

class _Launcher extends LauncherIconChannel {
  const _Launcher();

  @override
  Future<AppIconState?> state() async => const AppIconState(current: AppIcon.mist);
}

/// The launch screen's card over the wallpaper's, as on the appearance page.
Widget _page() => Scaffold(
  body: SafeArea(
    child: ListView(
      children: [
        Builder(
          builder: (context) => const SettingsSection(title: '启动画面', children: [LaunchScreenSection()]),
        ),
        Builder(
          builder: (context) => SettingsSection(
            title: '壁纸',
            footer: Text(context.l10n.wallpaperFooter),
            children: const [WallpaperSection()],
          ),
        ),
      ],
    ),
  ),
);

void main() {
  late _Import import;

  setUp(() => import = _Import((null, LaunchImportProblem.cancelled)));

  Future<void> pump(
    WidgetTester tester, {
    CustomWallpaper? stored,
    Brightness brightness = Brightness.light,
    bool animations = false,
  }) async {
    SharedPreferences.setMockInitialValues({if (stored != null) CustomWallpaper.prefsKey: jsonOf(stored)});
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: _page(),
        brightness: brightness,
        animations: animations,
        overrides: [
          wallpaperImportProvider.overrideWithValue(import),
          launcherIconChannelProvider.overrideWithValue(const _Launcher()),
        ],
      ),
    );
    await settle(tester);
  }

  Rect screenOf(WidgetTester tester, String key) =>
      tester.getRect(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(ClipRSuperellipse)));

  Rect cardOf(WidgetTester tester, String key) =>
      tester.getRect(find.ancestor(of: find.byKey(ValueKey(key)), matching: find.byType(SheetGroup)));

  bool selected(WidgetTester tester, String key) =>
      tester.getSemantics(find.byKey(ValueKey(key))).getSemanticsData().flagsCollection.isSelected ==
      ui.Tristate.isTrue;

  group('geometry', () {
    testWidgets('two phones: a symmetric pair a third of the card wide, 12 apart, on the launch card\'s columns', (
      tester,
    ) async {
      await pump(tester);
      final card = cardOf(tester, 'wallpaper-default');
      final a = screenOf(tester, 'wallpaper-default');
      final b = screenOf(tester, 'wallpaper-custom');
      expect(a.left - card.left, moreOrLessEquals(card.right - b.right, epsilon: 0.01));
      expect(b.left - a.right, moreOrLessEquals(PickerGrid.gap, epsilon: 0.01));
      final third = (card.width - 2 * PickerGrid.inset - 2 * PickerGrid.gap) / 3;
      expect(a.width, moreOrLessEquals(third, epsilon: 0.01));
      expect(b.width, moreOrLessEquals(a.width, epsilon: 0.01));
      expect(b.height, moreOrLessEquals(a.height, epsilon: 0.01));
      expect(a.top, b.top);
      expect(a.top - card.top, moreOrLessEquals(PickerGrid.inset + 4, epsilon: 0.6));
      expect(a.width / a.height, moreOrLessEquals(390 / 844, epsilon: 0.002));
      expect(tester.getCenter(find.text('默认').last).dx, moreOrLessEquals(a.center.dx, epsilon: 0.01));
      expect(tester.getCenter(find.text('自定义').last).dx, moreOrLessEquals(b.center.dx, epsilon: 0.01));
      // Column for column with the launch screen's phones in the card above.
      final la = screenOf(tester, 'launch-default');
      final lb = screenOf(tester, 'launch-custom');
      for (final (x, y) in [(a.left, la.left), (a.right, la.right), (b.left, lb.left), (b.right, lb.right)]) {
        expect(x, moreOrLessEquals(y, epsilon: 0.01));
      }
      expect(a.height, moreOrLessEquals(la.height, epsilon: 0.01));
    });

    testWidgets('rows and sliders: 16 from the card on both sides, the value flush right', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brightFixture));
      final card = cardOf(tester, 'wallpaper-blur');
      for (final key in ['wallpaper-blur', 'wallpaper-tone']) {
        final row = find.byKey(ValueKey(key));
        final slider = tester.getRect(find.descendant(of: row, matching: find.byType(Slider)));
        expect(slider.left - card.left, moreOrLessEquals(16, epsilon: 0.01), reason: key);
        expect(card.right - slider.right, moreOrLessEquals(16, epsilon: 0.01), reason: key);
        final title = tester.getRect(find.descendant(of: row, matching: find.byType(Text)).first);
        final value = tester.getRect(find.descendant(of: row, matching: find.byType(Text)).last);
        expect(title.left - card.left, moreOrLessEquals(16, epsilon: 0.01), reason: key);
        expect(card.right - value.right, moreOrLessEquals(16, epsilon: 0.01), reason: key);
        expect(title.center.dy, moreOrLessEquals(value.center.dy, epsilon: 0.6), reason: key);
      }
      // The plain rows' titles on the same line as the sliders' titles.
      final frameTitle = tester.getRect(find.text('调整位置'));
      expect(frameTitle.left - card.left, moreOrLessEquals(16, epsilon: 0.01));
    });
  });

  group('choosing', () {
    testWidgets('no picture yet: 自定义 picks one; it is chosen and its rows open', (tester) async {
      await pump(tester);
      expect(selected(tester, 'wallpaper-default'), isTrue);
      expect(find.text('调整位置'), findsNothing);
      final dir = Directory.systemTemp.createTempSync('wallpaper-section');
      addTearDown(() => dir.deleteSync(recursive: true));
      final copy = File('${dir.path}/w.jpg')..writeAsBytesSync(File(brightFixture).readAsBytesSync());
      import.next = (CustomWallpaper(path: copy.path, width: 720, height: 1280), null);
      await tester.tap(find.byKey(const ValueKey('wallpaper-custom')));
      await settle(tester);
      expect(import.picks, 1);
      expect(selected(tester, 'wallpaper-custom'), isTrue);
      expect(find.text('调整位置'), findsOneWidget);
      expect(find.text('壁纸已更换'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(CustomWallpaper.prefsKey), contains(copy.path));
    });

    testWidgets('a refused file says why; nothing changes', (tester) async {
      await pump(tester);
      for (final (problem, text) in [
        (LaunchImportProblem.tooLarge, '图片超过 15 MB'),
        (LaunchImportProblem.unsupported, '支持 PNG、JPEG 和 WebP'),
        (LaunchImportProblem.unreadable, '无法读取这张图片'),
      ]) {
        import.next = (null, problem);
        await tester.tap(find.byKey(const ValueKey('wallpaper-custom')));
        await settle(tester);
        expect(find.text(text), findsOneWidget, reason: problem.name);
        expect(selected(tester, 'wallpaper-default'), isTrue);
        ScaffoldMessenger.of(tester.element(find.byType(WallpaperSection))).clearSnackBars();
        await tester.pump(const Duration(milliseconds: 600));
      }
    });

    testWidgets('默认 puts the default back and keeps the picture to return to', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brightFixture));
      expect(selected(tester, 'wallpaper-custom'), isTrue);
      await tester.tap(find.byKey(const ValueKey('wallpaper-default')));
      await settle(tester);
      expect(selected(tester, 'wallpaper-default'), isTrue);
      expect(find.text('调整位置'), findsNothing);
      expect((await CustomWallpaper.load())!.on, isFalse);
      // Back: no picker, the same picture.
      await tester.tap(find.byKey(const ValueKey('wallpaper-custom')));
      await settle(tester);
      expect(import.picks, 0);
      expect(selected(tester, 'wallpaper-custom'), isTrue);
      expect((await CustomWallpaper.load())!.path, brightFixture);
    });

    testWidgets('sliders: blur, and 提亮 in light / 压暗 in dark, each stored when let go', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brightFixture, tone: 0.2));
      expect(find.descendant(of: find.byKey(const ValueKey('wallpaper-tone')), matching: find.text('提亮')), findsOne);
      await scrollToWallpaper(tester);
      await tester.drag(
        find.descendant(of: find.byKey(const ValueKey('wallpaper-blur')), matching: find.byType(Slider)),
        const Offset(-2000, 0),
      );
      await settle(tester);
      expect((await CustomWallpaper.load())!.blur, 0);
      expect(find.descendant(of: find.byKey(const ValueKey('wallpaper-blur')), matching: find.text('0%')), findsOne);
      await tester.drag(
        find.descendant(of: find.byKey(const ValueKey('wallpaper-tone')), matching: find.byType(Slider)),
        const Offset(2000, 0),
      );
      await settle(tester);
      final stored = (await CustomWallpaper.load())!;
      expect(stored.lighten, 1);
      expect(stored.dim, 0.2, reason: 'the dark page keeps its own');
    });

    Future<void> flip(WidgetTester tester, String key) async {
      await scrollToWallpaper(tester);
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey(key)));
      await settle(tester);
    }

    testWidgets('自动保证文字清晰 is stored when switched; a still has no 播放动图', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brightFixture));
      await flip(tester, 'wallpaper-guard');
      expect((await CustomWallpaper.load())!.guard, isFalse);
      expect(find.byKey(const ValueKey('wallpaper-play')), findsNothing);
    });

    testWidgets('an animation: 播放动图 is stored when switched; the guard\'s note on it only while guarded', (
      tester,
    ) async {
      const note = '播放动图时只调文字颜色，画面不加遮罩';
      const gif = CustomWallpaper(path: gifFixture, width: 120, height: 200, animated: true);
      await pump(tester, stored: gif, animations: true);
      await scrollToWallpaper(tester);
      expect(find.text(note), findsOneWidget);
      await flip(tester, 'wallpaper-guard');
      expect(find.text(note), findsNothing, reason: 'unguarded, the text colours stay as they are too');
      await flip(tester, 'wallpaper-play');
      final stored = (await CustomWallpaper.load())!;
      expect((stored.play, stored.guard), (false, false));
    });

    testWidgets('dark: the tone slider is 压暗', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brightFixture), brightness: Brightness.dark);
      expect(find.descendant(of: find.byKey(const ValueKey('wallpaper-tone')), matching: find.text('压暗')), findsOne);
    });

    testWidgets('调整位置 and 预览 open their pages', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brightFixture));
      await scrollToWallpaper(tester);
      await tester.tap(find.byKey(const ValueKey('wallpaper-frame')));
      await settle(tester);
      expect(find.byType(WallpaperEditorPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wallpaper-editor-cancel')));
      await settle(tester);
      expect(find.byType(WallpaperEditorPage), findsNothing);
      await tester.tap(find.byKey(const ValueKey('wallpaper-preview')));
      await settle(tester);
      expect(find.byType(WallpaperPreviewPage), findsOneWidget);
      await tester.tapAt(const Offset(195, 400));
      await settle(tester);
      expect(find.byType(WallpaperPreviewPage), findsNothing);
    });

    testWidgets('a picture that can no longer be read: the phone says so, nothing breaks', (tester) async {
      await pump(tester, stored: fixtureWallpaper(brokenFixture));
      expect(
        find.descendant(of: find.byKey(const ValueKey('wallpaper-custom')), matching: find.byType(Text)),
        findsWidgets,
      );
      expect(find.text('无法读取'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('goldens', () {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('default ($mode)', (tester) async {
        await pump(tester, brightness: brightness);
        await scrollToWallpaper(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/wallpaper_section_default_$mode.png'));
      });
      testWidgets('custom ($mode)', (tester) async {
        await pump(tester, stored: fixtureWallpaper(brightFixture), brightness: brightness);
        await scrollToWallpaper(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/wallpaper_section_custom_$mode.png'));
      });
    }
  });
}

/// Real I/O (prefs, the bake) lands a frame at a time; with a picture stored, until its phone
/// shows the bake or says it can't be read (however long a busy machine takes).
Future<void> settle(WidgetTester tester) async {
  bool baked() {
    final custom = find.byKey(const ValueKey('wallpaper-custom'));
    if (custom.evaluate().isEmpty) return true;
    return find.descendant(of: custom, matching: find.byType(RawImage)).evaluate().isNotEmpty ||
        find.descendant(of: custom, matching: find.text('无法读取')).evaluate().isNotEmpty ||
        find.descendant(of: custom, matching: find.byIcon(AppIcons.addImage)).evaluate().isNotEmpty;
  }

  // Waiting doesn't move the test clock; the fixed pumps after it do.
  for (var i = 0; i < 10 || (!baked() && i < 400); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
  }
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> scrollToWallpaper(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.byKey(const ValueKey('wallpaper-preview')), 200);
  await settle(tester);
}
