// Names, icons and one-line reasons for the system-permission items
// (lib/state/access_state.dart). The makers' switches are named as each
// maker names them, with where they live.

import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../../state/android_features.dart';
import '../../state/app_info.dart';
import '../theme/app_icons.dart';

extension AccessFeatureText on AccessFeature {
  IconData get icon => switch (this) {
    AccessFeature.files => AppIcons.fileAccess,
    AccessFeature.pet => AppIcons.pet,
    AccessFeature.phone => AppIcons.phoneControl,
    AccessFeature.background => AppIcons.keepAlive,
    AccessFeature.voice => AppIcons.voice,
    AccessFeature.alerts => AppIcons.notifications,
  };

  String title(L10n l10n) => switch (this) {
    AccessFeature.files => l10n.accessFeatureFiles,
    AccessFeature.pet => l10n.accessFeaturePet,
    AccessFeature.phone => l10n.accessFeaturePhone,
    AccessFeature.background => l10n.accessFeatureBackground,
    AccessFeature.voice => l10n.accessFeatureVoice,
    AccessFeature.alerts => l10n.accessFeatureAlerts,
  };

  /// What it needs, in one line.
  String needs(L10n l10n) => switch (this) {
    AccessFeature.files => l10n.accessFeatureFilesNeeds,
    AccessFeature.pet => l10n.accessFeaturePetNeeds,
    AccessFeature.phone => l10n.accessFeaturePhoneNeeds,
    AccessFeature.background => l10n.accessFeatureBackgroundNeeds,
    AccessFeature.voice => l10n.accessFeatureVoiceNeeds,
    AccessFeature.alerts => l10n.accessFeatureAlertsNeeds,
  };
}

extension AccessItemText on AccessItem {
  IconData get icon => switch (this) {
    AccessItem.mic => AppIcons.voice,
    AccessItem.storage => AppIcons.fileAccess,
    AccessItem.notifications => AppIcons.notifications,
    AccessItem.battery => AppIcons.keepAlive,
    AccessItem.vendorBackground => AppIcons.highPower,
    AccessItem.autostart => AppIcons.autostart,
    AccessItem.accessibility => AppIcons.accessibility,
    AccessItem.popup => AppIcons.backgroundPopUp,
    AccessItem.overlay => AppIcons.overlayPermission,
  };

  /// The switch as the system (or [vendor]'s ROM) names it.
  String title(L10n l10n, {String? vendor}) => switch (this) {
    AccessItem.mic => l10n.accessMicTitle,
    AccessItem.storage => l10n.accessStorageTitle,
    AccessItem.notifications => l10n.accessNotifyTitle,
    AccessItem.battery => l10n.accessBatteryTitle,
    AccessItem.vendorBackground => switch (vendor) {
      'vivo' => l10n.pluginsAllowHighPower,
      'xiaomi' => l10n.pluginsXiaomiBatterySetting,
      'oppo' => l10n.pluginsOppoBatterySetting,
      _ => l10n.pluginsHuaweiBatterySetting,
    },
    AccessItem.autostart => l10n.accessAutostartTitle,
    AccessItem.accessibility => l10n.accessA11yTitle,
    AccessItem.popup => l10n.accessPopupTitle,
    AccessItem.overlay => l10n.accessOverlayTitle,
  };

  /// Why, in one line. On HarmonyOS and iOS an alert can only go out while the
  /// app runs.
  String why(L10n l10n, {required String os}) => switch (this) {
    AccessItem.mic => l10n.accessMicWhy,
    AccessItem.storage => l10n.accessStorageWhy,
    AccessItem.notifications => androidSystemFeaturesOn(os) ? l10n.accessNotifyWhy : l10n.harmonyNotifyWhy,
    AccessItem.battery => l10n.accessBatteryWhy,
    AccessItem.vendorBackground => l10n.accessVendorBackgroundWhy,
    AccessItem.autostart => l10n.accessAutostartWhy,
    AccessItem.accessibility => l10n.accessA11yWhy,
    AccessItem.popup => l10n.accessPopupWhy,
    AccessItem.overlay => l10n.accessOverlayWhy,
  };

  /// Where a maker's switch lives, for when its own page doesn't open and
  /// the app's details page does; null for the system's items.
  String? path(L10n l10n, {String? vendor, String? app}) {
    final name = app ?? AppInfo.name;
    return switch ((this, vendor)) {
      (AccessItem.vendorBackground, 'vivo') => l10n.pluginsVivoBatteryPath(name),
      (AccessItem.vendorBackground, 'xiaomi') => l10n.pluginsXiaomiBatteryPath(name),
      (AccessItem.vendorBackground, 'huawei' || 'honor') => l10n.pluginsHuaweiBatteryPath(name),
      (AccessItem.vendorBackground, 'oppo') => l10n.pluginsOppoBatteryPath(name),
      (AccessItem.autostart, 'vivo') => l10n.accessVivoAutostartPath(name),
      (AccessItem.autostart, 'xiaomi') => l10n.accessXiaomiAutostartPath(name),
      (AccessItem.popup, 'vivo') => l10n.accessVivoPopupPath(name),
      (AccessItem.popup, 'xiaomi') => l10n.accessXiaomiPopupPath(name),
      _ => null,
    };
  }
}

extension AccessStateText on AccessState {
  String label(L10n l10n) => switch (this) {
    AccessState.on => l10n.accessStateOn,
    AccessState.off => l10n.accessStateOff,
    AccessState.visited => l10n.accessStateVisited,
    AccessState.unknown => l10n.accessStateUnknown,
  };
}
