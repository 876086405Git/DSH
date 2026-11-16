import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart';
import 'golden_harness.dart';

class _Logs extends LocalRuntimeLogsController {
  @override
  List<String> build() => const [];
  void emit(List<String> lines) => state = lines;
}

void main() {
  late _Logs logs;
  Future<RecordingRuntime> pump(
    WidgetTester tester, {
    bool autoStart = true,
    int strikes = 0,
    bool autoSafe = true,
    RuntimePhase phase = RuntimePhase.installed,
    RuntimeFailure? failure,
  }) async {
    logs = _Logs();
    final runtime = RecordingRuntime(
      LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(
          phase: phase,
          bundledVersion: 'r1',
          installedVersion: 'r1',
          strikes: strikes,
          autoSafe: autoSafe,
          failure: failure,
        ),
      ),
    );
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RootGate(home: Scaffold(body: Text('home'))),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          localRuntimeLogsProvider.overrideWith(() => logs),
          settingsProvider.overrideWith(
            () => FakeSettings(AppSettings(loaded: true, apiKey: 'key', autoStartLocal: autoStart)),
          ),
        ],
      ),
    );
    await tester.pump();
    ProviderScope.containerOf(tester.element(find.byType(RootGate))).read(localRuntimeLogsProvider);
    return runtime;
  }

  testWidgets('installed auto starts once across repeated rebuilds', (tester) async {
    final runtime = await pump(tester);
    for (var i = 0; i < 3; i++) {
      logs.emit(['$i']);
      await tester.pump();
    }
    expect(runtime.starts, ['start']);
  });

  testWidgets('auto start disabled does not start', (tester) async {
    final runtime = await pump(tester, autoStart: false);
    expect(runtime.starts, isEmpty);
  });

  testWidgets('two strikes with auto safe disabled waits', (tester) async {
    final runtime = await pump(tester, strikes: 2, autoSafe: false);
    expect(runtime.starts, isEmpty);
  });

  group('a run that didn\'t end cleanly and can\'t say why (HarmonyOS)', () {
    final unclean = RuntimeFailure(kind: FailureKind.killed, at: DateTime(2026), causeUnknown: true);

    testWidgets('the system reclaiming the app isn\'t held against the next start', (tester) async {
      final runtime = await pump(tester, phase: RuntimePhase.error, strikes: 1, autoSafe: false, failure: unclean);
      expect(runtime.starts, ['start']);
    });

    testWidgets('two in a row wait for the person', (tester) async {
      final runtime = await pump(tester, phase: RuntimePhase.error, strikes: 2, autoSafe: false, failure: unclean);
      expect(runtime.starts, isEmpty);
    });
  });

  testWidgets('a killed run with a known cause still waits (Android)', (tester) async {
    final runtime = await pump(
      tester,
      phase: RuntimePhase.error,
      strikes: 1,
      failure: RuntimeFailure(kind: FailureKind.killed, at: DateTime(2026)),
    );
    expect(runtime.starts, isEmpty);
  });

  testWidgets('reset routes back to runtime setup', (tester) async {
    final runtime = await pump(tester);
    runtime.emit(const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.notInstalled)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RuntimeSetupPage), findsOneWidget);
    expect(find.text('home'), findsNothing);
  });
}
