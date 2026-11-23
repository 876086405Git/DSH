// The WebView that draws the companion (app/assets/companion/). Everything
// Live2D happens in there; this widget serves it, passes commands in and events
// out, and pauses it when nobody can see it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../companion/companion_adapt.dart';
import '../../companion/companion_moves.dart';
import '../../companion/companion_pack.dart';
import '../../companion/companion_server.dart';
import '../../pets/pet_pack_validator.dart' show pngIntact, pngSize;
import '../../workshop/workshop_models.dart' show workshopPreviewBytes, workshopPreviewSide;
import '../plugins/islands/island_platform.dart';
import '../web/web_view_guard.dart';

/// Phones with less memory than this get a smaller texture (4096² is about
/// 64 MB of GPU memory, more with mipmaps).
// Physical memory reported by iOS is slightly below the marketed RAM size;
// this separates the 4 GB and 6 GB device classes without a model-name list.
const _bigTextureFromBytes = 5 * 1024 * 1024 * 1024;

/// At or below this, the smallest budget: a 3 GB iPhone reports a little less.
const _lowMemoryBytes = 3 * 1024 * 1024 * 1024;

/// Where her stage's resolution last settled on this phone (stage.js `quality`).
const _qualityKey = 'companion_stage_quality';

/// Where the person pinched her to in the room, per character: `<prefix><character key>`.
const _viewKeyPrefix = 'companion_room_view:';

/// The page's start-up options for this phone (stage.js and scene.js read them).
///
/// Memory sets what the page can't take back once WebKit or the GPU has run out
/// (the page is killed, a white screen): how big her textures are and, on the
/// smallest iPhones, how dense the canvases are and whether blur layers exist.
/// How fast the phone draws isn't guessed from it: the stage measures that and
/// sheds resolution itself, starting where it settled last time ([quality]).
@visibleForTesting
Map<String, String> companionStageQuery({
  required bool ios,
  required int totalMem,
  double? quality,
  bool reduceMotion = false,
  bool bare = false,
}) {
  // WebKit's GPU-process budget is separate from the phone's RAM.
  final small = totalMem > 0 ? totalMem < _bigTextureFromBytes : ios;
  final lowMemory = totalMem <= 0 || totalMem <= _lowMemoryBytes;
  return {
    if (small) 'maxTexture': ios && lowMemory ? '1024' : '2048',
    if (ios) 'antialias': '0',
    if (ios && lowMemory) ...{'dpr': '1.5', 'gpuBudget': 'low'},
    if (quality != null && quality >= 0.5 && quality < 1) 'quality': quality.toStringAsFixed(2),
    if (reduceMotion) 'reduceMotion': '1',
    if (bare) 'bare': '1',
  };
}

/// Why a stage left for good on its own account ([CompanionStageEvents.onFailed]):
/// her renderer died, or the pack under her was about to change. Not for the
/// person to read; the room has its own words for them.
const companionStageRendererGone = 'renderer gone';
const companionStagePackChanged = 'pack changed';

/// Sends commands to the stage; does nothing until it is ready.
class CompanionStageController {
  CompanionStageController({this.sink});

  /// Tests watch commands here instead of a WebView.
  final void Function(String type, Map<String, Object?> args)? sink;

  WebViewController? _web;
  bool _ready = false;

  void command(String type, [Map<String, Object?> args = const {}]) {
    sink?.call(type, args);
    final web = _web;
    if (web == null || !_ready) return;
    // Structured and JSON-encoded: nothing from a reply becomes script.
    unawaited(web.runJavaScript('stage.command(${jsonEncode({'type': type, ...args})})').catchError((Object _) {}));
  }
}

/// What the stage tells the page.
class CompanionStageEvents {
  const CompanionStageEvents({
    required this.onReady,
    required this.onFailed,
    required this.onTouch,
    required this.onWake,
    required this.onMood,
    required this.onObject,
    required this.onActivity,
    this.onModel,
    this.onProbe,
    this.onCover,
  });

  final VoidCallback onReady;

