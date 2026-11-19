import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/safe_mode_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_status.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/safe_mode/engine_failure_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/support/fake_relay.dart';
import '../shell/golden_harness.dart';
import 'support.dart';

const execError = '/bin/sh: 1: exec: /usr/local/bin/dsh: Bad address';

class _TawcBridge extends FakeBridge {
  final setTawc = Completer<void>();

  @override
  Future<void> setTawcEngine(bool enabled) {
    calls.add('setTawcEngine:$enabled');
    return setTawc.future;
  }
}

RuntimeFailure launchFailure({bool safe = false}) => RuntimeFailure.fromMap({
  'kind': 'launchFailed',
  'at': 123,
  'exitCode': 126,
  'safeMode': safe,
  'summary': execError,
  // Recent plugin changes are not evidence of this shell execution failure.
  'recent': ['unrelated-plugin'],
  'requiredRows': ['unrelated-row'],
})!;

void main() {
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('launch failure crosses the native bridge without blaming memory or plugins', () {
    for (final safe in [false, true]) {
      final f = launchFailure(safe: safe);
      expect(f.kind.counts, isFalse);
      expect(f.kind.isFatal, isFalse);
      final model = FailureCardModel.of(f, lkgUseful: true);
      expect(model.title, '本机运行环境未能启动');
      expect(model.body, '查看日志了解原因，或连接远程主机继续使用');
      expect(model.detail, execError);
      expect(model.culprits, isEmpty);
      expect(model.primary, FailureAction.retry);
      expect(model.secondary, [FailureAction.remote, FailureAction.showLog]);
      expect(failureOneLiner(f), contains(execError));
      expect(failureOneLiner(f), isNot(contains('unrelated')));
      expect(EngineStatusView.of(LocalRuntimeState(loaded: true, status: failedStatus(failure: f))).label, model.title);
    }
  });

  testWidgets('the PRoot recovery action saves the tawcroot choice before starting', (tester) async {
    usePhoneSurface(tester);
    final bridge = _TawcBridge();
    final status = RuntimeStatus.fromMap({
      'phase': 'error',
      'failure': {'kind': 'launchFailed', 'exitCode': 126, 'summary': execError},
      'tawcRecoveryAvailable': true,
    });
    final runtime = RecordingRuntime(LocalRuntimeState(loaded: true, status: status));
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(bridge), localRuntimeProvider.overrideWith(() => runtime)],
        home: const Scaffold(body: EngineFailureCard()),
      ),
    );
    await tester.pump();
    expect(find.widgetWithText(OutlinedButton, appL10n.commonRetry), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, appL10n.phoneFailureRetryWithTawcroot));
    expect(bridge.calls, ['setTawcEngine:true']);
    expect(runtime.starts, isEmpty);
    bridge.setTawc.complete();
    await tester.pump();
    expect(runtime.starts, ['start']);
    expect(runtime.stops, 0);
  });

  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('launch recovery fits 320dp / $locale / $brightness / $scale', (tester) async {
          AppLocale.use(locale);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 960);
          addTearDown(tester.view.reset);
          final bridge = FakeBridge(
            lkg: lkgUseful,
            hazards: const [SafeHazard(path: '/root/.env', kind: 'homeEnv', detail: 'Not launch evidence')],
          );
          final runtime = RecordingRuntime(
            LocalRuntimeState(loaded: true, status: failedStatus(failure: launchFailure(safe: true))),
          );
          await tester.pumpWidget(
            goldenApp(
              brightness: brightness,
              overrides: [
                runtimeBridgeProvider.overrideWithValue(bridge),
                localRuntimeProvider.overrideWith(() => runtime),
                settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
              ],
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: const SingleChildScrollView(
                    child: Padding(padding: EdgeInsets.all(16), child: EngineFailureCard()),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text(appL10n.phoneFailureLaunch), findsOneWidget);
          final retry = tester.getRect(find.widgetWithText(FilledButton, appL10n.commonRetry));
          final remote = tester.getRect(find.widgetWithText(OutlinedButton, appL10n.commonRemoteHost));
          for (final rect in [retry, remote]) {
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.left, closeTo(320 - rect.right, .5));
          }
          expect(retry.height, remote.height);
          expect(bridge.calls, isNot(contains('lastKnownGood')));
          expect(bridge.calls, isNot(contains('safePreflight')));
          expect(find.text('/root/.env'), findsNothing);
          for (final element in tester.elementList(find.byType(RichText))) {
            final paragraph = element.renderObject;
            if (paragraph is RenderParagraph) {
              expect(paragraph.didExceedMaxLines, isFalse, reason: paragraph.text.toPlainText());
            }
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('remote recovery opens the existing page without starting or switching a host', (tester) async {
    usePhoneSurface(tester);
    final bridge = FakeBridge(log: const [execError]);
    final runtime = RecordingRuntime(LocalRuntimeState(loaded: true, status: failedStatus(failure: launchFailure())));
    final relay = FakeRelayBackend();
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          runtimeBridgeProvider.overrideWithValue(bridge),
          localRuntimeProvider.overrideWith(() => runtime),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(relay),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
        ],
        home: const Scaffold(
          body: Padding(padding: EdgeInsets.all(16), child: EngineFailureCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(container.read(activeHostProvider), HostRef.local);
    await tester.tap(find.widgetWithText(OutlinedButton, appL10n.commonRemoteHost));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(container.read(activeHostProvider), HostRef.local);
    expect(runtime.starts, isEmpty);
    expect(runtime.stops, 0);
    expect(relay.connected, isEmpty);
    expect(relay.pendingLogin, isNull);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.byType(RemoteScreen))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text(appL10n.commonViewLogs));
    await tester.pumpAndSettle();
    expect(find.text(execError), findsWidgets);
    expect(bridge.calls, contains('failureLog'));
    expect(tester.takeException(), isNull);
  });
}
