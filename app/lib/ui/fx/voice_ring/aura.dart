// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The two ring geometries (aura.ts, auraMono.ts), knob defaults as the
// author ships them.
//
// Ring: a handful of rings lean a few degrees off the view axis, each on its
// own heading, so the rim reads as a luminous ribbon that thickens where the
// rings part and thins where they meet. One skin field bends every ring
// together; the rings tumble on the voice clock; the ring swells on the soft
// envelope. Processing spins the colours round and sweeps the highlight.
//
// Mono: the same rings as two loops of solid tube. Waiting, they lie almost
// face-on, one round loop barely bent; a voice opens them into a globe and
// sets them warping — a saddle out of the plane, an oval and a three-lobed
// wobble in it — while the voice clock spins everything faster.

import 'dart:math' as math;
import 'dart:typed_data';

import 'frame.dart';
import 'voice.dart';

/// The ring's default spectrum, read clockwise from the top.
const List<SpectrumStop> auraSpectrum = [
  (0, 255, 150, 90),
  (0.12, 255, 110, 120),
  (0.24, 255, 80, 170),
  (0.4, 190, 80, 255),
  (0.58, 90, 92, 255),
  (0.74, 60, 132, 255),
  // violet warms through magenta into the gold at the top, so the gold fades
  // in rather than meeting the violet at an edge
  (0.84, 170, 90, 255),
  (0.93, 240, 104, 165),
  (1, 255, 150, 90),
];

Float64List _unitCircle(int segs) {
  final points = Float64List(segs * 2);
  for (var i = 0; i < segs; i++) {
    final th = i / segs * tau;
    points[2 * i] = math.cos(th);
    points[2 * i + 1] = math.sin(th);
  }
  return points;
}

/// Builds the ring's frames into buffers it owns.
class AuraFrameBuilder {
  AuraFrameBuilder({required this.segs, this.rings = 6})
    : frame = OrbFrame([for (var k = 0; k < rings; k++) RingStroke(segs)], light: FrameLight()),
      _circle = _unitCircle(segs),
      _dirs = Float64List(rings * segs * 2),
      _f = Float64List(rings * segs),
      _rk = Float64List(rings);

  final int rings;
  final int segs;
  final OrbFrame frame;

  /// The spectrum the light carries (the theme's or the author's).
  List<SpectrumStop> stops = auraSpectrum;

  final Float64List _circle;
  final Float64List _dirs;
  final Float64List _f;
  final Float64List _rk;
  final SkinField _field = SkinField();

