// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'metal_geometry.dart';

/// The wandering halo's numbers (the web's `GLOW_DEFAULTS`).
abstract final class MetalGlowConfig {
  static const haloOpMul = 2.0;
  static const extraIntensity = 3.51;
  static const peakOp = 0.85;
  static const baseOp = 0.34;
  static const inset = 1.5;
  static const extraOutward = 1.0;
  static const wanderRange = 15.0;
  static const wanderLerp = 0.0075;
  static const fadeRate = 0.00875;
  static const lumLo = 0.08;
  static const lumHi = 0.32;
  static const minDwellMs = 1500.0;
  static const relocFadeMs = 300.0;
  static const relocFadeOutMs = 450.0;
  static const pointGain = 2.5;
  static const haloHalfLen = 7.8;
  static const extraHalfLen = 9.13952 / 3;
  static const haloLayers = [(26.4, 8.4, 0.385), (15.6, 4.8, 0.595), (7.2, 2.1, 0.70), (3.0, 0.9, 0.70)];
  static const extraLayers = [(4.0 / 3, 2.0 / 3, 0.85), (2.0 / 3, 1.35 / 3, 1.0)];
  static const extraFadeR = 13.0 / 3;

  // The cursor light's catch-light (`cursor/light.ts`), driven here by [MetalSweep].
  static const lightReach = 56.0;
  static const lightFadeMs = 200.0;
  static const catchFollow = 0.25;
  static const catchGain = 1.0;
}

/// 手机上没有光标，原作“光标当光源、环上的高光转过来对着它”这一路换成一束自己扫过的光：
/// 每隔 [every]，用 [duration] 从元素上方 [lift] 处由左向右扫过，环上的高光跟着它走，
/// 扫过后回到原作的亮点游走。只对环（按钮、圆钮、徽标）起作用，文字的高光是按字形取点，没有连续的边可走。
@immutable
class MetalSweep {
  const MetalSweep({
    this.every = const Duration(seconds: 9),
    this.duration = const Duration(milliseconds: 3600),
    this.lift = 10,
  });

  final Duration every;
  final Duration duration;

  /// How far above the top edge the light passes, px.
  final double lift;

  @override
  bool operator ==(Object other) =>
      other is MetalSweep && other.every == every && other.duration == duration && other.lift == lift;

  @override
  int get hashCode => Object.hash(every, duration, lift);
}

/// A light source near the ring: the outline point facing it and a 0..1 weight.
typedef MetalLight = ({Offset point, double weight});

/// Where the sweeping light is, as the web's cursor-light tracker would see a
/// pointer there: the nearest outline point and the smoothed proximity weight.
class MetalSweepTracker {
  double _u = 0;
  double? _lastMs;
  Offset _point = Offset.zero;

  MetalLight? step(double nowMs, MetalSweep sweep, Size size, double radius, MetalShapeKind kind) {
    final dtMs = _lastMs == null ? 1000 / 60 : (nowMs - _lastMs!).clamp(1.0, 50.0);
    _lastMs = nowMs;
    final every = sweep.every.inMicroseconds / 1000, duration = sweep.duration.inMicroseconds / 1000;
    final phase = nowMs % every - (every - duration);
    var u = 0.0;
    if (phase >= 0) {
      const reach = MetalGlowConfig.lightReach;
      final x = -reach + phase / duration * (size.width + 2 * reach);
      final (point, d) = MetalGeometry.nearestOutlinePoint(
        Offset(x, -sweep.lift),
        size.width,
        size.height,
        radius,
        kind,
      );
      _point = point;
      if (d.abs() <= reach) {
        final t = 1 - d.abs() / reach;
        u = t * t * (3 - 2 * t);
      }
    }
    _u += (u - _u) * (1 - math.exp(-dtMs / (MetalGlowConfig.lightFadeMs / 3)));
    if (u == 0 && _u < 0.002) {
      _u = 0;
      return null;
    }
    return (point: _point, weight: _u);
  }
}

/// One frame of the halo.
@immutable
class MetalGlowFrame {
  const MetalGlowFrame({
    required this.position,
    required this.extraPosition,
    required this.tangent,
    required this.haloOpacity,
    required this.extraOpacity,
    required this.envelope,
    required this.haloTint,
    required this.extraTint,
  });

