import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart'
    show
        DshConnectionState,
        RemoteConnectionState,
        RemoteDshWeb,
        RemoteDshWebException,
        RemoteDshWebGrant,
        RemoteHostSession,
        RemoteRpcException,
        RemoteTunnelCarrier,
        defaultDshWebTunnelDomains;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../l10n/l10n.dart';
import '../../../state/android_features.dart';
import '../../../state/read_list_identity.dart';
import '../../common/empty_view.dart';
import '../../plugins/islands/island_platform.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../web/web_view_guard.dart';
import 'remote_web_error.dart';

/// A DSH Remote Host's DSH Web through the Remote tunnel: what 网页版 opens
/// (dsh_web_launcher.dart) while the active host is a DSH Remote host.
///
/// One open, one original Noise session, one lease. No external browser,
/// JavaScript bridge or credential injection: the tunnel's TLS ends at the
/// Remote Server's Worker, so the page gets none of the app's native hooks.
/// Current plugin APIs lack isolated profiles/data stores; independent tunnel
/// origins are NOT full storage isolation. Never clear the app-wide cookie or
/// local-storage store, which also holds ordinary logins.
class RemoteWebPage extends StatefulWidget {
  const RemoteWebPage({
    super.key,
    required this.carrier,
    required this.session,
    this.trustedTunnelDomains = defaultDshWebTunnelDomains,
    this.leading,
  });

  final RemoteTunnelCarrier carrier;
  final RemoteHostSession session;
  final Set<String> trustedTunnelDomains;

  /// 网页模式: the native handle, in the back button's seat (the page is the
  /// app's home).
  final Widget? leading;

  @override
  State<RemoteWebPage> createState() => _RemoteWebPageState();
}

class _RemoteWebPageState extends State<RemoteWebPage> {
  /// 重试 opens anew: a new view and lease, after the old lease's close.
  int _attempt = 0;

  @override
  Widget build(BuildContext context) =>
      _RemoteWebView(key: ValueKey(_attempt), page: widget, onRetry: () => setState(() => _attempt++));
}

class _RemoteWebView extends ConsumerStatefulWidget {
  const _RemoteWebView({super.key, required this.page, required this.onRetry});

  final RemoteWebPage page;
  final VoidCallback onRetry;

  @override
  ConsumerState<_RemoteWebView> createState() => _RemoteWebViewState();
}

class _RemoteWebViewState extends ConsumerState<_RemoteWebView> {
  late final RemoteDshWeb _web;
  late final WebViewGuard _guard;
  StreamSubscription<RemoteConnectionState>? _states;
  StreamSubscription<RemoteHostSession>? _sessions;
  WebViewController? _controller;
  Uri? _root;
  bool _started = false;
  bool _openRequested = false;
  bool _ended = false;
  bool _ready = false;
  String? _errorCode;

  /// The session was still live when the page failed: 重试 can open again.
  bool _canRetry = false;
  Future<void>? _closing;
  Timer? _exchangeDeadline;

  RemoteTunnelCarrier get _carrier => widget.page.carrier;
  RemoteHostSession get _session => widget.page.session;

