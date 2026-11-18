// The media card (media-generation §5.1–§5.4), against the synthetic v1
// fixtures: parsing, placement in the chat (cardOnly after a folded turn),
// the reply's same-path image left out, geometry, the metadata line, save /
// share from the original bytes, the viewer, and goldens.

import 'package:dsh_app/ui/fx/image_gen/image_generation.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/features_state.dart' show jobsProvider;
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/media/generate_mode.dart' show GenerateCapsule;
import 'package:dsh_app/ui/chat/media/media_card.dart';
import 'package:dsh_app/ui/chat/media/media_format.dart' show chatTitleShown;
import 'package:dsh_app/ui/chat/media/media_grid.dart';
import 'package:dsh_app/ui/chat/media/media_viewer.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'support.dart';

/// The chat page on [fixture]'s conversation, its pictures served.
Future<ChatHarness> pumpConversation(
  WidgetTester tester,
  String fixture, {
  Brightness brightness = Brightness.light,
  double width = 390,
  double height = 844,
  double scale = 1,
  List<Override> extra = const [],
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.padding = FakeViewPadding(top: height > width ? 48 : 0, bottom: height > width ? 32 : 0);
  tester.view.viewPadding = FakeViewPadding(top: height > width ? 48 : 0, bottom: height > width ? 32 : 0);
  addTearDown(tester.view.reset);
  final transcript = fixtureTranscript(fixture);
  final metas = [for (final t in transcript.items.whereType<ToolChatItem>()) ?toolMedia(t)];
  final pictures = (await tester.runAsync(() => picturesFor(metas)))!;
  final harness = ChatHarness(
    session: 's1',
    states: {'s1': ChatState(loading: false, items: transcript.items, turns: transcript.turns)},
  );
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(minScaleFactor: scale, maxScaleFactor: scale, child: const ChatScreen()),
      brightness: brightness,
      overrides: [
        ...harness.overrides,
        workspaceImageReaderProvider.overrideWithValue(CachedImageReader(FakeMediaReader(pictures))),
        jobsProvider.overrideWith((ref, id) => const Stream.empty()),
        ...extra,
      ],
    ),
  );
  await pumpFrames(tester);
  await settlePictures(tester, find.byType(MediaCard));
  return harness;
}

