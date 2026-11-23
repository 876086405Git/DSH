// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The plastic and fabric body: the author's drawPlasticCap. The body is the
   form drawn as a relief — the far half's levels, the outline, the near
   half's levels, each the outline scaled to its level and filled with the
   side's light as a sweep — then the lit front laid over them (the texels,
   here a colour per vertex of a mesh over the texture grid). Fabric draws
   its slices into a layer of their own, lays the halo over the silhouette
   and the pile over the whole body as one film. */

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'bot_avatar_bakery.dart';
import 'bot_avatar_form.dart';
import 'bot_avatar_fur.dart';
import 'bot_avatar_material.dart';

/// One outline to draw as a solid.
class BotAvatarSolid {
  BotAvatarSolid(this.key, this.path, this.polys);

  /// names the outline for the material caches
  final String key;
  final ui.Path path;
  final List<Float64List> polys;
}

/// The rig's numbers for one frame of the material.
class PlasticRig {
  const PlasticRig({
    required this.cy,
    required this.sy,
    required this.cp,
    required this.sp,
    required this.facing,
    required this.roll,
    required this.halfDepth,
    required this.lx,
    required this.ly,
    required this.bx,
    required this.by,
    required this.box,
    required this.dpr,
    required this.ctm,
    required this.still,
    required this.round,
  });

  final double cy;
  final double sy;
  final double cp;
  final double sp;
  final double facing;
  final double roll;
  final double halfDepth;
  final double lx;
  final double ly;
  final double? bx;
  final double? by;

  /// the avatar box in logical pixels
  final double box;

  /// the real device pixel ratio, for tests that are about whole pixels
  final double dpr;

  /// the avatar box in device pixels with the ratio capped at 2, as the
  /// author's: picks the texture and pile tiers
  double get dev => box * math.min(2, dpr);

  /// the body's affine on the painter's canvas (a, b, c, d, e, f)
  final List<double> ctm;

  /// no animation follows: show the new light at once, measure at once
  final bool still;
  final double round;
}

/// Per avatar and outline: the matcap it holds, the cross-fade, the texels.
class PlasticState {
  int _n = 0;
  final _mc = Float32List(matcapM * matcapM * 3);
  final _mcPrev = Float32List(matcapM * matcapM * 3);
  final _mcMix = Float32List(matcapM * matcapM * 3);
  V3? _l;
  V3? _v;
  V3? _k;
  double _lx = double.nan, _ly = double.nan;
  Color? _base;
  Material? _mat;
  bool? _fabric;
  int _version = 0;
  int _mixVersion = 0;
  double _blendT = 1;
  int _blendFrames = 1;
  int _sinceBuild = 0;
  int _imgVersion = -1;
  double _imgAoK = double.nan;
  BotAvatarForm? _imgForm;
  double _aoK = -1;
  final _aoMul = Float32List(256);
  Int32List _argb = Int32List(0);
  ui.Vertices? _verts;
  String _sliceKey = '';
  List<Shader> _sliceG = const [];
  int _spriteVersion = -1;
  BotAvatarFur? _spriteFur;
  Shader? _fringeG;
  Shader? _sideG;
  Color _haze = const Color(0xFFFFFFFF);
  (double, double) _miss = (0, 0);
  (double, double) _missAt = (0, 0);
  (double, double) _turnAt = (0, 0);
  (double, double)? _fade;
  double _lay = 1;

  void dispose() {
    _verts?.dispose();
    _verts = null;
  }
}

/* the matcap is rebuilt once a direction has moved a bin (1/48) */
const _bin = 1 / 48;
bool _moved(V3 a, V3? b) =>
    b == null || (a.$1 - b.$1).abs() >= _bin || (a.$2 - b.$2).abs() >= _bin || (a.$3 - b.$3).abs() >= _bin;

Float64List _m4(List<double> m) =>
    Float64List.fromList([m[0], m[1], 0, 0, m[2], m[3], 0, 0, 0, 0, 1, 0, m[4], m[5], 0, 1]);

void _at(Canvas c, List<double> m, void Function() draw) {
  c.save();
  c.transform(_m4(m));
  draw();
  c.restore();
}

/* the texture grid as a mesh: a vertex per texel centre, triangles over every
   cell the front reaches (its alpha comes from the distance alone) */
class _Mesh {
  _Mesh(this.positions, this.indices);
  final Float32List positions;
  final Uint16List indices;
}

