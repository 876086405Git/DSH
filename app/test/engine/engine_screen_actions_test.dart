import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';

class _Runtime extends RecordingRuntime {
  _Runtime(super.initial);
  final resets = <ResetKeep>[];
  @override
  Future<void> resetKeeping(ResetKeep keep) async => resets.add(keep);
}

class _Logs extends LocalRuntimeLogsController {
  @override
  List<String> build() => const [];

  void show(String line) => state = [line];
}

void main() {
  Future<_Runtime> pump(WidgetTester tester, RuntimePhase phase, {_Logs? logs}) async {
    final runtime = _Runtime(LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: phase)));
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const EngineScreen(),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          if (logs != null) localRuntimeLogsProvider.overrideWith(() => logs),
          runtimeBridgeProvider.overrideWithValue(FakeBridge()),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      ),
    );
    await tester.pump();
    return runtime;
  }

  testWidgets('log batches update the terminal without rebuilding the engine page', (tester) async {
    final logs = _Logs();
    await pump(tester, RuntimePhase.installed, logs: logs);
    await tester.scrollUntilVisible(find.byType(TerminalCard), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final page = tester.widget<AppPage>(find.byType(AppPage));
    for (var i = 0; i < 4; i++) {
      logs.show('line $i');
      await tester.pump();
      expect(tester.widget<AppPage>(find.byType(AppPage)), same(page));
      expect(tester.widget<TerminalCard>(find.byType(TerminalCard)).lines, ['line $i']);
    }
  });

  testWidgets('stop cancellation leaves engine running, confirmation stops', (tester) async {
    final runtime = await pump(tester, RuntimePhase.running);
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.stops, 0);
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '停止'));
    await tester.pumpAndSettle();
    expect(runtime.stops, 1);
  });

  testWidgets('restart stops then starts', (tester) async {
    final runtime = await pump(tester, RuntimePhase.running);
    await tester.tap(find.text('重启'));
    await tester.pumpAndSettle();
    expect(runtime.stops, 1);
    expect(runtime.starts, ['start']);
  });

  testWidgets('start while installed starts without stop', (tester) async {
    final runtime = await pump(tester, RuntimePhase.installed);
    // The capsule, not the 启动 group under it.
    await tester.tap(find.text('启动').first);
    await tester.pumpAndSettle();
    expect(runtime.stops, 0);
    expect(runtime.starts, ['start']);
  });

  Future<void> openReset(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('重置运行环境'), 500, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('重置运行环境'));
    await tester.pumpAndSettle();
  }

  testWidgets('reset requires confirmation and keeps ui config and skills by default', (tester) async {
    final runtime = await pump(tester, RuntimePhase.running);
    await openReset(tester);
    expect(find.text('会删除对话、工作区、插件和设置，然后重新安装运行环境。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(runtime.resets, isEmpty);
    await openReset(tester);
    // Beyond the choices: what else in /root goes with the runtime.
    expect(find.textContaining('AGENTS.md'), findsOneWidget);
    await tester.tap(find.text('删除并重置'));
    await tester.pumpAndSettle();
    expect(runtime.resets, [const ResetKeep(uiAndSkills: true)]);
  });

  testWidgets('reset options toggle by row and the summary follows them', (tester) async {
    final runtime = await pump(tester, RuntimePhase.running);
    await openReset(tester);
    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value).toList();
    expect(boxes, [true, false]);

    await tester.tap(find.text('保留已装插件和设置'));
    await tester.pump();
    expect(find.text('会删除对话和工作区，然后重新安装运行环境。'), findsOneWidget);
    await tester.tap(find.text('保留界面配置和技能'));
    await tester.pump();
    expect(find.text('会删除对话、工作区、界面配置和技能，然后重新安装运行环境。'), findsOneWidget);
    // The box itself toggles too.
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();

    await tester.tap(find.text('删除并重置'));
    await tester.pumpAndSettle();
    expect(runtime.resets, [const ResetKeep(pluginsAndSettings: true)]);
  });

  testWidgets('reset options line up with the text and are equal rows', (tester) async {
    await pump(tester, RuntimePhase.running);
    await openReset(tester);
    final body = tester.getRect(find.textContaining('会删除'));
    final rows = [
      for (final label in ['保留界面配置和技能', '保留已装插件和设置'])
        tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first),
    ];
    final checks = tester.getRect(find.byType(Checkbox).first);
    final labels = [
      for (final l in ['保留界面配置和技能', '保留已装插件和设置']) tester.getRect(find.text(l)),
    ];
    // The 18dp box paints centred in the checkbox: its left edge is the text's.
    expect(checks.center.dx - 9, moreOrLessEquals(body.left, epsilon: 0.01));
    expect(rows[0].left, moreOrLessEquals(body.left, epsilon: 0.01));
    expect(rows[0].height, moreOrLessEquals(rows[1].height, epsilon: 0.01));
    expect(rows[0].height, greaterThanOrEqualTo(44));
    expect(rows[1].top, moreOrLessEquals(rows[0].bottom, epsilon: 0.01));
    for (var i = 0; i < 2; i++) {
      final box = tester.getRect(find.byType(Checkbox).at(i));
      expect(box.center.dy, moreOrLessEquals(rows[i].center.dy, epsilon: 0.01));
      expect(labels[i].center.dy, moreOrLessEquals(rows[i].center.dy, epsilon: 0.5));
      expect(labels[i].left, moreOrLessEquals(body.left + 18 + 12, epsilon: 0.01));
    }
  });

  test('reset summary lists what goes', () {
    expect(resetDeletes(const ResetKeep()), '对话、工作区、插件、设置、界面配置和技能');
    expect(resetDeletes(ResetKeep.suggested), '对话、工作区、插件和设置');
    expect(resetDeletes(const ResetKeep(pluginsAndSettings: true)), '对话、工作区、界面配置和技能');
    expect(resetDeletes(const ResetKeep(uiAndSkills: true, pluginsAndSettings: true)), '对话和工作区');
  });
}
