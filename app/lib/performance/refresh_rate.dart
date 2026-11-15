import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'performance_policy.dart';

/// Tells the platform when the app wants the screen's fastest refresh rate.
///
/// [RefreshRateMode.auto]: while Flutter is producing frames (animations, scrolling,
/// streaming output) the window asks for the fastest mode at its resolution; after
/// [idleAfter] without a frame it drops the preference and the system decides again.
/// [RefreshRateMode.max] keeps it pinned; [RefreshRateMode.system] never declares one.
///
/// Some ROMs (HyperOS, OriginOS, ColorOS) cap third-party apps at 60 Hz unless the app
/// asks, and once it does they show the per-app refresh-rate switch as an in-app setting
/// — so the app has to offer the choice itself, including handing the decision back.
/// HarmonyOS has no such cap to ask past, so there this does nothing.
class RefreshRateService {
  RefreshRateService._();

  static final RefreshRateService instance = RefreshRateService._();

  /// The channel MainActivity already serves for the app.
  @visibleForTesting
  static MethodChannel channel = const MethodChannel('dsh/app');

  /// How long after the last frame the preference is released.
  static const idleAfter = Duration(milliseconds: 700);

  RefreshRateMode _mode = RefreshRateMode.auto;
  bool _active = false;
  bool _started = false;
  Timer? _idle;

  RefreshRateMode get mode => _mode;

  /// Registers the frame listener and sends the initial mode. Safe to call twice.
  void start() {
    if (_started || _systemDecides) return;
    _started = true;
    // Widget tests have no platform side and must not leave timers behind; the mode is
    // still sent so a test can assert the channel traffic.
    if (!_testing) WidgetsBinding.instance.addPersistentFrameCallback(_onFrame);
    _sendMode();
  }

  static bool get _testing => Platform.environment.containsKey('FLUTTER_TEST');

  static bool get _systemDecides => Platform.operatingSystem == 'ohos' || Platform.isIOS;

  /// Called by the settings row and by the stored preference after launch.
  Future<void> setMode(RefreshRateMode mode) async {
    if (_mode == mode || _systemDecides) return;
    _mode = mode;
    _idle?.cancel();
    if (mode != RefreshRateMode.auto) _active = false;
    _sendMode();
  }

  void _onFrame(Duration _) {
    if (_mode != RefreshRateMode.auto) return;
    _idle?.cancel();
    _idle = Timer(idleAfter, _release);
    if (_active) return;
    _active = true;
    _sendActive(true);
  }

  void _release() {
    if (!_active) return;
    _active = false;
    _sendActive(false);
  }

  void _sendMode() => _send('setRefreshRateMode', {'mode': _mode.name});

  void _sendActive(bool active) => _send('setFrameActive', {'active': active});

  void _send(String method, Map<String, Object?> arguments) {
    unawaited(channel.invokeMethod<void>(method, arguments).catchError((Object _) {}));
  }

  /// Test seam: forget the listener, the timer and the current mode.
  @visibleForTesting
  void resetForTest() {
    _idle?.cancel();
    _idle = null;
    _mode = RefreshRateMode.auto;
    _active = false;
    _started = false;
  }
}
