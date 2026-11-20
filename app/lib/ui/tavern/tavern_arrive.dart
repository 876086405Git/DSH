// Things that turn up in the story's chrome after the page is open — the
// director's suggestions in the capsule row, a state value's 「+5」 — fade in
// and rise a little as they come, siblings 30ms apart (docs/design/
// roleplay-ui.md §11). FadeSlideIn only plays in a list's first moments; these
// come later, whenever the engine has them.

import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// [child] arriving: faded in and risen [offset] over [duration],
/// [index] × [AppMotion.stagger] after its first build (only the first
/// [AppMotion.staggerLimit] wait). Plays once per element, decided when it is
/// first built: key it by what it shows to play again for something new, and
/// pass [enabled] false for one that was already there. Reduced motion shows
/// it at once.
///
/// Only opacity and a translation move; the child is painted once, under its
/// own repaint boundary, not again each frame.
class TavernArrive extends StatefulWidget {
  const TavernArrive({
    super.key,
    required this.child,
    this.index = 0,
    this.enabled = true,
    this.duration = AppMotion.standard,
    this.curve = AppMotion.enter,
    this.offset = AppMotion.rise,
  });

  final Widget child;
  final int index;

  /// Read on the first build only: later builds change nothing.
  final bool enabled;
  final Duration duration;
  final Curve curve;

  /// How far it rises, in logical pixels; 0 only fades.
  final double offset;

  @override
  State<TavernArrive> createState() => _TavernArriveState();
}

/// A tab's content in place of another's (`FadeTransition` /
/// `SliverFadeTransition` on [opacity]): at [play] the new one fades in over
/// [AppMotion.quick]; the one it replaced goes at once, so the two never
/// stand over each other or are built side by side.
final class TavernSwapFade {
  TavernSwapFade(TickerProvider vsync)
    : _controller = AnimationController(vsync: vsync, duration: AppMotion.quick, value: 1);

  final AnimationController _controller;
  late final Animation<double> opacity = CurvedAnimation(parent: _controller, curve: AppMotion.std);

  void play(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.quick);
    if (duration == Duration.zero) {
      _controller.value = 1;
      return;
    }
    _controller
      ..duration = duration
      ..forward(from: 0);
  }

  void dispose() => _controller.dispose();
}

class _TavernArriveState extends State<TavernArrive> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _shown;
  bool _decided = false;

  /// The rise as decided on the first build.
  double _offset = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!widget.enabled || AppMotion.reduced(context)) return;
    final lead = AppMotion.stagger * widget.index.clamp(0, AppMotion.staggerLimit);
    final total = lead + widget.duration;
    final controller = AnimationController(vsync: this, duration: total)..forward();
    _controller = controller;
    _offset = widget.offset;
    _shown = CurvedAnimation(
      parent: controller,
      curve: Interval(lead.inMicroseconds / total.inMicroseconds, 1, curve: widget.curve),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return widget.child;
    final still = RepaintBoundary(child: widget.child);
    return FadeTransition(
      opacity: shown,
      child: _offset == 0
          ? still
          : AnimatedBuilder(
              animation: shown,
              builder: (context, child) =>
                  Transform.translate(offset: Offset(0, (1 - shown.value) * _offset), child: child),
              child: still,
            ),
    );
  }
}
