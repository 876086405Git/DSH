// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The renderer (the author's draw.ts). The body is a stack of copies of its
   outline along a depth axis with a pillow profile, each projected with the
   head's yaw and pitch, so the stack reads as a rounded solid that turns,
   flips and shows its side — or, in plastic and fabric, the material's
   inflated relief. The face lives on a sphere behind the front and follows
   it; the whirl rings a spinning body. */

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'bot_avatar_bakery.dart';
import 'bot_avatar_color.dart';
import 'bot_avatar_engine.dart';
import 'bot_avatar_form.dart';
import 'bot_avatar_fur.dart';
import 'bot_avatar_material.dart';
import 'bot_avatar_outline.dart';
import 'bot_avatar_plastic.dart';
import 'bot_avatar_types.dart';

/// The canvas is drawn larger than the avatar's box, so a hop or a flip can
/// leave the box without being clipped.
const botAvatarOverscan = 1.5;

/// The body's centre sits this fraction of the box below the canvas centre:
/// hops and flips need the room above, not below.
const botAvatarRise = 0.1;

/* Copies through the depth, and the stock half-depth in body units. */
const _slices = 17;
const _halfDepth = 15.0;
/* Cap scale at the ends of the pillow, at the stock rim width. */
const _capScale = 0.9;
double _profile(double z, double cap) => cap + (1 - cap) * math.sqrt(math.max(0, 1 - z * z));

/* Big, plain dark eyes: they carry the face at 24px. */
const _eyeGap = 25.0;
const _eyeRx = 6.3;

/// The stock outlines, parsed once.
final Map<String, BotAvatarSolid> _solids = {};
BotAvatarSolid _solid(String key, String d) => _solids.putIfAbsent(key, () {
  final o = BotAvatarOutline.parse(d);
  return BotAvatarSolid(key, o.toPath(), o.polygons());
});

final Map<BotAvatarType, List<BotAvatarSolid>> _partSolids = {};
List<BotAvatarSolid> _parts(BotAvatarType type) => _partSolids.putIfAbsent(type, () {
  final d = botAvatarParts[type];
  if (d == null) return const [];
  final pieces = BotAvatarOutline.parts(d);
  return [
    for (var i = 0; i < pieces.length; i++)
      BotAvatarSolid('${type.name}:parts$i/${pieces.length}', pieces[i].toPath(), pieces[i].polygons()),
  ];
});

/// The light each material looks its best in where the look leaves it.
class _LightDefaults {
  const _LightDefaults(this.shadow, this.highlight, this.light, this.rim, this.spread);
  final double shadow;
  final double highlight;
  final double light;
  final double rim;
  final double spread;
}

const _fabricLight = _LightDefaults(1.15, 1.45, 295, 0.6, 1.6);
const _otherLight = _LightDefaults(0.35, 1.3, 300, 0.5, 1.55);

/// Everything that decides how an avatar looks (not how it moves).
class BotAvatarLook {
  BotAvatarLook({
    required this.type,
    required this.color,
    Color? ink,
    BotAvatarFace? face,
    this.shading = BotAvatarShading.fabric,
    double? shadow,
    double? highlight,
    double? light,
    double? rim,
    double? spread,
    this.depth = 0.65,
    this.roundness = 1,
    this.vivid = 0,
    this.backLight,
    this.lightFront = 32,
    this.shine = 0,
    this.sheen = 0,
    this.backSoftness = 1,
    this.fur = const FurStyle(),
    this.whirl = 0,
    this.whirlSize = 1,
    this.whirlWidth = 1,
    this.whirlLength = 1,
    this.whirlTilt = 1,
  }) : ink = ink ?? autoInk(color),
       face = face ?? type.preset.face,
       shadow = shadow ?? _defaults(shading).shadow,
       highlight = highlight ?? _defaults(shading).highlight,
       light = light ?? _defaults(shading).light,
       rim = rim ?? _defaults(shading).rim,
       spread = spread ?? _defaults(shading).spread;

  static _LightDefaults _defaults(BotAvatarShading s) => s == BotAvatarShading.fabric ? _fabricLight : _otherLight;

  final BotAvatarType type;

  /// The body colour, as drawn (brightness and saturation already applied).
  final Color color;

