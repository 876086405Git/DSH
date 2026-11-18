import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../plugins/seams/seat_models.dart';
import '../../web/web_file_chooser.dart';
import 'island_assets.dart';
import 'island_messages.dart';
import 'island_navigation.dart';
import 'island_platform.dart';
import 'island_recipes.dart';
import 'island_theme.dart';

/// Where an island is in its life.
enum IslandPhase {
  /// Loading DSH Web, navigating, waiting for the slot (hidden, skeleton on
  /// top).
  loading,

  /// The slot is on screen.
  ready,

  /// It gave up ([IslandHandle.failure]): the seat falls back.
  failed,

  /// Destroyed; the handle is spent.
  closed,
}

abstract final class IslandTiming {
  /// From the first load to `ready`, a session hop's reload and island.js's
  /// two retries included. Measured on the emulator (software rendering):
  /// 0.8–3.4 s typically, 11.3 s once a first click was lost and retried;
  /// 5 s leaves no room for a hop plus a retry.
  static const ready = Duration(seconds: 15);

  /// A conversation view's page island (`recipes.json` "ready": "view"),
  /// under the loading skeleton. The same measurements: 0.8–3.4 s
  /// typically, 11.3 s at worst, which is when a conversation is opened
  /// for the first time and the page loads again into it. 12 s lets that
  /// first open come up instead of falling back.
  static const viewReady = Duration(seconds: 12);

  /// The chat page's 「插件」 sheet island (`recipes.json` "ready":
  /// "sheet"). The same measurements (0.8–3.4 s typically, 11.3 s at
  /// worst); a sheet is a glance, so past 8 s it is the way to DSH Web.
  static const sheetReady = Duration(seconds: 8);

  /// A recipe's `ready` name; null (unnamed or unknown): [ready].
  static Duration? named(Object? name) => switch (name) {
    'view' => viewReady,
    'sheet' => sheetReady,
    _ => null,
  };

  /// island.js waits this long for the client to boot, then for the slot.
  static const bootMs = 9000;
  static const slotMs = 4000;

  /// `link` / `session` requests the page may make: at most one a second.
  static const requestGap = Duration(seconds: 1);

  /// The App's theme cross-fades: only its last frame reaches the page.
  static const themeSettle = Duration(milliseconds: 160);
}

/// One island: a WebView on the host's DSH Web, isolated to one slot. Lives
/// in the [IslandHost]'s pool and outlives the views that show it (a warm
/// island comes back without a reload). Views listen to it.
class IslandHandle extends ChangeNotifier {
  IslandHandle({
    required this.spec,
    required this.url,
    required this.target,
    required this.recipe,
    required this.book,
    required IslandAssets assets,
    required IslandPlatform platform,
    required IslandTheme theme,
    this.onPhase,
  }) : _assets = assets, // ignore: prefer_initializing_formals
       _platform = platform, // ignore: prefer_initializing_formals
       _theme = theme, // ignore: prefer_initializing_formals
       _initialTheme = theme;

  final IslandSpec spec;

  /// The launch URL (`/?token=…`).
  final Uri url;

  /// island.js's navigation target ([IslandRecipeBook.targetFor]).
  final Map<String, Object?> target;
  final IslandRecipe? recipe;
  final IslandRecipeBook book;
  final IslandAssets _assets;
  final IslandPlatform _platform;

  /// Told about every phase change (the host keeps its books with it).
  final void Function(IslandHandle handle)? onPhase;

  late final WebViewController controller;
  late final _files = WebFileChooser(
    canChoose: () => _phase == IslandPhase.ready && visible && views > 0 && spec.form != IslandForm.probe,
  );

  IslandPhase get phase => _phase;
  IslandPhase _phase = IslandPhase.loading;

  IslandFailure? get failure => _failure;
  IslandFailure? _failure;

  /// What `ready` said.
  IslandReady? get ready => _ready;
  IslandReady? _ready;

  /// A panel island's content height (logical px), once reported.
  double? get contentHeight => _contentHeight;
  double? _contentHeight;

