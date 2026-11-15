import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The OS by Dart's name for it, read through here so a test can be on another
/// one. `Platform.isOhos` only exists on oh-flutter's Dart, hence the string.
final operatingSystemProvider = Provider<String>((ref) => Platform.operatingSystem);

/// Whether this OS has what only Android has today: 手机操控 (an accessibility
/// service to drive the phone; HarmonyOS has 系统操作 instead), the pet's windows
/// over other apps, a picture as a launcher shortcut, the rescue tools that work on
/// its Linux guest (自动安全模式, Direct 引擎), the relay's direct link, the line
/// about a maker cutting the network, call capture (语音通话, 实时字幕: the
/// streaming recognizer) and the
/// failure-evidence store behind 自动故障分析.
///
/// This hides only what has no HarmonyOS form yet, in the hub, search and links
/// alike (a link says it isn't there, or leads to its form there:
/// [SettingsIndex.ohosLink]); each moves out of here once it is built there. What
/// HarmonyOS does differently rather than lacks asks [operatingSystemProvider]
/// instead (后台运行, 系统权限). It asks the OS, where
/// [LocalRuntimeState.available] and [AppUpdateState.installable] ask for a
/// channel handler that may still come.
final androidSystemFeaturesProvider = Provider<bool>((ref) => ref.watch(operatingSystemProvider) != 'ohos');
