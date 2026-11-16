// The engine page's rescue on HarmonyOS: a failure says only what's known, and a
// reset's three answers (saved, not saved, can't tell) each read as what they are,
// through the app reopening. On Android none of this shows.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/engine_control.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/safe_mode_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine/engine_status.dart';
import 'package:dsh_app/ui/engine/reset_outcome.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/safe_mode/engine_failure_card.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../safe_mode/support.dart' show FakeBridge, failedAt;
import '../shell/golden_harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);
const _receipt = 'engine_reset_receipt';

class _Bridge extends FakeBridge {
  String? resetCode;
  Object? reopenError;
  final made = <String>[];
  Map<String, Object?>? asked;

  Never _throw() => throw PlatformException(code: resetCode!);

  @override
  Future<void> resetAndReinstall({ResetKeep keep = const ResetKeep()}) async {
    made.add('reinstall');
    asked = {'keep': keep.wire};
    if (resetCode != null) _throw();
  }

  @override
  Future<void> reset({ResetKeep keep = const ResetKeep()}) async {
    made.add('reset');
    if (resetCode != null) _throw();
  }

  @override
  Future<void> reopenApp() async {
    made.add('reopen');
    if (reopenError != null) throw reopenError!;
  }
}

const _installed = RuntimeStatus(
  phase: RuntimePhase.installed,
  bundledVersion: 'r4',
  installedVersion: 'r4',
  autoSafe: false,
);