  /// An overlay island's touch regions (logical px, in the island's box).
  List<Rect> get hitRects => _hitRects;
  List<Rect> _hitRects = const [];

  /// The underlying WebView (null where its controller has no identifier, as in tests).
  int? get webViewId => _webViewId;
  int? _webViewId;

  /// When the load started, for the PoC's timings.
  final Stopwatch clock = Stopwatch();

  /// How long `ready` took.
  Duration? get readyAfter => _readyAfter;
  Duration? _readyAfter;

  /// Book-keeping for the host.
  int views = 0;
  bool get visible => _visible;
  bool _visible = false;
  set visible(bool value) {
    if (_visible == value) return;
    _visible = value;
    // A warm document can outlive its view. Returning to that same document
    // must not receive a selection requested before leaving the panel.
    if (!value) _files.invalidate();
  }

  DateTime lastSeen = DateTime.now();
  bool paused = false;

  IslandTheme _theme;

  /// What attach and init gave the page (later themes go by setTheme).
  final IslandTheme _initialTheme;
  EdgeInsets _insets = EdgeInsets.zero;
  Timer? _readyTimer;
  final _requests = StreamController<IslandMessage>.broadcast();

  /// Counts injections; island.js echoes the latest one it got in every
  /// message, so what a document the page already left still says (a
  /// session hop's first half) is dropped.
  int _load = 0;
  Timer? _requestGate;
  Timer? _themeTimer;
  IslandTheme? _sentTheme;

  /// `link` and `session` requests for the view to act on (it has the
  /// context for a confirmation and a route).
  Stream<IslandMessage> get requests => _requests.stream;

  /// The launch URL plus what dsh-go-bridge picks up at boot: island mode
  /// for a list slot whose official entries it masks, or the right-pane tab
  /// to open (never both: masking that slot would empty official tabs too).
  Uri get _loadUrl {
    final cell = spec.cell ?? '';
    if (spec.slot == rightPaneTabSlot) {
      if (cell.isEmpty || book.officialRightbar.contains(cell)) return url;
      return url.replace(fragment: 'dsh-go-tab=${Uri.encodeComponent(cell)}');
    }
    if (!spec.maskOfficial) return url;
    final slots = recipe?.slotsFor(spec.slot) ?? [spec.slot];
    return url.replace(fragment: 'dsh-go-island=${slots.map(Uri.encodeComponent).join(',')}');
  }

  static const rightPaneTabSlot = 'sidebar.right.pane.tab';

