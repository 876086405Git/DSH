// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../themes/theme_pack.dart';
import '../../wallpaper/wallpaper_frames.dart';
import '../../wallpaper/wallpaper_render.dart' show WallpaperBake;
import 'backdrop_frame.dart';
import 'surfaces.dart';
import 'theme_style.dart';

/// 全屏页面背景:**竖向雾蓝渐变 + 两团极淡的光**。
///
/// - 底层:`backdropTop → backdropBottom` 竖向渐变(浅色彩度 ≤ 0.019)。
/// - 右上:主色光晕(跟随 accent)。左下:暮紫光晕。透明度都在 0.25–0.42,
///   画在大半径径向渐变里,肉眼只觉得"有点透亮",看不出是两个圆。
/// - 光晕的作用是给玻璃一点可"透"的颜色;纯平背景上的玻璃看起来只是白块。
///
/// **同一主题内所有页共用同一张背景**,
/// 切 tab 时背景不动,只有前景内容在变 —— 切换顺滑的关键。
///
/// 内部自带一个透明 `Material`:子树里的 `InkWell` 水波画在背景**之上**。
/// (若水波宿主是背景下面的 Scaffold,不透明的渐变会把水波整个盖住。)
///
/// 给了 [picture](自定义壁纸,lib/ui/wallpaper/wallpaper_backdrop.dart)就画那张
/// 预先烘好的图,不画渐变;子树里的 [BackdropVeil] 跟着画同一张图。
///
/// 主题包自己的背景(光晕位置、纹理、背景图)也都由同一个 painter 画,[BackdropVeil]
/// 的带子因此和它对得上;有壁纸时让给壁纸。
class AppBackdrop extends StatefulWidget {
  const AppBackdrop({super.key, required this.child, this.glow = true, this.picture});

  final Widget child;

  /// 是否画光晕。全屏 WebView、安装页等自带背景的场景可以关掉。
  final bool glow;

  /// A picture in place of the gradient; null: the gradient.
  final BackdropPicture? picture;

  /// How many blurred stills of a theme pack were softened for a page (tests).
  @visibleForTesting
  static int softened = 0;

  @override
  State<AppBackdrop> createState() => _AppBackdropState();
}

class _AppBackdropState extends State<AppBackdrop> {
  /// The theme pack's picture as this page shows it, once a pack has had one.
  _PackShown? _shown;

  @override
  void dispose() {
    _shown?.dispose();
    super.dispose();
  }

  /// The app's providers; null outside a [ProviderScope] (a bare preview), where a pack's
  /// picture is left out rather than the page broken.
  ProviderContainer? _container() {
    try {
      return ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = DshSurfaces.of(context);
    final picture = widget.picture;
    var pack = _PackLook.of(context);
    // The wallpaper comes first: the pack's picture isn't even decoded under it.
    final key = picture == null ? pack?.key : null;
    if (key != null || _shown != null) {
      final shown = _shown ??= _PackShown();
      // A page under another one's route doesn't tick, and doesn't keep a decoder going either.
      shown.show(key, key == null ? null : _container(), watched: key == null || TickerMode.valuesOf(context).enabled);
      pack = pack?.showing(shown);
    }
    return _BackdropScope(
      picture: picture,
      pack: pack,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _BackdropPainter(
                    top: s.backdropTop,
                    bottom: s.backdropBottom,
                    glowPrimary: widget.glow ? s.glowPrimary : null,
                    glowSecondary: widget.glow ? s.glowSecondary : null,
                    picture: picture,
                    pack: pack,
                  ),
                ),
              ),
            ),
          ),
          Material(type: MaterialType.transparency, child: widget.child),
        ],
      ),
    );
  }
}

/// What [AppBackdrop] paints instead of its gradient: [image], baked to the screen's size (the
/// custom wallpaper), faded in at [fade] over [from] (the picture it replaces; null: the
/// gradient). [image] null fades back to the gradient. The images belong to whoever made this;
/// they must outlive it.
///
/// [live]: the picture moves. Its frames are painted in place of [image], which stays up until
/// the first one is decoded.
@immutable
class BackdropPicture {
  const BackdropPicture({required this.image, this.from, this.fade = kAlwaysCompleteAnimation, this.live});

  final ui.Image? image;
  final ui.Image? from;
  final Animation<double> fade;
  final BackdropLive? live;

  @override
  bool operator ==(Object other) =>
      other is BackdropPicture &&
      other.image == image &&
      other.from == from &&
      other.fade == fade &&
      other.live == live;

  @override
  int get hashCode => Object.hash(image, from, fade, live);
}

