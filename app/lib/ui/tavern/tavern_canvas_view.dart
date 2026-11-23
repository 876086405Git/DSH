// 整页画布 (tavern_canvas.dart): one web view for the whole story, loaded
// once; messages go in through render(), the reply being written through
// stream() at most every 50 ms. A long press on a message opens the app's own
// message menu. If the web view's renderer goes, it loads again and says so.
// Tests swap the builder (no platform web view there).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dsh_tavern/dsh_tavern.dart' show TavernPersona, TavernSPresetPageLifecycle;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_canvas.dart';
import '../../tavern/tavern_canvas_audio.dart';
import '../../tavern/tavern_canvas_calls.dart';
import '../../tavern/tavern_canvas_helpers.dart' show tavernMvuIssueText;
import '../../tavern/tavern_islands.dart' show tavernFrameBaseUrl, tavernPageColorsJs;
import '../../tavern/tavern_page_perf.dart';
import '../../tavern/tavern_card_scripts.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_st_theme.dart';
import '../common/brief_notice.dart';
import '../theme/theme.dart';
import '../web/web_view_guard.dart';
import 'tavern_ink.dart';
import 'tavern_toasts.dart';

/// What the canvas is handed: the shown messages; the reply being written
/// (its speaker's name and its HTML, null when none) as it changes; what to
/// do when a message is held; and who answers the page's dsh.call, and
/// brings the engine's deliveries back to it, if anyone.
typedef TavernCanvasBuilder = Widget Function({
  required List<TavernCanvasEntry> entries,
  required ValueListenable<(String, String)?> streaming,
  required void Function(String nodeId) onMenu,
  TavernCanvasCalls? calls,
});

/// The libraries card scripts find on the canvas page, as 酒馆助手's pages
/// give them: jQuery, lodash, zod (`z`) and `YAML` (bundled; licences in
/// THIRD_PARTY_NOTICES.md). Islands get them too.
/// The libraries' names, in [tavernCanvasLibrariesProvider]'s order.
const tavernLibraryNames = ['jQuery', 'lodash', 'zod', 'YAML'];

final tavernCanvasLibrariesProvider = FutureProvider<List<String>>(
  (ref) async => [
    await rootBundle.loadString('assets/tavern/jquery-3.7.1.min.js'),
    await rootBundle.loadString('assets/tavern/lodash-4.17.21.min.js'),
    await rootBundle.loadString('assets/tavern/zod-4.6.7.min.js'),
    await rootBundle.loadString('assets/tavern/yaml-2.9.1.min.js'),
  ],
);

/// SPreset's page side, for the canvas only: a preset's SPreset functions
/// are evaluated with it where the preset's scripts run.
final tavernSPresetRuntimeProvider = FutureProvider<String>(
  (ref) => rootBundle.loadString('packages/dsh_tavern/assets/spreset_page_runtime.js'),
);

/// Builds the canvas. Tests swap it.
final tavernCanvasBuilderProvider = Provider<TavernCanvasBuilder>(
  (ref) =>
      ({required entries, required streaming, required onMenu, calls}) =>
          TavernCanvasView(entries: entries, streaming: streaming, onMenu: onMenu, calls: calls),
);

class TavernCanvasView extends ConsumerStatefulWidget {
  const TavernCanvasView({super.key, required this.entries, required this.streaming, required this.onMenu, this.calls});

  final List<TavernCanvasEntry> entries;
  final ValueListenable<(String, String)?> streaming;
  final void Function(String nodeId) onMenu;
  final TavernCanvasCalls? calls;

  @override
  ConsumerState<TavernCanvasView> createState() => _TavernCanvasViewState();
}

class _TavernCanvasViewState extends ConsumerState<TavernCanvasView> {
  WebViewController? _controller;
  late WebViewGuard _guard = WebViewGuard(onGone: _onGone);
  bool _ready = false;
  Object? _loaded;

  /// Which document the page is: one asked by a page since reloaded is not
  /// answered into the new one (its call ids start again).
  int _document = 0;
  String? _rendered;
  Timer? _streamTimer;
  (String, String)? _streamSent;
  final _toasts = TavernToasts();

  @override
  void initState() {
    super.initState();
    _lifecycle = switch (ref.read(tavernProvider)) {
      final TavernSPresetPageLifecycle page => page,
      _ => null,
    };
    widget.streaming.addListener(_onStream);
    widget.calls?.deliver = _deliver;
    _audioLifecycle = TavernCanvasAudioLifecycle(_suspendAudio);
    if (widget.calls?.chatId case final chat?) {
      final audio = ref.read(tavernCanvasAudioProvider(chat).notifier);
      audio.attach(_sendAudio);
      _audio = audio;
    }
  }