final _meshes = Expando<_Mesh>();
_Mesh _meshOf(BotAvatarForm form) {
  final hit = _meshes[form];
  if (hit != null) return hit;
  final n = form.n, u = span / n, sd = form.sd;
  final pos = Float32List(n * n * 2);
  for (var j = 0, i = 0; j < n; j++) {
    for (var x = 0; x < n; x++, i++) {
      pos[2 * i] = (x + 0.5) * u - pad;
      pos[2 * i + 1] = (j + 0.5) * u - pad;
    }
  }
  final idx = <int>[];
  for (var j = 0; j < n - 1; j++) {
    for (var x = 0; x < n - 1; x++) {
      final a = j * n + x, b = a + 1, c = a + n, d = c + 1;
      if (sd[a] <= 0 && sd[b] <= 0 && sd[c] <= 0 && sd[d] <= 0) continue;
      idx.addAll([a, b, d, a, d, c]);
    }
  }
  return _meshes[form] = _Mesh(pos, Uint16List.fromList(idx));
}

const _haloFit = 2.5;
const _haloInset = 3.0;
const _haloVeil = 0.8;
const _haloBlend = 0.3;
const _haloEase = 0.1;
const _haloShade = 0.5;
const _gapDeep = 0.28, _gapScatter = 0.42;
const _tipTint = 0.6;

final _scheduledMisses = <String>{};

