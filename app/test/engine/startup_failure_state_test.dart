import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine/engine_status.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:dsh_app/ui/safe_mode/engine_failure_card.dart';
import 'package:dsh_app/ui/safe_mode/safe_mode_banner.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';

const _noToken = 'start failed: no startup token received within 180s';
const _noPort = 'start failed: token seen but port 3080 never accepted connections';
const _waiting = '启动失败，正在停止';
const _tokenReason = '启动等待已超时（180 秒内未收到启动标记），请查看日志';
const _portReason = '已收到启动标记，但本机服务端口尚未就绪，请查看日志';
const _private = 'synthetic-private-token';
const _execError = '/bin/sh: 1: exec: /usr/local/bin/dsh: Bad address';

RuntimeFailure _latest({FailureKind kind = FailureKind.startupFailed}) => RuntimeFailure(
  kind: kind,
  at: DateTime.utc(2026, 10, 1),
  exitCode: kind == FailureKind.launchFailed ? 126 : 1,
  summary: kind == FailureKind.launchFailed ? _execError : 'previous classified failure',
  recent: const ['old-plugin'],
  requiredRows: const ['old-required'],
);

RuntimeStatus _status({
  RuntimePhase phase = RuntimePhase.stopping,
  String? error = _noToken,
  RuntimeFailure? failure,
  bool safe = false,
  bool tidying = false,
}) => RuntimeStatus(
  phase: phase,
  bundledVersion: 'test-runtime',
  installedVersion: 'test-runtime',
  error: error,
  failure: failure,
  mainFailure: failure,
  mode: safe ? EngineMode.safe : EngineMode.normal,
  safeState: safe ? SafeModeState.on : SafeModeState.off,
  safeReason: safe ? 'manual' : null,
  tidyingFiles: tidying,
);

LocalRuntimeState _state(RuntimeStatus status) => LocalRuntimeState(loaded: true, status: status);

