import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/ui/engine/local_uninstall.dart';

class _Bridge extends RuntimeBridge {
  _Bridge(MethodChannel methods) : super(methods: methods);
  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
  @override
  Future<RuntimeStatus> status() async => const RuntimeStatus(phase: RuntimePhase.notInstalled);
  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async => const RuntimeLogSnapshot([], 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/runtime-recovery');
  final calls = <MethodCall>[];
  var resetCode = 'ohos_reset_committed';
  Object? reopenError;
  late ProviderContainer container;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    resetCode = 'ohos_reset_committed';
    reopenError = PlatformException(code: 'ohos_restart_failed');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'reset' && resetCode.isNotEmpty) throw PlatformException(code: resetCode);
      if (call.method == 'reopenApp' && reopenError != null) throw reopenError!;
      return null;
    });
    container = ProviderContainer(overrides: [runtimeBridgeProvider.overrideWithValue(_Bridge(channel))]);
    container.read(localRuntimeProvider);
  });
  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('a committed reset requests reopen and propagates its failure, not a false completed reset', () async {
    Object? failure;
    try {
      await container.read(localRuntimeProvider.notifier).resetKeeping(const ResetKeep());
    } catch (error) {
      failure = error;
    }
    expect(calls.map((call) => call.method), ['reset', 'reopenApp']);
    expect(failure, isA<RuntimeResetPending>().having((error) => error.committed, 'committed', isTrue)
        .having((error) => error.reopenError, 'reopenError', isA<PlatformException>()));
  });
  test('a failed or conflicting reset never claims a committed marker and never reopens', () async {
    resetCode = 'ohos_reset_pending';
    await expectLater(container.read(localRuntimeProvider.notifier).resetKeeping(const ResetKeep()),
        throwsA(isA<RuntimeResetFailure>().having((error) => error.commitState, 'state', RuntimeResetCommitState.notCommitted)
            .having((error) => (error.cause as PlatformException).code, 'cause code', resetCode)));
    expect(calls.map((call) => call.method), ['reset']);
  });
  test('explicit reinstall keeps all options and returns pending after restart acknowledgement', () async {
    reopenError = null;
    final outcome = await container.read(localRuntimeProvider.notifier).resetAndReinstall(
        const ResetKeep(uiAndSkills: true, pluginsAndSettings: true));
    expect(outcome, RuntimeResetOutcome.pendingReopen);
    expect(calls.first.arguments, {'keep': ['uiAndSkills', 'pluginsAndSettings'], 'reinstall': true});
    expect(calls.map((call) => call.method), ['reset', 'reopenApp']);
  });
  test('legacy reset leaves Android wire and its void API unchanged after a normal native reply', () async {
    resetCode = '';
    await container.read(localRuntimeProvider.notifier).resetKeeping(ResetKeep.suggested);
    expect(calls.single.arguments, {'keep': ['uiAndSkills']});
  });
  test('a missing restart channel is also typed pending, without losing the durable acknowledgement', () async {
    reopenError = MissingPluginException('no ability bridge');
    await expectLater(container.read(localRuntimeProvider.notifier).resetAndReinstall(const ResetKeep()),
        throwsA(isA<RuntimeResetPending>().having((error) => error.reopenError, 'cause', isA<MissingPluginException>())));
  });

  test('actual uninstall keeps the remote-only choice when reset committed but reopening failed', () async {
    container.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    await expectLater(LocalUninstall.run(container), throwsA(isA<RuntimeResetPending>()));
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('onboarding_local_declined'), isTrue);
    expect(calls.first.arguments, {'keep': <String>[]});
  });
  test('actual uninstall still rolls back a request rejected before commit', () async {
    resetCode = 'ohos_recovery_invalid';
    container.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    await expectLater(LocalUninstall.run(container), throwsA(isA<RuntimeResetFailure>()
        .having((error) => error.commitState, 'state', RuntimeResetCommitState.notCommitted)
        .having((error) => (error.cause as PlatformException).code, 'cause code', resetCode)));
    expect(container.read(onboardingPrefsProvider).localDeclined, isFalse);
    expect((await SharedPreferences.getInstance()).getBool('onboarding_local_declined'), isFalse);
    expect(calls.map((call) => call.method), ['reset']);
  });

  test('actual uninstall preserves the choice on unknown commit without claiming success or reopening', () async {
    resetCode = 'ohos_reset_commit_unknown';
    container.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    Object? failure;
    try { await LocalUninstall.run(container); } catch (error) { failure = error; }
    expect(failure, isA<RuntimeResetPending>()
        .having((error) => error.commitState, 'state', RuntimeResetCommitState.unknown)
        .having((error) => error.committed, 'committed', isFalse)
        .having((error) => error.reopenError, 'no reopen attempted', isNull)
        .having((error) => (error.cause as PlatformException).code, 'cause code', resetCode));
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('onboarding_local_declined'), isTrue);
    expect(calls.map((call) => call.method), ['reset']);
  });

  for (final firstCode in ['ohos_reset_commit_unknown', 'ohos_reset_committed']) {
  test('retry after $firstCode rejected by an older pending reset restores the previous remote-only choice', () async {
    container.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    resetCode = firstCode;
    await expectLater(LocalUninstall.run(container), throwsA(isA<RuntimeResetPending>()));
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    resetCode = 'ohos_reset_pending';
    await expectLater(LocalUninstall.run(container), throwsA(isA<RuntimeResetFailure>()
        .having((error) => error.commitState, 'this request', RuntimeResetCommitState.notCommitted)));
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('onboarding_local_declined'), isTrue);
    expect(calls.map((call) => call.method), firstCode == 'ohos_reset_committed'
        ? ['reset', 'reopenApp', 'reset'] : ['reset', 'reset']);
  });
  }

  test('overlapping uninstall calls share one native transaction and release the slot after failure', () async {
    container.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    final firstReset = Completer<void>();
    final release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'reset') {
        if (!firstReset.isCompleted) firstReset.complete();
        await release.future;
        throw PlatformException(code: resetCode);
      }
      return null;
    });
    resetCode = 'ohos_reset_commit_unknown';
    final first = LocalUninstall.run(container);
    final firstResult = expectLater(first, throwsA(isA<RuntimeResetPending>()));
    await firstReset.future;
    final second = LocalUninstall.run(container);
    final secondResult = expectLater(second, throwsA(isA<RuntimeResetPending>()));
    await Future<void>.delayed(Duration.zero);
    final resetCountWhilePending = calls.where((call) => call.method == 'reset').length;
    release.complete();
    await Future.wait([firstResult, secondResult]);
    expect(resetCountWhilePending, 1);
    expect(identical(first, second), isTrue);
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    resetCode = 'ohos_reset_pending';
    await expectLater(LocalUninstall.run(container), throwsA(isA<RuntimeResetFailure>()
        .having((error) => error.commitState, 'state', RuntimeResetCommitState.notCommitted)));
    expect(calls.where((call) => call.method == 'reset'), hasLength(2));
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
  });

  test('different containers have separate transactions and disposing one does not retain its slot', () async {
    container.read(onboardingPrefsProvider);
    final other = ProviderContainer(overrides: [runtimeBridgeProvider.overrideWithValue(_Bridge(channel))]);
    other.read(localRuntimeProvider);
    other.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    final bothReset = Completer<void>();
    final release = Completer<void>();
    var resetCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'reset') {
        if (++resetCount == 2) bothReset.complete();
        await release.future;
        throw PlatformException(code: 'ohos_reset_commit_unknown');
      }
      return null;
    });
    final first = LocalUninstall.run(container);
    final second = LocalUninstall.run(other);
    final results = [expectLater(first, throwsA(isA<RuntimeResetPending>())),
        expectLater(second, throwsA(isA<RuntimeResetPending>()))];
    await bothReset.future;
    expect(identical(first, second), isFalse);
    other.dispose();
    release.complete();
    await Future.wait(results);
    // A disposed container fails anew; it must not return the old pending result.
    await expectLater(LocalUninstall.run(other), throwsStateError);
    expect(resetCount, 2);
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
  });

  test('synchronous preference listeners cannot reenter before the uninstall slot is registered', () async {
    container.read(onboardingPrefsProvider);
    await Future<void>.delayed(Duration.zero);
    resetCode = 'ohos_reset_commit_unknown';
    Future<void>? reentered;
    Future<void>? reenteredResult;
    var entered = false;
    final subscription = container.listen(onboardingPrefsProvider, (previous, next) {
      if (!entered && next.localDeclined) {
        entered = true;
        reentered = LocalUninstall.run(container);
        reenteredResult = expectLater(reentered, throwsA(isA<RuntimeResetPending>()));
      }
    });
    final first = LocalUninstall.run(container);
    await expectLater(first, throwsA(isA<RuntimeResetPending>()));
    await reenteredResult;
    subscription.close();
    expect(entered, isTrue);
    expect(calls.where((call) => call.method == 'reset'), hasLength(1));
    expect(identical(first, reentered), isTrue);
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
  });

}