/// A moving [BackdropPicture]: the frame up now, and what the bake did to its still (the
/// framing, the blur, the tone), done to each frame as it is painted. Painted by the backdrop's
/// own painter, so a [BackdropVeil] over it moves with it.
@immutable
class BackdropLive {
  const BackdropLive({
    required this.frames,
    required this.window,
    required this.veilTop,
    required this.veilBottom,
    this.sigma = 0,
    this.tone = 0,
  });

  /// The frame to paint; a new one only repaints.
  final ValueListenable<ui.Image?> frames;

  /// The part of a frame the screen shows, in fractions of the frame.
  final Rect window;

  /// The page's gradient: under a see-through frame, and [tone] (0–1) of it over every frame.
  final Color veilTop;
  final Color veilBottom;
  final double tone;

  /// The blur's σ, in dp.
  final double sigma;

  @override
  bool operator ==(Object other) =>
      other is BackdropLive &&
      other.frames == frames &&
      other.window == window &&
      other.veilTop == veilTop &&
      other.veilBottom == veilBottom &&
      other.sigma == sigma &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(frames, window, veilTop, veilBottom, sigma, tone);
}

/// What a theme pack adds to the page's gradient: where the glows sit, a texture, a picture of
/// its own. Null when the theme has none of these, and the page paints as it always has.
@immutable
class _PackLook {
  const _PackLook({
    required this.glow,
    required this.pattern,
    required this.ink,
    required this.pitch,
    required this.pixelRatio,
    this.source,
    this.soften,
    this.picture,
    this.imageOpacity = 0,
    this.imageBlur = 0,
    this.imageAlign = ThemeBackdropAlign.center,
    this.imageRepeat = false,
  });

  final ThemeGlowLayout glow;
  final ThemeBackdropPattern pattern;

  /// The texture's colour, its opacity included.
  final Color ink;

  /// The texture's period (a grain's size), in dp.
  final double pitch;
  final double pixelRatio;

  /// The pack's picture: the file, how a blurred still of it is softened for the page (null:
  /// it isn't blurred), and what a page has of it to paint (null until [showing]).
  final FrameSource? source;
  final _Soften? soften;
  final _PackShown? picture;
  final double imageOpacity;

  /// σ, in dp.
  final double imageBlur;
  final ThemeBackdropAlign imageAlign;

  /// Tiled from the page's corner, a pixel of it a dp; else it covers the page.
  final bool imageRepeat;

  /// What [_packFramesProvider] is asked for.
  (FrameSource, _Soften?)? get key => source == null ? null : (source!, soften);

  /// A pack's picture is decoded for at most this many pixels per dp, this long a side (a tile
  /// longer than that is drawn that much smaller).
  static const _imageDensity = 2.0;
  static const _imageSide = 2048;

  /// Decode sizes move in steps this large, so dragging a window's edge isn't a decode a frame.
  static const _imageStep = 256;

  static _PackLook? of(BuildContext context) {
    final style = DshThemeStyle.of(context);
    final pack = style.pack;
    if (pack == null) return null;
    final s = pack.surfaces;
    final file = s.backdropImage;
    final folder = pack.folderPath;
    final pictured = file != null && folder != null && s.backdropOpacity > 0;
    if (!pictured && s.pattern == ThemeBackdropPattern.none && s.glowLayout == ThemeGlowLayout.corners) return null;
    final theme = Theme.of(context);
    final tokens = theme.brightness == Brightness.dark ? pack.palette.dark : pack.palette.light;
    final ink = tokens.patternInk == null ? theme.colorScheme.onSurface : Color(tokens.patternInk!);
    final pixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    FrameSource? source;
    _Soften? soften;
    if (pictured) {
      final size = MediaQuery.sizeOf(context);
      final k = math.min(pixelRatio, _imageDensity);
      int step(double px) => (px / _imageStep).ceil() * _imageStep;
      source = FrameSource(
        path: '$folder/$file',
        // A tile keeps its own pixels.
        coverWidth: s.backdropRepeat ? _imageSide : step(size.width * k),
        coverHeight: s.backdropRepeat ? _imageSide : step(size.height * k),
        maxSide: _imageSide,
        loop:
            s.backdropAnimate &&
            !(MediaQuery.maybeDisableAnimationsOf(context) ?? false) &&
            !(MediaQuery.maybeHighContrastOf(context) ?? false),
        revision: style.assetRevision,
      );
      if (s.backdropBlur > 0 && !size.isEmpty) {
        soften = _Soften(
          page: size,
          density: WallpaperBake.densityAt(k, s.backdropBlur),
          sigma: s.backdropBlur,
          align: s.backdropAlign,
          repeat: s.backdropRepeat,
        );
      }
    }
    return _PackLook(
      glow: s.glowLayout,
      pattern: s.pattern,
      ink: ink.withValues(alpha: ink.a * s.patternOpacity),
      pitch:
          s.patternScale *
          switch (s.pattern) {
            ThemeBackdropPattern.lines => 28,
            ThemeBackdropPattern.diagonal => 16,
            ThemeBackdropPattern.grain => 0.5,
            _ => 24,
          },
      pixelRatio: pixelRatio,
      source: source,
      soften: soften,
      imageOpacity: s.backdropOpacity,
      imageBlur: s.backdropBlur,
      imageAlign: s.backdropAlign,
      imageRepeat: s.backdropRepeat,
    );
  }

