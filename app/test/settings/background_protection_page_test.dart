import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _Runtime extends FakeRuntime {
  _Runtime() : super(const LocalRuntimeState(loaded: true));

  void changed() => state = state.copyWith(status: const RuntimeStatus(phase: RuntimePhase.running));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/runtime');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final l10n = lookupL10n(AppLocale.zhCN);
  const audio = ValueKey('background-protection-audio');
  const location = ValueKey('background-protection-location');
  const task = ValueKey('background-protection-task');
  const status = ValueKey('background-protection-status');
  late Map<String, Object?>? actual;
  late List<MethodCall> calls;
  late FutureOr<Object?> Function(MethodCall) update;
  late _Runtime runtime;
  var readFails = false;
  var opens = true;

  setUp(() {
    actual = {'supported': true};
    calls = [];
    runtime = _Runtime();
    readFails = false;
    opens = true;
    update = (call) => actual;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'backgroundProtection':
          if (readFails) throw PlatformException(code: 'read_failed');
          return actual;
        case 'setBackgroundProtection':
          return await update(call);
        case 'openBackgroundProtectionSettings':
          return opens;
        default:
          return null;
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> pump(WidgetTester tester, {String os = 'ios'}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [
          operatingSystemProvider.overrideWithValue(os),
          runtimeBridgeProvider.overrideWithValue(RuntimeBridge()),
          localRuntimeProvider.overrideWith(() => runtime),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  SettingsSwitchTile toggle(WidgetTester tester, Key key) => tester.widget(find.byKey(key));

  testWidgets('iOS starts with just two off switches and one actual status', (tester) async {
    await pump(tester);
    expect(find.byType(SettingsSwitchTile), findsNWidgets(2));
    expect(toggle(tester, audio).value, isFalse);
    expect(toggle(tester, location).value, isFalse);
    expect(find.byKey(task), findsNothing);
    expect(find.byKey(status), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionOff), findsOneWidget);
    expect(calls.where((call) => call.method == 'setBackgroundProtection'), isEmpty);
  });

  for (final response in [
    null,
    <String, Object?>{'supported': false},
  ]) {
    testWidgets('legacy or unsupported native response hides switches: $response', (tester) async {
      actual = response;
      await pump(tester);
      expect(find.byType(SettingsSwitchTile), findsNothing);
      expect(find.byKey(status), findsNothing);
      expect(find.text(l10n.harmonyBackgroundSubtitle), findsOneWidget);
    });
  }

  testWidgets('toggle waits for the getter rather than trusting the setter response', (tester) async {
    await pump(tester);
    final pending = Completer<Object?>();
    update = (call) => pending.future;
    await tester.tap(find.text(l10n.backgroundProtectionAudio));
    await tester.pump();
    expect(toggle(tester, audio).value, isFalse);
    expect(toggle(tester, audio).onChanged, isNull);
    expect(toggle(tester, location).onChanged, isNull);
    actual = {'supported': true, 'audioEnabled': true, 'audioActive': false};
    pending.complete({'supported': true, 'audioEnabled': true, 'audioActive': true});
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isTrue);
    expect(toggle(tester, audio).onChanged, isNotNull);
    expect(find.text(l10n.backgroundProtectionReady), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionAudioActive), findsNothing);
    final change = calls.indexWhere((call) => call.method == 'setBackgroundProtection');
    expect(calls[change].arguments, {'audioEnabled': true});
    expect(calls.skip(change + 1).any((call) => call.method == 'backgroundProtection'), isTrue);
  });

  testWidgets('permission denial stays inactive and offers app settings', (tester) async {
    await pump(tester);
    update = (call) {
      actual = {
        'supported': true,
        'locationEnabled': true,
        'locationActive': false,
        'locationAuthorization': 'denied',
        'error': 'ios_background_location_denied',
      };
      return actual;
    };
    await tester.tap(find.text(l10n.backgroundProtectionLocation));
    await tester.pumpAndSettle();
    expect(toggle(tester, location).value, isTrue);
    expect(find.text(l10n.backgroundProtectionNeedsAlways), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionLocationActive), findsNothing);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsNothing);
    await tester.tap(find.text(l10n.backgroundProtectionStatus));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'openBackgroundProtectionSettings'), hasLength(1));
    expect(find.text(l10n.backgroundProtectionNeedsAlways), findsOneWidget);
  });

  testWidgets('failed update preserves the getter state and shows a brief notice', (tester) async {
    await pump(tester);
    update = (call) => throw PlatformException(code: 'native_failed');
    await tester.tap(find.text(l10n.backgroundProtectionAudio));
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isFalse);
    expect(find.text(l10n.backgroundProtectionOff), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('unrelated resource errors do not turn a saved preference into a failed update', (tester) async {
    actual = {
      'supported': true,
      'audioEnabled': true,
      'locationEnabled': true,
      'locationAuthorization': 'denied',
      'error': 'ios_background_location_denied',
    };
    await pump(tester);
    update = (call) {
      actual = {...actual!, 'audioEnabled': false};
      return actual;
    };
    await tester.tap(find.text(l10n.backgroundProtectionAudio));
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isFalse);
    expect(find.text(l10n.backgroundProtectionNeedsAlways), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsNothing);
  });

  testWidgets('a mismatched getter preference reports a failed update', (tester) async {
    await pump(tester);
    update = (call) => {'supported': true, 'audioEnabled': true};
    await tester.tap(find.text(l10n.backgroundProtectionAudio));
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isFalse);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsOneWidget);
  });

  testWidgets('resume reads revoked permission without guessing from the saved switch', (tester) async {
    actual = {
      'supported': true,
      'locationEnabled': true,
      'locationActive': true,
      'locationAuthorization': 'authorizedAlways',
    };
    await pump(tester);
    expect(find.text(l10n.backgroundProtectionLocationActive), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    actual = {
      'supported': true,
      'locationEnabled': true,
      'locationActive': false,
      'locationAuthorization': 'authorizedWhenInUse',
    };
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(toggle(tester, location).value, isTrue);
    expect(find.text(l10n.backgroundProtectionNeedsAlways), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionLocationActive), findsNothing);
  });

  testWidgets('native status changes re-read actual activity', (tester) async {
    actual = {'supported': true, 'audioEnabled': true};
    await pump(tester);
    actual = {'supported': true, 'audioEnabled': true, 'audioActive': true};
    runtime.changed();
    await tester.pumpAndSettle();
    expect(find.text(l10n.backgroundProtectionAudioActive), findsOneWidget);
  });

  testWidgets('HarmonyOS uses one switch and cannot fix ACL eligibility in settings', (tester) async {
    actual = {'supported': true, 'permissionStatus': 'eligible'};
    await pump(tester, os: 'ohos');
    expect(find.byType(SettingsSwitchTile), findsOneWidget);
    expect(toggle(tester, task).value, isFalse);
    update = (call) {
      actual = {
        'supported': true,
        'taskEnabled': true,
        'taskActive': false,
        'permissionStatus': 'eligibility_required',
        'actionRequired': 'obtain_task_keeping_acl_and_install_entitled_build',
        'error': 'ohos_background_eligibility_required',
      };
      return actual;
    };
    await tester.tap(find.text(l10n.backgroundProtectionTask));
    await tester.pumpAndSettle();
    expect(toggle(tester, task).value, isTrue);
    expect(find.text(l10n.backgroundProtectionTaskUnavailable), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsNothing);
    expect(tester.widget<SettingsTile>(find.byKey(status)).onTap, isNull);
    expect(find.text(l10n.backgroundProtectionTaskActive), findsNothing);
    expect(calls.singleWhere((call) => call.method == 'setBackgroundProtection').arguments, {'taskEnabled': true});
  });

  testWidgets('restricted location access does not promise a settings fix', (tester) async {
    actual = {
      'supported': true,
      'locationEnabled': true,
      'locationAuthorization': 'restricted',
      'error': 'ios_background_location_restricted',
    };
    await pump(tester);
    expect(find.text(l10n.backgroundProtectionLocationRestricted), findsOneWidget);
    expect(tester.widget<SettingsTile>(find.byKey(status)).onTap, isNull);
    expect(find.text(l10n.backgroundProtectionLocationActive), findsNothing);
  });

  testWidgets('a missing update reply cannot become a successful toggle', (tester) async {
    await pump(tester);
    update = (call) => null;
    await tester.tap(find.text(l10n.backgroundProtectionAudio));
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isFalse);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsOneWidget);
  });

  testWidgets('Android retains its existing guide without querying enhanced protection', (tester) async {
    await pump(tester, os: 'android');
    expect(find.byType(SettingsSwitchTile), findsNothing);
    expect(find.text(l10n.pluginsBackgroundDescription), findsOneWidget);
    expect(calls.where((call) => call.method == 'backgroundProtection'), isEmpty);
  });

  testWidgets('pending cleanup is not reported as stopped or active', (tester) async {
    actual = {'supported': true, 'taskEnabled': false, 'taskActive': true, 'cleanupPending': true};
    await pump(tester, os: 'ohos');
    expect(toggle(tester, task).value, isFalse);
    expect(find.text(l10n.backgroundProtectionCleanup), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionOff), findsNothing);
    expect(find.text(l10n.backgroundProtectionTaskActive), findsNothing);
  });

  testWidgets('settings that cannot open report the failure', (tester) async {
    actual = {'supported': true, 'locationEnabled': true, 'locationAuthorization': 'denied'};
    opens = false;
    await pump(tester);
    await tester.tap(find.text(l10n.backgroundProtectionStatus));
    await tester.pumpAndSettle();
    expect(find.text(l10n.accessOpenFailed), findsOneWidget);
  });

  testWidgets('getter failure after an update never shows a fabricated active grant', (tester) async {
    await pump(tester);
    final readsBefore = calls.where((call) => call.method == 'backgroundProtection').length;
    update = (call) {
      readFails = true;
      return {'supported': true, 'audioEnabled': true, 'audioActive': true};
    };
    await tester.tap(find.text(l10n.backgroundProtectionAudio));
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isFalse);
    expect(find.text(l10n.backgroundProtectionAudioActive), findsNothing);
    expect(find.text(l10n.backgroundProtectionUnavailable), findsOneWidget);
    expect(find.text(l10n.backgroundProtectionUpdateFailed), findsOneWidget);
    expect(toggle(tester, audio).onChanged, isNotNull);
    expect(toggle(tester, location).onChanged, isNotNull);
    expect(calls.where((call) => call.method == 'backgroundProtection'), hasLength(readsBefore + 1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    readFails = false;
    actual = {'supported': true, 'audioEnabled': true};
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(toggle(tester, audio).value, isTrue);
    expect(find.text(l10n.backgroundProtectionReady), findsOneWidget);
    expect(calls.where((call) => call.method == 'backgroundProtection'), hasLength(readsBefore + 2));
  });
}