  /// If set, load the one-shot cover stage instead of the interactive room.
  final ValueChanged<Uint8List>? onCover;

  /// What the model is (stage.js `probeReport`), when it loads and whenever
  /// an adapter is worn or taken off (companion_adapt.dart).
  final ValueChanged<CompanionProbe>? onProbe;

  /// What the model brings of its own, as it finishes loading (before [onReady]).
  final ValueChanged<CompanionModelInfo>? onModel;
  final ValueChanged<String> onFailed;
  final void Function(String zone, String kind) onTouch;
  final VoidCallback onWake;
  final ValueChanged<String> onMood;

  /// One of her things was tapped: `snack`, `play` or `rest`.
  final ValueChanged<String> onObject;

  /// What she's doing changed (also when it ran out): `idle` / `snack` / `play` / `rest`.
  final ValueChanged<String> onActivity;
}

class CompanionStage extends StatefulWidget {
  const CompanionStage({
    super.key,
    required this.store,
    required this.controller,
    required this.events,
    this.bare = false,
    this.viewKey,
  });

  final CompanionPackStore store;
  final CompanionStageController controller;
  final CompanionStageEvents events;

  /// The model alone on a see-through page, without her room around it (the
  /// tavern's visual novel draws its own scene behind).
  final bool bare;

  /// Her room's own: the size and place the person pinches her to are kept
  /// under this key (her character) and come back next visit. Null elsewhere
  /// (a call's backdrop, the tavern, a cover), which frame her their own way.
  final String? viewKey;

  @override
  State<CompanionStage> createState() => _CompanionStageState();
}

class _CompanionStageState extends State<CompanionStage> with WidgetsBindingObserver {
  static const _readyTimeout = Duration(seconds: 40);

  CompanionServer? _server;
  WebViewController? _web;

  /// The Android WebView behind [_web], once it is guarded.
  int? _webId;
  StreamSubscription<IslandPlatformEvent>? _platformEvents;
  void Function()? _unhook;

  /// Goes up each time her WebView is retired: a start that awaited across
  /// one gives up, and the retired page is no longer heard.
  int _generation = 0;
  Timer? _timeout;
  AppLifecycleState? _lifecycle;
  bool _routeVisible = true;
  bool? _appliedPause;