  OrbFrame build(double size, double t, VoiceInput v) {
    final half = size / 2;
    final level = v.level;
    final lo = v.softBands[0];
    final mid = v.softBands[1];
    final hi = v.bands[2];
    final drive = v.drive;
    final p = v.processing;
    final voice = 0.5 * level + 0.5 * v.soft;
    // signal's motion: the swell rides the soft envelope. Halo and bloom
    // spill past the rings, so they rest well inside the box.
    final r = half * 0.56 * (1 + 0.17 * v.soft) * (1 - 0.06 * p);
    const deform = 1.45;
    final aLobe = 0.02 + (0.14 * lo + 0.06 * level) * deform;
    final aFine = 0.01 + (0.07 * mid + 0.03 * hi) * deform;
    // one field for every ring, so they bend together like a skin
    _field.set(aLobe, aFine, drive, 1.75);
    final lw = math.max(0.6, 1.85 * radiusScale(size, 0.5));
    const spread = 0.91;
    // how far apart the rings sit, each a step larger than the last
    const gap = 0.02;

    // Rings first as directions and skin values, then drawn: their own
    // shared average is taken out too, so the bulges never change the size.
    var sum = 0.0;
    final count = rings * segs;
    for (var k = 0; k < rings; k++) {
      final odd = k.isOdd;
      // each ring tumbles on the voice clock, alternate rings opposite ways,
      // tipping a little further as it goes
      final spin = 0.16 * (0.5 + hashD(k.toDouble(), 2.1)) * (odd ? 1 : -1);
      final lean = math.max(
        0.02,
        spread * (0.2 + 0.8 * hashD(k.toDouble(), 3.1)) +
            0.03 * math.sin(t * 0.27 + k * 1.3) +
            0.08 * math.sin(drive * 0.35 + k * 1.7),
      );
      final dir = hashD(k.toDouble(), 7.7) * tau + t * 0.05 * (odd ? 1 : -1) + drive * spin;
      final sl = math.sin(lean);
      final nx = sl * math.cos(dir);
      final ny = sl * math.sin(dir);
      final nz = math.cos(lean);
      final ul = math.sqrt(nx * nx + nz * nz);
      final ux = nz / ul;
      final uz = -nx / ul;
      final vx = ny * uz;
      final vy = nz * ux - nx * uz;
      final vz = -ny * ux;
      // concentric spread: a hair of it bundles the rings into one glassy tube
      _rk[k] = r * (1 + gap * (k - (rings - 1) / 2));
      final a = frame.strokes[k].a;
      for (var i = 0; i < segs; i++) {
        final c = _circle[2 * i];
        final s = _circle[2 * i + 1];
        final x = ux * c + vx * s;
        final y = vy * s;
        final z = uz * c + vz * s;
        final fi = _field.at(x, y, z);
        final j = k * segs + i;
        _dirs[2 * j] = x;
        _dirs[2 * j + 1] = y;
        _f[j] = fi;
        sum += fi;
        // the near half of a ring a touch brighter than the far half
        a[i] = 0.62 + 0.38 * clamp01((z / sl + 1) / 2);
      }
    }
    final mean = sum / count;
    // The first harmonic round the ring is a shift, not a bend: take it out
    // across all rings with the average, leaving only true bends.
    var c1 = 0.0;
    var s1 = 0.0;
    for (var j = 0; j < count; j++) {
      final x = _dirs[2 * j];
      final y = _dirs[2 * j + 1];
      final l = _len(x, y);
      c1 += (_f[j] - mean) * (x / l);
      s1 += (_f[j] - mean) * (y / l);
    }
    c1 = 2 * c1 / count;
    s1 = 2 * s1 / count;
    for (var k = 0; k < rings; k++) {
      final stroke = frame.strokes[k];
      final pts = stroke.pts;
      stroke.w = lw;
      for (var i = 0; i < segs; i++) {
        final j = k * segs + i;
        final x = _dirs[2 * j];
        final y = _dirs[2 * j + 1];
        final l = _len(x, y);
        final rr = _rk[k] * (1 + _f[j] - mean - c1 * (x / l) - s1 * (y / l));
        pts[2 * i] = half + x * rr;
        pts[2 * i + 1] = half - y * rr;
      }
    }

    // the highlight rests low on the left; processing sweeps it round
    final specAt = 2.3 + 0.25 * math.sin(t * 0.21) + 2 * v.spin;
    final light = frame.light!
      ..cx = half
      ..cy = half
      ..r = r
      ..stops = stops
      // warm at the top, cool below, swaying rather than turning; processing
      // spins it all the way round
      ..angle = -math.pi / 2 - 0.35 + (0.5 * math.sin(t * 0.07) + 0.4 * math.sin(drive * 0.2)) + v.spin
      // processing lights the ring up: brighter bloom and a bigger halo
      ..intensity = (0.62 + 0.55 * voice + 0.5 * p) * 0.78
      ..halo = 0.5 * (1 + 0.6 * p)
      ..fringe = 0.016 + 0.012 * voice;
    light.spec
      ..x = half + math.cos(specAt) * r
      ..y = half + math.sin(specAt) * r
      ..r = r * (0.5 + 0.25 * p)
      ..a = (0.5 + 0.35 * voice + 0.4 * p) * 1.4;
    frame.contact = null;
    return frame;
  }
}

double _len(double x, double y) {
  final l = math.sqrt(x * x + y * y);
  return l == 0 ? 1 : l;
}

// The mono light: from the upper left, a little in front.
const double _lx = -0.45;
const double _ly = 0.55;
const double _lz = 0.7;
final double _ln = math.sqrt(_lx * _lx + _ly * _ly + _lz * _lz);
const double _eye = 1 / 0.02;

/// The mono tube's look: one even grey, the highlight alone giving it its
/// roundness; an emotion as deep as it goes, fading most of the way into the
/// grey on one side; green a shade darker than the others.
const FrameTube monoTube = FrameTube(
  shine: 1,
  contrast: 0,
  depth: 0,
  saturation: 2,
  gradient: 0.69,
  gradientAngle: 0,
  gradientSpin: 0,
  colorBrightness: 0.9,
  positiveBrightness: 0.93,
  negativeBrightness: 1,
  calmBrightness: 1,
);

/// Builds mono's frames into buffers it owns.
class MonoFrameBuilder {
  MonoFrameBuilder({required this.segs, this.rings = 2})
    : frame = OrbFrame([for (var k = 0; k < rings; k++) RingStroke(segs, depth: true)], tube: monoTube),
      _circle = _unitCircle(segs),
      _xs = Float64List(segs),
      _ys = Float64List(segs),
      _zs = Float64List(segs);

  final int rings;
  final int segs;
  final OrbFrame frame;
  final Float64List _circle;
  final Float64List _xs;
  final Float64List _ys;
  final Float64List _zs;

