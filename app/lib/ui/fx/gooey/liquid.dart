// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';
import 'liquid_engine.dart';
import 'liquid_style.dart';
import 'liquid_transition.dart';

/// 液态组:组里的 [LiquidItem] 碰到一起会像液体一样融合、分开,文字和图标照常清晰。
///
/// The liquid is one silhouette painted behind [child]: every [LiquidItem]
/// below contributes a rounded rect (or a moving body with a tail, or a bowed
/// body), the lot is blurred by [blur] and its alpha thresholded at slope
/// [contrast] — the SVG goo filter — and [shadows] are drawn from the merged
/// shape. Content stays crisp because it paints on top, untouched.
///
/// Size the group to hold the full travel of its items: the liquid is cut at
/// the group's box plus about `3 × blur + filterPadding`. Items find their
/// group by context; keep a [RepaintBoundary] from sitting between the group
/// and an item that moves, or the liquid will not see it move.
///
/// Cost: one blur + threshold layer, plus one per shadow layer (two per inset
/// layer), over the group's padded box — every frame something in the group
/// repaints. Keep groups small.
class Liquid extends StatefulWidget {
  const Liquid({
    super.key,
    this.blur = 6,
    this.contrast = 18,
    this.fill,
    this.shadows = const [],
    this.filterPadding = 24,
    required this.child,
  });

  /// Goo blur σ in px: how far apart pieces start bridging. Neighbours bridge
  /// once it is about as large as the gap between them.
  final double blur;

  /// Alpha slope: how sharp the liquid edge is. Higher is crisper and beadier.
  final double contrast;

  /// Liquid colour; null follows the theme ([LiquidPalette.surface]).
  final Color? fill;

  /// Drawn on the merged silhouette, first layer on top (CSS order).
  final List<LiquidShadow> shadows;

  /// Extra room in px for pieces travelling outside the group's box.
  final double filterPadding;

  final Widget child;

  /// The alpha intercept that keeps the threshold near the classic 18 / −7
  /// crossing whatever the slope.
  static double interceptFor(double contrast) => ((0.5 - contrast * (5 / 12)) * 100).round() / 100;

  @override
  State<Liquid> createState() => _LiquidState();
}

class _LiquidState extends State<Liquid> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final LiquidEngine _engine = LiquidEngine(onActive: _wake);

  // Called from the group's paint when a body starts moving.
  void _wake() {
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration _) {
    if (_engine.clean > 30) {
      _ticker.stop();
      _engine.sleep();
      return;
    }
    _engine.group?.markNeedsPaint();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: _LiquidScope(
        engine: _engine,
        child: _LiquidLayer(
          engine: _engine,
          blur: widget.blur,
          contrast: widget.contrast,
          fill: widget.fill ?? LiquidPalette.of(context).surface,
          shadows: widget.shadows,
          filterPadding: widget.filterPadding,
          reduced: AppMotion.reduced(context),
          child: widget.child,
        ),
      ),
    );
  }
}

class _LiquidScope extends InheritedWidget {
  const _LiquidScope({required this.engine, required super.child});

  final LiquidEngine engine;

  static LiquidEngine of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_LiquidScope>();
    if (scope == null) throw FlutterError('A LiquidItem must be placed inside a Liquid group.');
    return scope.engine;
  }

  @override
  bool updateShouldNotify(_LiquidScope oldWidget) => oldWidget.engine != engine;
}

/// A piece of a [Liquid] group (`Liquid.Item`). Its liquid is a rounded rect
/// of the item's own painted size, corner [radius] (a large radius makes a pill,
/// as CSS `999px` does).
///
/// - [LiquidEffect.morph]: the item animates [x] / [y] / [scale] itself with
///   [transition] after [delay], liquid and content together; nearby pieces
///   merge. Under "remove animations" it snaps.
/// - [LiquidEffect.move] / [LiquidEffect.bend]: move the item yourself
///   (`AnimatedPositioned`, `Transform`, a drag) — wrap the item, not its
///   child — and the liquid follows its painted rect with [move] / [bend]
///   physics; [x] / [y] / [scale] are ignored. Under "remove animations" the
///   liquid stays glued to the item.
///
/// Give the content no opaque background where the liquid should show: the
/// liquid is the surface. Opaque content covering its own liquid is fine.
class LiquidItem extends StatefulWidget {
  const LiquidItem({
    super.key,
    this.effect = LiquidEffect.morph,
    this.x = 0,
    this.y = 0,
    this.scale = 1,
    this.transition = LiquidTransition.smooth,
    this.delay = Duration.zero,
    this.move = const MoveTuning(),
    this.bend = const BendTuning(),
    this.radius = BorderRadius.zero,
    required this.child,
  });

