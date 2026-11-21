import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../common/empty_view.dart';
import '../common/expand_reveal.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'web_back.dart';
import 'web_file_chooser.dart';
import 'web_handle.dart';
import 'web_navigation.dart';
import 'web_target.dart';
import 'web_view_guard.dart';

/// Full-bleed WebView with floating glass controls (back · title · reload · open).
///
/// The page's own background runs edge to edge — behind the status bar, the
/// controls, a side camera cutout and the gesture bar — with no divider; a
/// fade of the page colour behind the controls gives content room to breathe
/// as it scrolls up. The page's content stays inside the safe area: injected
/// CSS for DSH Web and the top / bottom of other pages, the WebView's own
/// bounds for their sides (fixed-position elements ignore body padding).
class WebViewPage extends StatefulWidget {
  const WebViewPage({
    super.key,
    required this.url,
    required this.title,
    this.subtitle,
    this.allowOpenExternal = false,
    this.externalDisabledReason,
    this.reloadAfterBackground,
    this.lightBackground = const Color(0xFFFFFFFF),
    this.darkBackground = const Color(0xFF151517),
    this.dshWeb = false,
    this.phoneLayout = true,
    this.openTarget,
    this.leading,
    this.root = false,
    this.link,
    this.onSession,
  });

  final Uri url;
  final String title;
  final String? subtitle;

  /// Show an enabled "在浏览器打开" button. When false the button is still shown,
  /// disabled, with [externalDisabledReason] as its tooltip.
  final bool allowOpenExternal;
  final String? externalDisabledReason;

  /// Reload when returning from the background after this long (remote pages
  /// lose their socket when Android suspends the WebView).
  final Duration? reloadAfterBackground;

  /// The embedded site's page colour: painted before the first frame and used
  /// for the fade behind the controls, so nothing flashes or shows a seam.
  final Color lightBackground;
  final Color darkBackground;

  /// The page is DSH Web: fit it to a touch screen (`assets/web/`). Below
  /// [dshWebDesktopWidth] the sidebar becomes a drawer behind a menu button
  /// in the page's header row; from there up the official layout stays, with
  /// the way back above its sidebar.
  final bool dshWeb;

  /// With [dshWeb]: adapt the layout. Off leaves DSH Web's own layout alone:
  /// at phone widths its drawer keeps a leading seat in the header row for
  /// its sidebar opener, and the handle takes the far left of that row while
  /// the seat moves past it ([WebChrome.seat]); wider windows show the app's
  /// bar ([WebChrome.bar]).
  final bool phoneLayout;

  /// With [dshWeb]: the page to land on after the first load
  /// (`assets/web/dsh_web_open.js`); null opens the home page.
  final DshWebTarget? openTarget;

  /// Takes the back button's seat (网页模式: the native handle), at the
  /// size of the button it replaces. A page without one seats the app's mark
  /// as its way back instead (the marker in DSH Web's leading seat).
  final Widget Function(double size)? leading;

  /// The page is the app's home (网页模式): back leaves the app once the page
  /// has nowhere to go back to, as on the native home ([WebBackDispatcher]).
  final bool root;

  /// Lets the caller act on the live page (open a target, fill the composer).
  final DshWebLink? link;

  /// With [dshWeb]: the conversation on screen, whenever it changes (from
  /// the client's stored selection; null for none).
  final ValueChanged<String?>? onSession;

  bool get _adapt => dshWeb && phoneLayout;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

/// Frame width from which DSH Web keeps its own layout: the official client
/// keeps its sidebar open from here up (`SIDEBAR_AUTO_COLLAPSE` in
/// dsh-client-ui-layout) and folds it into an icon rail below. On a touch
/// screen the app folds it into a drawer instead.
const dshWebDesktopWidth = 1024.0;

/// Viewport width below which DSH Web's *own* layout (no app CSS) folds the
/// sidebar into a drawer and keeps a leading seat in its header row for the
/// host's button (`drawer = viewport < 768` in `dsh-client-ui-layout`; the
/// seat is `.leadingSeat` at top 11 / left 12, with
/// `--dsh-frame-leading-clearance` making room for it). The seat holds DSH
/// Web's own sidebar opener, so the app's back button takes the far left and
/// the seat moves past it ([WebChrome.seat]).
const dshWebDrawerWidth = 768.0;

/// How the app's controls sit on the page.
enum WebChrome {
  /// A row under the status bar: back · title · reload · open (other sites),
  /// or just back (DSH Web as shipped, wider than [dshWebDrawerWidth]).
  bar,

  /// DSH Web as shipped, phone widths: its own drawer layout keeps a leading
  /// seat in the header row for its sidebar opener, the handle takes the far
  /// left of that row and the seat moves past it — no bar of its own, and the
  /// page's opener stays where a finger looks for it.
  seat,

  /// Back and menu inside DSH Web's own header row, which makes room for
  /// them; the sidebar is a drawer.
  inline,

  /// DSH Web's own layout: back sits in a band above its sidebar, centred
  /// on the icon rail's column, which stays put as the sidebar opens.
  side,
}

/// Geometry of the app's controls over a web page.
abstract final class WebChromeMetrics {
  /// Height of the floating control row under the status bar ([WebChrome.bar]).
  static const barHeight = 52.0;

  /// Side margin of the controls, from the safe area.
  static const edge = 12.0;

  /// Back / menu buttons in DSH Web ([WebChrome.inline], [WebChrome.side]).
  static const button = 40.0;

  /// [WebChrome.inline]: offset of the buttons below the status bar (DSH
  /// Web's header row is 40px from 10px down).
  static const inlineTop = 10.0;

  /// [WebChrome.seat]: DSH Web's own leading seat in the drawer layout
  /// (`.leadingSeat`, top 11 / left 12 in `dsh-client-ui-layout`). What sits
  /// in it is DSH Web's own sidebar opener — a 28px icon button
  /// (`HeaderLeadingControls` in `dsh-client-ui-sidebar`), which the official
  /// layout keeps clear of the page's title with
  /// `--dsh-frame-leading-clearance: 48px` (12 + 28 + 8).
  static const seatTop = 11.0;
  static const seatLeft = 12.0;

  /// [WebChrome.seat]: the official opener's button, and the gap between the
  /// controls in that row (the official clearance, 48, is
  /// [seatLeft] + [officialButton] + [gap]).
  static const officialButton = 28.0;
  static const gap = 8.0;

  /// [WebChrome.seat]: the marker in that row, the page's own size there
  /// (its sidebar opener and header icons are all 28), so it reads as one of
  /// them rather than as a bar of its own. Its touch target is its own size,
  /// exactly as the page's own controls in that row.
  static const seatButton = 28.0;