Future<void> _pump(
  WidgetTester tester,
  Widget home,
  _Bridge bridge, {
  bool android = false,
  RuntimeStatus status = runningStatus,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 3600 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: home,
      brightness: Brightness.light,
      overrides: [
        operatingSystemProvider.overrideWithValue(android ? 'android' : 'ohos'),
        runtimeBridgeProvider.overrideWithValue(bridge),
        activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
        hostsProvider.overrideWith(FixedHosts.new),
        localRuntimeProvider.overrideWith(() => FakeRuntime(LocalRuntimeState(loaded: true, status: status))),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _askReset(WidgetTester tester) async {
  await tester.tap(find.text(_zh.phoneEngineReset));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_zh.phoneEngineDeleteReset));
  await tester.pumpAndSettle();
}

Future<String?> _savedReceipt() async => (await SharedPreferences.getInstance()).getString(_receipt);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('what a failure says', () {
    final unclean = RuntimeFailure(
      kind: FailureKind.killed,
      at: failedAt,
      causeUnknown: true,
      summary: '上次引擎没有确认干净退出。',
    );
    final androidKill = RuntimeFailure(kind: FailureKind.killed, at: failedAt);

    test('the wire says whether the cause is known', () {
      expect(RuntimeFailure.fromMap({'kind': 'killed', 'at': 1, 'causeUnknown': true})!.causeUnknown, isTrue);
      expect(RuntimeFailure.fromMap({'kind': 'killed', 'at': 1})!.causeUnknown, isFalse);
    });

    test('HarmonyOS doesn\'t name the system, the battery or Android', () {
      final model = FailureCardModel.of(unclean, lkgUseful: false);
      expect(model.title, _zh.harmonyFailureUnclean);
      expect(model.body, _zh.harmonyFailureUncleanHint);
      expect(failureOneLiner(unclean), _zh.harmonyEngineUnclean);
      final status = RuntimeStatus(phase: RuntimePhase.error, failure: unclean);
      expect(EngineStatusView.of(LocalRuntimeState(loaded: true, status: status)).label, _zh.harmonyEngineUnclean);
      expect(_en.harmonyEngineUnclean, isNot(contains('Android')));
      expect('${_zh.harmonyFailureUnclean}${_zh.harmonyFailureUncleanHint}', isNot(contains('省电')));
    });

    test('Android\'s words stay Android\'s', () {
      final model = FailureCardModel.of(androidKill, lkgUseful: false);
      expect(model.title, _zh.phoneFailureKilled);
      expect(model.body, _zh.phoneFailureKilledHint);
      final status = RuntimeStatus(phase: RuntimePhase.error, failure: androidKill);
      expect(EngineStatusView.of(LocalRuntimeState(loaded: true, status: status)).label, _zh.phoneEngineKilled);
      expect(failureOneLiner(androidKill), _zh.stateSafeKilled);
    });

    for (final (strikes, held) in [(1, false), (2, true)]) {
      testWidgets('$strikes in a row: the held line ${held ? 'shows' : 'doesn\'t'}', (tester) async {
        await _pump(
          tester,
          const Scaffold(body: EngineFailureCard()),
          _Bridge(),
          status: RuntimeStatus(phase: RuntimePhase.error, failure: unclean, strikes: strikes, autoSafe: false),
        );
        expect(find.text(_zh.harmonyFailureUnclean), findsOneWidget);
        expect(find.text(_zh.harmonyFailureHeld), held ? findsOneWidget : findsNothing);
        expect(find.text(_zh.commonRetry), findsOneWidget);
      });
    }
  });

  group('the launch-time start', () {
    RuntimeStatus unclean(int strikes, {String? error}) => RuntimeStatus(
      phase: RuntimePhase.error,
      strikes: strikes,
      autoSafe: false,
      error: error,
      failure: RuntimeFailure(kind: FailureKind.killed, at: failedAt, causeUnknown: true),
    );

    test('an app the system ended starts again by itself', () {
      expect(EngineControl.startsAtLaunch(unclean(1)), isTrue);
    });

    test('two short runs in a row stop it: the card waits', () {
      expect(EngineControl.startsAtLaunch(unclean(2)), isFalse);
    });

    test('another error on top isn\'t started over', () {
      expect(EngineControl.startsAtLaunch(unclean(1, error: '运行时安装未完成')), isFalse);
    });

    test('a launch failure waits for the person', () {
      final status = RuntimeStatus(
        phase: RuntimePhase.error,
        strikes: 1,
        autoSafe: false,
        failure: RuntimeFailure(kind: FailureKind.launchFailed, at: failedAt, causeUnknown: true),
      );
      expect(EngineControl.startsAtLaunch(status), isFalse);
    });

    test('Android is as it was: error waits, installed starts unless held', () {
      final kill = RuntimeFailure(kind: FailureKind.killed, at: failedAt);
      expect(EngineControl.startsAtLaunch(RuntimeStatus(phase: RuntimePhase.error, failure: kill)), isFalse);
      expect(EngineControl.startsAtLaunch(const RuntimeStatus(phase: RuntimePhase.installed)), isTrue);
      expect(
        EngineControl.startsAtLaunch(const RuntimeStatus(phase: RuntimePhase.installed, strikes: 2, autoSafe: false)),
        isFalse,
      );
    });
  });

  group('reset', () {
    testWidgets('the dialog says what it keeps, and the request reinstalls', (tester) async {
      final bridge = _Bridge();
      await _pump(tester, const EngineScreen(), bridge);
      await tester.tap(find.text(_zh.phoneEngineReset));
      await tester.pumpAndSettle();
      expect(find.text(_zh.harmonyResetKept), findsOneWidget);
      expect(find.text(_zh.phoneEngineKeepUiSkills), findsOneWidget);
      await tester.tap(find.text(_zh.phoneEngineDeleteReset));
      await tester.pumpAndSettle();
      expect(bridge.made, ['reinstall']);
      expect(bridge.asked, {
        'keep': ['uiAndSkills'],
      });
    });

    testWidgets('saved and reopening: no dialog, it says so', (tester) async {
      final bridge = _Bridge()..resetCode = 'ohos_reset_committed';
      await _pump(tester, const EngineScreen(), bridge);
      await _askReset(tester);
      expect(bridge.made, ['reinstall', 'reopen']);
      expect(find.text(_zh.harmonyResetReopening), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(await _savedReceipt(), 'committed');
    });

    testWidgets('saved but the system wouldn\'t reopen: not called a failure, and it can try again', (tester) async {
      final bridge = _Bridge()
        ..resetCode = 'ohos_reset_committed'
        ..reopenError = PlatformException(code: 'ohos_restart_failed');
      await _pump(tester, const EngineScreen(), bridge);
      await _askReset(tester);
      expect(find.text(_zh.harmonyResetCommittedTitle), findsOneWidget);
      expect(find.text(_zh.phoneEngineResetFailed), findsNothing);
      expect(await _savedReceipt(), 'committed');
      bridge.reopenError = null;
      await tester.tap(find.text(_zh.harmonyReopenApp));
      await tester.pumpAndSettle();
      expect(bridge.made, ['reinstall', 'reopen', 'reopen']);
    });

    testWidgets('can\'t tell: says so and doesn\'t reopen by itself', (tester) async {
      final bridge = _Bridge()..resetCode = 'ohos_reset_commit_unknown';
      await _pump(tester, const EngineScreen(), bridge);
      await _askReset(tester);
      expect(find.text(_zh.harmonyResetUnknownTitle), findsOneWidget);
      expect(bridge.made, ['reinstall']);
      expect(await _savedReceipt(), 'unknown');
      await tester.tap(find.text(_zh.commonLater));
      await tester.pumpAndSettle();
      expect(bridge.made, ['reinstall']);
    });

    testWidgets('not saved: nothing was reset, and no receipt waits for the next open', (tester) async {
      final bridge = _Bridge()..resetCode = 'ohos_recovery_invalid';
      await _pump(tester, const EngineScreen(), bridge);
      await _askReset(tester);
      expect(find.text(_zh.harmonyResetNotCommittedTitle), findsOneWidget);
      expect(await _savedReceipt(), isNull);
    });

    testWidgets('an older reset still waiting is named', (tester) async {
      final bridge = _Bridge()..resetCode = 'ohos_reset_pending';
      await _pump(tester, const EngineScreen(), bridge);
      await _askReset(tester);
      expect(find.text(_zh.harmonyResetOlderPendingTitle), findsOneWidget);
    });

    testWidgets('mid-install: refused, nothing to reopen', (tester) async {
      final bridge = _Bridge()..resetCode = 'reset_busy';
      await _pump(tester, const EngineScreen(), bridge);
      await _askReset(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_zh.harmonyResetInstalling), findsOneWidget);
      expect(bridge.made, ['reinstall']);
    });

    testWidgets('on Android the reset is the same as ever', (tester) async {
      final bridge = _Bridge();
      await _pump(tester, const EngineScreen(), bridge, android: true);
      await tester.tap(find.text(_zh.phoneEngineReset));
      await tester.pumpAndSettle();
      expect(find.text(_zh.harmonyResetKept), findsNothing);
      await tester.tap(find.text(_zh.phoneEngineDeleteReset));
      await tester.pumpAndSettle();
      expect(bridge.made, ['reset']);
      expect(await _savedReceipt(), isNull);
    });
  });

  group('a reset waiting for the app to reopen', () {
    testWidgets('the engine page says so and offers it', (tester) async {
      final bridge = _Bridge();
      await _pump(
        tester,
        const EngineScreen(),
        bridge,
        status: const RuntimeStatus(phase: RuntimePhase.installed, resetPending: true),
      );
      expect(find.text(_zh.harmonyResetPendingTitle), findsOneWidget);
      await tester.tap(find.text(_zh.harmonyReopenApp));
      await tester.pumpAndSettle();
      expect(bridge.made, ['reopen']);
    });

    testWidgets('otherwise it doesn\'t', (tester) async {
      await _pump(tester, const EngineScreen(), _Bridge(), status: _installed);
      expect(find.text(_zh.harmonyResetPendingTitle), findsNothing);
    });

    test('the wire carries it', () {
      expect(RuntimeStatus.fromMap({'phase': 'installed', 'resetPending': true}).resetPending, isTrue);
      expect(RuntimeStatus.fromMap({'phase': 'installed'}).resetPending, isFalse);
    });
  });

  group('back after the app reopened', () {
    Future<void> reopened(WidgetTester tester, {String? receipt, RuntimeStatus status = _installed}) async {
      SharedPreferences.setMockInitialValues({_receipt: ?receipt});
      await _pump(tester, const Scaffold(body: ResetReceiptHost()), _Bridge(), status: status);
    }

    testWidgets('a saved reset is reported done, once', (tester) async {
      await reopened(tester, receipt: 'committed');
      expect(find.text(_zh.harmonyResetDone), findsOneWidget);
      expect(await _savedReceipt(), isNull);
    });

    testWidgets('one nobody could confirm isn\'t claimed', (tester) async {
      await reopened(tester, receipt: 'unknown');
      expect(find.text(_zh.harmonyResetDone), findsNothing);
      expect(find.text(_zh.harmonyResetMaybeDone), findsOneWidget);
    });

    testWidgets('still pending: not done, and the receipt waits', (tester) async {
      await reopened(
        tester,
        receipt: 'committed',
        status: const RuntimeStatus(phase: RuntimePhase.installed, resetPending: true),
      );
      expect(find.text(_zh.harmonyResetDone), findsNothing);
      expect(await _savedReceipt(), 'committed');
    });

    testWidgets('no reset asked for, nothing to say', (tester) async {
      await reopened(tester);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('uninstall', () {
    testWidgets('on HarmonyOS it doesn\'t offer to free what it can\'t', (tester) async {
      await _pump(tester, const EngineScreen(), _Bridge());
      expect(find.text(_zh.harmonyUninstallHint), findsOneWidget);
      expect(find.text(_zh.localEnvUninstallHint), findsNothing);
      await tester.tap(find.text(_zh.localEnvUninstall));
      await tester.pumpAndSettle();
      expect(find.text(_zh.harmonyUninstallBody), findsOneWidget);
    });

    testWidgets('saved but not reopened isn\'t called a failure', (tester) async {
      final bridge = _Bridge()
        ..resetCode = 'ohos_reset_committed'
        ..reopenError = PlatformException(code: 'ohos_restart_failed');
      await _pump(tester, const EngineScreen(), bridge);
      await tester.tap(find.text(_zh.localEnvUninstall));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_zh.localEnvUninstallConfirm));
      await tester.pumpAndSettle();
      expect(find.text(_zh.harmonyResetCommittedTitle), findsOneWidget);
      expect(find.text(_zh.localEnvUninstallFailed), findsNothing);
    });

    testWidgets('on Android its words are as they were', (tester) async {
      await _pump(tester, const EngineScreen(), _Bridge(), android: true);
      expect(find.text(_zh.localEnvUninstallHint), findsOneWidget);
      expect(find.text(_zh.harmonyUninstallHint), findsNothing);
    });

    test('search on HarmonyOS finds it, but not as a way to free space', () {
      List<String> ids(String q, {required bool android}) => [
        for (final h in searchSettings(
          q,
          spots: SettingsIndex.spots,
          features: featureSections,
          zh: _zh,
          en: _en,
          androidFeatures: android,
        ))
          h.spot?.id ?? '',
      ];
      expect(ids('卸载', android: false), contains('engine-uninstall'));
      expect(ids('重置', android: false), contains('engine-reset'));
      expect(ids('释放空间', android: false), isNot(contains('engine-uninstall')));
      expect(ids('释放空间', android: true), contains('engine-uninstall'));
    });
  });
}