  final Offset position;
  final Offset extraPosition;
  final double tangent;
  final double haloOpacity;
  final double extraOpacity;

  /// Appear / disappear fade, 0..1.
  final double envelope;
  final Color haloTint;
  final Color extraTint;
}

/// The material's linear RGB at a box-local point, this frame.
typedef MetalSampler = (double, double, double) Function(Offset p);

/// The halo's state machine (`glow/glow.ts` `updateGlow`): it sits on the
/// brightest of 16 perimeter points (or of the glyph points), holds there at
/// least [MetalGlowConfig.minDwellMs], relocates by fading out in place and in
/// at the new spot, wanders slowly along the edge, and takes its tint from the
/// material under it. With a [MetalLight] it faces the light instead.
class MetalGlowState {
  MetalGlowState({math.Random? random}) : _random = random ?? math.Random(7);

  static const _relocateDelta = 0.05;
  static const _wanderRetargetMs = 120 * (1000 / 15);
  static const _rateTickMs = 1000 / 15;
  static const _huntIntervalMs = 66.0;
  static const _tintHoldMs = 2000.0, _tintFadeMs = 400.0;
  static const _envMaxStepMs = 34.0;
  static const _ltSatBoost = 2.625, _ltValMult = 1.008, _ltMinVal = 0.31;
  static const _lightEnter = -2, _lightExit = -3;

  final math.Random _random;

  List<({Offset point, double arc})> _perim = const [];
  List<Offset>? _points;
  bool _pointMode = false;
  Size _size = Size.zero;
  double _radius = 0;
  MetalShapeKind _kind = MetalShapeKind.pill;
  List<double> _lum = const [];

  int _currentIdx = 0;
  double _glowOpacity = 0;
  double? _appearedAt;
  int _relocNextIdx = 0;
  _Tween? _relocTween;
  double _envClock = 0;
  double? _lastTickMs;
  double? _lastHuntMs;
  double _wanderS = 0, _wanderTargetS = 0, _wanderMs = 0;
  bool _lightMode = false;
  double _lightArc = 0, _lightTargetArc = 0;
  (double, double, double) _tintFrom = (1, 1, 1), _tintTarget = (1, 1, 1);
  _Tween? _tintTween;
  double _tintHoldUntil = 0;

  /// Rebuilds the perimeter table when the box or the mask changes: 16 points
  /// along the outline, or [points] inside the glyphs (point mode).
  void configure(Size size, double radius, MetalShapeKind kind, {List<Offset>? points}) {
    if (size == _size && radius == _radius && kind == _kind && identical(points, _points) && _perim.isNotEmpty) return;
    _size = size;
    _radius = radius;
    _kind = kind;
    _pointMode = points != null;
    _points = points;
    if (points != null) {
      _perim = [for (var i = 0; i < points.length; i++) (point: points[i], arc: i.toDouble())];
    } else {
      final total = MetalGeometry.shapePerim(size.width, size.height, radius, kind);
      _perim = [
        for (var i = 0; i < 16; i++)
          (
            point: MetalGeometry.sampleAtArc(
              total * i / 16,
              size.width,
              size.height,
              radius,
              MetalGlowConfig.inset,
              0,
              kind,
            ),
            arc: total * i / 16,
          ),
      ];
    }
    _lum = List.filled(_perim.length, 0);
    _lastHuntMs = null;
    if (_currentIdx >= _perim.length) _currentIdx = 0;
  }

  /// Perimeter length of the configured shape over the 140×40 reference pill:
  /// what the halo's size and wander scale with.
  double get ratio => _pointMode
      ? MetalGeometry.rrPerim(_size.width, _size.height, _radius) / MetalGeometry.rrPerim(140, 40, 20)
      : MetalGeometry.shapePerim(_size.width, _size.height, _radius, _kind) / MetalGeometry.rrPerim(140, 40, 20);

  bool get pointMode => _pointMode;

