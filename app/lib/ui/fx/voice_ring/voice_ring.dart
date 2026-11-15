// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// VoiceRing (VoiceRing.tsx, VoiceOrb.tsx, presets.ts): the two aura types of
// the author's voice orbs. Every frame the follower reads the level, shapes
// and smooths it, the type's geometry is built, leaned toward the voice, and
// painted — as light for `ring`, as lit tubes for `mono`.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'aura.dart';
import 'frame.dart';
import 'lean.dart';
import 'light.dart';
import 'refract.dart';
import 'tube.dart';
import 'voice.dart';

export 'aura.dart' show auraSpectrum;
export 'frame.dart' show SpectrumStop;
export 'voice.dart' show VoiceRingEmotion, VoiceRingLevel;

/// 光环的画法：`ring` 一条带光谱的玻璃光带；`mono` 两圈灰色管子，有声音时张开成转动的球。
enum VoiceRingType { ring, mono }

/// 对话状态：
/// - `idle` 等人开口：不听输入，很慢地漂；
/// - `listening` 轮到用户：跟着 [VoiceRing.level]（通常是麦克风）；
/// - `speaking` 轮到助手：跟着 [VoiceRing.level]（通常是朗读播放）；
/// - `processing` 在想：不听输入，各自的「干活」动作（光谱转圈、高光扫过）。
enum VoiceRingState { idle, listening, speaking, processing }

/// 深浅：`auto` 跟 `Theme.of(context).brightness`。
enum VoiceRingTheme { auto, dark, light }

/// 光环的颜色：`ring` 的光谱，和一个可选的整体染色（作者的 `color`）。
@immutable
class VoiceRingPalette {
  const VoiceRingPalette({required this.spectrum, this.tint});

  /// 作者原版的光谱：珊瑚、粉、紫、蓝。
  static const VoiceRingPalette original = VoiceRingPalette(spectrum: auraSpectrum);

  /// 跟主题色走：作者的光谱换成主色相邻的几种色相（作者给情绪换色的同一套算法，
  /// 左右各摆 36°），再在 OKLab 里把彩度压到 0.65；灰主题（石墨）只留一点颜色。
  /// 明暗沿用作者每一档自己的亮度，所以光带的冷暖起伏还在。
  factory VoiceRingPalette.of(ColorScheme scheme) {
    final p = scheme.primary;
    final r = p.r * 255;
    final g = p.g * 255;
    final b = p.b * 255;
    final hue = toHsl(r, g, b).$1;
    final (_, la, lb) = toLab(r, g, b);
    // every preset but graphite clears 0.045 even in its paler dark-theme primary
    final colourful = smoothstep(0.012, 0.045, math.sqrt(la * la + lb * lb));
    final themed = [for (final s in auraSpectrum) recolourStop(s, hue, spectrumSwing, 1)];
    return VoiceRingPalette(spectrum: gradeSpectrum(themed, chroma: 0.65 * (0.18 + 0.82 * colourful)));
  }

  /// `[offset 0–1, r, g, b(0–255)]`，从正上方顺时针读，最后一档回到第一档。
  final List<SpectrumStop> spectrum;

  /// 整体染色：`ring` 的光谱往它靠 85%，`mono` 的灰管换成它的明暗。
  final Color? tint;

  @override
  bool operator ==(Object other) =>
      other is VoiceRingPalette && other.tint == tint && listEquals(other.spectrum, spectrum);

  @override
  int get hashCode => Object.hash(tint, Object.hashAll(spectrum));
}