  /// [WebChrome.seat]: the official seat moves this far right, past the
  /// marker — one header row, no bar of its own, and the page's opener stays
  /// reachable instead of under the marker.
  static const seatShift = seatButton + gap;

  /// [WebChrome.seat]: where the page's title starts: past the marker, the
  /// seat (whatever the official UI or a plugin puts in it, at the official
  /// 28px + 8px rhythm) and the gap after them.
  static const seatClearance = seatLeft + seatShift + officialButton + gap;

  /// [WebChrome.side]: the band above the sidebar and the official icon
  /// rail's width (`computeColumns` collapsedWidth).
  static const band = 52.0;
  static const rail = 56.0;

  /// Windows less tall than this are a phone on its side: the drawer layout,
  /// however wide.
  static const phoneHeight = 480.0;

  /// Below this much page height while typing, DSH Web's header row steps
  /// aside (a phone on its side: about 120 left above the keyboard).
  static const compactHeight = 300.0;

  /// Bottom inset while the system reports none and the keyboard is down:
  /// some ROMs (vivo in landscape) draw the gesture handle without an inset.
  static const gestureFloor = 12.0;
}

/// Where a page's content sits and how much room the app's controls take,
/// for one window size; [script] hands it to the page.
@immutable
class WebPageInsets {
  const WebPageInsets({
    required this.chrome,
    this.rootTop = 0,
    this.rootBottom = 0,
    this.left = 0,
    this.right = 0,
    this.layerTop = 0,
    this.bottom = 0,
    this.lead = 0,
    this.leadHeight = 0,
    this.status = 0,
    this.band = 0,
    this.frameBottom = 0,
    this.keyboard = 0,
    this.compact = false,
  });

  /// The insets for a page in a window of [size] with system [padding] and a
  /// [keyboard] that tall. DSH Web keeps its size and lifts its root and
  /// layers above the keyboard ([keyboard], a style of its own: typing lays
  /// the page out once and never resizes the WebView); other pages shrink
  /// above it ([WebViewPage] insets the WebView).
  factory WebPageInsets.resolve({
    required Size size,
    required EdgeInsets padding,
    required double keyboard,
    required bool dshWeb,
    required bool adapt,
  }) {
    final typing = keyboard > 0;
    final gesture = math.max(padding.bottom, WebChromeMetrics.gestureFloor);
    final topChrome = padding.top + WebChromeMetrics.barHeight;
    if (!dshWeb) {
      // The page's content starts where the feather runs out, fully clear at
      // rest. Its sides are the WebView's own bounds (see [WebViewPage]).
      final fade = topChrome + 24;
      final bottom = typing ? 0.0 : gesture;
      return WebPageInsets(chrome: WebChrome.bar, rootTop: fade, layerTop: fade, bottom: bottom, rootBottom: bottom);
    }
    if (!adapt) {
      // DSH Web as shipped. On a phone its own layout turns the sidebar into
      // a drawer and keeps a leading seat in the header row for the host's
      // button; the handle takes that seat, so nothing needs a bar. Wider
      // windows have no seat (an icon rail instead): the bar holds the handle.
      if (size.width - padding.horizontal < dshWebDrawerWidth) {
        const b = WebChromeMetrics.seatButton;
        const top = WebChromeMetrics.seatTop;
        return WebPageInsets(
          chrome: WebChrome.seat,
          rootTop: padding.top,
          rootBottom: gesture,
          left: padding.left,
          right: padding.right,
          layerTop: padding.top + top + b + 6,
          bottom: gesture,
          leadHeight: top + b,
          keyboard: keyboard,
        );
      }
      // An opaque header row of its own: it starts right under the bar, with
      // no feather over it.
      return WebPageInsets(
        chrome: WebChrome.bar,
        rootTop: topChrome,
        rootBottom: gesture,
        left: padding.left,
        right: padding.right,
        layerTop: topChrome,
        bottom: gesture,
        keyboard: keyboard,
      );
    }
    // A phone on its side stays a phone however wide it is (windows under 480
    // tall).
    if (size.width - padding.horizontal < dshWebDesktopWidth || size.height < WebChromeMetrics.phoneHeight) {
      const b = WebChromeMetrics.button;
      const top = WebChromeMetrics.inlineTop;
      // Typing on a phone on its side leaves too little room for the header
      // row, the composer and the conversation: the header steps aside (and
      // the app's buttons with it) until the keyboard goes down.
      if (typing && size.height - keyboard - padding.top < WebChromeMetrics.compactHeight) {
        return WebPageInsets(
          chrome: WebChrome.inline,
          rootTop: padding.top,
          rootBottom: gesture,
          left: padding.left,
          right: padding.right,
          layerTop: padding.top,
          bottom: gesture,
          keyboard: keyboard,
          compact: true,
        );
      }
      return WebPageInsets(
        chrome: WebChrome.inline,
        rootTop: padding.top,
        rootBottom: gesture,
        left: padding.left,
        right: padding.right,
        layerTop: padding.top + top + b + 6,
        bottom: gesture,
        lead: WebChromeMetrics.edge + b * 2 + 8 + 8,
        leadHeight: top + b,
        keyboard: keyboard,
      );
    }
    // The page runs under the status and gesture bars; its frame pads its
    // columns clear of them and the sidebar's background runs on underneath.
    // While typing the root ends at the keyboard, which hides the gesture bar.
    return WebPageInsets(
      chrome: WebChrome.side,
      left: padding.left,
      right: padding.right,
      layerTop: padding.top,
      bottom: gesture,
      status: padding.top,
      band: WebChromeMetrics.band,
      frameBottom: typing ? 0 : gesture,
      keyboard: keyboard,
    );
  }

  final WebChrome chrome;

  /// Top / bottom of the page's root (#root, or the body's padding), with
  /// the keyboard down.
  final double rootTop;
  final double rootBottom;

  /// Safe-area sides of DSH Web's root (other sites: 0, the WebView is inset).
  final double left;
  final double right;

  /// Where full-screen layers (dialogs, the drawer's content) start and end
  /// with the keyboard down: below every app control, above the gesture bar.
  final double layerTop;
  final double bottom;

  /// [WebChrome.inline]: width / bottom edge of the app's buttons inside the
  /// page's header row.
  final double lead;
  final double leadHeight;

  /// [WebChrome.side]: status bar height and the band above the sidebar.
  final double status;
  final double band;

  /// [WebChrome.side]: the gesture bar the frame pads its columns clear of
  /// (none while typing: the root ends at the keyboard).
  final double frameBottom;