  /// Advances to [nowMs] and returns this frame's halo.
  MetalGlowFrame? tick(
    double nowMs,
    MetalSampler sampler, {
    required double strength,
    required bool dark,
    MetalDeform? deform,
    MetalLight? light,
  }) {
    if (_perim.isEmpty) return null;
    final dtMs = _lastTickMs == null ? _rateTickMs : (nowMs - _lastTickMs!).clamp(0.5, 200.0);
    _lastTickMs = nowMs;
    _envClock += math.min(dtMs, _envMaxStepMs);
    double rate(double perTick) => 1 - math.pow(1 - perTick, dtMs / _rateTickMs).toDouble();

    // The luminance hunt runs at the web's shader rate; the envelope every frame.
    if (_lastHuntMs == null || nowMs - _lastHuntMs! >= _huntIntervalMs) {
      _lastHuntMs = nowMs;
      for (var i = 0; i < _perim.length; i++) {
        _lum[i] = _luma(sampler(_perim[i].point));
      }
    }
    var maxLum = -1.0, maxIdx = _currentIdx;
    for (var i = 0; i < _lum.length; i++) {
      if (_lum[i] > maxLum) {
        maxLum = _lum[i];
        maxIdx = i;
      }
    }
    final curLum = _lum[_currentIdx];
    final dwellActive = _appearedAt != null && nowMs - _appearedAt! < MetalGlowConfig.minDwellMs;
    final targetOp = _opacityFor(curLum);
    final rivalDominates = !dwellActive && maxLum - curLum > _relocateDelta;

    // The light as a light source: while it is near, the hotspot faces it and
    // its brightness follows proximity. Ring mode only.
    final lightOn = light != null && !_pointMode && light.weight > 0.02;
    final perimLen = MetalGeometry.shapePerim(_size.width, _size.height, _radius, _kind);
    if (lightOn) _lightTargetArc = MetalGeometry.arcAtPoint(light.point, _size.width, _size.height, _radius, _kind);
    final lightOp = lightOn ? math.min(1.0, MetalGlowConfig.peakOp * MetalGlowConfig.catchGain * light.weight) : 0.0;

    void fadeIn() {
      _appearedAt = nowMs;
      _wanderS = _wanderTargetS = _wanderMs = 0;
      _relocTween = _Tween(0, 1, MetalGlowConfig.relocFadeMs, smooth: true)..start(_envClock);
    }

    void fadeOut(int next) {
      _relocNextIdx = next;
      _relocTween = _Tween(1, 0, MetalGlowConfig.relocFadeOutMs, smooth: true)..start(_envClock);
    }

    final reloc = _relocTween;
    if (reloc != null && reloc.done && reloc.to == 0) {
      // Faded out at the old spot: switch, then fade in at the new one.
      var next = _relocNextIdx;
      if (next == _lightEnter && !lightOn) next = _lightExit;
      if (next == _lightExit) {
        // Back to the luminance hunt — re-appears below as a first appearance.
        _lightMode = false;
        _appearedAt = null;
        _relocTween = null;
      } else if (next == _lightEnter) {
        _lightMode = true;
        _lightArc = _lightTargetArc;
        _glowOpacity = lightOp;
        fadeIn();
      } else {
        _currentIdx = next;
        _glowOpacity = _opacityFor(_lum[next]);
        fadeIn();
      }
    }
    final current = _relocTween;
    if (current == null || current.done) {
      if (_appearedAt == null) {
        // First appearance: face the light if it's there, else the brightest point.
        if (lightOn) {
          _lightMode = true;
          _lightArc = _lightTargetArc;
          _glowOpacity = lightOp;
        } else {
          _lightMode = false;
          _currentIdx = maxIdx;
          _glowOpacity = targetOp;
        }
        fadeIn();
      } else if (lightOn != _lightMode) {
        fadeOut(lightOn ? _lightEnter : _lightExit);
      } else if (!_lightMode && rivalDominates) {
        fadeOut(maxIdx);
      }
    }
    if (_lightMode) {
      if (lightOn) _glowOpacity = lightOp;
      final fa = 1 - math.pow(1 - MetalGlowConfig.catchFollow, dtMs / (1000 / 60));
      var diff = _lightTargetArc - _lightArc;
      diff = ((diff % perimLen) + perimLen * 1.5) % perimLen - perimLen / 2;
      _lightArc += diff * fa;
    } else {
      _glowOpacity += (targetOp - _glowOpacity) * rate(MetalGlowConfig.fadeRate);
    }
    _glowOpacity = _glowOpacity.clamp(0.0, 1.0);
    final envelope = _relocTween?.tick(_envClock) ?? 1.0;

    final wanderRange = MetalGlowConfig.wanderRange * ratio;
    _wanderMs += dtMs;
    if (_wanderMs >= _wanderRetargetMs) {
      _wanderTargetS = (_random.nextDouble() * 2 - 1) * wanderRange;
      _wanderMs = 0;
    }
    _wanderS += (_wanderTargetS - _wanderS) * rate(MetalGlowConfig.wanderLerp);

    final arc = _lightMode ? _lightArc : _perim[_currentIdx].arc + _wanderS;
    var (blob, extra, tangent) = _place(arc, _wanderS);
    if (deform != null) {
      blob = deform(blob);
      extra = deform(extra);
    }

    late final samp = sampler(blob);
    final lightTheme = !dark;
    final tween = _tintTween;
    if (tween == null) {
      _tintFrom = _tintTarget = samp;
      _tintTween = _Tween(0, 1, _tintFadeMs)..start(nowMs);
      _tintHoldUntil = lightTheme ? 0 : nowMs + _tintHoldMs;
    } else if (tween.done) {
      if (lightTheme) {
        _tintFrom = _lerp3(_tintFrom, _tintTarget, tween.value);
        _tintTarget = samp;
        _tintTween = _Tween(0, 1, _tintFadeMs)..start(nowMs);
      } else if (nowMs >= _tintHoldUntil) {
        _tintFrom = _tintTarget;
        _tintTarget = samp;
        _tintTween = _Tween(0, 1, _tintFadeMs)..start(nowMs);
        _tintHoldUntil = nowMs + _tintHoldMs;
      }
    }
    final ft = _tintTween!.tick(nowMs);
    return _frame(blob, extra, tangent, _lerp3(_tintFrom, _tintTarget, ft), _glowOpacity, envelope, strength, dark);
  }

