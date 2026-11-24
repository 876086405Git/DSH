// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'distortion_wave_style.dart';
import 'wave_front.dart';

/// The wave's two fragment programs, loaded once for the app.
class WavePrograms {
  WavePrograms._(this.lens, this.band);

  final ui.FragmentProgram lens;
  final ui.FragmentProgram band;

  static Future<WavePrograms?>? _loading;
  static WavePrograms? _ready;

  /// The programs, once [load] has finished; null before, or where they can't
  /// load: the wave is then a plain crossfade.
  static WavePrograms? get ready => _ready;

  static Future<WavePrograms?> load() => _loading ??= _load();

  static Future<WavePrograms?> _load() async {
    try {
      final lens = await ui.FragmentProgram.fromAsset('shaders/fx/distortion_wave_lens.frag');
      final band = await ui.FragmentProgram.fromAsset('shaders/fx/distortion_wave_band.frag');
      _warmUp(lens, band);
      return _ready = WavePrograms._(lens, band);
    } catch (_) {
      return null;
    }
  }

  /// The first draw with a program builds its pipeline, which would otherwise
  /// land on the first frames of the first wave: done once here, out of sight,
  /// as the original draws its stage once behind the real one.
  static void _warmUp(ui.FragmentProgram lens, ui.FragmentProgram band) {
    final blank = ui.PictureRecorder();
    Canvas(blank).drawPaint(Paint());
    final pixel = blank.endRecording();
    final image = pixel.toImageSync(1, 1);
    pixel.dispose();
    final lensShader = lens.fragmentShader();
    for (var i = 0; i < 3; i++) {
      lensShader.setImageSampler(i, image);
    }
    final bandShader = band.fragmentShader();
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..shader = lensShader)
      ..drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..shader = bandShader);
    final picture = recorder.endRecording();
    picture.toImageSync(2, 2).dispose();
    picture.dispose();
    lensShader.dispose();
    bandShader.dispose();
    image.dispose();
  }
}

/// The two sides of a [WaveStage].
enum WaveSide { revealed, content }

/// The transition at the progress of [progress]: the revealed side, the content
/// side over it, then the colour and the dots. Everything on screen is derived
/// from that one number, through [WaveFront].
///
/// Through the swell each side is drawn from a snapshot of it (or, for the
/// content, from [contentImage] when the content isn't a child here: a route's
/// page underneath). [plain], or no [programs], makes it a crossfade.
class WaveStage extends SlottedMultiChildRenderObjectWidget<WaveSide, RenderBox> {
  const WaveStage({
    super.key,
    required this.progress,
    required this.style,
    required this.palette,
    required this.programs,
    required this.pixelRatio,
    this.source,
    this.focus,
    this.plain = false,
    this.content,
    this.contentImage,
    required this.revealed,
    this.revealedLiveOnceCrossed = false,
  });

  final Animation<double> progress;
  final DistortionWaveStyle style;
  final DistortionWavePalette palette;
  final WavePrograms? programs;
  final double pixelRatio;

  /// The frame the wave opens from, in this widget's coordinates; null: the
  /// type's default ([waveDefaultSource]).
  final Rect? source;
  final Offset? focus;
  final bool plain;
  final Widget? content;
  final ui.Image? contentImage;
  final Widget revealed;

  /// The revealed side takes touches as soon as the front has crossed the
  /// screen (a route's page), rather than only once the wave has finished.
  final bool revealedLiveOnceCrossed;

  @override
  Iterable<WaveSide> get slots => WaveSide.values;

  @override
  Widget? childForSlot(WaveSide slot) => switch (slot) {
    WaveSide.revealed => revealed,
    WaveSide.content => content,
  };

  @override
  RenderWaveStage createRenderObject(BuildContext context) => RenderWaveStage(
    progress: progress,
    style: style,
    palette: palette,
    programs: programs,
    pixelRatio: pixelRatio,
    source: source,
    focus: focus,
    plain: plain,
    contentImage: contentImage,
    revealedLiveOnceCrossed: revealedLiveOnceCrossed,
  );