  /// This with [picture] as what a page has of its picture.
  _PackLook showing(_PackShown picture) => _PackLook(
    glow: glow,
    pattern: pattern,
    ink: ink,
    pitch: pitch,
    pixelRatio: pixelRatio,
    source: source,
    soften: soften,
    picture: picture,
    imageOpacity: imageOpacity,
    imageBlur: imageBlur,
    imageAlign: imageAlign,
    imageRepeat: imageRepeat,
  );

  @override
  bool operator ==(Object other) =>
      other is _PackLook &&
      other.glow == glow &&
      other.pattern == pattern &&
      other.ink == ink &&
      other.pitch == pitch &&
      other.pixelRatio == pixelRatio &&
      other.source == source &&
      other.soften == soften &&
      other.picture == picture &&
      other.imageOpacity == imageOpacity &&
      other.imageBlur == imageBlur &&
      other.imageAlign == imageAlign &&
      other.imageRepeat == imageRepeat;

  @override
  int get hashCode => Object.hash(
    glow,
    pattern,
    ink,
    pitch,
    pixelRatio,
    source,
    soften,
    picture,
    imageOpacity,
    imageBlur,
    imageAlign,
    imageRepeat,
  );
}

/// How a blurred still of a pack's picture is softened for a page: the page (dp), the pixels a
/// dp it is done at, and what the painter would otherwise do to the picture every time.
@immutable
class _Soften {
  const _Soften({
    required this.page,
    required this.density,
    required this.sigma,
    required this.align,
    required this.repeat,
  });

  final Size page;
  final double density;

  /// σ, in dp.
  final double sigma;
  final ThemeBackdropAlign align;
  final bool repeat;

  @override
  bool operator ==(Object other) =>
      other is _Soften &&
      other.page == page &&
      other.density == density &&
      other.sigma == sigma &&
      other.align == align &&
      other.repeat == repeat;

  @override
  int get hashCode => Object.hash(page, density, sigma, align, repeat);
}

/// A pack's picture ready to paint: its frames as they come, or, for a still that is blurred,
/// the page's worth of it softened once ([soft]). A blur left to the painter is worked out
/// again on every frame the page is drawn, whether or not anything moved.
class _PackFrames extends ChangeNotifier implements ValueListenable<ui.Image?> {
  _PackFrames(this._frames, this._soften) {
    _frames.addListener(_changed);
    _changed();
  }

  final FrameLoop _frames;
  final _Soften? _soften;

  /// The softened page; this owns it.
  ui.Image? _soft;
  bool _softening = false;
  bool _disposed = false;

  /// Whether [value] is the softened page rather than a frame.
  bool get soft => _soft != null;

  /// No other frame is coming (a still).
  bool get still => _frames.settled;

  /// The picture can't be read.
  bool get broken => _frames.settled && _frames.value == null;

  @override
  ui.Image? get value => _soft ?? (_softening ? null : _frames.value);

  void _changed() {
    final frame = _frames.value;
    final how = _soften;
    if (how != null && frame != null && _frames.settled && _soft == null) {
      if (!_softening) unawaited(_bake(frame, how));
      return;
    }
    notifyListeners();
  }

