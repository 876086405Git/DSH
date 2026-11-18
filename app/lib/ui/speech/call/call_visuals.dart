// What 语音通话 draws, after Siri's light but quieter: a sphere of clear glass
// with soft colour drifting inside it, a fine rim of light, and the same colour
// running faintly round the edge of the screen. The colours come from the
// app's theme colour — a few neighbouring hues, pale and low in saturation — so
// a blue theme gives blue light and a green one green, never a rainbow. Light
// and dark follow the theme too. It breathes the whole time, and keeps time with
// whoever is speaking: it gathers in and swells with the person's syllables,
// throws its colour out with hers, breathes quick and shallow while it thinks,
// and goes grey and slow when muted. Every motion eases in and out.
// When the system asks for less motion the colours hold still and the sphere
// neither breathes nor grows in; only a voice still changes its size.
// One clock ([CallScene]) drives it all; the painters repaint from it.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../speech/call/voice_call.dart';

/// The call's colours, made from the theme.
@immutable
class CallPalette {
  const CallPalette._({required this.tones, required this.field, required this.light});

  /// Neighbouring hues around the theme colour, pale and soft.
  factory CallPalette.of(ColorScheme scheme, {required bool light}) {
    final base = HSLColor.fromColor(scheme.primary);
    final hue = base.hue;
    // A grey theme still gets a whisper of colour; a loud one is calmed down.
    final sat = (base.saturation * 0.62).clamp(0.28, 0.5);
    final l = light ? 0.7 : 0.74;
    Color tone(double shift, double s, double lightness) =>
        HSLColor.fromAHSL(1, (hue + shift) % 360, s.clamp(0.0, 1.0), lightness.clamp(0.0, 1.0)).toColor();
    return CallPalette._(
      tones: [
        tone(-34, sat * 0.9, l + 0.05),
        tone(-12, sat, l),
        tone(0, sat * 1.1, l - 0.05),
        tone(16, sat, l + 0.02),
        tone(38, sat * 0.85, l + 0.07),
      ],
      field: light ? tone(0, 0.28, 0.965) : tone(0, 0.3, 0.05),
      light: light,
    );
  }

  final List<Color> tones;
  final Color field;

  /// Drawn on a light field (frosted glass) rather than a dark one (clear glass).
  final bool light;

  Color get main => tones[2];

  @override
  bool operator ==(Object other) =>
      other is CallPalette && other.field == field && other.light == light && _same(other.tones, tones);

  static bool _same(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(field, light, Object.hashAll(tones));
}

/// The ink the call's words and keys are drawn in: light on a dark field (or a
/// picture, or her), dark on a light one.
@immutable
class CallInk extends InheritedWidget {
  const CallInk({super.key, required this.dark, required super.child});

  /// The field under the words is dark.
  final bool dark;

  Color get fg => dark ? Colors.white : const Color(0xFF14161F);
  Color get dim => fg.withValues(alpha: dark ? 0.72 : 0.66);
  Color get faint => fg.withValues(alpha: dark ? 0.5 : 0.46);
  Color get glass => dark ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.6);
  Color get glassBorder => dark ? Colors.white.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.06);

  /// A key that is on: filled with the ink itself, its glyph in the field's colour.
  Color get on => dark ? Colors.white.withValues(alpha: 0.94) : const Color(0xFF14161F).withValues(alpha: 0.88);
  Color get onGlyph => dark ? const Color(0xFF0B1020) : Colors.white;
  Color get warn => dark ? const Color(0xFFFF9AA8) : const Color(0xFFC6283E);

  static CallInk of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CallInk>() ?? const CallInk(dark: true, child: SizedBox());

  @override
  bool updateShouldNotify(CallInk old) => old.dark != dark;
}

/// The clock and the smoothed state the painters draw from. [tick] once a frame.
///
/// Three rhythms move the light:
/// - a breath under everything — in a little quicker than out, then a short
///   rest, never two quite alike: slow while it waits, quick and shallow while
///   it thinks, giving way to a voice when there is one;
/// - a voice's syllables ([level]) and its stresses ([accent]), the person's
///   while they speak and hers while she does;
/// - how much is being said ([energy]), which sets how fast the colours flow.
class CallScene extends ChangeNotifier {
  /// Seconds since the call page opened.
  double time = 0;

  /// Where the flow is: advances faster with a voice or while thinking, so a
  /// change of speed never makes the colours jump.
  double flow = 0;

