// 背景图逐帧解码：一路解码器，动图按帧时长循环取下一帧，任何时候只留当前这一帧。画它的人
// （lib/ui/theme/backdrop.dart 的 painter）把它当重绘信号：换帧只重绘，不重建。静图（主题包
// 的背景图）也走这里：解出唯一一帧就收工。
//
// 静图按屏幕需要的尺寸解码。动图不行：引擎解动图时不理会目标尺寸，每帧都是原始大小，所以
// 太大的动图不播放，只用第一帧（FrameSource.maxSide）。
//
// 同一张图、同一个尺寸全 App 共用一路（pictureFramesProvider）：没人看就停下、释放；App 退到
// 后台暂停，回来接着放。只是失去焦点（分屏时点了另一边、拉下通知栏）还看得见，不停。第一帧
// 不管暂停与否都解：静图只有这一帧。

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A picture file and how large its frames are decoded.
@immutable
class FrameSource {
  const FrameSource({
    required this.path,
    required this.coverWidth,
    required this.coverHeight,
    this.maxSide = 2048,
    this.loop = true,
    this.revision = 0,
  });

  final String path;

  /// The pixels a still has to cover: it is decoded no larger than that takes, and never larger
  /// than the file.
  final int coverWidth;
  final int coverHeight;

  /// A still's long side at most. An animation's frames come at their own size whatever is
  /// asked, so one longer than this shows its first frame only.
  final int maxSide;

  /// An animation plays. False: its first frame only.
  final bool loop;

  /// Changes when the file at [path] does.
  final int revision;

  /// The size a [width] × [height] picture is decoded at.
  ui.TargetImageSize target(int width, int height) {
    final cover = math.max(coverWidth / width, coverHeight / height);
    final scale = math.min(1.0, math.min(cover, maxSide / math.max(width, height)));
    return ui.TargetImageSize(
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FrameSource &&
      other.path == path &&
      other.coverWidth == coverWidth &&
      other.coverHeight == coverHeight &&
      other.maxSide == maxSide &&
      other.loop == loop &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(path, coverWidth, coverHeight, maxSide, loop, revision);
}

/// One picture's frames, one at a time: [value] is the frame to draw now (null until the first
/// is decoded, and when the picture can't be read). It owns the frame; whoever draws it reads
/// [value] as it paints and keeps nothing.
class FrameLoop extends ChangeNotifier implements ValueListenable<ui.Image?> {
  FrameLoop(this._open, {this.loop = true, this.maxSide}) {
    unawaited(_advance());
  }

  final Future<ui.Codec> Function() _open;

  /// An animation plays. False: its first frame only.
  final bool loop;

  /// An animation with frames longer than this on a side doesn't play either.
  final int? maxSide;

  /// 30 frames a second at most.
  static const minInterval = Duration(milliseconds: 33);

  /// A frame that says 0 (GIFs do) stays this long.
  static const unsetInterval = Duration(milliseconds: 100);

  /// How long a frame of [duration] stays up.
  static Duration intervalFor(Duration duration) {
    if (duration <= Duration.zero) return unsetInterval;
    return duration < minInterval ? minInterval : duration;
  }

  ui.Image? _frame;
  ui.Codec? _codec;
  Timer? _timer;
  bool _playing = false;
  bool _decoding = false;
  bool _done = false;
  bool _disposed = false;

  @override
  ui.Image? get value => _frame;

  /// No other frame is coming: a still, or an animation that doesn't play, with its frame up;
  /// or a picture that can't be read ([value] stays null).
  bool get settled => _done;

  /// Decoding the next frame when the current one's time is up. Off: the frame up stays (the
  /// first one is decoded all the same: a still is nothing else).
  bool get playing => _playing;
  set playing(bool value) {
    if (_disposed || value == _playing) return;
    _playing = value;
    if (value) {
      unawaited(_advance());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _advance() async {
    _timer = null;
    if (_decoding || _done || _disposed || (_frame != null && !_playing)) return;
    _decoding = true;
    final clock = Stopwatch()..start();
    try {
      final codec = _codec ??= await _open();
      final next = await codec.getNextFrame();
      if (_disposed) {
        next.image.dispose();
        return;
      }
      final last = _frame;
      _frame = next.image;
      final side = math.max(next.image.width, next.image.height);
      _done = !loop || codec.frameCount < 2 || (maxSide != null && side > maxSide!);
      notifyListeners();
      // What was drawn with it keeps the pixels alive; the handle goes now.
      last?.dispose();
      if (!_done && _playing) {
        // The decode's own time comes off the wait, so a slow decoder doesn't slow the picture.
        final wait = intervalFor(next.duration) - clock.elapsed;
        _timer = Timer(wait.isNegative ? Duration.zero : wait, () => unawaited(_advance()));
      }
    } catch (error) {
      debugPrint('frames: unreadable: $error');
      _done = true;
      // Whoever waits for a frame learns that none is coming.
      if (!_disposed) notifyListeners();
    } finally {
      _decoding = false;
      if (_done || _disposed) {
        _codec?.dispose();
        _codec = null;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    // A decode in flight lets go of the codec itself.
    if (!_decoding) {
      _codec?.dispose();
      _codec = null;
    }
    _frame?.dispose();
    _frame = null;
    super.dispose();
  }
}

/// [source]'s file, opened at its decode size.
Future<ui.Codec> openFrames(FrameSource source) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
  return ui.instantiateImageCodecWithSize(buffer, getTargetSize: source.target);
}

/// The frames of a [FrameSource]: one decoder for everything that shows it, let go when nothing
/// does, paused while the app is in the background.
final pictureFramesProvider = Provider.autoDispose.family<FrameLoop, FrameSource>((ref, source) {
  final frames = FrameLoop(() => openFrames(source), loop: source.loop, maxSide: source.maxSide);
  final lifecycle = AppLifecycleListener(onStateChange: (state) => frames.playing = _onScreen(state));
  ref.onDispose(() {
    lifecycle.dispose();
    frames.dispose();
  });
  frames.playing = _onScreen(WidgetsBinding.instance.lifecycleState);
  return frames;
});

/// Inactive is still on screen: the other half of a split screen has the focus, or the
/// notification shade is down.
bool _onScreen(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