/// Draws the plastic or fabric body. Returns false while its form (or pile)
/// still bakes: the caller draws the stock slices that frame.
bool drawPlasticCap(
  Canvas canvas,
  BotAvatarSolid solid,
  PlasticRig rig,
  Color base,
  Material mat,
  PlasticState st,
  FurStyle? furStyle,
  void Function(Float32List, Frame) fillPlastic,
) {
  final bakery = BotAvatarBakery.instance;
  final n = formTier(rig.dev);
  final form = bakery.form(solid.key, solid.polys, n, rig.halfDepth);
  if (form == null) return false;
  final fabric = furStyle != null;
  final capPx = (span * rig.dev / 100).ceilToDouble();
  final (bkx, bky) = rig.bx != null && rig.by != null ? (rig.bx!, rig.by!) : backFromKey(rig.lx, rig.ly);
  final fur = fabric
      ? bakery.fur(form, solid.key, rig.halfDepth, capPx, rig.lx, rig.ly, furStyle, FurLights(bkx, bky, mat.front))
      : null;
  if (fabric && fur == null) return false;
  final f = capFrame(
    CapRig(
      cy: rig.cy,
      sy: rig.sy,
      cp: rig.cp,
      sp: rig.sp,
      facing: rig.facing,
      roll: rig.roll,
      lx: rig.lx,
      ly: rig.ly,
      bx: rig.bx,
      by: rig.by,
    ),
  );
  final fl = math.sqrt(f.l.$1 * f.l.$1 + f.l.$2 * f.l.$2);
  final (lxx, lxy) = fl < 0.05 ? (0.0, -1.0) : (f.l.$1 / fl, f.l.$2 / fl);
  if (_moved(f.l, st._l) ||
      _moved(f.v, st._v) ||
      rig.lx != st._lx ||
      rig.ly != st._ly ||
      base != st._base ||
      mat != st._mat ||
      fabric != st._fabric ||
      (fabric && _moved(f.k, st._k))) {
    /* the fade starts from what is showing now */
    if (st._version > 0) st._mcPrev.setAll(0, st._mcMix);
    if (fabric) {
      buildFabricMatcap(st._mc, linearColor(base), f, mat);
    } else {
      fillPlastic(st._mc, f);
    }
    /* a still frame shows the new light at once: no frames follow to fade */
    if (st._version == 0 || rig.still) {
      st._mcMix.setAll(0, st._mc);
      st._blendT = 1;
    } else {
      st._blendFrames = st._sinceBuild.clamp(1, 10);
      st._blendT = 0;
    }
    st._sinceBuild = 0;
    st._mixVersion++;
    st._l = f.l;
    st._v = f.v;
    st._k = f.k;
    st._lx = rig.lx;
    st._ly = rig.ly;
    st._base = base;
    st._mat = mat;
    st._fabric = fabric;
    st._version++;
  }
  st._sinceBuild++;
  if (st._blendT < 1) {
    st._blendT = math.min(1, st._blendT + 1 / st._blendFrames);
    final e = st._blendT >= 1 ? 1.0 : st._blendT * st._blendT * (3 - 2 * st._blendT);
    final a = st._mcPrev, b = st._mc, o = st._mcMix;
    if (!fabric && e == 1) {
      // Plastic targets are zero or >= 2, so the Float32 endpoint is b.
      o.setAll(0, b);
    } else {
      for (var i = 0; i < o.length; i++) {
        o[i] = a[i] + (b[i] - a[i]) * e;
      }
    }
    st._mixVersion++;
  }
  /* the occlusion strength follows `shadow`; a pile sinks deeper into its
     creases than a clear coat does */
  final aoK = fur != null ? math.min(1.2, 0.3 + 0.8 * mat.shadow) : math.min(1.3, 1.2 * mat.shadow);
  if (aoK != st._aoK) {
    for (var a = 0; a < 256; a++) {
      st._aoMul[a] = math.max(0, 1 - aoK * (1 - a / 255));
    }
    st._aoK = aoK;
  }
  if (st._n != n) {
    st._argb = Int32List(n * n);
    st._n = n;
    st._imgVersion = -1;
  }
  if (st._imgVersion != st._mixVersion || st._imgAoK != aoK || !identical(st._imgForm, form)) {
    shadeTexels(form, st._mcMix, st._argb, st._aoMul, fur != null ? edgeLift(form) : null);
    final mesh = _meshOf(form);
    st._verts?.dispose();
    st._verts = ui.Vertices.raw(ui.VertexMode.triangles, mesh.positions, colors: st._argb, indices: mesh.indices);
    st._imgVersion = st._mixVersion;
    st._imgAoK = aoK;
    st._imgForm = form;
  }

  final kk = rig.dev <= 100 ? 14 : (rig.dev <= 224 ? 20 : 26);
  final rel = reliefFor(form, kk, rig.round);
  final cy = rig.cy, sy = rig.sy, cp = rig.cp, sp = rig.sp;
  final ctm = rig.ctm;
  final ca = ctm[0], cb = ctm[1], cc = ctm[2], cd = ctm[3], ce = ctm[4], cf = ctm[5];
  final m1 = sy * sp;
  final ta = ca * cy + cc * m1, tb = cb * cy + cd * m1, tc = cc * cp, td = cd * cp;
  final near = rig.facing >= 0 ? 1.0 : -1.0;

  /* the lit front's place, once, at the equator plane, stretched along the
     turn to span from the equator to the shoulder's silhouette */
  final dxs = sy / cy, dys = -sp / (cy * cp);
  final dl1 = math.sqrt(dxs * dxs + dys * dys);
  var lead = 50.0;
  for (var k = 1; k < kk; k++) {
    lead = math.max(lead, 50 * rel.scale[k] + rel.z[k] * dl1);
  }
  final ex = dl1 > 1e-6 ? (near * dxs) / dl1 : 1.0, ey = dl1 > 1e-6 ? (near * dys) / dl1 : 0.0;
  final backShade = math.min(0.7, 0.55 * math.min(1.6, mat.shadow / 0.35));
  final haloS = fur != null ? _haloStretch(form, rel, kk, ex, ey, dl1) : null;
  final stretch = (lead + 50) / 100, shift = (lead - 50) / 2;
  final aA = 1 + (stretch - 1) * ex * ex, bB = (stretch - 1) * ex * ey, dD = 1 + (stretch - 1) * ey * ey;
  final capSkew = [aA, bB, bB, dD, shift * ex - 50 * aA - 50 * bB, shift * ey - 50 * bB - 50 * dD];
  final capM = mulAffine(mulAffine(ctm, [cy, m1, 0, cp, 0, 0]), capSkew);

  /* the side's light per slice, made per matcap version */
  final c0x = rel.cx[0], c0y = rel.cy[0];
  final sliceKey = '${st._version}|$kk|${rel.q}|${fur != null}';
  Rays? rays;
  Rays raysNow() => rays ??= raysOf(st._argb, form, c0x, c0y);
  Shader sweep(List<Color> colors) => ui.Gradient.sweep(
    Offset(c0x, c0y),
    colors,
    [for (var s = 0; s <= conicStops; s++) s / conicStops],
    TileMode.clamp,
    0,
    math.pi * 2,
  );
  if (st._sliceKey != sliceKey) {
    st._sliceG = [
      for (var k = 0; k < kk; k++)
        sweep(sliceColors(raysNow(), (_) => fur != null ? math.max(_haloInset, rel.inset[k]) : rel.inset[k], (_) => 0)),
    ];
    st._sliceKey = sliceKey;
  }
  if (fur != null && (st._spriteVersion != st._version || !identical(st._spriteFur, fur))) {
    /* the halo's sprite: in each direction the colour of the slice that forms
       the silhouette there; its tips the front's brightest colour */
    final edge = haloS != null ? _haloRays(form, rel, kk, ex, ey, dl1, haloS, backShade) : null;
    st._fringeG = sweep(
      sliceColors(
        raysNow(),
        (s) => edge != null ? edge.$1[s] : math.max(_haloInset, rel.inset[0]),
        (s) => edge != null ? edge.$2[s] : 0,
      ),
    );
    st._sideG = st._sliceG[0];
    st._haze = hazeColor(raysNow(), base, mat.rim, mat.vivid);
    st._spriteVersion = st._version;
    st._spriteFur = fur;
  }

  /* fabric draws its slices into a layer of its own, then lays the pile over
     all of them at once; the layer covers where the slices can reach */
  var bx0 = 0.0, by0 = 0.0, bx1 = 0.0, by1 = 0.0;
  if (fur != null) {
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final z in [-rel.top, rel.top]) {
      final e = z * sy - 50 * cy, fo = -z * cy * sp - 50 * m1 - 50 * cp;
      final ee = ca * e + cc * fo + ce, ff = cb * e + cd * fo + cf;
      for (final x in [-pad, 100 + pad]) {
        for (final y in [-pad, 100 + pad]) {
          final xx = ta * x + tc * y + ee, yy = tb * x + td * y + ff;
          x0 = math.min(x0, xx);
          x1 = math.max(x1, xx);
          y0 = math.min(y0, yy);
          y1 = math.max(y1, yy);
        }
      }
    }
    bx0 = x0 - 1;
    by0 = y0 - 1;
    bx1 = x1 + 1;
    by1 = y1 + 1;
    canvas.saveLayer(Rect.fromLTRB(bx0, by0, bx1, by1), Paint());
  }

  /* at depth z: yaw about Y then pitch about X, orthographic */
  List<double> at(double z) {
    final e = z * sy - 50 * cy, fo = -z * cy * sp - 50 * m1 - 50 * cp;
    return [ta, tb, tc, td, ca * e + cc * fo + ce, cb * e + cd * fo + cf];
  }

  final sliceFill = Paint();
  final dark = Paint()..color = const Color(0xFF000000);
  final whole = Rect.fromLTWH(-pad, -pad, span, span);
  void slice(int k, double z, double darkA) {
    if (k > 0) {
      final sk = rel.scale[k];
      _at(canvas, mulAffine(at(z), [sk, 0, 0, sk, rel.cx[k] - sk * rel.cx[0], rel.cy[k] - sk * rel.cy[0]]), () {
        canvas.drawPath(solid.path, sliceFill..shader = st._sliceG[k]);
        if (darkA > 0.01) canvas.drawPath(solid.path, dark..color = Color.fromRGBO(0, 0, 0, darkA));
      });
      return;
    }
    _at(canvas, at(0), () {
      if (fur != null) {
        /* the equator: fabric's ends in its soft edge (its fringe is the halo
           laid over the whole stack) */
        /* the mask first and the light into it: a mask laid over an
           antialiased square would leave the square's edge */
        canvas.saveLayer(whole, Paint());
        _image(canvas, fur.soft, whole, Paint());
        canvas.drawRect(
          whole,
          Paint()
            ..shader = st._sideG
            ..blendMode = BlendMode.srcIn,
        );
        canvas.restore();
      } else {
        canvas.drawPath(solid.path, sliceFill..shader = st._sliceG[0]);
      }
    });
  }

  /* the far half, deepest first; fabric's far slice lying wholly inside the
     equator cannot show and is left out */
  final ring = ringOf(form), rn = ring.x.length, sd = form.sd, nf = form.n;
  final tdet = (ta * td - tb * tc).abs() * rig.dpr * rig.dpr;
  final hideBy = 1.5 / (tdet > 0 ? math.sqrt(tdet) : 1) + 0.4;
  final texel = span / nf;
  double toG(double v) => ((v + pad) / span) * nf - 0.5;
  final leanFar = math.atan2(-near * dys, -near * dxs), leanNear = math.atan2(near * dys, near * dxs);
  for (var k = kk - 1; k >= 1; k--) {
    final z = -near * rel.z[k], sk = rel.scale[k];
    if (fur != null) {
      final bx = rel.cx[k] - sk * rel.cx[0] + z * dxs, by = rel.cy[k] - sk * rel.cy[0] + z * dys;
      var hidden = bx.isFinite && by.isFinite;
      for (var j = 0; hidden && j < rn; j++) {
        final i = ringOrder(rn, leanFar, j);
        if (bilerp(sd, nf, toG(sk * ring.x[i] + bx), toG(sk * ring.y[i] + by)) < hideBy + sk * (ring.d[i] + texel)) {
          hidden = false;
        }
      }
      if (hidden) continue;
    }
    slice(k, z, fur != null ? 0 : backShade * (1 - math.exp(-2.4 * (k / kk))));
  }
  /* fabric's far half sinks into shade smoothly: one ramp laid over it */
  if (fur != null && dl1 > 1e-3) {
    final hn = reach(rimOf(form), -ex, -ey), spn = 1.3 * rel.top * dl1;
    _at(canvas, at(0), () {
      final stops = [for (var s = 0; s <= 8; s++) s / 8];
      canvas.drawRect(
        Rect.fromLTWH(-pad - 60, -pad - 60, span + 120, span + 120),
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.linear(Offset(-ex * hn, -ey * hn), Offset(-ex * (hn + spn), -ey * (hn + spn)), [
            for (final t in stops) Color.fromRGBO(0, 0, 0, backShade * (1 - math.exp(-2.4 * t)) * t * t * (3 - 2 * t)),
          ], stops),
      );
    });
  }
  slice(0, 0, 0);
  /* the near half; a slice lying wholly inside the front's opaque part
     cannot show and is left out */
  final face = rig.facing.abs();
  final frontA = face >= 0.72 ? 1.0 : (face <= 0.34 ? 0.0 : math.pow((face - 0.34) / 0.38, 1.5).toDouble());
  final cdet = capM[0] * capM[3] - capM[1] * capM[2];
  final cdev = cdet.abs() * rig.dpr * rig.dpr;
  final coverBy = frontFade + 1.5 / (cdev > 0 ? math.sqrt(cdev) : 1);
  for (var k = 1; k < kk; k++) {
    final z = near * rel.z[k], sk = rel.scale[k];
    if (frontA >= 1 && cdet.abs() > 1e-9) {
      final e = z * sy - 50 * cy, fo = -z * cy * sp - 50 * m1 - 50 * cp;
      final ee = ca * e + cc * fo + ce - capM[4], ff = cb * e + cd * fo + cf - capM[5];
      final ux = rel.cx[k] - sk * rel.cx[0], uy = rel.cy[k] - sk * rel.cy[0];
      var covered = true;
      for (var j = 0; covered && j < rn; j++) {
        final i = ringOrder(rn, leanNear, j);
        final u = sk * ring.x[i] + ux, v = sk * ring.y[i] + uy;
        final xx = ta * u + tc * v + ee, yy = tb * u + td * v + ff;
        final qx = (capM[3] * xx - capM[2] * yy) / cdet, qy = (capM[0] * yy - capM[1] * xx) / cdet;
        if (bilerp(sd, nf, toG(qx), toG(qy)) < coverBy + sk * (ring.d[i] + texel)) covered = false;
      }
      if (covered) continue;
    }
    slice(k, z, 0);
  }

  /* the front fades out over its outer band into the slices under it; turned
     far round it gives way to the slices' own light */
  if (frontA > 0.01) {
    _at(canvas, capM, () {
      if (frontA < 1) canvas.saveLayer(whole, Paint()..color = Color.fromRGBO(0, 0, 0, frontA));
      canvas.drawVertices(st._verts!, BlendMode.dst, Paint());
      if (frontA < 1) canvas.restore();
    });
  }

  if (fur != null) {
    if (haloS != null) _drawHalo(canvas, solid, form, rel, kk, haloS, fur, st, rig, at(0), near * dxs, near * dys, dl1);
    _drawFilms(canvas, fur, st, rig, base, mat, furStyle!, capM, capSkew, near, face, bx0, by0, bx1, by1);
    canvas.restore();
  }

  /* large plastic avatars: a crisp hairline of the environment along the lit
     side of the silhouette, fading out as the turn begins */
  final hairA = face >= 0.95 ? 1.0 : (face <= 0.8 ? 0.0 : (face - 0.8) / 0.15);
  if (fur == null && rig.dev >= 256 && mat.rim > 0 && mat.highlight > 0 && hairA > 0.01) {
    final al = hairA * math.min(0.5, 0.3 * mat.rim * math.min(1.4, mat.highlight));
    _at(canvas, capM, () {
      canvas.drawPath(
        solid.path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeJoin = StrokeJoin.round
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.linear(
            Offset(50 + lxx * 50, 50 + lxy * 50),
            Offset(50 - lxx * 50, 50 - lxy * 50),
            [
              Color.fromRGBO(235, 244, 255, al),
              Color.fromRGBO(235, 244, 255, 0.35 * al),
              const Color.fromRGBO(235, 244, 255, 0),
            ],
            const [0, 0.45, 0.75],
          ),
      );
    });
  }
  return true;
}