  @override
  void updateRenderObject(BuildContext context, RenderWaveStage renderObject) {
    renderObject
      ..progress = progress
      ..style = style
      ..palette = palette
      ..programs = programs
      ..pixelRatio = pixelRatio
      ..source = source
      ..focus = focus
      ..plain = plain
      ..contentImage = contentImage
      ..revealedLiveOnceCrossed = revealedLiveOnceCrossed;
  }
}

class _SnapshotContext extends PaintingContext {
  _SnapshotContext(super.containerLayer, super.estimatedBounds);

  void finish() => stopRecordingIfNeeded();
}

/// Draws [WaveStage]. Its own repaint boundary: it repaints every frame of a
/// wave, and nothing around it needs to.
class RenderWaveStage extends RenderBox with SlottedContainerRenderObjectMixin<WaveSide, RenderBox> {
  RenderWaveStage({
    required this._progress,
    required this._style,
    required this._palette,
    required this._programs,
    required this._pixelRatio,
    this._source,
    this._focus,
    this._plain = false,
    this._contentImage,
    this._revealedLiveOnceCrossed = false,
  });

  /// The radius of the first blurred copy; the second has the style's full radius.
  static const _nearBlur = 7.0;

  /// The blurred copies are drawn at one pixel a logical pixel: blurred, they
  /// need no more.
  static const _blurScale = 1.0;

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(_onProgress);
    _progress = value;
    if (attached) _progress.addListener(_onProgress);
    _onProgress();
  }

  /// The side last given to semantics and touches.
  RenderBox? _lastLive;

  void _onProgress() {
    // A resting route no longer needs the last snapshots bound to the lens shaders.
    if (_value <= 0 || _value >= 1) _disposeShaders();
    markNeedsPaint();
    final live = _live;
    if (!identical(live, _lastLive)) {
      _lastLive = live;
      markNeedsSemanticsUpdate();
    }
  }

  DistortionWaveStyle _style;
  set style(DistortionWaveStyle value) {
    if (identical(value, _style)) return;
    _style = value;
    _particles = null;
    _releaseContentBlur();
    markNeedsPaint();
  }

  DistortionWavePalette _palette;
  set palette(DistortionWavePalette value) {
    if (value == _palette) return;
    _palette = value;
    _packedPalette = null;
    markNeedsPaint();
  }

  WavePrograms? _programs;
  set programs(WavePrograms? value) {
    if (identical(value, _programs)) return;
    _disposeShaders();
    _programs = value;
    markNeedsPaint();
  }

  double _pixelRatio;
  set pixelRatio(double value) {
    if (value == _pixelRatio) return;
    _pixelRatio = value;
    markNeedsPaint();
  }

  Rect? _source;
  set source(Rect? value) {
    if (value == _source) return;
    _source = value;
    markNeedsPaint();
  }

  Offset? _focus;
  set focus(Offset? value) {
    if (value == _focus) return;
    _focus = value;
    markNeedsPaint();
  }

  bool _plain;
  set plain(bool value) {
    if (value == _plain) return;
    _plain = value;
    markNeedsPaint();
  }

  ui.Image? _contentImage;
  set contentImage(ui.Image? value) {
    if (identical(value, _contentImage)) return;
    _contentImage = value;
    _releaseContentBlur();
    markNeedsPaint();
  }

  bool _revealedLiveOnceCrossed;
  set revealedLiveOnceCrossed(bool value) {
    if (value == _revealedLiveOnceCrossed) return;
    _revealedLiveOnceCrossed = value;
    _onProgress();
  }

  RenderBox? get _revealed => childForSlot(WaveSide.revealed);
  RenderBox? get _content => childForSlot(WaveSide.content);

  /// A snapshot couldn't be taken this run (a platform view in a side): the rest
  /// of the run is a crossfade.
  bool _failed = false;

  ui.FragmentShader? _revealedShader;
  ui.FragmentShader? _contentShader;
  ui.FragmentShader? _bandShader;
  final _revealedPaint = Paint();
  final _contentPaint = Paint();
  final _bandPaint = Paint();
  final _dotPaint = Paint();
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;
  final _revealedOpacity = LayerHandle<OpacityLayer>();
  final _contentOpacity = LayerHandle<OpacityLayer>();
  final _lumps = Float64List(WaveRim.count * 3);
  Float32List? _packedPalette;
  List<WaveParticle>? _particles;

  /// This frame's snapshots and blurred copies, released on the next.
  final _frameImages = <ui.Image>[];

  /// The blurred copies of [_contentImage], made once: it doesn't change while
  /// the wave crosses.
  ui.Image? _contentNear;
  ui.Image? _contentFar;

  double get _value => _progress.value;

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(_onProgress);
    _onProgress();
  }

  @override
  void detach() {
    _progress.removeListener(_onProgress);
    super.detach();
  }

  @override
  void dispose() {
    _releaseFrameImages();
    _releaseContentBlur();
    _disposeShaders();
    _revealedOpacity.layer = null;
    _contentOpacity.layer = null;
    super.dispose();
  }

  void _disposeShaders() {
    _revealedShader?.dispose();
    _contentShader?.dispose();
    _bandShader?.dispose();
    _revealedShader = _contentShader = _bandShader = null;
  }

  void _releaseFrameImages() {
    for (final image in _frameImages) {
      image.dispose();
    }
    _frameImages.clear();
  }

  void _releaseContentBlur() {
    _contentNear?.dispose();
    _contentFar?.dispose();
    _contentNear = _contentFar = null;
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final tight = BoxConstraints.tight(size);
    _revealed?.layout(tight);
    _content?.layout(tight);
  }

  /// The side that takes touches: the content until the wave starts, the
  /// revealed side once it has finished (or, for a route's page, once the front
  /// has crossed the screen), neither in between.
  RenderBox? get _live {
    final p = _value;
    if (p >= 1) return _revealed;
    if (p <= 0) return _content;
    if (_revealedLiveOnceCrossed && hasSize && _frontAt(p).hasCleared) return _revealed;
    return null;
  }

  WaveFront _frontAt(double p) => WaveFront(
    progress: p,
    source: _source ?? waveDefaultSource(_style.type, size),
    size: size,
    style: _style,
    focus: _focus,
  );

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _live?.hitTest(result, position: position) ?? false;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final live = _live;
    if (live != null) visitor(live);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _releaseFrameImages();
    final p = _value;
    // A new run tries the shaders again.
    if (p <= 0 || p >= 1) _failed = false;
    final programs = _programs;
    if (_plain || programs == null || _failed) {
      _paintPlain(context, offset, p);
      return;
    }

    final source = _source ?? waveDefaultSource(_style.type, size);
    final front = _frontAt(p);
    final live = p > 0 && p < 1;
    final acting = live && front.energy > 0;
    final revealedLens = front.launched && acting;
    // Once launched, the content keeps its coverage mask until the front has
    // crossed, even where the swell has died first (a slow easing).
    final contentLens = live && !front.hasCleared && (front.launched || front.gravity > 0);

    ui.Image? revealedImage;
    ui.Image? contentImage;
    final revealed = _revealed;
    final content = _content;
    if (revealedLens && revealed != null) {
      revealedImage = _snapshot(revealed);
      if (revealedImage == null) return _fail(context, offset, p);
    }
    if (contentLens) {
      contentImage = _contentImage;
      if (contentImage == null && content != null) {
        contentImage = _snapshot(content);
        if (contentImage == null) return _fail(context, offset, p);
      }
    }

    // context.canvas is read afresh for each draw: painting a child that is a
    // repaint boundary ends the canvas before it.
    final blurring = acting && _style.blur > 0;
    if (front.launched) {
      if (revealedImage != null) {
        var near = revealedImage;
        var far = revealedImage;
        if (blurring) {
          near = _blurred(revealedImage, _nearBlur);
          far = _blurred(revealedImage, _style.blur);
          _frameImages.addAll([near, far]);
        }
        final shader = _revealedShader ??= programs.lens.fragmentShader();
        _setLens(shader, front, -1, revealedImage, near, far);
        context.canvas.drawRect(offset & size, _revealedPaint..shader = shader);
      } else if (revealed != null) {
        context.paintChild(revealed, offset);
      }
    }
    if (!front.hasCleared) {
      if (contentLens && contentImage != null) {
        var near = contentImage;
        var far = contentImage;
        if (blurring) {
          if (identical(contentImage, _contentImage)) {
            near = _contentNear ??= _blurred(contentImage, _nearBlur);
            far = _contentFar ??= _blurred(contentImage, _style.blur);
          } else {
            near = _blurred(contentImage, _nearBlur);
            far = _blurred(contentImage, _style.blur);
            _frameImages.addAll([near, far]);
          }
        }
        final shader = _contentShader ??= programs.lens.fragmentShader();
        _setLens(shader, front, 1, contentImage, near, far);
        context.canvas.drawRect(offset & size, _contentPaint..shader = shader);
      } else {
        _paintContentPlain(context, offset);
      }
    }
    if (live) {
      final canvas = context.canvas;
      _paintBand(canvas, offset, programs, front);
      _paintDots(canvas, offset, front, source);
    }
  }

  void _fail(PaintingContext context, Offset offset, double p) {
    _releaseFrameImages();
    _failed = true;
    _paintPlain(context, offset, p);
  }

  /// The crossfade: the revealed side fading in under the content fading out.
  /// A route's page underneath is its own content, so a route draws none.
  void _paintPlain(PaintingContext context, Offset offset, double p) {
    final revealed = _revealed;
    final content = _content;
    // At rest, just the side on show.
    if (p >= 1 || p <= 0) {
      _revealedOpacity.layer = _contentOpacity.layer = null;
      final shown = p >= 1 ? revealed : content;
      if (shown != null) context.paintChild(shown, offset);
      return;
    }
    if (revealed != null) {
      _revealedOpacity.layer = context.pushOpacity(
        offset,
        (p * 255).round(),
        (context, offset) => context.paintChild(revealed, offset),
        oldLayer: _revealedOpacity.layer,
      );
    }
    if (content != null) {
      _contentOpacity.layer = context.pushOpacity(
        offset,
        ((1 - p) * 255).round(),
        (context, offset) => context.paintChild(content, offset),
        oldLayer: _contentOpacity.layer,
      );
    }
  }

  void _paintContentPlain(PaintingContext context, Offset offset) {
    final content = _content;
    final image = _contentImage;
    if (content != null) {
      context.paintChild(content, offset);
    } else if (image != null) {
      context.canvas.drawImageRect(
        image,
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
        offset & size,
        _imagePaint,
      );
    }
  }

  /// [child] as an image, or null when it holds something that can't be
  /// rasterized (a platform view).
  ui.Image? _snapshot(RenderBox child) {
    final layer = OffsetLayer();
    final context = _SnapshotContext(layer, Offset.zero & size);
    context.paintChild(child, Offset.zero);
    context.finish();
    if (!layer.supportsRasterization()) {
      layer.dispose();
      return null;
    }
    final image = layer.toImageSync(Offset.zero & size, pixelRatio: _pixelRatio);
    layer.dispose();
    _frameImages.add(image);
    return image;
  }

  /// [image] blurred by [radius], at [_blurScale].
  ui.Image _blurred(ui.Image image, double radius) {
    final width = (size.width * _blurScale).ceil().clamp(1, 8192);
    final height = (size.height * _blurScale).ceil().clamp(1, 8192);
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final sigma = radius * _blurScale;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..saveLayer(
        bounds,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
      )
      ..drawImageRect(image, Offset.zero & Size(image.width.toDouble(), image.height.toDouble()), bounds, _imagePaint)
      ..restore();
    final picture = recorder.endRecording();
    final out = picture.toImageSync(width, height);
    picture.dispose();
    return out;
  }

  void _setLens(ui.FragmentShader shader, WaveFront f, double side, ui.Image sharp, ui.Image near, ui.Image far) {
    var i = 0;
    shader
      ..setFloat(i++, size.width)
      ..setFloat(i++, size.height)
      ..setFloat(i++, f.origin.dx)
      ..setFloat(i++, f.origin.dy)
      ..setFloat(i++, f.spine)
      ..setFloat(i++, f.radius)
      ..setFloat(i++, f.squash)
      ..setFloat(i++, f.time)
      ..setFloat(i++, f.swell)
      ..setFloat(i++, f.tilt)
      ..setFloat(i++, f.energy)
      ..setFloat(i++, f.gravity)
      ..setFloat(i++, f.ring ? 1 : 0)
      ..setFloat(i++, f.hold)
      ..setFloat(i++, _style.amplitude)
      ..setFloat(i++, _style.lensWidth)
      ..setFloat(i++, _style.aberration)
      ..setFloat(i++, side)
      ..setFloat(i++, _style.blur)
      ..setFloat(i++, _style.blurAhead)
      ..setFloat(i++, _style.blurBehind)
      ..setFloat(i++, f.launched ? 1 : 0)
      ..setImageSampler(0, sharp, filterQuality: FilterQuality.low)
      ..setImageSampler(1, near, filterQuality: FilterQuality.low)
      ..setImageSampler(2, far, filterQuality: FilterQuality.low);
  }

  /// OKLab triplets padded to vec4: up to eight colours, then the two fringes;
  /// last, how many colours there are.
  static Float32List _packPalette(DistortionWavePalette palette) {
    final colors = palette.colors.isEmpty ? [palette.ahead] : palette.colors.take(8).toList();
    final out = Float32List(10 * 4 + 1);
    for (var k = 0; k < 8; k++) {
      out.setRange(k * 4, k * 4 + 3, waveOklab(colors[k % colors.length]));
    }
    out.setRange(32, 35, waveOklab(palette.ahead));
    out.setRange(36, 39, waveOklab(palette.behind));
    out[40] = colors.length.toDouble();
    return out;
  }

  void _paintBand(Canvas canvas, Offset offset, WavePrograms programs, WaveFront f) {
    final s = _style;
    WaveRim.lumps(_lumps, time: f.time, size: size, cornerRadius: s.cornerRadius, pulse: s.rimPulse);
    final palette = _packedPalette ??= _packPalette(_palette);
    final shader = _bandShader ??= programs.band.fragmentShader();
    var i = 0;
    shader
      ..setFloat(i++, size.width)
      ..setFloat(i++, size.height)
      ..setFloat(i++, f.origin.dx)
      ..setFloat(i++, f.origin.dy)
      ..setFloat(i++, f.spine)
      ..setFloat(i++, f.radius)
      ..setFloat(i++, f.squash)
      ..setFloat(i++, f.time)
      ..setFloat(i++, f.swell)
      ..setFloat(i++, f.tilt)
      ..setFloat(i++, f.glow)
      ..setFloat(i++, f.rim)
      ..setFloat(i++, f.clearRadius)
      ..setFloat(i++, f.hairClearRadius)
      ..setFloat(i++, f.ring ? 1 : 0)
      ..setFloat(i++, f.hold)
      ..setFloat(i++, s.lead)
      ..setFloat(i++, s.tail)
      ..setFloat(i++, s.strength)
      ..setFloat(i++, s.rimWidth)
      ..setFloat(i++, s.rimSoftness)
      ..setFloat(i++, s.cornerRadius)
      ..setFloat(i++, s.rimUnevenness)
      ..setFloat(i++, s.rimPulse)
      ..setFloat(i++, s.hairlineWidth)
      ..setFloat(i++, s.hairlineOpacity)
      ..setFloat(i++, s.hairlineWhite)
      ..setFloat(i++, palette[40])
      ..setFloat(i++, 0)
      ..setFloat(i++, 0);
    for (var k = 0; k < 40; k++) {
      shader.setFloat(i++, palette[k]);
    }
    for (var k = 0; k < WaveRim.count; k++) {
      shader
        ..setFloat(i++, _lumps[k * 3])
        ..setFloat(i++, _lumps[k * 3 + 1])
        ..setFloat(i++, _lumps[k * 3 + 2])
        ..setFloat(i++, 0);
    }
    canvas.drawRect(offset & size, _bandPaint..shader = shader);
  }

  /// The dots, flat white over the colour.
  void _paintDots(Canvas canvas, Offset offset, WaveFront front, Rect source) {
    final particles = _particles ??= [for (var i = 0; i < _style.particleCount; i++) WaveParticle(i, _style)];
    for (final particle in particles) {
      final opacity = particle.opacity(front);
      if (opacity <= 0) continue;
      _dotPaint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
      canvas.drawCircle(particle.point(front, source) + offset, particle.size / 2, _dotPaint);
    }
  }
}
