// A screenshot tool, not a test: renders 伙伴小屋 (the room with a stand-in
// stage, then its menu) to PNGs so the room can be judged by eye on a machine
// with no phone.
//
// Skipped unless DSH_COMPANION_GALLERY_OUT names the output folder:
//
//   DSH_TEST_FONT_DIR=<fonts> DSH_COMPANION_GALLERY_OUT=<folder> \
//     flutter test test/companion/companion_gallery_dump_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/companion/companion_float.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_drawer_row.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';
import 'phone_keeper_fake.dart';

final _outDir = Platform.environment['DSH_COMPANION_GALLERY_OUT'];

/// Where her model would stand: a soft figure on the water, enough to judge
/// what the room's chrome does around her.
class _StandIn extends StatelessWidget {
  const _StandIn();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1B4E7E), Color(0xFF0D2F55), Color(0xFF09223F)],
      ),
    ),
    child: Align(
      alignment: Alignment(0, 0.1),
      child: SizedBox(
        width: 180,
        height: 420,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Color(0x33FFFFFF), borderRadius: BorderRadius.all(Radius.circular(90))),
        ),
      ),
    ),
  );
}

Future<void> _dump(WidgetTester tester, GlobalKey shot, String name) async {
  final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('$_outDir/$name').writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
  });
}

Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  group('companion gallery', skip: _outDir == null ? 'set DSH_COMPANION_GALLERY_OUT=<folder>' : false, () {
    late Directory root;

    setUpAll(() async {
      await loadTestFonts();
      Directory(_outDir!).createSync(recursive: true);
    });
    setUp(() => root = Directory.systemTemp.createTempSync('companion-gallery'));

    testWidgets('room and menu', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      tester.view.physicalSize = const Size(390 * 2, 844 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      Directory('${root.path}/pack/runtime').createSync(recursive: true);
      Directory('${root.path}/pack/character').createSync(recursive: true);
      File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
      File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
      File('${root.path}/pack/character/character.json').writeAsStringSync('{"name":"鲸鱼娘"}');
      final shot = GlobalKey();
      CompanionStageEvents? events;
      final base = buildDarkTheme();
      await tester.pumpWidget(
        RepaintBoundary(
          key: shot,
          child: ProviderScope(
            overrides: [
              activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
              companionPhoneKeeperProvider.overrideWithValue((_) => FakePhoneKeeper()),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: withTestFonts(
                base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])),
              ),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              locale: const Locale('zh'),
              home: CompanionPage(
                storeOverride: CompanionPackStore(root),
                sections: true,
                stageBuilder: (controller, e) {
                  events = e;
                  return const _StandIn();
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 100 && events == null; i++) {
        await _settle(tester);
      }
      events!.onReady();
      await _settle(tester, 20);
      await _dump(tester, shot, 'room.png');

      for (final (label, file) in [('记忆', 'memory'), ('交代', 'tasks'), ('她', 'her')]) {
        await tester.tap(find.text(label).last);
        await _settle(tester, 12);
        await _dump(tester, shot, '$file.png');
      }
      await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -700));
      await _settle(tester, 4);
      await _dump(tester, shot, 'her-2.png');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('drawer row', (tester) async {
      tester.view.physicalSize = const Size(320 * 2, 200 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final today = DateTime.now();
      final at7 = DateTime(today.year, today.month, today.day, 19);
      final tomorrow9 = DateTime(today.year, today.month, today.day + 1, 9);
      for (final (dark, name, due, file) in [
        (false, '鲸鱼娘', at7.isAfter(today) ? at7 : tomorrow9, 'reminder'),
        (true, '鲸鱼娘', tomorrow9, 'tomorrow'),
        (false, '鲸鱼娘', null, 'quiet'),
        (false, null, null, 'unnamed'),
      ]) {
        SharedPreferences.setMockInitialValues({'companion_name': ?name});
        final shot = GlobalKey();
        final base = dark ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(
          RepaintBoundary(
            key: shot,
            child: ProviderScope(
              overrides: [
                companionNextReminderProvider.overrideWith((ref) async => due?.millisecondsSinceEpoch),
                companionPackNameProvider.overrideWith((ref) async => null),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: withTestFonts(
                  base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])),
                ),
                localizationsDelegates: L10n.localizationsDelegates,
                supportedLocales: L10n.supportedLocales,
                locale: const Locale('zh'),
                home: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Column(children: [CompanionDrawerRow(onTap: () {})]),
                  ),
                ),
              ),
            ),
          ),
        );
        await _settle(tester, 4);
        await _dump(tester, shot, 'drawer-$file-${dark ? 'dark' : 'light'}.png');
      }
    });
  });
}