  /// The face's ink: dark, or light on a dark body.
  final Color ink;
  final BotAvatarFace face;
  final BotAvatarShading shading;
  final double shadow;
  final double highlight;

  /// Where the light comes from, degrees clockwise from the top.
  final double light;
  final double rim;
  final double spread;
  final double depth;
  final double roundness;

  /// 0–1: how much colour the light keeps past the palette's full saturation.
  final double vivid;
  final double? backLight;
  final double lightFront;
  final double shine;
  final double sheen;
  final double backSoftness;
  final FurStyle fur;
  final double whirl;
  final double whirlSize;
  final double whirlWidth;
  final double whirlLength;
  final double whirlTilt;

  BotAvatarSolid get solid => _solid(type.name, botAvatarShapes[type]!);
  List<BotAvatarSolid> get parts => _parts(type);

  /// Whether the look is drawn on a baked material (plastic, fabric).
  bool get material => shading == BotAvatarShading.plastic || shading == BotAvatarShading.fabric;

  /// A key for cached still frames: everything that changes the picture.
  String get id => [
    type.name,
    color.toARGB32(),
    ink.toARGB32(),
    face.name,
    shading.name,
    shadow,
    highlight,
    light,
    rim,
    spread,
    depth,
    roundness,
    vivid,
    backLight,
    lightFront,
    shine,
    sheen,
    backSoftness,
    fur.id,
  ].join('|');
}

/// Per avatar: the material's state for each outline it draws.
class BotAvatarRenderState {
  final _plastic = <String, PlasticState>{};

  PlasticState _for(String key) => _plastic.putIfAbsent(key, PlasticState.new);

  void dispose() {
    for (final s in _plastic.values) {
      s.dispose();
    }
    _plastic.clear();
  }
}

class _Palette {
  _Palette(Color color, double shadow, double highlight)
    : base = color,
      near = shade(color, -0.12 * shadow, 0.03 * shadow).color,
      light = shade(color, 0.04 * highlight).color,
      dark = shade(color, -0.3 * shadow, 0.05 * shadow).color,
      capTop = shade(color, 0.035 * highlight).color,
      capBottom = shade(color, -0.035 * shadow).color {
    final far = shade(color, -0.3 * shadow, 0.05 * shadow), nearH = shade(color, -0.12 * shadow, 0.03 * shadow);
    final self = shade(color, 0);
    for (var j = 0; j < _slices; j++) {
      final t = j / (_slices - 1);
      crispMix.add(t > 0.6 ? null : mixHsl(far, nearH, t / 0.6).color);
      smoothMix.add(t >= 0.5 ? color : mixHsl(far, self, t / 0.5).color);
    }
  }

  final Color base;
  final Color near;
  final Color light;
  final Color dark;
  final Color capTop;
  final Color capBottom;
  final crispMix = <Color?>[];
  final smoothMix = <Color>[];
  (double, double, Shader, Shader)? grad;
}

final _palettes = <String, _Palette>{};
_Palette _palette(Color color, double shadow, double highlight) {
  final key = '${color.toARGB32()}|$shadow|$highlight';
  final hit = _palettes[key];
  if (hit != null) return hit;
  if (_palettes.length > 200) _palettes.clear();
  return _palettes[key] = _Palette(color, shadow, highlight);
}

Float64List _m4(List<double> m) =>
    Float64List.fromList([m[0], m[1], 0, 0, m[2], m[3], 0, 0, 0, 0, 1, 0, m[4], m[5], 0, 1]);

/* The whirl: one tapered trail on a tilted ring, made of the body's own
   material — a translucent plastic tube in the body colour, lit from the same
   light. The near half is drawn over the face, the far half behind. */
const _whirlSegments = 34;
const _whirlSpan = math.pi * 1.55;
const _whirlRx = 57.0;
const _whirlRatio = 0.4;
const _whirlTilt = -0.28;