  /// Creates the WebView, takes it over on the platform side, loads.
  Future<void> start() async {
    clock.start();
    controller = WebViewController(onPermissionRequest: (request) => unawaited(request.deny()));
    await Future.wait<void>(
      [
        controller.setJavaScriptMode(JavaScriptMode.unrestricted),
        _files.attach(controller),
        controller.setBackgroundColor(Colors.transparent),
        controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: _onNavigation,
            onPageStarted: (_) => _files.invalidate(),
            onPageFinished: (_) => unawaited(_inject()),
            onWebResourceError: (error) {
              if (kDebugMode) {
                // URLs and descriptions may contain the Host's token.
                debugPrint(
                  '[island] ${spec.slot} resource: code=${error.errorCode} '
                  'type=${error.errorType?.name ?? 'unknown'} mainFrame=${error.isForMainFrame}',
                );
              }
              if (error.isForMainFrame ?? true) _fail(IslandFailure.load);
            },
          ),
        ),
        // Before the first load: Android only injects channels on load.
        controller.addJavaScriptChannel('DshGoIsland', onMessageReceived: (m) => _onMessage(m.message)),
      ].map((f) => f.catchError((Object _) {})),
    );
    _webViewId = _identifierOf(controller);
    final id = _webViewId;
    if (id != null) await _platform.attach(id, dark: _theme.dark, textZoom: _theme.textZoom);
    if (_phase != IslandPhase.loading) return;
    _readyTimer = Timer(recipe?.ready ?? IslandTiming.ready, () => _fail(IslandFailure.timeout));
    await controller.loadRequest(_loadUrl).catchError((Object _) => _fail(IslandFailure.load));
  }

  /// The platform controller's `webViewIdentifier` (webview_flutter_android's
  /// and webview_flutter_ohos's alike), without depending on either package (the
  /// app only depends on webview_flutter). Null where a controller has none.
  static int? _identifierOf(WebViewController c) {
    try {
      final Object? id = (c.platform as dynamic).webViewIdentifier;
      return id is int ? id : null;
    } catch (_) {
      return null;
    }
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    switch (islandNavigation(url, request.url, isMainFrame: request.isMainFrame)) {
      case IslandNavigation.stay:
        return NavigationDecision.navigate;
      case IslandNavigation.external:
        final uri = Uri.tryParse(request.url);
        if (uri != null) _request(IslandLink(uri));
        return NavigationDecision.prevent;
      case IslandNavigation.block:
        return NavigationDecision.prevent;
    }
  }

  /// Every load: the open bridge, the island runtime, then init. A session
  /// hop's reload comes back here and picks up where it left off.
  Future<void> _inject() async {
    if (_phase == IslandPhase.closed || _phase == IslandPhase.failed) return;
    try {
      _load++;
      final config = await initConfig();
      await controller.runJavaScript(await _assets.openBridge);
      await controller.runJavaScript(await _assets.runtime);
      await controller.runJavaScript('window.__dshGoIsland && window.__dshGoIsland.init(${jsonEncode(config)});');
    } catch (_) {
      // A page without a DOM (an error page): the load error handles it.
    }
  }

  /// `__dshGoIsland.init`'s argument.
  Future<Map<String, Object?>> initConfig() async => {
    'slot': spec.slot,
    'slots': ?recipe?.slots,
    'cell': spec.cell,
    'package': spec.package,
    'mode': spec.form.name,
    'mask': spec.maskOfficial && spec.slot != rightPaneTabSlot,
    'stretch': (recipe?.stretch ?? IslandStretch.none).name,
    'pad': [recipe?.padX ?? 0, recipe?.padY ?? 0],
    'labels': book.labels,
    'target': target,
    'css': await _assets.css,
    'theme': _theme.toJson(),
    'insets': {'top': _insets.top, 'bottom': _insets.bottom},
    'load': _load,
    'bootMs': IslandTiming.bootMs,
    'slotMs': IslandTiming.slotMs,
  };

  void _onMessage(String raw) {
    if (_phase == IslandPhase.closed || !_fromCurrentLoad(raw)) return;
    final message = parseIslandMessage(raw);
    switch (message) {
      case null:
        return;
      case IslandReady():
        if (_phase != IslandPhase.loading) return;
        _readyTimer?.cancel();
        _ready = message;
        _readyAfter = clock.elapsed;
        _setPhase(IslandPhase.ready);
      case IslandGaveUp(:final failure, :final detail):
        if (kDebugMode && detail.isNotEmpty) debugPrint('[island] ${spec.slot} says: ${failure.name} $detail');
        _fail(failure);
      case IslandSize(:final height):
        if (_contentHeight == height) return;
        _contentHeight = height;
        notifyListeners();
      case IslandHit(:final rects):
        _hitRects = rects;
        notifyListeners();
      case IslandLink() || IslandOpenSession():
        if (_phase == IslandPhase.ready) _request(message);
    }
  }

  /// Messages say which load they come from; one from a document the page
  /// has already left (a session hop's first half) is dropped. Messages
  /// without one are taken (nothing to check them against).
  bool _fromCurrentLoad(String raw) {
    if (raw.length > IslandMessageLimits.maxBytes) return false;
    try {
      final json = jsonDecode(raw);
      final load = json is Map ? json['load'] : null;
      return load is! int || load == _load;
    } on FormatException {
      return false;
    }
  }

  void _request(IslandMessage message) {
    if (_requestGate?.isActive ?? false) return;
    _requestGate = Timer(IslandTiming.requestGap, () {});
    if (!_requests.isClosed) _requests.add(message);
  }

  void _setPhase(IslandPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    notifyListeners();
    onPhase?.call(this);
  }

  void _fail(IslandFailure failure) {
    if (_phase == IslandPhase.closed || _phase == IslandPhase.failed) return;
    _files.invalidate();
    _readyTimer?.cancel();
    _failure = failure;
    if (kDebugMode) {
      debugPrint('[island] ${spec.slot} ${spec.cell ?? ''} gave up: ${failure.name}');
      // What island.js got to before giving up (debug builds only).
      if (failure != IslandFailure.evicted && failure != IslandFailure.renderer) {
        unawaited(inspect().then((i) => debugPrint('[island] ${spec.slot} trace: ${jsonEncode(i)}')));
      }
    }
    _setPhase(IslandPhase.failed);
  }

  /// Gives up from the outside (the renderer died, the budget closed it).
  void giveUp(IslandFailure failure) => _fail(failure);

  /// The App's look changed: no reload. A theme switch animates, so the
  /// page gets the last frame of it, not every one.
  void setTheme(IslandTheme theme) {
    if (theme == _theme || _phase == IslandPhase.closed) return;
    _theme = theme;
    _themeTimer?.cancel();
    _themeTimer = Timer(IslandTiming.themeSettle, () => unawaited(_sendTheme()));
  }

  Future<void> _sendTheme() async {
    final theme = _theme;
    final sent = _sentTheme ?? _initialTheme;
    if (theme == sent || _phase == IslandPhase.closed) return;
    _sentTheme = theme;
    final id = _webViewId;
    if (id != null && sent.dark != theme.dark) await _platform.setDark(id, theme.dark);
    if (id != null && sent.textZoom != theme.textZoom) await _platform.setTextZoom(id, theme.textZoom);
    await _run('window.__dshGoIsland && window.__dshGoIsland.setTheme(${jsonEncode(theme.toJson())});');
  }

  /// Room the frame keeps clear at the top and bottom (logical px).
  Future<void> setInsets(EdgeInsets insets) async {
    if (insets == _insets) return;
    _insets = insets;
    await _run(
      'window.__dshGoIsland && window.__dshGoIsland.setInsets(${jsonEncode({'top': insets.top, 'bottom': insets.bottom})});',
    );
  }

  Future<void> _run(String script) async {
    if (_phase == IslandPhase.closed) return;
    try {
      await controller.runJavaScript(script);
    } catch (_) {}
  }

  /// What island.js says about itself (the PoC's leak check).
  Future<Object?> inspect() async {
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'JSON.stringify(window.__dshGoIsland ? window.__dshGoIsland.inspect() : null)',
      );
      final text = raw is String ? raw : '$raw';
      final decoded = jsonDecode(text);
      return decoded is String ? jsonDecode(decoded) : decoded;
    } catch (_) {
      return null;
    }
  }

  Future<void> pause() async {
    if (paused || _webViewId == null) return;
    paused = true;
    await _platform.pause(_webViewId!);
  }

  Future<void> resume() async {
    if (!paused || _webViewId == null) return;
    paused = false;
    await _platform.resume(_webViewId!);
  }

  /// Destroys the WebView once no view shows it (the views drop their
  /// WebViewWidget on [IslandPhase.closed], a frame later it's detached).
  Future<void> close({IslandFailure? because}) async {
    if (_phase == IslandPhase.closed) return;
    _files.dispose();
    _readyTimer?.cancel();
    _themeTimer?.cancel();
    _requestGate?.cancel();
    if (because != null) _failure ??= because;
    _setPhase(IslandPhase.closed);
    final id = _webViewId;
    if (id != null) {
      if (views > 0) await SchedulerBinding.instance.endOfFrame;
      await _platform.destroy(id);
    }
    await _requests.close();
  }

  @override
  void dispose() {
    _files.dispose();
    _readyTimer?.cancel();
    _themeTimer?.cancel();
    _requestGate?.cancel();
    if (!_requests.isClosed) unawaited(_requests.close());
    super.dispose();
  }
}
