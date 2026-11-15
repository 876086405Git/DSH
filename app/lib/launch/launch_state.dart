// 启动画面：系统的启动窗口（Android 12+ 的启动画面，或 8–11 的启动窗口背景）交给
// App 自己的启动画面，中间看不出切换；再在界面可用时收起，不为动画多等一刻。
//
// 原生侧：android/.../launch/LaunchScreen.kt（MethodChannel `dsh/launch`）；鸿蒙是
// ohos/.../LaunchPlugin.ets，只有默认动画，系统启动页自己淡出（systemSplash 为 false）；iOS 是
// Runner/LaunchChannel.swift，系统启动页是一页空白的系统底色，首帧画同一页，图标随动画进来。
//
//   main()             begin：系统画了什么（图标像素、方块大小、底色）→ 首帧原样画出
//   首帧               Android 12+：系统启动画面盖在首帧上，原生量出它的图标位置送来
//                      （systemSplash）→ 按量到的位置再画一帧 → reveal：系统画面淡出
//   交接完成           动画开始（launch_motion.dart）；8–11 首帧即开始
//   RootGate 出界面    ready：自定义画面每次 App 冷启动都按它本身的长度播完一轮，不设上限，
//                      引擎在跑、现起还是没开都一样（轻量模式也播，只有系统要求减少动画时停在
//                      首帧、不等）；默认动画只在引擎这次现起时播完一遍（1.36 s，引擎先就绪
//                      就提前收），引擎早已在跑、没自动启动、或轻量 / 减少动画时界面可用就收，
//                      播到哪算哪。轻点屏幕随时跳过
//
// 系统阶段画不画图标（systemIcon）：清单里的启动主题画不了用户选的桌面图标（activity-alias
// 不能各有主题），所以只铺页面底色；Android 13+ 由原生把下一次启动的启动主题换成所选图标
// 自己的（launch/LaunchThemes.kt），那时系统画的就是它。没有图标时，App 在动画开头把图标淡入。
//
// 没有原生侧（测试、其他平台）或这次不是冷启动：没有启动画面，RootGate 照旧。

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'custom_launch.dart';
import 'launch_media.dart';
import 'startup_trace.dart';

/// What the launch window shows, as `begin` reports it.
class LaunchSnapshot {
  const LaunchSnapshot({
    required this.sdk,
    required this.systemSplash,
    required this.iconPx,
    required this.background,
    required this.backgroundBottom,
    required this.dark,
    this.icon,
    this.coldEngine = false,
    this.systemIcon = true,
  });

  /// Android API level.
  final int sdk;

  /// Android 12+'s splash will be handed over (measured, then faded out over the first frame).
  final bool systemSplash;

  /// The icon's square, physical pixels.
  final int iconPx;

  /// The icon as the launch window draws it, [iconPx] square; null when it couldn't be drawn.
  final ui.Image? icon;

  /// The page colour (12+: flat; 8–11: the top of a gradient to [backgroundBottom]).
  final Color background;
  final Color backgroundBottom;

  /// The system is in dark mode (the launch window follows it, not the app's own setting).
  final bool dark;

  /// A cold start of the engine (native `LaunchEngine.cold`): it wasn't running when this
  /// process's first activity was created, and the app's early start (LaunchStart) is starting
  /// it now. Nothing can be asked until it answers, so the launch screen plays its whole motion.
  final bool coldEngine;

  /// The system's launch window shows [icon] (Android 13+ with the chosen icon's own splash theme).
  /// Otherwise it shows the page colour alone, and the launch screen brings the icon in.
  final bool systemIcon;

  /// Android 12+ lays a flat colour; 8–11 the launch window's gradient.
  bool get flat => sdk >= 31;

  /// The icon's square for a screen of [size] (logical) at [dpr]: centred the way the system
  /// centres it, by whole pixels.
  Rect iconRect(Size size, double dpr) {
    final width = (size.width * dpr).round();
    final height = (size.height * dpr).round();
    final left = (width - iconPx) ~/ 2;
    final top = (height - iconPx) ~/ 2;
    return Rect.fromLTWH(left / dpr, top / dpr, iconPx / dpr, iconPx / dpr);
  }