  /// The voice now (the person's or hers), syllable by syllable: rises at once,
  /// falls away within a syllable.
  double level = 0;

  /// The voice over the last second or so: how much is being said, not each syllable.
  double energy = 0;

  /// A stressed syllable: how far the voice has just leapt above its run (0–1).
  double accent = 0;

  /// The breath, 0 (out) to 1 (in), and how deep it goes now (0–1).
  double breath = 0;
  double depth = 1;
  double _breathAt = 0;

  /// How much it is thinking, listening to the person, or speaking (0–1, eased).
  double think = 0;
  double hearing = 0;
  double speaking = 0;
  double muted = 0;

  /// 0 → 1 as the call opens, back to 0 as it ends.
  double appear = 0;

  /// The system asks for less motion: the colours stop flowing, the sphere
  /// neither breathes nor grows in. A voice still changes its size, so the
  /// person can see they are heard.
  bool still = false;

  void tick(
    double seconds, {
    required CallPhase phase,
    required double mic,
    required double voice,
    required bool isMuted,
    bool still = false,
  }) {
    final dt = (seconds - time).clamp(0.0, 0.1);
    time = seconds;
    this.still = still;
    final target = switch (phase) {
      CallPhase.hearing => mic,
      CallPhase.speaking => voice,
      _ => 0.0,
    }.clamp(0.0, 1.0);
    double ease(double from, double to, double rate) => from + (to - from) * (1 - math.exp(-rate * dt));
    level = ease(level, target, target > level ? 22 : 8);
    energy = ease(energy, target, 1.4);
    accent = ease(accent, ((level - energy - 0.1) * 2.4).clamp(0.0, 1.0), 16);
    think = ease(think, phase == CallPhase.thinking || phase == CallPhase.starting ? 1 : 0, 2.5);
    hearing = ease(hearing, phase == CallPhase.hearing ? 1 : 0, 3);
    speaking = ease(speaking, phase == CallPhase.speaking ? 1 : 0, 3);
    muted = ease(muted, isMuted && phase != CallPhase.speaking ? 1 : 0, 4);
    appear = ease(appear, phase == CallPhase.ended ? 0 : 1, phase == CallPhase.ended ? 5 : 2.4);
    if (!still) {
      // Slow while it waits, a little quicker with a voice, quick while it thinks;
      // a slow drift so no two breaths are quite alike.
      final period = (5.4 - think * 3.0 - hearing * 1.0 - speaking * 1.4).clamp(2.2, 6.0);
      final drift = 1 + 0.09 * math.sin(time * 0.21) + 0.05 * math.sin(time * 0.57 + 1.3);
      _breathAt = (_breathAt + dt / (period * drift)) % 1;
      flow += dt * (0.26 + think * 0.7 + energy * 0.7 + accent * 0.6 + (hearing + speaking) * 0.1) * (1 - muted * 0.7);
    }
    breath = _breathShape(_breathAt);
    depth = (1 - energy * 0.6) * (1 - think * 0.35) * (1 - muted * 0.5);
    notifyListeners();
  }

  /// How big the sphere is now, relative to its resting size: it breathes, and
  /// a voice's syllables swell it — hers a little more than the person's.
  double get scale {
    if (still) return 1 + level * 0.08;
    final breathing = (breath - 0.5) * 0.05 * depth;
    final voice = level * (0.04 + 0.04 * speaking) + accent * 0.04;
    return (0.86 + 0.14 * appear) * (1 + breathing + voice);
  }

  /// How much brighter than at rest the colour inside is now.
  double get glow => breath * (0.07 + think * 0.05) * depth + level * 0.14 + accent * 0.14 + think * 0.04;

  /// How far the colours sit from the middle, against the radius: out with each
  /// breath, gathered in while it listens, thrown out with her syllables.
  double get spread =>
      0.48 + (breath - 0.5) * 0.05 * depth + think * 0.04 - hearing * 0.05 + speaking * (level * 0.06 + accent * 0.06);
}

/// The breath [at] a point through one breath (0–1): in over the first 40%,
/// out over the next 48%, then resting.
double _breathShape(double at) {
  double s(double x) => 0.5 - 0.5 * math.cos(math.pi * x);
  if (at < 0.4) return s(at / 0.4);
  if (at < 0.88) return 1 - s((at - 0.4) / 0.48);
  return 0;
}

