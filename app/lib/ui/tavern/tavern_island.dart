// One island (tavern_islands.dart): a message's HTML in a sandboxed web view,
// see-through and as tall as its content, under 酒馆设置 › 安全's choices.
// Links open outside; the page itself never navigates away. Tests swap the
// builder (no platform web view there).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../tavern/tavern_island_story.dart';
import '../../tavern/tavern_islands.dart';
import '../../tavern/tavern_provider.dart' show tavernPersonaSelectionProvider;
import '../../tavern/tavern_settings.dart';
import '../web/web_view_guard.dart';
import 'tavern_canvas_view.dart' show tavernCanvasLibrariesProvider, tavernLibraryNames;
import 'tavern_toasts.dart';

/// Builds the island for a part's HTML. Tests swap it.
final tavernIslandBuilderProvider = Provider<Widget Function(String html)>(
  (ref) =>
      (html) => TavernHtmlIsland(key: ValueKey(html), html: html),
);

/// The message the islands under it are in: what their scripts read of the
/// story starts there (its floor, its variables).
class TavernIslandMessage extends InheritedWidget {
  const TavernIslandMessage({
    super.key,
    required this.chatId,
    required this.nodeId,
    required this.text,
    required this.name,
    required this.user,
    required super.child,
  });

  final String chatId;
  final String nodeId;
  final String text;
  final String name;
  final bool user;

  static TavernIslandMessage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TavernIslandMessage>();

  @override
  bool updateShouldNotify(TavernIslandMessage old) =>
      old.chatId != chatId || old.nodeId != nodeId || old.text != text || old.name != name || old.user != user;
}

class TavernHtmlIsland extends ConsumerStatefulWidget {
  const TavernHtmlIsland({super.key, required this.html});

  final String html;

  /// Heights it may take (logical px): a sliver before it reports, and no
  /// taller than a long page.
  static const minHeight = 24.0;
  static const maxHeight = 4000.0;

  @override
  ConsumerState<TavernHtmlIsland> createState() => _TavernHtmlIslandState();
}

class _TavernHtmlIslandState extends ConsumerState<TavernHtmlIsland> {
  WebViewController? _controller;
  late final WebViewGuard _guard = WebViewGuard(onGone: _onGone);
  double _height = 48;
  bool _gone = false;
  (String, bool, bool, int, String?)? _loaded;

  /// What its scripts get (build works it out): jQuery, lodash, zod and
  /// YAML, what they may read of the story; not loaded while either is on
  /// its way.
  List<String> _libraries = const [];
  Map<String, Object?>? _story;

  /// What of [_story] is this island's own (its floor, its words): the
  /// latest floor's, the chat's and the other variables go along but, as in
  /// 酒馆助手, an island already drawn is not loaded again for them — its
  /// page is told them (dshStoryUpdate), and MVU's update events fire.
  String? _storyKey;
  (Object?, String?, String?, String?)? _storyFrom;
  bool _waiting = true;

  /// The page's script has run (it reported a height): it can be told the
  /// story; [_untold] is a newer one that came before.
  bool _live = false;
  bool _untold = false;