void main() {
  group('the v1 meta', () {
    test('a header request: two 3:4 pictures, the cost, the rewrite', () {
      final media = toolMedia(fixtureTool('synthetic_header_image'))!;
      expect(media.version, 1);
      expect(media.rid, 'm_7f3a9c');
      expect(media.kind, MediaKind.image);
      expect(media.status, MediaStatus.done);
      expect(media.items, hasLength(2));
      expect(media.items.first.path, '/root/workspace/generated/2026-10-28/cat-1.png');
      expect(media.items.first.aspect, 0.75);
      expect(media.request.modelName, 'Seedream 5.0');
      expect(media.request.ratio, 0.75);
      expect(media.cost!.estimate, 0.6);
      expect(media.promptToCopy, startsWith('午后逆光'));
      expect(media.provenance!.c2pa, isTrue);
    });

    test('a plain request carries no cost', () {
      final media = toolMedia(fixtureTool('synthetic_plain_image'))!;
      expect(media.items.single.width, 2048);
      expect(media.cost, isNull);
    });

    test('a running video and a refusal are cards too', () {
      final video = toolMedia(fixtureTool('synthetic_video_running'))!;
      expect(video.status, MediaStatus.running);
      expect(video.kind, MediaKind.video);
      expect(video.job, 'media-1c2d');
      final failed = toolMedia(fixtureTool('synthetic_failed'))!;
      expect(failed.status, MediaStatus.failed);
      expect(failed.error!.code, 'policy');
    });

    test('unreadable metas are no card', () {
      expect(MediaMeta.fromToolMeta({'other': 1}), isNull);
      expect(MediaMeta.fromToolMeta({'dsh-go/media': 'x'}), isNull);
      expect(
        MediaMeta.fromToolMeta({
          'dsh-go/media': {'v': 1, 'status': 'done', 'items': []},
        }),
        isNull,
      );
      expect(
        MediaMeta.fromToolMeta({
          'dsh-go/media': {
            'v': 1,
            'kind': 'image',
            'status': 'done',
            'items': [{}],
          },
        }),
        isNull,
      );
    });
  });

  group('rows', () {
    test('a finished turn folds the call, the card stays outside before the answer', () {
      final t = fixtureTranscript('synthetic_header_image');
      final rows = deriveRows(items: t.items, turns: t.turns, foldTurns: true);
      expect(rows.map((r) => r.runtimeType).toList(), [UserRow, TurnProcessRow, ToolCallRow, AssistantRow]);
      final card = rows[2] as ToolCallRow;
      expect(card.card, ToolCardPlacement.cardOnly);
      final process = rows[1] as TurnProcessRow;
      expect(process.toolCalls, 1);
      expect((process.rows.single as ToolCallRow).card, ToolCardPlacement.rowOnly);
    });

    test('a media call is never grouped away with others', () {
      final t = fixtureTranscript('synthetic_plain_image');
      expect(hasToolCard(t.items.whereType<ToolChatItem>().single), isTrue);
    });
  });

  group('in the chat', () {
    testWidgets('the request bubble hides its header; the card shows; the reply\'s same image does not', (
      tester,
    ) async {
      await pumpConversation(tester, 'synthetic_header_image');
      expect(find.text('〔生成图像 · 3:4 · 2 张 · Seedream 5.0〕'), findsNothing);
      expect(find.textContaining('画一只在窗台上打盹的橘猫'), findsWidgets);
      expect(find.text('图像 · 3:4 · 2 张'), findsOneWidget);
      expect(find.byType(MediaCard), findsOneWidget);
      expect(find.byType(MediaCell), findsNWidgets(2));
      // The reply names cat-1.png too: drawn once, in the card.
      expect(find.descendant(of: find.byType(MarkdownImage), matching: find.byType(Image)), findsNothing);
      expect(
        find.descendant(of: find.byType(MediaMetaLine), matching: find.text('AI 生成 · Seedream 5.0 · 3:4 · 约 ¥0.60')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a plain request: one square, no cost on the line', (tester) async {
      await pumpConversation(tester, 'synthetic_plain_image');
      expect(find.byType(MediaCell), findsOneWidget);
      expect(
        find.descendant(of: find.byType(MediaMetaLine), matching: find.text('AI 生成 · Seedream 5.0 · 1:1')),
        findsOneWidget,
      );
      expect(find.textContaining('¥'), findsNothing);
    });

    for (final width in [320.0, 390.0]) {
      testWidgets('geometry at ${width.round()}: left on the reply text, under H, meta 8 below, actions 4 below', (
        tester,
      ) async {
        await pumpConversation(tester, 'synthetic_plain_image', width: width);
        final card = tester.getRect(find.byType(MediaCard));
        final cell = tester.getRect(find.byType(MediaCell));
        final reply = tester.getRect(find.byType(AssistantMessage).last);
        expect(cell.left, moreOrLessEquals(reply.left, epsilon: 0.5));
        expect(cell.left, moreOrLessEquals(16, epsilon: 0.5));
        expect(cell.width, moreOrLessEquals(width - 32, epsilon: 0.5));
        expect(cell.height, lessThanOrEqualTo(MediaGridMetrics.maxHeightFor(844) + 0.5));
        final meta = tester.getRect(find.byType(MediaMetaLine));
        expect(meta.top - cell.bottom, moreOrLessEquals(MediaCardMetrics.metaGap, epsilon: 0.5));
        expect(meta.left, moreOrLessEquals(cell.left, epsilon: 0.5));
        final row = tester.getRect(find.byType(MediaActionRow));
        expect(row.top - meta.bottom, moreOrLessEquals(MediaCardMetrics.actionsGap, epsilon: 0.5));
        // The first icon's glyph sits on the text edge (the bar bleeds 8).
        final save = tester.getRect(
          find.descendant(of: find.byType(MediaActionRow), matching: find.byIcon(AppIcons.save)),
        );
        expect(save.left, moreOrLessEquals(cell.left, epsilon: 0.5));
        expect(save.width, MediaCardMetrics.icon);
        final share = tester.getRect(
          find.descendant(of: find.byType(MediaActionRow), matching: find.byIcon(AppIcons.share)),
        );
        expect(share.left - save.right, moreOrLessEquals(16, epsilon: 0.5));
        expect(card.right, lessThanOrEqualTo(width - 16 + 0.5));
      });
    }

    testWidgets('save keeps the files\' own bytes and says how many', (tester) async {
      final saves = mockGallery();
      await pumpConversation(tester, 'synthetic_header_image');
      await tester.tap(find.descendant(of: find.byType(MediaActionRow), matching: find.byIcon(AppIcons.save)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumpFrames(tester);
      expect(saves.map((c) => c.method), ['saveImage', 'saveImage']);
      expect((saves.first.arguments as Map)['name'], 'cat-1.png');
      expect((saves.first.arguments as Map)['mime'], 'image/png');
      expect(find.text('已保存 2 张到相册'), findsOneWidget);
    });

    for (final (cancelAt, line) in [(1, null), (2, '已保存 1 张到相册')]) {
      testWidgets('backing out of the album window at picture $cancelAt: stops asking, and no failure', (tester) async {
        var calls = 0;
        const channel = MethodChannel('dsh/media');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (++calls == cancelAt) throw PlatformException(code: 'cancelled');
          return 'file://media/Photo/$calls/a.png';
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
        await pumpConversation(tester, 'synthetic_header_image');
        await tester.tap(find.descendant(of: find.byType(MediaActionRow), matching: find.byIcon(AppIcons.save)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await pumpFrames(tester);
        expect(calls, cancelAt, reason: 'nothing more is asked');
        expect(find.text('保存失败，请重试'), findsNothing);
        if (line == null) {
          expect(find.byType(SnackBar), findsNothing);
        } else {
          expect(find.text(line), findsOneWidget);
        }
      });
    }

    testWidgets('a running video waits in its shape', (tester) async {
      await pumpConversation(tester, 'synthetic_video_running');
      expect(find.text('生成中'), findsOneWidget);
      // What was asked; 「AI 生成」 is for what was made.
      expect(find.descendant(of: find.byType(MediaMetaLine), matching: find.textContaining('AI 生成')), findsNothing);
      expect(find.descendant(of: find.byType(MediaMetaLine), matching: find.textContaining('5 秒')), findsOneWidget);
      expect(find.byType(MediaActionRow), findsNothing);
      // 16:9 at the column's width.
      final box = tester.getRect(find.descendant(of: find.byType(MediaCard), matching: find.byType(ImageGeneration)));
      expect(box.width / box.height, moreOrLessEquals(16 / 9, epsilon: 0.01));
    });

    testWidgets('a refusal says why', (tester) async {
      await pumpConversation(tester, 'synthetic_failed');
      expect(find.text('描述未通过内容审核'), findsOneWidget);
    });

    testWidgets('修改 on a refusal: the description back in the composer, generation mode on with the card\'s values', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpConversation(tester, 'synthetic_failed', extra: mediaOverrides());
      await tester.tap(find.descendant(of: find.byType(MediaCard), matching: find.text('修改')));
      await pumpFrames(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isNot(contains('〔')));
      expect(field.controller!.text, isNotEmpty);
      expect(find.byType(GenerateCapsule), findsOneWidget);
    });
  });

  group('viewer', () {
    testWidgets('a tap opens it at that picture; swipe goes through the batch; AI 生成 over the capsule', (tester) async {
      await pumpConversation(tester, 'synthetic_header_image');
      await tester.tap(find.byType(MediaCell).last);
      await pumpFrames(tester);
      expect(find.byType(MediaViewerPage), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(300, 0), 1200);
      await pumpFrames(tester);
      expect(find.text('1 / 2'), findsOneWidget);

      final screen = tester.getSize(find.byType(MediaViewerPage));
      final back = tester.getRect(find.byTooltip('返回'));
      final share = tester.getRect(find.byTooltip('分享').last);
      expect(back.left, MediaViewerMetrics.side);
      expect(screen.width - share.right, moreOrLessEquals(MediaViewerMetrics.side, epsilon: 0.5));
      expect(back.top, moreOrLessEquals(24 + MediaViewerMetrics.top, epsilon: 0.5));
      expect(back.height, share.height);
      final label = tester.getRect(
        find.descendant(of: find.byType(MediaViewerPage), matching: find.byType(MediaOverlayLabel)),
      );
      final capsule = tester.getRect(
        find.descendant(of: find.byType(MediaViewerPage), matching: find.byType(GlassSurface)).last,
      );
      expect(capsule.height, MediaViewerMetrics.capsuleHeight);
      expect(capsule.left, MediaViewerMetrics.side);
      expect(screen.width - capsule.right, MediaViewerMetrics.side);
      expect(capsule.top - label.bottom, MediaViewerMetrics.labelGap);
      expect(label.left, capsule.left);
      expect(label.width, lessThan(80), reason: 'the label hugs its text');
      expect(label.height, MediaOverlayLabel.height);
      expect(find.text('复制提示词'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);
    });

    testWidgets('a phone on its side: keys off the safe areas, the capsule at most 400 and centred', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(915 * 2, 412 * 2);
      tester.view.padding = const FakeViewPadding(left: 48 * 2, right: 48 * 2);
      tester.view.viewPadding = const FakeViewPadding(left: 48 * 2, right: 48 * 2);
      addTearDown(tester.view.reset);
      final meta = mediaMeta(n: 2, width: 1536, height: 2048, aspect: '3:4');
      final pictures = (await tester.runAsync(() => picturesFor([meta])))!;
      await tester.pumpWidget(
        testApp(
          MediaViewerPage(sessionId: 's1', meta: meta),
          overrides: [workspaceImageReaderProvider.overrideWithValue(CachedImageReader(FakeMediaReader(pictures)))],
        ),
      );
      await pumpFrames(tester);
      final back = tester.getRect(find.byTooltip('返回'));
      final share = tester.getRect(find.byTooltip('分享'));
      expect(back.left, 48 + MediaViewerMetrics.side);
      expect(915 - share.right, moreOrLessEquals(48 + MediaViewerMetrics.side, epsilon: 0.5));
      final capsule = tester.getRect(
        find.descendant(of: find.byType(MediaViewerPage), matching: find.byType(GlassSurface)).last,
      );
      expect(capsule.width, MediaViewerMetrics.capsuleMaxWidth);
      expect(capsule.center.dx, moreOrLessEquals(915 / 2, epsilon: 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('详情 lists the model, size, cost, provenance and file', (tester) async {
      await pumpConversation(tester, 'synthetic_header_image');
      await tester.tap(find.byType(MediaCell).first);
      await pumpFrames(tester);
      await tester.tap(find.text('详情'));
      await pumpFrames(tester);
      expect(find.text('Seedream 5.0'), findsOneWidget);
      expect(find.text('1536 × 2048'), findsOneWidget);
      expect(find.text('约 ¥0.60'), findsOneWidget);
      expect(find.text('C2PA · 隐式'), findsOneWidget);
      expect(find.text('cat-1.png'), findsOneWidget);
      expect(find.textContaining('原文：画一只在窗台上打盹的橘猫'), findsOneWidget);
    });
  });

  group('header bubble', () {
    Future<void> pumpBubble(WidgetTester tester, String text) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: UserBubble(text: text),
            ),
          ),
        ),
      );
    }

    testWidgets('description as the bubble; the parameters under it, 4 below, 8 in from its right edge', (
      tester,
    ) async {
      await pumpBubble(tester, '〔生成视频 · 5 秒 · 720p · Seedance 2.0〕\n镜头缓慢推近');
      expect(find.text('镜头缓慢推近'), findsOneWidget);
      expect(find.text('视频 · 5 秒 · 720p'), findsOneWidget);
      expect(find.textContaining('〔'), findsNothing);
      final text = find.text('镜头缓慢推近');
      final bubble = tester.getRect(find.ancestor(of: text, matching: find.byType(DecoratedBox)).first);
      final line = tester.getRect(find.byType(GenerateParamsLine));
      expect(find.descendant(of: find.byType(GenerateParamsLine), matching: text), findsNothing);
      expect(line.top - bubble.bottom, moreOrLessEquals(GenerateParamsLine.gap, epsilon: 0.01));
      expect(bubble.right - line.right, moreOrLessEquals(GenerateParamsLine.inset, epsilon: 0.01));
      expect(
        tester.getRect(find.descendant(of: find.byType(GenerateParamsLine), matching: find.byType(Icon))).height,
        12,
      );
    });

    testWidgets('the description exactly as sent: spaces and inner blank lines stay', (tester) async {
      await pumpBubble(tester, '〔生成图像 · 1:1 · 1 张 · 质量=2k · Seedream 5.0〈ark/seedream〉〕\n  缩进的一行\n\n第三行');
      expect(find.text('  缩进的一行\n\n第三行'), findsOneWidget);
      expect(find.text('图像 · 1:1 · 1 张'), findsOneWidget);
    });

    // CR-722ae3f suggestion 1: only a whole, valid header is hidden.
    for (final text in [
      '〔生成图像的方法〕示例',
      '〔生成图像的方法〕\n示例',
      '〔生成图像 · 1:1 · 1 张〕',
      '〔生成图像·1:1·1张〕\n猫',
      ' 〔生成图像 · 1:1〕\n猫',
      '〔生成图像 · 1:1 · 1:1〕\n猫',
      '〔生成图像 · 0:1〕\n猫',
      '〔生成视频 · 2 张〕\n猫',
      '〔生成图像 · 1:1 · 1 张 · 高清 · Seedream 5.0〕\n猫',
    ]) {
      testWidgets('shown as typed: ${text.replaceAll('\n', r'\n')}', (tester) async {
        await pumpBubble(tester, text);
        expect(find.text(text), findsOneWidget);
        expect(find.byType(GenerateParamsLine), findsNothing);
      });
    }
  });

  group('titles', () {
    test('a title that starts with a request shows what follows; a cut-short one, the kind', () {
      expect(chatTitleShown('〔生成图像 · 3:4 · 2 张 · Seedream 5.0〕 画一只橘猫'), '画一只橘猫');
      // DSH's fallback: the first message's leading eight words.
      expect(chatTitleShown('〔生成图像 · 3:4 · 2 张 · Seedream'), '生成图像');
      expect(chatTitleShown('〔生成视频 · 5 秒 · 720p〕'), '生成视频');
      expect(chatTitleShown('窗台上的橘猫'), '窗台上的橘猫');
      expect(chatTitleShown('〔草稿〕周报'), '〔草稿〕周报');
    });

    test('ordinary words that only start like a header stay as they are', () {
      expect(chatTitleShown('〔生成图像的方法〕示例'), '〔生成图像的方法〕示例');
      expect(chatTitleShown('〔生成图像〕这个词是什么意思'), '〔生成图像〕这个词是什么意思');
      expect(chatTitleShown('〔生成视频：教程〕 内容'), '〔生成视频：教程〕 内容');
      expect(chatTitleShown('〔生成图像 · 1:1 · 高清 · Seedream 5.0〕 猫'), '〔生成图像 · 1:1 · 高清 · Seedream 5.0〕 猫');
    });
  });
}
