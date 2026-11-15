// System permissions by what they are for: first run's 「想让 DSH Go 帮你做哪些
// 事」 (lib/ui/onboarding/access_step.dart) and 设置 › 系统权限
// (lib/ui/settings/system_access_page.dart) read and open the same items here.
//
// Nothing here detects or opens anything on its own: the readings come from
// the channels the rest of the app already uses (runtime bridge for storage,
// battery and the makers' pages; notify, phone and pet overlay channels; the
// voice plugin), so a grant seen here is the grant the feature sees.
//
// feature → items (this phone's maker decides the last few):
//
//   读写手机里的文件  storage
//   桌宠与悬浮窗     overlay
//   手机操控        accessibility · notifications · popup (vivo, Xiaomi)
//   后台持续运行     notifications · battery · vendorBackground · autostart (vivo, Xiaomi)
//   语音输入        mic
//   回复提醒        notifications (HarmonyOS, which has no other way to them)

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pets/overlay_channel.dart';
import '../pets/pet_prefs.dart';
import '../runtime/background_net.dart' show backgroundSettingsProvider;
import '../runtime/runtime_bridge.dart' show RuntimePhase;
import '../runtime/runtime_state.dart';
import '../ui/chat/voice/voice_bridge.dart' show VoicePermission;
import 'android_features.dart';
import 'engine_control.dart';
import 'notify_state.dart';
import 'phone_state.dart';
import 'settings_state.dart';
import 'voice_model_state.dart' show VoiceModelController, voiceModelDefaultBytes;
import 'voice_state.dart';

/// The offline voice model's download in MB as the voice settings show it,
/// said before it is chosen (the voice feature downloads it once the engine
/// is up).
final voiceModelApproxMb = (voiceModelDefaultBytes / 1000000).round();

/// First run's answer about voice input, which [VoiceModelController] picks
/// up: true when 语音输入 was picked (it starts the download once), false when
/// the page was confirmed without it, absent when the page was skipped.
const onboardingWantsVoiceKey = VoiceModelController.onboardingKey;

/// What a person picks on first run: things DSH Go does, not permission names.
/// What [os] offers is [accessFeaturesFor]'s, never all of these.
enum AccessFeature { files, pet, phone, background, voice, alerts }

/// What first run and 系统权限 offer on [os], in their order. HarmonyOS and iOS
/// have only what works there: their files, windows over other apps and the
/// phone aren't reachable, and nothing keeps a turn running in the background
/// (后台运行 says so), which leaves notifications their own feature.
List<AccessFeature> accessFeaturesFor(String os) => androidSystemFeaturesOn(os)
    ? const [
        AccessFeature.files,
        AccessFeature.pet,
        AccessFeature.phone,
        AccessFeature.background,
        AccessFeature.voice,
      ]
    : const [AccessFeature.alerts, AccessFeature.voice];

/// Whether 语音输入 on [os] means the offline model's download: HarmonyOS and
/// iOS use the system's recogniser and have no model.
bool accessVoiceDownloads(String os) => androidSystemFeaturesOn(os);

/// One system permission or maker's switch, in the order first run walks
/// them: the system's own dialogs first, then settings pages, the makers'
/// pages after the system's, and the floating window last (with
/// accessibility on, the pet needs no other permission).
enum AccessItem {
  mic,
  storage,
  notifications,
  battery,
  vendorBackground,
  autostart,
  accessibility,
  popup,
  overlay;

  /// A maker's own switch: no API reports it, so the person says it is set.
  bool get vendor => vendorWire != null;

  /// Its name for the native side (`VendorSettings.Switch`).
  String? get vendorWire => switch (this) {
    vendorBackground => 'background',
    autostart => 'autostart',
    popup => 'popup',
    _ => null,
  };

  /// Asked for on [os] with a system dialog: the answer is back when the call
  /// returns. HarmonyOS and iOS ask for notifications that way; Android's come
  /// with their channels, and this opens their settings page.
  bool dialogOn(String os) =>
      this == mic || this == storage || this == battery || (this == notifications && !androidSystemFeaturesOn(os));
}

/// Where an item stands.
enum AccessState {
  /// Detected on.
  on,

  /// Detected off.
  off,

  /// A maker's switch the person went to and says is set ([AccessItem.vendor]).
  visited,

  /// A maker's switch not visited yet.
  unknown;

  /// Nothing left to do for it.
  bool get settled => this == on || this == visited;
}