  Future<void> _bake(ui.Image frame, _Soften how) async {
    _softening = true;
    final width = math.max(1, (how.page.width * how.density).round());
    final height = math.max(1, (how.page.height * how.density).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(width / how.page.width, height / how.page.height);
    _BackdropPainter.paintPicture(
      canvas,
      Offset.zero & how.page,
      frame,
      sigma: how.sigma,
      align: how.align,
      repeat: how.repeat,
    );
    final recording = recorder.endRecording();
    ui.Image? image;
    try {
      image = await recording.toImage(width, height);
    } catch (error) {
      // The frame itself is painted then, blurred as it goes.
      debugPrint('backdrop: softening failed: $error');
    } finally {
      recording.dispose();
    }
    _softening = false;
    if (_disposed) {
      image?.dispose();
      return;
    }
    _soft = image;
    if (image != null) AppBackdrop.softened++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _frames.removeListener(_changed);
    _soft?.dispose();
    _soft = null;
    super.dispose();
  }
}

/// A pack's picture for every page that shows it at one size: one decoder, one softened still.
final _packFramesProvider = Provider.autoDispose.family<_PackFrames, (FrameSource, _Soften?)>((ref, key) {
  final frames = _PackFrames(ref.watch(pictureFramesProvider(key.$1)), key.$2);
  ref.onDispose(frames.dispose);
  return frames;
});

/// A pack's picture as one page shows it: what [_packFramesProvider] has of it, and until that
/// has something (another decode size, the page uncovered again) the picture last shown here.
class _PackShown extends ChangeNotifier {
  (FrameSource, _Soften?)? _key;
  ProviderContainer? _container;
  ProviderSubscription<_PackFrames>? _subscription;
  _PackFrames? _frames;
  bool _watched = true;

  /// The decoder was let go while nobody watches; it comes back when someone does.
  bool _rested = false;

  /// This page's own handle on the picture it last showed, while [_frames] has none.
  ui.Image? _held;
  bool _heldSoft = false;

  /// The picture to paint now.
  ui.Image? get image => _frames?.value ?? _held;

  /// Whether [image] is the page already softened rather than a frame.
  bool get soft => _frames?.value != null ? _frames!.soft : _heldSoft;

  /// Shows [key]'s picture out of [container]; either null (no picture, no providers): nothing.
  /// Not [watched] (the page is covered), a still stays, and an animation's decoder is let go
  /// with its frame left up.
  void show((FrameSource, _Soften?)? key, ProviderContainer? container, {required bool watched}) {
    if (key == null || container == null) {
      if (_key == null) return;
      _close();
      _release();
      _key = null;
      _container = null;
      notifyListeners();
      return;
    }
    var changed = false;
    if (key != _key || !identical(container, _container)) {
      // The same file at another size or revision: what is up stays until that one is in.
      key.$1.path == _key?.$1.path ? _hold() : _release();
      _close();
      _key = key;
      _container = container;
      _rested = false;
      changed = true;
    }
    _watched = watched;
    if (_subscription == null && (watched || !_rested)) {
      final subscription = _subscription = container.listen(_packFramesProvider(key), (_, _) {});
      _frames = subscription.read()..addListener(_changed);
      _rested = false;
      changed = true;
    }
    _settle();
    if (changed) notifyListeners();
  }

  /// With a picture in (or none coming) the one held meanwhile goes. A page nobody watches
  /// then lets a decoder at work go and holds on to its frame.
  void _settle() {
    final frames = _frames;
    if (frames == null) return;
    if (frames.value != null || frames.broken) _release();
    if (!_watched && frames.value != null && !frames.still) {
      _hold();
      _close();
      _rested = true;
    }
  }

  void _changed() {
    _settle();
    notifyListeners();
  }

  void _hold() {
    final frames = _frames;
    final up = frames?.value;
    if (up == null) return;
    final held = up.clone();
    _held?.dispose();
    _held = held;
    _heldSoft = frames!.soft;
  }

  void _release() {
    _held?.dispose();
    _held = null;
  }

  void _close() {
    _frames?.removeListener(_changed);
    _frames = null;
    _subscription?.close();
    _subscription = null;
  }

  @override
  void dispose() {
    _close();
    _release();
    super.dispose();
  }
}

/// The tiles the textures are filled with: white on clear, a period (or a patch of grain)
/// each, tinted as they are drawn so a theme fading between two inks makes no new ones. Made
/// where one is first painted, once per texture, period and screen density, so a texture is
/// there on the page's first frame.
abstract final class _PatternTiles {
  /// Least recently painted first. A tile goes with its shader (the grain's patch stays).
  static final _shaders = <(ThemeBackdropPattern, int, int), (ui.Shader, ui.Image?)>{};

  /// Past this many (someone dragging a scale slider) the one painted longest ago goes.
  static const _most = 32;

  /// A side of the grain's patch, in grains.
  static const _grainSide = 128;

  /// The grain's patch: the same at every grain size, so made once and kept.
  static ui.Image? _grainPatch;

