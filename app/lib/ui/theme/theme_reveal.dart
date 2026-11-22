import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'motion.dart';

/// 换深浅色时从手指处揭开新配色(灵动档)。
///
/// 只在切换那一下拍一张整屏截图(GPU 纹理,不读回内存),之后每帧只画这张图加一个
/// 圆形裁切,结束就释放;平时只多一个 [RepaintBoundary]。
class ThemeRevealHost extends StatefulWidget {
  const ThemeRevealHost({super.key, required this.child});

  final Widget child;

  /// 揭开过程中:`MaterialApp` 不再交叉淡变配色,下面的新配色一步到位。
  static bool get active => _ThemeRevealHostState._active;

  static bool presentIn(BuildContext context) =>
      context.findAncestorStateOfType<_ThemeRevealHostState>() != null;

  /// 跑 [change](改主题的操作,要等它改完);灵动档且深浅真的变了时带揭开动画。
  static Future<void> run(BuildContext context, Future<void> Function() change) async {
    final host = context.findAncestorStateOfType<_ThemeRevealHostState>();
    if (host == null || !AppMotion.fluid(context)) {
      await change();
      return;
    }
    await host._reveal(change);
  }

  @override
  State<ThemeRevealHost> createState() => _ThemeRevealHostState();
}

class _ThemeRevealHostState extends State<ThemeRevealHost> with SingleTickerProviderStateMixin {
  static bool _active = false;
  static const _duration = Duration(milliseconds: 560);
  static const _curve = Cubic(0.4, 0, 0.2, 1);

  /// 改动之后最多等这么多帧看新配色出来:设置经 Riverpod 传到 `MaterialApp` 要隔帧,
  /// 不止一帧。按帧数算,不按时间:正是重建慢的时候才要多等。
  static const _maxWaitFrames = 8;

  final _boundary = GlobalKey();
  late final AnimationController _progress = AnimationController(vsync: this, duration: _duration);
  late final Animation<double> _hole = CurvedAnimation(parent: _progress, curve: _curve);

  ui.Image? _image;
  double _pixelRatio = 1;
  Offset? _lastDown;

  /// 最新一次切换。连着点时,旧的那次看到自己不是最新就不再收尾。
  int _run = 0;

  @override
  void dispose() {
    _active = false;
    _image?.dispose();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _reveal(Future<void> Function() change) async {
    final run = ++_run;
    final before = Theme.of(context).brightness;
    // 等当前这帧画完:截图要拿到按下之后的画面,而且渲染对象不能还脏着。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final ui.Image image;
    try {
      // 边界包着遮罩:上一次揭开到一半时再切换,截到的就是屏幕上的样子,不跳。
      image = (_boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImageSync(pixelRatio: ratio);
    } catch (_) {
      // 截不到图只是没有动画。
      await change();
      return;
    }
    final replaced = _image;
    _active = true;
    _pixelRatio = ratio;
    // 先归零:停在上一次的 1 上,遮罩就是全透明的,新配色会在动画开始前露出来闪一下。
    _progress.value = 0;
    setState(() => _image = image);
    WidgetsBinding.instance.addPostFrameCallback((_) => replaced?.dispose());
    try {
      await change();
    } catch (_) {
      // Nothing to reveal, and the screenshot must not stay over the app.
      if (mounted && run == _run) {
        _active = false;
        setState(() => _image = null);
        WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
      }
      rethrow;
    }
    // 新配色画出来之前,盖着的旧画面和屏幕上的一模一样。
    var frames = 0;
    while (mounted && run == _run && Theme.of(context).brightness == before && frames++ < _maxWaitFrames) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || run != _run) return;
    // 同样的深浅(浅色 → 跟随系统且系统是浅色)没什么可揭开的。
    if (Theme.of(context).brightness != before) {
      // 等新配色这一帧画完再走,重建再慢也不吞动画的开头。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || run != _run) return;
      try {
        await _progress.forward(from: 0).orCancel;
      } on TickerCanceled {
        // 又切换了一次,或者页面没了:都由下面判断。
      }
    }
    if (!mounted || run != _run) return;
    _active = false;
    setState(() => _image = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => _lastDown = event.position,
      child: RepaintBoundary(
        key: _boundary,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (image != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RevealPainter(image: image, pixelRatio: _pixelRatio, center: _lastDown, progress: _hole),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 画旧画面,挖掉一个越来越大的圆。
class _RevealPainter extends CustomPainter {
  _RevealPainter({required this.image, required this.pixelRatio, required this.center, required this.progress})
    : super(repaint: progress);

  final ui.Image image;
  final double pixelRatio;
  final Offset? center;
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final origin = center ?? rect.center;
    final reach = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ].map((corner) => (corner - origin).distance).reduce(math.max);
    final hole = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect)
      ..addOval(Rect.fromCircle(center: origin, radius: reach * progress.value));
    canvas
      ..save()
      ..clipPath(hole)
      ..scale(1 / pixelRatio)
      ..drawImage(image, Offset.zero, Paint())
      ..restore();
  }

  @override
  bool shouldRepaint(_RevealPainter old) => old.image != image || old.center != center;
}