void _drawWhirl(Canvas canvas, BotAvatarPose pose, BotAvatarLook look, double lx, double ly, bool near) {
  final k = math.min(1.0, pose.whirl * look.whirl);
  if (k <= 0.01) return;
  final span = _whirlSpan * look.whirlLength;
  final base = shade(look.color, 0.1, 0.02).color, light = shade(look.color, 0.3, 0.04).color;
  final dark = shade(look.color, -0.22, 0.08).color, halo = shade(look.color, 0.2).color;
  final head = -pose.whirlAngle;
  final rx = _whirlRx * look.whirlSize;
  final ry = rx * _whirlRatio * look.whirlTilt * (near ? 1.14 : 0.86);
  final lightA = math.atan2(ly, lx) - _whirlTilt;
  canvas.save();
  canvas.rotate(_whirlTilt);
  canvas.translate(0, 5);
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt;
  void seg(double a0, double a1, double width, Color c, double dy) {
    p
      ..color = c
      ..strokeWidth = width;
    canvas.drawArc(Rect.fromCenter(center: Offset(0, dy), width: 2 * rx, height: 2 * ry), a0, a1 - a0, false, p);
  }

  Color alpha(Color c, double a) => c.withValues(alpha: a.clamp(0.0, 1.0));
  if (near) {
    for (var i = 0; i < _whirlSegments; i++) {
      final f = i / _whirlSegments;
      final a1 = head + f * span, a0 = a1 + span / _whirlSegments + 0.012;
      if (math.sin((a0 + a1) / 2) <= 0) continue;
      final fade = math.pow(1 - f, 1.3).toDouble();
      seg(a1, a0, (2 + 8 * fade) * 1.5 * look.whirlWidth, Color.fromRGBO(0, 0, 0, 0.2 * k * fade), 3.5);
    }
  }
  for (var i = 0; i < _whirlSegments; i++) {
    final f = i / _whirlSegments;
    final a1 = head + f * span, a0 = a1 + span / _whirlSegments + 0.012;
    final mid = (a0 + a1) / 2;
    if ((math.sin(mid) > 0) != near) continue;
    final depth = 0.6 + 0.4 * math.sin(mid);
    final fade = math.pow(1 - f, 1.3).toDouble();
    final puff = 1 + 0.18 * math.sin(f * 9 + 1.2);
    final width = (2 + 8 * fade) * depth * look.whirlWidth * puff;
    final a = k * (0.3 + 0.7 * fade) * depth;
    final facing = 0.5 + 0.5 * math.cos(mid - lightA);
    seg(a1, a0, width * 2.6, alpha(halo, a * 0.2), 0);
    seg(a1, a0, width * 0.8, alpha(dark, a * 0.45), width * 0.32);
    seg(a1, a0, width, alpha(base, a * 0.72), 0);
    seg(a1, a0, width * 0.62, alpha(light, a * 0.78 * (0.4 + 0.6 * facing)), -width * 0.16);
    seg(a1, a0, width * 0.24, alpha(const Color(0xFFFFFFFF), a * 0.9 * (0.15 + 0.85 * facing * facing)), -width * 0.3);
  }
  canvas.restore();
}

/// Whether the look's material is baked for a box (the bakes start here).
bool botAvatarReady(BotAvatarLook look, double box, double dpr) {
  if (!look.material) return true;
  final dev = box * math.min(2, dpr);
  final bakery = BotAvatarBakery.instance;
  final halfDepth = _halfDepth * look.depth;
  final n = formTier(dev);
  var ready = true;
  for (final p in look.parts) {
    if (bakery.form(p.key, p.polys, n, halfDepth * 0.4) == null) ready = false;
  }
  final s = look.solid;
  final form = bakery.form(s.key, s.polys, n, halfDepth);
  if (form == null) return false;
  if (look.shading == BotAvatarShading.fabric) {
    final la = look.light * math.pi / 180;
    final lx = math.sin(la), ly = -math.cos(la);
    final (bx, by) = _backOf(look.backLight) ?? backFromKey(lx, ly);
    final front = look.lightFront.clamp(0.0, 85.0) * math.pi / 180;
    final capPx = (span * dev / 100).ceilToDouble();
    final fur = bakery.fur(form, s.key, halfDepth, capPx, lx, ly, look.fur, FurLights(bx, by, front));
    if (fur == null || fur.r != furTier(capPx)) ready = false;
  }
  return ready;
}

(double, double)? _backOf(double? deg) {
  if (deg == null || !deg.isFinite) return null;
  final a = deg * math.pi / 180;
  return (math.sin(a), -math.cos(a));
}

