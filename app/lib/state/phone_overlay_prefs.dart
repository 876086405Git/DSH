import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_state.dart';

/// 设置 → 手机操控 → 悬浮条: 闲置时不透明度, 闲置时自动收起 and 屏幕边缘光效, kept on the
/// native side (the overlay reads them there, live). The page shows a change at
/// once and sends it on; without the native side the change stays for this run.
class PhoneOverlayPrefsController extends Notifier<PhoneOverlayPrefs> {
  late Future<void> _loaded;

  PhoneChannel get _channel => ref.read(phoneChannelProvider);

  @override
  PhoneOverlayPrefs build() {
    _loaded = _load();
    return const PhoneOverlayPrefs();
  }

  Future<void> _load() async {
    final stored = await _channel.overlayPrefs();
    if (stored != null && ref.mounted) state = stored;
  }

  /// [opacity] 0.3–1; every slider step goes through, so a showing pill follows the thumb.
  Future<void> setIdleOpacity(double opacity) async {
    await _loaded;
    if (!ref.mounted) return;
    final next = state.copyWith(idleOpacity: opacity);
    if (next == state) return;
    state = next;
    await _channel.setOverlayPrefs(idleOpacity: next.idleOpacity);
  }

  Future<void> setAutoCollapse(bool on) async {
    await _loaded;
    if (!ref.mounted || state.autoCollapse == on) return;
    state = state.copyWith(autoCollapse: on);
    await _channel.setOverlayPrefs(autoCollapse: on);
  }

  Future<void> setEdgeGlow(bool on) async {
    await _loaded;
    if (!ref.mounted || state.edgeGlow == on) return;
    state = state.copyWith(edgeGlow: on);
    await _channel.setOverlayPrefs(edgeGlow: on);
  }
}

final phoneOverlayPrefsProvider = NotifierProvider<PhoneOverlayPrefsController, PhoneOverlayPrefs>(
  PhoneOverlayPrefsController.new,
);
