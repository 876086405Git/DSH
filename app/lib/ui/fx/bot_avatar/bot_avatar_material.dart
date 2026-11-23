// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The per-texel materials: a small MATCAP (a lit sphere, one colour per
   normal) evaluated with the full material whenever the light or the view
   has moved a bin, then the texels are a bilinear lookup into it. 'plastic'
   is a glossy toy plastic; 'fabric' a plush pile under a studio light.
   A port of the author's plastic.ts (colour, matcaps, cap frame, rays). */

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'bot_avatar_form.dart';

typedef V3 = (double, double, double);

const _m = matcapM;
const conicStops = 24;

/// Light elevation off the screen plane.
const _el = 48 * math.pi / 180;
final _eXY = math.cos(_el), _eZ = math.sin(_el);

/* ── colour ────────────────────────────────────────────────────────── */

double _toLin(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

/// A colour's linear channels.
V3 linearColor(Color c) => (_toLin(c.r), _toLin(c.g), _toLin(c.b));

/* tone map (soft shoulder above 0.75, keeps hue) + sRGB encode, as a table */
const _toneN = 2048, _toneMax = 2.5, _toneScale = _toneN / _toneMax;
final Float32List _toneLut = () {
  final t = Float32List(_toneN);
  for (var i = 0; i < _toneN; i++) {
    final v = (i + 0.5) / _toneScale;
    final y = v <= 0.75 ? v : 0.75 + 0.25 * (1 - math.exp(-(v - 0.75) / 0.25));
    t[i] = 255 * (y <= 0.0031308 ? 12.92 * y : 1.055 * math.pow(y, 1 / 2.4) - 0.055);
  }
  return t;
}();
double _tone(double v) => _toneLut[v <= 0 ? 0 : (v >= _toneMax ? _toneN - 1 : (v * _toneScale).floor())];

/// Linear to 0–255 sRGB, no shoulder.
double srgb(double v) =>
    v <= 0 ? 0 : (v >= 1 ? 255 : 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055));

/* x^e over x ∈ [0, 1], as a table, cached by exponent */
const powN = 1024;
final _powLuts = <double, Float32List>{};
Float32List powLut(double e) {
  return _powLuts.putIfAbsent(e, () {
    final t = Float32List(powN + 1);
    for (var i = 0; i <= powN; i++) {
      t[i] = math.pow(i / powN, e).toDouble();
    }
    return t;
  });
}

double smoothstep(double a, double b, double v) {
  final t = v <= a ? 0.0 : (v >= b ? 1.0 : (v - a) / (b - a));
  return t * t * (3 - 2 * t);
}

/* 1 inside |x| < w, falling to 0 over ±s around it */
double _soft(double w, double s, double x) => 1 - smoothstep(w - s, w + s, x);

V3 norm3(V3 v) {
  var l = math.sqrt(v.$1 * v.$1 + v.$2 * v.$2 + v.$3 * v.$3);
  if (l == 0) l = 1;
  return (v.$1 / l, v.$2 / l, v.$3 / l);
}

/// The material's knobs.
class Material {
  const Material({
    required this.shadow,
    required this.highlight,
    required this.spread,
    required this.rim,
    this.vivid = 0,
    this.front = keyEl,
    this.shine = 0,
    this.backSoft = 1,
    this.sheen = 0,
  });

  final double shadow;
  final double highlight;
  final double spread;
  final double rim;

  /// 0–1: how much colour the light keeps past the palette's full saturation
  final double vivid;

  /// fabric: how far round to the front the key sits, radians
  final double front;

  /// fabric: the light along single fibres
  final double shine;

  /// fabric: 0–1, how soft the back light is
  final double backSoft;

  /// fabric: the smooth satin light over the body's edge
  final double sheen;

  @override
  bool operator ==(Object other) =>
      other is Material &&
      other.shadow == shadow &&
      other.highlight == highlight &&
      other.spread == spread &&
      other.rim == rim &&
      other.vivid == vivid &&
      other.front == front &&
      other.shine == shine &&
      other.backSoft == backSoft &&
      other.sheen == sheen;

  @override
  int get hashCode => Object.hash(shadow, highlight, spread, rim, vivid, front, shine, backSoft, sheen);
}

