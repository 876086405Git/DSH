// The centrepiece of the first-run runtime setup screen: a 2.4 s breathing
// loop per direction (4.8 s round trip) that reads as "alive but quiet".

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/motion.dart';

/// 安静的进度光环:**细环 + 渐变弧 + 背后一团缓慢呼吸的光**。
///
/// 给首装解包(几百 MB、可能一两分钟)用:进度条会让人盯着数字焦虑,
/// 一个慢慢长满的环 + 每 2.4s 单向的呼吸(4.8s 一次完整来回),传达的是"在稳稳地进行"。
///
/// - [value] 为 null 时是不确定态(短弧缓慢旋转,1.6s 一圈);
/// - 数值变化用 480ms 缓动过渡,解包进度跳变时环不会"抽"一下;
/// - 系统要求减少动画时:不呼吸、不旋转,不确定态显示静止的 1/4 弧。
class ProgressHalo extends StatefulWidget {
  const ProgressHalo({super.key, this.value, this.size = 168, this.strokeWidth = 4, this.color, this.child});

  /// 0–1;null = 不确定。
  final double? value;
  final double size;
  final double strokeWidth;

  /// 默认 `colorScheme.primary`。
  final Color? color;

  /// 环中间的内容(百分比、图标、阶段名)。
  final Widget? child;

  @override
  State<ProgressHalo> createState() => _ProgressHaloState();
}

class _ProgressHaloState extends State<ProgressHalo> with TickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: AppMotion.breath);
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ProgressHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final reduced = AppMotion.reduced(context);
    if (reduced) {
      _breath
        ..stop()
        ..value = 0.5;
      _spin.stop();
      return;
    }
    if (!_breath.isAnimating) _breath.repeat(reverse: true);
    if (widget.value == null) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: l10n.botsProgress,
      value: widget.value == null ? null : '${(widget.value!.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox.square(
        dimension: widget.size,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: widget.value?.clamp(0.0, 1.0) ?? 0),
          duration: AppMotion.of(context, AppMotion.slow),
          curve: AppMotion.std,
          builder: (context, animatedValue, child) => AnimatedBuilder(
            animation: Listenable.merge([_breath, _spin]),
            builder: (context, _) => CustomPaint(
              painter: _HaloPainter(
                value: widget.value == null ? null : animatedValue,
                spin: _spin.value,
                breath: Curves.easeInOut.transform(_breath.value),
                color: color,
                glowAlpha: isDark ? 0.16 : 0.20,
                strokeWidth: widget.strokeWidth,
              ),
              child: child,
            ),
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({
    required this.value,
    required this.spin,
    required this.breath,
    required this.color,
    required this.glowAlpha,
    required this.strokeWidth,
  });

  final double? value;
  final double spin;
  final double breath;
  final Color color;
  final double glowAlpha;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2 - 8;

    // 背后的光:半径与透明度随呼吸缓慢起伏(±6% / ±40%)。
    final glowRadius = radius * (1.18 + 0.06 * breath);
    final glowRect = Rect.fromCircle(center: center, radius: glowRadius);
    canvas.drawCircle(
      center,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: glowAlpha * (0.6 + 0.4 * breath)),
            color.withValues(alpha: 0),
          ],
        ).createShader(glowRect),
    );

    final ring = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: 0.14),
    );

    final double start;
    final double sweep;
    if (value case final v?) {
      start = -math.pi / 2;
      sweep = 2 * math.pi * v;
    } else {
      start = -math.pi / 2 + 2 * math.pi * spin;
      sweep = math.pi / 2;
    }
    if (sweep <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        colors: [color.withValues(alpha: 0.35), color],
        stops: [0, (sweep / (2 * math.pi)).clamp(0.05, 1.0)],
        transform: GradientRotation(start),
      ).createShader(ring);
    canvas.drawArc(ring, start, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.value != value ||
      old.spin != spin ||
      old.breath != breath ||
      old.color != color ||
      old.glowAlpha != glowAlpha ||
      old.strokeWidth != strokeWidth;
}