/// 会听的光环（Libraries.dev Voice ring 的移植）。
///
/// 只画，不开麦克风：[level] 由外面给，每帧读一次。App 的通话电平是 dB 映射过的，
/// 先过 [VoiceRingLevel.mic] / [VoiceRingLevel.playback] 再给它。
///
/// 布局占 [size]×[size]；给了 [direction] 时会朝那边倾、画到盒子外面去（最多到屏幕
/// 边缘前 32 像素），盒子本身不变。系统「减弱动态」时环境动作全停，只有声音还会让它
/// 变大变亮，和作者一样；没声音可跟时只画一张静止帧。
class VoiceRing extends StatefulWidget {
  const VoiceRing({
    super.key,
    this.type = VoiceRingType.ring,
    this.state = VoiceRingState.listening,
    this.size = 160,
    this.level,
    this.sensitivity = 0.85,
    this.speed = 1,
    this.theme = VoiceRingTheme.auto,
    this.emotion,
    this.direction,
    this.palette,
    this.paused = false,
    this.semanticLabel,
  });

  final VoiceRingType type;

  /// 状态切换是缓过去的，不会跳。
  final VoiceRingState state;

  /// 逻辑像素，按 200 设计。
  final double size;

  /// 0–1 的音量，每帧读一次；`listening` / `speaking` 才听。
  final double Function()? level;

  /// 输入增益，安静的来源调高。
  final double sensitivity;

  /// 时钟倍速。
  final double speed;

  final VoiceRingTheme theme;

  /// 情绪：颜色缓缓染进来、互相交叉淡变，null 时淡出。
  final VoiceRingEmotion? emotion;

  /// 声音从哪边来，−1 左 … 1 右；有声音时朝那边倾，静下来回中间。null 不倾。
  final double? direction;

  /// null 时跟主题色（[VoiceRingPalette.of]）；[VoiceRingPalette.original] 是作者原色。
  final VoiceRingPalette? palette;

  /// 停在当前帧。
  final bool paused;

  final String? semanticLabel;

  @override
  State<VoiceRing> createState() => _VoiceRingState();
}

class _VoiceRingState extends State<VoiceRing> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _RingEngine _engine = _RingEngine();
  bool _reduced = false;
  bool _dark = true;
  double _dpr = 1;
  double _screenWidth = double.infinity;
  ColorScheme? _paletteScheme;
  VoiceRingPalette? _themePalette;
  Object? _stillKey;
  double? _lastStep;
  double? _lastPaint;
  double _lastMeasure = double.negativeInfinity;

  bool get _loops => !widget.paused && (!_reduced || widget.level != null || widget.state == VoiceRingState.processing);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
  }

  @override
  void didUpdateWidget(VoiceRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configure();
  }

  void _configure() {
    _reduced = AppMotion.reduced(context);
    _dark = switch (widget.theme) {
      VoiceRingTheme.auto => Theme.of(context).brightness == Brightness.dark,
      VoiceRingTheme.dark => true,
      VoiceRingTheme.light => false,
    };
    _dpr = MediaQuery.devicePixelRatioOf(context);
    _screenWidth = MediaQuery.sizeOf(context).width;
    var palette = widget.palette;
    if (palette == null) {
      final scheme = Theme.of(context).colorScheme;
      if (scheme != _paletteScheme) {
        _paletteScheme = scheme;
        _themePalette = VoiceRingPalette.of(scheme);
      }
      palette = _themePalette!;
    }
    final w = widget;
    _engine.configure(w.type, w.size, palette, hasDirection: w.direction != null);
    if (w.type == VoiceRingType.ring && w.direction != null) EdgeLens.load();

    if (_loops) {
      if (!_ticker.isActive) {
        // the gap while stopped is not time the ring lived through
        _lastStep = null;
        _lastPaint = null;
        _ticker.start();
      }
      if (_engine.frame == null) _step(1 / 60);
      _stillKey = null;
    } else {
      if (_ticker.isActive) _ticker.stop();
      // a still ring repaints once when what it shows changes
      final key = Object.hash(w.type, w.size, w.state, w.emotion, w.direction, w.speed, palette, _dark, _reduced);
      if (key != _stillKey || _engine.frame == null) {
        _stillKey = key;
        _step(1 / 60);
      }
    }
  }

  void _tick(Duration elapsed) {
    final now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    // 120 Hz would double the paint work for no visible gain
    if (_lastPaint != null && now - _lastPaint! < 1 / 62) return;
    _lastPaint = now;
    final dt = _lastStep == null ? 1 / 60 : math.min(0.05, now - _lastStep!);
    _lastStep = now;
    if (widget.direction != null && now - _lastMeasure >= 0.5) {
      _lastMeasure = now;
      _measure();
    }
    _step(dt);
  }

  /// The room from the ring's box to the screen's edges, short by the margin.
  void _measure() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final x = box.localToGlobal(Offset.zero).dx;
    _engine.setRoom(
      math.max(0, (x - leanMargin).floorToDouble()),
      math.max(0, (_screenWidth - x - widget.size - leanMargin).floorToDouble()),
    );
  }

  void _step(double dt) {
    final w = widget;
    _engine.step(
      dt,
      state: w.state,
      level: w.level,
      sensitivity: w.sensitivity,
      speed: w.speed,
      emotion: w.emotion,
      direction: w.direction,
      reduced: _reduced,
      paused: w.paused,
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _RingPainter(_engine, dark: _dark, dpr: _dpr),
      ),
    );
    final label = widget.semanticLabel;
    return label == null ? ring : Semantics(image: true, label: label, child: ring);
  }
}