  /// A settled frame without running the clock — reduced motion, or a paused
  /// instance that never ticked: the halo on the brightest point, fully in.
  MetalGlowFrame? still(MetalSampler sampler, {required double strength, required bool dark, MetalDeform? deform}) {
    if (_perim.isEmpty) return null;
    var maxLum = -1.0, maxIdx = 0;
    for (var i = 0; i < _perim.length; i++) {
      final l = _luma(sampler(_perim[i].point));
      if (l > maxLum) {
        maxLum = l;
        maxIdx = i;
      }
    }
    var (blob, extra, tangent) = _place(_perim[maxIdx].arc, 0);
    if (_pointMode) blob = extra = _perim[maxIdx].point;
    if (deform != null) {
      blob = deform(blob);
      extra = deform(extra);
    }
    return _frame(blob, extra, tangent, sampler(blob), _opacityFor(maxLum), 1, strength, dark);
  }

  (Offset, Offset, double) _place(double arc, double wander) {
    if (_pointMode) {
      // Hotspot on a glyph point, running horizontally; wander slides it along x.
      final p = _perim[_currentIdx].point + Offset(wander, 0);
      return (p, p, 0.0);
    }
    final w = _size.width, h = _size.height;
    return (
      MetalGeometry.sampleAtArc(arc, w, h, _radius, MetalGlowConfig.inset, 0, _kind),
      MetalGeometry.sampleAtArc(arc, w, h, _radius, MetalGlowConfig.inset, MetalGlowConfig.extraOutward * ratio, _kind),
      MetalGeometry.tangentAngleAtArc(arc, w, h, _radius, MetalGlowConfig.inset, _kind),
    );
  }

  MetalGlowFrame _frame(
    Offset blob,
    Offset extra,
    double tangent,
    (double, double, double) tint,
    double glowOpacity,
    double envelope,
    double strength,
    bool dark,
  ) {
    var (r, g, b) = (tint.$1.clamp(0.0, 1.0), tint.$2.clamp(0.0, 1.0), tint.$3.clamp(0.0, 1.0));
    var extraTint = const Color(0xFFFFFFFF);
    if (dark) {
      final peak = math.max(r, math.max(g, b));
      if (peak > 0) (r, g, b) = (r / peak, g / peak, b / peak);
    } else {
      final hsv = HSVColor.fromColor(Color.from(alpha: 1, red: r, green: g, blue: b));
      extraTint = hsv
          .withSaturation(math.min(1.0, hsv.saturation * _ltSatBoost))
          .withValue(math.max(_ltMinVal, math.min(1.0, hsv.value * _ltValMult)))
          .toColor();
    }
    final m = strength.clamp(0.0, 1.0) * (_pointMode ? MetalGlowConfig.pointGain : 1);
    return MetalGlowFrame(
      position: blob,
      extraPosition: extra,
      tangent: tangent,
      haloOpacity: math.min(1.0, glowOpacity * MetalGlowConfig.haloOpMul * m),
      extraOpacity: math.min(1.0, glowOpacity * MetalGlowConfig.extraIntensity * m),
      envelope: envelope,
      haloTint: Color.from(alpha: 1, red: r, green: g, blue: b),
      extraTint: extraTint,
    );
  }