/// Draws one frame. The canvas is `box × botAvatarOverscan` square with the
/// body's centre `botAvatarRise × box` below its middle.
void paintBotAvatar(
  Canvas canvas,
  double box,
  BotAvatarPose pose,
  BotAvatarLook look,
  BotAvatarRenderState rs, {
  required double dpr,
  required bool still,
}) {
  final full = box * botAvatarOverscan;
  final s = box / 100;
  final halfDepth = _halfDepth * look.depth;
  final rimK = look.rim;
  final cap = 1 - (1 - _capScale) * rimK;
  final la = look.light * math.pi / 180;
  final lx = math.sin(la), ly = -math.cos(la);
  final pal = _palette(look.color, look.shadow, look.highlight);
  final mode = look.shading;

  final cy0 = math.cos(pose.yaw), sy = math.sin(pose.yaw);
  final cp0 = math.cos(pose.pitch), sp = math.sin(pose.pitch);
  /* which cap faces the viewer: the front while this is positive */
  final facing = cy0 * cp0;
  /* edge-on, every slice would thin to a line; a floor keeps it a solid */
  double floor(double v) => v.abs() < 0.22 ? (v < 0 ? -0.22 : 0.22) : v;
  final cy = floor(cy0), cp = floor(cp0);

  /* body space: the box centre plus the pose's offset, its roll and squash
     about the body's base, so a landing keeps the feet on the ground */
  final cr = math.cos(pose.roll), sr = math.sin(pose.roll), kx = pose.sx * s, ky = pose.sy * s;
  final lift = 50 * (1 - pose.sy) * s;
  final body = <double>[
    cr * kx,
    sr * kx,
    -sr * ky,
    cr * ky,
    full / 2 + pose.x * s - sr * lift,
    full / 2 + botAvatarRise * box + pose.y * s + cr * lift,
  ];
  final back = _backOf(look.backLight);
  final mat = Material(
    shadow: look.shadow,
    highlight: look.highlight,
    spread: look.spread,
    rim: rimK,
    vivid: look.vivid,
    front: look.lightFront.clamp(0.0, 85.0) * math.pi / 180,
    shine: look.shine,
    sheen: look.sheen,
    backSoft: look.backSoftness,
  );

  // Parts share this paint's plastic target, while each keeps its own fade.
  Float32List? plasticTarget;
  void fillPlastic(Float32List out, Frame frame) {
    final source = plasticTarget;
    if (source != null) {
      out.setAll(0, source);
      return;
    }
    buildMatcap(out, linearColor(look.color), frame, mat);
    plasticTarget = out;
  }

  /* plastic's hairline lays itself over the avatar's own pixels only */
  final layered = mode == BotAvatarShading.plastic && box * math.min(2, dpr) >= 256;
  if (layered) canvas.saveLayer(Rect.fromLTWH(0, 0, full, full), Paint());

  bool drawSolid(BotAvatarSolid solid, double halfDepth, bool plush) {
    Shader? litG, capG;
    if (mode == BotAvatarShading.crisp) {
      final g = pal.grad;
      if (g == null || g.$1 != lx || g.$2 != ly) {
        pal.grad = (
          lx,
          ly,
          ui.Gradient.linear(
            Offset(lx * 56, ly * 56),
            Offset(-lx * 56, -ly * 56),
            [pal.light, pal.near, pal.dark],
            const [0, 0.45, 1],
          ),
          ui.Gradient.linear(Offset(lx * 46, ly * 46), Offset(-lx * 46, -ly * 46), [pal.capTop, pal.capBottom]),
        );
      }
      litG = pal.grad!.$3;
      capG = pal.grad!.$4;
    }
    var done = false;
    if (mode == BotAvatarShading.plastic || mode == BotAvatarShading.fabric) {
      done = drawPlasticCap(
        canvas,
        solid,
        PlasticRig(
          cy: cy,
          sy: sy,
          cp: cp,
          sp: sp,
          facing: facing,
          roll: pose.roll,
          halfDepth: halfDepth,
          lx: lx,
          ly: ly,
          bx: back?.$1,
          by: back?.$2,
          box: box,
          dpr: dpr,
          ctm: body,
          still: still,
          round: look.roundness,
        ),
        look.color,
        mat,
        rs._for(solid.key),
        plush && mode == BotAvatarShading.fabric ? look.fur : null,
        fillPlastic,
      );
    }
    if (done) return true;
    final soft = mode == BotAvatarShading.smooth || mode == BotAvatarShading.plastic || mode == BotAvatarShading.fabric;
    final union = soft ? Path() : null;
    final order = facing >= 0 ? 1 : -1;
    canvas.save();
    canvas.transform(_m4(body));
    final paint = Paint();
    for (var j = 0; j < _slices; j++) {
      final k = order > 0 ? j : _slices - 1 - j;
      final z = -1 + (2 * k) / (_slices - 1);
      final sc = _profile(z, cap);
      final near = j / (_slices - 1);
      final m0 = cy * sc, m1 = sy * sp * sc, m3 = cp * sc;
      final e = z * sy * halfDepth - 50 * m0, fo = -z * cy * sp * halfDepth - 50 * m1 - 50 * m3;
      final m = _m4([m0, m1, 0, m3, e, fo]);
      paint.shader = null;
      if (soft) {
        paint.color = pal.smoothMix[j];
      } else if (j == _slices - 1) {
        if (capG != null) {
          paint.shader = capG;
        } else {
          paint.color = pal.base;
        }
      } else if (near > 0.6) {
        if (litG != null) {
          paint.shader = litG;
        } else {
          paint.color = pal.near;
        }
      } else {
        paint.color = pal.crispMix[j]!;
      }
      canvas.save();
      canvas.transform(m);
      canvas.drawPath(solid.path, paint);
      canvas.restore();
      union?.addPath(solid.path, Offset.zero, matrix4: m);
    }
    /* smooth: a soft shadow from the lower right and a light from the upper
       left, laid over the whole form so nothing has an edge */
    if (union != null) {
      canvas.save();
      canvas.clipPath(union);
      final sa = math.min(1.0, 0.34 * look.shadow);
      final shadowC = Offset(-lx * 45, -ly * 45);
      canvas.drawRect(
        const Rect.fromLTWH(-120, -120, 240, 240),
        Paint()
          ..blendMode = BlendMode.multiply
          ..shader = ui.Gradient.radial(
            shadowC,
            84 * look.spread,
            [Color.fromRGBO(0, 0, 0, sa), Color.fromRGBO(0, 0, 0, sa * 0.35), const Color.fromRGBO(0, 0, 0, 0)],
            const [0, 0.5, 1],
            TileMode.clamp,
            null,
            shadowC,
            4 * look.spread,
          ),
      );
      final ha = math.min(1.0, 0.22 * look.highlight);
      canvas.drawRect(
        const Rect.fromLTWH(-120, -120, 240, 240),
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(lx * 37, ly * 37),
            62 * look.spread,
            [
              Color.fromRGBO(255, 255, 255, ha),
              Color.fromRGBO(255, 255, 255, ha * 0.23),
              const Color.fromRGBO(255, 255, 255, 0),
            ],
            const [0, 0.6, 1],
          ),
      );
      canvas.restore();
    }
    canvas.restore();
    return false;
  }

  /* the far half of the whirl sits behind everything */
  canvas.save();
  canvas.transform(_m4(body));
  _drawWhirl(canvas, pose, look, lx, ly, false);
  canvas.restore();

  /* the thin parts first with a fraction of the depth, as moulded plastic */
  for (final p in look.parts) {
    drawSolid(p, halfDepth * 0.4, false);
  }
  final plasticDone = drawSolid(look.solid, halfDepth, true);

  /* the face: each feature sits on a sphere behind the front, so a turn
     slides it round the head; the cushion of plastic and fabric has no front
     cap, so its outline is taken a little over halfway up the face */
  final preset = look.type.preset;
  final zf = facing >= 0 ? 1.0 : -1.0;
  final sf = plasticDone ? 1.0 : _profile(zf, cap);
  double zFace = halfDepth;
  if (plasticDone) {
    final form = BotAvatarBakery.instance.form(
      look.solid.key,
      look.solid.polys,
      formTier(box * math.min(2, dpr)),
      halfDepth,
    );
    zFace = 0.55 * (form != null ? surfaceAt(form, preset.faceX, preset.faceY, look.roundness) : 0.8 * halfDepth);
  }
  final fm0 = cy * sf, fm1 = sy * sp * sf, fm3 = cp * sf;
  final fe = zf * sy * zFace - 50 * fm0;
  final ffo = -zf * cy * sp * zFace - 50 * fm1 - 50 * fm3;

  canvas.save();
  canvas.transform(_m4(body));
  if (facing > -0.2) {
    canvas.save();
    /* the face is printed on the front of the body, so it cannot leave it */
    canvas.clipPath(look.solid.path.transform(_m4([fm0, fm1, 0, fm3, fe, ffo])));
    canvas.translate(preset.faceX - 50, preset.faceY - 50);
    canvas.scale(preset.faceScale, preset.faceScale);
    /* under a clear coat the print shows the gloss faintly through it */
    _drawFace(canvas, pose, look, mode == BotAvatarShading.plastic && plasticDone ? 0.93 : 1);
    canvas.restore();
  }
  /* the near half of the whirl passes in front of the face */
  _drawWhirl(canvas, pose, look, lx, ly, true);
  canvas.restore();
  if (layered) canvas.restore();
}