/* More colour than a fully saturated palette colour has: the light's own mixes
   pulled away from grey about their luminance, as far as the gamut allows. */
V3 _vivify(V3 c, double v, [double cap = double.infinity]) {
  if (!(v > 0)) return c;
  final y = 0.2126 * c.$1 + 0.7152 * c.$2 + 0.0722 * c.$3;
  final mn = math.min(c.$1, math.min(c.$2, c.$3)), mx = math.max(c.$1, math.max(c.$2, c.$3));
  var k = 1 + 3 * v;
  if (mn < y) k = math.min(k, y / (y - mn));
  if (mx > y) k = math.min(k, math.max(1, (cap - y) / (mx - y)));
  return (y + (c.$1 - y) * k, y + (c.$2 - y) * k, y + (c.$3 - y) * k);
}

/// Light and view in the cap's own frame.
class Frame {
  const Frame(this.l, this.v, this.h, this.u, this.w, this.a, this.b, this.d, this.k);
  final V3 l;
  final V3 v;
  final V3 h;
  final V3 u;
  final V3 w;
  final V3 a;
  final V3 b;

  /// down on screen: toward the floor
  final V3 d;

  /// toward the back light on screen
  final V3 k;
}

const _env = (0.92, 0.96, 1.0);
const _warm = (1.0, 0.98, 0.95);

double _dot(double x, double y, double z, V3 v) => x * v.$1 + y * v.$2 + z * v.$3;

/// Fill `out` (m × m × rgb, sRGB 0–255) with the lit sphere for body colour `c` (linear).
void buildMatcap(Float32List out, V3 c, Frame f, Material p) {
  final vivid = p.vivid;
  final mx = math.max(math.max(c.$1, c.$2), math.max(c.$3, 0.05));
  final tint = (c.$1 / mx, c.$2 / mx, c.$3 / mx);
  final amb = math.max(0.03, 0.30 - 0.15 * p.shadow);
  final wrap = 0.15 + 0.14 * p.spread;
  const kd = 0.85;
  final e1 = math.min(90, (110 / math.pow(p.spread, 1.3)).round()), e2 = math.max(2, (8 / p.spread).round());
  final lut1 = powLut(e1.toDouble()), lut2 = powLut(e2.toDouble());
  final ks1 = 0.45 * p.highlight, ks2 = 0.10 * p.highlight, winK = 0.11 * p.highlight, rimK = 0.30 * p.rim;
  final ambT = (amb * tint.$1, amb * tint.$2, amb * tint.$3);
  final vv = f.v;
  for (var j = 0; j < _m; j++) {
    for (var i = 0; i < _m; i++) {
      var nx = (i / (_m - 1)) * 2 - 1, ny = (j / (_m - 1)) * 2 - 1;
      var r2 = nx * nx + ny * ny;
      if (r2 > 1.14) continue;
      if (r2 > 1) {
        final s = 1 / math.sqrt(r2);
        nx *= s;
        ny *= s;
        r2 = 1;
      }
      final nz = math.sqrt(1 - r2);
      final nl = _dot(nx, ny, nz, f.l);
      final nv = math.max(0.0, _dot(nx, ny, nz, vv));
      final nh = math.max(0.0, _dot(nx, ny, nz, f.h));
      final dif = ((nl + wrap) / (1 + wrap)).clamp(0.0, 1.0);
      final q = 1 - nv, q2 = q * q, f3 = q2 * q, f5 = f3 * q2;
      final ni = (nh * powN).floor();
      final spec = (ks1 * lut1[ni] + ks2 * lut2[ni]) * (1 + 3 * f5);
      /* the mirror direction: sky/floor gradient and the window */
      final rx = 2 * nv * nx - vv.$1, ry = 2 * nv * ny - vv.$2, rz = 2 * nv * nz - vv.$3;
      final sky = 0.45 + 0.55 * smoothstep(-0.4, 0.6, _dot(rx, ry, rz, f.u));
      final rw = _dot(rx, ry, rz, f.w);
      var win = 0.0;
      if (rw > 0.5) {
        final ra = _dot(rx, ry, rz, f.a) / rw, rb = _dot(rx, ry, rz, f.b) / rw;
        win = _soft(0.34, 0.12, ra.abs()) * _soft(0.12, 0.06, rb.abs());
      }
      final env = rimK * f3 * sky + winK * win;
      final k = (j * _m + i) * 3;
      /* the body's own light only: a clear coat's reflections stay white */
      final px = _vivify((
        c.$1 * (ambT.$1 + kd * dif),
        c.$2 * (ambT.$2 + kd * dif),
        c.$3 * (ambT.$3 + kd * dif),
      ), vivid);
      out[k] = _tone(px.$1 + spec * _warm.$1 + env * _env.$1);
      out[k + 1] = _tone(px.$2 + spec * _warm.$2 + env * _env.$2);
      out[k + 2] = _tone(px.$3 + spec * _warm.$3 + env * _env.$3);
    }
  }
}

