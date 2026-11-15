// The system-permission pages on HarmonyOS: notifications are asked for with
// the system's dialog, and only what works there is read or offered. Android
// beside it wherever the OS is a parameter.

import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/ui/access/access_walk.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/onboarding/access_step.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/settings/system_access_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _primary = ValueKey('access-primary');

Future<void> _frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _primaryLabel(WidgetTester tester) => (tester.widget<FilledButton>(find.byKey(_primary)).child! as Text).data!;

/// The runtime's answers on HarmonyOS: no storage, and no battery exemption to ask about.
class _HarmonyBridge extends RuntimeBridge {
  @override
  Future<StorageAccess> storageStatus() async => const StorageAccess(granted: false, permission: false, legacy: false);

  @override
  Future<bool?> batteryExempt() => Future.error(PlatformException(code: 'ohos_unsupported'));
}

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const notify = MethodChannel('dsh/notify');
  const voice = MethodChannel('dsh/voice');
  final calls = <String>[];
  late Future<Object?> Function(MethodCall) answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    answer = (_) async => true;
    messenger.setMockMethodCallHandler(notify, (call) {
      calls.add(call.method);
      return answer(call);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(notify, null);
    messenger.setMockMethodCallHandler(voice, null);
  });

  group('the channel\'s permission dialog', () {
    test('answers what the native side says; refused is false', () async {
      expect(await NotifyChannel().requestPermission(), isTrue);
      answer = (_) async => false;
      expect(await NotifyChannel().requestPermission(), isFalse);
      expect(calls, ['requestPermission', 'requestPermission']);
    });

    test('a failure or no native side is not a grant', () async {
      answer = (_) async => throw PlatformException(code: 'no_ability');
      expect(await NotifyChannel().requestPermission(), isFalse);
      messenger.setMockMethodCallHandler(notify, null);
      expect(await NotifyChannel().requestPermission(), isFalse);
    });
  });

  group('notifications, by OS', () {
    test('a dialog item on HarmonyOS only', () {
      expect(AccessItem.notifications.dialogOn('ohos'), isTrue);
      expect(AccessItem.notifications.dialogOn('ios'), isTrue);
      expect(AccessItem.notifications.dialogOn('android'), isFalse);
      for (final item in AccessItem.values.where((i) => i != AccessItem.notifications)) {
        expect(item.dialogOn('ohos'), item.dialogOn('android'), reason: item.name);
      }
    });

    AccessDriver driver(String os) {
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(os)]);
      addTearDown(container.dispose);
      return container.read(accessDriverProvider);
    }

    test('HarmonyOS: the first try asks, again opens settings', () async {
      final phone = driver('ohos');
      expect(await phone.open(AccessItem.notifications), isTrue);
      expect(calls, ['requestPermission']);
      expect(await phone.open(AccessItem.notifications, again: true), isTrue);
      expect(calls, ['requestPermission', 'openSettings']);
    });

    test('HarmonyOS: a refusal or a failed dialog still came back, for the step to say so', () async {
      final phone = driver('ohos');
      answer = (_) async => false;
      expect(await phone.open(AccessItem.notifications), isTrue);
      answer = (_) async => throw PlatformException(code: 'no_ability');
      expect(await phone.open(AccessItem.notifications), isTrue);
    });

    test('Android: settings, first and again', () async {
      final phone = driver('android');
      expect(await phone.open(AccessItem.notifications), isTrue);
      expect(await phone.open(AccessItem.notifications, again: true), isTrue);
      expect(calls, ['openSettings', 'openSettings']);
    });
  });

  group('the step', () {
    Future<FakeAccessDriver> pump(WidgetTester tester, String os) async {
      final phone = FakeAccessDriver(readingsWith(offPhone, notifications: false));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: AccessWalk(items: const [AccessItem.notifications], onDone: () {}),
          brightness: Brightness.light,
          overrides: [...accessOverrides(phone), operatingSystemProvider.overrideWithValue(os)],
        ),
      );
      await _frames(tester);
      return phone;
    }

    testWidgets('on HarmonyOS the dialog answers at once; 重试 goes to settings', (tester) async {
      final phone = await pump(tester, 'ohos');
      expect(_primaryLabel(tester), '去开启');
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications']);
      expect(find.text('还没开启'), findsOneWidget);
      expect(_primaryLabel(tester), '重试');

      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications', 'notifications+']);
    });

    testWidgets('on HarmonyOS allowed in the dialog: its check, without leaving the app', (tester) async {
      final phone = await pump(tester, 'ohos');
      phone.answer = (_, r) => readingsWith(r, notifications: true);
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(find.text('已开启'), findsOneWidget);
    });

    testWidgets('on Android a settings page: nothing to say until the person is back', (tester) async {
      final phone = await pump(tester, 'android');
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications']);
      expect(find.text('还没开启'), findsNothing);
      await awayAndBack(tester);
      expect(find.text('还没开启'), findsOneWidget);
    });

    testWidgets('why it asks: on HarmonyOS only while the app runs', (tester) async {
      await pump(tester, 'ohos');
      expect(find.text(_zh.harmonyNotifyWhy), findsOneWidget);
      expect(find.text(_zh.accessNotifyWhy), findsNothing);
    });

    testWidgets('why it asks: on Android as ever', (tester) async {
      await pump(tester, 'android');
      expect(find.text(_zh.accessNotifyWhy), findsOneWidget);
      expect(find.text(_zh.harmonyNotifyWhy), findsNothing);
    });
  });

  group('what each OS offers', () {
    test('Android: exactly what it always had, in that order, never 回复提醒', () {
      expect(accessFeaturesFor('android'), [
        AccessFeature.files,
        AccessFeature.pet,
        AccessFeature.phone,
        AccessFeature.background,
        AccessFeature.voice,
      ]);
      expect(accessFeaturesFor('linux'), accessFeaturesFor('android'));
    });

    test('HarmonyOS: 回复提醒 and 语音输入, which ask for notifications and the microphone', () {
      expect(accessFeaturesFor('ohos'), [AccessFeature.alerts, AccessFeature.voice]);
      expect(accessFeaturesFor('ios'), accessFeaturesFor('ohos'));
      expect(accessItemsFor(AccessFeature.alerts, null), [AccessItem.notifications]);
      // A maker's name changes nothing: none of its switches belong to these.
      expect(accessWalk(accessFeaturesFor('ohos'), 'huawei'), [AccessItem.mic, AccessItem.notifications]);
    });

    test('only Android\'s voice input downloads a model', () {
      expect(accessVoiceDownloads('android'), isTrue);
      expect(accessVoiceDownloads('ohos'), isFalse);
      expect(accessVoiceDownloads('ios'), isFalse);
    });
  });

  group('picks kept across a kill', () {
    Future<AccessSetup> reload(WidgetTester tester, String stored) async {
      SharedPreferences.setMockInitialValues({AccessSetupController.prefsKey: stored});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(accessSetupProvider);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      return container.read(accessSetupProvider);
    }

    testWidgets('回复提醒 comes back', (tester) async {
      final setup = await reload(tester, '{"features":["alerts","voice"],"skipped":[]}');
      expect(setup.features, {AccessFeature.alerts, AccessFeature.voice});
    });

    testWidgets('a name this build doesn\'t know is passed over', (tester) async {
      final setup = await reload(tester, '{"features":["alerts","later"],"skipped":[]}');
      expect(setup.features, {AccessFeature.alerts});
    });
  });

  group('the readings on HarmonyOS', () {
    test('only the two it offers: the runtime\'s no and its error are not asked for', () async {
      messenger.setMockMethodCallHandler(voice, (call) async => call.method == 'permission' ? 'denied' : null);
      answer = (call) async => {'enabled': false, 'done': false, 'attention': false};
      final bridge = _HarmonyBridge();
      final container = ProviderContainer(
        overrides: [operatingSystemProvider.overrideWithValue('ohos'), runtimeBridgeProvider.overrideWithValue(bridge)],
      );
      addTearDown(container.dispose);
      final r = await container.read(accessDriverProvider).read();
      expect(r.mic, isFalse);
      expect(r.notifications, isFalse);
      for (final item in AccessItem.values.where(
        (i) => !i.vendor && i != AccessItem.mic && i != AccessItem.notifications,
      )) {
        expect(accessStateOf(item, r, const {}), isNull, reason: item.name);
      }
      expect(r.metered, isNull);
    });

    test('no answer from a channel is no reading, not an off', () async {
      messenger.setMockMethodCallHandler(notify, null);
      messenger.setMockMethodCallHandler(voice, (call) async => throw PlatformException(code: 'no_ability'));
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
      addTearDown(container.dispose);
      final r = await container.read(accessDriverProvider).read();
      expect(accessStateOf(AccessItem.notifications, r, const {}), isNull);
      expect(accessStateOf(AccessItem.mic, r, const {}), isNull);
    });
  });

  group('first run\'s pick', () {
    Future<FakeAccessDriver> pick(WidgetTester tester, String os, {bool metered = false}) async {
      final phone = FakeAccessDriver(
        const AccessReadings(mic: false, notifications: false).copyMetered(metered),
        answer: (item, r) => item == AccessItem.mic
            ? const AccessReadings(mic: true, notifications: false)
            : const AccessReadings(mic: true, notifications: true),
      );
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: AccessStepPage(onDone: () {}),
          brightness: Brightness.light,
          overrides: [...accessOverrides(phone), operatingSystemProvider.overrideWithValue(os)],
        ),
      );
      await _frames(tester);
      return phone;
    }

    testWidgets('on HarmonyOS: two rows, and no model promised', (tester) async {
      await pick(tester, 'ohos', metered: true);
      expect(find.text(_zh.accessFeatureAlerts), findsOneWidget);
      expect(find.text(_zh.accessFeatureAlertsNeeds), findsOneWidget);
      expect(find.text(_zh.accessFeatureVoice), findsOneWidget);
      expect(find.text(_zh.accessFeatureVoiceNeeds), findsOneWidget);
      for (final other in [
        _zh.accessFeatureFiles,
        _zh.accessFeaturePet,
        _zh.accessFeaturePhone,
        _zh.accessFeatureBackground,
      ]) {
        expect(find.text(other), findsNothing, reason: other);
      }
      expect(find.text(_zh.accessVoiceModel(voiceModelApproxMb)), findsNothing);
      expect(find.text(_zh.accessVoiceMetered), findsNothing);
    });

    testWidgets('on Android: voice still says its download, and never 回复提醒', (tester) async {
      await pick(tester, 'android', metered: true);
      expect(find.text(_zh.accessVoiceModel(voiceModelApproxMb)), findsOneWidget);
      expect(find.text(_zh.accessVoiceMetered), findsOneWidget);
      expect(find.text(_zh.accessFeatureAlerts), findsNothing);
      expect(find.text(_zh.accessFeatureFiles), findsOneWidget);
    });

    testWidgets('on HarmonyOS: picked, walked, summed up, and nothing set to download', (tester) async {
      final phone = await pick(tester, 'ohos');
      await tester.tap(find.text(_zh.accessFeatureVoice));
      await _frames(tester);
      await tester.tap(find.text(_zh.accessFeatureAlerts));
      await _frames(tester);
      await tester.tap(find.byKey(_primary));
      await _frames(tester);

      // Microphone, then notifications, each answered by its dialog.
      expect(find.text(_zh.accessMicTitle), findsOneWidget);
      await tester.tap(find.byKey(_primary));
      await _frames(tester, 12);
      expect(find.text(_zh.accessNotifyTitle), findsOneWidget);
      await tester.tap(find.byKey(_primary));
      await _frames(tester, 12);
      expect(phone.opened, ['mic', 'notifications']);

      expect(find.byKey(const ValueKey('access-summary-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('access-voice')), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(onboardingWantsVoiceKey), isFalse);
      expect(prefs.getBool(VoiceModelController.wantedKey), isNull);
    });

    testWidgets('on Android: the same pick writes the wish and says so', (tester) async {
      await pick(tester, 'android');
      await tester.tap(find.text(_zh.accessFeatureVoice));
      await _frames(tester);
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      await tester.tap(find.byKey(_primary));
      await _frames(tester, 12);
      expect(find.byKey(const ValueKey('access-voice')), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(onboardingWantsVoiceKey), isTrue);
    });
  });

  group('设置 › 系统权限', () {
    Future<void> page(WidgetTester tester, String os) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SystemAccessPage(),
          brightness: Brightness.light,
          overrides: [
            ...accessOverrides(FakeAccessDriver(const AccessReadings(mic: true, notifications: false))),
            operatingSystemProvider.overrideWithValue(os),
          ],
        ),
      );
      await _frames(tester);
    }

    testWidgets('on HarmonyOS: 回复提醒 and 语音输入 with their states, nothing falsely off', (tester) async {
      await page(tester, 'ohos');
      expect(find.byKey(const ValueKey('access-section-alerts')), findsOneWidget);
      expect(find.byKey(const ValueKey('access-section-voice')), findsOneWidget);
      for (final other in ['files', 'pet', 'phone', 'background']) {
        expect(find.byKey(ValueKey('access-section-$other')), findsNothing, reason: other);
      }
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-notifications')), matching: find.text('未开启')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-mic')), matching: find.text('已开启')),
        findsOneWidget,
      );
      expect(find.text('未开启'), findsOneWidget);
    });

    test('the subtitle names the right system', () {
      expect(_en.accessPageSubtitle, contains('Android'));
      expect(_en.harmonyAccessSubtitle, contains('HarmonyOS'));
      expect(_en.harmonyAccessSubtitle, isNot(contains('Android')));
    });

    testWidgets('on HarmonyOS the subtitle is its own', (tester) async {
      await page(tester, 'ohos');
      expect(find.text(_zh.harmonyAccessSubtitle), findsOneWidget);
    });
  });

  group('search for it', () {
    List<String> ids(String q, {required bool android}) => [
      for (final h in searchSettings(
        q,
        spots: SettingsIndex.spots,
        features: featureSections,
        zh: _zh,
        en: _en,
        androidFeatures: android,
      ))
        h.spot?.id ?? 'feature:${h.feature!.id}',
    ];

    test('by name and by what it has on HarmonyOS', () {
      for (final q in ['系统权限', 'System permissions', '麦克风', '通知权限', '回复提醒']) {
        expect(ids(q, android: false), contains('page:systemAccess'), reason: q);
      }
    });

    test('not by what only Android has', () {
      for (final q in ['无障碍', '后台弹出界面', '受限制的设置', 'overlay', 'restricted settings']) {
        expect(ids(q, android: false), isNot(contains('page:systemAccess')), reason: q);
        expect(ids(q, android: true), contains('page:systemAccess'), reason: q);
      }
    });
  });
}

extension on AccessReadings {
  AccessReadings copyMetered(bool metered) => AccessReadings(mic: mic, notifications: notifications, metered: metered);
}
