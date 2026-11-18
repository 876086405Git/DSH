// Behaviour of the startup gate, onboarding helpers and small formatters.

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/progress_halo.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine/engine_status.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_harness.dart';

const _v = 'r1-dsh0.2.0-rc.2-node24.22.1-ubuntu24.04.5-a45b1e8964a3';

RuntimeStatus _status(RuntimePhase phase, {String? installed, String bundled = _v}) =>
    RuntimeStatus(phase: phase, bundledVersion: bundled, installedVersion: installed);

void main() {
  group('initialOnboardingStep', () {
    const fresh = OnboardingPrefs(loaded: true);
    const seen = OnboardingPrefs(loaded: true, welcomeSeen: true);
    const skipped = OnboardingPrefs(loaded: true, welcomeSeen: true, keySkipped: true);

    test('fresh install starts at the welcome page', () {
      expect(
        initialOnboardingStep(status: _status(RuntimePhase.notInstalled), hasApiKey: false, prefs: fresh),
        OnboardingStep.welcome,
      );
    });

    test('an interrupted first install resumes at setup', () {
      expect(
        initialOnboardingStep(status: _status(RuntimePhase.notInstalled), hasApiKey: false, prefs: seen),
        OnboardingStep.runtime,
      );
      expect(
        initialOnboardingStep(status: _status(RuntimePhase.installing), hasApiKey: false, prefs: fresh),
        OnboardingStep.runtime,
      );
    });

    test('an app upgrade with an older rootfs goes straight to setup', () {
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.notInstalled, installed: 'r0-old'),
          hasApiKey: true,
          prefs: fresh,
        ),
        OnboardingStep.runtime,
      );
    });

    test('installed without a key asks for one unless skipped', () {
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.installed, installed: _v),
          hasApiKey: false,
          prefs: seen,
        ),
        OnboardingStep.apiKey,
      );
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.installed, installed: _v),
          hasApiKey: false,
          prefs: skipped,
        ),
        isNull,
      );
    });

    test('a custom provider on the local engine is enough to get in', () {
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.installed, installed: _v),
          hasApiKey: false,
          hasCustomProvider: true,
          prefs: seen,
        ),
        isNull,
      );
      // It does not skip setup, though: the provider lives in the engine.
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.notInstalled, installed: 'r0-old'),
          hasApiKey: false,
          hasCustomProvider: true,
          prefs: seen,
        ),
        OnboardingStep.runtime,
      );
    });

    test('installed with a key lands in the shell, even if the engine errored', () {
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.running, installed: _v),
          hasApiKey: true,
          prefs: fresh,
        ),
        isNull,
      );
      expect(
        initialOnboardingStep(
          status: _status(RuntimePhase.error, installed: _v),
          hasApiKey: true,
          prefs: fresh,
        ),
        isNull,
      );
    });

    test('a failed install (error, nothing current installed) returns to setup', () {
      expect(
        initialOnboardingStep(status: _status(RuntimePhase.error), hasApiKey: true, prefs: seen),
        OnboardingStep.runtime,
      );
    });
  });

  group('API key helpers', () {
    test('normalize strips whitespace from pastes', () {
      expect(normalizeApiKey('  sk-abc\n def \t'), 'sk-abcdef');
    });

    test('warnings are light and non-blocking', () {
      expect(apiKeyWarning(''), isNull);
      expect(apiKeyWarning('sk-0123456789abcdef0123'), isNull);
      expect(apiKeyWarning('sk-short'), isNotNull);
      expect(apiKeyWarning('or-0123456789abcdef0123'), isNotNull);
    });

    test('mask keeps only the prefix and last four', () {
      expect(maskApiKey('sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9'), 'sk-…a3f9');
      expect(maskApiKey(''), '');
      expect(maskApiKey('abc'), '••••');
    });
  });

  group('formatters', () {
    test('sessions group by local calendar day', () {
      final now = DateTime(2026, 10, 23, 9);
      expect(sessionDayOf(DateTime(2026, 10, 23, 0, 1), now), SessionDay.today);
      expect(sessionDayOf(DateTime(2026, 10, 22, 23, 59), now), SessionDay.yesterday);
      // 23 Oct 2026 is a Friday; the week starts on Monday the 19th.
      expect(sessionDayOf(DateTime(2026, 10, 20), now), SessionDay.thisWeek);
      expect(sessionDayOf(DateTime(2026, 10, 19, 0, 1), now), SessionDay.thisWeek);
      expect(sessionDayOf(DateTime(2026, 10, 18, 23, 59), now), SessionDay.earlier);
      // On a Monday, Sunday is 昨天 and nothing is 本周 before it.
      final monday = DateTime(2026, 10, 19, 9);
      expect(sessionDayOf(DateTime(2026, 10, 18, 12), monday), SessionDay.yesterday);
      expect(sessionDayOf(DateTime(2026, 10, 17, 12), monday), SessionDay.earlier);
    });

    test('runtime version is shortened to release and hash', () {
      expect(shortRuntimeVersion(_v), 'r1 · a45b1e89');
      expect(shortRuntimeVersion(null), '—');
      expect(shortRuntimeVersion('custom'), 'custom');
    });

    test('runtime errors read as sentences', () {
      expect(humanizeRuntimeError('install failed: 存储空间不足：需要约 640 MB，当前可用 212 MB'), '存储空间不足：需要约 640 MB，当前可用 212 MB');
      expect(humanizeRuntimeError('DSH exited unexpectedly (code 137)'), '引擎意外退出了');
      expect(humanizeRuntimeError(null), isNull);
      expect(humanizeRuntimeError('install failed: raw native exception'), isNull);
      expect(humanizeRuntimeError('start failed: token=secret'), isNull);
    });

    test('ANSI colour codes are stripped from logs', () {
      expect(stripAnsi('\x1B[2m[gateway]\x1B[0m ok'), '[gateway] ok');
    });

    test('engine status labels', () {
      final installing = EngineStatusView.of(
        const LocalRuntimeState(
          status: RuntimeStatus(phase: RuntimePhase.installing),
          progress: RuntimeProgressEvent(step: 'extract', done: 46, total: 100),
        ),
      );
      expect(installing.label, '正在安装 · 46%');
      expect(EngineStatusView.of(const LocalRuntimeState(status: runningStatus)).label, '运行中');
    });
  });

  testWidgets('failed install hides raw errors and has one log action', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: RuntimeSetupPage(onDone: () {}),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(
              const LocalRuntimeState(
                loaded: true,
                status: RuntimeStatus(phase: RuntimePhase.error, error: 'install failed: raw-secret'),
                progress: RuntimeProgressEvent(step: 'extract', done: 50, total: 100),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('查看日志'), findsOneWidget);
    expect(find.text('解压时出错'), findsOneWidget);
    expect(tester.widgetList<Text>(find.byType(Text)).any((t) => RegExp(r'[A-Za-z]').hasMatch(t.data ?? '')), isFalse);
    expect(tester.widget<ProgressHalo>(find.byType(ProgressHalo)).value, 0);
    final left = tester.getRect(find.widgetWithText(OutlinedButton, '查看日志'));
    final right = tester.getRect(find.widgetWithText(FilledButton, '重试'));
    expect(left.size, right.size);
    expect(right.left - left.right, 12);
  });

  for (final scale in [1.5, 2.0]) {
    testWidgets('install metadata fits at text scale $scale', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: RuntimeSetupPage(onDone: () {}),
            ),
          ),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(
                const LocalRuntimeState(
                  loaded: true,
                  status: RuntimeStatus(phase: RuntimePhase.installing),
                  progress: RuntimeProgressEvent(step: 'extract', done: 1048576, total: 10485760),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();
      final meta = find.text('1 / 10 MB');
      expect(meta, findsOneWidget);
      final box = find.ancestor(of: meta, matching: find.byType(SizedBox)).first;
      expect(tester.getSize(box).height, greaterThanOrEqualTo(12 * scale * 1.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('setup primes notifications once after progress starts', (tester) async {
    usePhoneSurface(tester);
    final runtime = _ProgressRuntime();
    final channel = _CountingNotify();
    await tester.pumpWidget(
      goldenApp(
        home: RuntimeSetupPage(onDone: () {}),
        brightness: Brightness.light,
        overrides: [localRuntimeProvider.overrideWith(() => runtime), notifyChannelProvider.overrideWithValue(channel)],
      ),
    );
    await tester.pump();
    expect(channel.calls, 0);
    runtime.progress(1);
    await tester.pump();
    runtime.progress(2);
    await tester.pump();
    expect(channel.calls, 1);
    expect(find.text('全程在本机完成'), findsOneWidget);
  });

  group('while it installs', () {
    Future<void> setup(WidgetTester tester, String os, {bool waiting = false}) async {
      usePhoneSurface(tester);
      final runtime = _ProgressRuntime();
      await tester.pumpWidget(
        goldenApp(
          home: RuntimeSetupPage(onDone: () {}, waiting: waiting),
          brightness: Brightness.light,
          overrides: [
            operatingSystemProvider.overrideWithValue(os),
            localRuntimeProvider.overrideWith(() => runtime),
            notifyChannelProvider.overrideWithValue(_CountingNotify()),
          ],
        ),
      );
      await tester.pump();
      runtime.progress(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    final zh = lookupL10n(AppLocale.zhCN);

    testWidgets('on HarmonyOS: stay here, no notification promised', (tester) async {
      await setup(tester, 'ohos', waiting: true);
      expect(find.text(zh.harmonySetupStay), findsOneWidget);
      expect(find.text(zh.setupNotifyWhenDone), findsNothing);
    });

    testWidgets('on Android: as ever', (tester) async {
      await setup(tester, 'android');
      expect(find.text(zh.shellRuntimeLocalOnly), findsOneWidget);
      expect(find.text(zh.harmonySetupStay), findsNothing);
    });
  });

  testWidgets('update notes begin 16 inside the card', (tester) async {
    usePhoneSurface(tester);
    final release = ReleaseInfo(
      version: AppVersion.tryParse('1.2.0+2')!,
      tag: 'v1.2.0',
      notes: '修复了连接恢复',
      apks: {ApkFlavor.arm64: ReleaseAsset(name: 'app.apk', url: Uri.parse('https://example.com/app.apk'), size: 1234)},
    );
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(body: SafeArea(child: UpdateSheet())),
        brightness: Brightness.light,
        overrides: [
          appUpdateProvider.overrideWith(
            () => _FixedUpdate(
              AppUpdateState(
                loaded: true,
                current: AppVersion.tryParse('1.0.0+1')!,
                flavor: ApkFlavor.arm64,
                check: UpdateCheckPhase.available,
                latest: release,
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    final notes = tester.getRect(find.byType(MarkdownBody));
    final card = tester.getRect(find.byType(SheetGroup));
    expect(notes.left - card.left, closeTo(16, .5));
    expect(card.right - notes.right, closeTo(16, .5));
    expect(tester.takeException(), isNull);
  });

  group('root gate', () {
    Future<void> pumpGate(WidgetTester tester, LocalRuntimeState runtime, AppSettings settings) async {
      await tester.pumpWidget(
        goldenApp(
          home: const RootGate(),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(() => FakeRuntime(runtime)),
            settingsProvider.overrideWith(() => FakeSettings(settings)),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('waits on a splash until the runtime reports in', (tester) async {
      await pumpGate(tester, const LocalRuntimeState(), const AppSettings(loaded: true));
      expect(find.byType(WelcomePage), findsNothing);
      expect(find.byType(RuntimeSetupPage), findsNothing);
    });

    testWidgets('not installed (welcome already seen) shows setup', (tester) async {
      await pumpGate(
        tester,
        const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.notInstalled)),
        const AppSettings(loaded: true),
      );
      // The fake onboarding prefs report welcomeSeen = true.
      expect(find.byType(RuntimeSetupPage), findsOneWidget);
    });

    testWidgets('installed without a key shows the connect step with a skip option', (tester) async {
      await pumpGate(
        tester,
        LocalRuntimeState(loaded: true, status: _status(RuntimePhase.installed, installed: _v)),
        const AppSettings(loaded: true),
      );
      // Account sign-in (recommended) or API key; ConnectPage hosts both.
      expect(find.byType(ConnectPage), findsOneWidget);
      expect(find.text('稍后设置'), findsOneWidget);
    });
  });

  group('small screen, large text: nothing overflows', () {
    final screens = <String, Widget Function()>{
      'welcome': () => WelcomePage(onStart: () {}),
      'setup': () => RuntimeSetupPage(onDone: () {}),
      'api key': () => ApiKeyPage(onDone: () {}),
      'settings': () => const SettingsScreen(),
      'engine': () => const EngineScreen(),
      'remote': () => const RemoteScreen(),
      'drawer': () => HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
    };
    for (final MapEntry(key: name, value: build) in screens.entries) {
      testWidgets(name, (tester) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(320 * 2, 568 * 2);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          goldenApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: build(),
              ),
            ),
            brightness: Brightness.light,
            overrides: [
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
              ),
              localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
              settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
              sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
      });
    }
  });
}

class _ProgressRuntime extends FakeRuntime {
  _ProgressRuntime()
    : super(const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.installing)));

  void progress(int done) {
    state = state.copyWith(
      progress: RuntimeProgressEvent(step: 'extract', done: done, total: 10),
    );
  }
}

class _CountingNotify extends NotifyChannel {
  int calls = 0;

  @override
  Future<NotifySystemStatus> status() async {
    calls++;
    return const NotifySystemStatus();
  }
}

class _FixedUpdate extends AppUpdateController {
  _FixedUpdate(this.initial);

  final AppUpdateState initial;

  @override
  AppUpdateState build() => initial;
}
