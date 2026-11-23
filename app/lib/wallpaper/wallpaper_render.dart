// 壁纸烘焙：解码一次（按屏幕需要的尺寸，动图只取首帧）→ 取景、模糊画进一张屏幕大小的位图 →
// 逐格量背景亮度，算出每格最少要叠多少页面色才让字够清楚（wallpaper_look.dart）→ 扩散、
// 抹匀成一张小遮罩 → 和用户的提亮 / 压暗取大，叠上去，得到最终一张位图。
//
// 每帧只画这一张图：没有实时 BackdropFilter，也不再解码。越模糊烘得越小（模糊本来就不需要
// 细节），轻量档（低端机、过热、用户选了轻量）模糊减半、封顶，按每 dp 一个像素烘。
//
// 用户关掉「自动保证文字清晰」（CustomWallpaper.guard）：不量、不叠遮罩，只有模糊和提亮 / 压暗，
// 两个都是 0 就是原图；按屏幕自己的密度烘，轻量档也不降、模糊也不折减。正在播放的动图
// （wallpaper_frames.dart）垫在底下的那张首帧同样不叠遮罩，和它的每一帧一个样。

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'custom_wallpaper.dart';
import 'wallpaper_frames.dart';
import 'wallpaper_look.dart';

/// One screen in one mode: what a wallpaper is baked for.
@immutable
class WallpaperFrame {
  const WallpaperFrame({
    required this.size,
    required this.pixelRatio,
    required this.look,
    this.top = 0,
    this.bottom = 0,
    this.lightweight = false,
    this.motion = false,
  });

  /// The screen, in dp.
  final Size size;
  final double pixelRatio;
  final WallpaperLook look;

  /// The bars over the picture, in dp: the status bar and the chat's header ([top]); the
  /// composer and the navigation bar ([bottom]). They get [WallpaperLook.edgeBound].
  final double top;
  final double bottom;

  /// The performance profile's lightweight mode: less blur, fewer pixels.
  final bool lightweight;

  /// An animated picture may play here (motion isn't reduced).
  final bool motion;

  /// Whether [wallpaper] is an animation this device could play: one whose frames are too
  /// large to keep decoding isn't ([WallpaperBake.motionSide]).
  bool playable(CustomWallpaper wallpaper) =>
      wallpaper.animated && math.max(wallpaper.width, wallpaper.height) <= WallpaperBake.motionSideFor(lightweight);

  /// Whether [wallpaper] plays on this screen rather than showing its first frame.
  bool plays(CustomWallpaper wallpaper) => motion && wallpaper.play && playable(wallpaper);

  WallpaperFrame copyWith({WallpaperLook? look, bool? lightweight}) => WallpaperFrame(
    size: size,
    pixelRatio: pixelRatio,
    look: look ?? this.look,
    top: top,
    bottom: bottom,
    lightweight: lightweight ?? this.lightweight,
    motion: motion,
  );

  @override
  bool operator ==(Object other) =>
      other is WallpaperFrame &&
      other.size == size &&
      other.pixelRatio == pixelRatio &&
      other.look == look &&
      other.top == top &&
      other.bottom == bottom &&
      other.lightweight == lightweight &&
      other.motion == motion;

  @override
  int get hashCode => Object.hash(size, pixelRatio, look, top, bottom, lightweight, motion);
}

/// The numbers of a bake.
abstract final class WallpaperBake {
  /// The contrast map's cells, in dp.
  static const cell = 8.0;

  /// How far (in cells) a cell's need spreads before it's smoothed; the smoothing reaches as far.
  static const spread = 6;

  /// The softest blur (σ, dp), at the slider's end.
  static const maxSigma = 36.0;

  /// Lightweight mode: half the blur, at most this σ (dp).
  static const lightSigma = 12.0;

  /// Pixels per dp: at most the screen's own up to [maxDensity]; [lightDensity] when lightweight.
  static const maxDensity = 3.0;
  static const lightDensity = 1.0;

  /// The most the tone sliders lay over the picture (at 100%).
  static const maxTone = 0.8;

  /// Pictures are decoded no larger than this on the long side ([lightDecodeSide] when
  /// lightweight).
  static const decodeSide = 4096;
  static const lightDecodeSide = 2048;