  OrbFrame build(double size, double t, VoiceInput v) {
    final half = size / 2;
    final p = v.processing;
    // the slow envelope only: the shape breathes with speech, it doesn't pump
    final voice = v.soft;
    final mids = v.softBands[1];
    final r = half * 0.44 * (1 + 0.08 * voice) * (1 - 0.06 * p);
    const deform = 1.85;
    final lw = math.max(0.5, 1.7 * radiusScale(size, 0.6));
    // a few degrees off the view axis waiting, a globe while someone speaks
    final lean = 0.22 + 0.75 * voice;
    const rest = 0.12;
    final bend = rest + (1 - rest) * clamp01(voice * deform);
    final twist = 1.69 * bend;
    final wobble = 0.31 * bend;
    // the voice clock, which runs much faster while someone speaks
    final u = v.drive * 2.1;

    // the waiting motion, gone once the voice has the ring
    final calm = 1 - smoothstep(0.1, 0.5, voice);
    final sway = 0.18 * calm;
    final swell = 0.05 * calm;
    final drift = 0.03 * calm;
    final cx = half + r * drift * math.sin(0.9 * t + 0.6);
    final cy = half + r * drift * math.sin(0.7 * t + 2.1);

    for (var k = 0; k < rings; k++) {
      // each loop on its own phases, a golden turn apart
      final ph = k * 2.399;
      final sign = k.isOdd ? -1 : 1;
      // the loops tip opposite ways, so they cross like the lines of a globe
      final tip = lean * (1 + 0.25 * math.sin(0.17 * u + ph)) + sway * math.sin(1.3 * t + 1.3 * ph);
      final dir = k * tau / rings + 0.23 * u * sign + 0.4 * math.sin(0.11 * u + ph) + v.spin;
      final nx = math.sin(tip) * math.cos(dir);
      final ny = math.sin(tip) * math.sin(dir);
      final nz = math.cos(tip);
      final ul = _len(nx, nz);
      final ux = nz / ul;
      final uz = -nx / ul;
      final vx = ny * uz;
      final vy = nz * ux - nx * uz;
      final vz = -ny * ux;

      // out of the plane: a saddle and a gentler three-fold
      final b2 = 0.2 * twist * math.sin(0.29 * u + 1.3 + ph);
      final p2 = 0.37 * u + ph;
      final b3 = 0.07 * twist * math.sin(0.23 * u + 0.4 + ph);
      final p3 = -0.31 * u + 2.1 + ph;
      // in the plane: an oval and a three-lobed wobble; the mids add a four-fold swell
      final a2 = 0.07 * wobble * math.sin(0.33 * u + 0.4 + ph);
      final q2 = 0.41 * u + ph;
      final a3 = 0.04 * wobble * math.sin(0.27 * u + 1 + ph);
      final q3 = -0.35 * u + 0.8 + ph;
      final a4 = 0.04 * deform * mids;
      final q4 = 0.5 * u + ph;
      // waiting: a slow oval and three-lobed swell, turning round the loop
      final s2 = swell * math.sin(1.1 * t + 0.7 + ph);
      final r2 = 0.7 * t + ph;
      final s3 = 0.6 * swell * math.sin(1.5 * t + 1.9 + ph);
      final r3 = -0.5 * t + ph;
      // each a hair smaller than the last, so where they meet they part
      final rk = 1 - 0.035 * k;

      for (var i = 0; i < segs; i++) {
        final th = i / segs * tau;
        final c = _circle[2 * i];
        final s = _circle[2 * i + 1];
        final rr =
            rk *
            (1 +
                a2 * math.cos(2 * th + q2) +
                a3 * math.cos(3 * th + q3) +
                a4 * math.cos(4 * th + q4) +
                s2 * math.cos(2 * th + r2) +
                s3 * math.cos(3 * th + r3));
        final h = rk * (b2 * math.sin(2 * th + p2) + b3 * math.sin(3 * th + p3));
        _xs[i] = (ux * c + vx * s) * rr + nx * h;
        _ys[i] = vy * s * rr + ny * h;
        _zs[i] = (uz * c + vz * s) * rr + nz * h;
      }

      final stroke = frame.strokes[k];
      final pts = stroke.pts;
      final shade = stroke.a;
      final depth = stroke.z!;
      stroke.w = lw;
      for (var i = 0; i < segs; i++) {
        // all but flat on: the eye 50 radii away (the author's `persp` floor)
        final f = _eye / (_eye - _zs[i]);
        pts[2 * i] = cx + _xs[i] * r * f;
        pts[2 * i + 1] = cy - _ys[i] * r * f;
        // a tube is brightest across the light, darkest along it
        final j = (i + 1) % segs;
        final m = (i + segs - 1) % segs;
        final tx = _xs[j] - _xs[m];
        final ty = _ys[j] - _ys[m];
        final tz = _zs[j] - _zs[m];
        final tl = math.sqrt(tx * tx + ty * ty + tz * tz);
        final along = (tx * _lx + ty * _ly + tz * _lz) / ((tl == 0 ? 1 : tl) * _ln);
        final lit = math.sqrt(math.max(0, 1 - along * along));
        final near = clamp01((_zs[i] + 1) / 2);
        shade[i] = clamp01(0.12 + 0.6 * lit * (0.55 + 0.45 * near) + 0.28 * near + 0.08 * voice);
        depth[i] = near * 2 - 1;
      }
    }
    frame.contact = null;
    return frame;
  }
}