/* The pile's two lights: the key lower than plastic's, from further round the
   side; the back light behind the toy, above it and away from the key. */
const keyEl = 32 * math.pi / 180;
V3 fabricKey(V3 u, V3 v, [double front = keyEl]) {
  final c = math.cos(front), s = math.sin(front);
  return norm3((u.$1 * c + v.$1 * s, u.$2 * c + v.$2 * s, u.$3 * c + v.$3 * s));
}

V3 fabricBack(V3 k, V3 v) => norm3((0.94 * k.$1 - 0.34 * v.$1, 0.94 * k.$2 - 0.34 * v.$2, 0.94 * k.$3 - 0.34 * v.$3));

/// Where the back light is on screen by default, as a unit vector (y down)
/// from the key's (lx, ly): above the toy and toward the side away from the key.
(double, double) backFromKey(double lx, double ly) {
  final x = -0.5 * lx, y = -0.5 * ly - 0.87;
  var l = math.sqrt(x * x + y * y);
  if (l == 0) l = 1;
  return (x / l, y / l);
}

/// The lit sphere for the pile, as a studio photograph of a plush toy lights
/// it: a clear key with a readable terminator, the shade deepened rather than
/// greyed, a saturated band at the terminator, and a back light along the
/// silhouette. No specular lobe — fur has no clear coat.
void buildFabricMatcap(Float32List out, V3 c, Frame f, Material p) {
  final v = f.v, u = f.u, d = f.d;
  final vivid = p.vivid;
  final l = fabricKey(u, v, p.front);
  final lb = fabricBack(f.k, v);
  final amb = math.max(0.03, 0.2 - 0.15 * p.shadow);
  final fillK = math.max(0.04, 0.24 - 0.13 * p.shadow);
  final wrap = math.min(0.7, 0.05 + 0.12 * p.spread);
  const kd = 1.3;
  final floorK = 0.34 * math.min(1.6, p.shadow / 0.35);
  final fl = norm3((
    -0.55 * u.$1 + 0.85 * v.$1 + 0.15 * d.$1,
    -0.55 * u.$2 + 0.85 * v.$2 + 0.15 * d.$2,
    -0.55 * u.$3 + 0.85 * v.$3 + 0.15 * d.$3,
  ));
  final satin = p.sheen;
  final backSoft = p.backSoft.clamp(0.0, 1.0);
  final sheenK = 0.16 * p.highlight * satin, rimK = 1.15 * p.rim * satin, sssK = 0.2 + 0.25 * vivid;
  final mx = math.max(math.max(c.$1, c.$2), math.max(c.$3, 0.02));
  final cb = [c.$1 / mx, c.$2 / mx, c.$3 / mx];
  final cc = [c.$1, c.$2, c.$3];
  final wR = 0.45 * (1 - vivid), wS = 0.25 * (1 - vivid);
  final rimOut = [for (final x in cb) wR + (1 - wR) * x];
  final sheenC = [for (final x in cb) wS + (1 - wS) * x];
  double yOf(List<double> q) => 0.2126 * q[0] + 0.7152 * q[1] + 0.0722 * q[2];
  final de = 1.8 + 2.2 * vivid;
  final d0 = [for (final x in cc) math.pow(x, de).toDouble()];
  final dk = yOf(cc) / math.max(1e-4, yOf(d0));
  final deep = [for (final x in d0) x * dk];
  final sc = [for (var i = 0; i < 3; i++) cb[i] * cb[i] * cc[i]];
  final ch = [0.0, 0.0, 0.0];
  for (var j = 0; j < _m; j++) {
    for (var i = 0; i < _m; i++) {
      var nx = (i / (_m - 1)) * 2 - 1, ny = (j / (_m - 1)) * 2 - 1;
      var r2 = nx * nx + ny * ny;
      if (r2 > 1.14) continue;
      if (r2 > 1) {
        final s = 1 / math.sqrt(r2);
        nx *= s;
        ny *= s;
        r2 = 1;
      }
      final nz = math.sqrt(1 - r2);
      final nl = _dot(nx, ny, nz, l);
      final nv = math.max(0.0, _dot(nx, ny, nz, v));
      final nd = _dot(nx, ny, nz, d);
      final nb = _dot(nx, ny, nz, lb);
      final q = 1 - nv;
      final w = wrap + (0.45 - wrap) * q * q;
      var dif = ((nl + w) / (1 + w)).clamp(0.0, 1.0);
      dif = math.pow(dif, 1.35).toDouble();
      final fill = fillK * math.max(0.0, _dot(nx, ny, nz, fl));
      final floor = 1 - floorK * math.max(0.0, nd) * (0.6 + 0.4 * q);
      final light = (amb + kd * dif + fill) * floor;
      /* toward the shade the colour deepens rather than greys */
      final t = (1 - light).clamp(0.0, 1.0);
      final sb = math.max(0.0, 1 - ((nl + 0.08) * (nl + 0.08)) / 0.18);
      final sss = sssK * sb * sb * floor;
      final lit = ((nl + 0.2) / 0.8).clamp(0.0, 1.0);
      final sheen = sheenK * q * q * lit;
      final bl = smoothstep(-0.3, 0.6, nb);
      final rq = smoothstep(0.18 - 0.12 * backSoft, 0.62 + 0.18 * backSoft, q);
      final rim = rimK * rq * math.sqrt(rq) * (0.3 + 0.7 * bl) * (1 - 0.7 * math.max(0.0, nd));
      final hot = rq * rq * math.sqrt(rq) * (1 - 0.5 * backSoft);
      for (var k = 0; k < 3; k++) {
        final base = cc[k] + (deep[k] - cc[k]) * t * 0.9;
        ch[k] = base * light + sss * sc[k] + sheen * sheenC[k] + rim * (cb[k] + (rimOut[k] - cb[k]) * hot);
      }
      /* bright parts roll off as a whole, not channel by channel */
      var r = ch[0], g = ch[1], b = ch[2];
      final m = math.max(r, math.max(g, b));
      if (m > 0.8) {
        final kk = (0.8 + 0.2 * (1 - math.exp(-(m - 0.8) / 0.2))) / m;
        r *= kk;
        g *= kk;
        b *= kk;
      }
      if (vivid > 0) (r, g, b) = _vivify((r, g, b), vivid, 1);
      final o = (j * _m + i) * 3;
      out[o] = srgb(r);
      out[o + 1] = srgb(g);
      out[o + 2] = srgb(b);
    }
  }
}

