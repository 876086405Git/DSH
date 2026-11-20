// Generation mode (media-generation §4.2, revised 2026-10-28): 生成 in the ＋
// panel only where the host has the media plugin; the mode capsule on the
// composer's edge (left on the composer, 34 high, equal end insets, beside a
// 34 round ⚠ when the permission pill shows); the parameter sheet; and a send
// that is an ordinary message with the parameter header (v1, §4.6). What the
// host offers comes from its catalogue (§4.3): none it can read, no mode.

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/media/generate_mode.dart';
import 'package:dsh_app/ui/chat/media/generate_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/permission_pill.dart';
import 'package:dsh_app/ui/settings/media_settings_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart' show UserChatItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'support.dart';

Future<ChatHarness> pumpGenerate(
  WidgetTester tester, {
  MediaPluginState plugin = MediaPluginState.ready,
  SessionModes modes = const SessionModes(preset: 'workspace-write'),
  MediaCatalog? catalog,
  double scale = 1,
  Brightness brightness = Brightness.light,
  ChatHarness? harness,
}) async {
  SharedPreferences.setMockInitialValues({});
  usePhoneView(tester);
  final h = harness ?? ChatHarness(session: 's1');
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(minScaleFactor: scale, maxScaleFactor: scale, child: const ChatScreen()),
      brightness: brightness,
      overrides: [
        ...h.overrides,
        ...mediaOverrides(plugin: plugin, modes: modes, catalog: catalog),
      ],
    ),
  );
  await pumpFrames(tester);
  return h;
}

Future<void> enterMode(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('添加图片或文件'));
  await pumpFrames(tester);
  await tester.tap(find.text('生成'));
  await pumpFrames(tester);
}

Finder get _capsule => find.byType(GenerateCapsule);