/// The makers' own switches, by the native vendor key (`VendorSettings.kt`
/// holds their pages). Huawei and Honor keep start-up and background running
/// on one page; OPPO keeps everything on the app's details page; Samsung's
/// 「不受限制」 is the system's battery exemption.
const vendorSwitches = <String, List<AccessItem>>{
  'vivo': [AccessItem.vendorBackground, AccessItem.autostart, AccessItem.popup],
  'xiaomi': [AccessItem.vendorBackground, AccessItem.autostart, AccessItem.popup],
  'huawei': [AccessItem.vendorBackground],
  'honor': [AccessItem.vendorBackground],
  'oppo': [AccessItem.vendorBackground],
};

/// What [feature] needs on a phone of [vendor], in walk order.
List<AccessItem> accessItemsFor(AccessFeature feature, String? vendor) {
  final own = vendorSwitches[vendor] ?? const <AccessItem>[];
  final items = switch (feature) {
    AccessFeature.files => [AccessItem.storage],
    AccessFeature.pet => [AccessItem.overlay],
    AccessFeature.phone => [AccessItem.accessibility, AccessItem.notifications, AccessItem.popup],
    AccessFeature.background => [
      AccessItem.notifications,
      AccessItem.battery,
      AccessItem.vendorBackground,
      AccessItem.autostart,
    ],
    AccessFeature.voice => [AccessItem.mic],
    AccessFeature.alerts => [AccessItem.notifications],
  };
  return [
    for (final item in AccessItem.values)
      if (items.contains(item) && (!item.vendor || own.contains(item))) item,
  ];
}

/// Everything [features] need, each item once, in walk order.
List<AccessItem> accessWalk(Iterable<AccessFeature> features, String? vendor) {
  final wanted = {for (final f in features) ...accessItemsFor(f, vendor)};
  return [for (final item in AccessItem.values) if (wanted.contains(item)) item];
}

/// What the phone says right now. A null grant: this phone can't tell (no
/// native side), and the item isn't offered.
class AccessReadings {
  const AccessReadings({
    this.vendor,
    this.appLabel,
    this.mic,
    this.storage,
    this.notifications,
    this.battery,
    this.accessibility,
    this.overlay,
    this.overlayBlocked = false,
    this.restricted,
    this.sdk,
    this.manufacturer,
    this.sideloaded,
    this.metered,
  });

  /// `vivo`, `xiaomi`, `huawei`, `honor`, `oppo`, `samsung`; null for the rest.
  final String? vendor;

  /// The app's name as system settings list it.
  final String? appLabel;
  final bool? mic;
  final bool? storage;
  final bool? notifications;
  final bool? battery;
  final bool? accessibility;

  /// The pet can be drawn over other apps (the permission, or accessibility).
  final bool? overlay;

  /// The system says the overlay is allowed but the window was refused: a
  /// maker's own floating-window switch (vivo), on the app's details page.
  final bool overlayBlocked;

  final RestrictedSettingsState? restricted;
  final int? sdk;
  final String? manufacturer;
  final bool? sideloaded;

  /// On mobile data (a download costs the person).
  final bool? metered;

  bool? granted(AccessItem item) => switch (item) {
    AccessItem.mic => mic,
    AccessItem.storage => storage,
    AccessItem.notifications => notifications,
    AccessItem.battery => battery,
    AccessItem.accessibility => accessibility,
    AccessItem.overlay => overlay,
    AccessItem.vendorBackground || AccessItem.autostart || AccessItem.popup => null,
  };

  /// Android's 「受限制的设置」 may stand in front of the accessibility switch.
  bool get mayNeedRestricted => PhoneDevice(sdkInt: sdk, sideloaded: sideloaded, restricted: restricted)
      .mayNeedRestrictedSettings;
}

/// [item]'s state from [readings]; null when this phone can't tell (the
/// item is left out). A maker's switch is [AccessState.visited] once the
/// person said so, whatever the phone.
AccessState? accessStateOf(AccessItem item, AccessReadings readings, Set<AccessItem> visited) {
  if (item.vendor) return visited.contains(item) ? AccessState.visited : AccessState.unknown;
  return switch (readings.granted(item)) {
    true => AccessState.on,
    false => AccessState.off,
    null => null,
  };
}