/// A type's tuning (presets.ts), designed at 200 px.
class _Preset {
  const _Preset({
    required this.speed,
    required this.driveGain,
    required this.voiceSpeed,
    required this.segs,
    required this.minSegs,
    required this.lean,
  });

  /// Ring seconds per real second, on both clocks.
  final double speed;

  /// The voice clock runs at 1 + driveGain × level.
  final double driveGain;

  /// How much a voice speeds the type up.
  final double voiceSpeed;

  /// Segments per ring at 200 px; they scale with size^0.5.
  final int segs;
  final int minSegs;
  final LeanAmounts lean;

  int segsAt(double size) {
    final scale = (size / 200).clamp(0.2, 1.4);
    return math.max(minSegs, (segs * math.sqrt(scale)).round());
  }
}

const _ringPreset = _Preset(speed: 1.6, driveGain: 2, voiceSpeed: 0.9, segs: 140, minSegs: 24, lean: ringLean);
// a voice spins mono up a long way: waiting it drifts, speaking it turns and
// morphs quickly
const _monoPreset = _Preset(speed: 1.2, driveGain: 4, voiceSpeed: 1, segs: 180, minSegs: 48, lean: monoLean);

// The follower's defaults (VoiceOrb props): noise gate, rise and settle
// times, the breathing kept under the voice, and the waiting pace.
const double _threshold = 0.04;
const double _attack = 0.06;
const double _release = 0.32;
const double _idle = 0.1;
const double _calm = 0.4;

/// One ring's living state, stepped once per drawn frame; the painter
/// listens to it.
class _RingEngine extends ChangeNotifier {
  final VoiceFollower _follower = VoiceFollower();
  final GlowFollower _glow = GlowFollower();
  final EdgeBounce _bounce = EdgeBounce();
  final LightPainter _light = LightPainter();
  final TubePainter _tube = TubePainter();
  final EdgeLens _lens = EdgeLens();
  final Paint _isolate = Paint();
  double _press = 0;

  VoiceRingType _type = VoiceRingType.ring;
  _Preset _preset = _ringPreset;
  double _size = 160;
  AuraFrameBuilder? _aura;
  MonoFrameBuilder? _mono;
  Rgb? _tint;
  Color? _tintColor;
  bool _hasDirection = false;
  double _roomLeft = double.infinity;
  double _roomRight = double.infinity;

  OrbFrame? frame;