/// [c] drained toward grey by [amount] (muted).
Color _drain(Color c, double amount) {
  if (amount <= 0) return c;
  final l = c.r * 0.3 + c.g * 0.59 + c.b * 0.11;
  return Color.lerp(c, Color.from(alpha: c.a, red: l, green: l, blue: math.min(1, l * 1.04)), amount * 0.9)!;
}

/// A point on a slow, uneven loop: the phase itself wobbles, so the speed
/// along the path rises and falls instead of staying even.
Offset _wander(double t, double a, double b, double phase) {
  final u = t * a + phase + 0.7 * math.sin(t * b + phase * 1.7);
  final v = t * b * 0.83 + phase * 2.1 + 0.6 * math.sin(t * a * 1.3 + phase);
  return Offset(math.sin(u), math.cos(v));
}

/// The field, with a faint light of the theme's colour behind where the sphere sits.
class CallField extends StatelessWidget {
  const CallField({super.key, required this.scene, required this.palette, this.center = 0.4});

  final CallScene scene;
  final CallPalette palette;

  /// The sphere's height on the screen (0 top, 1 bottom).
  final double center;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _FieldPainter(scene, palette, center), child: const SizedBox.expand()),
  );
}

class _FieldPainter extends CustomPainter {
  _FieldPainter(this.scene, this.palette, this.center) : super(repaint: scene);

  final CallScene scene;
  final CallPalette palette;
  final double center;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.field);
    final at = Offset(size.width / 2, size.height * center);
    final radius = size.width * (0.9 + scene.energy * 0.1 + (scene.breath - 0.5) * 0.04 * scene.depth);
    final tint = _drain(palette.main, scene.muted);
    final strength = (palette.light ? 0.2 : 0.12) + scene.energy * 0.05 + scene.breath * 0.025 * scene.depth;
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            tint.withValues(alpha: strength * scene.appear),
            tint.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_FieldPainter old) => old.center != center || old.palette != palette;
}

/// The sphere of glass. Its resting diameter is [size] × 0.5; the rest is its glow.
class CallLight extends StatelessWidget {
  const CallLight({super.key, required this.scene, required this.palette, this.size = 300});

  final CallScene scene;
  final CallPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _GlassPainter(scene, palette)),
    ),
  );
}

class _GlassPainter extends CustomPainter {
  _GlassPainter(this.scene, this.palette) : super(repaint: scene);

  final CallScene scene;
  final CallPalette palette;

  // How each light inside wanders, and how big it is.
  static const _paths = [
    (0.9, 0.62, 0.0, 0.66),
    (0.71, 1.05, 1.3, 0.56),
    (1.13, 0.77, 2.6, 0.72),
    (0.83, 0.94, 3.9, 0.64),
    (1.27, 0.69, 5.1, 0.54),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide * 0.25 * scene.scale;
    if (r <= 0.5) return;
    final light = palette.light;
    final fade = scene.appear;
    final muted = scene.muted;
    final tones = [for (final t in palette.tones) _drain(t, muted)];
    final strength = ((light ? 0.58 : 0.5) + scene.glow * 0.6) * fade;
    final disc = Rect.fromCircle(center: center, radius: r);

    // Outside: a soft halo of the theme's colour.
    final halo = tones[2].withValues(alpha: ((light ? 0.28 : 0.18) + scene.glow * 0.45) * fade);
    // A disc of r·1.02 blurred by σ = r·0.45, drawn as that blur's own falloff
    // (full well inside, half at the edge, gone 2.5σ out): a mask blur that
    // wide, every frame, is what made the call page stutter.
    final outer = r * 2.145;
    canvas.drawCircle(
      center,
      outer,
      Paint()
        ..shader = RadialGradient(
          colors: [
            halo,
            halo.withValues(alpha: halo.a * 0.85),
            halo.withValues(alpha: halo.a * 0.5),
            halo.withValues(alpha: halo.a * 0.12),
            halo.withValues(alpha: 0),
          ],
          stops: const [0, 0.266, 0.476, 0.727, 1],
        ).createShader(Rect.fromCircle(center: center, radius: outer)),
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(disc));
    // The glass: barely there on a dark field, frosted on a light one.
    canvas.drawRect(disc, Paint()..color = Colors.white.withValues(alpha: (light ? 0.55 : 0.035) * fade));
    // The colour drifting inside, overlapping softly.
    canvas.saveLayer(disc, Paint());
    for (final (i, (a, b, phase, reach)) in _paths.indexed) {
      final at = center + _wander(scene.flow, a, b, phase) * r * scene.spread;
      final radius =
          r *
          reach *
          (1 +
              scene.level * 0.18 +
              scene.accent * 0.1 +
              (scene.breath - 0.5) * 0.06 * scene.depth +
              0.05 * math.sin(scene.flow * 1.7 + i));
      final tone = tones[i];
      canvas.drawCircle(
        at,
        radius,
        Paint()
          ..blendMode = light ? BlendMode.srcOver : BlendMode.screen
          ..shader = RadialGradient(
            colors: [
              tone.withValues(alpha: strength),
              tone.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: at, radius: radius)),
      );
    }
    canvas.restore();
    // Clear glass is brighter at its edge, where it bends the light…
    canvas.drawRect(
      disc,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.transparent,
            Colors.transparent,
            Colors.white.withValues(alpha: (light ? 0.3 : 0.12) * fade),
          ],
          stops: const [0, 0.78, 1],
        ).createShader(disc),
    );
    // …and holds a faint crescent of light just inside its top.
    canvas.drawRect(
      disc,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -1.05),
          radius: 0.6,
          colors: [
            Colors.white.withValues(alpha: (light ? 0.42 : 0.16) * fade),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(disc),
    );
    canvas.restore();

    // The rim: a fine line of light, the theme's hues turning slowly round it.
    canvas.drawCircle(
      center,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = SweepGradient(
          colors: [
            for (final t in [...tones, tones.first]) Color.lerp(t, Colors.white, light ? 0.2 : 0.45)!,
          ],
          transform: GradientRotation(scene.flow * 0.7),
        ).createShader(disc)
        ..color = Colors.white.withValues(alpha: (light ? 0.9 : 0.6) * fade),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) => old.palette != palette;
}