/// The step of 「先允许受限制的设置」 the accessibility page is on, 1-based
/// (1 tap the greyed switch once, 2 allow it on App info, 3 turn it on);
/// null when nothing stands in front of the switch.
///
/// Read from the system when it says ([state]); otherwise, on a phone where
/// it may apply, only after a trip to Accessibility came back without the
/// switch on ([tried]) — that trip was step 1.
int? restrictedStep({
  required RestrictedSettingsState? state,
  required bool mayNeed,
  required bool tried,
  required bool wasRestricted,
  required bool appInfoVisited,
}) => switch (state) {
  RestrictedSettingsState.guarded => 1,
  RestrictedSettingsState.acknowledged => 2,
  RestrictedSettingsState.clear => wasRestricted ? 3 : null,
  null => !mayNeed || !tried ? null : (appInfoVisited ? 3 : 2),
};

// ── Reading and opening ─────────────────────────────────────────────────────

/// Reads every item and opens where each is turned on.
abstract class AccessDriver {
  Future<AccessReadings> read();

  /// The system dialog for [item], else its settings page; [again] after a
  /// denial goes to the page a dialog can no longer be raised from. False
  /// when nothing opened.
  Future<bool> open(AccessItem item, {bool again = false});

  /// This app's system info page (「允许受限制的设置」).
  Future<bool> openAppInfo();
}

/// The real phone: the same channels the features use.
class SystemAccessDriver implements AccessDriver {
  SystemAccessDriver(this.ref);

  final Ref ref;

  static const _voice = MethodChannel('dsh/voice');

  static Future<T?> _safe<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      // No native side (tests, desktop), or it failed: unknown.
      return null;
    }
  }

  Future<bool?> _readMic() => _safe(() async => switch (await _voice.invokeMethod<String>('permission')) {
    'granted' => true,
    'denied' => false,
    _ => null,
  });

  Future<bool?> _readNotifications() => _safe(() async {
    final s = await ref.read(notifyChannelProvider).status();
    return s.native ? s.enabled : null;
  });

  @override
  Future<AccessReadings> read() async {
    // Only what [accessFeaturesFor] offers there: the runtime's storage and
    // battery answers on HarmonyOS and iOS aren't readings (always not granted,
    // an error) and the rest has no native side. Unread, none can show as off.
    if (!androidSystemFeaturesOn(ref.read(operatingSystemProvider))) {
      final mic = _readMic();
      final notify = _readNotifications();
      final readings = AccessReadings(mic: await mic, notifications: await notify);
      ref.invalidate(notifySystemStatusProvider);
      return readings;
    }
    final bridge = ref.read(runtimeBridgeProvider);
    final phone = ref.read(phoneProvider.notifier);
    final pet = ref.read(petOverlayProvider.notifier);
    final info = _safe(() => ref.read(backgroundSettingsProvider.future));
    final mic = _readMic();
    final storage = _safe(() async => (await bridge.storageStatus()).granted);
    final notify = _readNotifications();
    final battery = _safe(bridge.batteryExempt);
    final metered = _safe(bridge.networkMetered);
    final phoneRead = _safe(() async {
      await phone.refreshStatus();
      return true;
    });
    final overlay = _safe(pet.refresh);
    await phoneRead;
    final status = ref.read(phoneProvider).status;
    final petStatus = await overlay;
    final settings = await info;
    // Keep the pages that show the same facts in step.
    ref.invalidate(batteryExemptProvider);
    ref.invalidate(notifySystemStatusProvider);
    return AccessReadings(
      vendor: settings?.vendor,
      appLabel: settings?.label,
      mic: await mic,
      storage: await storage,
      notifications: await notify,
      battery: await battery,
      accessibility: status.ready ? status.a11y.enabled : null,
      overlay: petStatus == null || !petStatus.native ? null : petStatus.permission.usable,
      overlayBlocked: petStatus?.permission == PetOverlayPermission.blocked,
      restricted: status.device.restricted,
      sdk: status.device.sdkInt ?? (petStatus?.sdk == 0 ? null : petStatus?.sdk),
      manufacturer: status.device.manufacturer,
      sideloaded: status.device.sideloaded,
      metered: await metered,
    );
  }

  @override
  Future<bool> open(AccessItem item, {bool again = false}) async {
    final bridge = ref.read(runtimeBridgeProvider);
    final opened = await _safe<bool>(() async {
      switch (item) {
        case AccessItem.mic:
          final voice = ref.read(voiceBridgeProvider);
          // Denied for good: only the app's permission page can turn it on.
          if (await voice.requestPermission() == VoicePermission.blocked) await voice.openSettings();
          return true;
        case AccessItem.storage:
          final access = await bridge.requestStorage();
          if (access.granted) return true;
          // The device ignores legacy storage: 「所有文件访问」 is the way.
          if (access.permission && !access.legacy) return bridge.openAllFilesAccess();
          // Denied again: the dialog won't come back, the app's page will.
          if (again) return ref.read(phoneProvider.notifier).openAppDetails();
          return true;
        case AccessItem.notifications:
          final notify = ref.read(notifyChannelProvider);
          if (again || androidSystemFeaturesOn(ref.read(operatingSystemProvider))) return notify.openSettings();
          // The system's dialog; refused, the step says so and 重试 comes back
          // here with [again], for the settings a dialog can no longer reach.
          await notify.requestPermission();
          return true;
        case AccessItem.battery:
          return await bridge.requestBatteryExempt() ?? false;
        case AccessItem.vendorBackground || AccessItem.autostart || AccessItem.popup:
          return await bridge.openVendorSettings(item.vendorWire!) != null;
        case AccessItem.accessibility:
          return ref.read(phoneProvider.notifier).openAccessibilitySettings();
        case AccessItem.overlay:
          // On with it: the pet is what the permission is for. A vivo switch the
          // system doesn't report opens the app's page instead.
          await ref.read(petOverlayProvider.notifier).turnOn();
          return true;
      }
    });
    return opened ?? false;
  }

  @override
  Future<bool> openAppInfo() async => await _safe(ref.read(phoneProvider.notifier).openAppDetails) ?? false;
}

