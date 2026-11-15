// Incoming app links (`dshgo://…`, the https landing
// links once App Links are verified) and files opened with / shared to the
// app, routed to the feature that owns them. Native side:
// android/.../links/LinksPlugin.kt (MethodChannel `dsh/links`).
//
// ── For features ────────────────────────────────────────────────────────────
//
//   final router = ref.read(linkRouterProvider);
//   final off = router.registerLinkHandler('forum', (uri) async {
//     … ;
//     return true; // took it; false → the calm 「无法打开这个链接」 toast
//   });
//   router.registerLinkHandler('forum/auth', …); // host + path prefix, longest wins
//   router.registerLinkHandler('example.com/s', …); // https: the URL's host
//   router.registerFileHandler('dshgo', (file) async { … }); // file:// by extension
//   router.registerFileFallback((file) async { … }); // files no extension claims
//   off(); // unregister
//
//   router.context — a BuildContext under the home route (sheets, dialogs,
//   toasts), null while the home shell isn't on screen.
//
// Reserved hosts: `share` (分享码, lib/share_code), `forum` (community login,
// e.g. `dshgo://forum/auth?payload=…`), `open` (a page of the app,
// links/page_links.dart), and the share host's own name for
// hosted conversation links (`dshgo://go.dshtui.com/c/…`, the same as its
// https links; registered by [LinkHost] itself, lib/ui/share_hosted/) and
// the official market's plugin pages (`dshgo://go.dshtui.com/p/…`,
// links/plugin_links.dart).
//
// ── Delivery ────────────────────────────────────────────────────────────────
//
// - Every link and file is dispatched exactly once, including the one that
//   cold-started the app ([AppLinks.links] holds arrivals until its first
//   listener, the router; the native side marks the launch intent as taken).
// - Nothing is dispatched until [LinkHost] is on screen (it sits in the home
//   shell): links that arrive during the splash or onboarding wait.
// - A link with no matching handler waits until one registers, for up to
//   [LinkRouter.grace] after [LinkHost] first appears, then gets the toast.
//   So register at startup — in a widget or provider the home shell builds —
//   not when a page opens; that covers links that cold-start the app (e.g. a
//   browser sign-in that returns after Android killed the app).
// - After that window, unhandled links get the toast right away.
// - A handler that throws counts as `false`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sessions_state.dart' show currentSessionProvider;
import '../ui/share_hosted/hosted_link_host.dart' show registerHostedLinks;
import 'page_links.dart' show pageLinkResolverProvider, registerPageLinks;
import 'plugin_links.dart' show registerPluginLinks;

import '../l10n/l10n.dart';

/// Scheme of the app's own links.
const appLinkScheme = 'dshgo';

