// A screenshot tool, not a test: renders the chat page under the default look
// and every built-in theme pack, light and dark, and writes PNGs to a folder
// so a theme can be judged by eye on a machine with no emulator.
//
// Skipped unless DSH_THEME_GALLERY_OUT names the output folder:
//
//   DSH_TEST_FONT_DIR=<fonts> DSH_THEME_GALLERY_OUT=<folder> \
//     flutter test test/themes/theme_gallery_dump_test.dart
//
// Per theme and brightness: `<id>-<light|dark>-chat.png` (one screen of
// conversation, idle composer) and `<id>-<light|dark>-empty.png` (the new-chat
// page with a draft in the composer). Both are the real ChatScreen over the
// chat tests' fake providers, 390×844 at 2x.
//
// The `serif` font role draws with Noto Serif SC when the font folder has
// `NotoSerifSC-VF.ttf` (or DSH_THEME_GALLERY_SERIF names a font file);
// otherwise Noto Sans CJK stands in for it.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import '../support/test_fonts.dart';

/// What gets drawn: an id for the file names and the pack (null = the app
/// without a theme pack). Add a pack here to look at it.
final galleryThemes = <(String id, ThemePack? pack)>[
  ('default', null),
  for (final pack in ThemePack.builtIns) (pack.id, pack),
];

final _outDir = Platform.environment['DSH_THEME_GALLERY_OUT'];

const _longReply = '''## 原因和修法

两次点击之间的 `await` 让第二次也进了 `submit()`，**进入时先上锁**就行，见 [异步指南](https://dart.dev/libraries/async/async-await)。

- 进入时先判断 `_submitting`
- 上锁后再发请求
- 成功失败都复位

```dart
Future<void> submit() async {
  if (_submitting) return; // 已在提交
  _submitting = true;
  await _api
      .login(email, password)
      .whenComplete(_unlock);
}
```''';

/// Two finished turns, the short one first: when a theme's type runs taller
/// than the screen it is the short turn that slides under the header, and the
/// reply with every Markdown piece a theme restyles stays whole.
ChatState _conversation() => ChatState(
  items: [user(1, '先跑一下登录相关的测试。'), assistant(2, '跑过了，有 1 个失败：连点会重复提交。'), user(3, '帮我看看怎么修。'), assistant(4, _longReply)],
  title: '修复登录重复提交',
  loading: false,
  model: const ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro', reasoningEffort: 'high'),
);

/// As the app's root builds it (lib/app.dart), with the test engine's fonts
/// named as `testTheme` does for the plain theme.
ThemeData _theme(ThemePack? pack, Brightness brightness) {
  final accent = pack == null ? AppAccent.mist : AppAccent.fromThemePack(pack);
  final base = brightness == Brightness.dark
      ? buildDarkTheme(accent: accent, themePack: pack)
      : buildLightTheme(accent: accent, themePack: pack);
  return withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])));
}

/// `testApp` with a theme pack's theme, inside the boundary that is captured.
Widget _app(GlobalKey shot, ThemePack? pack, Brightness brightness, ChatHarness harness) {
  return RepaintBoundary(
    key: shot,
    child: ProviderScope(
      overrides: [accountWalletBalanceProvider.overrideWithValue(null), ...harness.overrides],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(pack, Brightness.light),
        darkTheme: _theme(pack, Brightness.dark),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MirroredSideInsets(child: child!),
        home: const ChatScreen(),
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

/// The `serif` role names the family `serif`, which a phone answers with its
/// system serif and the test engine with boxes: give it real glyphs.
Future<void> _loadSerif() async {
  final fontDir = Platform.environment['DSH_TEST_FONT_DIR'] ?? '/usr/share/fonts/noto-cjk';
  final asked = Platform.environment['DSH_THEME_GALLERY_SERIF'];
  final serif = [?asked, '$fontDir/NotoSerifSC-VF.ttf'].where((path) => File(path).existsSync()).firstOrNull;
  final paths = serif != null ? [serif] : ['$fontDir/NotoSansCJK-Regular.ttc', '$fontDir/NotoSansCJK-Bold.ttc'];
  final loader = FontLoader('serif');
  for (final path in paths) {
    loader.addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  }
  await loader.load();
  // ignore: avoid_print
  print('theme gallery: serif role drawn with ${serif ?? 'Noto Sans CJK (no serif font found)'}');
}

void main() {
  group('theme gallery', skip: _outDir == null ? 'set DSH_THEME_GALLERY_OUT=<folder> to render the PNGs' : false, () {
    setUpAll(() async {
      await loadTestFonts();
      await _loadSerif();
      await WhaleSprites.load();
      chatClock = () => DateTime(2026, 10, 23, 15, 20);
      runClock = () => DateTime(2026, 10, 23, 15, 20);
      Directory(_outDir!).createSync(recursive: true);
    });

    for (final (id, pack) in galleryThemes) {
      for (final brightness in Brightness.values) {
        final mode = brightness == Brightness.dark ? 'dark' : 'light';

        testWidgets('$id $mode: conversation', (tester) async {
          usePhoneView(tester);
          mockClipboard(tester);
          final shot = GlobalKey();
          final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
          await tester.pumpWidget(_app(shot, pack, brightness, harness));
          await pumpFrames(tester, 10);
          await _dump(tester, shot, '$id-$mode-chat.png');
          expect(tester.takeException(), isNull);
        });

        testWidgets('$id $mode: new chat', (tester) async {
          usePhoneView(tester);
          final shot = GlobalKey();
          await tester.pumpWidget(_app(shot, pack, brightness, ChatHarness()));
          await pumpFrames(tester, 10);
          // A draft, here where there is room for the taller composer: the
          // send key in the theme's own colours (the conversation shot has
          // the idle composer).
          await tester.enterText(find.byType(TextField), '帮我看看这个项目的结构');
          await pumpFrames(tester, 6);
          await _dump(tester, shot, '$id-$mode-empty.png');
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