/// The rig's numbers the material needs for one frame.
class CapRig {
  const CapRig({
    required this.cy,
    required this.sy,
    required this.cp,
    required this.sp,
    required this.facing,
    required this.roll,
    required this.lx,
    required this.ly,
    this.bx,
    this.by,
  });

  /// the rig's (floored) cos/sin of yaw and pitch, as used by the slice affines
  final double cy;
  final double sy;
  final double cp;
  final double sp;

  /// cos(yaw)·cos(pitch), unfloored: the front faces the viewer while positive
  final double facing;
  final double roll;

  /// unit vector toward the light on screen
  final double lx;
  final double ly;

  /// unit vector toward the back light on screen (fabric); from the key's when null
  final double? bx;
  final double? by;
}

/// Screen-space vectors into the cap's frame: un-roll, then the transpose of
/// the rig's rotation; the back is the front mirrored in z.
Frame capFrame(CapRig r) {
  final cr = math.cos(r.roll), sr = math.sin(r.roll);
  final lx = cr * r.lx + sr * r.ly, ly = -sr * r.lx + cr * r.ly;
  final mirror = r.facing < 0 ? -1.0 : 1.0;
  /* the flip passes through edge-on: fade the mirrored component */
  final zf = mirror * math.min(1.0, r.facing.abs() / 0.16);
  final cy = r.cy, sy = r.sy, cp = r.cp, sp = r.sp;
  V3 local(double x, double y, double z, double zk) =>
      norm3((cy * x + sy * sp * y - sy * cp * z, cp * y + sp * z, zk * (sy * x - cy * sp * y + cy * cp * z)));
  final l = local(_eXY * lx, _eXY * ly, _eZ, zf);
  final v = local(0, 0, 1, mirror);
  final h = norm3((l.$1 + v.$1, l.$2 + v.$2, l.$3 + v.$3));
  final u = local(lx, ly, 0, mirror);
  /* the window: 80° round from the light, 34° off the view axis */
  final cw = math.cos(80 * math.pi / 180), sw = math.sin(80 * math.pi / 180);
  final wx = cw * lx - sw * ly, wy = sw * lx + cw * ly;
  final ws = norm3((0.55 * wx, 0.55 * wy, 0.83));
  final as_ = norm3((ws.$2, -ws.$1, 0));
  final bs = (ws.$2 * as_.$3 - ws.$3 * as_.$2, ws.$3 * as_.$1 - ws.$1 * as_.$3, ws.$1 * as_.$2 - ws.$2 * as_.$1);
  final w = local(ws.$1, ws.$2, ws.$3, mirror);
  final a = local(as_.$1, as_.$2, as_.$3, mirror);
  final b = local(bs.$1, bs.$2, bs.$3, mirror);
  /* screen down, un-rolled the same way as the light */
  final d = local(sr, cr, 0, mirror);
  final (kx0, ky0) = r.bx != null && r.by != null ? (r.bx!, r.by!) : backFromKey(r.lx, r.ly);
  final k = local(cr * kx0 + sr * ky0, -sr * kx0 + cr * ky0, 0, mirror);
  return Frame(l, v, h, u, w, a, b, d, k);
}