  /// From `begin`'s answer; null when there's no launch screen this time.
  static Future<LaunchSnapshot?> fromMap(Map<Object?, Object?>? raw) async {
    if (raw == null || raw['active'] != true) return null;
    final sdk = raw['sdk'];
    final iconPx = raw['iconPx'];
    final background = raw['background'];
    if (sdk is! int || iconPx is! int || iconPx <= 0 || background is! int) return null;
    final bottom = raw['backgroundBottom'];
    final pixels = raw['icon'];
    ui.Image? icon;
    if (pixels is Uint8List && pixels.length == iconPx * iconPx * 4) {
      icon = await _decode(pixels, iconPx);
    }
    return LaunchSnapshot(
      sdk: sdk,
      systemSplash: raw['systemSplash'] == true,
      iconPx: iconPx,
      icon: icon,
      background: Color(background),
      backgroundBottom: Color(bottom is int ? bottom : background),
      dark: raw['dark'] == true,
      coldEngine: raw['coldEngine'] == true,
      systemIcon: raw['systemIcon'] != false,
    );
  }

  static Future<ui.Image?> _decode(Uint8List rgba, int side) {
    final done = Completer<ui.Image?>();
    try {
      ui.decodeImageFromPixels(rgba, side, side, ui.PixelFormat.rgba8888, done.complete);
    } catch (_) {
      done.complete(null);
    }
    return done.future.timeout(const Duration(milliseconds: 400), onTimeout: () => null);
  }
}

/// The native side (`dsh/launch`).
class LaunchChannel {
  const LaunchChannel([this.channel = const MethodChannel('dsh/launch')]);

  final MethodChannel channel;

  Future<Map<Object?, Object?>?> begin() => _call<Map<Object?, Object?>>('begin');

  /// Fades Android 12+'s splash away; true once it is gone, false when there was none.
  Future<bool> reveal() async => await _call<bool>('reveal') ?? false;

  /// A point on the launch timeline (`firstFrame`, `ready`): the log line comes from these.
  Future<void> mark(String name) => _call<void>('mark', {'name': name});

  Future<void> done() => _call<void>('done');

  /// What the launch window shows now, for a preview (the icon of the current entry).
  Future<Map<Object?, Object?>?> snapshot() => _call<Map<Object?, Object?>>('snapshot');

  /// Android 12+'s splash, measured: its icon's square (logical, from the Flutter view's
  /// corner), or null when it shows none; `removed` when it was exactly where the first frame
  /// drew it and the native side has already taken it away.
  void listen(void Function(Rect? icon, {bool removed}) onSystemSplash) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'systemSplash') return;
      final raw = call.arguments;
      final icon = raw is Map ? raw['icon'] : null;
      final removed = raw is Map && raw['removed'] == true;
      onSystemSplash(
        removed: removed,
        icon is List && icon.length == 4 && icon.every((v) => v is num)
            ? Rect.fromLTWH(
                (icon[0] as num).toDouble(),
                (icon[1] as num).toDouble(),
                (icon[2] as num).toDouble(),
                (icon[3] as num).toDouble(),
              )
            : null,
      );
    });
  }

  void stopListening() => channel.setMethodCallHandler(null);

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Where the launch screen is.
enum LaunchPhase {
  /// The system's picture, redrawn: waiting for Android 12+'s splash to hand over.
  cover,

  /// The motion runs (or a custom launch screen fades in and plays).
  playing,

  /// The app is usable: the whole layer fades away.
  leaving,

  /// Gone for good.
  gone,
}

/// The launch screen of this run: one per cold start ([current]), driven by the overlay
/// (lib/ui/launch/launch_overlay.dart), the native side and RootGate's [ready].
class LaunchController extends ChangeNotifier {
  LaunchController({
    required this.snapshot,
    this.custom,
    this.channel = const LaunchChannel(),
    this.handOverWait = const Duration(milliseconds: 700),
    this.native = true,
  });

  /// This cold start's launch screen; null once it is gone or when there is none.
  static final active = ValueNotifier<LaunchController?>(null);

  final LaunchSnapshot snapshot;

  /// The user's own launch screen, if any (its media opens while the system picture shows).
  final CustomLaunch? custom;

  final LaunchChannel channel;

  /// How long after the first frame to wait for Android 12+'s splash before playing anyway
  /// (a system that doesn't hand it over has already taken it away itself).
  final Duration handOverWait;

  /// Talks to the native side (false: a preview inside the app).
  final bool native;

