// First run on this phone sets up while the runtime unpacks
// (docs/design/onboarding-parallel-setup.md): 本机 starts the unpack once and
// moves on; 外观 and 连接 DeepSeek follow with the unpack in a capsule; done
// early waits on its own page; a sign-in waits for the runtime; failures,
// resuming after the app went away, and the remote way.

import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/access_step.dart';
import 'package:dsh_app/ui/onboarding/appearance_step.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/onboarding/setup_progress.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../performance/support.dart';
import 'local_optional_support.dart';
import 'parallel_setup_support.dart';

const _capsule = ValueKey('setup-capsule');
const _seen = OnboardingPrefs(loaded: true, welcomeSeen: true);

Finder _capsuleText(String text) => find.descendant(of: find.byKey(_capsule), matching: find.text(text));

Future<void> _saveKey(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, '使用 API Key'));
  await frames(tester);
  await tester.enterText(find.byType(TextField), 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9');
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, '保存并继续'));
  await frames(tester);
}

void main() {
  setUp(useSavedHost);

  group('where a launch resumes', () {
    const fresh = OnboardingPrefs(loaded: true, welcomeSeen: true);
    OnboardingStep? at(SetupStep step, RuntimeStatus status, {bool key = false, bool skipped = false}) =>
        initialOnboardingStep(
          status: status,
          hasApiKey: key,
          prefs: fresh.copyWith(setupStep: step, keySkipped: skipped),
        );

    test('back on the page it was on, whatever the unpack did meanwhile', () {
      for (final status in [missingStatus, installingStatus, failedStatus, stoppedStatus]) {
        expect(at(SetupStep.appearance, status), OnboardingStep.appearance, reason: '${status.phase}');
        expect(at(SetupStep.access, status), OnboardingStep.access, reason: '${status.phase}');
        expect(at(SetupStep.connect, status), OnboardingStep.apiKey, reason: '${status.phase}');
      }
    });

    test('connected already: the waiting page while the runtime is missing, else home', () {
      expect(at(SetupStep.connect, installingStatus, key: true), OnboardingStep.finishing);
      expect(at(SetupStep.connect, missingStatus, skipped: true), OnboardingStep.finishing);
      expect(at(SetupStep.connect, stoppedStatus, key: true), isNull);
      expect(at(SetupStep.finishing, installingStatus), OnboardingStep.finishing);
      expect(at(SetupStep.finishing, missingStatus), OnboardingStep.finishing);
      expect(at(SetupStep.finishing, stoppedStatus), isNull);
    });

    test('an upgrade or a remote host instead goes the old way', () {
      final upgrade = RuntimeStatus(phase: RuntimePhase.notInstalled, bundledVersion: bundled, installedVersion: 'r4');
      expect(at(SetupStep.appearance, upgrade), OnboardingStep.runtime);
      expect(
        initialOnboardingStep(
          status: missingStatus,
          hasApiKey: false,
          prefs: fresh.copyWith(setupStep: SetupStep.appearance, localDeclined: true),
        ),
        isNull,
      );
    });

    test('without a saved page nothing changes', () {
      expect(initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: fresh), OnboardingStep.runtime);
      expect(initialOnboardingStep(status: installingStatus, hasApiKey: false, prefs: fresh), OnboardingStep.runtime);
      expect(initialOnboardingStep(status: stoppedStatus, hasApiKey: false, prefs: fresh), OnboardingStep.apiKey);
    });

    test('the setup runtime reads the native phase', () {
      expect(setupRuntimeOf(missingStatus), SetupRuntime.absent);
      expect(setupRuntimeOf(missingStatus, launchFailed: true), SetupRuntime.failed);
      expect(setupRuntimeOf(installingStatus), SetupRuntime.unpacking);
      expect(setupRuntimeOf(stoppedStatus), SetupRuntime.ready);
      expect(setupRuntimeOf(failedStatus), SetupRuntime.failed);
      // The engine's own error with a current runtime is not setup's.
      expect(
        setupRuntimeOf(
          const RuntimeStatus(phase: RuntimePhase.error, bundledVersion: bundled, installedVersion: bundled),
        ),
        SetupRuntime.ready,
      );
    });
  });

  group('本机: set up while it unpacks', () {
    testWidgets('starts the unpack once, then 外观 with the unpack in a capsule', (tester) async {
      final rig = await pumpGate(tester);
      expect(find.text('想怎么用 dsh-Go？'), findsOneWidget);
      expect(find.byKey(_capsule), findsNothing);

      await chooseThisPhone(tester);
      expect(rig.runtime.calls, ['install']);
      expect(find.byType(AppearanceStepPage), findsOneWidget);
      expect(find.text('选择外观'), findsOneWidget);
      expect(_capsuleText('准备运行环境'), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.appearance);
      expect(rig.prefs.localDeclined, isFalse);

      rig.runtime.unpack(0.42);
      await frames(tester, 3);
      expect(_capsuleText('运行环境 42%'), findsOneWidget);
      final read = find.bySemanticsLabel('正在准备运行环境，已完成 42%');
      expect(read, findsOneWidget);
      expect(tester.getSemantics(read), isSemantics(label: '正在准备运行环境，已完成 42%', isButton: true));
    });

    testWidgets('the usage and privacy notice does not stop the unpack', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester, keepNotice: true);
      expect(find.text('使用与隐私说明'), findsOneWidget);
      expect(rig.runtime.calls, ['install']);

      rig.runtime.unpack(0.42);
      await frames(tester, 3);
      expect(find.text('使用与隐私说明'), findsOneWidget);
      await closeUsagePrivacyNotice(tester);
      expect(find.text('使用与隐私说明'), findsNothing);
      expect(_capsuleText('运行环境 42%'), findsOneWidget);
      expect(rig.runtime.calls, ['install']);
    });

    testWidgets('paging on never starts a second unpack', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.4);
      await frames(tester, 2);

      await pastAppearance(tester);
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(_capsuleText('运行环境 40%'), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.connect);
      // No engine to start while it unpacks.
      expect(rig.engineStarts, isEmpty);
      expect(rig.runtime.calls, ['install']);
    });

    testWidgets('after 外观, what DSH Go should do: step 3 of 4, beside the unpack, kept on a relaunch', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.3);
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await frames(tester);
      expect(find.byType(AccessStepPage), findsOneWidget);
      expect(find.text('想让 DSH Go 帮你做哪些事'), findsOneWidget);
      expect(find.bySemanticsLabel('第 3 步，共 4 步'), findsOneWidget);
      expect(_capsuleText('运行环境 30%'), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.access);
      expect(rig.runtime.calls, ['install']);

      await tester.tap(find.widgetWithText(TextButton, '跳过'));
      await frames(tester);
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(find.bySemanticsLabel('第 4 步，共 4 步'), findsOneWidget);
    });

    testWidgets('choices on 外观 apply at once', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      await tester.tap(find.text('深色'));
      await frames(tester, 3);
      expect(rig.container.read(settingsProvider).themeMode, ThemeMode.dark);
      expect(tester.getSemantics(find.bySemanticsLabel('深色')), isSemantics(isSelected: true));
    });

    testWidgets('a key saved before the unpack ends waits for it, then goes home with the engine', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.6);
      await pastAppearance(tester);
      await _saveKey(tester);

      expect(find.byType(RuntimeSetupPage), findsOneWidget);
      expect(find.text('完成后自动进入'), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.finishing);
      // The waiting page is no step: no bar, and the halo is the progress.
      expect(find.byKey(_capsule), findsNothing);
      expect(rig.runtime.calls, ['install']);

      rig.runtime.finish();
      await frames(tester, 20);
      expect(find.text('home'), findsOneWidget);
      expect(rig.runtime.calls, ['install', 'start']);
      expect(rig.prefs.setupStep, isNull);
      expect(rig.container.read(settingsProvider).hasApiKey, isTrue);
    });

    testWidgets('done between the steps: the capsule says so, fades, keeps its room; the engine starts', (
      tester,
    ) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.9);
      await frames(tester, 2);
      final slot = tester.getRect(find.byKey(const ValueKey('setup-capsule-slot')));
      final button = tester.getRect(find.widgetWithText(FilledButton, '继续'));

      rig.runtime.finish();
      await frames(tester, 3);
      expect(_capsuleText('运行环境已就绪'), findsOneWidget);
      expect(rig.runtime.calls, ['install', 'start']);

      await tester.pump(SetupProgressCapsule.readyHold);
      await frames(tester, 5);
      final fade = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(_capsule), matching: find.byType(AnimatedOpacity)).first,
      );
      expect(fade.opacity, 0);
      // Nothing under the person's thumb moved.
      expect(tester.getRect(find.byKey(const ValueKey('setup-capsule-slot'))), slot);
      expect(tester.getRect(find.widgetWithText(FilledButton, '继续')), button);

      // On to 连接 DeepSeek: it starts the account engine; 稍后设置 goes home.
      await pastAppearance(tester);
      expect(rig.engineStarts, [1]);
      await tester.tap(find.widgetWithText(TextButton, '稍后设置'));
      await frames(tester);
      expect(find.text('home'), findsOneWidget);
      expect(rig.prefs.keySkipped, isTrue);
      expect(rig.prefs.setupStep, isNull);
      // Started once for the whole of first run.
      expect(rig.runtime.calls, ['install', 'start']);
    });

    testWidgets('a key already there: straight from 外观 to the waiting page', (tester) async {
      final rig = await pumpGate(tester, settings: const AppSettings(loaded: true, apiKey: 'sk-1'));
      await chooseThisPhone(tester);
      await pastAppearance(tester);
      expect(find.byType(ConnectPage), findsNothing);
      expect(find.text('完成后自动进入'), findsOneWidget);
      expect(rig.prefs.setupStep, SetupStep.finishing);
    });
  });

  group('signing in while it unpacks', () {
    testWidgets('waits for the runtime, then signs in by itself', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.5);
      await pastAppearance(tester);

      await tester.tap(find.widgetWithText(FilledButton, '用 DeepSeek 账号登录'));
      await frames(tester);
      expect(find.text('就绪后自动打开 DeepSeek 登录'), findsOneWidget);
      // The page is the progress: no capsule under it.
      expect(find.byKey(_capsule), findsNothing);
      expect(rig.account.signIns, isEmpty);

      rig.runtime.unpack(0.8);
      await frames(tester, 2);
      expect(rig.account.signIns, isEmpty);
      rig.runtime.finish();
      await frames(tester, 3);
      expect(rig.account.signIns, hasLength(1));
      expect(rig.runtime.calls, contains('start'));
    });

    testWidgets('ready while the app is away: the sign-in opens once the person is back', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.5);
      await pastAppearance(tester);
      await tester.tap(find.widgetWithText(FilledButton, '用 DeepSeek 账号登录'));
      await frames(tester);

      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      rig.runtime.finish();
      await frames(tester, 3);
      // No browser behind the person's back; the engine still gets going.
      expect(rig.account.signIns, isEmpty);
      expect(rig.runtime.calls, contains('start'));

      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await frames(tester, 3);
      expect(rig.account.signIns, hasLength(1));
      expect(find.text('就绪后自动打开 DeepSeek 登录'), findsNothing);
    });

    testWidgets('取消 goes back to the ways in; back does too', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.5);
      await pastAppearance(tester);

      await tester.tap(find.widgetWithText(FilledButton, '用 DeepSeek 账号登录'));
      await frames(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      await frames(tester);
      expect(find.text('就绪后自动打开 DeepSeek 登录'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '使用 API Key'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '用 DeepSeek 账号登录'));
      await frames(tester);
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(find.text('就绪后自动打开 DeepSeek 登录'), findsNothing);

      // Cancelled: the unpack finishing later starts no sign-in.
      rig.runtime.finish();
      await frames(tester, 3);
      expect(rig.account.signIns, isEmpty);
    });

    testWidgets('a failed unpack drops the wait and shows what to do', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.unpack(0.5);
      await pastAppearance(tester);
      await tester.tap(find.widgetWithText(FilledButton, '用 DeepSeek 账号登录'));
      await frames(tester);

      rig.runtime.fail();
      await frames(tester, 8);
      expect(find.text('就绪后自动打开 DeepSeek 登录'), findsNothing);
      expect(find.byKey(const ValueKey('setup-status-sheet')), findsOneWidget);
      expect(find.text('存储空间不足：需要约 862 MB，当前可用 600 MB'), findsOneWidget);
      expect(rig.account.signIns, isEmpty);
    });
  });

  group('a failed unpack', () {
    testWidgets('the capsule turns red; its sheet retries through the one entry', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.fail();
      await frames(tester, 3);
      expect(_capsuleText('安装未完成'), findsOneWidget);
      // Still on 外观: nothing interrupted.
      expect(find.byType(AppearanceStepPage), findsOneWidget);

      await tester.tap(find.byKey(_capsule));
      await frames(tester, 6);
      final sheet = find.byKey(const ValueKey('setup-status-sheet'));
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('安装未完成')), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '改用远程主机'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '查看日志'), findsOneWidget);
      // Only a drag handle closes it: no ×.
      expect(find.byTooltip('关闭'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pump();
      expect(rig.runtime.calls, ['install', 'install']);
      // A second tap while that one is on its way is the same request.
      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pump();
      expect(rig.runtime.calls, ['install', 'install']);
    });

    testWidgets('改用远程主机 from the sheet: host list, a host, home; first run over', (tester) async {
      final rig = await pumpGate(tester);
      await chooseThisPhone(tester);
      rig.runtime.fail();
      await frames(tester, 3);
      await tester.tap(find.byKey(_capsule));
      await frames(tester, 6);
      await tester.tap(find.widgetWithText(OutlinedButton, '改用远程主机'));
      await frames(tester);
      expect(find.byType(RemoteScreen), findsOneWidget);

      await tester.tap(find.text('电脑'));
      await frames(tester);
      expect(find.text('home'), findsOneWidget);
      expect(rig.prefs.localDeclined, isTrue);
      expect(rig.prefs.setupStep, isNull);
    });

    testWidgets('on the waiting page: retry, logs and the remote host', (tester) async {
      final rig = await pumpGate(
        tester,
        runtime: unpackingState(0.7),
        prefs: _seen.copyWith(setupStep: SetupStep.finishing, keySkipped: true),
      );
      expect(find.text('完成后自动进入'), findsOneWidget);
      rig.runtime.fail();
      await frames(tester, 3);
      expect(find.text('安装未完成'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '查看日志'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '改用远程主机'), findsOneWidget);
    });
  });

  group('coming back after the app went away', () {
    testWidgets('unpack died with the app: same page, unpacking again', (tester) async {
      final rig = await pumpGate(tester, prefs: _seen.copyWith(setupStep: SetupStep.appearance));
      expect(find.byType(AppearanceStepPage), findsOneWidget);
      expect(find.text('DSH 在哪里运行？'), findsNothing);
      expect(rig.runtime.calls, ['install']);
      expect(find.byKey(_capsule), findsOneWidget);
    });

    testWidgets('still unpacking: same page, same unpack', (tester) async {
      final rig = await pumpGate(
        tester,
        runtime: unpackingState(0.3),
        prefs: _seen.copyWith(setupStep: SetupStep.connect),
      );
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(_capsuleText('运行环境 30%'), findsOneWidget);
      expect(rig.runtime.calls, isEmpty);
    });

    testWidgets('waiting page, unpack died: one unpack, though page and gate both ask', (tester) async {
      final rig = await pumpGate(tester, prefs: _seen.copyWith(setupStep: SetupStep.finishing, keySkipped: true));
      expect(find.text('完成后自动进入'), findsOneWidget);
      expect(rig.runtime.calls, ['install']);
    });

    testWidgets('done while away: the page it was on, engine starting, no capsule', (tester) async {
      final rig = await pumpGate(
        tester,
        runtime: const LocalRuntimeState(loaded: true, status: stoppedStatus),
        prefs: _seen.copyWith(setupStep: SetupStep.appearance),
      );
      expect(find.byType(AppearanceStepPage), findsOneWidget);
      expect(rig.runtime.calls, ['start']);
      final fade = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(_capsule), matching: find.byType(AnimatedOpacity)).first,
      );
      expect(fade.opacity, 0);
    });

    testWidgets('done and connected while away: home', (tester) async {
      final rig = await pumpGate(
        tester,
        runtime: const LocalRuntimeState(loaded: true, status: stoppedStatus),
        prefs: _seen.copyWith(setupStep: SetupStep.finishing, keySkipped: true),
      );
      expect(find.text('home'), findsOneWidget);
      expect(rig.prefs.setupStep, isNull);
    });
  });

  group('the other ways are as they were', () {
    testWidgets('远程主机: no unpack, no setup step', (tester) async {
      final rig = await pumpGate(tester);
      await tester.tap(find.byKey(const ValueKey('runtime-option-remote')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await frames(tester);
      expect(find.byType(RemoteScreen), findsOneWidget);
      await tester.tap(find.text('电脑'));
      await frames(tester);
      expect(find.text('home'), findsOneWidget);
      expect(rig.container.read(activeHostProvider), isNot(HostRef.local));
      expect(rig.runtime.calls, isEmpty);
      expect(rig.prefs.setupStep, isNull);
    });

    testWidgets('an upgrade unpacks on its own page, then home', (tester) async {
      final rig = await pumpGate(
        tester,
        runtime: const LocalRuntimeState(
          loaded: true,
          status: RuntimeStatus(phase: RuntimePhase.notInstalled, bundledVersion: bundled, installedVersion: 'r4'),
        ),
        settings: const AppSettings(loaded: true, apiKey: 'sk-1'),
      );
      expect(find.text('正在更新运行环境'), findsOneWidget);
      expect(find.byKey(_capsule), findsNothing);
      expect(rig.runtime.calls, ['install']);
      rig.runtime.finish();
      await frames(tester, 20);
      expect(find.text('home'), findsOneWidget);
      expect(rig.prefs.setupStep, isNull);
    });

    testWidgets('installed without a key: just 连接 DeepSeek, step 2 of 2, no capsule', (tester) async {
      await pumpGate(tester, runtime: const LocalRuntimeState(loaded: true, status: stoppedStatus));
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(find.bySemanticsLabel('第 2 步，共 2 步'), findsOneWidget);
      expect(find.byKey(_capsule), findsNothing);
    });
  });

  group('外观 on a low-end phone', () {
    Future<GateRig> pumpLow(WidgetTester tester, DeviceTier tier) async {
      final rig = await pumpGate(
        tester,
        overrides: [performanceChannelProvider.overrideWithValue(FakePerformanceChannel(Future.value(snapshot(tier))))],
      );
      // A low-end phone suggests the remote host: pick this phone.
      await tester.tap(find.byKey(const ValueKey('runtime-option-local')));
      await tester.pump(const Duration(milliseconds: 300));
      await chooseThisPhone(tester);
      return rig;
    }

    testWidgets('confirms 轻量模式, on by default; off means 完整', (tester) async {
      final rig = await pumpLow(tester, DeviceTier.low);
      final tile = find.byKey(const ValueKey('setup-light-mode'));
      expect(tile, findsOneWidget);
      expect(tester.widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch))).value, isTrue);
      await tester.tap(tile);
      await frames(tester, 3);
      expect(rig.container.read(performancePrefsProvider).mode, PerformanceMode.full);
      expect(tester.widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch))).value, isFalse);
    });

    testWidgets('other phones have nothing to confirm', (tester) async {
      await pumpLow(tester, DeviceTier.medium);
      expect(find.byKey(const ValueKey('setup-light-mode')), findsNothing);
    });
  });

  testWidgets('the palette on 外观 has the six presets, no custom slot', (tester) async {
    final rig = await pumpGate(tester);
    await chooseThisPhone(tester);
    expect(find.text('自定义'), findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp('^配色.*')).at(2));
    await frames(tester, 3);
    expect(rig.container.read(appearanceProvider).source, AccentSource.preset);
    expect(rig.container.read(appearanceProvider).presetId, isNot('mist'));
  });

  tearDown(() => SharedPreferences.setMockInitialValues({}));
}