  /// The chat's player in the app (舞台 › 会话): what this page's players
  /// are doing goes there, and what the person does there comes here.
  TavernCanvasAudio? _audio;

  /// The app out of sight: the card's music waits for it to be back.
  late final TavernCanvasAudioLifecycle _audioLifecycle;

  /// Whether the app is out of sight: a page that comes up meanwhile is told
  /// so before anything on it plays.
  bool _hidden = false;

  void _suspendAudio(bool on) {
    _hidden = on;
    final controller = _controller;
    if (!_ready || controller == null) return;
    unawaited(controller.runJavaScript('window.dsh&&dsh.audioSuspend($on)').catchError((_) {}));
  }

  Future<void> _sendAudio(Map<String, Object?> command) async {
    final controller = _controller;
    if (!mounted || !_ready || controller == null) return;
    await controller.runJavaScript('window.dsh&&dsh.audioControl(${jsonEncode(command)})');
  }

  /// The engine's delivery for this page's script context, into its copy;
  /// not before the page is ready (it takes a snapshot then anyway).
  Future<bool> _deliver(Map<String, Object?> delivery) async {
    final controller = _controller;
    if (!mounted || !_ready || controller == null) return false;
    await controller.runJavaScript('window.dsh&&dsh.scripts.deliver(${jsonEncode(delivery)})');
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open();
  }

  @override
  void didUpdateWidget(TavernCanvasView old) {
    super.didUpdateWidget(old);
    if (!identical(old.calls, widget.calls)) {
      if (old.calls?.deliver == _deliver) old.calls?.deliver = null;
      widget.calls?.deliver = _deliver;
    }
    if (old.streaming != widget.streaming) {
      old.streaming.removeListener(_onStream);
      widget.streaming.addListener(_onStream);
    }
    // The chat's character came (its summary loaded) or went (a group): the
    // page is built again with its card and scripts, or without.
    if (widget.calls?.characterId() != _character) _open();
    _render();
  }

  /// The character the page was last built for.
  String? _character;