  LaunchPhase _phase = LaunchPhase.cover;
  LaunchPhase get phase => _phase;

  Rect? _measured;
  late bool _systemIcon = snapshot.systemIcon;
  bool _ready = false;
  bool _firstFrame = false;
  bool _handingOver = false;
  Timer? _handOverTimer;
  bool _waitsForEngine = true;
  bool _engineReady = false;
  bool _motionDone = false;
  bool _reduced = false;
  bool _skipped = false;
  LaunchMedia? _media;
  bool _mediaFailed = false;

  /// The custom launch screen's picture, once it can be shown; null before (or without).
  LaunchMedia? get media => _media;

  /// A custom launch screen was set but couldn't be read: the default motion plays instead.
  bool get mediaFailed => _mediaFailed;

  /// The custom launch screen will show (set, and not failed).
  bool get showsCustom => custom != null && !_mediaFailed;

  final _mediaDone = Completer<void>();

  /// The custom picture has played its one round (a still: as soon as it shows).
  Future<void> get mediaDone => _mediaDone.future;

  /// The overlay's report that the picture has come to rest.
  void mediaFinished() {
    if (!_mediaDone.isCompleted) _mediaDone.complete();
  }

  /// The icon's square on a screen of [size] at [dpr]: where Android 12+'s splash was measured,
  /// else where the system centres it.
  Rect iconSquare(Size size, double dpr) => _measured ?? snapshot.iconRect(size, dpr);

  /// The system's picture has the icon in it (else the page alone: the icon comes in as the
  /// motion starts).
  bool get systemIcon => _systemIcon;

  static bool _gaveUp = false;

  /// main(): [begin] took too long and the app has gone on without it. An answer that still comes
  /// is ignored: the launch screen would lie over a page that has already said it's ready, and
  /// nothing would ever take it away.
  static void giveUp() => _gaveUp = true;

  @visibleForTesting
  static void resetGaveUp() => _gaveUp = false;

  /// main(): asks the native side what the launch window shows. Null when there's no launch
  /// screen this time (no native side, a warm start).
  static Future<LaunchController?> begin({LaunchChannel channel = const LaunchChannel(), Size? screen}) async {
    try {
      final snapshot = await LaunchSnapshot.fromMap(await channel.begin());
      if (snapshot == null) return null;
      final stored = await CustomLaunch.load();
      final custom = stored != null && stored.on ? stored : null;
      if (_gaveUp) {
        snapshot.icon?.dispose();
        return null;
      }
      final controller = LaunchController(snapshot: snapshot, custom: custom, channel: channel);
      channel.listen(controller.handOver);
      if (custom != null) unawaited(controller.openMedia(screen ?? _screen()));
      active.value = controller;
      return controller;
    } catch (_) {
      unawaited(channel.done());
      return null;
    }
  }

  static Size _screen() {
    final views = ui.PlatformDispatcher.instance.views;
    return views.isEmpty ? const Size(1080, 2400) : views.first.physicalSize;
  }

  /// Opens the custom launch screen's picture ([screen] in physical pixels), off the first frame.
  Future<void> openMedia(Size screen) async {
    final custom = this.custom;
    if (custom == null) return;
    final media = await LaunchMedia.open(custom, screen: screen);
    if (_phase == LaunchPhase.gone) {
      media?.dispose();
      return;
    }
    if (media == null) {
      _mediaFailed = true;
    } else {
      _media = media;
    }
    notifyListeners();
    // Unreadable: the default motion's rules from now on.
    _leaveIfDone();
  }

  /// Sets the custom picture directly (tests: no file to open).
  @visibleForTesting
  void useMedia(LaunchMedia media) {
    _media = media;
    notifyListeners();
  }

  /// The overlay's first frame is out.
  void firstFrame() {
    if (_firstFrame) return;
    _firstFrame = true;
    if (native) unawaited(channel.mark('firstFrame'));
    if (!snapshot.systemSplash) return _play();
    _handOverTimer = Timer(handOverWait, _play);
  }

