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
///
/// HarmonyOS has no such switch, but its Flutter engine votes its own rate: 120 under a
/// finger, 60 from 3 s after, and only scrolls and routes vote in between, so springs, sheets
/// and streaming output run at what that leaves. There active asks the engine for 120, which
/// is a real cost rather than a preference, so it follows motion and not any frame: several
/// frames in a row at animation cadence. A blinking cursor, two frames a second, doesn't
/// start it or hold it up. The price is about [motionFrames] frames at the old rate at the
/// start of a motion that no finger began.
class RefreshRateService {
  RefreshRateService._();

  static final RefreshRateService instance = RefreshRateService._();

  /// The channel MainActivity already serves for the app.
  @visibleForTesting
  static MethodChannel channel = const MethodChannel('dsh/app');

  /// The OS by Dart's name for it, so a test can be on another one.
  @visibleForTesting
  static String operatingSystem = Platform.operatingSystem;

  /// How long after the last frame the preference is released.
  static const idleAfter = Duration(milliseconds: 700);

  /// HarmonyOS: frames this close together are animating. 20 fps, so a panel the system
  /// has lowered to 30 Hz still counts, and a cursor's half-second blink never does.
  static const motionGap = Duration(milliseconds: 50);

  /// HarmonyOS: this many such gaps in a row are motion.
  static const motionFrames = 3;

  /// HarmonyOS: how often motion says so again. The native side stops by itself without it,
  /// so a UI thread that stops answering can't leave 120 running.
  static const renewEvery = Duration(seconds: 1);

  RefreshRateMode _mode = RefreshRateMode.auto;
  bool _active = false;
  bool _started = false;
  Timer? _idle;

  /// The frame [_idle] was set from, and the latest one held since: one timer per
  /// idle stretch, which on firing waits out whatever is left.
  Duration _idleFrom = Duration.zero;
  Duration _heldAt = Duration.zero;
  Duration _lastFrame = Duration.zero;
  Duration _renewedAt = Duration.zero;
  int _motionRun = 0;

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

  static bool get _motionOnly => operatingSystem == 'ohos';

  /// iOS paces frames itself (ProMotion); nothing to ask for.
  static bool get _systemDecides => operatingSystem == 'ios';

  /// Called by the settings row and by the stored preference after launch.
  Future<void> setMode(RefreshRateMode mode) async {
    if (_mode == mode || _systemDecides) return;
    _mode = mode;
    _idle?.cancel();
    _idle = null;
    if (mode != RefreshRateMode.auto) _active = false;
    _sendMode();
  }

  void _onFrame(Duration timeStamp) {
    if (_mode != RefreshRateMode.auto) return;
    if (_motionOnly) return _onMotionFrame(timeStamp);
    _hold(timeStamp);
    if (_active) return;
    _active = true;
    _sendActive(true);
  }

  void _onMotionFrame(Duration timeStamp) {
    _motionRun = timeStamp - _lastFrame <= motionGap ? _motionRun + 1 : 0;
    _lastFrame = timeStamp;
    if (_motionRun < motionFrames) return;
    _hold(timeStamp);
    if (_active && timeStamp - _renewedAt < renewEvery) return;
    _active = true;
    _renewedAt = timeStamp;
    _sendActive(true);
  }

  /// Releases [idleAfter] after the frame at [timeStamp], unless a later one is held.
  void _hold(Duration timeStamp) {
    _heldAt = timeStamp;
    if (_idle != null) return;
    _idleFrom = timeStamp;
    _idle = Timer(idleAfter, _idleCheck);
  }

  void _idleCheck() {
    final later = _heldAt - _idleFrom;
    if (later > Duration.zero) {
      _idleFrom = _heldAt;
      _idle = Timer(later, _idleCheck);
      return;
    }
    _idle = null;
    _release();
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

  /// Test seam: a frame, since tests don't register the listener.
  @visibleForTesting
  void frameForTest(Duration timeStamp) => _onFrame(timeStamp);

  /// Test seam: forget the listener, the timer and the current mode.
  @visibleForTesting
  void resetForTest() {
    _idle?.cancel();
    _idle = null;
    _mode = RefreshRateMode.auto;
    _active = false;
    _started = false;
    _lastFrame = Duration.zero;
    _renewedAt = Duration.zero;
    _motionRun = 0;
  }
}