/// How wide the front's texture fades out toward the outline, in design units.
const frontFade = 5.0;

/// Shade unpremultiplied ARGB texels for both the vertex mesh and the side rays.
/// `lift` (fabric) multiplies in when given.
void shadeTexels(BotAvatarForm form, Float32List mc, Int32List argb, Float32List aoMul, Lift? lift) {
  final n = form.n, i00 = form.i00, wx = form.wx, wy = form.wy, ao = form.ao, sd = form.sd;
  const r3 = _m * 3;
  for (var i = 0; i < n * n; i++) {
    final a = ao[i];
    if (a == 0) {
      argb[i] = 0;
      continue;
    }
    var m = lift != null ? aoMul[lift.ao[i]] * lift.k[i] : aoMul[a];
    final b = i00[i] * 3, x = wx[i] * (1 / 255), y = wy[i] * (1 / 255);
    if (lift != null) {
      /* the occlusion is the room's light hidden by the form, not the key's:
         where the matcap is lit by the key it takes less of it */
      final g = (mc[b + 1] * (1 - x) + mc[b + 4] * x) * (1 - y) + (mc[b + r3 + 1] * (1 - x) + mc[b + r3 + 4] * x) * y;
      m = 1 - (1 - m) * (1.1 - 0.75 * math.min(1.0, g / 235));
    }
    final w00 = (1 - x) * (1 - y) * m, w10 = x * (1 - y) * m, w01 = (1 - x) * y * m, w11 = x * y * m;
    final rr = (mc[b] * w00 + mc[b + 3] * w10 + mc[b + r3] * w01 + mc[b + r3 + 3] * w11).round().clamp(0, 255);
    final gg = (mc[b + 1] * w00 + mc[b + 4] * w10 + mc[b + r3 + 1] * w01 + mc[b + r3 + 4] * w11).round().clamp(0, 255);
    final bb = (mc[b + 2] * w00 + mc[b + 5] * w10 + mc[b + r3 + 2] * w01 + mc[b + r3 + 5] * w11).round().clamp(0, 255);
    final t = sd[i] / frontFade;
    final al = t >= 1 ? 255 : (t <= 0 ? 0 : (255 * t * t * (3 - 2 * t)).round());
    argb[i] = (al << 24) | (rr << 16) | (gg << 8) | bb;
  }
}

