// After a fork (重新回答, 编辑后重发, 从这里分叉) the 「已在新对话中…」
// toast with 返回原对话 floats above the composer — it neither covers it nor
// pushes the layout — and goes away on its own.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/composer_toast.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _question = '帮我看看测试为什么失败';
const _answer = '是**超时重试**多发了一次请求。';

ChatState _state(String prompt) => ChatState(
  items: [
    UserChatItem(seq: 1, time: DateTime(2026, 10, 24, 9), text: prompt, images: const [], files: const []),
    AssistantChatItem(id: 'a2', seq: 2, time: DateTime(2026, 10, 24, 9), text: _answer, reasoning: ''),
  ],
  title: '测试失败',
  loading: false,
);

Future<ChatHarness> _pump(
  WidgetTester tester, {
  String prompt = _question,
  Brightness brightness = Brightness.light,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': _state(prompt)});
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
  await pumpFrames(tester);
  final chat = harness.controllers['s1']!;
  chat.branchPoints[2] = 7;
  chat.emit(chat.state.copyWith());
  await pumpFrames(tester);
  return harness;
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

Rect _toast(WidgetTester tester) =>
    tester.getRect(find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);

double _gap(WidgetTester tester) => tester.getRect(find.byType(Composer)).top - _toast(tester).bottom;

void main() {
  setUpAll(loadTestFonts);

  testWidgets('重新回答: the toast floats above the composer and leaves on its own', (tester) async {
    await _pump(tester);
    final composer = tester.getRect(find.byType(Composer));
    await tester.tap(find.byTooltip('重新回答'));
    await pumpFrames(tester);

    expect(_container(tester).read(currentSessionProvider), 'fork-session');
    expect(find.text('已在新对话中重新回答'), findsOneWidget);
    expect(find.text('返回原对话'), findsOneWidget);
    // Clear of the composer, which stays where it was.
    expect(_gap(tester), moreOrLessEquals(composerToastGap + 8, epsilon: 1));
    expect(tester.getRect(find.byType(Composer)), composer);
    expect(_toast(tester).left, moreOrLessEquals(16, epsilon: 0.5));
    expect(
      _toast(tester).right,
      moreOrLessEquals(tester.view.physicalSize.width / tester.view.devicePixelRatio - 16, epsilon: 0.5),
    );

    // It doesn't wait for 返回原对话 (persist: false).
    await tester.pump(composerToastActionDuration);
    await pumpFrames(tester, 8);
    expect(find.text('返回原对话'), findsNothing);
    expect(_container(tester).read(currentSessionProvider), 'fork-session');
  });

  testWidgets('a conversation left before the toast shows takes the toast with it', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('重新回答'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_container(tester).read(currentSessionProvider), 'fork-session');
    expect(find.text('已在新对话中重新回答'), findsNothing, reason: 'still waiting for the composer');

    _container(tester).read(currentSessionProvider.notifier).select('s1');
    await pumpFrames(tester);
    expect(find.text('已在新对话中重新回答'), findsNothing);
  });

  testWidgets('返回原对话 goes back to the source conversation', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('重新回答'));
    await pumpFrames(tester);
    await tester.tap(find.text('返回原对话'));
    await pumpFrames(tester);
    expect(_container(tester).read(currentSessionProvider), 's1');
  });

  testWidgets('编辑后重发: measured after the text went into the composer', (tester) async {
    const prompt = '第一行：重试的间隔\n第二行：超时的设置\n第三行：日志里看到的';
    await _pump(tester, prompt: prompt);
    await tester.longPress(find.textContaining('第一行'));
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(SettingsTile, '编辑后重发'));
    await pumpFrames(tester);

    expect(_container(tester).read(currentSessionProvider), 'fork-session');
    expect(find.text('已在新对话中打开'), findsOneWidget);
    // The three lines grew the composer; the toast still clears it.
    expect(_gap(tester), greaterThanOrEqualTo(composerToastGap - 0.5));
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: fork toast ($suffix)', (tester) async {
      await _pump(tester, brightness: brightness);
      await tester.tap(find.byTooltip('重新回答'));
      await pumpFrames(tester);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/fork_toast_$suffix.png'));
    });
  }
}