  final LiquidEffect effect;

  /// Morph offset and scale (about the centre).
  final double x;
  final double y;
  final double scale;

  /// Timing for [x] / [y] / [scale] changes; a retarget starts from where the
  /// item is now and plays the full duration.
  final LiquidTransition transition;

  /// Hold before a transition starts (stagger).
  final Duration delay;

  final MoveTuning move;
  final BendTuning bend;
  final BorderRadius radius;
  final Widget child;

  @override
  State<LiquidItem> createState() => _LiquidItemState();
}

class _LiquidItemState extends State<LiquidItem> with SingleTickerProviderStateMixin {
  Ticker? _ticker;

  // Rendered offset and scale, and where the running transition started.
  late double _x = widget.x;
  late double _y = widget.y;
  late double _s = widget.scale;
  double _fx = 0;
  double _fy = 0;
  double _fs = 1;
  LiquidTiming _timing = LiquidTiming.instant;
  Duration _delay = Duration.zero;

  @override
  void didUpdateWidget(LiquidItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.x == widget.x && oldWidget.y == widget.y && oldWidget.scale == widget.scale) return;
    final timing = widget.transition.resolve(reduced: AppMotion.reduced(context));
    if (timing.duration <= Duration.zero || (_x == widget.x && _y == widget.y && _s == widget.scale)) {
      _ticker?.stop();
      _x = widget.x;
      _y = widget.y;
      _s = widget.scale;
      return;
    }
    _fx = _x;
    _fy = _y;
    _fs = _s;
    _timing = timing;
    _delay = widget.delay;
    final ticker = _ticker ??= createTicker(_tick);
    ticker
      ..stop()
      ..start();
  }

  void _tick(Duration elapsed) {
    final p = ((elapsed - _delay).inMicroseconds / _timing.duration.inMicroseconds).clamp(0.0, 1.0);
    final e = _timing.curve.transform(p);
    setState(() {
      _x = _fx + (widget.x - _fx) * e;
      _y = _fy + (widget.y - _fy) * e;
      _s = _fs + (widget.scale - _fs) * e;
    });
    if (p >= 1) _ticker!.stop();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final marker = _LiquidMarker(
      engine: _LiquidScope.of(context),
      effect: widget.effect,
      radius: widget.radius,
      move: switch (widget.effect) {
        LiquidEffect.morph => null,
        LiquidEffect.move => widget.move.resolve(),
        LiquidEffect.bend => widget.bend.resolve(),
      },
      child: widget.child,
    );
    if (widget.effect != LiquidEffect.morph) return marker;
    // T(x, y) · S(s), about the centre: CSS `translate() scale()` with the
    // origin at the centre.
    return Transform(
      transform: Matrix4(_s, 0, 0, 0, 0, _s, 0, 0, 0, 0, 1, 0, _x, _y, 0, 1),
      alignment: Alignment.center,
      child: marker,
    );
  }
}

class _LiquidMarker extends SingleChildRenderObjectWidget {
  const _LiquidMarker({
    required this.engine,
    required this.effect,
    required this.radius,
    required this.move,
    required super.child,
  });

  final LiquidEngine engine;
  final LiquidEffect effect;
  final BorderRadius radius;
  final LiquidMoveOptions? move;

  @override
  _RenderLiquidMarker createRenderObject(BuildContext context) =>
      _RenderLiquidMarker(engine: engine, effect: effect, radius: radius, move: move);

  @override
  void updateRenderObject(BuildContext context, _RenderLiquidMarker renderObject) {
    renderObject
      ..engine = engine
      ..configure(effect, radius, move);
  }
}

/// Registers the item's box with its group while attached.
class _RenderLiquidMarker extends RenderProxyBox {
  _RenderLiquidMarker({
    required this._engine,
    required LiquidEffect effect,
    required BorderRadius radius,
    required LiquidMoveOptions? move,
  }) {
    blob = LiquidBlob(box: this, effect: effect, radius: radius, move: move);
  }

