// Shared fakes for the set-up-while-unpacking tests
// (docs/design/onboarding-parallel-setup.md): a runtime that unpacks on
// command, an account that records sign-in requests, and the root gate on a
// phone without the runtime.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FakeBrowser;
import '../remote/support/fake_relay.dart';
import '../remote/support/fake_ssh.dart';
import '../shell/golden_harness.dart';
import 'local_optional_support.dart';

const unpackTotal = 120586240;

const installingStatus = RuntimeStatus(phase: RuntimePhase.installing, bundledVersion: bundled, abi: 'arm64-v8a');

const failedStatus = RuntimeStatus(
  phase: RuntimePhase.error,
  bundledVersion: bundled,
  abi: 'arm64-v8a',
  error: 'install failed: 存储空间不足：需要约 862 MB，当前可用 600 MB',
);

RuntimeProgressEvent unpackProgress(double fraction) =>
    RuntimeProgressEvent(step: 'extract', done: (unpackTotal * fraction).round(), total: unpackTotal);

LocalRuntimeState unpackingState(double? fraction) => LocalRuntimeState(
  loaded: true,
  status: installingStatus,
  progress: fraction == null ? null : unpackProgress(fraction),
);

/// [RecordingLocalRuntime] whose `install()` answers, as the bridge does,
/// only when the unpack ends ([finish] / [fail]); it reports progress on
/// command.
class UnpackingRuntime extends RecordingLocalRuntime {
  UnpackingRuntime(super.initial);

  Completer<void>? _unpack;

  @override
  Future<void> install() {
    calls.add('install');
    return (_unpack = Completer<void>()).future;
  }

  void unpack(double fraction) => state = unpackingState(fraction);

  /// Done: installed and stopped; the unpack's progress goes, as on Android.
  void finish() {
    state = const LocalRuntimeState(loaded: true, status: stoppedStatus);
    if (_unpack case final c? when !c.isCompleted) c.complete();
  }

  void fail() {
    state = const LocalRuntimeState(loaded: true, status: failedStatus);
    if (_unpack case final c? when !c.isCompleted) c.completeError(StateError('install_failed'));
  }
}

/// Signed out; records sign-in requests instead of starting one.
class RecordingAccount extends AccountController {
  final signIns = <Brightness?>[];

  @override
  AccountState build() => const AccountState(phase: AccountPhase.signedOut);

  @override
  Future<SignInResult> signIn({Brightness? brightness}) async {
    signIns.add(brightness);
    return SignInResult.cancelled;
  }

  @override
  void dismissFailure() {}

  @override
  void noteAppResumed() {}
}

/// What the system allows for notifications, fixed.
List<Override> notifications({required bool enabled}) => [
  notifySystemStatusProvider.overrideWith((ref) async => NotifySystemStatus(enabled: enabled)),
];

/// Saved hosts for the remote way: the sample SSH host.
void useSavedHost() {
  SharedPreferences.setMockInitialValues({
    HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
  });
}

List<Override> remoteOverrides() => [
  secretStoreProvider.overrideWithValue(MemorySecretStore()),
  networkKicksProvider.overrideWithValue(const Stream.empty()),
  relayBackendProvider.overrideWithValue(FakeRelayBackend()),
  sshTransportFactoryProvider.overrideWithValue(FakeSshServer().connect),
  hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
];

/// The root gate as a launch finds it.
class GateRig {
  GateRig(this.runtime, this.account, this.container, this.engineStarts);

  final UnpackingRuntime runtime;
  final RecordingAccount account;
  final ProviderContainer container;

  /// Times the connect step asked the account's engine starter to go.
  final List<int> engineStarts;

  OnboardingPrefs get prefs => container.read(onboardingPrefsProvider);
}

Future<void> frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<GateRig> pumpGate(
  WidgetTester tester, {
  LocalRuntimeState runtime = const LocalRuntimeState(loaded: true, status: missingStatus),
  OnboardingPrefs prefs = const OnboardingPrefs(loaded: true, welcomeSeen: true),
  AppSettings settings = const AppSettings(loaded: true),
  List<Override> overrides = const [],
}) async {
  final fake = UnpackingRuntime(runtime);
  final account = RecordingAccount();
  final starts = <int>[];
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: const RootGate(home: Scaffold(body: Text('home'))),
      brightness: Brightness.light,
      prefs: prefs,
      overrides: [
        localRuntimeProvider.overrideWith(() => fake),
        settingsProvider.overrideWith(() => FakeSettings(settings)),
        footprint(roomyPhone),
        accountProvider.overrideWith(() => account),
        accountEngineStarterProvider.overrideWithValue(() async => starts.add(1)),
        accountBrowserProvider.overrideWithValue(FakeBrowser()),
        ...remoteOverrides(),
        ...overrides,
      ],
    ),
  );
  await frames(tester);
  return GateRig(fake, account, ProviderScope.containerOf(tester.element(find.byType(RootGate))), starts);
}

/// 外观's 继续, then 跳过 on 想让 DSH Go 帮你做哪些事: on to what comes next.
Future<void> pastAppearance(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '继续'));
  await frames(tester);
  await tester.tap(find.widgetWithText(TextButton, '跳过'));
  await frames(tester);
}

/// On the choice: 「本机」 is suggested on a roomy phone; 继续.
Future<void> chooseThisPhone(WidgetTester tester, {bool keepNotice = false}) async {
  await tester.tap(find.widgetWithText(FilledButton, '继续'));
  await frames(tester);
  if (!keepNotice) await closeUsagePrivacyNotice(tester);
}

Future<void> closeUsagePrivacyNotice(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byKey(const ValueKey('usage-privacy-notice')), matching: find.byTooltip('关闭')),
  );
  await frames(tester);
}