/* Radius of the sphere the face is drawn on, in body units. */
const _faceR = 30.0;

/* A feature's place on the sphere: its screen offset, its foreshortening, and
   how much it faces the viewer. */
(double, double, double, double, double) _onSphere(double x, double y, double yaw, double pitch) {
  final lon = math.asin((x / _faceR).clamp(-1.0, 1.0)) + yaw;
  final lat = math.asin((-y / _faceR).clamp(-1.0, 1.0)) + pitch;
  final cl = math.cos(lat);
  return (_faceR * math.sin(lon) * cl, -_faceR * math.sin(lat), math.cos(lon), cl, math.cos(lon) * cl);
}

/* An eye's curve as a short polyline, cached by its numbers. */
const _eyeSteps = 8;
final _eyePaths = <int, Path>{};
Path _eyePath(double x0, double y0, double cy) {
  final qx = (x0 * 50).round(), qy = (y0 * 50).round(), qc = (cy * 50).round();
  final key = qx + 2000 * qy + 4000000 * qc;
  final hit = _eyePaths[key];
  if (hit != null) return hit;
  final ax = qx / 50, ay = qy / 50, ac = qc / 50;
  final p = Path()..moveTo(-ax, ay);
  for (var i = 1; i <= _eyeSteps; i++) {
    final t = i / _eyeSteps, mt = 1 - t;
    p.lineTo(mt * mt * -ax + t * t * ax, (mt * mt + t * t) * ay + 2 * mt * t * ac);
  }
  if (_eyePaths.length > 256) _eyePaths.clear();
  return _eyePaths[key] = p;
}

