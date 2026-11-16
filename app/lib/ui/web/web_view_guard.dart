// Every WebView of the app survives its renderer.
//
// webview_flutter doesn't handle `onRenderProcessGone`: when the renderer
// crashes, or Android kills it for memory in the background, the whole app goes
// with it. The web islands' platform side
// (lib/ui/plugins/islands/island_platform.dart,
// android/.../islands/IslandsPlugin.kt) wraps a WebView's client so the loss is
// reported instead; this attaches the app's own pages to it (the web page,
// 网页模式's home, the chart preview).
//
// All WebViews of the app share one renderer: when it goes, every page shows
// 「网页已关闭 · 重新打开」 and builds a new WebView on demand. The dead one is destroyed
// once no WebViewWidget shows it.
//
// The same attach also gives the page `prefers-color-scheme` from the app's own
// light or dark (per WebView, the switch that works at targetSdk 28) and the
// app's text size, as the islands have.

import 'dart:async';

import 'package:webview_flutter/webview_flutter.dart';

import '../plugins/islands/island_platform.dart';

class WebViewGuard {
  WebViewGuard({required this.onGone});

  /// The renderer is gone ([crashed]: crashed rather than killed).
  final void Function(bool crashed) onGone;

  int? _id;
  StreamSubscription<IslandPlatformEvent>? _events;

  IslandPlatform get _platform => IslandPlatform.instance;

  /// The platform controller's `webViewIdentifier` (webview_flutter_android's
  /// and webview_flutter_ohos's alike), without depending on either package.
  /// Null where a controller has none, as in tests.
  static int? identifierOf(WebViewController controller) {
    try {
      final Object? id = (controller.platform as dynamic).webViewIdentifier;
      return id is int ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Guards [controller]'s WebView. Call after its navigation delegate is
  /// set: the guard wraps the client that sets.
  Future<void> attach(WebViewController controller, {required bool dark, required int textZoom}) async {
    final id = _id = identifierOf(controller);
    if (id == null) return;
    _events ??= _platform.events.listen((event) {
      // One renderer for every WebView: any loss is this page's too.
      if (event is IslandRendererGone) onGone(event.crashed);
    });
    await _platform.attach(id, dark: dark, textZoom: textZoom);
  }

  Future<void> setDark(bool dark) async {
    if (_id case final id?) await _platform.setDark(id, dark);
  }

  Future<void> setTextZoom(int percent) async {
    if (_id case final id?) await _platform.setTextZoom(id, percent);
  }

  /// Destroys the WebView last attached; only once no WebViewWidget shows it.
  Future<void> destroy() async {
    final id = _id;
    _id = null;
    if (id != null) await _platform.destroy(id);
  }

  void dispose() {
    unawaited(_events?.cancel());
    _events = null;
  }
}
