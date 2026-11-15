// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The luminous painter (light.ts): a frame's rings drawn as coloured light.
// One conic gradient carries the spectrum round the ring, so every pass —
// halo, bloom, fringe, core, highlight — is a handful of path strokes. The
// halo and bloom are stacks of wide, faint strokes on a layer of their own,
// laid down through a blur; on a dark substrate everything adds (plus), so
// overlaps run hot toward white like light does. On paper it reads as deeper
// ink instead: plain source-over, no fringes, no highlight.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'frame.dart';
import 'voice.dart';

// The chromatic fringes either side of each ring: a cool teal just outside,
// a deep blue just inside — the split a lens gives bright light.
const Rgb _fringeOut = Rgb(120, 232, 214);
const Rgb _fringeIn = Rgb(64, 72, 255);

/// HSL, every channel 0–1.
(double, double, double) toHsl(double r, double g, double b) {
  r /= 255;
  g /= 255;
  b /= 255;
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  if (mx == mn) return (0, 0, l);
  final d = mx - mn;
  final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  final double h;
  if (mx == r) {
    h = (g - b) / d + (g < b ? 6 : 0);
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  return (h / 6, s, l);
}

(double, double, double) fromHsl(double h, double s, double l) {
  double k(double n) => (n + h * 12) % 12;
  final a = s * math.min(l, 1 - l);
  double f(double n) => l - a * math.max(-1, math.min(k(n) - 3, math.min(9 - k(n), 1)));
  return (f(0) * 255, f(8) * 255, f(4) * 255);
}

// OKLab, where a straight line between two colours looks like an even blend
double _lin(double c) {
  c /= 255;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _gam(double c) =>
    255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(math.max(0, c), 1 / 2.4).toDouble() - 0.055);

double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

(double, double, double) toLab(double r, double g, double b) {
  final rr = _lin(r);
  final gg = _lin(g);
  final bb = _lin(b);
  final l = _cbrt(0.4122214708 * rr + 0.5363325363 * gg + 0.0514459929 * bb);
  final m = _cbrt(0.2119034982 * rr + 0.6806995451 * gg + 0.1073969566 * bb);
  final s = _cbrt(0.0883024619 * rr + 0.2817188376 * gg + 0.6299787005 * bb);
  return (
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  );
}

(double, double, double) fromLab(double ll, double aa, double bb) {
  final l = math.pow(ll + 0.3963377774 * aa + 0.2158037573 * bb, 3).toDouble();
  final m = math.pow(ll - 0.1055613458 * aa - 0.0638541728 * bb, 3).toDouble();
  final s = math.pow(ll - 0.0894841775 * aa - 1.291485548 * bb, 3).toDouble();
  double c(double v) => _gam(v).clamp(0.0, 255.0);
  return (
    c(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    c(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    c(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  );
}

// Green runs from green to yellow, like light through leaves, rather than
// round its own hue toward teal: near green the swing spans 81°–136°, faded
// out over 40° so a colour crossfading through green turns smoothly.
const double _green = 146 / 360;
const double _greenFrom = 81;
const double _greenTo = 136;

/// How far round the hue wheel a recoloured spectrum swings, in turns.
const double spectrumSwing = 0.1;

/// The hue an emotion's spectrum swings round, and how far, in turns.
(double, double) emotionHue(double eh) {
  const mid = (_greenFrom + _greenTo) / 720;
  const swing = (_greenTo - _greenFrom) / 720;
  final off = (((eh - _green + 1.5) % 1) - 0.5).abs();
  final w = math.max(0.0, 1 - off / (40 / 360));
  return (eh + (mid - eh) * w, spectrumSwing + (swing - spectrumSwing) * w);
}

/// Each stop recoloured toward a gradient of one hue's neighbours, swinging
/// round the ring so it closes seamlessly, at the stop's own saturation and
/// lightness; blended in OKLab by [amount], never a turn of the hue (turning
/// a whole spectrum tears the ring where neighbours turn opposite ways).
SpectrumStop recolourStop(SpectrumStop stop, double hue, double swing, double amount) {
  final (o, r, g, b) = stop;
  final (_, sat, l) = toHsl(r, g, b);
  final to = fromHsl((hue + swing * math.sin(2 * math.pi * o) + 1) % 1, sat, l);
  final a = toLab(r, g, b);
  final z = toLab(to.$1, to.$2, to.$3);
  final (nr, ng, nb) = fromLab(
    a.$1 + (z.$1 - a.$1) * amount,
    a.$2 + (z.$2 - a.$2) * amount,
    a.$3 + (z.$3 - a.$3) * amount,
  );
  return (o, nr, ng, nb);
}

/// The spectrum graded in OKLab: hues turned by [hue] degrees, colourfulness
/// scaled by [chroma], warmed by [warmth], lightness stretched by [contrast].
List<SpectrumStop> gradeSpectrum(
  List<SpectrumStop> stops, {
  double hue = 0,
  double chroma = 1,
  double warmth = 0,
  double contrast = 1,
}) {
  final lab = [for (final (_, r, g, b) in stops) toLab(r, g, b)];
  final mean = lab.fold(0.0, (s, v) => s + v.$1) / lab.length;
  final c = math.cos(hue * math.pi / 180);
  final s = math.sin(hue * math.pi / 180);
  final out = <SpectrumStop>[];
  for (var i = 0; i < stops.length; i++) {
    final (l, a, b) = lab[i];
    final (r, g, bl) = fromLab(
      (mean + (l - mean) * contrast).clamp(0.0, 1.0),
      (a * c - b * s) * chroma + 0.02 * warmth,
      (a * s + b * c) * chroma + 0.07 * warmth,
    );
    out.add((stops[i].$1, r, g, bl));
  }
  return out;
}

/// The ring's colours resampled every 10° along a smooth curve through the
/// stops, in OKLab: joined in straight lines the colours turn sharply at a
/// stop, and the additive bloom turns that corner into a visible edge.
List<SpectrumStop> smoothSpectrum(List<SpectrumStop> stops, [int samples = 36]) {
  // the ring closes on itself: the stop at 1 is the one at 0 again
  final ring = [
    for (final s in stops)
      if (s.$1 < 1) s,
  ];
  final m = ring.length;
  if (m < 3) return stops;
  final lab = [for (final (_, r, g, b) in ring) toLab(r, g, b)];
  int at(int i) => ((i % m) + m) % m;
  // where stop i sits, counting laps round the ring
  double pos(int i) => ring[at(i)].$1 + (i / m).floorToDouble();
  double ch((double, double, double) v, int c) => c == 0 ? v.$1 : (c == 1 ? v.$2 : v.$3);
  // the slope through each stop, from its neighbours: no corner at the stop
  double slope(int i, int c) => (ch(lab[at(i + 1)], c) - ch(lab[at(i - 1)], c)) / (pos(i + 1) - pos(i - 1));
  final out = <SpectrumStop>[];
  for (var k = 0; k <= samples; k++) {
    final u = k / samples;
    var i = -1;
    while (i < m - 1 && pos(i + 1) <= u) {
      i++;
    }
    final h = pos(i + 1) - pos(i);
    final t = (u - pos(i)) / h;
    final t2 = t * t;
    final t3 = t2 * t;
    double v(int c) =>
        (2 * t3 - 3 * t2 + 1) * ch(lab[at(i)], c) +
        (t3 - 2 * t2 + t) * h * slope(i, c) +
        (-2 * t3 + 3 * t2) * ch(lab[at(i + 1)], c) +
        (t3 - t2) * h * slope(i + 1, c);
    final (r, g, b) = fromLab(v(0), v(1), v(2));
    out.add((u, r, g, b));
  }
  return out;
}

/// The spectrum after tint, emotion and theme have had their say.
List<SpectrumStop> lightPalette(List<SpectrumStop> stops, {required bool dark, Rgb? tint, GlowFollower? glow}) {
  final e = glow != null && glow.amount > 0.005 ? glow : null;
  final (double, double)? swing = e == null ? null : emotionHue(toHsl(e.r, e.g, e.b).$1);
  final d = dark ? 1.0 : 0.82;
  final out = <SpectrumStop>[];
  for (var stop in stops) {
    if (tint != null) {
      // keep a breath of the hue variation so a tinted ring still shimmers
      final (o, r, g, b) = stop;
      stop = (o, r + (tint.r - r) * 0.85, g + (tint.g - g) * 0.85, b + (tint.b - b) * 0.85);
    }
    if (swing != null) stop = recolourStop(stop, swing.$1, swing.$2, e!.amount);
    // on paper, light reads as deeper, saturated ink
    final (o, r, g, b) = stop;
    out.add((o, r * d, g * d, b * d));
  }
  return out;
}

// The ring's look over the painter's defaults: a fainter, wider, softer
// bloom (aura.ts `bloom`, `bloomSize`, `softness`).
const double _bloom = 0.55;
const double _bloomSize = 1.4;
const double _soft = 3.7;

final ui.ImageFilter _softBlur = ui.ImageFilter.blur(sigmaX: _soft, sigmaY: _soft);

/// Paints a luminous frame. One per ring widget: it keeps its paths, paints
/// and the resolved spectrum between frames.
class LightPainter {
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _layer = Paint()..imageFilter = _softBlur;
  final List<Path> _paths = [];
  final List<double> _alpha = [];
  final List<double> _width = [];
  final Float64List _matrix = Float64List(16)
    ..[10] = 1
    ..[15] = 1;

  // the resolved spectrum, kept while nothing it depends on moves
  List<SpectrumStop>? _forStops;
  bool? _forDark;
  Rgb? _forTint;
  final List<Color> _colors = [];
  final List<double> _offsets = [];

  void _resolve(List<SpectrumStop> stops, bool dark, Rgb? tint, GlowFollower? glow) {
    final glowing = glow != null && glow.amount > 0.005;
    if (!glowing && identical(stops, _forStops) && dark == _forDark && identical(tint, _forTint)) return;
    final smooth = smoothSpectrum(lightPalette(stops, dark: dark, tint: tint, glow: glow));
    _colors.clear();
    _offsets.clear();
    for (final (o, r, g, b) in smooth) {
      _offsets.add(clamp01(o));
      _colors.add(Color.fromARGB(255, r.round(), g.round(), b.round()));
    }
    // an emotion moves the colours every frame, so it is never kept
    _forStops = glowing ? null : stops;
    _forDark = dark;
    _forTint = tint;
  }

  void paint(Canvas canvas, OrbFrame frame, {required bool dark, required Rect bounds, Rgb? tint, GlowFollower? glow}) {
    final light = frame.light!;
    _resolve(light.stops, dark, tint, glow);
    // the conic spectrum, turned to the light's angle about its centre
    final c = math.cos(light.angle);
    final s = math.sin(light.angle);
    _matrix
      ..[0] = c
      ..[1] = s
      ..[4] = -s
      ..[5] = c
      ..[12] = light.cx
      ..[13] = light.cy;
    final spectrum = ui.Gradient.sweep(Offset.zero, _colors, _offsets, TileMode.clamp, 0, tau, _matrix);

    // one path per ring, lit at its mean depth: per-segment opacity would
    // seam where the wide, additive strokes overlap
    final rings = frame.strokes.length;
    while (_paths.length < rings) {
      _paths.add(Path());
      _alpha.add(0);
      _width.add(0);
    }
    for (var k = 0; k < rings; k++) {
      final st = frame.strokes[k];
      final p = _paths[k]..reset();
      final pts = st.pts;
      final n = st.length;
      var a = 0.0;
      p.moveTo(pts[0], pts[1]);
      for (var i = 1; i < n; i++) {
        p.lineTo(pts[2 * i], pts[2 * i + 1]);
      }
      p.close();
      for (var i = 0; i < n; i++) {
        a += st.a[i];
      }
      _alpha[k] = a / n;
      _width[k] = st.w;
    }

    final count = math.max(1, rings);
    final i = light.intensity;
    final op = dark ? BlendMode.plus : BlendMode.srcOver;
    final paint = _stroke
      ..blendMode = op
      ..shader = spectrum;
    void pass(double Function(double w) width, double Function(double a) alpha) {
      for (var k = 0; k < rings; k++) {
        paint
          ..strokeWidth = width(_width[k])
          ..color = Color.fromRGBO(0, 0, 0, clamp01(alpha(_alpha[k])));
        canvas.drawPath(_paths[k], paint);
      }
    }

    // A wide, faint pass is laid down once, on the middle ring, with the whole
    // bundle's opacity: those strokes are far wider than the rings are apart, so
    // one reads as all of them (under the blur, side by side, the same light),
    // and the frame costs about a third of stroking each ring.
    void bundle(double Function(double w) width, double Function(double a) alpha) {
      final mid = rings ~/ 2;
      var a = 0.0;
      for (var k = 0; k < rings; k++) {
        a += alpha(_alpha[k]);
      }
      paint
        ..strokeWidth = width(_width[mid])
        ..color = Color.fromRGBO(0, 0, 0, clamp01(a));
      canvas.drawPath(_paths[mid], paint);
    }

    // the glow, on its own layer to be softened
    canvas.saveLayer(bounds, _layer..blendMode = op);
    // 1 · halo: very wide, very faint, shared out between the rings so the
    // total stays the same however many there are
    final haloK = light.halo * i * (dark ? 1 : 0.2) / count;
    for (final (wk, ak) in const [(0.7, 0.045), (0.42, 0.075), (0.24, 0.11), (0.12, 0.16)]) {
      bundle((_) => light.r * wk, (_) => ak * haloK);
    }
    // 2 · bloom: three soft passes hugging each ring; across the bundle they
    // sum into one luminous band, the glassy ribbon
    final bloomK = i * (dark ? 1 : 0.6) * _bloom;
    for (final (wk, ak) in const [(16.0, 0.05), (8.0, 0.11), (4.0, 0.2)]) {
      bundle((w) => w * wk * _bloomSize, (a) => ak * bloomK * a);
    }
    canvas.restore();

    // 3 · chromatic fringes, scaled about the centre (dark substrates only)
    if (dark && light.fringe > 0) {
      paint.shader = null;
      for (final (scale, rgb, ak) in [(1 + light.fringe, _fringeOut, 0.16), (1 - light.fringe, _fringeIn, 0.22)]) {
        canvas
          ..save()
          ..translate(light.cx, light.cy)
          ..scale(scale)
          ..translate(-light.cx, -light.cy);
        for (var k = 0; k < rings; k++) {
          paint
            ..strokeWidth = _width[k] * 1.4 / scale
            ..color = Color.fromRGBO(rgb.r.round(), rgb.g.round(), rgb.b.round(), clamp01(ak * i * _alpha[k]));
          canvas.drawPath(_paths[k], paint);
        }
        canvas.restore();
      }
      paint.shader = spectrum;
    }

    // 4 · the crisp core of every ring
    pass((w) => w, (a) => 0.7 * a * (0.75 + 0.25 * i));

    // 5 · specular hot spot: white pooled where the light sits
    if (dark) {
      final sp = light.spec;
      paint.shader = ui.Gradient.radial(
        Offset(sp.x, sp.y),
        sp.r,
        const [Color(0xFFFFFFFF), Color(0x73FFFFFF), Color(0x00FFFFFF)],
        const [0, 0.35, 1],
      );
      pass((w) => w * 2.2, (a) => sp.a * a);
    }
    paint.shader = null;
  }
}