  /// The fill for [pattern] at [period] device pixels a period (a grain), on a screen of
  /// [pixelRatio].
  static ui.Shader shader(ThemeBackdropPattern pattern, int period, double pixelRatio) {
    final key = (pattern, period, (pixelRatio * 100).round());
    var entry = _shaders.remove(key);
    if (entry == null) {
      if (_shaders.length >= _most) {
        final (shader, tile) = _shaders.remove(_shaders.keys.first)!;
        shader.dispose();
        tile?.dispose();
      }
      final grain = pattern == ThemeBackdropPattern.grain;
      final tile = grain ? (_grainPatch ??= _grain()) : _tile(pattern, period, pixelRatio);
      // Whole device pixels, from the page's corner: tiles meet without a seam, and a band of
      // the page repainted elsewhere lands on the same pixels.
      final k = (grain ? period : 1) / pixelRatio;
      final shader = ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.diagonal3Values(k, k, 1).storage,
        filterQuality: grain ? FilterQuality.none : FilterQuality.low,
      );
      entry = (shader, grain ? null : tile);
    }
    // Back in at the end: the one just painted.
    _shaders[key] = entry;
    return entry.$1;
  }

  static ui.Image _tile(ThemeBackdropPattern pattern, int period, double pixelRatio) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final p = period.toDouble();
    final white = Paint()..color = const Color(0xFFFFFFFF);
    // Hairlines: half a dp, on whole pixels.
    final hair = math.max(1, (0.5 * pixelRatio).round()).toDouble();
    var width = period;
    switch (pattern) {
      case ThemeBackdropPattern.dots:
        canvas.drawCircle(Offset(p / 2, p / 2), pixelRatio, white);
      case ThemeBackdropPattern.grid:
        canvas
          ..drawRect(Rect.fromLTWH(0, 0, p, hair), white)
          ..drawRect(Rect.fromLTWH(0, 0, hair, p), white);
      case ThemeBackdropPattern.lines:
        width = 8;
        canvas.drawRect(Rect.fromLTWH(0, p - hair, 8, hair), white);
      case ThemeBackdropPattern.diagonal:
        final stroke = white..strokeWidth = math.max(1, 0.75 * pixelRatio);
        // x + y = 0, p, 2p: the stripe and the two corners its neighbours cross.
        for (var k = 0; k <= 2; k++) {
          canvas.drawLine(Offset(k * p + hair, -hair), Offset(-hair, k * p + hair), stroke);
        }
      case ThemeBackdropPattern.grain || ThemeBackdropPattern.none:
        break;
    }
    return _image(recorder, width, period);
  }

  static ui.Image _grain() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..blendMode = BlendMode.src
      ..isAntiAlias = false;
    // xorshift32 from a fixed seed: the same grain on every device, every run, every frame.
    var x = 0x2545F491;
    for (var i = 0; i < _grainSide * _grainSide; i++) {
      x ^= (x << 13) & 0xFFFFFFFF;
      x ^= x >> 17;
      x ^= (x << 5) & 0xFFFFFFFF;
      // A grain a pixel: white at that alpha.
      paint.color = Color.fromARGB(x & 0xFF, 255, 255, 255);
      canvas.drawRect(Rect.fromLTWH((i % _grainSide).toDouble(), (i ~/ _grainSide).toDouble(), 1, 1), paint);
    }
    return _image(recorder, _grainSide, _grainSide);
  }

  /// What [recorder] drew, there for the frame being painted: an image made off the frame
  /// lands a few frames late, and the texture with it.
  static ui.Image _image(ui.PictureRecorder recorder, int width, int height) {
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }
}

/// What the nearest [AppBackdrop] paints, for the [BackdropVeil]s over it.
class _BackdropScope extends InheritedWidget {
  const _BackdropScope({required this.picture, required this.pack, required super.child});

  final BackdropPicture? picture;
  final _PackLook? pack;

  static _BackdropScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_BackdropScope>();

  @override
  bool updateShouldNotify(_BackdropScope old) => old.picture != picture || old.pack != pack;
}

/// [AppBackdrop] 的一角:同一张背景,只画底部 [solidHeight] + [feather] 这一条,
/// 底部 [solidHeight] 实心,往上 [feather] 缓缓淡出。
///
/// 叠在滚动内容之上、浮动控件(输入条、思考胶囊)之下:内容滑到控件后面时
/// 淡出,控件之间的缝里只露背景,底色不跟着滚动内容闪、也不出现割裂的缝。
/// 不用遮罩去裁内容本身,是因为列表里的玻璃卡片要采样真背景做模糊。
///
/// 渐变和光晕按整屏尺寸算(与 [AppBackdrop] 相同),从页面顶端画起、只留
/// 这一条,所以和真背景严丝合缝;键盘弹起页面变矮时也对得上。要求铺满
/// 整页、和页面左上角对齐。分栏布局里的一栏(宽屏的聊天栏、详情栏)由
/// [BackdropFrame] 告知它在整张背景里的位置,照样对得上。
class BackdropVeil extends StatelessWidget {
  const BackdropVeil({super.key, required this.solidHeight, this.feather = 14, this.glow = true}) : fromTop = false;

