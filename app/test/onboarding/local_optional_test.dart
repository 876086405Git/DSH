// The on-device runtime is optional: first run asks 本机 or 远程主机, a phone
// without the runtime opens home, every 本机 entry offers to install, the
// runtime can be uninstalled, and the auto start setting holds.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/local_footprint.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/local_install.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/onboarding/runtime_choice.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/web/local_web_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FakeBrowser, FixedAccount, NoConnection;
import '../remote/support/fake_relay.dart';
import '../remote/support/fake_ssh.dart';
import '../shell/golden_harness.dart';
import 'local_optional_support.dart';

const _local = ValueKey('runtime-option-local');
const _remote = ValueKey('runtime-option-remote');

RuntimeStatus _status(RuntimePhase phase, {String? installed}) =>
    RuntimeStatus(phase: phase, bundledVersion: bundled, installedVersion: installed);

Future<void> _frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('initialOnboardingStep without the runtime', () {
    const seen = OnboardingPrefs(loaded: true, welcomeSeen: true);
    const declined = OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true);

    test('a phone that runs on a remote host goes straight home', () {
      expect(initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: declined), isNull);
      // No key needed either: the remote host has its own.
      expect(
        initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: declined.copyWith(keySkipped: false)),
        isNull,
      );
    });

    test('an install underway carries on', () {
      expect(
        initialOnboardingStep(status: _status(RuntimePhase.installing), hasApiKey: false, prefs: declined),
        OnboardingStep.runtime,
      );
    });

    test('an upgrade runs unless the person left a failed one for a remote host', () {
      final upgrade = _status(RuntimePhase.notInstalled, installed: 'r4-old');
      expect(initialOnboardingStep(status: upgrade, hasApiKey: true, prefs: seen), OnboardingStep.runtime);
      expect(initialOnboardingStep(status: upgrade, hasApiKey: true, prefs: declined), isNull);
    });

    test('not declined: welcome on a fresh phone, the choice after it', () {
      expect(
        initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: const OnboardingPrefs(loaded: true)),
        OnboardingStep.welcome,
      );
      expect(initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: seen), OnboardingStep.runtime);
    });

    test('the setup step asks only when there is nothing to resume', () {
      expect(runtimeStepAsks(missingStatus), isTrue);
      expect(runtimeStepAsks(_status(RuntimePhase.error)), isTrue);
      expect(runtimeStepAsks(_status(RuntimePhase.installing)), isFalse);
      expect(runtimeStepAsks(_status(RuntimePhase.notInstalled, installed: 'r4-old')), isFalse);
    });

    test('only a real report counts as missing', () {
      expect(missingStatus.runtimeMissing, isTrue);
      expect(const RuntimeStatus.unknown().runtimeMissing, isFalse);
      expect(stoppedStatus.runtimeMissing, isFalse);
    });
  });

  group('footprint', () {
    test('suggests the remote host on a small or full phone only', () {
      expect(roomyPhone.suggestRemote, isFalse);
      expect(smallPhone.lowMemory, isTrue);
      expect(smallPhone.suggestRemote, isTrue);
      expect(fullPhone.lowStorage, isTrue);
      expect(fullPhone.requiredStorageMb, 862);
      expect(fullPhone.requiredRoundedMb, 900);
      expect(const LocalFootprint().suggestRemote, isFalse);
      expect(LocalFootprint.round(749), 750);
    });
  });

  group('the choice', () {
    Future<(RecordingLocalRuntime, ProviderContainer)> pump(
      WidgetTester tester, {
      LocalFootprint phone = roomyPhone,
      RuntimeStatus status = missingStatus,
      VoidCallback? onRemote,
      bool choose = true,
      bool available = true,
      OnboardingPrefs prefs = const OnboardingPrefs(loaded: true, welcomeSeen: true),
    }) async {
      final runtime = RecordingLocalRuntime(LocalRuntimeState(loaded: true, status: status, available: available));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: RuntimeSetupPage(onDone: () {}, choose: choose, onRemote: onRemote),
          brightness: Brightness.light,
          prefs: prefs,
          overrides: [localRuntimeProvider.overrideWith(() => runtime), footprint(phone)],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return (runtime, ProviderScope.containerOf(tester.element(find.byType(RuntimeSetupPage))));
    }

    testWidgets('asks first; 本机 installs, with what it costs', (tester) async {
      var remote = 0;
      final (runtime, _) = await pump(tester, onRemote: () => remote++);
      expect(find.text('DSH 在哪里运行？'), findsOneWidget);
      expect(find.text('存储约 750 MB · 内存约 300 MB'), findsOneWidget);
      expect(find.text('推荐'), findsNothing);
      expect(tester.getSemantics(find.byKey(_local)), isSemantics(isSelected: true));
      expect(tester.getSemantics(find.byKey(_remote)), isSemantics(isSelected: false));
      expect(runtime.calls, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pump();
      expect(runtime.calls, ['install']);
      expect(remote, 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('DSH 在哪里运行？'), findsNothing);
      expect(find.text('正在准备运行环境'), findsOneWidget);
    });

    testWidgets('the two cards are the same size, glyph and mark equally inset', (tester) async {
      await pump(tester, onRemote: () {});
      final local = tester.getRect(find.byKey(_local));
      final remote = tester.getRect(find.byKey(_remote));
      expect(local.width, remote.width);
      expect(local.height, closeTo(remote.height, 0.5));
      expect(remote.top - local.bottom, closeTo(RuntimeOptionCard.gap, 0.5));
      for (final (key, glyph) in [(_local, AppIcons.thisPhone), (_remote, AppIcons.computer)]) {
        final card = tester.getRect(find.byKey(key));
        final tile = tester.getRect(
          find
              .ancestor(
                of: find.descendant(of: find.byKey(key), matching: find.byIcon(glyph)),
                matching: find.byType(SizedBox),
              )
              .first,
        );
        final mark = tester.getRect(
          find.descendant(
            of: find.byKey(key),
            matching: find.byWidgetPredicate(
              (w) => w is Icon && (w.icon == AppIcons.radioOn || w.icon == AppIcons.radioOff),
            ),
          ),
        );
        expect(tile.left - card.left, RuntimeOptionCard.pad);
        expect(card.right - mark.right, RuntimeOptionCard.pad);
        expect(tile.center.dy, closeTo(card.center.dy, 0.5));
        expect(mark.center.dy, closeTo(card.center.dy, 0.5));
      }
    });

    testWidgets('a small phone suggests the remote host', (tester) async {
      var remote = 0;
      final (runtime, _) = await pump(tester, phone: smallPhone, onRemote: () => remote++);
      expect(find.text('推荐'), findsOneWidget);
      expect(tester.getSemantics(find.byKey(_remote)), isSemantics(isSelected: true));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pump();
      expect(remote, 1);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('picking 本机 on a small phone still installs', (tester) async {
      var remote = 0;
      final (runtime, _) = await pump(tester, phone: smallPhone, onRemote: () => remote++);
      await tester.tap(find.byKey(_local));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSemantics(find.byKey(_local)), isSemantics(isSelected: true));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pump();
      expect(runtime.calls, ['install']);
      expect(remote, 0);
    });

    testWidgets('short of storage says how much it needs', (tester) async {
      await pump(tester, phone: fullPhone, onRemote: () {});
      expect(find.text('存储空间不足，需要约 900 MB'), findsOneWidget);
      expect(tester.getSemantics(find.byKey(_remote)), isSemantics(isSelected: true));
    });

    testWidgets('a build without the runtime only goes on with the remote host', (tester) async {
      var remote = 0;
      final (runtime, _) = await pump(tester, available: false, onRemote: () => remote++);
      expect(find.text('这台设备暂时不能在本机运行 DSH'), findsOneWidget);
      expect(find.text('推荐'), findsNothing);
      expect(
        tester.getSemantics(find.byKey(_local)),
        isSemantics(isSelected: false, isEnabled: false, hasEnabledState: true),
      );
      expect(tester.getSemantics(find.byKey(_remote)), isSemantics(isSelected: true));

      await tester.tap(find.byKey(_local));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSemantics(find.byKey(_remote)), isSemantics(isSelected: true));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pump();
      expect(remote, 1);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('installing clears a past 「远程主机」', (tester) async {
      final (_, container) = await pump(
        tester,
        onRemote: () {},
        prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true),
      );
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pump();
      expect(container.read(onboardingPrefsProvider).localDeclined, isFalse);
    });

    testWidgets('resume, upgrade and reset install at once', (tester) async {
      final (runtime, _) = await pump(tester, choose: false, onRemote: () {});
      expect(find.text('DSH 在哪里运行？'), findsNothing);
      expect(runtime.calls, ['install']);
    });

    testWidgets('a failed install offers the remote host, quietly', (tester) async {
      var remote = 0;
      await pump(
        tester,
        status: const RuntimeStatus(phase: RuntimePhase.error, bundledVersion: bundled, error: 'install failed: x'),
        onRemote: () => remote++,
      );
      final way = find.widgetWithText(TextButton, '改用远程主机');
      expect(way, findsOneWidget);
      await tester.tap(way);
      expect(remote, 1);
    });

    testWidgets('no remote way, no remote button', (tester) async {
      await pump(
        tester,
        status: const RuntimeStatus(phase: RuntimePhase.error, bundledVersion: bundled, error: 'install failed: x'),
      );
      expect(find.text('改用远程主机'), findsNothing);
    });
  });

  group('root gate', () {
    late MemorySecretStore secrets;
    late FakeSshServer server;

    setUp(() {
      secrets = MemorySecretStore();
      server = FakeSshServer();
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
    });

    List<Override> remote() => [
      secretStoreProvider.overrideWithValue(secrets),
      networkKicksProvider.overrideWithValue(const Stream.empty()),
      relayBackendProvider.overrideWithValue(FakeRelayBackend()),
      sshTransportFactoryProvider.overrideWithValue(server.connect),
      hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
    ];

    Future<(RecordingLocalRuntime, ProviderContainer)> pumpGate(
      WidgetTester tester, {
      RuntimeStatus status = missingStatus,
      OnboardingPrefs prefs = const OnboardingPrefs(loaded: true, welcomeSeen: true),
      AppSettings settings = const AppSettings(loaded: true),
    }) async {
      final runtime = RecordingLocalRuntime(LocalRuntimeState(loaded: true, status: status));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const RootGate(home: Scaffold(body: Text('home'))),
          brightness: Brightness.light,
          prefs: prefs,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            settingsProvider.overrideWith(() => FakeSettings(settings)),
            footprint(roomyPhone),
            ...remote(),
          ],
        ),
      );
      await _frames(tester);
      return (runtime, ProviderScope.containerOf(tester.element(find.byType(RootGate))));
    }

    Future<void> chooseRemote(WidgetTester tester) async {
      await tester.tap(find.byKey(_remote));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await _frames(tester);
    }

    testWidgets('远程主机 → pick a host → home, nothing installed', (tester) async {
      final (runtime, container) = await pumpGate(tester);
      expect(find.text('DSH 在哪里运行？'), findsOneWidget);
      await chooseRemote(tester);
      expect(find.byType(RemoteScreen), findsOneWidget);

      await tester.tap(find.text('电脑'));
      await _frames(tester);
      expect(find.byType(RemoteScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(container.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
      expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('back from the host list without a host: the choice again', (tester) async {
      final (runtime, container) = await pumpGate(tester);
      await chooseRemote(tester);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(find.byType(RemoteScreen), findsNothing);
      expect(find.text('DSH 在哪里运行？'), findsOneWidget);
      expect(container.read(onboardingPrefsProvider).localDeclined, isFalse);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('a phone without the runtime opens home and starts nothing', (tester) async {
      final (runtime, _) = await pumpGate(
        tester,
        prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true),
      );
      expect(find.text('home'), findsOneWidget);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('auto start off: home with the engine stopped', (tester) async {
      final (runtime, _) = await pumpGate(
        tester,
        status: stoppedStatus,
        settings: const AppSettings(loaded: true, apiKey: 'key', autoStartLocal: false),
      );
      expect(find.text('home'), findsOneWidget);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('auto start on: the engine starts once', (tester) async {
      final (runtime, _) = await pumpGate(
        tester,
        status: stoppedStatus,
        settings: const AppSettings(loaded: true, apiKey: 'key'),
      );
      expect(runtime.calls, ['start']);
    });

    testWidgets('uninstall stays home; reset reinstalls through setup', (tester) async {
      final (runtime, container) = await pumpGate(
        tester,
        status: stoppedStatus,
        settings: const AppSettings(loaded: true, apiKey: 'key', autoStartLocal: false),
      );
      await container.read(onboardingPrefsProvider.notifier).setLocalDeclined(true);
      runtime.emit(missingStatus);
      await _frames(tester);
      expect(find.text('home'), findsOneWidget);
      expect(find.byType(RuntimeSetupPage), findsNothing);

      // Reinstalled from settings, then reset: setup takes over and installs.
      await container.read(onboardingPrefsProvider.notifier).setLocalDeclined(false);
      runtime.emit(stoppedStatus);
      await _frames(tester, 3);
      runtime.emit(missingStatus);
      await _frames(tester);
      expect(find.byType(RuntimeSetupPage), findsOneWidget);
      expect(find.text('DSH 在哪里运行？'), findsNothing);
      expect(runtime.calls, ['install']);
    });
  });

  group('install page', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(RecordingLocalRuntime, ProviderContainer)> pump(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(loaded: true, apiKey: 'key'),
      bool useWhenDone = false,
      LocalFootprint phone = roomyPhone,
    }) async {
      final runtime = RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => openLocalInstall(context, useWhenDone: useWhenDone),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            settingsProvider.overrideWith(() => FakeSettings(settings)),
            footprint(phone),
            accountProvider.overrideWith(() => FixedAccount(const AccountState(phase: AccountPhase.signedOut))),
            accountEngineStarterProvider.overrideWithValue(() async {}),
            accountBrowserProvider.overrideWithValue(FakeBrowser()),
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await _frames(tester, 8);
      return (runtime, ProviderScope.containerOf(tester.element(find.byType(LocalInstallPage))));
    }

    testWidgets('says what it costs, installs on 安装, starts the engine when done', (tester) async {
      final (runtime, container) = await pump(tester, useWhenDone: true);
      container.read(activeHostProvider.notifier).select(HostRef.ssh('elsewhere'));
      expect(find.text('安装本机运行环境'), findsOneWidget);
      expect(find.text('约 750 MB 存储空间'), findsOneWidget);
      expect(find.text('运行时约 300 MB 内存'), findsOneWidget);
      expect(runtime.calls, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, '安装'));
      await _frames(tester, 3);
      expect(runtime.calls, ['install']);
      expect(find.text('正在准备运行环境'), findsOneWidget);

      runtime.emit(stoppedStatus);
      await _frames(tester, 20);
      expect(runtime.calls, ['install', 'start']);
      expect(find.byType(LocalInstallPage), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(container.read(activeHostProvider), HostRef.local);
    });

    testWidgets('no model yet: on to 连接 DeepSeek, and leaving it does not come back', (tester) async {
      final (runtime, container) = await pump(tester, settings: const AppSettings(loaded: true));
      await tester.tap(find.widgetWithText(FilledButton, '安装'));
      await _frames(tester, 3);
      runtime.emit(stoppedStatus);
      await _frames(tester, 20);
      expect(find.byType(ConnectPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(find.text('open'), findsOneWidget);
      expect(container.read(onboardingPrefsProvider).keySkipped, isTrue);
    });

    testWidgets('a full phone hears it before installing', (tester) async {
      await pump(tester, phone: fullPhone);
      expect(find.text('存储空间不足，需要约 900 MB'), findsOneWidget);
      expect(find.text('约 750 MB 存储空间'), findsNothing);
    });

    testWidgets('back leaves before anything starts', (tester) async {
      final (runtime, _) = await pump(tester);
      await tester.tap(find.byTooltip('返回'));
      await _frames(tester);
      expect(find.text('open'), findsOneWidget);
      expect(runtime.calls, isEmpty);
    });
  });

  group('entries without the runtime', () {
    // A host picked in one test must not carry into the next.
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('engine page: install, no log, no reset', (tester) async {
      final runtime = RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const EngineScreen(),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            footprint(roomyPhone),
          ],
        ),
      );
      await _frames(tester, 6);
      expect(find.text('引擎日志'), findsNothing);
      expect(find.text('重置运行环境'), findsNothing);
      expect(find.text('卸载运行环境'), findsNothing);
      // The auto start switch stays where it was.
      expect(find.text('打开 App 时自动启动'), findsOneWidget);
      await tester.tap(find.text('安装运行环境'));
      await _frames(tester, 8);
      expect(find.byType(LocalInstallPage), findsOneWidget);
      expect(runtime.calls, isEmpty);
    });

    testWidgets('engine page: uninstall deletes everything and stays put', (tester) async {
      final runtime = RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: stoppedStatus));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const EngineScreen(),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          ],
        ),
      );
      await _frames(tester, 6);
      final container = ProviderScope.containerOf(tester.element(find.byType(EngineScreen)));
      container.read(currentSessionProvider.notifier).select('s1');
      await tester.scrollUntilVisible(find.text('卸载运行环境'), 500, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('卸载运行环境'));
      await _frames(tester, 2);
      await tester.tap(find.text('卸载运行环境'));
      await _frames(tester, 4);
      expect(find.text('本机的对话、工作区、插件、设置、界面配置和技能会一并删除。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await _frames(tester, 6);
      expect(runtime.calls, ['reset:']);
      expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
      // Its conversations are gone: nothing reopens one.
      expect(container.read(currentSessionProvider), isNull);
      expect(find.byType(EngineScreen), findsOneWidget);
      await tester.scrollUntilVisible(find.text('安装运行环境'), -500, scrollable: find.byType(Scrollable).first);
      expect(find.text('安装运行环境'), findsOneWidget);
    });

    testWidgets('host list: 本机 reads 未安装 and installs', (tester) async {
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showHostSheet(context, onManage: () {}),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus)),
            ),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            relayBackendProvider.overrideWithValue(FakeRelayBackend()),
            networkKicksProvider.overrideWithValue(const Stream.empty()),
            hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
            footprint(roomyPhone),
          ],
        ),
      );
      await tester.pump();
      ProviderScope.containerOf(tester.element(find.text('open')))
          .read(activeHostProvider.notifier)
          .select(HostRef.ssh(sampleSsh.id));
      await tester.tap(find.text('open'));
      await _frames(tester, 6);
      expect(find.text('未安装'), findsOneWidget);
      await tester.tap(find.text('这台手机上的 DSH'));
      await _frames(tester, 8);
      expect(find.byType(HostSheet), findsNothing);
      expect(find.byType(LocalInstallPage), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(LocalInstallPage)));
      // Not switched until it is installed.
      expect(container.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
    });

    testWidgets('drawer: the empty list offers the install', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            sessionsProvider.overrideWith(() => FakeSessions(const [])),
            footprint(roomyPhone),
          ],
        ),
      );
      await _frames(tester, 6);
      expect(find.text('本机未安装运行环境'), findsOneWidget);
      await tester.tap(find.text('安装运行环境'));
      await _frames(tester, 8);
      expect(find.byType(LocalInstallPage), findsOneWidget);
    });

    testWidgets('a build without the runtime: no 本机 row, the drawer offers a remote host', (tester) async {
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
      usePhoneSurface(tester);
      final runtime = RecordingLocalRuntime(
        const LocalRuntimeState(loaded: true, status: missingStatus, available: false),
      );
      await tester.pumpWidget(
        goldenApp(
          home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            sessionsProvider.overrideWith(() => FakeSessions(const [])),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            relayBackendProvider.overrideWithValue(FakeRelayBackend()),
            networkKicksProvider.overrideWithValue(const Stream.empty()),
            hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
            footprint(roomyPhone),
          ],
        ),
      );
      await _frames(tester, 6);
      expect(find.text('这台设备暂时不能在本机运行 DSH'), findsOneWidget);
      expect(find.text('安装运行环境'), findsNothing);
      await tester.tap(find.text('改用远程主机'));
      await _frames(tester, 8);
      expect(find.byType(RemoteScreen), findsOneWidget);
      expect(find.byType(LocalInstallPage), findsNothing);
      expect(runtime.calls, isEmpty);

      final context = tester.element(find.byType(RemoteScreen));
      unawaited(showHostSheet(context, onManage: () {}));
      await _frames(tester, 6);
      expect(find.byType(HostSheet), findsOneWidget);
      expect(find.text('这台手机上的 DSH'), findsNothing);
      expect(find.text(sampleSsh.name), findsWidgets);
    });

    testWidgets('web page: install instead of 启动', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const LocalWebScreen(),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            footprint(roomyPhone),
          ],
        ),
      );
      await _frames(tester, 6);
      expect(find.text('本机未安装运行环境'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '安装运行环境'), findsOneWidget);
    });

    testWidgets('chat empty state: one pill, suggestions folded', (tester) async {
      var taps = 0;
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Scaffold(
            body: ChatEmptyState(
              connected: false,
              onSuggestion: (_) {},
              idle: ChatIdleAction(message: '引擎未运行', label: '启动引擎', onTap: () => taps++),
            ),
          ),
          brightness: Brightness.light,
        ),
      );
      await _frames(tester, 6);
      expect(find.text('引擎未运行'), findsOneWidget);
      await tester.tap(find.text('启动引擎'));
      expect(taps, 1);
      expect(find.text('看看工作区'), findsNothing);
    });

    test('DeepSeek sign-in without the runtime fails at once', () async {
      final container = ProviderContainer(
        overrides: [
          localRuntimeProvider.overrideWith(
            () => RecordingLocalRuntime(const LocalRuntimeState(loaded: true, status: missingStatus)),
          ),
          accountEngineStarterProvider.overrideWithValue(() async => fail('must not start')),
          accountBrowserProvider.overrideWithValue(FakeBrowser()),
          localConnectionProvider.overrideWith(NoConnection.new),
          onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      );
      addTearDown(container.dispose);
      container.listen(accountProvider, (_, _) {});
      // The app's root keeps the runtime's state alive from launch.
      container.listen(localRuntimeProvider, (_, _) {});
      final result = await container.read(accountProvider.notifier).signIn().timeout(const Duration(seconds: 2));
      expect(result, SignInResult.failed);
      expect(container.read(accountProvider).failure?.kind, SignInFailureKind.noRuntime);
      expect(container.read(accountProvider).failure?.title, '需要本机运行环境');
    });
  });
}