void _image(Canvas c, ui.Image img, Rect dst, Paint paint) {
  c.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    dst,
    paint..filterQuality = FilterQuality.low,
  );
}

/* the stack's reach along a direction v, given the outline's (h): the furthest
   of the slices of either half that way — and which one it is */
(double, int, bool) _stackReach(Relief rel, int kk, double ex, double ey, double dl1, double vx, double vy, double h) {
  final v0 = vx * rel.cx[0] + vy * rel.cy[0], ve = (vx * ex + vy * ey) * dl1;
  var best = h;
  var kb = 0;
  var far = false;
  for (var k = 1; k < kk; k++) {
    final r = vx * rel.cx[k] + vy * rel.cy[k] + rel.scale[k] * (h - v0);
    if (r + rel.z[k] * ve > best) {
      best = r + rel.z[k] * ve;
      kb = k;
      far = false;
    }
    if (r - rel.z[k] * ve > best) {
      best = r - rel.z[k] * ve;
      kb = k;
      far = true;
    }
  }
  return (best, kb, far);
}

/* the halo's stretch: along the turn e by 1 + s1, shifted by t, so the outline
   spans the stack's reach both ways */
List<double> _haloStretch(BotAvatarForm form, Relief rel, int kk, double ex, double ey, double dl1) {
  if (dl1 <= 1e-4) return const [1, 0, 0, 1, 0, 0];
  final rim = rimOf(form);
  final hp = reach(rim, ex, ey), hn = reach(rim, -ex, -ey);
  final up = _stackReach(rel, kk, ex, ey, dl1, ex, ey, hp).$1, un = _stackReach(rel, kk, ex, ey, dl1, -ex, -ey, hn).$1;
  final s1 = (up + un) / math.max(1, hp + hn) - 1, t = up - (s1 + 1) * hp;
  return [1 + s1 * ex * ex, s1 * ex * ey, s1 * ex * ey, 1 + s1 * ey * ey, ex * t, ey * t];
}