void main() {
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  Future<RecordingRuntime> pump(
    WidgetTester tester,
    RuntimeStatus status, {
    Widget home = const EngineScreen(),
    double scale = 1,
    bool narrow = false,
  }) async {
    final runtime = RecordingRuntime(_state(status));
    usePhoneSurface(tester);
    if (narrow) tester.view.physicalSize = const Size(640, 1280);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          runtimeBridgeProvider.overrideWithValue(FakeBridge()),
          localRuntimeLogsProvider.overrideWithBuild(
            (ref, notifier) => const ['[dsh-app] controlled cleanup diagnostic'],
          ),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: home,
          ),
        ),
      ),
    );
    // A STOPPING action has an indeterminate spinner. Advance virtual frames;
    // never wait for that spinner or the real 180-second native deadline.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    return runtime;
  }

  Finder action(String label) => find.descendant(of: find.byType(EngineActions), matching: find.text(label));

  InkWell actionWidget(WidgetTester tester, String label) =>
      tester.widget<InkWell>(find.ancestor(of: action(label), matching: find.byType(InkWell)).first);

  SettingsTile tileFor(WidgetTester tester, String label) =>
      tester.widget<SettingsTile>(find.ancestor(of: find.text(label), matching: find.byType(SettingsTile)).first);

  test('no-token startup failure has an exact safe explanation in both languages', () {
    expect(humanizeRuntimeError(_noToken), _tokenReason);
    AppLocale.use(AppLocale.en);
    expect(
      humanizeRuntimeError(_noToken),
      'Startup timed out: no startup token arrived within 180 seconds. Check the logs.',
    );
  });

  test('token without a ready port has a distinct explanation in both languages', () {
    expect(humanizeRuntimeError(_noPort), _portReason);
    expect(humanizeRuntimeError(_noPort.replaceFirst('3080', '65535')), _portReason);
    AppLocale.use(AppLocale.en);
    expect(
      humanizeRuntimeError(_noPort),
      'The startup token arrived, but the local service port did not become ready. Check the logs.',
    );
  });

  test('unknown and almost-matching startup details remain private', () {
    for (final raw in [
      'start failed: token=$_private',
      'start failed: controlled unknown failure $_private',
      '$_noToken token=$_private',
      '$_noPort token=$_private',
      '$_noToken\ntoken=$_private',
      'start failed: token seen but port $_private never accepted connections',
    ]) {
      expect(humanizeRuntimeError(raw), isNull, reason: 'unrecognized details must not become UI text');
      final detail = engineDetail(_status(phase: RuntimePhase.error, error: raw, failure: _latest()));
      expect(detail, appL10n.phoneEngineErrorSeeLogs);
      expect(detail, isNot(contains(_private)));
      expect(detail, isNot(contains('old-plugin')));
    }
  });

  test('the known integer storage message retains both localized numeric values', () {
    for (final locale in [AppLocale.zhCN, AppLocale.en]) {
      AppLocale.use(locale);
      expect(
        humanizeRuntimeError('install failed: 存储空间不足：需要约 640 MB，当前可用 212 MB'),
        appL10n.phoneEngineStorageDetails('640', '212'),
      );
      expect(humanizeRuntimeError('start failed: 存储空间不足'), appL10n.commonStorageFull);
    }
  });

  test('storage-like private text cannot escape through the existing error mapper', () {
    for (final locale in [AppLocale.zhCN, AppLocale.en]) {
      AppLocale.use(locale);
      for (final raw in [
        'start failed: 存储空间不足 token=$_private',
        'start failed: 存储空间不足：需要约 token=$_private MB，当前可用 212 MB',
      ]) {
        expect(humanizeRuntimeError(raw), isNull);
        expect(engineDetail(_status(phase: RuntimePhase.error, error: raw)), appL10n.phoneEngineErrorSeeLogs);
      }
    }
  });

  test('current startup error precedes the latest fatal card without mutating history', () {
    final latest = _latest();
    final status = _status(phase: RuntimePhase.error, failure: latest);
    expect(EngineStatusView.of(_state(status)).label, appL10n.phoneEngineStartupFailed);
    expect(engineDetail(status), _tokenReason);
    expect(EngineFailureCard.visibleFor(status), false);
    expect(identical(status.failure, latest), true);
    expect(identical(status.mainFailure, latest), true);
  });

  test('an accepted startup failure remains busy while the owner is stopping', () {
    final status = RuntimeStatus.fromMap({'phase': 'stopping', 'error': _noToken});
    expect(status.phase.isBusy, true);
    expect(EngineStatusView.of(_state(status)).label, _waiting);
    expect(EngineStatusView.of(_state(status)).tone, StatusTone.error);
    expect(engineDetail(status), contains(_waiting));
    expect(engineDetail(status), contains(_tokenReason));
    expect(EngineFailureCard.visibleFor(status), false);
  });

  test('the port failure remains stopping rather than becoming retryable idle', () {
    final status = _status(error: _noPort, failure: _latest());
    expect(status.phase.isBusy, true);
    expect(EngineStatusView.of(_state(status)).label, _waiting);
    expect(engineDetail(status), contains(_portReason));
    expect(engineDetail(status), isNot(contains('未收到启动标记')));
    expect(EngineFailureCard.visibleFor(status), false);
  });

  testWidgets('engine ring loop repaints without rebuilding its paint widget', (tester) async {
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        animations: true,
        home: const Center(child: EngineRing(tone: StatusTone.busy)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final ringPaint = find.descendant(of: find.byType(EngineRing), matching: find.byType(CustomPaint));
    final widget = tester.widget<CustomPaint>(ringPaint);
    final painter = widget.painter!;
    var repaints = 0;
    void countRepaint() => repaints++;
    painter.addListener(countRepaint);
    try {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.widget<CustomPaint>(ringPaint), same(widget));
        expect(tester.widget<CustomPaint>(ringPaint).painter, same(painter));
      }
      expect(repaints, 4);
      expect(tester.takeException(), isNull);
    } finally {
      painter.removeListener(countRepaint);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  test('ordinary stopping is not called a startup failure', () {
    final status = _status(error: null, failure: _latest());
    expect(EngineStatusView.of(_state(status)).label, appL10n.commonStopping);
    expect(EngineStatusView.of(_state(status)).tone, StatusTone.busy);
    expect(engineDetail(status), appL10n.phoneEngineStoppingEllipsis);
    expect(EngineFailureCard.visibleFor(status), false);
  });

  test('an ordinary classified exit keeps its structured failure despite an error string', () {
    final status = _status(phase: RuntimePhase.error, error: 'DSH exited unexpectedly (code 1)', failure: _latest());
    expect(EngineFailureCard.visibleFor(status), true);
    expect(engineDetail(status), contains('old-plugin'));
    expect(EngineStatusView.of(_state(status)).label, appL10n.phoneEngineStartupFailed);
  });

  test('a fresh launchFailed on the normal exit path retains its execution diagnosis', () {
    final latest = _latest(kind: FailureKind.launchFailed);
    final status = _status(phase: RuntimePhase.error, error: 'DSH exited unexpectedly (code 126)', failure: latest);
    expect(EngineFailureCard.visibleFor(status), true);
    expect(EngineStatusView.of(_state(status)).label, appL10n.phoneFailureLaunch);
    expect(engineDetail(status), contains(_execError));
    expect(engineDetail(status), isNot(contains('old-plugin')));
    expect(FailureCardModel.of(latest, lkgUseful: true).primary, FailureAction.retry);
  });

  test('starting and tidying retain their original phase meaning', () {
    for (final tidying in [false, true]) {
      final status = _status(phase: RuntimePhase.starting, error: null, failure: _latest(), tidying: tidying);
      expect(
        EngineStatusView.of(_state(status)).label,
        tidying ? appL10n.phoneEngineTidyingFiles : appL10n.phoneEngineStarting,
      );
      expect(EngineFailureCard.visibleFor(status), false);
      expect(status.phase.isBusy, true);
    }
  });

  test('an idle historical card is not removed when there is no current startup error', () {
    expect(EngineFailureCard.visibleFor(_status(phase: RuntimePhase.installed, error: null, failure: _latest())), true);
  });

  testWidgets('real engine page keeps actions, reset and workspace recovery unavailable during failed cleanup', (
    tester,
  ) async {
    final runtime = await pump(tester, _status(failure: _latest()));
    expect(find.textContaining(_waiting), findsOneWidget);
    for (final label in [appL10n.phoneEngineStart, appL10n.commonStop, appL10n.phoneEngineRestart]) {
      expect(actionWidget(tester, label).onTap, isNull);
    }
    await tester.scrollUntilVisible(
      find.text(appL10n.phoneEngineReset),
      500,
      // Keep the gesture on the page; its live log is another Scrollable.
      continuous: true,
      scrollable: find.byType(Scrollable).first,
    );
    // The rescue row sits just above reset, with the other ways out of trouble.
    final rescue = tester.widget<SettingsTile>(find.byKey(const ValueKey('workspace-recovery')));
    expect(rescue.onTap, isNull);
    expect(tileFor(tester, appL10n.phoneEngineReset).onTap, isNull);
    expect(runtime.starts, isEmpty);
    expect(runtime.stops, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same engine page permits a retry only after an error event', (tester) async {
    final runtime = await pump(tester, _status(failure: _latest()));
    expect(actionWidget(tester, appL10n.phoneEngineStart).onTap, isNull);
    expect(runtime.starts, isEmpty);
    runtime.emit(_state(_status(phase: RuntimePhase.error, failure: _latest())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(_tokenReason), findsOneWidget);
    expect(actionWidget(tester, appL10n.phoneEngineStartAgain).onTap, isNotNull);
    await tester.tap(action(appL10n.phoneEngineStartAgain));
    await tester.pump();
    expect(runtime.starts, ['start']);
    expect(runtime.stops, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real engine page shows the current cause instead of old plugin recovery actions', (tester) async {
    await pump(tester, _status(phase: RuntimePhase.error, failure: _latest()));
    expect(find.text(_tokenReason), findsOneWidget);
    expect(find.textContaining('old-plugin'), findsNothing);
    expect(find.textContaining('old-required'), findsNothing);
    expect(find.text(appL10n.phoneFailureRestore), findsNothing);
    expect(find.byType(EngineActions), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a compatibility combination with launchFailed uses safe current text and keeps logs reachable', (
    tester,
  ) async {
    // A legacy status can combine these fields even within one run. This input
    // tests the consumer policy, not a native thread interleaving or record age.
    await pump(
      tester,
      _status(
        phase: RuntimePhase.error,
        error: 'start failed: controlled post-spawn failure token=$_private',
        failure: _latest(kind: FailureKind.launchFailed),
      ),
    );
    expect(find.text(appL10n.phoneEngineErrorSeeLogs), findsOneWidget);
    expect(find.textContaining(_private), findsNothing);
    expect(find.textContaining(_execError), findsNothing);
    expect(find.textContaining('old-plugin'), findsNothing);
    await tester.scrollUntilVisible(find.byType(TerminalCard), 400, scrollable: find.byType(Scrollable).first);
    expect(find.text('[dsh-app] controlled cleanup diagnostic'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(appL10n.phoneEngineDiagnostics),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tileFor(tester, appL10n.phoneEngineDiagnostics).onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  const banner = Scaffold(body: SingleChildScrollView(child: SafeModeBanner()));

  testWidgets('safe-mode banner describes failed cleanup without claiming the engine stopped', (tester) async {
    final runtime = await pump(tester, _status(safe: true), home: banner);
    expect(find.text(_waiting), findsOneWidget);
    expect(find.text(appL10n.phoneSafeBannerStoppedHint), findsNothing);
    expect(find.text(appL10n.phoneFailureStartNormal), findsNothing);
    expect(runtime.starts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('safe-mode banner describes ordinary cleanup without calling it failure', (tester) async {
    await pump(tester, _status(safe: true, error: null), home: banner);
    expect(find.text(appL10n.phoneEngineStoppingEllipsis), findsOneWidget);
    expect(find.text(appL10n.phoneSafeBannerStoppedHint), findsNothing);
    expect(find.text(_waiting), findsNothing);
    expect(find.text(appL10n.phoneFailureStartNormal), findsNothing);
  });

  testWidgets('safe-mode banner still distinguishes a genuinely idle stopped engine', (tester) async {
    await pump(tester, _status(safe: true, phase: RuntimePhase.installed, error: null), home: banner);
    expect(find.text(appL10n.phoneSafeBannerStoppedHint), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, appL10n.phoneFailureStartNormal)).onPressed,
      isNotNull,
    );
  });

  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    testWidgets('failed-cleanup banner stays readable with large text in $locale', (tester) async {
      AppLocale.use(locale);
      await pump(tester, _status(safe: true), home: banner, scale: 2, narrow: true);
      expect(find.text(locale == AppLocale.en ? 'Startup failed; stopping' : _waiting), findsOneWidget);
      expect(find.text(appL10n.phoneSafeBannerStoppedHint), findsNothing);
      for (final element in tester.elementList(find.byType(RichText))) {
        final paragraph = element.renderObject;
        if (paragraph is RenderParagraph) expect(paragraph.didExceedMaxLines, false);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
