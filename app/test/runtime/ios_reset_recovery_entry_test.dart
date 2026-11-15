import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/onboarding/local_install.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onboarding/local_optional_support.dart';
import '../shell/golden_harness.dart';

// Fields emitted by 0130 EngineChannel.snapshot after installed becomes nil,
// when native.phase is still error (or setupError is present). No credentials.
RuntimeStatus snapshot({String phase = 'error', String? installed, String? bundledVersion = bundled}) =>
    RuntimeStatus.fromMap({
      'abi': 'arm64-v8a', 'bundledVersion': bundledVersion,
      'installedVersion': installed, 'phase': phase,
      'error': 'synthetic retained native failure',
      'mode': 'normal', 'safeState': 'off', 'autoSafe': false,
      'failure': null, 'mainFailure': null,
      'launchSelectedMode': 'ios-embedded', 'launchSpawned': true,
    });

class UninstallRuntime extends RecordingLocalRuntime {
  UninstallRuntime() : super(const LocalRuntimeState(loaded: true, status: stoppedStatus));
  @override
  Future<void> resetKeeping(ResetKeep keep) async {
    calls.add('reset:${keep.wire.join(',')}');
    emit(snapshot());
  }
}

Future<void> frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) { await tester.pump(const Duration(milliseconds: 100)); }
}

Future<void> showScreen(WidgetTester tester, RecordingLocalRuntime runtime, String os) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(
    home: const RootGate(home: EngineScreen()), brightness: Brightness.light,
    prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, keySkipped: true, localDeclined: true),
    overrides: [
      operatingSystemProvider.overrideWithValue(os),
      localRuntimeProvider.overrideWith(() => runtime),
      localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => const []),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, autoStartLocal: false))),
      footprint(roomyPhone),
    ],
  ));
  await frames(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('iOS successful uninstall with retained native error can reach install retry', (tester) async {
    final runtime = UninstallRuntime();
    await showScreen(tester, runtime, 'ios');
    await tester.scrollUntilVisible(find.text('卸载运行环境'), 500, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('卸载运行环境'));
    await frames(tester);
    await tester.tap(find.text('卸载运行环境'));
    await frames(tester);
    await tester.tap(find.byType(FilledButton).last);
    await frames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(RootGate)));
    expect(runtime.calls, ['reset:']);
    expect(runtime.state.status.phase, RuntimePhase.error);
    expect(runtime.state.status.installedVersion, isNull);
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    expect(find.byType(EngineScreen), findsOneWidget);
    expect(find.byType(RuntimeSetupPage), findsNothing);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2500));
    await frames(tester);
    expect(find.text('安装运行环境'), findsOneWidget);
    await tester.tap(find.text('安装运行环境'));
    await frames(tester);
    expect(find.byType(LocalInstallPage), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(runtime.calls, ['reset:']); // Navigation alone never starts Node/install.
    await tester.tap(find.text('重试'));
    await frames(tester);
    expect(runtime.calls, ['reset:', 'install']);
    expect(container.read(onboardingPrefsProvider).localDeclined, isFalse);
    await tester.pumpWidget(const SizedBox());
    await frames(tester, 1);
  });

  for (final os in ['ios', 'android', 'ohos']) {
    for (final installed in [null, bundled]) {
      testWidgets('$os error installed=${installed != null} retains scoped action', (tester) async {
        final runtime = RecordingLocalRuntime(LocalRuntimeState(loaded: true, status: snapshot(installed: installed)));
        await showScreen(tester, runtime, os);
        final install = os == 'ios' && installed == null;
        expect(find.text('安装运行环境'), install ? findsOneWidget : findsNothing);
        expect(find.text('重新启动'), install ? findsNothing : findsOneWidget);
        expect(runtime.calls, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await frames(tester, 1);
      });
    }
  }
  for (final phase in ['starting', 'stopping', 'installing']) {
    testWidgets('iOS $phase without installed version does not expose install', (tester) async {
      final runtime = RecordingLocalRuntime(LocalRuntimeState(loaded: true, status: snapshot(phase: phase)));
      // RootGate owns installing navigation; exercise actual EngineActions directly for busy controls.
      usePhoneSurface(tester);
      await tester.pumpWidget(goldenApp(home: Scaffold(body: EngineActions(phase: RuntimePhase.parse(phase))),
        brightness: Brightness.light, overrides: [operatingSystemProvider.overrideWithValue('ios'),
          localRuntimeProvider.overrideWith(() => runtime)]));
      await frames(tester);
      expect(find.text('安装运行环境'), findsNothing);
      expect(runtime.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await frames(tester, 1);
    });
  }
}
