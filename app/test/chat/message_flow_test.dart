// In-chat message actions end to end on the chat screen: the reply row's ↻
// (重新回答: fork just before the prompt, open the fork, send the prompt
// there — text and images — and give it back to that composer if the send
// fails) and ⋯ (the same menu as a long-press); 引用 (the chip above the
// composer, sent as a blockquote, shown as a quote in the bubble, split back
// out on 编辑后重发); and 保存到相册 on a picture in a message.

import 'package:dsh_app/state/attachments.dart' show sessionImageProvider;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/quote_chip.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _question = '帮我看看测试为什么失败';
const _answer = '是**超时重试**多发了一次请求。';

UserChatItem _user(
  int seq,
  String text, {
  List<ImageAttachment> images = const [],
  List<FileAttachment> files = const [],
}) => UserChatItem(seq: seq, time: DateTime(2026, 10, 24, 9), text: text, images: images, files: files);

AssistantChatItem _assistant(int seq, String text) =>
    AssistantChatItem(id: 'a$seq', seq: seq, time: DateTime(2026, 10, 24, 9), text: text, reasoning: '');

ChatState _state({UserChatItem? prompt}) =>
    ChatState(items: [prompt ?? _user(1, _question), _assistant(2, _answer)], title: '测试失败', loading: false);

const _image = ImageAttachment(attachmentId: 'i1', mediaType: 'image/png', name: '截图.png');

/// The chat screen on [state]; the last reply's turn is over (branchable).
Future<ChatHarness> _pump(
  WidgetTester tester, {
  ChatState? state,
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state ?? _state()});
  await tester.pumpWidget(
    testApp(const ChatScreen(), brightness: brightness, overrides: [...harness.overrides, ...overrides]),
  );
  await pumpFrames(tester);
  final chat = harness.controllers['s1']!;
  chat.branchPoints[2] = 7;
  chat.emit(chat.state.copyWith());
  await pumpFrames(tester);
  return harness;
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

List<String> _composerTexts(WidgetTester tester) => [
  for (final field in tester.widgetList<TextField>(find.byType(TextField))) field.controller?.text ?? '',
];

Finder _lastReply() => find.byType(AssistantMessage).last;