  /// 顶部版:从顶边往下 [height] 实心,再往下 [feather] 缓缓淡出(页面顶栏
  /// 后面)。同样要铺满整页、和页面左上角对齐。
  BackdropVeil.top({super.key, required double height, this.feather = 14, this.glow = true})
    : solidHeight = _FixedHeight(height),
      fromTop = true;

  /// 从底边往上实心的高度。由页面布局在排好浮动控件时写入:遮罩画在布局
  /// 之后,不经过重建,这一帧就按新高度画,和控件严丝合缝。
  final ValueListenable<double> solidHeight;

  /// 实心区之外(底部版在上、顶部版在下)的淡出高度。
  final double feather;
  final bool glow;

  /// 顶部版([BackdropVeil.top])。
  final bool fromTop;

  @override
  Widget build(BuildContext context) {
    final s = DshSurfaces.of(context);
    final frame = BackdropFrame.maybeOf(context);
    final scope = _BackdropScope.of(context);
    return IgnorePointer(
      // A layer of its own: a moving picture's next frame repaints the band, not the bars and
      // the list around it.
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _VeilPainter(
            solidHeight: solidHeight,
            feather: feather,
            fromTop: fromTop,
            backdrop: _BackdropPainter(
              top: s.backdropTop,
              bottom: s.backdropBottom,
              glowPrimary: glow ? s.glowPrimary : null,
              glowSecondary: glow ? s.glowSecondary : null,
              area: frame?.area ?? MediaQuery.sizeOf(context),
              origin: frame?.origin ?? Offset.zero,
              picture: scope?.picture,
              // The backdrop's own, its decoded picture with it; a band with no backdrop over it
              // still gets the theme's glows and texture.
              pack: scope == null ? _PackLook.of(context) : scope.pack,
            ),
          ),
        ),
      ),
    );
  }
}

/// A fixed height for [BackdropVeil.top].
class _FixedHeight implements ValueListenable<double> {
  const _FixedHeight(this.value);

  @override
  final double value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool operator ==(Object other) => other is _FixedHeight && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// [BackdropVeil] 的一条:底部实心,往上缓缓淡出(顶部版反过来)。
class _VeilPainter extends CustomPainter {
  _VeilPainter({required this.solidHeight, required this.feather, required this.backdrop, this.fromTop = false})
    : super(repaint: backdrop.signals == null ? solidHeight : Listenable.merge([solidHeight, backdrop.signals]));

  final ValueListenable<double> solidHeight;
  final double feather;
  final _BackdropPainter backdrop;
  final bool fromTop;

  @override
  void paint(Canvas canvas, Size size) {
    final band = (solidHeight.value + feather).clamp(0.0, size.height);
    if (band <= 0) return;
    final rect = fromTop
        ? Rect.fromLTWH(0, 0, size.width, band)
        : Rect.fromLTWH(0, size.height - band, size.width, band);
    final fade = (feather / band).clamp(0.0, 1.0);
    // Eased ramp: a linear one reads as a crease at both ends.
    const samples = 8;
    final stops = <double>[];
    final colors = <Color>[];
    if (fromTop) {
      stops.add(0);
      colors.add(Colors.black);
    }
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      stops.add(fromTop ? 1 - fade + fade * t : fade * t);
      final alpha = Curves.easeInOutCubic.transform(t);
      colors.add(Colors.black.withValues(alpha: fromTop ? 1 - alpha : alpha));
    }
    if (!fromTop) {
      stops.add(1);
      colors.add(Colors.black);
    }

    canvas.saveLayer(rect, Paint());
    canvas.clipRect(rect);
    // The whole backdrop from the page's top, so the band lines up with it.
    backdrop.paint(canvas, size);
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stops,
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VeilPainter old) =>
      old.solidHeight != solidHeight ||
      old.feather != feather ||
      old.fromTop != fromTop ||
      backdrop.shouldRepaint(old.backdrop);
}

class _BackdropPainter extends CustomPainter {
  factory _BackdropPainter({
    required Color top,
    required Color bottom,
    Color? glowPrimary,
    Color? glowSecondary,
    Size? area,
    Offset origin = Offset.zero,
    BackdropPicture? picture,
    _PackLook? pack,
  }) {
    // A cross-fade, a moving picture's next frame, the pack's picture landing or moving.
    final extra = <Listenable?>[picture?.live?.frames, pack?.picture].nonNulls.toList();
    final signals = extra.isEmpty ? picture?.fade : Listenable.merge([picture?.fade, ...extra]);
    return _BackdropPainter._(top, bottom, glowPrimary, glowSecondary, area, origin, picture, pack, signals);
  }