  /// DSH Web while typing: the root and the layers end this far up, at the
  /// keyboard's top (the WebView keeps its size).
  final double keyboard;

  /// [WebChrome.inline] while typing in a short window: DSH Web's header row
  /// and the app's buttons in it step aside for the composer.
  final bool compact;

  /// Where the page's layers end now: above the keyboard while typing.
  double get layerBottom => keyboard > 0 ? keyboard : bottom;

  /// Bottom of the app's controls: content below this is fully clear.
  double chromeBottom(EdgeInsets padding) => switch (chrome) {
    WebChrome.bar => padding.top + WebChromeMetrics.barHeight,
    WebChrome.seat => padding.top + WebChromeMetrics.seatTop + WebChromeMetrics.seatButton,
    WebChrome.inline => padding.top + WebChromeMetrics.inlineTop + WebChromeMetrics.button,
    WebChrome.side => padding.top + band,
  };

  /// Moves the page's content clear of the controls and the system bars while
  /// its background keeps running underneath. Single-page apps with a #root
  /// (DSH Web) get #root pinned inside the safe area; other pages get body
  /// padding instead. `html[data-dsh-app-layout]` tells `dsh_web_phone.css`
  /// which layout the app chose.
  ///
  /// Writes only what changed. The keyboard has a style of its own, in plain
  /// pixels: the `--dsh-app-*` variables live on the root and every element
  /// inherits them, so changing one restyles the whole page, where the
  /// keyboard's few rules restyle the few elements they name.
  String get script {
    String px(double v) => '${v.toStringAsFixed(1)}px';
    final layout = switch (chrome) {
      WebChrome.inline => 'drawer',
      WebChrome.side => 'desktop',
      WebChrome.bar || WebChrome.seat => '',
    };
    // [WebChrome.seat]: DSH Web's own drawer layout keeps its sidebar opener
    // in a leading seat at the frame's top left (28 at 12 / 11) and clears
    // the page's title past it with `--dsh-frame-leading-clearance` (48 =
    // 12 + 28 + 8). The marker takes the far left (28 at 12, the same size as
    // the page's own chrome there), so the whole official seat — its opener,
    // and anything a plugin mounts in it — moves past the marker instead of
    // under it; both stay in the one row DSH Web lays out. The clearance then
    // covers marker, gap, official seat and the gap after it. The fullscreen
    // right panel has no reserve of its own — its tab strip starts at the
    // panel's left edge — so it starts past them too: one row, no empty band.
    //
    // Both seat rules name the drawer frame: that is where the official
    // layout puts its seat, so a build that lays the seat out differently is
    // left exactly as it is (the handle then floats over the page, as before)
    // instead of pulling the seat to a place of the app's choosing.
    final seat = chrome == WebChrome.seat
        ? ':root:root [data-slot="root"]>[class*="_frame"][data-sidebar-drawer]'
              '{--dsh-frame-leading-clearance:${px(WebChromeMetrics.seatClearance)}!important}'
              ':root:root [data-slot="root"]>[class*="_frame"][data-sidebar-drawer]>[data-shell-leading]'
              '{left:${px(WebChromeMetrics.seatLeft + WebChromeMetrics.seatShift)}!important}'
              ':root:root [data-sidebar-right-panel="fullscreen"] [data-dockkit-strip]'
              '{padding-left:${px(WebChromeMetrics.seatClearance)}!important}'
        : '';
    final vars = [
      '--dsh-app-inset-top:${px(layerTop)}',
      '--dsh-app-inset-bottom:${px(bottom)}',
      '--dsh-app-inset-left:${px(left)}',
      '--dsh-app-inset-right:${px(right)}',
      '--dsh-app-lead:${px(lead)}',
      '--dsh-app-lead-h:${px(leadHeight)}',
      '--dsh-app-status:${px(status)}',
      '--dsh-app-band:${px(band)}',
      '--dsh-app-frame-bottom:${px(frameBottom)}',
    ].join(';');
    final k = px(keyboard);
    // Ahead of dsh_web_phone.css's own rules for the same boxes whatever the
    // order of the styles (an extra :root): the root, the dialogs' backdrops,
    // the drawer's content and the settings sheet end at the keyboard.
    final typing = keyboard > 0
        ? ':root #root{bottom:$k!important}'
              ':root body>[class*="_overlay"]{bottom:$k!important}'
              ':root:root[data-dsh-app-layout="drawer"] [class*="_sidebarCol"] [data-slot="sidebar"]>[class*="_root"]'
              '{padding-bottom:$k!important}'
              '@media (max-width:760px),(max-height:600px){'
              ':root:root[data-dsh-app-layout="drawer"] [class*="_panel"]:has(>nav):has([data-slot="settings.section"])'
              '{padding-bottom:$k!important}}'
        : '';
    return [
      '(function () {',
      '  var html = document.documentElement;',
      // A document on its way out (a hop's load) has none: the next load
      // gets these.
      '  if (!html) return;',
      if (layout.isEmpty)
        "  if (html.hasAttribute('data-dsh-app-layout')) html.removeAttribute('data-dsh-app-layout');"
      else
        "  if (html.getAttribute('data-dsh-app-layout') !== '$layout') html.setAttribute('data-dsh-app-layout', '$layout');",
      "  if (html.hasAttribute('data-dsh-app-compact') !== $compact) html.toggleAttribute('data-dsh-app-compact', $compact);",
      '  function sheet(id, css) {',
      '    var s = document.getElementById(id);',
      '    if (!s) {',
      '      if (!css) return;',
      "      s = document.createElement('style'); s.id = id; document.head.appendChild(s);",
      '    }',
      '    if (s.textContent !== css) s.textContent = css;',
      '  }',
      "  var root = document.getElementById('root');",
      "  var vars = ':root{$vars}';",
      "  sheet('dsh-app-insets', root",
      // Pinned inside the safe area, and the document itself never scrolls:
      // DSH gives #root `min-height: 100vh`, so any offset made the page
      // taller than the screen and an overscroll dragged the whole page
      // (composer included) up.
      "    ? vars + '#root{position:fixed!important;top:${px(rootTop)}!important;bottom:${px(rootBottom)}!important;"
          "left:${px(left)}!important;right:${px(right)}!important;height:auto!important;min-height:0!important;margin:0!important}"
          "html,body{overflow:hidden!important;overscroll-behavior:none!important}'",
      "    : vars + 'body{padding-top:${px(rootTop)}!important;padding-bottom:${px(rootBottom)}!important;box-sizing:border-box}');",
      "  sheet('dsh-app-keyboard', root ? ${jsonEncode(typing)} : '');",
      // The seat is the app's own: only with the official layout chosen.
      "  sheet('dsh-app-seat', root ? ${jsonEncode(seat)} : '');",
      // The WebView no longer shrinks, so nothing scrolls a field the
      // keyboard covers into view: the focused one goes up to its edge.
      '  window.__dshAppKeyboard = ${keyboard.toStringAsFixed(1)};',
      '  if (!window.__dshAppReveal) {',
      '    window.__dshAppReveal = function () {',
      '      var k = window.__dshAppKeyboard, a = document.activeElement;',
      "      if (!(k > 0) || !a || !(a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)\$/.test(a.tagName))) return;",
      '      var r = a.getBoundingClientRect();',
      "      if (r.bottom > innerHeight - k) a.scrollIntoView({ block: 'nearest' });",
      '    };',
      "    document.addEventListener('focusin', function () { requestAnimationFrame(window.__dshAppReveal); });",
      '  }',
      '  if (window.__dshAppKeyboard > 0) requestAnimationFrame(window.__dshAppReveal);',
      '})();',
    ].join('\n');
  }