final accessDriverProvider = Provider<AccessDriver>((ref) => SystemAccessDriver(ref));

/// The latest readings; [AccessReadingsController.refresh] reads again (on
/// coming back from system settings).
final accessReadingsProvider = AsyncNotifierProvider<AccessReadingsController, AccessReadings>(
  AccessReadingsController.new,
);

class AccessReadingsController extends AsyncNotifier<AccessReadings> {
  @override
  Future<AccessReadings> build() => ref.read(accessDriverProvider).read();

  /// Reads again, keeping the last readings on screen meanwhile.
  Future<AccessReadings> refresh() async {
    final readings = await ref.read(accessDriverProvider).read();
    if (ref.mounted) state = AsyncData(readings);
    return readings;
  }
}

/// The makers' switches the person went to and said are set: no API reports
/// them, so this is the only record (`system_access_visited`).
final accessVisitedProvider = NotifierProvider<AccessVisitedController, Set<AccessItem>>(
  AccessVisitedController.new,
);

class AccessVisitedController extends Notifier<Set<AccessItem>> {
  static const prefsKey = 'system_access_visited';

  @override
  Set<AccessItem> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final names = prefs.getStringList(prefsKey) ?? const [];
      if (!ref.mounted) return;
      state = {...state, for (final n in names) ?AccessItem.values.asNameMap()[n]};
    } catch (_) {}
  }

  Future<void> mark(AccessItem item) async {
    if (state.contains(item)) return;
    state = {...state, item};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, [for (final i in state) i.name]);
    } catch (_) {}
  }
}

// ── First run ───────────────────────────────────────────────────────────────

/// First run's picks while it walks them (`onboarding_access`), so a launch
/// after the app was killed in system settings comes back to the same walk.
class AccessSetup {
  const AccessSetup({this.loaded = false, this.features, this.skipped = const {}});

  final bool loaded;

  /// Picked, and being walked; null before the pick (or after a skip).
  final Set<AccessFeature>? features;

  /// Items passed over with 「跳过」.
  final Set<AccessItem> skipped;
}

final accessSetupProvider = NotifierProvider<AccessSetupController, AccessSetup>(AccessSetupController.new);

class AccessSetupController extends Notifier<AccessSetup> {
  static const prefsKey = 'onboarding_access';

  Future<void>? _finishing;