  bool get _cover => widget.events.onCover != null;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _platformEvents = IslandPlatform.instance.events.listen((event) {
      // One renderer for every WebView of the app: any loss is hers too.
      if (event is IslandRendererGone && _webId != null) unawaited(_retire(companionStageRendererGone));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Off only when a page covers the room whole (the memory page): a sheet or
    // a dialog over her leaves her moving under it, not frozen.
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _syncVisibility();
  }

  void _syncVisibility() {
    if (!widget.controller._ready) return;
    final pause = !_routeVisible || (_lifecycle != null && _lifecycle != AppLifecycleState.resumed);
    if (_appliedPause == pause) return;
    _appliedPause = pause;
    widget.controller.command(pause ? 'pause' : 'resume');
  }

  Future<void> _start() async {
    final cover = _cover;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final generation = _generation;
    bool stale() => generation != _generation;
    // Before the pack under her changes she stops reading it. Never call the
    // store from this hook: it runs inside the store's queue.
    _unhook = widget.store.beforeChanges(() => _retire(companionStagePackChanged));
    try {
      if (cover) {
        // A picked ZIP can borrow a runtime. Check the actual code and model
        // references before giving this pack a WebView with a bridge.
        final reason = await widget.store.coverUnavailableReason();
        if (stale()) return;
        if (reason != null) {
          _fail(reason);
          return;
        }
      }
      final server = await CompanionServer.start(rootBundle, widget.store.pack);
      if (stale()) {
        await server.close();
        return;
      }
      _server = server;
      final device = await IslandPlatform.instance.device();
      final quality = cover ? null : await _rememberedQuality();
      if (stale()) return;
      final view = cover || widget.viewKey == null ? null : await _rememberedView(widget.viewKey!);
      if (stale()) return;
      final query = companionStageQuery(
        ios: defaultTargetPlatform == TargetPlatform.iOS,
        totalMem: device.totalMem,
        quality: quality,
        reduceMotion: reduceMotion || cover,
        bare: widget.bare || cover,
      );
      if (view != null) {
        query['viewZoom'] = '${view.zoom}';
        query['viewX'] = '${view.x}';
        query['viewY'] = '${view.y}';
      }
      if (cover) {
        query['mode'] = 'cover';
        query['coverSide'] = '$workshopPreviewSide';
        query.putIfAbsent('maxTexture', () => '2048');
      }
      final page = server.pageUrl(query: query);
      final web = WebViewController(onPermissionRequest: (request) => unawaited(request.deny()));
      final android = defaultTargetPlatform == TargetPlatform.android;
      final needsGuard = android || (cover && defaultTargetPlatform != TargetPlatform.iOS);
      if (cover && needsGuard) _webId = WebViewGuard.identifierOf(web);
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(widget.bare || cover ? const Color(0x00000000) : const Color(0xFF0D2F55));
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final allowed = cover
                ? request.isMainFrame && Uri.tryParse(request.url) == page
                : server.ownsUrl(request.url);
            return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (generation == _generation && (error.isForMainFrame ?? false)) _fail('load ${error.errorCode}');
          },
        ),
      );
      await web.addJavaScriptChannel(
        'DshCompanion',
        onMessageReceived: (m) {
          if (generation == _generation) _onMessage(m.message);
        },
      );
      if (stale()) return;
      // After the navigation delegate: the guard wraps the client it set.
      // Her renderer is the floating window's too; unguarded, its death takes
      // the app with it, so she doesn't load without the guard. (The page has
      // no text and its own colours: nothing else of the attach applies.)
      final id = cover ? _webId : (android ? WebViewGuard.identifierOf(web) : null);
      if (cover && needsGuard && id == null) {
        _fail('guard');
        return;
      }
      if (id != null) {
        final guarded = await IslandPlatform.instance.attach(id, dark: false, textZoom: 100);
        if (stale()) {
          // Left while attaching: never shown, so it goes now (a cover's id was released already).
          if (!cover) unawaited(IslandPlatform.instance.destroy(id));
          return;
        }
        if (!guarded) {
          _fail('guard');
          return;
        }
        _webId = id;
      }
      setState(() {
        _web = web;
        widget.controller._web = web;
      });
      _timeout = Timer(_readyTimeout, () => _fail('timeout'));
      await web.loadRequest(page);
    } on Object catch (error) {
      if (generation == _generation) _fail('$error');
    }
  }

  /// Her WebView leaves for good and its server closes: the renderer died, or
  /// the pack is about to change (the store waits here for the last handler).
  /// The room builds a new stage; this one is not loaded again.
  Future<void> _retire(String why) async {
    if (kDebugMode) debugPrint('[companion] stage retired: $why');
    if (mounted) {
      _generation++;
      _timeout?.cancel();
      widget.controller
        .._web = null
        .._ready = false;
      if (_web != null) setState(() => _web = null);
      _destroyWebView();
    }
    await _server?.close();
    _fail(why);
  }

  void _destroyWebView() {
    final id = _webId;
    _webId = null;
    // Never destroy the native view before Flutter has detached its widget.
    if (id != null) {
      final platform = IslandPlatform.instance;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(platform.destroy(id)));
    }
  }

  void _onMessage(String raw) {
    if (!mounted) return;
    if (_cover && raw.length > (workshopPreviewBytes + 2) ~/ 3 * 4 + 32) {
      _fail('cover size');
      return;
    }
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    final events = widget.events;
    if (events.onCover case final onCover?) {
      switch (message['type']) {
        case 'cover':
          final data = message['png'];
          if (data is! String) {
            _fail('cover format');
            return;
          }
          try {
            final png = base64Decode(data);
            if (png.length > workshopPreviewBytes ||
                pngSize(png) != (workshopPreviewSide, workshopPreviewSide) ||
                !pngIntact(png)) {
              _fail('cover png');
              return;
            }
            onCover(png);
          } on FormatException {
            _fail('cover format');
          }
        case 'error':
          _fail('cover render');
      }
      return;
    }
    switch (message['type']) {
      case 'ready':
        _timeout?.cancel();
        widget.controller._ready = true;
        _appliedPause = null;
        _syncVisibility();
        // What the model is first: its moves are kept by its fingerprint.
        if (CompanionProbe.fromJson(message['probe']) case final probe?) events.onProbe?.call(probe);
        events.onModel?.call(CompanionModelInfo.fromMessage(message));
        events.onReady();
      case 'adapted':
        if (CompanionProbe.fromJson(message['probe']) case final probe?) events.onProbe?.call(probe);
      case 'error':
        _fail('${message['message']}');
      case 'touch':
        final zone = message['zone'];
        final kind = message['kind'];
        if (zone is String && kind is String) events.onTouch(zone, kind);
      case 'wake':
        events.onWake();
      case 'mood':
        final mood = message['mood'];
        if (mood is String) events.onMood(mood);
      case 'object':
        final id = message['id'];
        if (id is String && const {'snack', 'play', 'rest'}.contains(id)) events.onObject(id);
      case 'activity':
        final name = message['name'];
        if (name is String) events.onActivity(name);
      case 'quality':
        final value = message['value'];
        if (value is num && value >= 0.5 && value <= 1) unawaited(_rememberQuality(value.toDouble()));
      case 'view':
        final (zoom, x, y) = (message['zoom'], message['x'], message['y']);
        if (_viewKey case final key? when zoom is num && x is num && y is num && zoom > 0) {
          unawaited(_rememberView(key, (zoom: zoom.toDouble(), x: x.toDouble(), y: y.toDouble())));
        }
    }
  }

  /// The pref key this stage keeps her room's view under, once it has read it.
  String? _viewKey;

  Future<({double zoom, double x, double y})?> _rememberedView(String character) async {
    try {
      final key = _viewKey = '$_viewKeyPrefix$character';
      final saved = (await SharedPreferences.getInstance()).getString(key);
      if (saved == null) return null;
      final json = jsonDecode(saved);
      if (json case {'zoom': final num zoom, 'x': final num x, 'y': final num y} when zoom > 0) {
        return (zoom: zoom.toDouble(), x: x.toDouble(), y: y.toDouble());
      }
    } on Object {
      // Her default framing.
    }
    return null;
  }

  static Future<void> _rememberView(String key, ({double zoom, double x, double y}) view) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode({'zoom': view.zoom, 'x': view.x, 'y': view.y}),
      );
    } on Object {
      // Kept for next time when it can be; this visit already has it.
    }
  }

  static Future<double?> _rememberedQuality() async {
    try {
      return (await SharedPreferences.getInstance()).getDouble(_qualityKey);
    } on Object {
      return null; // A first visit's full resolution.
    }
  }

  static Future<void> _rememberQuality(double value) async {
    try {
      await (await SharedPreferences.getInstance()).setDouble(_qualityKey, value);
    } on Object {
      // Kept for next time when it can be; this visit already has it.
    }
  }

  void _fail(String why) {
    _timeout?.cancel();
    if (mounted) widget.events.onFailed(why);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_platformEvents?.cancel());
    _generation++;
    _timeout?.cancel();
    widget.controller
      .._web = null
      .._ready = false;
    _destroyWebView();
    // The hook stays until the server has closed: a pack change that races
    // leaving the room waits for the last handler too.
    final unhook = _unhook;
    unawaited((_server?.close() ?? Future<void>.value()).whenComplete(() => unhook?.call()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    if (web == null) return const SizedBox.expand();
    return WebViewWidget(
      controller: web,
      // Her touch handling lives in the page: strokes must not become scrolls
      // or the back gesture's competitors.
      gestureRecognizers: _cover ? const {} : {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}