  @override
  void initState() {
    super.initState();
    _web = RemoteDshWeb(_session, trustedTunnelDomains: widget.page.trustedTunnelDomains);
    _guard = WebViewGuard(onGone: (_) => _end('WEB_RENDERER_GONE'));
    ref.listenManual(readListLiveConnectionProvider, (_, next) {
      if (!identical(next?.client.carrier, _carrier)) _end('CONNECTION_NOT_FOUND');
    });
    _states = _carrier.states.listen((state) {
      if (!state.isConnected) _end('CONNECTION_NOT_FOUND');
    });
    _sessions = _carrier.sessions.listen((session) {
      if (!identical(session, _session)) _end('CONNECTION_NOT_FOUND');
    });
    unawaited(_session.rpc.done.then((_) => _end('CONNECTION_NOT_FOUND')));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start(Theme.of(context).brightness == Brightness.dark));
  }

  /// The Noise session this page opened on is still the live one.
  bool get _live {
    final connection = ref.read(readListLiveConnectionProvider);
    return identical(connection?.client.carrier, _carrier) &&
        identical(_carrier.session, _session) &&
        !_session.isClosed &&
        (_carrier.state?.isConnected ?? connection?.client.mux.state == DshConnectionState.connected);
  }

  bool get _current => !_ended && _live;

  Future<void> _start(bool dark) async {
    RemoteDshWebGrant? grant;
    try {
      final os = ref.read(operatingSystemProvider);
      if (os != 'android' && os != 'ios') {
        _end('WEB_PLATFORM_UNAVAILABLE');
        return;
      }
      if (!_current) {
        _end('CONNECTION_NOT_FOUND');
        return;
      }
      // Configure before obtaining the short-lived grant; no JS bridge, file
      // picker, browser handoff or automatic form resubmission.
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _allows(request.url) || _isExchangePage(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageStarted: (url) {
            // Android skips shouldOverrideUrlLoading for some POST navigation.
            // Stop unexpected documents too; never log their URL or body.
            if (!_allows(url) && !_isExchangePage(url)) _end('UNSAFE_WEB_NAVIGATION');
          },
          onPageFinished: (url) {
            if (!mounted || _ended) return;
            final uri = Uri.tryParse(url);
            if (uri != null && _allows(url) && uri.path == '/' && !uri.hasQuery) {
              _exchangeDeadline?.cancel();
              setState(() => _ready = true);
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != false) _end('WEB_LOAD_FAILED');
          },
          onHttpError: _httpError,
          onSslAuthError: (error) {
            unawaited(error.cancel());
            _end('WEB_LOAD_FAILED');
          },
          onHttpAuthRequest: (request) {
            request.onCancel();
            _end('WEB_SESSION_EXPIRED');
          },
        ),
      );
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        await platform.setAllowFileAccess(false);
        await platform.setAllowContentAccess(false);
        await platform.setMixedContentMode(MixedContentMode.neverAllow);
        await platform.setGeolocationEnabled(false);
        final cookies = WebViewCookieManager().platform as AndroidWebViewCookieManager;
        await cookies.setAcceptThirdPartyCookies(platform, false);
      }
      if (!mounted || _ended) return;
      await _guard.attach(controller, dark: dark, textZoom: 100);
      if (!mounted) return;
      if (!_current) {
        _end('CONNECTION_NOT_FOUND');
        return;
      }
      _openRequested = true;
      grant = await _web.open();
      if (!mounted) return;
      if (!_current) {
        _end('CONNECTION_NOT_FOUND');
        return;
      }
      _root = grant.url;
      final page = grant.takeExchangePage();
      _exchangeDeadline = Timer(const Duration(seconds: 30), () => _end('WEB_LOAD_FAILED'));
      // The form posts the grant from the tunnel's own origin; this WebView
      // takes the session cookie and follows the 303 to `/`.
      await controller.loadHtmlString(page, baseUrl: grant.exchangeBase.toString());
      if (!mounted || _ended) return;
      setState(() {});
    } on Object catch (error) {
      _end(switch (error) {
        RemoteRpcException(:final code) => code,
        RemoteDshWebException(:final code) => code,
        _ => 'WEB_LOAD_FAILED',
      });
    } finally {
      grant?.discard();
      if (!mounted || _ended) _retireView();
    }
  }

  void _httpError(HttpResponseError error) {
    final uri = error.request?.uri ?? error.response?.uri;
    if (_root == null) return;
    if (uri != null && !_allows(uri.toString())) return;
    // Only document and exchange errors retire the view, not subresource failures.
    // WKWebView may omit both URLs; preserve its status-based recovery path.
    if (uri != null && uri.path != '/' && uri.path != '/__remote/session') return;
    final status = error.response?.statusCode;
    if (status == 429) {
      _end('HTTP_429');
      return;
    }
    _end(switch (status) {
      400 || 403 || 405 => 'WEB_EXCHANGE_REJECTED',
      401 || 404 || 410 || 425 => 'WEB_SESSION_EXPIRED',
      _ => 'WEB_LOAD_FAILED',
    });
  }

  bool _allows(String value) {
    if (_ended || _root == null) return false;
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.userInfo.isEmpty && !uri.hasPort && uri.origin == _root!.origin;
  }

  /// The exchange page itself, until the tunnel answers: loaded with the
  /// tunnel as its base URL, which Android reports as about:blank (or its
  /// data: URL).
  bool _isExchangePage(String url) =>
      !_ended && !_ready && _root != null && (url == 'about:blank' || url.startsWith('data:'));

  Future<void> _closeLease() {
    if (!_openRequested) return Future.value();
    return _closing ??= () async {
      try {
        await _web.close();
      } on Object {
        // Original session only, best effort. If disconnected, the server's
        // lease expiry remains authoritative; never close a replacement link.
      }
    }();
  }

  void _retireView() {
    final controller = _controller;
    _controller = null;
    _guard.dispose();
    final id = controller == null ? null : WebViewGuard.identifierOf(controller);
    // Also destroy a view abandoned during setup, before guard.attach ran.
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(IslandPlatform.instance.destroy(id)));
    }
  }

  void _end(String code) {
    if (!mounted) return;
    if (_ended) {
      // Failed while the session was live, which has since gone: 重试 would
      // fail at once; say to reconnect instead.
      if (_canRetry && !_live) {
        setState(() {
          _canRetry = false;
          _errorCode = 'CONNECTION_NOT_FOUND';
        });
      }
      return;
    }
    _canRetry = _live && code != 'WEB_PLATFORM_UNAVAILABLE';
    _ended = true;
    _exchangeDeadline?.cancel();
    _errorCode = code;
    _retireView();
    unawaited(_closeLease());
    setState(() {});
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final controller = _controller;
    final root = _root;
    if (!_ready || controller == null || root == null || !_current) return;
    try {
      // Never reload(): history may still hold the exchange page.
      await controller.loadRequest(root);
    } on Object {
      _end('WEB_LOAD_FAILED');
    }
  }

  @override
  void dispose() {
    _ended = true;
    _exchangeDeadline?.cancel();
    unawaited(_states?.cancel());
    unawaited(_sessions?.cancel());
    unawaited(_closeLease());
    _retireView();
    _guard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controller = _controller;
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        // Queue close before the exit animation: a quick reopen must not beat
        // the old page's cleanup and then have its new lease revoked.
        if (didPop) _end('WEB_SESSION_ENDED');
      },
      child: AppPage(
        title: l10n.remoteWebTitle,
        showLargeTitle: false,
        padBottom: false,
        leading: widget.page.leading,
        actions: [
          GlassIconButton(
            icon: AppIcons.refresh,
            tooltip: l10n.remoteWebRefresh,
            onPressed: _ready && !_ended ? () => unawaited(_refresh()) : null,
          ),
        ],
        slivers: [
          SliverFillRemaining(
            hasScrollBody: _errorCode == null,
            child: SafeArea(
              top: false,
              child: _errorCode != null
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 80),
                      child: Center(
                        child: EmptyView(
                          icon: AppIcons.webApp,
                          title: l10n.remoteWebFailed,
                          message: remoteWebErrorText(l10n, _errorCode!),
                          actionLabel: _canRetry ? l10n.commonRetry : null,
                          onAction: _canRetry ? widget.onRetry : null,
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        if (controller != null && _root != null) WebViewWidget(controller: controller),
                        if (!_ready)
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(l10n.remoteWebOpening),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
