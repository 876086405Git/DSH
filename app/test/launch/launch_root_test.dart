// 启动画面 at the app root: RootGate says "ready" the frame its first page is up (no waiting
// for the engine), and the layer over the app comes and goes without the page under it losing
// its state.

import 'package:dsh_app/app.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/launch/startup_trace.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui/theme/theme_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';
import 'support.dart';

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => setState(() => taps++), child: Text('taps $taps')),
    ),
  );
}

/// Builds the app root again a moment later, as a provider changing does.
Future<void> _rebuildRoot(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  tester.element(find.byType(DshApp)).markNeedsBuild();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => LaunchController.active.value = null);

  testWidgets('RootGate: ready as soon as home is up, with the engine still starting', (tester) async {
    final channel = FakeLaunchChannel();
    final c = LaunchController(snapshot: snapshotFor(), channel: channel);
    LaunchController.active.value = c;
    final runtime = RecordingRuntime(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.installed, bundledVersion: 'r1', installedVersion: 'r1'),
      ),
    );
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RootGate(home: Scaffold(body: Text('home'))),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          settingsProvider.overrideWith(
            () => FakeSettings(const AppSettings(loaded: true, apiKey: 'key', autoStartLocal: true)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(channel.marks, contains('ready'));
    // The engine was asked to start, and nobody waited for it.
    expect(runtime.starts, ['start']);
    await tester.pump(const Duration(seconds: 1));
  });

  group('the startup watch on iOS', () {
    late List<String> said;
    final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

    Widget gate(AppSettings settings) => goldenApp(
      home: const RootGate(home: Scaffold(body: Text('home'))),
      brightness: Brightness.light,
      overrides: [
        localRuntimeProvider.overrideWith(
          () => RecordingRuntime(
            const LocalRuntimeState(
              loaded: true,
              status: RuntimeStatus(phase: RuntimePhase.installed, bundledVersion: 'r1', installedVersion: 'r1'),
            ),
          ),
        ),
        settingsProvider.overrideWith(() => FakeSettings(settings)),
      ],
    );

    setUp(() {
      said = [];
      StartupTrace.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dsh/startup'),
        (call) async {
          said.add('${call.method}:${call.arguments}');
          return null;
        },
      );
    });

    testWidgets('no launch screen: stands down when the first page is up', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(gate(const AppSettings(loaded: true, apiKey: 'key')));
      await tester.pump();
      await tester.pump();
      expect(said, containsAllInOrder(['mark:first page', 'finished:null']));
      await tester.pump(const Duration(seconds: 1));
    }, variant: ios);

    testWidgets('says what the first page is waiting for, and stays', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(gate(const AppSettings(apiKey: 'key')));
      await tester.pump();
      await tester.pump();
      expect(said.any((s) => s.contains('waiting: settings false')), isTrue);
      expect(said, isNot(contains('finished:null')));
      await tester.pump(const Duration(seconds: 1));
    }, variant: ios);

    testWidgets('a launch screen over it: stays until that has gone', (tester) async {
      usePhoneSurface(tester);
      final c = LaunchController(snapshot: snapshotFor(), channel: FakeLaunchChannel());
      LaunchController.active.value = c;
      await tester.pumpWidget(gate(const AppSettings(loaded: true, apiKey: 'key')));
      await tester.pump();
      await tester.pump();
      expect(said, contains('mark:first page'));
      expect(said, isNot(contains('finished:null')));
      c.gone();
      await tester.pump();
      expect(said, contains('finished:null'));
      await tester.pump(const Duration(seconds: 1));
    }, variant: ios);

    testWidgets('tapped away before the first page: still watching until that comes', (tester) async {
      usePhoneSurface(tester);
      final c = LaunchController(snapshot: snapshotFor(), channel: FakeLaunchChannel());
      LaunchController.active.value = c;
      c.gone();
      await tester.pump();
      expect(said, isNot(contains('finished:null')));
      await tester.pumpWidget(gate(const AppSettings(loaded: true, apiKey: 'key')));
      await tester.pump();
      await tester.pump();
      expect(said, contains('finished:null'));
      await tester.pump(const Duration(seconds: 1));
    }, variant: ios);
  });

  testWidgets('the app root tells a held cold start when this phone\'s engine is running', (tester) async {
    usePhone(tester);
    final c = LaunchController(
      snapshot: snapshotFor(sdk: 30, systemSplash: false, coldEngine: true),
      channel: FakeLaunchChannel(),
    );
    LaunchController.active.value = c;
    final runtime = RecordingRuntime(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.starting, bundledVersion: 'r1', installedVersion: 'r1'),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          localRuntimeProvider.overrideWith(() => runtime),
        ],
        child: const DshApp(home: _Counter()),
      ),
    );
    await tester.pump();
    c.ready();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.phase, LaunchPhase.playing);
    runtime.emit(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.running, bundledVersion: 'r1', installedVersion: 'r1'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(c.phase, LaunchPhase.leaving);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(LaunchController.active.value, isNull);
  });

  // iOS: `coldEngine` is true whenever the engine is bundled, and on a first run nothing starts it.
  testWidgets('a cold start with no engine coming: the layer still goes', (tester) async {
    usePhone(tester);
    final c = LaunchController(
      snapshot: snapshotFor(sdk: 26, systemSplash: false, coldEngine: true, systemIcon: false),
      channel: FakeLaunchChannel(),
    );
    LaunchController.active.value = c;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
        child: const DshApp(home: _Counter()),
      ),
    );
    await tester.pump();
    c.ready();
    // Providers settling at launch build the root again, mid-motion.
    await _rebuildRoot(tester);
    await _rebuildRoot(tester);
    for (var t = 0; t < 2000; t += 20) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(LaunchController.active.value, isNull);
  });

  // MaterialApp builds Theme for AnimationStyle.noAnimation and AnimatedTheme for anything else:
  // what the app's builder holds has to survive that swap, as the navigator does.
  testWidgets('the theme cross-fade coming on or off keeps the layers over the navigator', (tester) async {
    usePhone(tester);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
        child: const DshApp(home: _Counter()),
      ),
    );
    final first = tester.state(find.byType(ThemeRevealHost));
    // Long enough for the stored appearance to arrive and the cross-fade to come on.
    for (var i = 0; i < 10; i++) {
      await _rebuildRoot(tester);
    }
    final settled = tester.state(find.byType(ThemeRevealHost));
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.state(find.byType(ThemeRevealHost)), same(settled));
    expect(settled, same(first));
  });

  testWidgets('the app root: the layer over everything, then gone; the page keeps its state', (tester) async {
    usePhone(tester);
    final c = LaunchController(snapshot: snapshotFor(sdk: 30, systemSplash: false), channel: FakeLaunchChannel());
    LaunchController.active.value = c;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
        child: const DshApp(home: _Counter()),
      ),
    );
    await tester.pump();
    expect(find.byType(LaunchOverlay), findsOneWidget);
    expect(c.phase, LaunchPhase.playing);
    // A tap skips the launch screen, and doesn't reach the page under it.
    await tester.tap(find.text('taps 0'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('taps 0'), findsOneWidget);
    expect(c.phase, LaunchPhase.leaving);
    c.ready();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(c.phase, LaunchPhase.gone);
    expect(find.byType(LaunchOverlay), findsNothing);
    expect(LaunchController.active.value, isNull);
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);
  });
}
