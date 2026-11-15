import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The OS by Dart's name for it, read through here so a test can be on another
/// one. `Platform.isOhos` only exists on oh-flutter's Dart, hence the string.
final operatingSystemProvider = Provider<String>((ref) => Platform.operatingSystem);

/// Whether this OS has what only Android has today: 手机操控 (an accessibility
/// service to drive the phone), the pet's windows over other apps, refresh-rate
/// caps, a picture as a launcher shortcut, the rescue tools that work on its Linux
/// guest (安全模式, Direct 引擎), and the line about a maker cutting the network.
///
/// This hides only what has no HarmonyOS or iOS form yet, in the hub, search and
/// links alike (a link says the page isn't available here); each moves out of here
/// once it is built there. What HarmonyOS does differently rather than lacks
/// asks [operatingSystemProvider] instead (后台运行, 系统权限). It asks the OS, where
/// [LocalRuntimeState.available] and [AppUpdateState.installable] ask for a
/// channel handler that may still come.
final androidSystemFeaturesProvider = Provider<bool>((ref) => androidSystemFeaturesOn(ref.watch(operatingSystemProvider)));

/// Whether a launch screen of one's own can be set: Flutter draws it, so it takes the system's
/// picker and a clip player (`dsh/native-files`, `dsh/launch_clip`), not yet there on HarmonyOS.
final ownLaunchScreenProvider = Provider<bool>((ref) => ownLaunchScreenOn(ref.watch(operatingSystemProvider)));

bool ownLaunchScreenOn(String os) => os != 'ohos';

/// Whether 重置和卸载运行环境 is on offer: not yet on HarmonyOS, whose channel refuses it.
final engineResetProvider = Provider<bool>((ref) => engineResetOn(ref.watch(operatingSystemProvider)));

bool engineResetOn(String os) => os != 'ohos';

/// Whether flutter_webrtc has an implementation here, for DSH Remote's direct path.
final webRtcAvailableProvider = Provider<bool>((ref) => webRtcOn(ref.watch(operatingSystemProvider)));

bool androidSystemFeaturesOn(String os) => os != 'ohos' && os != 'ios';

bool webRtcOn(String os) => os != 'ohos';