  /// A playing animation decodes every frame, and the engine decodes an animation's frames at
  /// their own size whatever it is asked for. So one longer than this on a side doesn't play
  /// ([lightMotionSide] when lightweight): its first frame is baked like any still.
  static const motionSide = 2048;
  static const lightMotionSide = 1280;

  static int motionSideFor(bool lightweight) => lightweight ? lightMotionSide : motionSide;

  /// σ in dp for a blur setting.
  static double sigmaFor(double blur, {bool lightweight = false}) {
    final sigma = blur.clamp(0.0, 1.0) * maxSigma;
    return lightweight ? math.min(sigma * 0.5, lightSigma) : sigma;
  }

  /// σ in dp for [w] on [frame]. Unguarded it is the slider's own, whatever the profile: the
  /// picture is promised to be exactly what the sliders say.
  static double sigmaOf(CustomWallpaper w, WallpaperFrame frame) =>
      sigmaFor(w.blur, lightweight: frame.lightweight && w.guard);

  /// Pixels per dp for [frame] at blur [sigma] ([densityAt]). [exact]: from the screen's own
  /// density, whatever the profile.
  static double densityFor(WallpaperFrame frame, double sigma, {bool exact = false}) {
    final k = exact ? frame.pixelRatio : math.min(frame.pixelRatio, frame.lightweight ? lightDensity : maxDensity);
    return densityAt(k, sigma);
  }

  /// [k] pixels per dp, or fewer under a blur: past σ 6 a picture loses nothing at a lower
  /// resolution, so it bakes smaller (never under 0.75 px per dp for that reason).
  static double densityAt(double k, double sigma) => sigma <= 6 ? k : math.min(k, math.max(0.75, k * 6 / sigma));

  /// What a playing [w] decodes its frames from: the file as it is ([WallpaperFrame.plays]
  /// has seen to its size).
  static FrameSource motionSource(CustomWallpaper w) =>
      FrameSource(path: w.path, coverWidth: w.width, coverHeight: w.height, maxSide: motionSide);
}

/// Bakes wallpapers, one at a time, keeping the last decoded picture for the next bake.
class WallpaperRenderer {
  _Decoded? _source;
  Future<void> _queue = Future<void>.value();

  /// How many times a picture was decoded, and how many bakes were asked for (tests).
  @visibleForTesting
  int decodes = 0;
  @visibleForTesting
  int bakes = 0;