  @override
  bool operator ==(Object other) =>
      other is WebPageInsets &&
      other.chrome == chrome &&
      other.rootTop == rootTop &&
      other.rootBottom == rootBottom &&
      other.left == left &&
      other.right == right &&
      other.layerTop == layerTop &&
      other.bottom == bottom &&
      other.lead == lead &&
      other.leadHeight == leadHeight &&
      other.status == status &&
      other.band == band &&
      other.frameBottom == frameBottom &&
      other.keyboard == keyboard &&
      other.compact == compact;

  @override
  int get hashCode => Object.hash(
    chrome,
    rootTop,
    rootBottom,
    left,
    right,
    layerTop,
    bottom,
    lead,
    leadHeight,
    status,
    band,
    frameBottom,
    keyboard,
    compact,
  );
}

/// The keyboard height a page is laid out for.
///
/// Flutter reports the keyboard's height on every frame of its slide. Laying
/// a web page out again on each of them (and, for a WebView that shrinks,
/// resizing the platform view and its texture) is what made opening and
/// closing the keyboard stutter. The page moves once per slide instead, as in
/// a browser: right away when the slide's end is known — a keyboard opening
/// to the height it had last time in a window this wide, or one closing —
/// else once the reports stop ([settle], [rest] after the last one). The
/// heights outlive the app's process ([restore]), so a cold start's first
/// keyboard is known up front too.
class WebKeyboard {
  /// Quiet time after which the keyboard counts as at rest.
  static const rest = Duration(milliseconds: 100);

  /// The last height an open keyboard came to rest at, per window width
  /// (shared by every page: it is the phone's keyboard).
  static final _open = <int, double>{};

  /// Where [_open] is kept between runs.
  static const prefsKey = 'web.keyboard';

  static Future<void>? _restored;

  /// Reads the heights of earlier runs, once per run; heights seen since win.
  static Future<void> restore() => _restored ??= () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(prefs.getString(prefsKey) ?? '{}');
      if (json is! Map) return;
      for (final MapEntry(:key, :value) in json.entries) {
        final width = int.tryParse('$key');
        if (width != null && value is num && value > 0) _open.putIfAbsent(width, value.toDouble);
      }
    } catch (_) {
      // No storage (tests, a broken store): learnt again this run.
    }
  }();

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode({for (final e in _open.entries) '${e.key}': e.value}));
    } catch (_) {}
  }

  /// Forgets every height; with [restore], the next [restore] reads the
  /// stored ones again.
  @visibleForTesting
  static void forgetHeights({bool restore = false}) {
    _open.clear();
    _restored = restore ? null : Future<void>.value();
  }

  /// What the page is laid out for.
  double get height => _height;
  double _height = 0;

  /// The height last seen at rest.
  double _rest = 0;

  /// The keyboard reports [raw] in a window [width] wide. True when [height]
  /// changed.
  bool report(double raw, double width) {
    final before = _height;
    if (raw == _rest) {
      _height = raw;
    } else if (raw > _rest) {
      // Opening (or growing): where it ends is known from last time.
      final known = _rest == 0 ? _open[width.round()] : null;
      if (known != null) _height = known;
    } else {
      // Closing: the page goes back down at once, under the keyboard.
      _height = 0;
    }
    return _height != before;
  }

  /// The reports stopped at [raw]. True when [height] changed.
  bool settle(double raw, double width) {
    final before = _height;
    _rest = _height = raw;
    if (raw > 0 && _open[width.round()] != raw) {
      _open[width.round()] = raw;
      unawaited(_save());
    }
    return _height != before;
  }
}

class _WebViewPageState extends State<WebViewPage> {
  late WebViewController _controller;
  late final AppLifecycleListener _lifecycle;
  late final WebViewGuard _guard = WebViewGuard(onGone: _onRendererGone);
  final _files = WebFileChooser();
  int _progress = 0;
  bool _loading = true;
  String? _error;
  DateTime? _hiddenAt;
  Brightness? _bgFor;
  WebPageInsets? _insets;
  WebPageInsets? _appliedInsets;

  /// The keyboard the page is laid out for ([WebKeyboard]).
  final _keyboard = WebKeyboard();
  double _keyboardRaw = 0;
  Timer? _keyboardRest;

  /// The renderer died (crash, or killed in the background): the WebView is
  /// unusable and the page says so until it is reopened.
  bool _gone = false;

  /// Each reopen is a new WebView (a new platform view).
  int _generation = 0;

  /// The app's look the WebView follows (set before the first frame).
  bool _dark = false;
  int _textZoom = 100;

  @override
  void initState() {
    super.initState();
    widget.link?._attach(this);
    unawaited(WebKeyboard.restore());
    _open();
    _lifecycle = AppLifecycleListener(onHide: _onHide, onShow: _onShow);
  }

  /// A new WebView for [WebViewPage.url].
  void _open() {
    _files.invalidate();
    final controller = _controller = WebViewController();
    _loading = true;
    _progress = 0;
    _error = null;
    _appliedInsets = null;
    _sidebarOpen = false;
    unawaited(_setUp(controller));
  }