/* The mouth's outline: corners at ±hw, a top edge and a bottom edge as cubics,
   round caps of radius t0 at the corners. */
final _mouthSin = math.sin(0.684), _mouthCos = math.cos(0.684);
final _mouthPaths = <String, Path>{};
Path _mouthPath(double hw0, double t00, double a0, double yt0, double ab0, double yb0) {
  double q(double v) => (v * 50).round() / 50;
  final hw = q(hw0), t0 = q(t00), a = q(a0), yt = q(yt0), ab = q(ab0), yb = q(yb0);
  final key = '$hw,$t0,$a,$yt,$ab,$yb';
  final hit = _mouthPaths[key];
  if (hit != null) return hit;
  final nx = t0 * _mouthSin, ny = t0 * _mouthCos;
  final ltx = -hw + nx, lty = -ny, rtx = hw - nx, rty = -ny;
  final lbx = -hw - nx, lby = ny, rbx = hw + nx, rby = ny;
  final cx = (4 / 3) * t0 * _mouthCos, cy = (4 / 3) * t0 * _mouthSin;
  final p = Path()
    ..moveTo(ltx, lty)
    ..cubicTo(-hw + a * hw, yt - t0, hw - a * hw, yt - t0, rtx, rty)
    ..cubicTo(rtx + cx, rty - cy, rbx + cx, rby - cy, rbx, rby)
    ..cubicTo(hw - ab * hw, yb + t0, -hw + ab * hw, yb + t0, lbx, lby)
    ..cubicTo(lbx - cx, lby - cy, ltx - cx, lty - cy, ltx, lty)
    ..close();
  if (_mouthPaths.length > 256) _mouthPaths.clear();
  return _mouthPaths[key] = p;
}