/// The native bridge: a broadcast stream of incoming links.
class AppLinks {
  AppLinks({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/links') {
    _controller = StreamController<Uri>.broadcast(onListen: _flush);
    _channel.setMethodCallHandler(_onCall);
    unawaited(_ready());
  }

  /// Scheme of the placeholder for a file the native side couldn't read (too
  /// large, unreadable); its path is the file's name.
  static const unreadableScheme = 'x-dshgo-unreadable';

  final MethodChannel _channel;
  late final StreamController<Uri> _controller;
  final _held = <Uri>[];
  bool _disposed = false;

  /// Incoming links, `file://` URIs of opened / shared files (copied into the
  /// app cache, named as the sender named them) and [unreadableScheme]
  /// placeholders. What arrives while nobody listens is held for the next
  /// listener — so the cold-start link reaches the first one, exactly once.
  Stream<Uri> get links => _controller.stream;

  Future<void> _ready() async {
    try {
      await _channel.invokeMethod<bool>('ready');
    } on MissingPluginException {
      // No native side (widget tests, desktop): no links.
    } on PlatformException {
      // Same: nothing to listen to.
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'link') throw MissingPluginException(call.method);
    final uri = parseNativeLink(call.arguments);
    if (uri != null) add(uri);
    return null;
  }

  /// Delivers [uri] as if it had come from the platform (tests, in-app scans).
  void add(Uri uri) {
    if (_disposed) return;
    if (_controller.hasListener) {
      _controller.add(uri);
    } else {
      _held.add(uri);
    }
  }

  void _flush() {
    final held = List.of(_held);
    _held.clear();
    held.forEach(_controller.add);
  }

  /// One `link` call's arguments → its URI; null for anything malformed.
  static Uri? parseNativeLink(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'];
    if (uri is String && uri.isNotEmpty && uri.length <= 64 * 1024) return Uri.tryParse(uri);
    if (raw['error'] is String) {
      final name = raw['name'];
      return Uri(scheme: unreadableScheme, path: name is String ? name : '');
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    unawaited(_controller.close());
  }
}

/// Takes a link; true when handled.
typedef LinkHandler = Future<bool> Function(Uri uri);

class _Route {
  _Route(this.host, this.prefix, this.handle);

  final String host;
  final String prefix;
  final LinkHandler handle;

  bool matches(Uri uri) {
    if (uri.host.toLowerCase() != host) return false;
    if (prefix.isEmpty) return true;
    final path = uri.path;
    return path == prefix || path.startsWith('$prefix/');
  }
}

/// Sends each incoming link to the feature registered for it.
class LinkRouter {
  LinkRouter(Stream<Uri> links, {this.grace = const Duration(seconds: 4)}) {
    _sub = links.listen(_arrive);
  }

  /// How long, after [LinkHost] first appears, a link waits for its handler.
  final Duration grace;

  late final StreamSubscription<Uri> _sub;
  final _routes = <_Route>[];
  final _files = <String, LinkHandler>{};
  LinkHandler? _fileFallback;
  final _pending = <Uri>[];
  BuildContext? _context;
  void Function(String message)? _toast;
  Stopwatch? _since;
  Timer? _graceTimer;
  bool _graceOver = false;

  /// Under the home route while [LinkHost] is mounted; null otherwise.
  BuildContext? get context {
    final c = _context;
    return c != null && c.mounted ? c : null;
  }

  /// Routes links whose host is [host] — optionally `host/path/prefix`, the
  /// longest registered match wins — to [handle]. For https links the host is
  /// the URL's. Returns the unregister function.
  VoidCallback registerLinkHandler(String host, LinkHandler handle) {
    final key = host.toLowerCase();
    final slash = key.indexOf('/');
    final route = slash < 0
        ? _Route(key, '', handle)
        : _Route(key.substring(0, slash), _trimSlash(key.substring(slash)), handle);
    _routes.add(route);
    // Longest prefix first, so the first match is the most specific.
    _routes.sort((a, b) => b.prefix.length.compareTo(a.prefix.length));
    scheduleMicrotask(_flush);
    return () => _routes.remove(route);
  }

  /// Routes `file://` URIs whose name ends in `.<extension>` to [handle].
  VoidCallback registerFileHandler(String extension, LinkHandler handle) {
    final key = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    _files[key] = handle;
    scheduleMicrotask(_flush);
    return () {
      if (_files[key] == handle) _files.remove(key);
    };
  }

  /// Routes `file://` URIs that no [registerFileHandler] extension takes to
  /// [handle] (lib/ui/shell/system_entry_host.dart: into a new conversation).
  /// One at a time; the latest wins.
  VoidCallback registerFileFallback(LinkHandler handle) {
    _fileFallback = handle;
    scheduleMicrotask(_flush);
    return () {
      if (_fileFallback == handle) _fileFallback = null;
    };
  }

  static String _trimSlash(String path) => path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// [LinkHost] is on screen: start dispatching, toasts through [toast].
  void attach(BuildContext context, {required void Function(String message) toast}) {
    _context = context;
    _toast = toast;
    _since ??= Stopwatch()..start();
    _flush();
  }

  void detach(BuildContext context) {
    if (!identical(_context, context)) return;
    _context = null;
    _toast = null;
  }

  /// Dispatches [uri] now (an in-app scan or paste): the toast when nobody
  /// takes it. True when handled.
  Future<bool> open(Uri uri) async {
    final handler = _handlerFor(uri);
    if (handler == null) {
      _unhandled(uri);
      return false;
    }
    return _run(uri, handler);
  }

  void _arrive(Uri uri) {
    _pending.add(uri);
    _flush();
  }

  void _flush() {
    if (context == null || _pending.isEmpty) return;
    final now = List.of(_pending);
    _pending.clear();
    for (final uri in now) {
      final handler = _handlerFor(uri);
      if (handler != null) {
        unawaited(_run(uri, handler));
      } else if (_settled || !_canWait(uri)) {
        _unhandled(uri);
      } else {
        _pending.add(uri);
      }
    }
    // A timer only while something waits: an idle router leaves no timer behind.
    if (_pending.isNotEmpty && !_settled) {
      _graceTimer ??= Timer(grace - _since!.elapsed, () {
        _graceOver = true;
        _flush();
      });
    }
  }

  /// The grace window after the first attach is over.
  bool get _settled => _graceOver || (_since?.elapsed ?? Duration.zero) >= grace;

  LinkHandler? _handlerFor(Uri uri) {
    switch (uri.scheme.toLowerCase()) {
      case appLinkScheme || 'https' || 'http':
        for (final route in _routes) {
          if (route.matches(uri)) return route.handle;
        }
        return null;
      case 'file':
        final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
        final dot = name.lastIndexOf('.');
        final byExtension = dot < 0 ? null : _files[name.substring(dot + 1).toLowerCase()];
        return byExtension ?? _fileFallback;
      default:
        return null;
    }
  }

  static bool _canWait(Uri uri) => switch (uri.scheme.toLowerCase()) {
    appLinkScheme || 'https' || 'http' || 'file' => true,
    _ => false,
  };

  Future<bool> _run(Uri uri, LinkHandler handler) async {
    var handled = false;
    try {
      handled = await handler(uri);
    } catch (error, stack) {
      debugPrint('link handler failed for ${uri.scheme}://${uri.host}: $error\n$stack');
    }
    if (!handled) _unhandled(uri);
    return handled;
  }

  /// Says [message] where the router's own toast goes, for a handler that took
  /// a link and has only this to say about it.
  void toast(String message) => _toast?.call(message);

  void _unhandled(Uri uri) {
    final file = uri.scheme == 'file' || uri.scheme == AppLinks.unreadableScheme;
    _toast?.call(file ? appL10n.stateFileOpenFailed : appL10n.stateLinkOpenFailed);
  }

  void dispose() {
    _graceTimer?.cancel();
    unawaited(_sub.cancel());
  }
}

final appLinksProvider = Provider<AppLinks>((ref) {
  final links = AppLinks();
  ref.onDispose(links.dispose);
  return links;
});

final linkRouterProvider = Provider<LinkRouter>((ref) {
  final router = LinkRouter(ref.watch(appLinksProvider).links);
  ref.onDispose(router.dispose);
  return router;
});

/// Put it once inside the home route (the home shell's stack, next to the
/// notification host). It draws nothing: it gives the router its context and
/// shows the toast for links nobody takes.
class LinkHost extends ConsumerStatefulWidget {
  const LinkHost({super.key});

  @override
  ConsumerState<LinkHost> createState() => _LinkHostState();
}

class _LinkHostState extends ConsumerState<LinkHost> {
  late final LinkRouter _router;
  late final VoidCallback _offHosted;
  late final VoidCallback _offPlugins;
  late final VoidCallback _offPages;

  @override
  void initState() {
    super.initState();
    _router = ref.read(linkRouterProvider);
    // Hosted conversation links: no feature page owns them, the replay opens.
    _offHosted = registerHostedLinks(_router);
    // A plugin's page in the official market: its detail sheet.
    _offPlugins = registerPluginLinks(_router);
    // `dshgo://open/<page>`: the guide's links to the app's own pages.
    _offPages = registerPageLinks(
      _router,
      session: () => ref.read(currentSessionProvider),
      page: ref.read(pageLinkResolverProvider),
    );
    // After the first frame: the home route is laid out before a sheet opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _router.attach(context, toast: _toast);
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _offHosted();
    _offPlugins();
    _offPages();
    _router.detach(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
