// 安全模式 and 恢复上次正常配置 on HarmonyOS: the engine runs in the app's process, so its
// failures only read as `killed` or `launchFailed`, and a change of mode takes a new
// process. The way in has to be reachable anyway, and the dialogs say what it costs.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/safe_mode_state.dart';
import 'package:dsh_app/ui/safe_mode/engine_failure_card.dart';
import 'package:dsh_app/ui/safe_mode/safe_mode_card.dart';
import 'package:dsh_app/ui/safe_mode/safe_mode_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support.dart';

final _zh = lookupL10n(AppLocale.zhCN);

RuntimeFailure _unclean({bool safeMode = false}) =>
    RuntimeFailure(kind: FailureKind.killed, at: failedAt, exitCode: 0, safeMode: safeMode, causeUnknown: true);

const _useful = LastKnownGood(available: true, disable: ['bad-plugin'], empty: false);

void main() {
  group('the failure card', () {
    FailureCardModel model(RuntimeFailure f, {bool lkg = false, bool held = false}) =>
        FailureCardModel.of(f, lkgUseful: lkg, held: held);

    test('one unclean exit: try again first, with the ways out beside it', () {
      final m = model(_unclean());
      expect(m.primary, FailureAction.retry);
      expect(m.secondary, [FailureAction.enterSafe, FailureAction.background, FailureAction.showLog]);
      expect(model(_unclean(), lkg: true).secondary.take(2), [FailureAction.restoreLkg, FailureAction.enterSafe]);
    });

    test('the engine waiting: the ways out come first', () {
      expect(model(_unclean(), held: true).primary, FailureAction.enterSafe);
      final m = model(_unclean(), lkg: true, held: true);
      expect(m.primary, FailureAction.restoreLkg);
      expect(m.secondary.take(2), [FailureAction.enterSafe, FailureAction.retry]);
    });

    test('a safe run that died can go back to normal, and offers no safe mode again', () {
      final m = model(_unclean(safeMode: true), held: true);
      expect(m.primary, FailureAction.retry);
      expect(m.secondary, contains(FailureAction.startNormal));
      expect(m.secondary, isNot(contains(FailureAction.enterSafe)));
    });

    test('a launch that failed offers no safe mode: the configuration was never read', () {
      final launch = RuntimeFailure(kind: FailureKind.launchFailed, at: failedAt, causeUnknown: true);
      expect(model(launch, held: true).primary, FailureAction.retry);
      expect(model(launch).secondary, isNot(contains(FailureAction.enterSafe)));
      final safe = RuntimeFailure(kind: FailureKind.launchFailed, at: failedAt, safeMode: true, causeUnknown: true);
      expect(model(safe).secondary, contains(FailureAction.startNormal));
    });

    test('Android\'s kinds read as they did', () {
      final killed = RuntimeFailure(kind: FailureKind.killed, at: failedAt);
      final m = model(killed, held: true);
      expect(m.title, _zh.phoneFailureKilled);
      expect(m.primary, FailureAction.retry);
      expect(m.secondary, [FailureAction.background, FailureAction.showLog]);
      final launch = RuntimeFailure(kind: FailureKind.launchFailed, at: failedAt);
      expect(model(launch).secondary, [FailureAction.remote, FailureAction.showLog]);
      expect(model(startupFailure()).primary, FailureAction.enterSafe);
      expect(model(startupFailure(), lkg: true).primary, FailureAction.restoreLkg);
    });
  });

  group('the repair prompt', () {
    const status = RuntimeStatus(phase: RuntimePhase.running, mode: EngineMode.safe);

    test('HarmonyOS names no tool or briefing it doesn\'t have; Android keeps its own', () {
      expect(repairPrompt(status), contains('dsh-app-plugins'));
      final harmony = repairPrompt(status, harmony: true);
      expect(harmony, isNot(contains('dsh-app-plugins')));
      expect(harmony, isNot(contains('「安全模式」说明')));
      expect(harmony, contains(_zh.stateSafeManualEntry));
    });
  });

  group('the dialogs', () {
    late RecordingRuntime runtime;
    late FakeBridge bridge;

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      required String os,
      required RuntimeStatus status,
      LastKnownGood lkg = const LastKnownGood.none(),
    }) async {
      usePhoneView(tester);
      runtime = RecordingRuntime(LocalRuntimeState(loaded: true, status: status));
      bridge = FakeBridge(lkg: lkg);
      final overrides = <Override>[
        operatingSystemProvider.overrideWithValue(os),
        localRuntimeProvider.overrideWith(() => runtime),
        runtimeBridgeProvider.overrideWithValue(bridge),
      ];
      await tester.pumpWidget(
        testApp(
          Scaffold(body: SingleChildScrollView(child: child)),
          overrides: overrides,
        ),
      );
      await pumpFrames(tester);
    }

    const spawned = RuntimeStatus(phase: RuntimePhase.running, launchSpawned: true);
    const fresh = RuntimeStatus(phase: RuntimePhase.installed);
    const safeRunning = RuntimeStatus(phase: RuntimePhase.running, mode: EngineMode.safe, launchSpawned: true);
    const tile = SafeModeSettingsTiles(showAutoSwitch: false, icon: false);

    testWidgets('Android: 以安全模式启动 starts right away, as it did', (tester) async {
      await pump(tester, tile, os: 'android', status: spawned);
      await tester.tap(find.text(_zh.phoneSafeStartSettings));
      await pumpFrames(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(runtime.starts, ['safe']);
    });

    testWidgets('HarmonyOS: asks first, and says it reopens the app when it will', (tester) async {
      await pump(tester, tile, os: 'ohos', status: spawned);
      await tester.tap(find.text(_zh.phoneSafeStartSettings));
      await pumpFrames(tester);
      expect(find.textContaining(_zh.harmonySafeEnterBody), findsOneWidget);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsOneWidget);
      expect(runtime.starts, isEmpty, reason: 'nothing happens before the answer');

      await tester.tap(find.text(_zh.commonCancel));
      await pumpFrames(tester);
      expect(runtime.starts, isEmpty);

      await tester.tap(find.text(_zh.phoneSafeStartSettings));
      await pumpFrames(tester);
      await tester.tap(find.text(_zh.phoneFailureEnterSafe));
      await pumpFrames(tester);
      expect(runtime.starts, ['safe']);
    });

    testWidgets('HarmonyOS: no engine started yet, so no reopening to warn of', (tester) async {
      await pump(tester, tile, os: 'ohos', status: fresh);
      await tester.tap(find.text(_zh.phoneSafeStartSettings));
      await pumpFrames(tester);
      expect(find.textContaining(_zh.harmonySafeEnterBody), findsOneWidget);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsNothing);
    });

    testWidgets('leaving: Android\'s words alone; HarmonyOS adds what it costs', (tester) async {
      await pump(tester, tile, os: 'android', status: safeRunning);
      await tester.tap(find.text(_zh.phoneSafeLeave));
      await pumpFrames(tester);
      expect(find.text(_zh.phoneSafeLeaveBody), findsOneWidget);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsNothing);
      await tester.tap(find.text(_zh.commonCancel));
      await pumpFrames(tester);

      await pump(tester, tile, os: 'ohos', status: safeRunning);
      await tester.tap(find.text(_zh.phoneSafeLeave));
      await pumpFrames(tester);
      expect(find.textContaining(_zh.phoneSafeLeaveBody), findsOneWidget);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsOneWidget);
    });

    testWidgets('HarmonyOS: the card under an unclean exit reaches safe mode', (tester) async {
      final status = RuntimeStatus(phase: RuntimePhase.error, failure: _unclean(), strikes: 2, autoSafe: false);
      await pump(tester, const EngineFailureCard(), os: 'ohos', status: status);
      expect(find.text(_zh.harmonyFailureHeld), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, _zh.phoneFailureEnterSafe));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(FilledButton, _zh.phoneFailureEnterSafe).last);
      await pumpFrames(tester);
      expect(runtime.starts, ['safe']);
    });

    testWidgets('HarmonyOS: the card offers 恢复配置 when there is something to restore', (tester) async {
      final status = RuntimeStatus(
        phase: RuntimePhase.error,
        failure: _unclean(),
        strikes: 2,
        autoSafe: false,
        launchSpawned: true,
      );
      await pump(tester, const EngineFailureCard(), os: 'ohos', status: status, lkg: _useful);
      await tester.tap(find.widgetWithText(FilledButton, _zh.phoneFailureRestore));
      await pumpFrames(tester);
      expect(find.textContaining('bad-plugin'), findsOneWidget);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsOneWidget);
      await tester.tap(find.text(_zh.phoneSafeRestoreStart));
      await pumpFrames(tester);
      expect(bridge.calls, contains('restoreLastKnownGood'));
      expect(runtime.starts, ['normal']);
      expect(find.text(_zh.harmonyRestoredReopening), findsOneWidget);
    });

    testWidgets('the safe-mode card: 帮我修复, 正常启动 and 恢复配置 work on HarmonyOS too', (tester) async {
      await pump(tester, const SafeModeCard(), os: 'ohos', status: safeRunning, lkg: _useful);
      expect(find.text(_zh.phoneSafeReasonManual), findsOneWidget);
      expect(find.text(_zh.phoneSafeRepair), findsOneWidget);
      expect(find.text(_zh.phoneFailureRestore), findsOneWidget);
      await tester.tap(find.text(_zh.phoneFailureStartNormal));
      await pumpFrames(tester);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsOneWidget);
      await tester.tap(find.text(_zh.phoneSafeLeave));
      await pumpFrames(tester);
      expect(runtime.starts, ['normal']);
    });

    testWidgets('HarmonyOS: starting normally from a failed safe run asks too', (tester) async {
      final status = RuntimeStatus(
        phase: RuntimePhase.error,
        mode: EngineMode.safe,
        failure: _unclean(safeMode: true),
        launchSpawned: true,
      );
      await pump(tester, const EngineFailureCard(), os: 'ohos', status: status);
      await tester.tap(find.text(_zh.phoneFailureStartNormal));
      await pumpFrames(tester);
      expect(runtime.starts, isEmpty);
      expect(find.textContaining(_zh.harmonySafeReopenNote), findsOneWidget);
    });
  });
}
