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
        RemoteTunnelCarrier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../l10n/l10n.dart';
import '../../../state/android_features.dart';
import '../../../state/read_list_identity.dart';
import '../../plugins/islands/island_platform.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../web/web_view_guard.dart';
import 'remote_web_error.dart';

/// One page, one original Noise session, one lease. No external browser or
/// credential injection. Current plugin APIs lack isolated profiles/data stores;
/// independent tunnel origins are NOT full storage isolation. Never clear the
/// app-wide cookie or local-storage store, which also holds ordinary logins.
class RemoteWebPage extends ConsumerStatefulWidget {
  const RemoteWebPage({
    super.key,
    required this.carrier,
    required this.session,
    this.trustedTunnelDomains = const {'hostc.4ba.io'},
  });

  final RemoteTunnelCarrier carrier;
  final RemoteHostSession session;
  final Set<String> trustedTunnelDomains;

  @override
  ConsumerState<RemoteWebPage> createState() => _RemoteWebPageState();
}

class _RemoteWebPageState extends ConsumerState<RemoteWebPage> {
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
  Future<void>? _closing;
  Timer? _exchangeDeadline;

  @override
  void initState() {
    super.initState();
    _web = RemoteDshWeb(widget.session, trustedTunnelDomains: widget.trustedTunnelDomains);
    _guard = WebViewGuard(onGone: (_) => _end('WEB_RENDERER_GONE'));
    ref.listenManual(readListLiveConnectionProvider, (_, next) {
      if (!identical(next?.client.carrier, widget.carrier)) _end('CONNECTION_NOT_FOUND');
    });
    _states = widget.carrier.states.listen((state) {
      if (!state.isConnected) _end('CONNECTION_NOT_FOUND');
    });
    _sessions = widget.carrier.sessions.listen((session) {
      if (!identical(session, widget.session)) _end('CONNECTION_NOT_FOUND');
    });
    unawaited(widget.session.rpc.done.then((_) => _end('CONNECTION_NOT_FOUND')));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start(Theme.of(context).brightness == Brightness.dark));
  }

  bool get _current {
    final connection = ref.read(readListLiveConnectionProvider);
    return !_ended &&
        identical(connection?.client.carrier, widget.carrier) &&
        identical(widget.carrier.session, widget.session) &&
        !widget.session.isClosed &&
        (widget.carrier.state?.isConnected ?? connection?.client.mux.state == DshConnectionState.connected);
  }

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
          onNavigationRequest: (request) =>
              _allows(request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageStarted: (url) {
            // Android skips shouldOverrideUrlLoading for some POST navigation.
            // Stop unexpected documents too; never log their URL or body.
            if (!_allows(url)) _end('UNSAFE_WEB_NAVIGATION');
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
      final body = grant.takePostBody();
      _exchangeDeadline = Timer(const Duration(seconds: 30), () => _end('WEB_LOAD_FAILED'));
      try {
        // Android: native postUrl, ignoring headers. iOS: WKWebView URLRequest
        // with form Content-Type. Cookie reception and 303 stay in this view.
        await controller.loadRequest(
          grant.exchangeUrl,
          method: LoadRequestMethod.post,
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: body,
        );
      } finally {
        body.fillRange(0, body.length, 0);
      }
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
    if (!mounted || _ended) return;
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
      // Never reload(): history may still contain the single-use form POST.
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
        actions: [
          GlassIconButton(
            icon: AppIcons.refresh,
            tooltip: l10n.remoteWebRefresh,
            onPressed: _ready && !_ended ? () => unawaited(_refresh()) : null,
          ),
        ],
        slivers: [
          SliverFillRemaining(
            child: SafeArea(
              top: false,
              child: _errorCode != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(remoteWebErrorText(l10n, _errorCode!), textAlign: TextAlign.center),
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