void main() {
  setUpAll(loadTestFonts);

  group('重新回答', () {
    testWidgets('forks before the prompt, opens the fork, sends it there', (tester) async {
      final harness = await _pump(tester);
      expect(find.byTooltip('重新回答'), findsOneWidget);
      await tester.tap(find.byTooltip('重新回答'));
      await pumpFrames(tester);

      final source = harness.controllers['s1']!;
      expect(source.edited, [1]);
      expect(source.forkActions, ['重新回答失败']);
      expect(_container(tester).read(currentSessionProvider), 'fork-session');
      expect(find.text('已在新对话中重新回答'), findsOneWidget);
      final fork = harness.controllers['fork-session']!;
      expect(fork.sent, [_question]);
      expect(fork.sentAttachments.single, isEmpty);
      // Nothing waits in the fork's composer: it went out.
      expect(_composerTexts(tester), isNot(contains(_question)));

      await tester.tap(find.text('返回原对话'));
      await pumpFrames(tester);
      expect(_container(tester).read(currentSessionProvider), 's1');
    });

    testWidgets('the prompt\'s images go again, read back from the session', (tester) async {
      final harness = await _pump(
        tester,
        state: _state(prompt: _user(1, '看看这张图', images: const [_image])),
        overrides: [sessionImageProvider.overrideWith((ref, key) async => tinyPng)],
      );
      await tester.tap(find.byTooltip('重新回答'));
      await pumpFrames(tester);
      final sent = harness.controllers['fork-session']!.sentAttachments.single;
      expect(sent, hasLength(1));
      expect(sent.single.name, '截图.png');
      expect(sent.single.mediaType, 'image/png');
      expect(sent.single.bytes, tinyPng);
    });

    testWidgets('an image that cannot be read back: no fork, the reason', (tester) async {
      final harness = await _pump(
        tester,
        state: _state(prompt: _user(1, '看看这张图', images: const [_image])),
        overrides: [sessionImageProvider.overrideWith((ref, key) async => throw StateError('gone'))],
      );
      await tester.tap(find.byTooltip('重新回答'));
      await pumpFrames(tester);
      final source = harness.controllers['s1']!;
      expect(source.edited, isEmpty);
      expect(source.reported, ['读取原图失败，请重试']);
      expect(_container(tester).read(currentSessionProvider), 's1');
    });

    testWidgets('a failed send waits in the fork\'s composer', (tester) async {
      final harness = await _pump(tester);
      // The fork's controller exists before the send reaches it.
      _container(tester).read(chatProvider('fork-session').notifier);
      harness.controllers['fork-session']!.sendResult = Future.value(false);
      await tester.tap(find.byTooltip('重新回答'));
      await pumpFrames(tester);
      expect(harness.controllers['fork-session']!.sent, [_question]);
      expect(_container(tester).read(currentSessionProvider), 'fork-session');
      expect(_composerTexts(tester), contains(_question));
    });

    testWidgets('a failed fork stays put', (tester) async {
      final harness = await _pump(tester);
      harness.controllers['s1']!.forkOutcome = null;
      await tester.tap(find.byTooltip('重新回答'));
      await pumpFrames(tester);
      expect(_container(tester).read(currentSessionProvider), 's1');
      expect(harness.controllers.containsKey('fork-session'), isFalse);
    });

    testWidgets('not offered for a prompt with files, or while one runs', (tester) async {
      await _pump(
        tester,
        state: _state(
          prompt: _user(
            1,
            '看看这个表',
            files: const [FileAttachment(attachmentId: 'f1', name: 'a.xlsx')],
          ),
        ),
      );
      expect(find.byTooltip('重新回答'), findsNothing);
      // Branching is still there.
      expect(find.byTooltip('从这里分叉'), findsOneWidget);
    });

    testWidgets('also in the long-press menu, with the same result', (tester) async {
      final harness = await _pump(tester);
      await tester.longPress(find.textContaining('多发了一次请求', findRichText: true).first);
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(SettingsTile, '重新回答'));
      await pumpFrames(tester);
      expect(harness.controllers['fork-session']!.sent, [_question]);
    });
  });

  testWidgets('⋯ opens the same menu as a long-press', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('更多'));
    await pumpFrames(tester);
    for (final label in ['复制', '选择文字', '引用', '分享', '重新回答', '从这里分叉']) {
      expect(find.widgetWithText(SettingsTile, label), findsOneWidget);
    }
    expect(find.widgetWithText(SettingsTile, '分享图片'), findsNothing, reason: 'one 分享 for every form');
  });

  group('引用', () {
    testWidgets('quote a reply, ask, and it goes as a blockquote', (tester) async {
      final harness = await _pump(tester);
      await tester.tap(find.byTooltip('更多'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(SettingsTile, '引用'));
      await pumpFrames(tester);
      expect(find.descendant(of: find.byType(QuoteChip), matching: find.text('是超时重试多发了一次请求。')), findsOneWidget);

      await tester.enterText(find.byType(TextField), '为什么会重试？');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, ['> $_answer\n\n为什么会重试？']);
      expect(find.byType(QuoteChip), findsNothing);
    });

    testWidgets('✕ drops the quote; a quote alone does not send', (tester) async {
      final harness = await _pump(tester);
      await tester.longPress(find.textContaining('多发了一次请求', findRichText: true).first);
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(SettingsTile, '引用'));
      await pumpFrames(tester);
      await tester.tap(find.byIcon(AppIcons.send), warnIfMissed: false);
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, isEmpty);
      await tester.tap(find.bySemanticsLabel('移除引用'));
      await pumpFrames(tester);
      expect(find.byType(QuoteChip), findsNothing);
    });

    testWidgets('a failed send gives the quote back as the chip', (tester) async {
      final harness = await _pump(tester);
      harness.controllers['s1']!.sendResult = Future.value(false);
      await tester.tap(find.byTooltip('更多'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(SettingsTile, '引用'));
      await pumpFrames(tester);
      await tester.enterText(find.byType(TextField), '为什么？');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, ['> $_answer\n\n为什么？']);
      expect(find.byType(QuoteChip), findsOneWidget);
      expect(_composerTexts(tester), contains('为什么？'));
    });

    testWidgets('the sent message shows its quote; 编辑后重发 splits it back', (tester) async {
      final quoted = _user(1, '> 第一次在 30 秒时超时\n\n那为什么会重试？');
      final harness = await _pump(tester, state: _state(prompt: quoted));
      expect(find.byType(BubbleQuote), findsOneWidget);
      expect(find.text('第一次在 30 秒时超时'), findsOneWidget);
      expect(find.text('那为什么会重试？'), findsOneWidget);

      await tester.longPress(find.text('那为什么会重试？'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(SettingsTile, '编辑后重发'));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.edited, [1]);
      expect(_container(tester).read(currentSessionProvider), 'fork-session');
      expect(_composerTexts(tester), contains('那为什么会重试？'));
      expect(find.descendant(of: find.byType(QuoteChip), matching: find.text('第一次在 30 秒时超时')), findsOneWidget);
    });
  });

  testWidgets('long-press a sent picture: 保存到相册', (tester) async {
    final saved = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dsh/media'), (call) async {
      saved.add(call);
      return 'Pictures/DSH Go/截图.png';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dsh/media'), null),
    );
    await _pump(
      tester,
      state: _state(prompt: _user(1, '看看这张图', images: const [_image])),
      overrides: [sessionImageProvider.overrideWith((ref, key) async => tinyPng)],
    );
    await tester.longPress(find.bySemanticsLabel('图片').first);
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(SettingsTile, '保存到相册'));
    await pumpFrames(tester);
    expect(saved.single.method, 'saveImage');
    final args = saved.single.arguments as Map;
    expect(args['name'], '截图.png');
    expect(args['bytes'], tinyPng);
    expect(find.text('已保存到相册'), findsOneWidget);
  });

  testWidgets('the row: ↻ and ⋯ are the same 36 keys, in one line', (tester) async {
    await _pump(tester);
    Rect key(String tooltip) =>
        tester.getRect(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)).first);
    final copy = key('复制');
    final branch = key('从这里分叉');
    final regenerate = key('重新回答');
    final more = key('更多');
    for (final r in [branch, regenerate, more]) {
      expect(r.size, copy.size);
      expect(r.center.dy, moreOrLessEquals(copy.center.dy, epsilon: 0.5));
    }
    expect(copy.size, const Size.square(36));
    // Side by side, no gaps: the icons keep the row's 8 rhythm.
    expect(regenerate.left, moreOrLessEquals(branch.right, epsilon: 0.5));
    expect(more.left, moreOrLessEquals(regenerate.right, epsilon: 0.5));
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden: the last reply\'s row (${brightness.name})', (tester) async {
      await _pump(tester, brightness: brightness);
      await expectLater(_lastReply(), matchesGoldenFile('goldens/reply_row_${brightness.name}.png'));
    });

    testWidgets('golden: a quoted question\'s bubble (${brightness.name})', (tester) async {
      await _pump(
        tester,
        brightness: brightness,
        state: _state(
          prompt: _user(
            1,
            '> 第一次请求在 30 秒时超时，客户端重试，而服务端其实已经处理完了第一次。\n\n'
            '那该怎么避免重复提交？',
          ),
        ),
      );
      await expectLater(find.byType(UserBubble), matchesGoldenFile('goldens/bubble_quote_${brightness.name}.png'));
    });
  }
}