  @override
  AccessSetup build() {
    unawaited(_load());
    return const AccessSetup();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (!ref.mounted) return;
      if (raw == null) {
        state = const AccessSetup(loaded: true);
        return;
      }
      final map = jsonDecode(raw) as Map<String, Object?>;
      Set<T> names<T extends Enum>(Object? list, List<T> values) => {
        if (list is List)
          for (final n in list) ?values.asNameMap()[n],
      };
      state = AccessSetup(
        loaded: true,
        features: names(map['features'], AccessFeature.values),
        skipped: names(map['skipped'], AccessItem.values),
      );
    } catch (_) {
      if (ref.mounted) state = const AccessSetup(loaded: true);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final features = state.features;
      if (features == null) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(
          prefsKey,
          jsonEncode({
            'features': [for (final f in features) f.name],
            'skipped': [for (final i in state.skipped) i.name],
          }),
        );
      }
    } catch (_) {}
  }

  /// 「开启所选」: the walk starts, and the voice answer is written for the
  /// voice feature to pick up (never yes where there is no model to fetch,
  /// [accessVoiceDownloads]). [phoneMode], picked with 手机操控, goes to the
  /// phone's policies now, or as soon as they can be written
  /// ([PhoneController.chooseConfirmMode]).
  Future<void> choose(Set<AccessFeature> features, {PhoneConfirmMode? phoneMode}) async {
    state = AccessSetup(loaded: true, features: {...features});
    await _save();
    try {
      final prefs = await SharedPreferences.getInstance();
      final os = ref.read(operatingSystemProvider);
      await prefs.setBool(onboardingWantsVoiceKey, features.contains(AccessFeature.voice) && accessVoiceDownloads(os));
    } catch (_) {}
    if (phoneMode != null && features.contains(AccessFeature.phone)) {
      try {
        await ref.read(phoneProvider.notifier).chooseConfirmMode(phoneMode);
      } catch (_) {
        // Kept pending: the next read of the policies writes it.
      }
    }
  }

  Future<void> skip(AccessItem item) async {
    state = AccessSetup(loaded: true, features: state.features, skipped: {...state.skipped, item});
    await _save();
  }

  /// The step is over.
  Future<void> clear() async {
    state = const AccessSetup(loaded: true);
    await _save();
  }

  /// 「继续」 on the summary: what was picked is turned on from readings taken
  /// now (an item turned on from the summary counts), and the step is over
  /// only once the settings that changes are written — killed before then,
  /// the next launch comes back to the step. Asked again meanwhile, it is the
  /// same run.
  Future<void> finish() => _finishing ??= _finish().whenComplete(() => _finishing = null);

  Future<void> _finish() async {
    final readings = await ref.read(accessReadingsProvider.notifier).refresh();
    await apply(readings);
    await clear();
  }

  /// Turns on what was picked, as far as the phone allows: 访问手机文件 once
  /// files may be reached, 手机操控 (its disclosure was accepted on the pick),
  /// the default pet unless one was chosen, its floating window once it can
  /// be drawn. An engine running or starting restarts once
  /// so its mounts and tools follow: one starting already took the old
  /// settings with it.
  Future<void> apply(AccessReadings readings) async {
    final features = state.features ?? const <AccessFeature>{};
    // Each on its own: one that fails (no native side) leaves the others.
    Future<T?> attempt<T>(Future<T> Function() step) async {
      try {
        return await step();
      } catch (_) {
        return null;
      }
    }

    var restart = false;
    if (features.contains(AccessFeature.files) && readings.storage == true && !ref.read(settingsProvider).phoneStorage) {
      await attempt(() => ref.read(settingsProvider.notifier).setPhoneStorage(true));
      restart = true;
    }
    var restarting = false;
    if (features.contains(AccessFeature.phone) && !ref.read(phoneProvider).status.enabled) {
      restarting = (await attempt(() => ref.read(phoneProvider.notifier).setEnabled(true)))?.restarting ?? false;
    }
    if (features.contains(AccessFeature.phone)) {
      // The pick's 确认方式, if it didn't go in then; still pending after this,
      // it goes in on the next read of the policies.
      await attempt(ref.read(phoneProvider.notifier).applyPendingConfirmMode);
    }
    final phase = ref.read(localRuntimeProvider).status.phase;
    if (restart && !restarting && (phase == RuntimePhase.running || phase == RuntimePhase.starting)) {
      unawaited(EngineControl.restart(ref.container));
    }
    if (features.contains(AccessFeature.pet)) {
      // The pet itself, or the floating window has nothing to show (a light
      // phone starts without one). Also in the app when the window stays off.
      await attempt(ref.read(petPrefsProvider.notifier).adoptDefault);
      if (readings.overlay == true && !ref.read(petOverlayProvider).working) {
        await attempt(ref.read(petOverlayProvider.notifier).turnOn);
      }
    }
  }
}