  Future<void> _setUp(WebViewController controller) async {
    await Future.wait(
      [
        controller.setJavaScriptMode(JavaScriptMode.unrestricted),
        _files.attach(controller),
        controller.setNavigationDelegate(
          NavigationDelegate(
            // DSH Web keeps to its own origin; other pages open in the browser.
            onNavigationRequest: widget.dshWeb ? _onDshWebNavigation : null,
            onPageStarted: (_) {
              if (!mounted || _gone || controller != _controller) return;
              _files.invalidate();
              _set(() {
                _loading = true;
                _error = null;
              });
            },
            onProgress: (p) {
              if (!mounted || _gone || controller != _controller) return;
              _set(() => _progress = p);
            },
            onPageFinished: (_) {
              if (!mounted || _gone || controller != _controller) return;
              _set(() => _loading = false);
              _appliedInsets = null;
              _applyInsets();
              if (widget._adapt) unawaited(_injectPhoneLayout());
              if (widget.dshWeb) unawaited(_injectBackBridge());
              if (widget.dshWeb) unawaited(_injectOpenBridge());
              if (widget.dshWeb) unawaited(_injectSidebarBridge());
              if (widget.dshWeb && widget.onSession != null) {
                unawaited(_injectStateBridge());
              }
            },
            onWebResourceError: (error) {
              if (!mounted || _gone || controller != _controller) return;
              if (kDebugMode) {
                // URLs and descriptions may contain the Host's token.
                debugPrint(
                  '[webview] resource: code=${error.errorCode} '
                  'type=${error.errorType?.name ?? 'unknown'} mainFrame=${error.isForMainFrame}',
                );
              }
              if (error.isForMainFrame ?? true) {
                _set(() {
                  _loading = false;
                  _error = error.description;
                });
              }
            },
          ),
        ),
        // Before the first load: Android only injects a channel on load.
        if (widget.dshWeb && (widget.openTarget != null || widget.link != null))
          controller.addJavaScriptChannel('DshAppOpen', onMessageReceived: _onOpened),
        if (widget.dshWeb && widget.link != null)
          controller.addJavaScriptChannel('DshAppCompose', onMessageReceived: (m) => widget.link?._composed(m.message)),
        if (widget.dshWeb && widget.onSession != null)
          controller.addJavaScriptChannel('DshAppState', onMessageReceived: _onState),
        // Whether DSH Web's own sidebar drawer covers the page (the seat
        // marker steps aside while it does).
        if (widget.dshWeb) controller.addJavaScriptChannel('DshAppSidebar', onMessageReceived: _onSidebar),
      ].map((f) => f.catchError((_) {})),
    );
    if (!mounted || controller != _controller) return;
    // After the navigation delegate: the guard wraps the client it set.
    await _guard.attach(controller, dark: _dark, textZoom: _textZoom);
    if (!mounted || controller != _controller) return;
    await controller.loadRequest(widget.url).catchError((_) {});
  }

