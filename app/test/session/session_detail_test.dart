// 对话详情: entry from the chat header, tab switching, the changes and files
// tabs, and goldens (light + dark) of every tab over the synthetic timed
// session (test/chat/support/run_info_fixture.dart). Regenerate with
// `flutter test --update-goldens test/session/session_detail_test.dart`.

import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/diff_page.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/run_info_fixture.dart';
import '../files/support/memory_workspace.dart';

/// Serves fixed projections instead of watching the Host.
class FakePanels extends SessionPanelsController {
  FakePanels(super.sessionId, this.panels);
  final SessionPanels panels;

  @override
  SessionPanels build() => panels;
}

/// An in-memory workspace (test/files/support/memory_workspace.dart).
class FakeWorkspaceFiles extends MemoryWorkspace {
  FakeWorkspaceFiles()
    : super(
        files: {
          'README.md':
              '# Login demo\n\nA tiny Flutter login demo.\n\n## Run\n\n'
              'flutter pub get\nflutter run',
          '.gitignore': 'build/\n',
          'pubspec.yaml': 'name: login_demo\n',
        },
        folders: {'app/lib', 'test'},
        // Another year: the row shows a date, whatever day the test runs.
        modified: DateTime(2024, 3, 2, 10),
      );

  /// Folders listed, in order ('' = the workspace root).
  List<String> get requested => [
    for (final call in calls)
      if (call.startsWith('list ')) call.substring(5),
  ];
}

const _usage = SessionUsage(
  uncachedInput: 10446,
  cacheRead: 126208,
  output: 2532,
  pressureTokens: 21800,
  contextWindow: 1000000,
  systemTokens: 1467,
  toolsTokens: 5157,
  messageTokens: 15176,
  turns: 2,
);

const _goal = SessionGoal(objective: '修好登录的重复提交,并让测试覆盖连点', phase: 'active', roundsStarted: 2, maxRounds: 8);

late FakeWorkspaceFiles _files;

List<Override> _overrides(ChatHarness harness, {SessionPanels? panels}) => [
  ...harness.overrides,
  sessionPanelsProvider.overrideWith2((id) => FakePanels(id, panels ?? SessionPanels.empty)),
  workspaceSourceProvider.overrideWith((ref, id) => _files),
  workspaceRootProvider.overrideWith((ref, id) => null),
];

Future<void> _pumpPage(
  WidgetTester tester, {
  bool finished = false,
  SessionTab tab = SessionTab.trajectory,
  Brightness brightness = Brightness.light,
  SessionPanels? panels,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {'s1': runInfoState(finished: finished)},
    usage: const {'s1': _usage},
  );
  await tester.pumpWidget(
    testApp(
      SessionDetailPage(sessionId: 's1', initialTab: tab),
      brightness: brightness,
      overrides: _overrides(harness, panels: panels),
    ),
  );
  await pumpFrames(tester, 6);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  setUp(() {
    _files = FakeWorkspaceFiles();
    runClock = () => runInfoTestDispatched.add(const Duration(milliseconds: 12300));
  });

  tearDown(() => runClock = DateTime.now);

  group('behaviour', () {
    testWidgets('the header title opens the page; segments switch tabs', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': runInfoState()}, usage: const {'s1': _usage});
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: _overrides(harness)));
      await pumpFrames(tester, 6);
      await tester.tap(find.text('修复登录重复提交'));
      await pumpFrames(tester, 8);
      expect(find.byType(SessionDetailPage), findsOneWidget);
      // The hero: rounds and the three figures.
      expect(find.text('共 2 轮 · 进行中'), findsOneWidget);
      expect(find.text('改动文件'), findsOneWidget);
      // No subagent was ever called: no such tab.
      expect(find.text('子代理'), findsNothing);
      // Newest turn first and open; the older one is collapsed.
      expect(find.text('第 2 轮'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('第 1 轮'),
        200,
        scrollable: find.descendant(of: find.byType(TrajectoryTab), matching: find.byType(Scrollable)).first,
      );
      expect(find.text('第 1 轮'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);

      await tester.tap(find.text('进度'));
      await pumpFrames(tester, 8);
      expect(find.text('跑一遍测试确认'), findsOneWidget);
      expect(find.text('4/5'), findsOneWidget);

      // A screen reader's tap switches too (#157).
      final semantics = tester.ensureSemantics();
      tester.semantics.tap(find.semantics.byLabel('轨迹'));
      await pumpFrames(tester, 8);
      expect(find.text('第 2 轮'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('changes: one row per file across turns → change page', (tester) async {
      await _pumpPage(tester, tab: SessionTab.changes);
      expect(find.text('改动了 3 个文件'), findsOneWidget);
      expect(find.textContaining('第 2 轮'), findsOneWidget);
      await tester.tap(find.text('README.md'));
      await pumpFrames(tester, 8);
      expect(find.byType(ChangeDiffPage), findsOneWidget);
      expect(find.text('对话改动'), findsOneWidget);
    });

    testWidgets('files: browse into a folder, preview a file', (tester) async {
      await _pumpPage(tester, tab: SessionTab.files);
      expect(find.text('pubspec.yaml'), findsOneWidget);
      await tester.tap(find.text('app'));
      await pumpFrames(tester, 4);
      expect(_files.requested, ['', 'app']);
      expect(find.text('lib'), findsOneWidget);
      await tester.tap(find.text('工作区'));
      await pumpFrames(tester, 4);
      await tester.tap(find.text('README.md'));
      await pumpFrames(tester, 8);
      expect(find.byType(FilePreviewPage), findsOneWidget);
      expect(find.textContaining('flutter pub get', findRichText: true), findsWidgets);
    });
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    group('goldens ($suffix)', () {
      for (final tab in [
        SessionTab.trajectory,
        SessionTab.changes,
        SessionTab.files,
        SessionTab.progress,
        SessionTab.context,
      ]) {
        testWidgets(tab.label, (tester) async {
          await _pumpPage(
            tester,
            tab: tab,
            brightness: brightness,
            panels: tab == SessionTab.progress ? const SessionPanels(goal: _goal) : null,
          );
          await expectLater(
            find.byType(SessionDetailPage),
            matchesGoldenFile('goldens/session_${tab.name}_$suffix.png'),
          );
        });
      }
    });
  }
}
