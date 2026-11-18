import 'dart:io' show Platform;

import 'package:flutter/services.dart' show BinaryMessenger;
import 'package:flutter/widgets.dart';

import '../../clipboard/paste_button_messenger.dart';

/// 动画时钟防跳帧。
///
/// 动画按墙上时钟走:一帧卡了 150ms(新页面第一次排版、着色器编译),下一帧动画就
/// 直接跳到半路,开头那段全被吞掉,看起来就是「一顿」。这里让时钟每帧最多走
/// [maxStep]:卡顿之后动画从卡住的地方接着走,只是晚一点到,不再跳。
///
/// 对全 App 的动画都生效,本身几乎没有开销。持续低于 30 帧时动画会变慢一些,而不是
/// 掉帧跳着走。[maxStep] 是绝对时长,不按屏幕刷新率算:120Hz 屏跑在 60 帧时不会变慢。
///
/// 只改动画看到的时间:`Timer`、`DateTime`、指针事件的时间都不受影响。
class FrameClock {
  FrameClock({this.maxStep = const Duration(milliseconds: 34)});

  /// [SteadyFrameBinding] 用的那一个;`lib/app.dart` 按灵动动效开关设置 [enabled]。
  static final instance = FrameClock();

  final Duration maxStep;

  /// 关掉后不再累计新的跳过量;已经跳过的继续扣掉,时间不会往回或往前突变。
  bool enabled = false;

  Duration? _last;
  Duration _skipped = Duration.zero;

  /// 一帧的原始时间戳换算成动画看到的时间戳。
  Duration adjust(Duration raw) {
    final last = _last;
    _last = raw;
    if (enabled && last != null) {
      final step = raw - last;
      if (step > maxStep) _skipped += step - maxStep;
    }
    return raw - _skipped;
  }

  @visibleForTesting
  void reset() {
    _last = null;
    _skipped = Duration.zero;
    enabled = false;
  }
}

/// 把 [FrameClock] 接进帧调度。要在其他任何 binding 之前创建,而且只能建一次。
class SteadyFrameBinding extends WidgetsFlutterBinding {
  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    super.handleBeginFrame(rawTimeStamp == null ? null : FrameClock.instance.adjust(rawTimeStamp));
  }

  @override
  BinaryMessenger createBinaryMessenger() =>
      clipboardMessengerFor(Platform.operatingSystem, super.createBinaryMessenger());
}
