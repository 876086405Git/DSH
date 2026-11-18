// 桌面图标: which of the four launcher icons the phone shows. Native side:
// android/.../icons/ (LauncherIconPlugin, LauncherIcons; MethodChannel
// `dsh/launcher_icon`), one <activity-alias> per icon; on HarmonyOS
// ohos/.../LauncherIconPlugin.ets, the system's alternate icons.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';

/// The launcher icons, in the picker's order. [mist] is every install's.
enum AppIcon {
  mist,
  night,
  frost,
  ink;

  String get label => switch (this) {
    mist => appL10n.stateIconMist,
    night => appL10n.stateIconNight,
    frost => appL10n.stateIconFrost,
    ink => appL10n.stateIconInk,
  };

  static AppIcon? byId(Object? id) {
    for (final icon in values) {
      if (icon.name == id) return icon;
    }
    return null;
  }
}

/// What the launcher shows, and the shape it cuts icons to.
class AppIconState {
  const AppIconState({required this.current, this.mask});

  final AppIcon current;

  /// The system's adaptive-icon mask as a closed outline, x and y in 0…1
  /// (`[x0, y0, x1, y1, …]`); null when unknown.
  final List<double>? mask;

  AppIconState copyWith({AppIcon? current}) => AppIconState(current: current ?? this.current, mask: mask);
}

/// The native side (`dsh/launcher_icon`).
class LauncherIconChannel {
  const LauncherIconChannel([this.channel = const MethodChannel('dsh/launcher_icon')]);

  final MethodChannel channel;

  /// Null when the platform has no launcher icons to switch (tests, other
  /// platforms) or the call failed.
  Future<AppIconState?> state() async {
    try {
      final raw = await channel.invokeMapMethod<String, Object?>('state');
      final current = AppIcon.byId(raw?['current']);
      if (current == null) return null;
      final mask = raw?['mask'];
      return AppIconState(
        current: current,
        mask: mask is List && mask.length >= 6 && mask.every((v) => v is num)
            ? List.unmodifiable([for (final v in mask) (v as num).toDouble()])
            : null,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Switches the launcher entry; the icon it shows now, or null if it
  /// didn't happen.
  Future<AppIcon?> set(AppIcon icon) async {
    try {
      final raw = await channel.invokeMapMethod<String, Object?>('set', {'id': icon.name});
      return AppIcon.byId(raw?['current']);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final launcherIconChannelProvider = Provider<LauncherIconChannel>((ref) => const LauncherIconChannel());

/// The launcher icon. [AppIconController.select] shows the pick at once and
/// settles on what the launcher really has.
final appIconProvider = AsyncNotifierProvider<AppIconController, AppIconState>(AppIconController.new);

class AppIconController extends AsyncNotifier<AppIconState> {
  /// Switches run one after another, in the order they were picked.
  Future<void> _queue = Future.value();

  @override
  Future<AppIconState> build() async =>
      await ref.read(launcherIconChannelProvider).state() ?? const AppIconState(current: AppIcon.mist);

  /// Makes [icon] the launcher icon. True when the launcher has it now.
  Future<bool> select(AppIcon icon) {
    if (state.value case final shown?) state = AsyncData(shown.copyWith(current: icon));
    final channel = ref.read(launcherIconChannelProvider);
    final done = Completer<bool>();
    _queue = _queue.then((_) async {
      var now = await channel.set(icon);
      // Didn't happen: show what the launcher really has.
      now ??= (await channel.state())?.current;
      if (ref.mounted && now != null) {
        // A later pick shows already; its own switch settles it.
        if (state.value case final shown? when shown.current == icon) {
          state = AsyncData(shown.copyWith(current: now));
        }
      }
      done.complete(now == icon);
    });
    return done.future;
  }
}