  /// [wallpaper] baked for [frame] ([density] pixels per dp, else [WallpaperBake.densityFor]);
  /// null when the picture can't be read. The caller owns the image. [moving]: the still under
  /// a playing animation, which gets no veil since its frames get none.
  Future<ui.Image?> bake(CustomWallpaper wallpaper, WallpaperFrame frame, {double? density, bool moving = false}) {
    bakes++;
    final done = Completer<ui.Image?>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await _bake(wallpaper, frame, density, moving));
      } catch (error) {
        debugPrint('wallpaper: bake failed: $error');
        done.complete(null);
      }
    });
    return done.future;
  }

  /// Drops the decoded picture.
  void release() {
    _source?.image.dispose();
    _source = null;
  }

  Future<ui.Image?> _bake(CustomWallpaper w, WallpaperFrame frame, double? density, bool moving) async {
    if (frame.size.isEmpty) return null;
    final sigma = WallpaperBake.sigmaOf(w, frame);
    // Unguarded, nothing may soften the picture but its own blur: the lightweight profile's
    // fewer pixels would.
    final exact = !w.guard && !moving;
    final k = density ?? WallpaperBake.densityFor(frame, sigma, exact: exact);
    final outW = math.max(1, (frame.size.width * k).round());
    final outH = math.max(1, (frame.size.height * k).round());
    final source = await _decode(w, frame, outW, exact);
    if (source == null) return null;
    final look = frame.look;
    final tone = w.toneFor(look.brightness).clamp(0.0, 1.0) * WallpaperBake.maxTone;
    if (!w.guard || moving) return _soften(source, w, frame, outW, outH, sigma * k, tone: tone);
    final soft = await _soften(source, w, frame, outW, outH, sigma * k);
    try {
      final data = await soft.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final request = VeilRequest(
        rgba: data.buffer.asUint8List(),
        width: outW,
        height: outH,
        cellPx: math.max(2, (WallpaperBake.cell * k).round()),
        dark: look.dark,
        bound: look.bound,
        edgeBound: look.edgeBound,
        topPx: (frame.top * k).ceil(),
        bottomPx: (frame.bottom * k).ceil(),
        veilTop: _rgb(look.veilTop),
        veilBottom: _rgb(look.veilBottom),
        lift: look.lift,
        user: tone,
      );
      // Large bakes measure off the UI thread.
      final alpha = outW * outH > 1 << 17 ? await compute(veilAlpha, request) : veilAlpha(request);
      final mask = await _maskImage(alpha, request.cols, request.rows);
      try {
        return await _compose(soft, mask, request, look);
      } finally {
        mask.dispose();
      }
    } finally {
      soft.dispose();
    }
  }

  /// The picture's first frame, decoded only as large as [outW] across the screen needs.
  Future<ui.Image?> _decode(CustomWallpaper w, WallpaperFrame frame, int outW, bool exact) async {
    final cap = frame.lightweight && !exact ? WallpaperBake.lightDecodeSide : WallpaperBake.decodeSide;
    int target(int iw, int ih) {
      final window = w.windowIn(Size(iw.toDouble(), ih.toDouble()), frame.size);
      final scale = math.min(1.0, math.min(outW / window.width, cap / math.max(iw, ih)));
      return math.max(1, (iw * scale).round());
    }

    final cached = _source;
    if (cached != null && cached.path == w.path) {
      if (cached.image.width + 1 >= target(cached.intrinsicWidth, cached.intrinsicHeight)) return cached.image;
    }
    ui.Codec? codec;
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(w.path);
      var iw = 0, ih = 0;
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          iw = width;
          ih = height;
          final tw = target(width, height);
          return ui.TargetImageSize(width: tw, height: math.max(1, (height * tw / width).round()));
        },
      );
      // An animation: its first frame only.
      final image = (await codec.getNextFrame()).image;
      decodes++;
      release();
      _source = _Decoded(w.path, image, iw, ih);
      return image;
    } catch (error) {
      debugPrint('wallpaper: unreadable: $error');
      return null;
    } finally {
      codec?.dispose();
    }
  }

  /// The screen's part of [source], blurred to [sigmaPx], on the page's own gradient (a
  /// see-through picture shows the page, not black), then [tone] of that gradient evenly over it.
  static Future<ui.Image> _soften(
    ui.Image source,
    CustomWallpaper w,
    WallpaperFrame frame,
    int outW,
    int outH,
    double sigmaPx, {
    double tone = 0,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final out = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
    canvas.drawRect(out, Paint()..shader = _veilShader(frame.look, out));
    final bounds = Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble());
    final window = w.windowIn(bounds.size, frame.size);
    final scale = outW / window.width;
    // Past the screen's edges the blur takes the picture itself, where there is more of it.
    final src = sigmaPx > 0 ? window.inflate(3 * sigmaPx / scale).intersect(bounds) : window;
    final dst = Rect.fromLTRB(
      (src.left - window.left) * scale,
      (src.top - window.top) * scale,
      (src.right - window.left) * scale,
      (src.bottom - window.top) * scale,
    );
    final paint = Paint()..filterQuality = FilterQuality.high;
    // Blurred as it's drawn: the filter sees the whole drawn piece, past the screen's edges, and
    // stretches the picture's own last pixels where it ends.
    if (sigmaPx > 0) paint.imageFilter = ui.ImageFilter.blur(sigmaX: sigmaPx, sigmaY: sigmaPx);
    canvas.drawImageRect(source, src, dst, paint);
    if (tone > 0) {
      canvas.drawRect(
        out,
        Paint()
          ..shader = _veilShader(frame.look, out)
          ..color = Color.fromRGBO(0, 0, 0, tone),
      );
    }
    final recording = recorder.endRecording();
    try {
      return await recording.toImage(outW, outH);
    } finally {
      recording.dispose();
    }
  }

  /// [soft] with the page's gradient laid over it through [mask] (one texel a cell, stretched
  /// smoothly over the cells).
  static Future<ui.Image> _compose(ui.Image soft, ui.Image mask, VeilRequest r, WallpaperLook look) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final out = Rect.fromLTWH(0, 0, r.width.toDouble(), r.height.toDouble());
    canvas
      ..drawImage(soft, Offset.zero, Paint())
      ..saveLayer(out, Paint())
      ..drawRect(out, Paint()..shader = _veilShader(look, out))
      ..drawImageRect(
        mask,
        Rect.fromLTWH(0, 0, r.cols.toDouble(), r.rows.toDouble()),
        Rect.fromLTWH(0, 0, (r.cols * r.cellPx).toDouble(), (r.rows * r.cellPx).toDouble()),
        Paint()
          ..blendMode = BlendMode.dstIn
          ..filterQuality = FilterQuality.low,
      )
      ..restore();
    final recording = recorder.endRecording();
    try {
      return await recording.toImage(r.width, r.height);
    } finally {
      recording.dispose();
    }
  }

  static Shader _veilShader(WallpaperLook look, Rect out) =>
      ui.Gradient.linear(out.topLeft, out.bottomLeft, [look.veilTop, look.veilBottom]);

  static Future<ui.Image> _maskImage(Uint8List alpha, int cols, int rows) async {
    final rgba = Uint8List(cols * rows * 4);
    for (var i = 0; i < alpha.length; i++) {
      final a = alpha[i];
      rgba
        ..[i * 4] = a
        ..[i * 4 + 1] = a
        ..[i * 4 + 2] = a
        ..[i * 4 + 3] = a;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(buffer, width: cols, height: rows, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  static List<double> _rgb(Color c) => [c.r, c.g, c.b];
}

class _Decoded {
  _Decoded(this.path, this.image, this.intrinsicWidth, this.intrinsicHeight);

  final String path;
  final ui.Image image;
  final int intrinsicWidth;
  final int intrinsicHeight;
}

/// What [veilAlpha] measures: a blurred, unveiled bake and the bounds it must meet.
class VeilRequest {
  const VeilRequest({
    required this.rgba,
    required this.width,
    required this.height,
    required this.cellPx,
    required this.dark,
    required this.bound,
    required this.edgeBound,
    required this.topPx,
    required this.bottomPx,
    required this.veilTop,
    required this.veilBottom,
    required this.user,
    this.lift = 0,
    this.spread = WallpaperBake.spread,
  });

  /// Opaque RGBA, [width] × [height].
  final Uint8List rgba;
  final int width;
  final int height;
  final int cellPx;
  final bool dark;
  final double bound;
  final double edgeBound;
  final int topPx;
  final int bottomPx;

  /// sRGB, 0–1.
  final List<double> veilTop;
  final List<double> veilBottom;

  /// The tone slider's own amount, 0–1.
  final double user;

  /// White laid over the result by the lightest surface text sits on ([WallpaperLook.lift]).
  final double lift;
  final int spread;

  int get cols => (width + cellPx - 1) ~/ cellPx;
  int get rows => (height + cellPx - 1) ~/ cellPx;
}

/// How much of the page's gradient each cell of the bake gets, 0–255 a cell (row-major).
///
/// A cell's need is the least that brings its worst pixel within the bound: per channel the
/// darkest (light mode) or lightest (dark mode) value in the cell is a colour no pixel there is
/// worse than, and laying more veil over it only helps. Needs spread [VeilRequest.spread] + 1
/// cells, then two box blurs reaching [VeilRequest.spread] between them smooth them: every
/// cell, and every point the stretched mask interpolates within it, keeps at least its own need.
Uint8List veilAlpha(VeilRequest r) {
  final cols = r.cols;
  final rows = r.rows;
  final n = cols * rows;
  final dark = r.dark;
  final start = dark ? 0 : 255;
  final wr = Uint8List(n)..fillRange(0, n, start);
  final wg = Uint8List(n)..fillRange(0, n, start);
  final wb = Uint8List(n)..fillRange(0, n, start);
  final px = r.rgba;
  final w = r.width;
  final cell = r.cellPx;
  for (var y = 0; y < r.height; y++) {
    final base = (y ~/ cell) * cols;
    var i = y * w * 4;
    for (var cx = 0; cx < cols; cx++) {
      final c = base + cx;
      var mr = wr[c], mg = wg[c], mb = wb[c];
      final end = math.min(w, (cx + 1) * cell);
      for (var x = cx * cell; x < end; x++, i += 4) {
        final pr = px[i], pg = px[i + 1], pb = px[i + 2];
        if (dark) {
          if (pr > mr) mr = pr;
          if (pg > mg) mg = pg;
          if (pb > mb) mb = pb;
        } else {
          if (pr < mr) mr = pr;
          if (pg < mg) mg = pg;
          if (pb < mb) mb = pb;
        }
      }
      wr[c] = mr;
      wg[c] = mg;
      wb[c] = mb;
    }
  }

  var need = Float64List(n);
  for (var row = 0; row < rows; row++) {
    final y0 = row * cell;
    final y1 = math.min(r.height, (row + 1) * cell);
    final edge = y0 < r.topPx || y1 > r.height - r.bottomPx;
    final limit = edge ? r.edgeBound : r.bound;
    // The veil's colour over this row: per channel its least favourable end.
    double veil(int ch) {
      final a = r.veilTop[ch] + (r.veilBottom[ch] - r.veilTop[ch]) * (y0 / r.height);
      final b = r.veilTop[ch] + (r.veilBottom[ch] - r.veilTop[ch]) * (y1 / r.height);
      return dark ? math.max(a, b) : math.min(a, b);
    }

    final vr = veil(0), vg = veil(1), vb = veil(2);
    for (var cx = 0; cx < cols; cx++) {
      final c = row * cols + cx;
      need[c] = _need(wr[c] / 255, wg[c] / 255, wb[c] / 255, vr, vg, vb, limit, dark, r.lift);
    }
  }

  need = _spreadMax(need, cols, rows, r.spread + 1);
  final first = r.spread ~/ 2;
  need = _boxBlur(need, cols, rows, first);
  need = _boxBlur(need, cols, rows, r.spread - first);

  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (math.max(need[i], r.user) * 255).ceil().clamp(0, 255);
  }
  return out;
}

/// The least veil [a] for which the colour (r, g, b) blended toward (vr, vg, vb), then under
/// [lift] of white, is within [limit]. Along the blend the luminance is convex, so the amounts that work are one interval
/// ending at 1 (the veil itself is within the limit).
double _need(double r, double g, double b, double vr, double vg, double vb, double limit, bool dark, double lift) {
  // Blended, then under the surface's white (which moves every channel up the same way).
  double up(double c) => c + (1 - c) * lift;
  bool ok(double a) {
    final l = _luminance(up(r + (vr - r) * a), up(g + (vg - g) * a), up(b + (vb - b) * a));
    return dark ? l <= limit : l >= limit;
  }

  if (ok(0)) return 0;
  if (!ok(1)) return 1;
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 18; i++) {
    final mid = (lo + hi) / 2;
    if (ok(mid)) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

double _luminance(double r, double g, double b) => 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b);

double _linear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

/// Each cell the largest value within [radius] cells (a square).
Float64List _spreadMax(Float64List v, int cols, int rows, int radius) {
  final across = Float64List(v.length);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      var m = 0.0;
      for (var dx = math.max(0, x - radius); dx <= math.min(cols - 1, x + radius); dx++) {
        m = math.max(m, v[y * cols + dx]);
      }
      across[y * cols + x] = m;
    }
  }
  final out = Float64List(v.length);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      var m = 0.0;
      for (var dy = math.max(0, y - radius); dy <= math.min(rows - 1, y + radius); dy++) {
        m = math.max(m, across[dy * cols + x]);
      }
      out[y * cols + x] = m;
    }
  }
  return out;
}

/// Each cell the mean of the cells within [radius] (a square, cut off at the edges).
Float64List _boxBlur(Float64List v, int cols, int rows, int radius) {
  if (radius <= 0) return v;
  final across = Float64List(v.length);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      var sum = 0.0;
      final lo = math.max(0, x - radius), hi = math.min(cols - 1, x + radius);
      for (var dx = lo; dx <= hi; dx++) {
        sum += v[y * cols + dx];
      }
      across[y * cols + x] = sum / (hi - lo + 1);
    }
  }
  final out = Float64List(v.length);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      var sum = 0.0;
      final lo = math.max(0, y - radius), hi = math.min(rows - 1, y + radius);
      for (var dy = lo; dy <= hi; dy++) {
        sum += across[dy * cols + x];
      }
      out[y * cols + x] = sum / (hi - lo + 1);
    }
  }
  return out;
}