/* the halo's colour along each ray: the slice forming the stack's silhouette
   where the stretched outline's ray lands */
(Float32List, Float32List) _haloRays(
  BotAvatarForm form,
  Relief rel,
  int kk,
  double ex,
  double ey,
  double dl1,
  List<double> s,
  double backShade,
) {
  final rim = rimOf(form);
  final inset = Float32List(conicStops), dark = Float32List(conicStops);
  final s1 = s[0] + s[3] - 2;
  for (var i = 0; i < conicStops; i++) {
    final phi = (i / conicStops) * math.pi * 2, ux = math.cos(phi), uy = math.sin(phi);
    final ue = ux * ex + uy * ey, q = s1 / (1 + s1);
    var vx = ux - q * ue * ex, vy = uy - q * ue * ey;
    final vl = math.sqrt(vx * vx + vy * vy);
    vx /= vl;
    vy /= vl;
    final (_, k, far) = _stackReach(rel, kk, ex, ey, dl1, vx, vy, reach(rim, vx, vy));
    inset[i] = math.max(_haloInset, rel.inset[k]);
    dark[i] = far ? _haloShade * backShade * (1 - math.exp(-2.4 * (k / kk))) : 0;
  }
  return (inset, dark);
}

/* the halo's sprite: the side's light under the haze in the tips' colour, cut
   to the body and its fringe */
