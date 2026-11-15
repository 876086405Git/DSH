import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The OS by Dart's name for it, read through here so a test can be on another
/// one. `Platform.isOhos` only exists on oh-flutter's Dart, hence the string.
final operatingSystemProvider = Provider<String>((ref) => Platform.operatingSystem);

/// Whether this OS has what only Android has today: 手机操控 (an accessibility
/// service to drive the phone; HarmonyOS has 系统操作 instead), the pet's windows
/// over other apps, the rescue tools that work on its Linux guest (自动安全模式,
/// Direct 引擎), the relay's direct link and the line about a maker cutting the
/// network.
///
/// This hides only what has no HarmonyOS form yet, in the hub, search and links
/// alike (a link says it isn't there, or leads to its form there:
/// [SettingsIndex.ohosLink]); each moves out of here once it is built there. What
/// HarmonyOS does differently rather than lacks asks [operatingSystemProvider]
/// instead (后台运行, 系统权限). It asks the OS, where
/// [LocalRuntimeState.available] and [AppUpdateState.installable] ask for a
/// channel handler that may still come.
final androidSystemFeaturesProvider = Provider<bool>((ref) => ref.watch(operatingSystemProvider) != 'ohos');