  _BackdropPainter._(
    this.top,
    this.bottom,
    this.glowPrimary,
    this.glowSecondary,
    this.area,
    this.origin,
    this.picture,
    this.pack,
    this.signals,
  ) : super(repaint: signals);

  final Color top;
  final Color bottom;
  final Color? glowPrimary;
  final Color? glowSecondary;

  /// The whole backdrop's size when this paints only a band of it.
  final Size? area;

  /// Where the canvas sits inside [area] (a column of a split layout).
  final Offset origin;

  /// A picture in place of the gradient.
  final BackdropPicture? picture;

  /// What the theme pack adds to the gradient.
  final _PackLook? pack;

  /// What this repaints on, for a [_VeilPainter] to repaint with it.
  final Listenable? signals;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final size = area ?? canvasSize;
    if (area != null) {
      // Only the band: CustomPaint does not clip what is drawn outside it.
      canvas.save();
      canvas.clipRect(Offset.zero & canvasSize);
      canvas.translate(-origin.dx, -origin.dy);
    }
    final picture = this.picture;
    if (picture == null) {
      _gradient(canvas, size);
    } else {
      final t = picture.fade.value;
      if (t < 1) _layer(canvas, size, picture.from);
      if (t > 0) {
        final fading = t < 1;
        if (fading) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, t));
        final live = picture.live;
        final frame = live?.frames.value;
        if (frame == null) {
          _layer(canvas, size, picture.image);
        } else {
          _live(canvas, size, live!, frame);
        }
        if (fading) canvas.restore();
      }
    }
    if (area != null) canvas.restore();
  }

  void _layer(Canvas canvas, Size size, ui.Image? image) {
    if (image == null) {
      _gradient(canvas, size);
      return;
    }
    // Baked to the screen's shape; covers whatever else this is asked to fill.
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final scale = size.isEmpty ? 1.0 : (w / size.width < h / size.height ? w / size.width : h / size.height);
    final src = Rect.fromCenter(center: Offset(w / 2, h / 2), width: size.width * scale, height: size.height * scale);
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
  }

  /// One frame of a moving picture, as the bake would have drawn it: the page's gradient under
  /// it, its window blurred, the tone over it.
  void _live(Canvas canvas, Size size, BackdropLive live, ui.Image frame) {
    final rect = Offset.zero & size;
    final veil = ui.Gradient.linear(rect.topLeft, rect.bottomLeft, [live.veilTop, live.veilBottom]);
    canvas
      ..save()
      ..clipRect(rect)
      ..drawRect(rect, Paint()..shader = veil);
    final w = frame.width.toDouble();
    final h = frame.height.toDouble();
    // The screen's shape, like the bake; covers whatever else this is asked to fill.
    final shown = Rect.fromLTRB(
      live.window.left * w,
      live.window.top * h,
      live.window.right * w,
      live.window.bottom * h,
    );
    final window = _cover(shown.size, size, 0).shift(shown.topLeft);
    _fill(canvas, frame, window, size, live.sigma, Paint()..filterQuality = FilterQuality.medium);
    if (live.tone > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = veil
          ..color = Color.fromRGBO(0, 0, 0, live.tone),
      );
    }
    canvas.restore();
  }

  /// The largest part of a [picture] with the shape of [size]: centred across, and down it at
  /// [alignY] (-1 the top, 1 the bottom).
  static Rect _cover(Size picture, Size size, double alignY) {
    if (size.isEmpty) return Offset.zero & picture;
    final scale = math.min(picture.width / size.width, picture.height / size.height);
    final w = size.width * scale;
    final h = size.height * scale;
    return Rect.fromLTWH((picture.width - w) / 2, (picture.height - h) / 2 * (1 + alignY), w, h);
  }

  /// [window] of [image] over the whole of [size] with [paint], blurred to [sigma] (dp). The
  /// caller clips to the page.
  static void _fill(Canvas canvas, ui.Image image, Rect window, Size size, double sigma, Paint paint) {
    final scale = size.width / window.width;
    final bounds = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    // Past the page's edges the blur takes the picture itself, where there is more of it.
    final src = sigma > 0 ? window.inflate(3 * sigma / scale).intersect(bounds) : window;
    final dst = Rect.fromLTRB(
      (src.left - window.left) * scale,
      (src.top - window.top) * scale,
      (src.right - window.left) * scale,
      (src.bottom - window.top) * scale,
    );
    if (sigma > 0) paint.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.drawImageRect(image, src, dst, paint);
  }

  void _gradient(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(rect),
    );
    final longest = size.longestSide;
    final pack = this.pack;
    final layout = pack?.glow ?? ThemeGlowLayout.corners;
    if (glowPrimary case final color?) {
      final (center, radius) = switch (layout) {
        ThemeGlowLayout.corners || ThemeGlowLayout.top => (Offset(size.width * 0.92, 0), 0.62),
        ThemeGlowLayout.bottom => (Offset(size.width * 0.92, size.height), 0.62),
        ThemeGlowLayout.center => (Offset(size.width * 0.5, size.height * 0.22), 0.7),
      };
      _glow(canvas, center, longest * radius, color);
    }
    if (glowSecondary case final color?) {
      final center = switch (layout) {
        ThemeGlowLayout.corners || ThemeGlowLayout.bottom => Offset(0, size.height),
        ThemeGlowLayout.top => Offset.zero,
        ThemeGlowLayout.center => Offset(size.width * 0.5, size.height),
      };
      _glow(canvas, center, longest * 0.55, color);
    }
    if (pack == null) return;
    final shown = pack.picture;
    if (shown?.image case final image?) {
      final opacity = pack.imageOpacity.clamp(0.0, 1.0);
      if (shown!.soft) {
        _softened(canvas, rect, pack, image, opacity);
      } else {
        paintPicture(
          canvas,
          rect,
          image,
          sigma: pack.imageBlur,
          align: pack.imageAlign,
          repeat: pack.imageRepeat,
          opacity: opacity,
        );
      }
    }
    if (pack.pattern != ThemeBackdropPattern.none) _pattern(canvas, rect, pack);
  }

  void _glow(Canvas canvas, Offset center, double radius, Color color) {
    final bounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0, 1],
        ).createShader(bounds),
    );
  }

  /// A pack's own picture over [page]: covering it (what doesn't fit cut off at [align]), or
  /// tiled from its corner, a pixel of the picture a dp. Blurred to [sigma] (dp) as it is drawn.
  static void paintPicture(
    Canvas canvas,
    Rect page,
    ui.Image image, {
    required double sigma,
    required ThemeBackdropAlign align,
    required bool repeat,
    double opacity = 1,
  }) {
    final paint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, opacity)
      ..filterQuality = FilterQuality.medium;
    canvas
      ..save()
      ..clipRect(page);
    if (repeat) {
      // In dp, so a tile is as large in the hand on every screen.
      final tiles = ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
        filterQuality: FilterQuality.medium,
      );
      paint.shader = tiles;
      if (sigma > 0) paint.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      // Wider than the page, so the blur's own edge falls outside it.
      canvas.drawRect(page.inflate(3 * sigma), paint);
      // What was drawn keeps what it needs of it.
      tiles.dispose();
    } else {
      final window = _cover(Size(image.width.toDouble(), image.height.toDouble()), page.size, _alignY(align));
      _fill(canvas, image, window, page.size, sigma, paint);
    }
    canvas.restore();
  }

  static double _alignY(ThemeBackdropAlign align) => switch (align) {
    ThemeBackdropAlign.top => -1.0,
    ThemeBackdropAlign.center => 0.0,
    ThemeBackdropAlign.bottom => 1.0,
  };

  /// A still already softened for the page ([_PackFrames]), as it is. One made for a page of
  /// another shape (the window is being resized) covers this one, cut the same way.
  void _softened(Canvas canvas, Rect page, _PackLook pack, ui.Image image, double opacity) {
    final window = _cover(Size(image.width.toDouble(), image.height.toDouble()), page.size, _alignY(pack.imageAlign));
    final paint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, opacity)
      ..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(image, window, page, paint);
  }

  /// The pack's texture over all of that: one tile, repeated from the page's corner.
  void _pattern(Canvas canvas, Rect page, _PackLook pack) {
    final grain = pack.pattern == ThemeBackdropPattern.grain;
    final period = math.max(grain ? 1 : 4, (pack.pitch * pack.pixelRatio).round());
    canvas.drawRect(
      page,
      Paint()
        ..shader = _PatternTiles.shader(pack.pattern, period, pack.pixelRatio)
        ..colorFilter = ColorFilter.mode(pack.ink, BlendMode.srcIn),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.top != top ||
      old.bottom != bottom ||
      old.glowPrimary != glowPrimary ||
      old.glowSecondary != glowSecondary ||
      old.area != area ||
      old.origin != origin ||
      old.picture != picture ||
      old.pack != pack;
}