/// The theme's colour running faintly round the edge of the screen, as Siri's:
/// barely there while the call waits, a little stronger with a voice.
class CallEdgeGlow extends StatelessWidget {
  const CallEdgeGlow({super.key, required this.scene, required this.palette, this.radius = 44});

  final CallScene scene;
  final CallPalette palette;

  /// Follows the screen's corners.
  final double radius;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(painter: _EdgePainter(scene, palette, radius), child: const SizedBox.expand()),
    ),
  );
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.scene, this.palette, this.radius) : super(repaint: scene);

  final CallScene scene;
  final CallPalette palette;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final strength =
        (0.05 +
            scene.breath * 0.02 * scene.depth +
            (scene.hearing + scene.speaking).clamp(0.0, 1.0) * 0.08 +
            scene.energy * 0.16 +
            scene.accent * 0.18) *
        scene.appear *
        (1 - scene.muted * 0.85);
    if (strength < 0.01) return;
    final frame = RRect.fromRectAndRadius((Offset.zero & size).deflate(1), Radius.circular(radius));
    final shader = SweepGradient(
      colors: [...palette.tones, palette.tones.first],
      transform: GradientRotation(scene.flow * 0.5),
    ).createShader(Offset.zero & size);
    final width = 10 + scene.energy * 6 + scene.accent * 5;
    final alpha = strength.clamp(0.0, 1.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..shader = shader;
    // A 16 blur round the whole screen every frame cost too much: eight nested
    // strokes instead, each 6 wider on either side and carrying the Gaussian's
    // share between its edge and the next one's.
    double falloff(double d) => math.exp(-d * d / (2 * 16 * 16));
    final peak = alpha * math.min(1.0, width / 40);
    for (var k = 0; k < 8; k++) {
      canvas.drawRRect(
        frame,
        paint
          ..strokeWidth = width + 12.0 * k
          ..color = Colors.white.withValues(alpha: peak * (falloff(6.0 * k) - falloff(6.0 * k + 6))),
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.radius != radius || old.palette != palette;
}

/// Drives a [CallScene] from a ticker for as long as it is mounted.
class CallClock extends StatefulWidget {
  const CallClock({super.key, required this.onTick, required this.child});

  final void Function(double seconds) onTick;
  final Widget child;

  @override
  State<CallClock> createState() => _CallClockState();
}

class _CallClockState extends State<CallClock> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  double? _last;

  void _tick(Duration elapsed) {
    final now = elapsed.inMicroseconds / 1e6;
    // At most 60 a second, as the voice ring keeps: a 120 Hz screen would
    // otherwise repaint the whole page twice as often for no visible gain.
    if (_last != null && now - _last! < 1 / 62) return;
    _last = now;
    widget.onTick(now);
  }

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