void main() {
  group('entry', () {
    testWidgets('生成 shows where the host has the plugin, and enters image mode', (tester) async {
      await pumpGenerate(tester);
      await enterMode(tester);
      expect(_capsule, findsOneWidget);
      expect(find.descendant(of: _capsule, matching: find.text('图像 · 1:1 · 1 张')), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, '描述你想要的画面…');
    });

    testWidgets('no plugin on the host: no 生成', (tester) async {
      await pumpGenerate(tester, plugin: MediaPluginState.absent);
      await tester.tap(find.bySemanticsLabel('添加图片或文件'));
      await pumpFrames(tester);
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('生成'), findsNothing);
    });

    testWidgets('offered but not installed: 生成 offers 在此主机上安装', (tester) async {
      await pumpGenerate(tester, plugin: MediaPluginState.installable);
      await enterMode(tester);
      expect(_capsule, findsNothing);
      expect(find.text('在此主机上安装'), findsOneWidget);
    });

    testWidgets('the plugin with no service yet: 生成 opens 图像与视频 first', (tester) async {
      await pumpGenerate(tester, catalog: testMediaCatalogWith(services: const []));
      await enterMode(tester);
      expect(find.byType(MediaSettingsPage), findsOneWidget);
      expect(_capsule, findsNothing);
    });

    testWidgets('a switched-off service doesn\'t count: 图像与视频 first', (tester) async {
      await pumpGenerate(
        tester,
        catalog: testMediaCatalogWith(
          services: [testMediaService('ark', '火山方舟', 'doubao-seedream-5-0-pro', enabled: false)],
        ),
      );
      await enterMode(tester);
      expect(find.byType(MediaSettingsPage), findsOneWidget);
      expect(_capsule, findsNothing);
    });

    // CR-722ae3f must-fix 1: no catalogue the app can read, no generation
    // mode — and no built-in models standing in for one.
    for (final (name, catalog) in [
      ('missing', () => testMediaCatalogWith(catalog: null)),
      ('damaged', () => testMediaCatalogWith(catalog: {'v': 1, 'models': 'gpt-image-2'})),
      ('of an unknown version', () => testMediaCatalogWith(catalog: {...testCatalogMeta(), 'v': 2})),
    ]) {
      testWidgets('a catalogue $name: 生成 says the mode is unavailable; chat goes on', (tester) async {
        final harness = await pumpGenerate(tester, catalog: catalog());
        await enterMode(tester);
        expect(_capsule, findsNothing);
        expect(find.text('生成模式不可用'), findsOneWidget);
        expect(find.text('这台主机的图像与视频插件版本不兼容。仍可直接在对话里描述想要的画面。'), findsOneWidget);
        await tester.tapAt(const Offset(195, 100));
        await pumpFrames(tester);
        await tester.enterText(find.byType(TextField), '画一只猫');
        await tester.pump();
        await tester.tap(find.byIcon(AppIcons.send));
        await pumpFrames(tester);
        expect(harness.controllers['s1']!.sent, ['画一只猫']);
      });
    }

    testWidgets('a host with pictures only: no [图像 | 视频] in the sheet', (tester) async {
      await pumpGenerate(
        tester,
        catalog: testMediaCatalogWith(
          services: [
            testMediaService('ark', '火山方舟', 'doubao-seedream-5-0-pro'),
            testMediaService('bailian', '阿里云百炼', 'qwen-image-3.0-pro'),
          ],
        ),
      );
      await enterMode(tester);
      await tester.tap(_capsule);
      await pumpFrames(tester);
      expect(find.byType(GenerateSheet), findsOneWidget);
      expect(find.text('视频'), findsNothing);
      expect(find.text('比例'), findsOneWidget);
    });

    testWidgets('× leaves the mode and keeps the text', (tester) async {
      await pumpGenerate(tester);
      await enterMode(tester);
      await tester.enterText(find.byType(TextField), '橘猫');
      await tester.tap(find.bySemanticsLabel('退出生成'));
      await pumpFrames(tester);
      expect(_capsule, findsNothing);
      expect(find.text('橘猫'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, '给 DSH 发消息…');
    });
  });

  group('round trip', () {
    // What the app sends: no edge whitespace (typed text is trimmed), inner
    // blank lines and indentation kept.
    const sent = '〔生成图像 · 16:9 · 2 张 · 质量=1k · 通义千问图像 3.0〈bailian/qwen-image-3.0-pro〉〕\n一只猫\n\n  在窗台上';

    Future<ChatHarness> pumpSent(WidgetTester tester, String text, {MediaCatalog? catalog}) => pumpGenerate(
      tester,
      catalog: catalog,
      harness: ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            items: [
              UserChatItem(seq: 1, time: DateTime(2026, 10, 28, 9), text: text, images: const [], files: const []),
            ],
            loading: false,
          ),
        },
      ),
    );

    Future<void> editAndResend(WidgetTester tester, String shown) async {
      await tester.longPress(find.text(shown));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(SettingsTile, '编辑后重发'));
      await pumpFrames(tester);
      // The fork's own toast would hold the queue for a few seconds.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await pumpFrames(tester);
    }

    testWidgets('编辑后重发: the same header and description go again, byte for byte', (tester) async {
      final harness = await pumpSent(tester, sent);
      await editAndResend(tester, '一只猫\n\n  在窗台上');
      expect(find.descendant(of: _capsule, matching: find.text('图像 · 16:9 · 2 张')), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '一只猫\n\n  在窗台上');
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['fork-session']!.sent, [sent]);
    });

    testWidgets('a name two services share is not guessed: 请选择, and nothing goes until one is picked', (tester) async {
      final twin = testMediaCatalogWith(
        services: [...testMediaServices(), testMediaService('home', '家里', 'qwen-image-3.0-pro')],
      );
      final harness = await pumpSent(tester, '〔生成图像 · 16:9 · 通义千问图像 3.0〕\n猫', catalog: twin);
      await editAndResend(tester, '猫');
      expect(_capsule, findsOneWidget);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['fork-session']?.sent ?? const <String>[], isEmpty);
      expect(find.text('先选一个模型'), findsOneWidget);

      await tester.tap(_capsule);
      await pumpFrames(tester);
      expect(find.descendant(of: find.byType(GenerateSheet), matching: find.text('请选择')), findsOneWidget);
      await tester.tap(find.text('模型'));
      await pumpFrames(tester);
      expect(find.text('阿里云百炼'), findsOneWidget);
      expect(find.text('家里'), findsOneWidget);
      await tester.tap(find.text('通义千问图像 3.0').last);
      await pumpFrames(tester);
      await tester.tapAt(const Offset(195, 100));
      await pumpFrames(tester);
      // The toast sits over the send key.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await pumpFrames(tester);
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['fork-session']!.sent, [
        '〔生成图像 · 16:9 · 1 张 · 通义千问图像 3.0〈home/qwen-image-3.0-pro〉〕\n猫',
      ]);
    });

    testWidgets('where the host can\'t generate, 编辑后重发 keeps the whole message, header and all', (tester) async {
      await pumpSent(tester, sent, catalog: testMediaCatalogWith(catalog: {...testCatalogMeta(), 'v': 2}));
      await editAndResend(tester, '一只猫\n\n  在窗台上');
      expect(_capsule, findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, sent);
    });
  });

  group('geometry', () {
    for (final scale in [1.0, 1.3]) {
      testWidgets('capsule: on the composer\'s left edge, 34 high, 12 at both ends (×$scale)', (tester) async {
        await pumpGenerate(tester, scale: scale);
        await enterMode(tester);
        final capsule = tester.getRect(_capsule);
        final composer = tester.getRect(find.byType(Composer));
        expect(capsule.left, moreOrLessEquals(composer.left, epsilon: 0.01));
        expect(capsule.height, GenerateCapsuleMetrics.height);
        expect(composer.top - capsule.bottom, moreOrLessEquals(8, epsilon: 0.01));
        final icon = tester.getRect(find.descendant(of: _capsule, matching: find.byIcon(AppIcons.generateImage)));
        final exit = tester.getRect(find.byKey(const ValueKey('generate-exit')));
        expect(icon.left - capsule.left, moreOrLessEquals(GenerateCapsuleMetrics.inset, epsilon: 0.01));
        expect(capsule.right - exit.right, moreOrLessEquals(GenerateCapsuleMetrics.inset, epsilon: 0.01));
        expect(icon.size, exit.size);
        expect(icon.center.dy, moreOrLessEquals(capsule.center.dy, epsilon: 0.01));
        expect(exit.center.dy, moreOrLessEquals(capsule.center.dy, epsilon: 0.01));
      });

      testWidgets('with the permission pill: a 34 round ⚠ first, the capsule 8 after it, both one height (×$scale)', (
        tester,
      ) async {
        await pumpGenerate(
          tester,
          modes: const SessionModes(preset: 'danger-full-access'),
          scale: scale,
        );
        await enterMode(tester);
        final pill = tester.getRect(find.byType(PermissionPill));
        final capsule = tester.getRect(_capsule);
        final composer = tester.getRect(find.byType(Composer));
        expect(pill.size, const Size.square(PermissionPillMetrics.height));
        expect(pill.left, moreOrLessEquals(composer.left, epsilon: 0.01));
        expect(capsule.left - pill.right, moreOrLessEquals(GenerateCapsuleMetrics.gap, epsilon: 0.01));
        expect(capsule.top, pill.top);
        expect(capsule.height, pill.height);
        final glyph = tester.getRect(
          find.descendant(of: find.byType(PermissionPill), matching: find.byIcon(AppIcons.permissionRisky)),
        );
        expect(glyph.center.dx, moreOrLessEquals(pill.center.dx, epsilon: 0.01));
        expect(glyph.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.01));
      });
    }
  });

  group('sheet', () {
    testWidgets('the capsule opens it; choices apply at once; video has length and no sound', (tester) async {
      await pumpGenerate(tester);
      await enterMode(tester);
      await tester.tap(_capsule);
      await pumpFrames(tester);
      expect(find.byType(GenerateSheet), findsOneWidget);
      expect(find.text('约 ¥0.30'), findsOneWidget);
      await tester.tap(find.text('3:4'));
      await pumpFrames(tester);
      await tester.tap(find.descendant(of: find.byType(GenerateSheet), matching: find.text('2')));
      await pumpFrames(tester);
      expect(find.text('约 ¥0.60'), findsOneWidget);
      expect(find.descendant(of: _capsule, matching: find.text('图像 · 3:4 · 2 张')), findsOneWidget);

      await tester.tap(find.text('视频'));
      await pumpFrames(tester);
      expect(find.text('时长'), findsOneWidget);
      // Header v1 has no sound field: nothing to switch (§4.6.4).
      expect(find.text('声音'), findsNothing);
      expect(find.text('约 ¥4'), findsOneWidget);
      expect(find.descendant(of: _capsule, matching: find.text('视频 · 5 秒 · 720p')), findsOneWidget);
    });

    testWidgets('quality starts on 自动, which leaves it to the host; a pick goes as its own value', (tester) async {
      final harness = await pumpGenerate(tester);
      await enterMode(tester);
      await tester.tap(_capsule);
      await pumpFrames(tester);
      for (final word in ['自动', '标准', '高清', '4K']) {
        expect(find.descendant(of: find.byType(GenerateSheet), matching: find.text(word)), findsOneWidget);
      }
      await tester.tap(find.text('高清'));
      await pumpFrames(tester);
      await tester.tapAt(const Offset(195, 100));
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField), '猫');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, [
        '〔生成图像 · 1:1 · 1 张 · 质量=2k · Seedream 5.0〈ark/doubao-seedream-5-0-pro〉〕\n猫',
      ]);
    });

    testWidgets('a model with empty option sets: no aspect, no quality, nothing made up', (tester) async {
      final bare = testMediaCatalogWith(
        catalog: {
          'v': 1,
          'capabilities': {'image': true, 'video': false},
          'models': [
            {
              'id': 'gemini-2.5-flash-image',
              'label': 'Gemini 2.5 Flash Image',
              'kind': 'image',
              'ratios': <Object?>[],
              'qualities': <Object?>[],
              'maxN': 1,
            },
          ],
        },
        services: [testMediaService('google', 'Google', 'gemini-2.5-flash-image')],
      );
      final harness = await pumpGenerate(tester, catalog: bare);
      await enterMode(tester);
      expect(find.descendant(of: _capsule, matching: find.text('图像 · 1 张')), findsOneWidget);
      await tester.tap(_capsule);
      await pumpFrames(tester);
      expect(find.text('比例'), findsNothing);
      expect(find.text('清晰度'), findsNothing);
      expect(find.text('数量'), findsNothing);
      await tester.tapAt(const Offset(195, 100));
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField), '猫');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, [
        '〔生成图像 · 1 张 · Gemini 2.5 Flash Image〈google/gemini-2.5-flash-image〉〕\n猫',
      ]);
    });

    testWidgets('模型 is a page of its own, by service, with 管理 at the end', (tester) async {
      await pumpGenerate(tester);
      await enterMode(tester);
      await tester.tap(_capsule);
      await pumpFrames(tester);
      await tester.tap(find.text('模型'));
      await pumpFrames(tester);
      expect(find.text('火山方舟'), findsOneWidget);
      expect(find.text('阿里云百炼'), findsOneWidget);
      expect(find.text('¥0.30 / 张'), findsOneWidget);
      expect(find.text('管理'), findsOneWidget);
      await tester.tap(find.text('通义千问图像 3.0'));
      await pumpFrames(tester);
      // Back on the first page, the model's own choices.
      expect(find.text('9:16'), findsNothing);
      expect(find.text('16:9'), findsOneWidget);
    });
  });

  group('send', () {
    testWidgets('an ordinary message with the header; the mode stays for the next batch', (tester) async {
      final harness = await pumpGenerate(tester);
      await enterMode(tester);
      await tester.enterText(find.byType(TextField), '  画一只在窗台上打盹的橘猫 ');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      // Header v1 (§4.6): quality 自动 is left out; the model carries its marker.
      expect(harness.controllers['s1']!.sent, [
        '〔生成图像 · 1:1 · 1 张 · Seedream 5.0〈ark/doubao-seedream-5-0-pro〉〕\n画一只在窗台上打盹的橘猫',
      ]);
      expect(_capsule, findsOneWidget);
    });

    testWidgets('a picture for a model that takes none: nothing goes, and it says so', (tester) async {
      final harness = ChatHarness(session: 's1')..picker.images = [DraftAttachment.sniff('a.png', tinyPng)];
      await pumpGenerate(
        tester,
        harness: harness,
        catalog: testMediaCatalogWith(services: [testMediaService('bailian', '阿里云百炼', 'qwen-image-3.0-pro')]),
      );
      await enterMode(tester);
      await tester.tap(find.bySemanticsLabel('添加图片或文件'));
      await pumpFrames(tester);
      await tester.tap(find.text('相册'));
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField), '换成油画');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']?.sent ?? const <String>[], isEmpty);
      expect(find.text('这个模型不支持参考图'), findsOneWidget);
    });

    testWidgets('a description past 4096 bytes: nothing goes, and it says so', (tester) async {
      final harness = await pumpGenerate(tester);
      await enterMode(tester);
      await tester.enterText(find.byType(TextField), '猫' * 1366);
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']?.sent ?? const <String>[], isEmpty);
      expect(find.text('描述太长，删短一些再生成'), findsOneWidget);
    });

    testWidgets('reference pictures go as attachments; video labels them 首帧 and 尾帧', (tester) async {
      final harness = ChatHarness(session: 's1')
        ..picker.images = [DraftAttachment.sniff('a.png', tinyPng), DraftAttachment.sniff('b.png', tinyPng)];
      await pumpGenerate(tester, harness: harness);
      await enterMode(tester);
      await tester.tap(_capsule);
      await pumpFrames(tester);
      await tester.tap(find.text('视频'));
      await pumpFrames(tester);
      await tester.tapAt(const Offset(195, 100));
      await pumpFrames(tester);
      await tester.tap(find.bySemanticsLabel('添加图片或文件'));
      await pumpFrames(tester);
      await tester.tap(find.text('相册'));
      await pumpFrames(tester);
      expect(find.text('首帧'), findsOneWidget);
      expect(find.text('尾帧'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '镜头推近');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      // This model takes no last frame: the send waits and says so.
      expect(harness.controllers['s1']?.sent ?? const <String>[], isEmpty);
      expect(find.text('这个模型不支持尾帧'), findsOneWidget);
    });

    testWidgets('nothing described: nothing sent', (tester) async {
      final harness = await pumpGenerate(tester);
      await enterMode(tester);
      await tester.tap(find.byIcon(AppIcons.send), warnIfMissed: false);
      await pumpFrames(tester);
      expect(harness.controllers['s1']?.sent ?? const <String>[], isEmpty);
    });
  });

  group('goldens', () {
    for (final brightness in Brightness.values) {
      final suffix = brightness.name;
      testWidgets('capsule beside the permission ⚠ ($suffix)', (tester) async {
        await pumpGenerate(
          tester,
          modes: const SessionModes(preset: 'danger-full-access'),
          brightness: brightness,
        );
        await enterMode(tester);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/generate_capsule_$suffix.png'));
      });

      testWidgets('generation mode unavailable ($suffix)', (tester) async {
        await pumpGenerate(
          tester,
          brightness: brightness,
          catalog: testMediaCatalogWith(catalog: {'v': 2}),
        );
        await enterMode(tester);
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/generate_unavailable_$suffix.png'));
      });

      testWidgets('parameter sheet, image ($suffix)', (tester) async {
        await pumpGenerate(tester, brightness: brightness);
        await enterMode(tester);
        await tester.tap(_capsule);
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/generate_sheet_image_$suffix.png'));
      });

      testWidgets('parameter sheet, video ($suffix)', (tester) async {
        await pumpGenerate(tester, brightness: brightness);
        await enterMode(tester);
        await tester.tap(_capsule);
        await pumpFrames(tester);
        await tester.tap(find.text('视频'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/generate_sheet_video_$suffix.png'));
      });

      testWidgets('320dp at 1.3×: capsule and sheet ($suffix)', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(640, 1500);
        tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
        tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
        addTearDown(tester.view.reset);
        final h = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)});
        await tester.pumpWidget(
          testApp(
            MediaQuery.withClampedTextScaling(minScaleFactor: 1.3, maxScaleFactor: 1.3, child: const ChatScreen()),
            brightness: brightness,
            overrides: [
              ...h.overrides,
              ...mediaOverrides(modes: const SessionModes(preset: 'auto')),
            ],
          ),
        );
        await pumpFrames(tester);
        await enterMode(tester);
        // The capsule beside the ⚠, the summary cut before it wraps.
        await tester.enterText(find.byType(TextField), '一只橘猫');
        await pumpFrames(tester, 4);
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/generate_320_capsule_$suffix.png'));
        await tester.tap(_capsule);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/generate_320_sheet_$suffix.png'));
      });
    }
  });
}