void _fringed(Canvas canvas, BotAvatarFur fur, PlasticState st) {
  final whole = Rect.fromLTWH(-pad, -pad, span, span);
  /* the mask first, the light into it, the haze atop: the same as the
     author's haze over the light cut to the mask, without the square's edge */
  _image(canvas, fur.mask, whole, Paint());
  canvas.drawRect(
    whole,
    Paint()
      ..shader = st._fringeG
      ..blendMode = BlendMode.srcIn,
  );
  _image(
    canvas,
    fur.haze,
    whole,
    Paint()
      ..blendMode = BlendMode.srcATop
      ..colorFilter = ColorFilter.mode(st._haze, BlendMode.srcIn),
  );
}

/* Fabric's halo over the silhouette: the outline stretched to the turned
   stack's reach, laid over the body keeping the body only where the halo
   covers it. Where the stretch no longer fits the stack (a lobed body far
   round), the cut the halo makes recedes and the halo shows behind it. */
void _drawHalo(
  Canvas canvas,
  BotAvatarSolid solid,
  BotAvatarForm form,
  Relief rel,
  int kk,
  List<double> haloS,
  BotAvatarFur fur,
  PlasticState st,
  PlasticRig rig,
  List<double> at0,
  double mx,
  double my,
  double dl1,
) {
  final stale = (mx - st._missAt.$1).abs() > 1.5 * missStep || (my - st._missAt.$2).abs() > 1.5 * missStep;
  final measured = dl1 > 1e-4 ? _haloMiss(form, solid.polys, rel, kk, haloS, mx, my, rig.still || stale) : (0.0, 0.0);
  if (measured != null) {
    st._miss = measured;
    st._missAt = (mx, my);
  }
  final (cut, over) = st._miss;
  final miss = math.max(cut, over);
  var back = smoothstep(_haloFit / 2, 2 * _haloFit, miss), gone = smoothstep(_haloFit / 2, _haloFit, over);
  final quick = (mx - st._turnAt.$1).abs() > missStep || (my - st._turnAt.$2).abs() > missStep;
  st._turnAt = (mx, my);
  final settle = !rig.still && !quick;
  final fade = st._fade;
  if (settle && fade != null) {
    double ease(double a, double b) => (b - a).abs() < 0.02 ? b : a + (b - a) * 0.2;
    back = ease(fade.$1, back);
    gone = ease(fade.$2, gone);
  }
  st._fade = (back, gone);
  final layTo = (1 - smoothstep(0, _haloBlend, back)) * (1 - gone);
  final lay = st._lay = !settle ? layTo : st._lay + (layTo - st._lay).clamp(-_haloEase, _haloEase);
  final veil = _haloVeil * math.min(1, dl1 / 0.2);
  final whole = Rect.fromLTWH(-pad, -pad, span, span);
  _at(canvas, mulAffine(at0, haloS), () {
    if (lay >= 0.5) {
      /* laid over: the body kept where the halo is, the halo where it is not */
      canvas.saveLayer(whole, Paint()..blendMode = BlendMode.dstATop);
      _fringed(canvas, fur, st);
      canvas.restore();
      /* and over the body's own edge, in part, the halo's colour */
      if (veil > 0.01) {
        canvas.saveLayer(
          whole,
          Paint()
            ..blendMode = BlendMode.srcATop
            ..color = Color.fromRGBO(0, 0, 0, veil),
        );
        _fringed(canvas, fur, st);
        _image(canvas, fur.core, whole, Paint()..blendMode = BlendMode.dstOut);
        canvas.restore();
      }
      return;
    }
    if (back < 1) {
      /* the cut grown about the outline's centre */
      final fk = 1 + (back * (miss + _haloFit)) / 25, cx = rel.cx[0], cy = rel.cy[0];
      canvas.save();
      canvas.transform(_m4([fk, 0, 0, fk, cx * (1 - fk), cy * (1 - fk)]));
      _image(
        canvas,
        fur.mask,
        whole,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..colorFilter = const ColorFilter.matrix([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 255]),
      );
      canvas.restore();
    }
    if (gone < 1) {
      canvas.saveLayer(
        whole,
        Paint()
          ..blendMode = BlendMode.dstOver
          ..color = Color.fromRGBO(0, 0, 0, 1 - gone),
      );
      _fringed(canvas, fur, st);
      canvas.restore();
    }
  });
}