  /// Android 12+'s splash lies over the first frame, measured ([icon]: null when it shows none):
  /// draw the same picture, then fade it out over it. [removed]: it was exactly the first frame's
  /// picture and the native side has taken it away already.
  Future<void> handOver(Rect? icon, {bool removed = false}) async {
    if (_handingOver || _phase == LaunchPhase.gone) return;
    _handingOver = true;
    _handOverTimer?.cancel();
    if (removed) return _play();
    if (_phase == LaunchPhase.cover) {
      _measured = icon;
      _systemIcon = icon != null;
      notifyListeners();
      // The matching frame is built, then one more so it is on the screen before the splash
      // starts to fade.
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    await channel.reveal();
    if (native) unawaited(channel.mark('handedOver'));
    _play();
  }

  /// The app is usable (RootGate shows its first page). A custom picture plays its round first;
  /// the default motion finishes first only on a cold start of the engine, unless the engine is up
  /// sooner; otherwise the launch screen leaves now. [waitsForEngine]: the first page talks to this
  /// phone's engine (not a remote host's).
  void ready({bool waitsForEngine = true}) {
    if (_ready) return;
    _ready = true;
    _waitsForEngine = waitsForEngine;
    if (native) unawaited(channel.mark('ready'));
    if (_phase == LaunchPhase.playing) {
      _leaveIfDone();
    } else if (_phase == LaunchPhase.cover && _firstFrame && !_handingOver && !_coldHold) {
      // Still waiting for Android 12+'s splash: the app doesn't wait the whole of
      // [handOverWait] for it. A splash that comes later dissolves straight onto the app.
      _handOverTimer?.cancel();
      _handOverTimer = Timer(readyWait, _play);
    }
  }

  /// With the app ready, how much longer to wait for the system's splash to be handed over.
  static const readyWait = Duration(milliseconds: 200);

  /// What the launch screen still covers (before the hand-over too), with motion allowed: the
  /// user's own picture on every cold start of the app, whatever the engine is doing (opening, then
  /// its whole round); the default motion only while this phone's engine starts cold.
  bool get _coldHold =>
      !_skipped && !_reduced && (showsCustom || (snapshot.coldEngine && _waitsForEngine && !_engineReady));

  /// Whether the launch screen stays although the app is ready: a custom picture for its whole
  /// round however long (the engine running, starting or off); the default motion on a cold start
  /// of the engine, until it ends or the engine answers. A tap ends either.
  bool get holds => _coldHold && !_motionDone;

  /// A tap on the launch screen: it goes now.
  void skip() {
    if (_skipped || _phase == LaunchPhase.leaving || _phase == LaunchPhase.gone) return;
    _skipped = true;
    if (native) unawaited(channel.mark('skipped'));
    if (_phase != LaunchPhase.playing) return;
    _phase = LaunchPhase.leaving;
    notifyListeners();
  }

  /// The engine answers (its phase is running): a cold start's motion needn't finish.
  void engineReady() {
    if (_engineReady) return;
    _engineReady = true;
    if (native) unawaited(channel.mark('engine'));
    _leaveIfDone();
  }

  /// The motion has come to rest (the default one played through, or the custom picture its
  /// round).
  void motionDone() {
    if (_motionDone) return;
    _motionDone = true;
    _leaveIfDone();
  }

  /// 减少动画, as the overlay finds it for what shows (the user's own picture: the system's
  /// setting alone, not a light phone's): nothing plays, so nothing is waited for.
  bool get reduced => _reduced;
  set reduced(bool value) {
    if (_reduced == value) return;
    _reduced = value;
    _leaveIfDone();
  }

  void _leaveIfDone() {
    if (_phase != LaunchPhase.playing || !_ready || holds) return;
    _phase = LaunchPhase.leaving;
    notifyListeners();
  }

  void _play() {
    _handOverTimer?.cancel();
    if (_phase != LaunchPhase.cover) return;
    _phase = _skipped ? LaunchPhase.leaving : LaunchPhase.playing;
    notifyListeners();
    _leaveIfDone();
  }

  /// The overlay has faded out.
  void gone() {
    if (_phase == LaunchPhase.gone) return;
    _phase = LaunchPhase.gone;
    _handOverTimer?.cancel();
    if (native) {
      channel.stopListening();
      unawaited(channel.done());
      // Tapped away before the first page: RootGate says so when that comes.
      if (_ready) StartupTrace.finished();
    }
    if (identical(active.value, this)) active.value = null;
    notifyListeners();
    // Nothing draws them after this frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _media?.dispose();
      _media = null;
      snapshot.icon?.dispose();
    });
  }
}
