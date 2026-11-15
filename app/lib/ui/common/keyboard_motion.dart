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

  double get _bottom => _from + (_to! - _from) * Curves.easeOutCubic.transform(_motion.value);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final target = MediaQuery.viewInsetsOf(context).bottom;
    if (target == _to) return;
    if (_to == null || MediaQuery.disableAnimationsOf(context)) {
      _to = _from = target;
      _motion.value = 1;
    } else {
      _from = _bottom;
      _to = target;
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
