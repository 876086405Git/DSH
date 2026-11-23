// Measured alignment of the shell's chrome: the drawer's 10 / 20 grid, the
// secondary-page bar, the search header, the sheet header and the onboarding
// step bar. Numbers, not eyeballing.
//
//   flutter test test/shell/shell_geometry_test.dart

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/onboarding/onboarding_scaffold.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/shell/brand_mark.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'brand_support.dart';
import 'golden_harness.dart';

const _eps = 0.01;

Matcher _near(double v) => closeTo(v, _eps);

Future<void> _pumpDrawer(WidgetTester tester) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      brightness: Brightness.light,
      overrides: [
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
        currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('drawer', () {
    testWidgets('text on the 20 line, edges on the 10 line', (tester) async {
      await _pumpDrawer(tester);
      final drawer = tester.getRect(find.byType(SessionsDrawer));
      final lockup = tester.getRect(find.byType(BrandLockup));
      final newChat = tester.getRect(find.byType(NewChatButton));
      final search = tester.getRect(
        find.descendant(of: find.byType(SessionSearchBar), matching: find.byType(GlassSurface)),
      );
      final tile = tester.getRect(find.byType(SessionTile).first);
      final title = tester.getRect(find.text('修复登录按钮重复提交'));

      expect(lockup.left - drawer.left, _near(20));
      expect(title.left - drawer.left, _near(20));
      expect(tile.left - drawer.left, _near(10));
      expect(drawer.right - tile.right, _near(10));
      expect(search.left - drawer.left, _near(10));
      // With no workspace row the list's options key ends the search row on the 10 line.
      final options = find.descendant(of: find.byType(SessionSearchBar), matching: find.byType(DrawerViewButton));
      final searchRowEnd = options.evaluate().isEmpty ? search.right : tester.getRect(options).right;
      expect(drawer.right - searchRowEnd, _near(10));
      expect(drawer.right - newChat.right, _near(10));
      // The pill and the lockup share a centre line.
      expect(newChat.center.dy, _near(lockup.center.dy));
      expect(newChat.height, _near(36));
      // The lockup itself: glyph centred on the word's cap height, sized and spaced by it.
      await expectBrandLockup(tester, find.byType(BrandLockup));
    });

    testWidgets('identity bar: avatar on the 20 line, 全部功能 and 设置 equal, ending on the 10 line', (tester) async {
      await _pumpDrawer(tester);
      final drawer = tester.getRect(find.byType(SessionsDrawer));
      final bar = find.byType(IdentityBar);
      final avatar = tester.getRect(
        find.ancestor(of: find.byIcon(AppIcons.thisPhone), matching: find.byType(DecoratedBox)).first,
      );
      final features = tester.getRect(find.descendant(of: bar, matching: find.byTooltip('全部功能')));
      final settings = tester.getRect(find.descendant(of: bar, matching: find.byTooltip('设置')));

      expect(avatar.left - drawer.left, _near(20));
      expect(features.size, settings.size);
      expect(features.width, _near(44));
      expect(features.height, _near(44));
      expect(drawer.right - settings.right, _near(10));
      expect(settings.left - features.right, _near(8));
      // One centre line through the avatar and both buttons.
      expect(features.center.dy, _near(avatar.center.dy));
      expect(settings.center.dy, _near(avatar.center.dy));
    });
  });

  group('secondary page bar', () {
    testWidgets('back button 12 from the edge, 44 round, title on the large-title line', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: AppPage.list(
            title: '示例',
            children: [for (var i = 0; i < 40; i++) SizedBox(height: 48, child: Text('行 $i'))],
          ),
        ),
      );
      await tester.pump();
      final screen = tester.getRect(find.byType(AppPage));
      final back = tester.getRect(find.byType(GlassIconButton));
      expect(back.left - screen.left, _near(12));
      expect(back.size, const Size(44, 44));
      expect(back.top, _near(32 + 6)); // status bar + (56 - 44) / 2
      final titles = find.text('示例');
      expect(titles, findsNWidgets(2));
      // The large title starts on the 24 line, where the back glyph sits.
      final large = tester.getRect(titles.first);
      expect(large.left, _near(24));
      // The bar title is centred on the screen.
      final bar = tester.getRect(titles.last);
      expect(bar.center.dx, _near(screen.center.dx));
    });
  });

  testWidgets('secondary page with two actions keeps its title centred', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: AppPage.list(
          title: '两个操作',
          actions: [
            GlassIconButton(icon: AppIcons.search, tooltip: '查找', onPressed: () {}),
            GlassIconButton(icon: AppIcons.more, tooltip: '更多', onPressed: () {}),
          ],
          children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('行 $i'))],
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final screen = tester.getRect(find.byType(AppPage));
    final title = tester.getRect(find.text('两个操作').last);
    final back = tester.getRect(find.byTooltip('返回'));
    final search = tester.getRect(find.byTooltip('查找'));
    final more = tester.getRect(find.byTooltip('更多'));
    expect(title.center.dx, closeTo(screen.center.dx, 0.5));
    expect(more.left - search.right, _near(8));
    expect(screen.right - more.right, _near(12));
    for (final button in [back, search, more]) {
      expect(button.size, const Size(44, 44));
      expect(button.center.dy, _near(back.center.dy));
    }
  });

  testWidgets('search header: 12 on both sides, field as tall as the back button and level with it', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(brightness: Brightness.light, home: const SessionSearchPage()));
    await tester.pump();
    final screen = tester.getRect(find.byType(SessionSearchPage));
    final back = tester.getRect(find.byType(GlassIconButton));
    final field = tester.getRect(find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first);
    expect(back.left - screen.left, _near(12));
    expect(screen.right - field.right, _near(12));
    expect(field.height, _near(back.height));
    expect(field.center.dy, _near(back.center.dy));
  });

  testWidgets('sheet header: one handle and a title with mirrored 20 gutters', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAppSheet<void>(
                  context,
                  builder: (_) => const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SheetHeader('切换主机'),
                      SheetGroup(children: [ListTile(title: Text('本机'))]),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheet = tester.getRect(find.byType(SheetHeader));
    final title = tester.getRect(find.text('切换主机'));
    final group = tester.getRect(find.descendant(of: find.byType(SheetGroup), matching: find.byType(GlassSurface)));
    expect(title.left - sheet.left, _near(kSheetGutter));
    expect(sheet.right - title.right, _near(kSheetGutter));
    expect(find.byType(SheetIconButton), findsNothing);
    expect(find.byType(SheetDragHandle), findsOneWidget);
    // Default groups in a sheet follow the same gutter.
    expect(group.left - sheet.left, _near(kSheetGutter));
    expect(sheet.right - group.right, _near(kSheetGutter));
  });

  testWidgets('onboarding step bar is centred on the screen', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: OnboardingProgress(step: 1, steps: 2, child: RuntimeSetupPage(onDone: () {})),
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(
              const LocalRuntimeState(
                loaded: true,
                status: RuntimeStatus(phase: RuntimePhase.installing, bundledVersion: 'r1'),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    final screen = tester.getRect(find.byType(RuntimeSetupPage));
    final bar = tester.getRect(find.byType(OnboardingStepBar));
    expect(bar.center.dx, _near(screen.center.dx));
    expect(bar.width, _near(OnboardingStepBar.width));
  });
}
