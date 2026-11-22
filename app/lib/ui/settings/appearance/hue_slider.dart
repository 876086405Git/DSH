// The hue track of the custom accent, shared with the Theme Studio's colour pickers.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/theme.dart';

/// The hue wheel and the hue track: guarded colours every 15°, per brightness.
List<Color> hueWheelColors(Brightness brightness) => _wheels[brightness] ??= [
  for (var h = 0; h <= 360; h += 15) AppAccent.guardedSeed(AppAccent.hueColor(h % 360.0), brightness),
];

final _wheels = <Brightness, List<Color>>{};

/// 色相条:一条守卫后的色相渐变,一颗圆钮(里面是当前色)。拖动时圆钮
/// 跟手,主题每 ~100ms 跟一次,松手落定。
class HueSlider extends StatefulWidget {
  const HueSlider({super.key, required this.hue, required this.brightness, required this.onChanged});

  final double hue;
  final Brightness brightness;
  final ValueChanged<double> onChanged;

  static const height = 36.0;
  static const track = 12.0;
  static const knob = 26.0;

  @override
  State<HueSlider> createState() => _HueSliderState();
}

class _HueSliderState extends State<HueSlider> {
  double? _dragging;
  double _lastDx = 0;
  DateTime _sent = DateTime(0);

  double get _hue => _dragging ?? widget.hue;

  double _hueAt(double dx, double width) {
    const pad = HueSlider.knob / 2;
    return ((dx - pad) / (width - 2 * pad)).clamp(0.0, 1.0) * 360;
  }

  void _drag(double dx, double width, {bool end = false}) {
    final hue = _hueAt(dx, width);
    setState(() => _dragging = end ? null : hue);
    final now = DateTime.now();
    if (end || now.difference(_sent) > const Duration(milliseconds: 100)) {
      _sent = now;
      widget.onChanged(hue);
    }
  }

  void _step(double by) => widget.onChanged((widget.hue + by) % 360);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hue = _hue;
    final colors = hueWheelColors(widget.brightness);
    final current = AppAccent.guardedSeed(AppAccent.hueColor(hue % 360), widget.brightness);
    return Semantics(
      slider: true,
      label: l10n.pluginsHue,
      value: '${hue.round()}°',
      increasedValue: '${((hue + 15) % 360).round()}°',
      decreasedValue: '${((hue - 15) % 360).round()}°',
      onIncrease: () => _step(15),
      onDecrease: () => _step(-15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _drag(d.localPosition.dx, width, end: true),
            onHorizontalDragStart: (d) => _drag(_lastDx = d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _drag(_lastDx = d.localPosition.dx, width),
            onHorizontalDragEnd: (_) => _drag(_lastDx, width, end: true),
            child: SizedBox(
              height: HueSlider.height,
              width: width,
              child: CustomPaint(
                painter: _HuePainter(
                  colors: colors,
                  hue: hue,
                  current: current,
                  knob: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.white,
                  shadow: Theme.of(context).colorScheme.shadow,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter({
    required this.colors,
    required this.hue,
    required this.current,
    required this.knob,
    required this.shadow,
  });

  final List<Color> colors;
  final double hue;
  final Color current;
  final Color knob;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = HueSlider.knob / 2;
    final track = Rect.fromLTWH(
      pad - HueSlider.track / 2,
      (size.height - HueSlider.track) / 2,
      size.width - 2 * pad + HueSlider.track,
      HueSlider.track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, const Radius.circular(99)),
      Paint()..shader = LinearGradient(colors: colors).createShader(track),
    );
    final x = pad + (hue / 360).clamp(0.0, 1.0) * (size.width - 2 * pad);
    final c = Offset(x, size.height / 2);
    canvas.drawCircle(
      c.translate(0, 1),
      HueSlider.knob / 2,
      Paint()
        ..color = shadow.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(c, HueSlider.knob / 2, Paint()..color = knob);
    canvas.drawCircle(c, HueSlider.knob / 2 - 4, Paint()..color = current);
  }

  @override
  bool shouldRepaint(_HuePainter old) =>
      old.hue != hue || old.current != current || old.knob != knob || old.colors != colors || old.shadow != shadow;
}