void _drawFace(Canvas canvas, BotAvatarPose pose, BotAvatarLook look, double printAlpha) {
  final wd = pose.w[0], ww = pose.w[1], ws = pose.w[2];
  final ink = look.ink;
  final ey = look.face == BotAvatarFace.eyes ? 1.0 : -3.5;
  const half = _eyeGap / 2;
  final lx = pose.lookX, ly = pose.lookY;
  final yaw = pose.yaw, pitch = pose.pitch;
  final paint = Paint();

  /* place a feature: skip it once it has gone round the side */
  void at(double x, double y, void Function(Paint) fn) {
    final (qx, qy, qsx, qsy, qz) = _onSphere(x, y, yaw, pitch);
    if (qz <= 0.02) return;
    canvas.save();
    paint.color = ink.withValues(alpha: ink.a * printAlpha * math.min(1, qz * 5));
    canvas.translate(qx, qy);
    canvas.scale(math.max(0.02, qsx), math.max(0.02, qsy));
    fn(paint);
    canvas.restore();
  }

  /* each eye is one stroked curve — endpoints at ±x0,y0, a control at 0,cy,
     width w, round caps — so a blend of the numbers is a real morph */
  double past(double v, double d) => v.abs() <= d ? 0 : (v.sign * (v.abs() - d)) / (1 - d);
  double clamp1(double v) => v.clamp(-1.0, 1.0);
  final up = past(clamp1(-pose.pitch / 0.26 - pose.lookY / 7), 0.34);
  final side = past(clamp1(pose.lookX / 4.5), 0.4).abs();
  final tall = math.max(0.3, 1 + 0.55 * up - 0.1 * side);
  final wide = 1 - 0.05 * up + 0.12 * side;
  final open = wd + ww * (1 - pose.laugh);
  final laugh = ww * pose.laugh;
  final lift = math.max(0.0, -pose.y) / 26;
  final sag = 0.5 + 0.5 * pose.breath;
  for (final sideK in const [-1.0, 1.0]) {
    final lid = sideK < 0 ? pose.blinkL : pose.blinkR;
    final e = (pose.eyeOpen * (1 - lid)).clamp(0.0, 1.0);
    final kOpen = open * e, kShut = open * (1 - e), kLaugh = laugh, kSleep = ws;
    final x0 = kOpen * 0.01 + kShut * 5.4 + kLaugh * 6.2 + kSleep * 6;
    final y0 = kOpen * 1.1 * tall + kShut * 0.6 + kLaugh * (2.2 - lift * 1.5) + kSleep * (-1.4 + sag);
    final cy = kOpen * -3.3 * tall + kShut * 0.6 + kLaugh * (-11.4 - 4 * lift) + kSleep * (5.4 + 2 * sag);
    final w = kOpen * _eyeRx * 2 * wide + kShut * 2.8 + kLaugh * 4.4 + kSleep * 4;
    final dx = lx * (kOpen + 0.5 * (kShut + kLaugh)), dy = ly * (kOpen + 0.5 * kShut);
    at(sideK * half + dx, ey + dy, (p) {
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(_eyePath(x0, y0, cy), p);
    });
  }

  if (look.face == BotAvatarFace.mouth) {
    /* one mouth for every state, so a switch morphs it */
    final kd = (0.6 + 0.4 * wd) * (1 + 0.06 * pose.breath);
    final kw = (0.6 + 0.4 * ww) * (1 + (0.25 * math.max(0.0, -pose.y)) / 26);
    final r = 2.7 * ws * (1 + 0.25 * pose.breath);
    double b(double d, double w, double s) => wd * d + ww * w + ws * s;
    at(lx * 0.35, b(12.5, 11.6, 15.5), (p) {
      p.style = PaintingStyle.fill;
      canvas.drawPath(
        _mouthPath(
          b(6.5 * kd, 9.5 * kw, r),
          b(1.9, 0, 0),
          b(2 / 3, 2 / 3, 0),
          b(3.53 * kd, 1.6 * kw, (-4 * r) / 3),
          b(2 / 3, 0, 0),
          b(3.53 * kd, 17.3 * kw, (4 * r) / 3),
        ),
        p,
      );
    });
  }
}