  late final LiquidBlob blob;
  LiquidEngine _engine;

  set engine(LiquidEngine value) {
    if (value == _engine) return;
    if (attached) {
      _engine.remove(blob);
      value.add(blob);
    }
    _engine = value;
  }

  void configure(LiquidEffect effect, BorderRadius radius, LiquidMoveOptions? move) {
    if (effect == blob.effect && radius == blob.radius && move == blob.move) return;
    blob
      ..effect = effect
      ..radius = radius
      ..move = move;
    _engine.group?.markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _engine.add(blob);
  }

  @override
  void detach() {
    _engine.remove(blob);
    super.detach();
  }
}

class _LiquidLayer extends SingleChildRenderObjectWidget {
  const _LiquidLayer({
    required this.engine,
    required this.blur,
    required this.contrast,
    required this.fill,
    required this.shadows,
    required this.filterPadding,
    required this.reduced,
    required super.child,
  });

  final LiquidEngine engine;
  final double blur;
  final double contrast;
  final Color fill;
  final List<LiquidShadow> shadows;
  final double filterPadding;
  final bool reduced;

  @override
  _RenderLiquid createRenderObject(BuildContext context) => _RenderLiquid(
    engine: engine,
    blur: blur,
    contrast: contrast,
    fill: fill,
    shadows: shadows,
    filterPadding: filterPadding,
    reduced: reduced,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderLiquid renderObject) {
    renderObject
      ..blur = blur
      ..contrast = contrast
      ..fill = fill
      ..shadows = shadows
      ..filterPadding = filterPadding
      ..reduced = reduced;
  }
}

/// Paints the merged silhouette (filter.tsx `GooFilterPrimitives`) under its
/// child: outer shadow passes in reverse list order, the shape, then inset
/// passes on top.
class _RenderLiquid extends RenderProxyBox {
  _RenderLiquid({
    required this._engine,
    required this._blur,
    required this._contrast,
    required Color fill,
    required this._shadows,
    required this._filterPadding,
    required bool reduced,
  }) {
    _fill = fill;
    _shape.color = fill.withValues(alpha: 1);
    _engine.reduced = reduced;
  }

  final LiquidEngine _engine;

  double get blur => _blur;
  double _blur;
  set blur(double value) {
    if (value == _blur) return;
    _blur = value;
    _invalidate();
  }

  double get contrast => _contrast;
  double _contrast;
  set contrast(double value) {
    if (value == _contrast) return;
    _contrast = value;
    _invalidate();
  }

  List<LiquidShadow> get shadows => _shadows;
  List<LiquidShadow> _shadows;
  set shadows(List<LiquidShadow> value) {
    if (listEquals(value, _shadows)) return;
    _shadows = value;
    _invalidate();
  }

  double get filterPadding => _filterPadding;
  double _filterPadding;
  set filterPadding(double value) {
    if (value == _filterPadding) return;
    _filterPadding = value;
    markNeedsPaint();
  }

  // Shapes stay opaque so the goo threshold never sees a translucent edge; the
  // fill's colour and alpha are painted over the thresholded silhouette
  // instead. A layer's opacity lands in the colour-matrix input before the
  // filter runs (Impeller), so a 20% fill used to be thresholded to nothing.
  final _shape = Paint();
  final _layer = Paint();
  final _isolate = Paint();
  Color _fill = const Color(0xFFFFFFFF);
  set fill(Color value) {
    if (value == _fill) return;
    _fill = value;
    _shape.color = value.withValues(alpha: 1);
    _invalidate();
  }

  set reduced(bool value) {
    if (value == _engine.reduced) return;
    _engine.reduced = value;
    markNeedsPaint();
  }

  List<_Pass>? _passes;

  void _invalidate() {
    _passes = null;
    markNeedsPaint();
  }