/* the measure, or null while it waits (unless `sync`) */
(double, double)? _haloMiss(
  BotAvatarForm form,
  List<Float64List> polys,
  Relief rel,
  int kk,
  List<double> s,
  double dxs,
  double dys,
  bool sync,
) {
  final key = '$kk|${rel.q}|${(dxs / missStep).round()}|${(dys / missStep).round()}';
  final hit = form.misses[key];
  if (hit != null) return hit;
  if (form.misses.length > 256) form.misses.clear();
  if (!sync) {
    final id = '${identityHashCode(form)}|$key';
    if (_scheduledMisses.add(id)) {
      scheduleMicrotask(() {
        form.misses[key] = measureMiss(form, polys, rel, kk, s, dxs, dys);
        _scheduledMisses.remove(id);
      });
    }
    return null;
  }
  return form.misses[key] = measureMiss(form, polys, rel, kk, s, dxs, dys);
}

/* The pile over the whole body at once, only where it is: its dark part in a
   deep shade of the colour, its light part in the colour at full brightness,
   the fibres' own light on a large avatar. The tops stand over the hollows,
   so the light part is laid a little further along the turn. */
void _drawFilms(
  Canvas canvas,
  BotAvatarFur fur,
  PlasticState st,
  PlasticRig rig,
  Color base,
  Material mat,
  FurStyle style,
  List<double> capM,
  List<double> capSkew,
  double near,
  double face,
  double bx0,
  double by0,
  double bx1,
  double by1,
) {
  final lin = linearColor(base);
  final lum = math.pow(0.2126 * lin.$1 + 0.7152 * lin.$2 + 0.0722 * lin.$3, 1 / 2.2).toDouble();
  final e = [srgb(lin.$1), srgb(lin.$2), srgb(lin.$3)];
  final vivid = mat.vivid.clamp(0.0, 1.0);
  /* the gaps: the colour's own deep shade, deeper still in hue */
  final ve = [for (final v in e) v / 255];
  final vmx = math.max(math.max(ve[0], ve[1]), math.max(ve[2], 1e-3));
  final lu = 0.2126 * ve[0] + 0.7152 * ve[1] + 0.0722 * ve[2];
  final pale = math.min(ve[0], math.min(ve[1], ve[2])) / vmx;
  final kd = _gapDeep + _gapScatter * lu * lu * pale;
  final vq = (math.min(1, mat.vivid) * 10).round() / 10;
  int gch(double v) => (255 * kd * v * math.pow(v / vmx, 3.2 + 3 * vq)).round().clamp(0, 255);
  final gr = gch(ve[0]), gg = gch(ve[1]), gb = gch(ve[2]);
  final deep = (0.2126 * gr + 0.7152 * gg + 0.0722 * gb) / 255 / math.max(1e-3, lu);
  final gapA = math.min(1.0, math.sqrt((1 - gapRef) / math.max(0.05, 1 - deep)));
  final gap = Color.fromARGB(255, gr, gg, gb);
  /* the tips: the colour at full brightness, part of the way from white */
  final mx = math.max(math.max(e[0], e[1]), math.max(e[2], 1));
  Color mix(double k) {
    int ch(double u) => (255 + ((255 * u) / mx - 255) * k).round().clamp(0, 255);
    return Color.fromARGB(255, ch(e[0]), ch(e[1]), ch(e[2]));
  }

  final tips = mix(math.min(1, ((_tipTint + (1 - _tipTint) * vivid) * 10).round() / 10));
  /* the fibres' own light: off on a small avatar, where single fibres are
     finer than its pixels */
  final sheenA = rig.dev < 160 ? 0.0 : (face >= 0.88 ? 1.0 : (face <= 0.55 ? 0.0 : (face - 0.55) / 0.33));
  final hk = math.min(1.0, 0.45 * mat.highlight * mat.shine), rk = math.min(1.0, 1.1 * mat.rim);
  final soft = (mat.backSoft.clamp(0.0, 1.0) * 20).round() / 20;
  final sheens = sheenA > 0.01 && (hk > 0.01 || rk > 0.01)
      ? [
          (fur.back, mix(0.65 + 0.35 * vivid), rk * (1 - 0.85 * soft)),
          (fur.backSoft, mix(0.7 + 0.3 * vivid), rk * soft),
          (fur.glint, mix(0.45 + 0.55 * vivid), hk),
        ].where((l) => l.$3 > 0.01).toList()
      : const <(ui.Image, Color, double)>[];
  final cy = rig.cy, sy = rig.sy, cp = rig.cp, sp = rig.sp;
  final lift = near * pileH * style.length;
  final capT = mulAffine(
    mulAffine(mulAffine(rig.ctm, [1, 0, 0, 1, lift * sy, -lift * cy * sp]), [cy, sy * sp, 0, cp, 0, 0]),
    capSkew,
  );
  final film = Rect.fromLTWH(-pad - filmM, -pad - filmM, filmSpan, filmSpan);
  void lay(List<double> m, double a, bool withSheen, List<double> t) {
    _at(canvas, m, () {
      _image(
        canvas,
        fur.dark,
        film,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..colorFilter = ColorFilter.mode(gap.withValues(alpha: a * gapA), BlendMode.srcIn),
      );
    });
    _at(canvas, t, () {
      _image(
        canvas,
        fur.light,
        film,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..colorFilter = ColorFilter.mode(tips.withValues(alpha: a * (0.25 + 0.75 * lum)), BlendMode.srcIn),
      );
      if (withSheen && sheens.isNotEmpty) {
        canvas.saveLayer(
          film,
          Paint()
            ..blendMode = BlendMode.srcATop
            ..color = Color.fromRGBO(0, 0, 0, a * sheenA),
        );
        for (final (img, fill, alpha) in sheens) {
          _image(
            canvas,
            img,
            film,
            Paint()..colorFilter = ColorFilter.mode(fill.withValues(alpha: math.min(1, alpha)), BlendMode.srcIn),
          );
        }
        canvas.restore();
      }
    });
  }

  /* turned far round the front squeezes into a strip: from there the pile is
     laid square to the view instead, over the whole turned body */
  final sideU = face >= 0.62 ? 0.0 : (face <= 0.36 ? 1.0 : (0.62 - face) / 0.26);
  if (sideU < 1) lay(capM, 1 - sideU, true, capT);
  if (sideU > 0) {
    final k = rig.box / 100, cxs = (bx0 + bx1) / 2, cys = (by0 + by1) / 2;
    final m = [k, 0.0, 0.0, k, cxs - 50 * k, cys - 50 * k];
    lay(m, sideU, false, m);
  }
}