  static double _opacityFor(double lum) =>
      MetalGlowConfig.baseOp +
      (MetalGlowConfig.peakOp - MetalGlowConfig.baseOp) *
          _smoothstep(MetalGlowConfig.lumLo, MetalGlowConfig.lumHi, lum);
}

double _luma((double, double, double) c) => 0.2126 * c.$1 + 0.7152 * c.$2 + 0.0722 * c.$3;

(double, double, double) _lerp3((double, double, double) a, (double, double, double) b, double t) =>
    (a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t, a.$3 + (b.$3 - a.$3) * t);

double _smoothstep(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// `tween.ts`: linear by default, smoothstep for the appear / disappear envelope.
class _Tween {
  _Tween(this.from, this.to, this.duration, {this.smooth = false}) : value = from;

  final double from;
  final double to;
  final double duration;
  final bool smooth;
  double value;
  double _start = 0;
  bool done = false;

  void start(double now) {
    _start = now;
    value = from;
    done = false;
  }

  double tick(double now) {
    if (done) return value;
    final t = math.min(1.0, (now - _start) / duration);
    value = from + (to - from) * (smooth ? t * t * (3 - 2 * t) : t);
    if (t >= 1) done = true;
    return value;
  }
}

// ── Drawing ───────────────────────────────────────────────────────────────

/// A baked halo sprite: white strokes, alpha only, drawn along +x with the
/// stroke centre at ([ax], [ay]) in logical px.
class _Sprite {
  const _Sprite(this.image, this.width, this.height, this.ax, this.ay);

  final ui.Image image;
  final double width, height, ax, ay;
}

/// Draws [MetalGlowFrame]s: the halo and catch-light sprites at the hotspot,
/// tinted, clipped to the ring band (full) and its surround (half) or to a
/// glyph mask, under the theme's blend.
class MetalGlowPainter {
  static final _cache = <String, _Sprite>{};

  /// The web's `compose`: round-capped strokes, gaussian-blurred, stacked
  /// white over white, with the catch-light's radial end fade. Baked once per
  /// size and pixel ratio.
  static _Sprite _bake(bool halo, double halfLen, double dpr) {
    final key = '${halo ? 'h' : 'e'}|${halfLen.toStringAsFixed(2)}|$dpr';
    return _cache[key] ??= () {
      final layers = halo ? MetalGlowConfig.haloLayers : MetalGlowConfig.extraLayers;
      var padMax = 0.0;
      for (final (stroke, blur, _) in layers) {
        padMax = math.max(padMax, stroke / 2 + 3 * blur);
      }
      final pad = padMax.ceilToDouble() + 1;
      final cw = 2 * halfLen + 2 * pad, ch = 2 * pad;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(dpr);
      for (final (stroke, blur, opacity) in layers) {
        canvas.drawLine(
          Offset(pad - halfLen, pad),
          Offset(pad + halfLen, pad),
          Paint()
            ..color = Color.from(alpha: opacity, red: 1, green: 1, blue: 1)
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
        );
      }
      if (!halo) {
        // SVG luminance mask: white to 0.30, #404040 (0.25) at 0.65, black at 1.
        const r = MetalGlowConfig.extraFadeR;
        canvas.drawRect(
          Rect.fromLTWH(0, 0, cw, ch),
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = ui.Gradient.radial(
              Offset(pad, pad),
              r,
              const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x40FFFFFF), Color(0x00FFFFFF)],
              const [0, 0.3, 0.65, 1],
            ),
        );
      }
      final picture = recorder.endRecording();
      final image = picture.toImageSync((cw * dpr).ceil(), (ch * dpr).ceil());
      picture.dispose();
      return _Sprite(image, cw, ch, pad, pad);
    }();
  }

  /// How far the halo can reach past the box, px.
  static double overflow(double ratio) => 46 + MetalGlowConfig.haloHalfLen * ratio;

  /// Draws [frame] for a ring: full strength on [band], half on [surround].
  static void paintRing(
    Canvas canvas,
    MetalGlowFrame frame, {
    required Rect box,
    required Path band,
    required Path surround,
    required double ratio,
    required double dpr,
    required bool dark,
    required bool small,
  }) {
    _group(canvas, frame, box, ratio, dark, small, () {
      canvas
        ..save()
        ..clipPath(surround);
      _sprites(canvas, frame, ratio, dpr, 0.5);
      canvas
        ..restore()
        ..save()
        ..clipPath(band);
      _sprites(canvas, frame, ratio, dpr, 1);
      canvas.restore();
    });
  }

  /// Draws [frame] masked by whatever [mask] paints (glyphs and their skirt).
  static void paintMasked(
    Canvas canvas,
    MetalGlowFrame frame, {
    required Rect box,
    required double ratio,
    required double dpr,
    required bool dark,
    required void Function(Canvas canvas) mask,
  }) {
    _group(canvas, frame, box, ratio, dark, false, () {
      final bounds = box.inflate(overflow(ratio));
      canvas.saveLayer(bounds, Paint());
      _sprites(canvas, frame, ratio, dpr, 1);
      canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
      mask(canvas);
      canvas
        ..restore()
        ..restore();
    });
  }

  static void _group(
    Canvas canvas,
    MetalGlowFrame frame,
    Rect box,
    double ratio,
    bool dark,
    bool small,
    void Function() draw,
  ) {
    if (frame.envelope <= 0.002 || (frame.haloOpacity <= 0.002 && frame.extraOpacity <= 0.002)) return;
    final paint = Paint();
    if (dark) {
      paint.color = Color.from(alpha: 0.7 * frame.envelope, red: 0, green: 0, blue: 0);
    } else {
      // The web's light theme: saturate + brightness filter, multiplied in.
      paint
        ..color = Color.from(alpha: 0.2746 * frame.envelope, red: 0, green: 0, blue: 0)
        ..blendMode = BlendMode.multiply
        ..colorFilter = ColorFilter.matrix(_saturateBrightness(small ? 7.5 : 5.355, small ? 0.6 : 0.78));
    }
    canvas.saveLayer(box.inflate(overflow(ratio)), paint);
    draw();
    canvas.restore();
  }

  static void _sprites(Canvas canvas, MetalGlowFrame frame, double ratio, double dpr, double mul) {
    final halo = _bake(true, math.max(1, MetalGlowConfig.haloHalfLen * ratio), dpr);
    final extra = _bake(false, math.max(0.6, MetalGlowConfig.extraHalfLen * ratio), dpr);
    void draw(_Sprite sp, Offset at, double opacity, Color tint) {
      if (opacity <= 0.002) return;
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        ..rotate(frame.tangent);
      canvas.drawImageRect(
        sp.image,
        Rect.fromLTWH(0, 0, sp.image.width.toDouble(), sp.image.height.toDouble()),
        Rect.fromLTWH(-sp.ax, -sp.ay, sp.width, sp.height),
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Color.from(alpha: opacity * mul, red: 0, green: 0, blue: 0)
          ..colorFilter = ColorFilter.mode(tint, BlendMode.modulate),
      );
      canvas.restore();
    }

    draw(halo, frame.position, frame.haloOpacity, frame.haloTint);
    draw(extra, frame.extraPosition, frame.extraOpacity, frame.extraTint);
  }

  /// CSS `saturate(s) brightness(b)` as a colour matrix.
  static List<double> _saturateBrightness(double s, double b) => [
    (0.213 + 0.787 * s) * b, (0.715 - 0.715 * s) * b, (0.072 - 0.072 * s) * b, 0, 0, //
    (0.213 - 0.213 * s) * b, (0.715 + 0.285 * s) * b, (0.072 - 0.072 * s) * b, 0, 0, //
    (0.213 - 0.213 * s) * b, (0.715 - 0.715 * s) * b, (0.072 + 0.928 * s) * b, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}
