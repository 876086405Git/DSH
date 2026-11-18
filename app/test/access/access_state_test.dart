// What each feature needs on each maker's phone, the walk's order, the
// states, the restricted-settings steps, and what first run keeps.

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _i = AccessItem.values;

void main() {
  group('the makers\' switches', () {
    test('vivo and Xiaomi: background, auto-start and pop-ups; one page for the others', () {
      for (final v in ['vivo', 'xiaomi']) {
        expect(vendorSwitches[v], [AccessItem.vendorBackground, AccessItem.autostart, AccessItem.popup], reason: v);
      }
      for (final v in ['huawei', 'honor', 'oppo']) {
        expect(vendorSwitches[v], [AccessItem.vendorBackground], reason: v);
      }
      expect(vendorSwitches['samsung'], isNull);
      expect(vendorSwitches.keys, unorderedEquals(['vivo', 'xiaomi', 'huawei', 'honor', 'oppo']));
    });

    test('only the makers\' switches go to the native side, by its names', () {
      expect([for (final i in _i) ?i.vendorWire], ['background', 'autostart', 'popup']);
      expect(
        [for (final i in _i) if (i.dialogOn('android')) i],
        [AccessItem.mic, AccessItem.storage, AccessItem.battery],
      );
    });
  });

  group('feature → items', () {
    test('on vivo', () {
      expect(accessItemsFor(AccessFeature.files, 'vivo'), [AccessItem.storage]);
      expect(accessItemsFor(AccessFeature.pet, 'vivo'), [AccessItem.overlay]);
      expect(accessItemsFor(AccessFeature.phone, 'vivo'), [
        AccessItem.notifications,
        AccessItem.accessibility,
        AccessItem.popup,
      ]);
      expect(accessItemsFor(AccessFeature.background, 'vivo'), [
        AccessItem.notifications,
        AccessItem.battery,
        AccessItem.vendorBackground,
        AccessItem.autostart,
      ]);
      expect(accessItemsFor(AccessFeature.voice, 'vivo'), [AccessItem.mic]);
    });

    test('on stock Android nothing of a maker\'s', () {
      expect(accessItemsFor(AccessFeature.phone, null), [AccessItem.notifications, AccessItem.accessibility]);
      expect(accessItemsFor(AccessFeature.background, null), [AccessItem.notifications, AccessItem.battery]);
      expect(accessItemsFor(AccessFeature.background, 'huawei'), [
        AccessItem.notifications,
        AccessItem.battery,
        AccessItem.vendorBackground,
      ]);
      expect(accessItemsFor(AccessFeature.phone, 'oppo'), [AccessItem.notifications, AccessItem.accessibility]);
    });

    test('the walk takes each item once: dialogs, pages, the makers\' pages, the window last', () {
      expect(accessWalk(AccessFeature.values, 'vivo'), _i);
      expect(accessWalk({AccessFeature.phone, AccessFeature.background}, 'xiaomi'), [
        AccessItem.notifications,
        AccessItem.battery,
        AccessItem.vendorBackground,
        AccessItem.autostart,
        AccessItem.accessibility,
        AccessItem.popup,
      ]);
      expect(accessWalk({AccessFeature.pet, AccessFeature.phone}, null), [
        AccessItem.notifications,
        AccessItem.accessibility,
        AccessItem.overlay,
      ]);
      expect(accessWalk(const [], 'vivo'), isEmpty);
    });
  });

  group('states', () {
    test('read from the phone; null when it can\'t tell', () {
      expect(accessStateOf(AccessItem.mic, readingsWith(offPhone, mic: true), const {}), AccessState.on);
      expect(accessStateOf(AccessItem.storage, offPhone, const {}), AccessState.off);
      expect(accessStateOf(AccessItem.notifications, const AccessReadings(), const {}), isNull);
    });

    test('a maker\'s switch is never on: visited once the person says so', () {
      expect(accessStateOf(AccessItem.autostart, offPhone, const {}), AccessState.unknown);
      expect(accessStateOf(AccessItem.autostart, offPhone, {AccessItem.autostart}), AccessState.visited);
      // Even without the native side: what the person said is what there is.
      expect(accessStateOf(AccessItem.popup, const AccessReadings(), const {}), AccessState.unknown);
      expect(AccessState.visited.settled, isTrue);
      expect(AccessState.unknown.settled, isFalse);
      expect(AccessState.off.settled, isFalse);
    });
  });

  group('「先允许受限制的设置」', () {
    int? step(RestrictedSettingsState? state, {bool mayNeed = true, bool tried = false, bool was = false, bool info = false}) =>
        restrictedStep(state: state, mayNeed: mayNeed, tried: tried, wasRestricted: was, appInfoVisited: info);

    test('the system says where the person is', () {
      expect(step(RestrictedSettingsState.guarded), 1);
      expect(step(RestrictedSettingsState.acknowledged), 2);
      expect(step(RestrictedSettingsState.acknowledged, tried: true), 2);
      // Allowed: back to the switch.
      expect(step(RestrictedSettingsState.clear, was: true), 3);
      // Never restricted: no steps at all.
      expect(step(RestrictedSettingsState.clear, tried: true), isNull);
    });

    test('unknown: only after a trip to the switch came back off, on a phone it may apply to', () {
      expect(step(null), isNull);
      expect(step(null, tried: true), 2);
      expect(step(null, tried: true, info: true), 3);
      expect(step(null, tried: true, mayNeed: false), isNull);
    });

    test('the device facts behind "may apply"', () {
      expect(const PhoneDevice(restricted: RestrictedSettingsState.clear, sdkInt: 34, sideloaded: true).mayNeedRestrictedSettings, isFalse);
      expect(const PhoneDevice(restricted: RestrictedSettingsState.guarded, sideloaded: false).mayNeedRestrictedSettings, isTrue);
      expect(const PhoneDevice(sdkInt: 34, sideloaded: true).mayNeedRestrictedSettings, isTrue);
      expect(const PhoneDevice(sdkInt: 32).mayNeedRestrictedSettings, isFalse);
      expect(PhoneDevice.fromMap(const {'restricted': 'acknowledged'}).restricted, RestrictedSettingsState.acknowledged);
      expect(PhoneDevice.fromMap(const {'restricted': 'nonsense'}).restricted, isNull);
    });
  });

  group('first run keeps', () {
    Future<ProviderContainer> container() async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(accessSetupProvider);
      c.read(accessVisitedProvider);
      await Future<void>.delayed(Duration.zero);
      return c;
    }

    test('the picks and skips, and voice as true or false', () async {
      SharedPreferences.setMockInitialValues({});
      var c = await container();
      expect(c.read(accessSetupProvider).loaded, isTrue);
      expect(c.read(accessSetupProvider).features, isNull);

      await c.read(accessSetupProvider.notifier).choose({AccessFeature.voice, AccessFeature.phone});
      await c.read(accessSetupProvider.notifier).skip(AccessItem.popup);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(onboardingWantsVoiceKey), isTrue);

      // A new launch finds the same walk.
      c = await container();
      expect(c.read(accessSetupProvider).features, {AccessFeature.voice, AccessFeature.phone});
      expect(c.read(accessSetupProvider).skipped, {AccessItem.popup});

      await c.read(accessSetupProvider.notifier).choose({AccessFeature.files});
      expect(prefs.getBool(onboardingWantsVoiceKey), isFalse);

      await c.read(accessSetupProvider.notifier).clear();
      expect(prefs.getString(AccessSetupController.prefsKey), isNull);
      // The answer about voice stays for the voice feature.
      expect(prefs.getBool(onboardingWantsVoiceKey), isFalse);
    });

    test('nothing about voice while the page was never confirmed', () async {
      SharedPreferences.setMockInitialValues({});
      final c = await container();
      await c.read(accessSetupProvider.notifier).clear();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(onboardingWantsVoiceKey), isFalse);
    });

    test('the makers\' switches the person said are set', () async {
      SharedPreferences.setMockInitialValues({});
      var c = await container();
      await c.read(accessVisitedProvider.notifier).mark(AccessItem.autostart);
      c = await container();
      expect(c.read(accessVisitedProvider), {AccessItem.autostart});
    });
  });
}