/// The front's colour along 24 rays out from a centre, sampled every half
/// unit with how far each sample is from the outline.
class Rays {
  Rays(this.d, this.c);
  final List<Float32List> d;
  final List<Uint8List> c;
}

Rays raysOf(Int32List argb, BotAvatarForm form, double c0x, double c0y) {
  final n = form.n, sd = form.sd;
  double toG(double v) => ((v + pad) / span) * n - 0.5;
  final dOut = <Float32List>[], cOut = <Uint8List>[];
  for (var s = 0; s < conicStops; s++) {
    final phi = (s / conicStops) * math.pi * 2, ux = math.cos(phi), uy = math.sin(phi);
    final ds = <double>[], cs = <int>[];
    for (var r = 0.0; r < 80; r += 0.5) {
      final x = c0x + ux * r, y = c0y + uy * r;
      final d = bilerp(sd, n, toG(x), toG(y));
      if (d < 0) break;
      final gx = toG(x).round(), gy = toG(y).round();
      if (gx < 0 || gy < 0 || gx >= n || gy >= n) break;
      final color = argb[gy * n + gx];
      ds.add(d);
      cs.addAll([(color >>> 16) & 255, (color >>> 8) & 255, color & 255]);
    }
    dOut.add(Float32List.fromList(ds));
    cOut.add(Uint8List.fromList(cs));
  }
  return Rays(dOut, cOut);
}

/// One slice's side light: every ray's colour at `inset` from the outline,
/// darkened by `dark`, as the 25 stops of a sweep round the centre.
List<Color> sliceColors(Rays rays, double Function(int) inset, double Function(int) dark) {
  Color at(int s) {
    final d = rays.d[s], c = rays.c[s];
    final ins = inset(s), k = 1 - dark(s);
    var j = 0;
    for (var i = d.length - 1; i >= 0; i--) {
      if (d[i] >= ins) {
        j = i;
        break;
      }
    }
    if (c.isEmpty) return const Color(0xFF000000);
    return Color.fromARGB(255, (c[j * 3] * k).floor(), (c[j * 3 + 1] * k).floor(), (c[j * 3 + 2] * k).floor());
  }

  return [for (var s = 0; s <= conicStops; s++) at(s % conicStops)];
}

/// The front's brightest colour, where it faces the light, in steps of four.
(int, int, int) brightest(Rays rays) {
  var best = -1.0;
  var r = 0, g = 0, b = 0;
  for (final c in rays.c) {
    for (var i = 0; i < c.length; i += 3) {
      final l = 0.2126 * c[i] + 0.7152 * c[i + 1] + 0.0722 * c[i + 2];
      if (l > best) {
        best = l;
        r = c[i];
        g = c[i + 1];
        b = c[i + 2];
      }
    }
  }
  int q(int v) => math.min(255, (v / 4).round() * 4);
  return (q(r), q(g), q(b));
}

/// The halo's lit tips: the front's brightest colour, and toward the back
/// light's own through the dyed fibres as far as `rim` says.
Color hazeColor(Rays rays, Color base, double rim, double vivid) {
  final (br, bg, bb) = brightest(rays);
  final lin = linearColor(base);
  final e = [srgb(lin.$1), srgb(lin.$2), srgb(lin.$3)];
  final mx = math.max(math.max(e[0], e[1]), math.max(e[2], 1));
  final k = math.min(0.85, 0.75 * rim);
  final pale = 0.45 + 0.55 * math.min(1, vivid);
  final b = [br, bg, bb];
  int q(int i) => (b[i] + (255 + ((255 * e[i]) / mx - 255) * pale - b[i]) * k).round().clamp(0, 255);
  return Color.fromARGB(255, q(0), q(1), q(2));
}