  void _onRendererGone(bool crashed) {
    if (_gone || !mounted) return;
    _files.invalidate();
    setState(() {
      _gone = true;
      _loading = false;
    });
    // The dead WebView leaves the tree this frame; then it is destroyed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_guard.destroy());
    });
  }

  /// 重新打开: a new WebView, back where the page was (DSH Web restores its
  /// stored conversation; 网页模式's link re-sends nothing it already did).
  void _reopen() {
    setState(() {
      _gone = false;
      _generation++;
      _targetSent = false;
      _bgFor = null;
      _open();
    });
    _syncLook();
  }

  NavigationDecision _onDshWebNavigation(NavigationRequest request) {
    final decision = dshWebNavigation(widget.url, request.url, request.isMainFrame);
    if (decision == DshWebNavigation.external) {
      unawaited(launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication).catchError((_) => false));
    }
    return decision == DshWebNavigation.stay ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  /// Scripts for the page, read once per run and kept as text (not as
  /// futures: a future answers in the zone that made it).
  static final _sources = <String, String>{};

  static Future<String> _source(String key, Future<String> Function() load) async => _sources[key] ??= await load();

  /// "Open this page" bridge.
  static Future<String> _openBridge() =>
      _source('open', () => rootBundle.loadString('assets/web/dsh_web_open.js', cache: false));

  /// Whether [WebViewPage.openTarget] was handed to the page already.
  bool _targetSent = false;

  /// Whether DSH Web's own sidebar drawer is up (the seat marker steps aside
  /// while it is): reported by `assets/web/dsh_web_sidebar.js`.
  bool _sidebarOpen = false;

  /// Runs on every load: a session hop reloads the page and the bridge
  /// picks the rest of the target up from there. A load that failed
  /// finished on the WebView's own error page: the target and the
  /// [DshWebLink] calls wait for the load that works (重试), rather than
  /// being spent on a page with no DSH Web in it.
  Future<void> _injectOpenBridge() async {
    if (_error != null) return;
    try {
      await _controller.runJavaScript(await _openBridge());
      if (_pendingScripts.isNotEmpty) {
        final scripts = [..._pendingScripts];
        _pendingScripts.clear();
        for (final script in scripts) {
          await _controller.runJavaScript(script);
        }
      }
      final target = widget.openTarget;
      if (_targetSent || target == null || target.isHome) return;
      _targetSent = true;
      await _controller.runJavaScript(target.openScript);
    } catch (_) {
      // Error page without a DOM: the next load injects again.
    }
  }

  /// Back inside the page (`assets/web/dsh_web_back.js`, [WebBack]).
  static Future<String> _backBridgeSource() =>
      _source('back', () => rootBundle.loadString('assets/web/dsh_web_back.js', cache: false));

  Future<void> _injectBackBridge() async {
    try {
      await _controller.runJavaScript(await _backBridgeSource());
    } catch (_) {
      // Error page without a DOM: the next load injects again.
    }
  }

  /// DSH Web's own sidebar drawer, open or folded
  /// (`assets/web/dsh_web_sidebar.js`).
  static Future<String> _sidebarBridge() =>
      _source('sidebar', () => rootBundle.loadString('assets/web/dsh_web_sidebar.js', cache: false));

  Future<void> _injectSidebarBridge() async {
    try {
      await _controller.runJavaScript(await _sidebarBridge());
    } catch (_) {
      // Error page without a DOM: the next load injects again.
    }
  }

  /// The page's sidebar drawer went up or down: the marker in its header row
  /// steps aside for it, so it never covers the sidebar's own brand and rows.
  void _onSidebar(JavaScriptMessage message) {
    final open = message.message == 'open';
    if (open != _sidebarOpen && mounted) setState(() => _sidebarOpen = open);
  }

  /// Session tracking (`assets/web/dsh_web_state.js`).
  static Future<String> _stateBridge() =>
      _source('state', () => rootBundle.loadString('assets/web/dsh_web_state.js', cache: false));

  Future<void> _injectStateBridge() async {
    try {
      await _controller.runJavaScript(await _stateBridge());
    } catch (_) {}
  }

  void _onState(JavaScriptMessage message) {
    final state = DshWebState.parse(message.message);
    if (state != null && mounted) widget.onSession?.call(state.sessionId);
  }

  /// [DshWebLink] calls made before the page (and its bridge) loaded.
  final _pendingScripts = <String>[];

  Future<void> _run(String script) async {
    if (_loading || _error != null || _gone) {
      _pendingScripts.add(script);
      return;
    }
    try {
      await _controller.runJavaScript(script);
    } catch (_) {}
  }

  void _onOpened(JavaScriptMessage message) {
    final problem = DshWebOpenResult.parse(message.message)?.problem;
    if (problem == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(problem)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLook();
    _followKeyboard();
  }

  /// Hands the keyboard's height to [_keyboard] on every report; build lays
  /// the page out for [WebKeyboard.height].
  void _followKeyboard() {
    final raw = MediaQuery.viewInsetsOf(context).bottom;
    if (raw == _keyboardRaw) return;
    _keyboardRaw = raw;
    final width = MediaQuery.sizeOf(context).width;
    _keyboard.report(raw, width);
    _keyboardRest?.cancel();
    _keyboardRest = Timer(WebKeyboard.rest, () {
      if (mounted && _keyboard.settle(_keyboardRaw, width)) setState(() {});
    });
  }

  /// The page colour behind the page, its light or dark, its text size: the
  /// app's.
  void _syncLook() {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final zoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    if (_bgFor != brightness) {
      _bgFor = brightness;
      if (!_gone) {
        unawaited(_controller.setBackgroundColor(_background(brightness)).catchError((_) {}));
      }
    }
    if (dark != _dark) {
      _dark = dark;
      if (!_gone) unawaited(_guard.setDark(dark));
    }
    if (zoom != _textZoom) {
      _textZoom = zoom;
      if (!_gone) unawaited(_guard.setTextZoom(zoom));
    }
  }

  void _applyInsets() {
    final insets = _insets;
    if (_loading || _gone || insets == null || _appliedInsets == insets) {
      return;
    }
    _appliedInsets = insets;
    unawaited(_controller.runJavaScript(insets.script).catchError((_) {}));
  }

  /// CSS + script that fit DSH Web to a touch screen; read once per app run.
  ///
  /// Also hands the page the app's JetBrains Mono: DSH's code font stack
  /// (`"SF Mono", "JetBrains Mono", … Courier`) finds nothing on Android
  /// until `Courier`, which Android maps to a wide typewriter face.
  static Future<String> _phoneLayout() => _source('phone', () async {
    final font = await rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf');
    final fontFace =
        '@font-face{font-family:"JetBrains Mono";font-weight:400;'
        'font-style:normal;font-display:swap;'
        'src:url(data:font/ttf;base64,${base64Encode(font.buffer.asUint8List(font.offsetInBytes, font.lengthInBytes))}) format("truetype")}\n';
    final css = fontFace + await rootBundle.loadString('assets/web/dsh_web_phone.css', cache: false);
    final js = await rootBundle.loadString('assets/web/dsh_web_phone.js', cache: false);
    return [
      '(function () {',
      "  var s = document.getElementById('dsh-app-phone');",
      "  if (!s) { s = document.createElement('style'); s.id = 'dsh-app-phone'; document.head.appendChild(s); }",
      '  s.textContent = ${jsonEncode(css)};',
      '})();',
      js,
    ].join('\n');
  });

  Future<void> _injectPhoneLayout() async {
    try {
      await _controller.runJavaScript(await _phoneLayout());
    } catch (_) {
      // A page without a DOM yet (error page): the next load injects again.
    }
  }

  void _toggleSidebar() {
    if (_gone) return;
    unawaited(_controller.runJavaScript('window.__dshApp && window.__dshApp.toggleSidebar()').catchError((_) {}));
  }

  Color _background(Brightness b) => b == Brightness.dark ? widget.darkBackground : widget.lightBackground;

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  void _onHide() => _hiddenAt = DateTime.now();

  Future<void> _onShow() async {
    final after = widget.reloadAfterBackground;
    final hidden = _hiddenAt;
    _hiddenAt = null;
    if (after == null || hidden == null || _gone || DateTime.now().difference(hidden) <= after) return;
    final controller = _controller;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && widget.dshWeb) {
      try {
        final count = await controller
            .runJavaScriptReturningResult(
              "typeof window.__dshAppPendingAttachmentCount === 'function' ? window.__dshAppPendingAttachmentCount() : null",
            )
            .timeout(const Duration(seconds: 1));
        // Only a definite count protects this draft. An unavailable or stuck
        // page still gets the original socket-recovery reload.
        if (count is num && count.isFinite && count > 0 && count == count.truncateToDouble()) return;
      } on Object {
        // Missing bridge, timeout or WebView error: keep the recovery reload.
      }
    }
    // Asking JavaScript yields: the person may leave or background us again.
    if (!mounted || _gone || _hiddenAt != null || !identical(controller, _controller)) return;
    await controller.reload();
  }

  @override
  void dispose() {
    widget.link?._detach(this);
    _keyboardRest?.cancel();
    _files.dispose();
    _guard.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  /// System back and the back button: what DSH Web has open first (its
  /// dialogs and menus, the drawer, a page inside it), then the page's own
  /// history, then out — off the page, or (as the app's home) out of the app.
  /// One press, one step ([WebBackDispatcher]).
  late final _backs = WebBackDispatcher(
    // A dead WebView is never asked anything again; a loading or failed one
    // has no bridge to ask.
    askPage: () => widget.dshWeb && !_gone && !_loading && _error == null
        ? _controller.runJavaScriptReturningResult(WebBack.script)
        : null,
    canGoBack: () => _gone ? Future.value(false) : _controller.canGoBack(),
    goBack: () => _controller.goBack(),
    leave: _leave,
    isActive: () => mounted,
  );

  Future<void> _back() => _backs.press();

  /// Off the page, or (as the app's home) out of the app.
  Future<void> _leave() async {
    if (!mounted) return;
    if (widget.root) {
      await SystemNavigator.pop();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openExternal() async {
    final current = _gone ? null : await _controller.currentUrl();
    final uri = Uri.tryParse(current ?? '') ?? widget.url;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = _background(theme.brightness);
    final media = MediaQuery.of(context);
    final keyboard = _keyboard.height;
    // The system's bottom padding shrinks as the keyboard slides in; the
    // page's own rest insets keep the gesture bar's (the keyboard has a
    // style of its own, [WebPageInsets.keyboard]).
    final padding = media.padding.copyWith(bottom: media.viewPadding.bottom);
    final insets = WebPageInsets.resolve(
      size: media.size,
      padding: padding,
      keyboard: keyboard,
      dshWeb: widget.dshWeb,
      adapt: widget._adapt,
    );
    // DSH Web lifts its root above the keyboard; other pages shrink above it.
    final shrink = widget.dshWeb ? 0.0 : keyboard;
    if (insets != _insets) {
      _insets = insets;
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyInsets());
    }
    final fadeHeight = insets.rootTop;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: dshSystemOverlay(ThemeData.estimateBrightnessForColor(bg)),
        child: Scaffold(
          backgroundColor: bg,
          // The keyboard never resizes the page as it slides ([WebKeyboard]).
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                // DSH Web pads its own root (its backgrounds run under a
                // cutout); other sites stay out of the cutout and the side
                // navigation bar, fixed headers and footers included.
                padding: widget.dshWeb
                    ? EdgeInsets.zero
                    : EdgeInsets.only(left: padding.left, right: padding.right, bottom: shrink),
                // A dead WebView leaves the tree; a reopen is a new one.
                child: _gone
                    ? const SizedBox.expand()
                    : WebViewWidget(key: ValueKey(_generation), controller: _controller),
              ),
              // No divider: the page colour fades in behind the controls.
              if (!widget.dshWeb)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: fadeHeight,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: featherFade(
                          color: bg,
                          height: fadeHeight,
                          solidUntil: padding.top + WebChromeMetrics.barHeight / 2,
                        ),
                      ),
                    ),
                  ),
                ),
              // Under the controls: the way back stays where it always is.
              if (_gone)
                Positioned.fill(
                  child: ColoredBox(
                    color: bg,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        padding.left,
                        insets.chromeBottom(padding),
                        padding.right,
                        insets.layerBottom + shrink,
                      ),
                      child: RendererGone(label: context.l10n.webPageClosed, onReopen: _reopen),
                    ),
                  ),
                )
              else if (_error case final error?)
                Positioned.fill(
                  child: ColoredBox(
                    color: bg,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        padding.left,
                        insets.chromeBottom(padding),
                        padding.right,
                        insets.layerBottom + shrink,
                      ),
                      child: _LoadError(detail: error, onRetry: () => unawaited(_controller.loadRequest(widget.url))),
                    ),
                  ),
                ),
              if (_loading)
                Positioned(
                  top: padding.top,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    value: _progress <= 0 ? null : _progress / 100,
                    minHeight: 2,
                    borderRadius: BorderRadius.zero,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              switch (insets.chrome) {
                WebChrome.seat => _seatControls(padding),
                WebChrome.inline => _inlineControls(padding, hidden: insets.compact),
                WebChrome.side => _sideControls(padding),
                WebChrome.bar => _bar(context, padding),
              },
            ],
          ),
        ),
      ),
    );
  }

  /// DSH Web as shipped at phone widths: its own drawer layout keeps a
  /// leading seat in the header row, and the marker takes the far left of
  /// that row at the size of the page's own chrome — one mark of the app, no
  /// bar of its own. The page's own opener in the seat moves one gap past the
  /// marker (see the seat CSS in [WebPageInsets.script]), so both stay in the
  /// row DSH Web lays out.
  ///
  /// Its sidebar, opened, slides over that row: the marker steps aside for it
  /// (fades out, and lets touches through to the sidebar's mask) instead of
  /// covering the sidebar's brand and rows.
  Widget _seatControls(EdgeInsets padding) => Positioned(
    key: const ValueKey('web-controls-seat'),
    left: padding.left + WebChromeMetrics.seatLeft,
    top: padding.top + WebChromeMetrics.seatTop,
    child: IgnorePointer(
      ignoring: _sidebarOpen,
      child: AnimatedOpacity(
        opacity: _sidebarOpen ? 0 : 1,
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        child: BackdropGroup(child: _leading(WebChromeMetrics.seatButton, mark: true)),
      ),
    ),
  );

  /// Adapted DSH Web below [dshWebDesktopWidth]: only the two buttons, left-
  /// aligned and sized, so the rest of the page's header row stays touchable.
  Widget _inlineControls(EdgeInsets padding, {required bool hidden}) => Positioned(
    key: const ValueKey('web-controls-inline'),
    left: padding.left + WebChromeMetrics.edge,
    top: padding.top + WebChromeMetrics.inlineTop,
    child: IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        child: GlassOverNativeView(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _leading(WebChromeMetrics.button),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: AppIcons.menu,
                tooltip: context.l10n.webChatsWorkspaces,
                size: WebChromeMetrics.button,
                onPressed: _loading || _error != null || _gone ? null : _toggleSidebar,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// Adapted DSH Web from [dshWebDesktopWidth] up: back, centred in the band
  /// above the sidebar on the icon rail's column (the page's own toggle
  /// opens and closes the sidebar).
  Widget _sideControls(EdgeInsets padding) => Positioned(
    key: const ValueKey('web-controls-side'),
    left: padding.left + (WebChromeMetrics.rail - WebChromeMetrics.button) / 2,
    top: padding.top + (WebChromeMetrics.band - WebChromeMetrics.button) / 2,
    child: _leading(WebChromeMetrics.button),
  );

  /// The back button, or what [WebViewPage.leading] seats there instead.
  ///
  /// [mark]: in DSH Web's own header row, where the page keeps a seat for the
  /// app's marker (the official layout, phone widths), the way back is the
  /// app's mark itself — the same round key as the 网页模式 handle, at the
  /// size of the page's own chrome there.
  Widget _leading(double size, {bool mark = false}) =>
      widget.leading?.call(size) ??
      (mark
          ? WebMarkButton(size: size, tooltip: context.l10n.commonBack, label: context.l10n.commonBack, onTap: _back)
          : GlassIconButton(
              icon: AppIcons.back,
              tooltip: context.l10n.commonBack,
              // The app's own chrome takes the whole 22; a marker the size of
              // the page's own controls shrinks the glyph with it.
              size: size,
              iconSize: math.min(22, size * 0.6),
              onPressed: _back,
            ));

  Widget _bar(BuildContext context, EdgeInsets padding) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Positioned(
      key: const ValueKey('web-controls-bar'),
      left: 0,
      right: 0,
      top: padding.top,
      height: WebChromeMetrics.barHeight,
      child: GlassOverNativeView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left + WebChromeMetrics.edge,
            4,
            padding.right + WebChromeMetrics.edge,
            4,
          ),
          child: Row(
            children: [
              _leading(44),
              // DSH Web (official layout) shows its own title and actions in
              // its header row: just the way back.
              if (!widget.dshWeb) ...[
                const SizedBox(width: 8),
                // The pill hugs its title; the actions keep to the far edge.
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: GlassSurface(
                      tier: GlassTier.chrome,
                      stadium: true,
                      grouped: true,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text.rich(
                        TextSpan(
                          text: widget.title,
                          style: theme.textTheme.titleSmall,
                          children: [
                            if (widget.subtitle case final sub?)
                              TextSpan(
                                text: ' · $sub',
                                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassIconButton(
                  icon: AppIcons.refresh,
                  tooltip: context.l10n.webRefresh,
                  onPressed: () => _gone ? _reopen() : unawaited(_controller.reload()),
                ),
                const SizedBox(width: 8),
                GlassIconButton(
                  icon: AppIcons.browser,
                  tooltip: widget.allowOpenExternal
                      ? context.l10n.webOpenInBrowser
                      : (widget.externalDisabledReason ?? context.l10n.webBrowserUnavailable),
                  onPressed: widget.allowOpenExternal ? () => unawaited(_openExternal()) : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The renderer went away (crashed, or killed in the background): one quiet
/// line in place of the page — 「网页已关闭 · 重新打开」.
class RendererGone extends StatelessWidget {
  const RendererGone({super.key, required this.label, required this.onReopen});

  /// What closed: 网页已关闭, 图表已关闭.
  final String label;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: style),
          Text(' · ', style: style),
          // No side padding: the dot sits a space from either word.
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.bodyMedium,
            ),
            onPressed: onReopen,
            child: Text(context.l10n.webReopen),
          ),
        ],
      ),
    );
  }
}

/// The page didn't load: one line, one button, and the WebView's own
/// error text behind 「详情」.
class _LoadError extends StatefulWidget {
  const _LoadError({required this.detail, required this.onRetry});

  final String detail;
  final VoidCallback onRetry;

  @override
  State<_LoadError> createState() => _LoadErrorState();
}

class _LoadErrorState extends State<_LoadError> {
  bool _detail = false;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyView(
              icon: AppIcons.offline,
              title: context.l10n.webPageNotOpened,
              message: context.l10n.webCheckConnection,
              action: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
                onPressed: widget.onRetry,
                child: Text(context.l10n.commonRetry),
              ),
            ),
            if (widget.detail.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: colors.textTertiary),
                onPressed: () => setState(() => _detail = !_detail),
                child: Text(_detail ? context.l10n.commonCollapse : context.l10n.commonDetails),
              ),
              ExpandReveal(
                open: _detail,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: SelectableText(
                    widget.detail,
                    textAlign: TextAlign.center,
                    style: AppType.monoLabel(color: colors.textTertiary),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A handle on a live DSH Web page ([WebViewPage.link]): open a
/// target, fill the composer. Calls made before the page has loaded run once
/// it has.
class DshWebLink {
  _WebViewPageState? _page;
  Completer<WebComposeResult>? _composing;
  final _correlateComposeReplies = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  final _composeReplies = <String, Completer<WebComposeResult>>{};
  int _composeNumber = 0;

  /// Calls made while no page is attached (the engine still starting, a
  /// host switch rebuilding the page): the next page runs them.
  final _queued = <String>[];

  bool get attached => _page != null;

  void _attach(_WebViewPageState page) {
    _page = page;
    final queued = [..._queued];
    _queued.clear();
    for (final script in queued) {
      unawaited(page._run(script));
    }
  }

  Future<void> _send(String script) async {
    final page = _page;
    if (page == null) {
      _queued.add(script);
    } else {
      await page._run(script);
    }
  }

  void _detach(_WebViewPageState page) {
    if (_page == page) _page = null;
  }

  /// Lands on [target] (see `assets/web/dsh_web_open.js`).
  Future<void> open(DshWebTarget target) => _send(target.openScript);

  /// Puts [text] and [files] (name, MIME type, bytes as base64) in the
  /// composer on screen, as a paste would. Resolves with what landed;
  /// nothing landed when the page is gone or doesn't answer in time.
  Future<WebComposeResult> compose(
    String text, {
    List<({String name, String? type, String base64})> files = const [],
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final done = Completer<WebComposeResult>();
    final requestId = _correlateComposeReplies ? '${++_composeNumber}' : null;
    if (requestId == null) {
      _composing = done;
    } else {
      _composeReplies[requestId] = done;
    }
    final draft = {
      'requestId': ?requestId,
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) 'composerAttachmentCount': true,
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) 'requireOpenedTarget': true,
      'text': text,
      'files': [
        for (final f in files) {'name': f.name, 'type': ?f.type, 'data': f.base64},
      ],
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) 'guardTextFallback': true,
    };
    final script = 'window.__dshAppCompose && window.__dshAppCompose(${jsonEncode(draft)});';
    try {
      await _send(script);
      return await done.future.timeout(timeout, onTimeout: () => const WebComposeResult());
    } finally {
      if (requestId != null) {
        _composeReplies.remove(requestId);
        // A failed paste must not be sent later, after its caller has fallen back.
        _queued.remove(script);
        _page?._pendingScripts.remove(script);
      }
    }
  }

  void _composed(String message) {
    Completer<WebComposeResult>? done;
    if (_correlateComposeReplies) {
      try {
        final reply = jsonDecode(message);
        if (reply is! Map || reply['requestId'] is! String) return;
        done = _composeReplies.remove(reply['requestId']);
      } on FormatException {
        return;
      }
    } else {
      done = _composing;
    }
    if (done == null || done.isCompleted) return;
    done.complete(WebComposeResult.parse(message));
  }
}

/// What [DshWebLink.compose] put in the composer.
class WebComposeResult {
  const WebComposeResult({this.text = false, this.files = 0});

  static WebComposeResult parse(String message) {
    try {
      final json = jsonDecode(message);
      if (json is! Map) return const WebComposeResult();
      final files = json['files'];
      return WebComposeResult(text: json['text'] == true, files: files is int ? files : 0);
    } on FormatException {
      return const WebComposeResult();
    }
  }

  /// The text is in the composer.
  final bool text;

  /// How many files the composer took.
  final int files;
}

/// The page's stored conversation selection (`DshAppState` channel).
class DshWebState {
  const DshWebState(this.sessionId);

  /// Null for anything that isn't a message of ours.
  static DshWebState? parse(String message) {
    try {
      final json = jsonDecode(message);
      if (json is! Map || !json.containsKey('session')) return null;
      final id = json['session'];
      if (id == null) return const DshWebState(null);
      if (id is! String || id.isEmpty || id.length > 200) return null;
      return DshWebState(id);
    } on FormatException {
      return null;
    }
  }

  final String? sessionId;
}
