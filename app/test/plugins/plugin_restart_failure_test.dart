import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

enum RestartOutcome { success, stopError, startError, stopping, delayedStopError }

/// Only native runtime IO is controlled. LocalRuntimeController and
/// EngineControl still process the status events and restart sequence.
class RestartBridge extends RuntimeBridge {
  RestartBridge(this.outcome);

  final RestartOutcome outcome;
  final stream = StreamController<RuntimeEvent>.broadcast(sync: true);
  final calls = <String>[];
  final stopResult = Completer<void>();
  RuntimeStatus current = const RuntimeStatus(phase: RuntimePhase.running);

  @override
  Stream<RuntimeEvent> get events => stream.stream;
  @override
  Future<RuntimeStatus> status() async => current;
  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async => const RuntimeLogSnapshot([], 0);

  void emit(RuntimePhase phase) {
    current = RuntimeStatus(phase: phase);
    stream.add(RuntimeStatusEvent(current));
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (outcome == RestartOutcome.stopError) throw PlatformException(code: 'synthetic_stop_failure');
    if (outcome == RestartOutcome.delayedStopError) await stopResult.future;
    emit(outcome == RestartOutcome.stopping ? RuntimePhase.stopping : RuntimePhase.installed);
  }

  @override
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) async {
    calls.add('start');
    if (outcome == RestartOutcome.startError) throw PlatformException(code: 'synthetic_start_failure');
    emit(RuntimePhase.starting);
  }
}

Future<RestartBridge> installAndOfferRestart(
  WidgetTester tester,
  RestartOutcome outcome, {
  Brightness brightness = Brightness.light,
  double width = 390,
  double scale = 1,
}) async {
  usePhoneView(tester);
  tester.view.physicalSize = Size(width * 2, 1688);
  final bridge = RestartBridge(outcome);
  final carrier = FakePluginCarrier();
  final client = DshClient.withCarrier(carrier);
  carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
  carrier.handlers['pluginManager/installBundle'] = (_) =>
      installResult(application: 'restart-required', restartReason: 'no-hmr');
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await client.close();
    await bridge.stream.close();
  });
  await tester.pumpWidget(
    testApp(
      Consumer(
        builder: (context, ref, _) {
          ref.watch(localRuntimeProvider);
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: const PluginsScreen(initialTab: PluginsTab.market),
          );
        },
      ),
      brightness: brightness,
      overrides: [
        ...pluginOverrides(fakeHost(client)),
        runtimeBridgeProvider.overrideWithValue(bridge),
        settingsProvider.overrideWith(TestSettings.new),
      ],
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
  expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.running);
  final card = find.widgetWithText(MarketCard, 'novel-writer');
  await tester.tap(find.descendant(of: card, matching: find.byType(PluginInstallButton)));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '安装到本机').last);
  await tester.pumpAndSettle();
  expect(carrier.argsOf('pluginManager/installBundle'), hasLength(1));
  expect(find.text('需要重启引擎'), findsOneWidget);
  expect(bridge.calls, isEmpty, reason: 'installation cannot restart without confirmation');
  return bridge;
}

Future<void> confirmRestart(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '重启引擎'));
  await tester.pumpAndSettle();
}

const restartFailureText = '未能重启内核，请查看引擎日志';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('declining the install restart leaves native runtime untouched', (tester) async {
    final bridge = await installAndOfferRestart(tester, RestartOutcome.success);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(bridge.calls, isEmpty);
    expect(find.text(restartFailureText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed install restart requests stop then start without a failure', (tester) async {
    final bridge = await installAndOfferRestart(tester, RestartOutcome.success);
    await confirmRestart(tester);
    expect(bridge.calls, ['stop', 'start']);
    expect(bridge.current.phase, RuntimePhase.starting, reason: 'start accepted does not prove engine ready');
    expect(find.text(restartFailureText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final outcome in [RestartOutcome.stopError, RestartOutcome.startError]) {
    testWidgets('install restart ${outcome.name} reports a reachable failure above its sheet', (tester) async {
      final bridge = await installAndOfferRestart(tester, outcome);
      await confirmRestart(tester);
      expect(bridge.calls, outcome == RestartOutcome.stopError ? ['stop'] : ['stop', 'start']);
      expect(tester.takeException(), isNull);
      expect(find.text(restartFailureText).hitTestable(), findsOneWidget);
      expect(find.widgetWithText(AlertDialog, restartFailureText), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(find.text(restartFailureText), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'only the failure dialog closes');
    });
  }

  testWidgets('an unfinished native stop reports failure and never requests start', (tester) async {
    final bridge = await installAndOfferRestart(tester, RestartOutcome.stopping);
    await confirmRestart(tester);
    expect(bridge.calls, ['stop']);
    expect(find.text(restartFailureText), findsNothing, reason: 'the existing stop wait has not timed out');
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(bridge.calls, ['stop']);
    expect(bridge.current.phase, RuntimePhase.stopping);
    expect(find.text(restartFailureText).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late restart error after the root is disposed is contained', (tester) async {
    final bridge = await installAndOfferRestart(tester, RestartOutcome.delayedStopError);
    await confirmRestart(tester);
    expect(bridge.calls, ['stop']);
    await tester.pumpWidget(const SizedBox.shrink());
    bridge.stopResult.completeError(PlatformException(code: 'synthetic_late_stop_failure'));
    await tester.pump();
    expect(bridge.calls, ['stop']);
    expect(find.text(restartFailureText), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
