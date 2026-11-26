// Goldens for the run information (light + dark): the running state with the
// header timer and the activity strip, a finished turn with its footnote and
// change card, the trajectory sheet, the change page and a step detail page.
// Regenerate with
// `flutter test --update-goldens test/chat/run_info_golden_test.dart`.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/diff_page.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart' show DockFoldController;
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/step_detail_page.dart';
import 'package:dsh_app/ui/chat/trajectory_sheet.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/widgets/turn_footnote.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/run_info_fixture.dart';

Future<void> _pumpChat(WidgetTester tester, ChatHarness harness, Brightness brightness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
  await pumpFrames(tester, 10);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  setUp(() {
    // 12.3 s into the running `flutter test` (turn 2 started 19.95 s ago).
    runClock = () => runInfoTestDispatched.add(const Duration(milliseconds: 12300));
    // The strip and the todo bar spread, each with its own job (folded: dock_stack_test).
    SharedPreferences.setMockInitialValues({DockFoldController.key: false});
  });

  tearDown(() => runClock = DateTime.now);

  group('behaviour', () {
    testWidgets('opening a folded turn opens downward from its header', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
      await _pumpChat(tester, harness, Brightness.light);
      final header = find.textContaining('次工具调用');
      final reply = find.textContaining('改好了', findRichText: true);
      final before = tester.getRect(header);
      final answer = tester.getRect(reply);

      await tester.tap(header);
      await pumpFrames(tester, 12);
      // The short history above can only scroll to its top, so the header may
      // rise that far but stays on screen; the process opens below it.
      final opened = tester.getRect(header);
      expect(opened.top, greaterThan(100));
      expect(opened.top, lessThanOrEqualTo(before.top + 1));
      final firstStep = tester.getRect(find.text('思考').first);
      expect(firstStep.top, greaterThan(opened.bottom));
      expect(tester.getRect(reply).top, greaterThan(answer.top + 100));

      await tester.tap(header);
      await pumpFrames(tester, 12);
      expect(tester.getRect(header).top, moreOrLessEquals(before.top, epsilon: 1));
      expect(tester.getRect(reply).top, moreOrLessEquals(answer.top, epsilon: 1));
    });

    testWidgets('running: header timer and the activity strip', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': runInfoState()});
      await _pumpChat(tester, harness, Brightness.light);
      expect(find.text('生成中'), findsOneWidget);
      expect(find.textContaining('生成中 · 0:'), findsNothing);
      expect(find.byType(ActivityStrip), findsOneWidget);
      expect(find.text('跑'), findsOneWidget);
      // The strip counts the turn, like the header.
      expect(find.text('0:19'), findsOneWidget);
      // The todo bar above the strip carries the count (the strip leaves it
      // out).
      expect(find.text('进度 4/5'), findsNothing);
      expect(find.text('4/5 · 正在：跑一遍测试确认'), findsOneWidget);

      // The clock moves the timers only.
      runClock = () => runInfoTestDispatched.add(const Duration(milliseconds: 15300));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:22'), findsOneWidget);
      expect(find.text('生成中'), findsOneWidget);
      expect(find.textContaining('生成中 · 0:'), findsNothing);

      // Tapping the strip opens the running turn's trajectory.
      await tester.tap(find.byType(ActivityStrip));
      await pumpFrames(tester, 8);
      expect(find.byType(TrajectorySheet), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
    });

    testWidgets('footnote → trajectory → step detail → back', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
      await _pumpChat(tester, harness, Brightness.light);
      expect(find.byType(TurnFootnote), findsOneWidget);
      // This width drops the token count before the speed, so the footnote shows
      // the shorter variant even though variants() still offers the full one.
      expect(find.text('1 分 23 秒 · 5 步 · 117 tokens/秒'), findsOneWidget);

      await tester.tap(find.byType(TurnFootnote));
      await pumpFrames(tester, 8);
      expect(find.byType(TrajectorySheet), findsOneWidget);
      expect(find.text('等待确认'), findsOneWidget);
      expect(find.text('等你 48 秒'), findsOneWidget);

      await tester.ensureVisible(find.text('等待确认'));
      await pumpFrames(tester, 2);
      await tester.tap(find.text('等待确认'));
      await pumpFrames(tester, 8);
      expect(find.byType(StepDetailPage), findsOneWidget);
      expect(find.text('flutter test test/auth'), findsWidgets);
      expect(find.text('48 秒 · 允许了'), findsOneWidget);
      expect(find.text('12 秒'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await pumpFrames(tester, 8);
      expect(find.byType(TrajectorySheet), findsOneWidget);
    });

    testWidgets('tool details rebuild for the last matching call, not for unrelated drafts', (tester) async {
      final state = runInfoState();
      final harness = ChatHarness(states: {'s1': state});
      await tester.pumpWidget(
        testApp(
          const StepDetailPage(sessionId: 's1', turn: 1, kind: TraceKind.tool, callId: 'c-write'),
          overrides: harness.overrides,
        ),
      );
      void publish(ChatItem tail) =>
          harness.controllers['s1']!.emit(ChatState(items: [...state.items, tail], turns: state.turns, running: true));
      FactsCard facts() => tester.widget<FactsCard>(find.byType(FactsCard));
      final built = {facts()};
      for (var i = 1; i <= 5; i++) {
        publish(AssistantChatItem(id: 'draft', text: 'x' * i, reasoning: '', streaming: true));
        await tester.pump();
        built.add(facts());
      }
      expect(built, hasLength(1));
      publish(const ToolChatItem(callId: 'c-write', name: 'write', arguments: '{}', status: ToolStatus.running));
      await tester.pump();
      expect(built.contains(facts()), isFalse);
    });

    testWidgets('change card opens the change page; swipe moves the chip', (tester) async {
      final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
      await _pumpChat(tester, harness, Brightness.light);
      await tester.tap(find.text('查看改动'));
      await pumpFrames(tester, 8);
      expect(find.byType(ChangeDiffPage), findsOneWidget);
      // Line numbers come from the read that preceded the edit.
      expect(find.text('第 9 行起'), findsOneWidget);
      expect(find.text('16'), findsWidgets);
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
      await pumpFrames(tester, 8);
      expect(find.text('新建文件'), findsOneWidget);
    });
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    group('goldens ($suffix)', () {
      testWidgets('running turn', (tester) async {
        final harness = ChatHarness(session: 's1', states: {'s1': runInfoState()});
        await _pumpChat(tester, harness, brightness);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/run_running_$suffix.png'));
      });

      testWidgets('finished turn', (tester) async {
        final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
        await _pumpChat(tester, harness, brightness);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/run_finished_$suffix.png'));
      });

      testWidgets('finished turn, process open', (tester) async {
        final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
        await _pumpChat(tester, harness, brightness);
        await tester.tap(find.textContaining('次工具调用'));
        await pumpFrames(tester, 10);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/run_finished_open_$suffix.png'));
      });

      testWidgets('trajectory sheet', (tester) async {
        final harness = ChatHarness(session: 's1', states: {'s1': runInfoState(finished: true)});
        await _pumpChat(tester, harness, brightness);
        await tester.tap(find.byType(TurnFootnote));
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run_trajectory_$suffix.png'));
      });

      testWidgets('trajectory sheet, running', (tester) async {
        final harness = ChatHarness(session: 's1', states: {'s1': runInfoState()});
        await _pumpChat(tester, harness, brightness);
        await tester.tap(find.byType(ActivityStrip));
        await pumpFrames(tester, 10);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run_trajectory_live_$suffix.png'));
      });

      testWidgets('change page', (tester) async {
        usePhoneView(tester);
        final s = runInfoState(finished: true);
        final files = fileChangesOf(s.items.whereType<ToolChatItem>().toList());
        await tester.pumpWidget(testApp(ChangeDiffPage(files: files), brightness: brightness));
        await pumpFrames(tester, 4);
        await expectLater(find.byType(ChangeDiffPage), matchesGoldenFile('goldens/run_diff_$suffix.png'));
      });

      testWidgets('step detail: a command that waited for approval', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = const Size(780, 2000);
        final harness = ChatHarness(states: {'s1': runInfoState(finished: true)});
        await tester.pumpWidget(
          testApp(
            const StepDetailPage(sessionId: 's1', turn: 1, kind: TraceKind.tool, callId: 'c-test'),
            brightness: brightness,
            overrides: harness.overrides,
          ),
        );
        await pumpFrames(tester, 4);
        await expectLater(find.byType(StepDetailPage), matchesGoldenFile('goldens/run_step_tool_$suffix.png'));
      });

      testWidgets('step detail: a model request', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = const Size(780, 2000);
        final harness = ChatHarness(states: {'s1': runInfoState(finished: true)});
        await tester.pumpWidget(
          testApp(
            const StepDetailPage(sessionId: 's1', turn: 1, kind: TraceKind.model, step: 1),
            brightness: brightness,
            overrides: harness.overrides,
          ),
        );
        await pumpFrames(tester, 4);
        await expectLater(find.byType(StepDetailPage), matchesGoldenFile('goldens/run_step_model_$suffix.png'));
      });
    });
  }
}