  /// Unpremultiplied alpha remap; Flutter takes the offset in 0..255.
  static ColorFilter _alpha(double slope, double intercept) => ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, slope, intercept * 255,
  ]);

  /// Binarises the goo before spread / inset passes: its soft fringe would
  /// otherwise dilate into a second hairline.
  static final _binarize = _alpha(60, -29.5);

  static ui.ImageFilter _blurOf(double sigma) =>
      ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal);

  static ui.ImageFilter _then(ui.ImageFilter inner, ui.ImageFilter outer) =>
      ui.ImageFilter.compose(outer: outer, inner: inner);

  List<_Pass> _build() {
    final goo = _then(_blurOf(_blur), _alpha(_contrast, Liquid.interceptFor(_contrast)));
    final bin = _then(goo, _binarize);
    // The threshold runs on the opaque shape; the fill (colour and alpha) is
    // applied on top of the thresholded silhouette. The threshold cuts the
    // edge with no antialiasing, so a hair of blur after the tint turns that
    // hard edge back into a smooth one (the goo itself stays crisp).
    _layer.imageFilter = _then(
      _then(goo, ColorFilter.mode(_fill, BlendMode.srcIn)),
      _blurOf(0.6),
    );
    ui.ImageFilter morph(ui.ImageFilter src, double spread, {required bool grow}) => _then(
      src,
      grow
          ? ui.ImageFilter.dilate(radiusX: spread, radiusY: spread)
          : ui.ImageFilter.erode(radiusX: spread, radiusY: spread),
    );
    final outer = <_Pass>[];
    final inset = <_Pass>[];
    for (final s in _shadows) {
      if (s.inset) {
        // The band: the silhouette minus its shrunk / offset / blurred self.
        var cut = bin;
        if (s.spread != 0) cut = morph(cut, s.spread.abs(), grow: s.spread < 0);
        if (s.blur > 0) cut = _then(cut, _blurOf(s.blur / 2));
        inset.add(
          _Pass(
            Paint()..imageFilter = _then(bin, ColorFilter.mode(s.color, BlendMode.srcIn)),
            s.offset,
            cut: Paint()
              ..blendMode = BlendMode.dstOut
              ..imageFilter = cut,
          ),
        );
      } else {
        var src = s.spread != 0 ? morph(bin, s.spread.abs(), grow: s.spread > 0) : goo;
        src = _then(src, ColorFilter.mode(s.color, BlendMode.srcIn));
        if (s.blur > 0) src = _then(src, _blurOf(s.blur / 2));
        // Outer shadows reach past the silhouette's own box: their layers do too.
        final reach = math.max(s.offset.dx.abs(), s.offset.dy.abs()) + s.blur * 1.5 + math.max(0, s.spread);
        outer.add(_Pass(Paint()..imageFilter = src, s.offset, reach: reach));
      }
    }
    return [...outer.reversed, _Pass(_layer, Offset.zero), ...inset];
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _engine.group = this;
  }

  @override
  void detach() {
    if (_engine.group == this) _engine.group = null;
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_engine.blobs.isNotEmpty) {
      _engine.step(this, SchedulerBinding.instance.currentFrameTimeStamp);
      _paintLiquid(context.canvas, offset);
    }
    super.paint(context, offset);
  }

  void _paintLiquid(Canvas canvas, Offset offset) {
    final passes = _passes ??= _build();
    // The filter region: the group's box plus the goo's reach and some slack.
    final region = (Offset.zero & size).inflate((_blur * 3 + _filterPadding).ceilToDouble());
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    for (final pass in passes) {
      final cut = pass.cut;
      final bounds = region.inflate(pass.reach);
      if (cut == null) {
        _shapes(canvas, bounds, pass.paint, pass.offset);
      } else {
        canvas.saveLayer(bounds, _isolate);
        _shapes(canvas, bounds, pass.paint, Offset.zero);
        _shapes(canvas, bounds, cut, pass.offset);
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _shapes(Canvas canvas, Rect bounds, Paint layer, Offset shift) {
    canvas.saveLayer(bounds, layer);
    if (shift != Offset.zero) canvas.translate(shift.dx, shift.dy);
    _engine.paint(canvas, _shape);
    canvas.restore();
  }
}

/// One filtered draw of the silhouette, shifted by [offset]; inset passes punch
/// the [cut] copy out of it.
class _Pass {
  _Pass(this.paint, this.offset, {this.cut, this.reach = 0});

  final Paint paint;
  final Offset offset;
  final Paint? cut;

  /// How far past the filter region this pass paints.
  final double reach;
}