  /// What its toastr calls ask to show, as the app's own notice.
  final _toasts = TavernToasts();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open();
  }

  @override
  void didUpdateWidget(TavernHtmlIsland old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _open();
  }

  /// The theme's colours for the page, and the last set the loaded page was given.
  Map<String, Color> _colors = const {};
  Map<String, Color>? _shown;
  bool _pageLoaded = false;

  /// The page's own light / dark (prefers-color-scheme), kept with the app's:
  /// set at attach, then in place on a theme change, as the colours are.
  bool _wantDark = false;
  bool? _darkSent;

  void _syncDark() {
    if (_darkSent == null || _darkSent == _wantDark) return;
    _darkSent = _wantDark;
    unawaited(_guard.setDark(_wantDark).catchError((_) {}));
  }

  void _pushColors() {
    final controller = _controller;
    if (!mounted || !_pageLoaded || controller == null || mapEquals(_shown, _colors)) return;
    _shown = _colors;
    unawaited(controller.runJavaScript(tavernPageColorsJs(_colors)).catchError((_) {}));
  }

  /// Loads the page, again when what it shows or how it is guarded changes.
  void _open() {
    final theme = Theme.of(context);
    if (_waiting) return;
    final (noScripts, offline) = ref.read(tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline)));
    // The colours are set in place on the loaded page (_pushColors), never by
    // loading it again: a theme's cross-fade would run the card's scripts, and
    // what they write, once per step.
    final (text, accent) = (theme.colorScheme.onSurface, theme.colorScheme.primary);
    _colors = {'text': text, 'accent': accent};
    _wantDark = theme.brightness == Brightness.dark;
    _syncDark();
    final key = (widget.html, noScripts, offline, _libraries.length, _storyKey);
    if (key == _loaded) {
      _pushColors();
      return;
    }
    _pageLoaded = false;
    _loaded = key;
    final document = tavernIslandDocument(
      widget.html,
      text: text,
      accent: accent,
      fontSize: theme.textTheme.bodyLarge?.fontSize ?? 15,
      nonce: _nonce(),
      noScripts: noScripts,
      offline: offline,
      libraries: _libraries,
      story: _story,
    );
    final controller = _controller ??= WebViewController();
    final textZoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    final dark = theme.brightness == Brightness.dark;
    _live = _untold = false;
    unawaited(() async {
      await Future.wait(
        [
          controller.setJavaScriptMode(JavaScriptMode.unrestricted),
          controller.setBackgroundColor(Colors.transparent),
          controller.addJavaScriptChannel('TavernIsland', onMessageReceived: (m) => _onMessage(m.message)),
          controller.setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: _onNavigation,
              onPageFinished: (_) {
                _pageLoaded = true;
                _shown = null;
                _pushColors();
              },
            ),
          ),
        ].map((f) => f.catchError((_) {})),
      );
      if (!mounted || controller != _controller) return;
      await _guard.attach(controller, dark: dark, textZoom: textZoom).catchError((_) {});
      if (!mounted || controller != _controller) return;
      _darkSent = dark;
      _syncDark();
      await controller.loadHtmlString(document, baseUrl: tavernFrameBaseUrl).catchError((_) {});
    }());
  }

  static final _random = Random.secure();
  static String _nonce() => List.generate(16, (_) => _random.nextInt(36).toRadixString(36)).join();

  /// The page's word: its height, or (JSON) a toastr notice.
  void _onMessage(String message) {
    if (!mounted) return;
    if (message.startsWith('{')) {
      final Object? data;
      try {
        data = jsonDecode(message);
      } on FormatException {
        return;
      }
      if (data is! Map) return;
      switch (data['type']) {
        case 'toast':
          final messenger = ScaffoldMessenger.maybeOf(context);
          if (messenger != null) _toasts.show(messenger, data);
        case 'toastClear':
          _toasts.clear(data);
      }
      return;
    }
    final h = double.tryParse(message);
    if (h == null) return;
    if (!_live) {
      _live = true;
      if (_untold) _tell();
    }
    final height = h.clamp(TavernHtmlIsland.minHeight, TavernHtmlIsland.maxHeight).toDouble();
    if ((height - _height).abs() >= 1) setState(() => _height = height);
  }

  /// Tells the page the story as it is now.
  void _tell() {
    _untold = false;
    final story = _story;
    final controller = _controller;
    if (story == null || controller == null) return;
    unawaited(
      controller.runJavaScript('window.dshStoryUpdate&&dshStoryUpdate(${jsonEncode(story)});').catchError((_) {}),
    );
  }

  /// The page itself stays put; a link opens outside the app.
  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = request.url;
    // Its own page, loaded from its base URL (WebKit asks for that load).
    if (url == 'about:blank' ||
        url == tavernFrameBaseUrl ||
        url.startsWith('data:') ||
        url.startsWith('about:srcdoc')) {
      return NavigationDecision.navigate;
    }
    if (!request.isMainFrame) return NavigationDecision.navigate;
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false));
    }
    return NavigationDecision.prevent;
  }

  /// Works out what its scripts get; loads again when that changed. A
  /// library or the story that could not be had: it goes without.
  void _prepare() {
    final scripted =
        !ref.watch(tavernSettingsProvider.select((s) => s.islandNoScripts)) && tavernIslandHasScript(widget.html);
    final libraries = scripted ? ref.watch(tavernCanvasLibrariesProvider) : null;
    final at = scripted && tavernIslandReadsStory(widget.html) ? TavernIslandMessage.maybeOf(context) : null;
    final story = at == null ? null : ref.watch(tavernIslandStoryProvider(at.chatId));
    // The reader's name (SillyTavern's name1).
    final persona = at == null ? null : ref.watch(tavernPersonaSelectionProvider(at.chatId));
    final waiting = (libraries?.isLoading ?? false) || (story?.isLoading ?? false) || (persona?.isLoading ?? false);
    // zod and YAML (over half a megabyte) only where the page could use them.
    final libs = [
      for (final (i, code) in (libraries?.value ?? const <String>[]).indexed)
        if (tavernIslandNeeds(tavernLibraryNames[i], widget.html)) code,
    ];
    final name1 = persona?.value?.persona?.name;
    final from = (story?.value, at?.nodeId, at?.text, name1);
    if (waiting == _waiting && libs.length == _libraries.length && from == _storyFrom) return;
    _storyFrom = from;
    final read = at == null
        ? null
        : story?.value?.forMessage(
            at.nodeId,
            text: at.text,
            name: at.name,
            user: at.user,
            persona: name1 ?? '',
            chatId: at.chatId,
          );
    // What else moves without loading the page again.
    const told = ['latest', 'chat', 'last', 'global', 'character', 'floors'];
    final own = read == null ? null : jsonEncode({...read}..removeWhere((k, _) => told.contains(k)));
    final moved = _story != null && read != null && own == _storyKey;
    // Kept for whenever it loads again (a theme change), though not a reason to.
    _story = read;
    if (waiting == _waiting && libs.length == _libraries.length && own == _storyKey) {
      // The rest of the story moved: the page is told, not loaded again.
      if (moved) _live ? _tell() : _untold = true;
      return;
    }
    _storyKey = own;
    _waiting = waiting;
    _libraries = libs;
    // Built since: the page loads, and the view it is in is drawn.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_open);
    });
  }

  void _onGone(bool crashed) {
    if (_gone || !mounted) return;
    setState(() => _gone = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_guard.destroy()));
  }

  @override
  void dispose() {
    _guard.dispose();
    _toasts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its guards changed: load again.
    ref.listen(tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline)), (_, _) => _open());
    _prepare();
    final controller = _controller;
    if (_gone || controller == null) return const SizedBox(height: TavernHtmlIsland.minHeight);
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: _height,
        child: WebViewWidget(controller: controller),
      ),
    );
  }
}