  /// The theme's colours for the page, and the last set it was given.
  Map<String, Color> _colors = const {};
  Map<String, Color>? _pushed;

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
    if (!_ready || controller == null || mapEquals(_pushed, _colors)) return;
    _pushed = _colors;
    unawaited(controller.runJavaScript(tavernPageColorsJs(_colors)).catchError((_) {}));
  }

  /// Loads the page, again when its look or its guards change.
  void _open() {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final ink = TavernInkScope.maybeOf(context);
    final (noScripts, offline) = ref.read(tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline)));
    // An ST theme's custom CSS, with its colours chosen and its CSS kept on.
    final themeCss = ref.read(tavernSettingsProvider.select((s) => s.palette)) == TavernPalette.st
        ? ref.read(tavernStThemeProvider)?.canvasCss ?? ''
        : '';
    final reading = ref.read(tavernSettingsProvider.select((s) => (s.textSize, s.lineHeight)));
    // 省电渲染: the page is built again with it, the story drawn as it was.
    final lowPower = ref.read(tavernSettingsProvider.select((s) => s.lowPower));
    final text = theme.colorScheme.onSurface;
    // Card scripts get their libraries first; the page waits for them (and
    // goes without, should they not load) — not when scripts do not run.
    final List<String> libraries;
    // And the card itself, for the scripts that ask about the character.
    final Map<String, Object?>? card;
    final character = widget.calls?.characterId();
    if (noScripts) {
      libraries = const [];
      card = null;
    } else {
      final loaded = ref.read(tavernCanvasLibrariesProvider);
      final spreset = ref.read(tavernSPresetRuntimeProvider);
      // The chat's scripts are told to the page once it is up (_pushScripts),
      // but it waits for them, so they start with the story.
      final chat = widget.calls?.chatId;
      final scripts = chat == null ? null : ref.read(tavernChatScriptsProvider((chat, character)));
      final data = character == null ? null : ref.read(tavernCardDataProvider(character));
      if (loaded.isLoading || spreset.isLoading || (scripts?.isLoading ?? false) || (data?.isLoading ?? false)) return;
      libraries = [...?loaded.value, ?spreset.value];
      card = data?.value;
    }
    // The colours are set in place on the loaded page (_pushColors), never by
    // loading it again: that would start the card's scripts, and what they
    // write, once more on every step of a theme's cross-fade.
    _colors = {
      'text': text,
      'accent': theme.colorScheme.primary,
      'muted': dsh.textTertiary,
      'user': theme.colorScheme.primary.withValues(alpha: 0.12),
      'quote': ink?.dialogue ?? text,
      'emphasis': ink?.action ?? text,
    };
    _wantDark = theme.brightness == Brightness.dark;
    _syncDark();
    final key = (noScripts, offline, reading, themeCss, card, character, lowPower);
    _character = character;
    if (key == _loaded) {
      _pushColors();
      return;
    }
    _loaded = key;
    // What the old page was running (events, filters, SPreset functions)
    // will not be answered by the new one.
    _pageGone();
    _document++;
    _ready = false;
    _rendered = null;
    // The old page's script buttons go with it, now (a press could not reach
    // them); after this frame, as this can run while the chat page builds.
    if (widget.calls case final calls? when calls.hostButtons.value.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => calls.hostButtons.value = const []);
    }
    final document = tavernCanvasDocument(
      text: text,
      accent: theme.colorScheme.primary,
      muted: dsh.textTertiary,
      quote: ink?.dialogue ?? text,
      emphasis: ink?.action ?? text,
      userTint: theme.colorScheme.primary.withValues(alpha: 0.12),
      fontSize: reading.$1,
      lineHeight: reading.$2,
      nonce: _nonce(),
      page: _document,
      userLabel: context.l10n.tavernYou,
      labels: TavernCanvasLabels(
        letter: context.l10n.tavernLetter,
        letterFrom: context.l10n.tavernLetterFrom('{from}'),
        taken: context.l10n.tavernItemTaken,
        clue: context.l10n.tavernClue,
        phone: context.l10n.tavernPhoneMessage,
        phoneFrom: context.l10n.tavernPhoneFrom('{from}'),
        roll: context.l10n.tavernRoll,
        rollCheck: context.l10n.tavernRollCheck('{skill}'),
        success: context.l10n.tavernRollSuccess,
        failure: context.l10n.tavernRollFailure,
        game: context.l10n.tavernGameHere,
        replied: context.l10n.tavernCanvasReplied('{name}'),
      ),
      noScripts: noScripts,
      offline: offline,
      libraries: libraries,
      themeCss: themeCss,
      card: card,
      characterId: character,
      lowPower: lowPower,
      perf: tavernPerfLog,
    );
    // A controller made here (its libraries came later than the first
    // build) needs a build to be shown: now, or after this frame when this
    // runs while building.
    if (_controller == null) {
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      } else {
        setState(() {});
      }
    }
    final controller = _controller ??= WebViewController();
    final textZoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    final dark = theme.brightness == Brightness.dark;
    final generation = _document;
    unawaited(() async {
      await Future.wait(
        [
          controller.setJavaScriptMode(JavaScriptMode.unrestricted),
          controller.setBackgroundColor(Colors.transparent),
          controller.addJavaScriptChannel('DshTavern', onMessageReceived: (m) => _onMessage(m.message)),
          controller.setNavigationDelegate(NavigationDelegate(onNavigationRequest: _onNavigation)),
          // A card's music starts when its script says, as in a browser tab
          // the page is already playing in.
          if (controller.platform case final AndroidWebViewController android)
            android.setMediaPlaybackRequiresUserGesture(false),
        ].map((f) => f.catchError((_) {})),
      );
      if (!mounted || controller != _controller) return;
      await _guard.attach(controller, dark: dark, textZoom: textZoom).catchError((_) {});
      if (!mounted || controller != _controller) return;
      // A later _open has its own document to load; this one is not loaded.
      if (generation != _document) return;
      _darkSent = dark;
      _syncDark();
      // Whatever came up meanwhile (a page still loading when _open ran) is
      // replaced now: what it was given is settled.
      _pageGone();
      await controller.loadHtmlString(document, baseUrl: tavernFrameBaseUrl).catchError((_) {});
    }());
  }

  /// The page (or document) is gone: what it was running is settled, and
  /// the engine forgets the chat's page state (SPreset entry decisions,
  /// PromptManager collections) before a new document comes.
  void _pageGone() {
    widget.calls?.pageLost();
    if (widget.calls?.chatId case final chat?) _lifecycle?.resetSPresetPage(chat);
  }

  /// The engine's page lifecycle, read once (dispose cannot read providers).
  TavernSPresetPageLifecycle? _lifecycle;

  static final _random = Random.secure();
  static String _nonce() => List.generate(16, (_) => _random.nextInt(36).toRadixString(36)).join();

  void _onMessage(String message) {
    final Object? data;
    try {
      data = jsonDecode(message);
    } on FormatException {
      return;
    }
    // A page since replaced says nothing more (its ready, its answers).
    if (data is! Map || !mounted || data['page'] != _document) return;
    switch (data['type']) {
      case 'ready':
        _ready = true;
        _pushed = null;
        _pushColors();
        _rendered = null;
        _streamSent = null;
        _avatars.reset();
        widget.calls?.hostButtons.value = const [];
        widget.calls?.pageReady();
        _audio?.report(null);
        if (_hidden) _suspendAudio(true);
        _pushPersonas();
        _pushAudio();
        _pushScripts();
        _render();
        _onStream();
      case 'menu':
        if (data['node'] case final String node when node.isNotEmpty) widget.onMenu(node);
      case 'call':
        unawaited(_answer(data));
      case 'invoked':
        widget.calls?.invoked(data);
      case 'spreset':
        widget.calls?.spreset(data);
      case 'ack':
        widget.calls?.acknowledge(data);
      case 'toast':
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger != null) _toasts.show(messenger, data);
      case 'toastClear':
        _toasts.clear(data);
      // A script's buttons changed: the composer's row shows them.
      case 'buttons':
        if (data case {'key': final String key, 'names': final List<Object?> names}) {
          widget.calls?.showButtons(key, [for (final n in names) '$n']);
        }
      // What scripts put in ST's places for buttons: the same row shows them.
      case 'hostButtons':
        if (data['buttons'] case final List<Object?> list) {
          widget.calls?.hostButtons.value = [
            for (final b in list)
              if (b case {'id': final String id, 'label': final String label}) (id: id, label: label),
          ];
        }
      // What the engine said went wrong with the card's variables (MVU),
      // said as a notice: the page went on.
      case 'issues':
        final messenger = ScaffoldMessenger.maybeOf(context);
        final issues = data['issues'];
        if (messenger != null && issues is List && issues.isNotEmpty) {
          _toasts.show(messenger, {
            'level': 'warning',
            'title': context.l10n.tavernMvuIssues,
            'message': tavernMvuIssueText(issues, unfinished: context.l10n.tavernMvuUnfinished),
          });
        }
      case 'audio':
        if (widget.calls?.chatId case final chat?) unawaited(tavernSaveAudio(chat, data['state']).catchError((_) {}));
      case 'audioNow':
        _audio?.report(data['now']);
      case 'perf':
        debugPrint(tavernPerfLine('canvas', data, lowPower: ref.read(tavernSettingsProvider).lowPower));
    }
  }

  /// The chat's players as its scripts left them, for the page that just
  /// came up.
  Future<void> _pushAudio() async {
    final controller = _controller;
    final chat = widget.calls?.chatId;
    if (controller == null || chat == null) return;
    final state = await tavernLoadAudio(chat);
    if (state.isEmpty || !mounted || !identical(controller, _controller)) return;
    await controller.runJavaScript('window.dsh&&dsh.setAudioState(${jsonEncode(state)})').catchError((_) {});
  }

  /// The chat's scripts (global, the current preset's, the card's), to who
  /// answers them and, once the page is up, to the page; not when scripts
  /// do not run.
  void _pushScripts() {
    final calls = widget.calls;
    if (calls == null || ref.read(tavernSettingsProvider).islandNoScripts) return;
    final chosen = ref.read(tavernChatScriptsProvider((calls.chatId, calls.characterId()))).value;
    if (chosen == null) return;
    calls.setScripts(chosen);
    final controller = _controller;
    if (!_ready || controller == null) return;
    final json = jsonEncode([for (final s in chosen.scripts) tavernScriptJson(s)]);
    unawaited(controller.runJavaScript('window.dsh&&dsh.setScripts($json)').catchError((_) {}));
  }

  /// A dsh.call from the page, answered to the page that asked (not to one
  /// built since, after the renderer went).
  Future<void> _answer(Map<Object?, Object?> request) async {
    final controller = _controller;
    final document = _document;
    final calls = widget.calls;
    final reply = calls == null
        ? {
            'id': request['id'],
            'ok': false,
            'error': {'code': 'unsupportedCapability', 'message': 'Nothing answers here.', 'committed': false},
          }
        : await calls.handle(request);
    if (!mounted || controller == null || !identical(controller, _controller) || document != _document) return;
    await controller.runJavaScript('window.dsh&&dsh.answer(${jsonEncode(reply)})').catchError((_) {});
  }

  /// The user's personas and this chat's, for the card scripts that ask
  /// (getPersona …); once the page is ready, and again as they change.
  void _pushPersonas() {
    final controller = _controller;
    final chat = widget.calls?.chatId;
    if (!_ready || controller == null || chat == null) return;
    final personas = ref.read(tavernPersonasProvider).value ?? const <TavernPersona>[];
    final json = tavernCanvasPersonas(personas, ref.read(tavernPersonaSelectionProvider(chat)).value);
    unawaited(controller.runJavaScript('window.dsh&&dsh.setPersonas(${jsonEncode(json)})').catchError((_) {}));
    unawaited(_pushAvatars(controller, personas));
  }

  /// The personas' pictures the page does not have yet, each as it is read.
  final _avatars = TavernCanvasPersonaAvatars();

  Future<void> _pushAvatars(WebViewController controller, List<TavernPersona> personas) async {
    for (final (id, url) in await _avatars.changes(personas)) {
      if (!mounted || !identical(controller, _controller)) return;
      await controller
          .runJavaScript('window.dsh&&dsh.setPersonaAvatar(${jsonEncode(id)},${jsonEncode(url)})')
          .catchError((_) {});
    }
  }

  /// The messages, when they differ from what the page shows.
  void _render() {
    final controller = _controller;
    if (!_ready || controller == null) return;
    final json = tavernCanvasJson(widget.entries);
    if (json == _rendered) return;
    _rendered = json;
    _streamSent = null;
    unawaited(controller.runJavaScript('window.dsh&&dsh.render($json)').catchError((_) {}));
  }

  /// The reply being written, at most every 50 ms (as ST reflows it).
  void _onStream() {
    if (_streamTimer?.isActive ?? false) return;
    _streamTimer = Timer(const Duration(milliseconds: 50), () {
      final controller = _controller;
      final now = widget.streaming.value;
      if (!mounted || !_ready || controller == null || now == _streamSent) return;
      _streamSent = now;
      final call = now == null
          ? 'window.dsh&&dsh.stream("",null)'
          : 'window.dsh&&dsh.stream(${jsonEncode(now.$1)},${jsonEncode(now.$2)})';
      unawaited(controller.runJavaScript(call).catchError((_) {}));
    });
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

  /// The renderer went (a heavy card, memory): a new web view, the story
  /// drawn again, and a word that it happened.
  void _onGone(bool crashed) {
    if (!mounted) return;
    final old = _guard;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(old.destroy()));
    ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.tavernCanvasReloaded);
    // The handlers the lost page was running will not answer; its music
    // stopped with it.
    _pageGone();
    // Its script buttons too, even while the new page waits for what it loads.
    widget.calls?.hostButtons.value = const [];
    _audio?.report(null);
    setState(() {
      _guard = WebViewGuard(onGone: _onGone);
      _controller = null;
      _loaded = null;
      _darkSent = null;
    });
    _open();
  }

  @override
  void dispose() {
    if (widget.calls?.deliver == _deliver) {
      widget.calls?.deliver = null;
      _pageGone();
    }
    if (_audio case final audio?) {
      final send = _sendAudio;
      // Not while the tree is being taken down.
      scheduleMicrotask(() {
        try {
          audio.detach(send);
        } on Object {
          // The app's state went first: nothing to clear.
        }
      });
    }
    _audioLifecycle.dispose();
    widget.streaming.removeListener(_onStream);
    _streamTimer?.cancel();
    _guard.dispose();
    WebViewGuard.release(_controller);
    _toasts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      tavernSettingsProvider.select(
        (s) => (s.islandNoScripts, s.islandOffline, s.textSize, s.lineHeight, s.palette, s.lowPower),
      ),
      (_, _) => _open(),
    );
    ref.listen(tavernStThemeProvider, (_, _) => _open());
    // The user's personas, told to the page as they change (no reload).
    ref.listen(tavernPersonasProvider, (_, _) => _pushPersonas());
    if (widget.calls?.chatId case final chat?) {
      ref.listen(tavernPersonaSelectionProvider(chat), (_, _) => _pushPersonas());
    }
    if (widget.calls?.characterId() case final character?) {
      ref.listen(tavernCardDataProvider(character), (_, next) {
        if (!next.isLoading) _open();
      });
    }
    // The chat's scripts as they change: the page starts, keeps or stops
    // their frames itself, never reloading for them.
    if (widget.calls case final calls?) {
      ref.listen(tavernChatScriptsProvider((calls.chatId, calls.characterId())), (_, next) {
        if (next.isLoading) return;
        _open();
        _pushScripts();
      });
    }
    ref.listen(tavernSPresetRuntimeProvider, (_, next) {
      if (!next.isLoading) _open();
    });
    ref.listen(tavernCanvasLibrariesProvider, (_, next) {
      if (!next.isLoading) _open();
    });
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    return WebViewWidget(key: const ValueKey('tavern-canvas'), controller: controller);
  }
}
