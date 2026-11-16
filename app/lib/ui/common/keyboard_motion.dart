// Keyboard insets that move.
//
// Android reports the keyboard's height on every frame of its animation, so
// the composer rides up with it. HarmonyOS reports only the final height, which
// would make everything above the keyboard jump. This eases between reports.

import 'dart:math' as math;

import 'package:flutter/material.dart';

class EasedKeyboardInset extends StatefulWidget {
  const EasedKeyboardInset({super.key, required this.child});

  final Widget child;

  @override
  State<EasedKeyboardInset> createState() => _EasedKeyboardInsetState();
}

class _EasedKeyboardInsetState extends State<EasedKeyboardInset> with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(vsync: this, duration: const Duration(milliseconds: 250), value: 1);
  double? _to;
  double _from = 0;

  /// After a change of mind, how fast it leaves [_from], in inset per run of [_motion]:
  /// the speed it already had, within three times the distance so that it can't pass a
  /// nearer target or go far the old way. Null is an uninterrupted run.
  double? _leaving;

  double get _bottom => _at(_motion.value);

  double _at(double t) {
    final change = _to! - _from;
    final leaving = _leaving;
    if (leaving == null) return _from + change * Curves.easeOutCubic.transform(t);
    if (t >= 1) return _to!;
    return math.max(0, _from + t * (leaving + t * (3 * change - 2 * leaving + t * (leaving - 2 * change))));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final target = MediaQuery.viewInsetsOf(context).bottom;
    if (target == _to) return;
    if (_to == null || MediaQuery.disableAnimationsOf(context)) {
      _to = _from = target;
      _leaving = null;
      _motion.value = 1;
    } else {
      final t = _motion.value;
      final step = math.min(0.01, 1 - t);
      final speed = _motion.isAnimating ? (_at(t + step) - _at(t)) / step : null;
      _from = _bottom;
      _to = target;
      final limit = 3 * (target - _from).abs();
      _leaving = speed?.clamp(-limit, limit);
      _motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: _motion,
      child: widget.child,
      builder: (context, child) {
        final bottom = _bottom;
        return MediaQuery(
          data: media.copyWith(
            viewInsets: media.viewInsets.copyWith(bottom: bottom),
            padding: media.padding.copyWith(bottom: math.max(0, media.viewPadding.bottom - bottom)),
          ),
          child: child!,
        );
      },
    );
  }
}