  void configure(VoiceRingType type, double size, VoiceRingPalette palette, {required bool hasDirection}) {
    _type = type;
    _size = size;
    _hasDirection = hasDirection;
    _preset = type == VoiceRingType.ring ? _ringPreset : _monoPreset;
    final segs = _preset.segsAt(size);
    if (type == VoiceRingType.ring) {
      if (_aura?.segs != segs) _aura = AuraFrameBuilder(segs: segs);
      _aura!.stops = palette.spectrum;
    } else if (_mono?.segs != segs) {
      _mono = MonoFrameBuilder(segs: segs);
    }
    if (palette.tint != _tintColor) {
      final t = _tintColor = palette.tint;
      _tint = t == null ? null : Rgb(t.r * 255, t.g * 255, t.b * 255);
    }
  }

  void setRoom(double left, double right) {
    if ((left - _roomLeft).abs() > 1 || (right - _roomRight).abs() > 1) {
      _roomLeft = left;
      _roomRight = right;
    }
  }

  /// How far the canvas may reach past the box: as far as the lean can carry
  /// the ring, but no further than the edge of the screen.
  double get _reach => _hasDirection ? leanReach(_preset.lean, _size) : 0;
  double get _left => math.min(_reach, _roomLeft);
  double get _right => math.min(_reach, _roomRight);

  void step(
    double dt, {
    required VoiceRingState state,
    required double Function()? level,
    required double sensitivity,
    required double speed,
    required VoiceRingEmotion? emotion,
    required double? direction,
    required bool reduced,
    required bool paused,
  }) {
    final f = _follower;
    // waiting and processing do not listen, whatever is attached
    final hears = state == VoiceRingState.listening || state == VoiceRingState.speaking;
    if (hears && level != null) {
      f.readLevel(level(), sensitivity);
    } else {
      f.readSilence();
    }
    final voice = f.step(
      dt,
      threshold: _threshold,
      attack: _attack,
      release: _release,
      idle: _idle,
      driveGain: _preset.driveGain * _preset.voiceSpeed,
      calm: _calm,
      rate: _preset.speed * speed,
      processing: state == VoiceRingState.processing,
      direction: direction ?? 0,
      still: reduced,
    );
    // a still ring shows the emotion at once
    _glow.step(dt, emotion == null ? null : emotionColors[emotion], f.clock, still: paused || reduced);
    final built = _type == VoiceRingType.ring ? _aura!.build(_size, f.t, voice) : _mono!.build(_size, f.t, voice);
    // the bounce off the edge chases how hard the last frame pressed on it
    final hit = paused || reduced ? 0.0 : _bounce.step(_press, dt);
    leanFrame(built, voice.pan, _size, _preset.lean, roomLeft: _left, roomRight: _right, bounce: hit);
    _press = built.contact?.press ?? 0;
    frame = built;
    notifyListeners();
  }

  void paint(Canvas canvas, {required bool dark, required double dpr}) {
    final f = frame;
    if (f == null) return;
    // the canvas reaches on into the margin, so a glow fades out there
    // instead of being cut at the bound
    final pad = _reach > 0 ? leanMargin : 0.0;
    final box = Rect.fromLTRB(-(_left + pad), 0, _size + _right + pad, _size);
    void marks(Canvas c) {
      c
        ..save()
        ..clipRect(box)
        ..saveLayer(box, _isolate);
      if (f.light != null) {
        _light.paint(c, f, dark: dark, bounds: box, tint: _tint, glow: _glow);
      } else {
        _tube.paint(c, f, dark: dark, tint: _tint, glow: _glow);
      }
      c
        ..restore()
        ..restore();
    }

    final contact = f.contact;
    final lens = contact?.lens;
    final program = EdgeLens.program;
    if (contact != null && lens != null && program != null) {
      _lens.paint(canvas, box, dpr, contact, lens, program, marks);
    } else {
      marks(canvas);
    }
  }

  @override
  void dispose() {
    _lens.dispose();
    super.dispose();
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.engine, {required this.dark, required this.dpr}) : super(repaint: engine);

  final _RingEngine engine;
  final bool dark;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) => engine.paint(canvas, dark: dark, dpr: dpr);

  @override
  bool shouldRepaint(_RingPainter old) => old.engine != engine || old.dark != dark || old.dpr != dpr;
}
