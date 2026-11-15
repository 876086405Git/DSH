// Where the on-device engine's files are, as the engine itself sees them: what
// the app hands it (a new session's cwd) and reads back from it (tool paths).
//
// Android's engine runs in a Linux guest, so these are the guest's fixed paths
// and the guest root is `filesDir/runtime/rootfs`. HarmonyOS has no guest: the
// engine runs in the app's own process and sees real sandbox paths, which only
// the OS knows. It keeps the same layout under a root the native side reports,
// so a guest path still joins onto the root the same way on both.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LocalPaths {
  LocalPaths._();

  static String? _root;

  /// The directory that stands for `/` on HarmonyOS. Null on Android, where
  /// the guest root moves with the install ([GuestFs.local] looks it up).
  static String? get root => _root;

  /// Whether the engine sees real paths and has no guest around it.
  static bool get noGuest => _root != null;

  /// Home of the engine's user.
  static String get home => '${_root ?? ''}/root';

  /// Default working directory for sessions created on the phone.
  static String get workspace => '$home/workspace';

  /// Asks for the root before the first frame where there's no guest (HarmonyOS,
  /// iOS). Without an answer the paths stay Android's and the engine refuses them,
  /// which shows up as a failed session rather than a wrong folder.
  static Future<void> load({bool? ohos, MethodChannel channel = const MethodChannel('dsh/runtime')}) async {
    if (!(ohos ?? (Platform.operatingSystem == 'ohos' || Platform.isIOS))) return;
    try {
      final root = await channel.invokeMethod<String>('guestRoot');
      if (root != null && root.startsWith('/')) _root = root;
    } on PlatformException {
      // The native side couldn't say.
    } on MissingPluginException {
      // No native side.
    }
  }

  @visibleForTesting
  static set debugRoot(String? root) => _root = root;
}
