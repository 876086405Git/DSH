// A full-screen preview of a ```mermaid chart from a reply. There is no
// native Mermaid renderer for Flutter worth its weight, so the chart is drawn
// by Mermaid itself in a WebView; the reply keeps showing the source
// (copyable) and only this page needs the network, to fetch Mermaid from a
// CDN (China mirror first). The chart source never leaves the phone.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/l10n.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../web/web_view_guard.dart';
import '../../web/web_view_page.dart' show RendererGone;

/// Where Mermaid is fetched from, in order: npmmirror first (reachable in
/// mainland China), then jsDelivr and unpkg.
const mermaidScriptUrls = [
  'https://registry.npmmirror.com/mermaid/11.4.1/files/dist/mermaid.min.js',
  'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js',
  'https://unpkg.com/mermaid@11.4.1/dist/mermaid.min.js',
];

/// The page Mermaid renders [source] in. `securityLevel: strict` keeps the
/// chart from running scripts or links of its own.
@visibleForTesting
String mermaidHtml(String source, {required bool dark, required Color background, required Color foreground}) {
  String css(Color c) => 'rgb(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()})';
  // `</script>` inside the chart must not end the script element.
  final json = jsonEncode(source).replaceAll('</', r'<\/');
  final urls = jsonEncode(mermaidScriptUrls);
  final origins = mermaidScriptUrls.map((url) => Uri.parse(url).origin).toSet().join(' ');
  return '''
<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' $origins; style-src 'unsafe-inline'; img-src data:; font-src data:">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=6, user-scalable=yes">
<style>
html,body{margin:0;background:${css(background)};color:${css(foreground)};}
#chart{box-sizing:border-box;min-height:100vh;padding:24px 16px;display:flex;align-items:center;justify-content:center;}
#chart svg{max-width:100%;height:auto;}
</style></head>
<body><div id="chart"></div>
<script>
const source = $json;
const urls = $urls;
function post(m){ try { Dsh.postMessage(m); } catch (_) {} }
async function render(){
  try {
    mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'${dark ? 'dark' : 'default'}'});
    const out = await mermaid.render('dsh-chart', source);
    document.getElementById('chart').innerHTML = out.svg;
    post('ok');
  } catch (e) { post('syntax'); }
}
function load(i){
  if (i >= urls.length) { post('offline'); return; }
  const s = document.createElement('script');
  s.src = urls[i];
  s.onload = render;
  s.onerror = function(){ load(i + 1); };
  document.head.appendChild(s);
}
load(0);
</script></body></html>''';
}

/// 全屏预览一张 Mermaid 图表:可双指缩放;没网或语法有误时一句话说明。
class MermaidPreviewPage extends StatefulWidget {
  const MermaidPreviewPage({super.key, required this.source});

  final String source;

  static Route<void> route({required String source}) =>
      MaterialPageRoute<void>(builder: (_) => MermaidPreviewPage(source: source));

  @override
  State<MermaidPreviewPage> createState() => _MermaidPreviewPageState();
}

class _MermaidPreviewPageState extends State<MermaidPreviewPage> {
  WebViewController? _controller;
  late final WebViewGuard _guard = WebViewGuard(onGone: _onRendererGone);
  bool _ready = false;
  String? _problem;

  /// The renderer died: the chart says so until it is reopened (a new
  /// WebView, [_generation]).
  bool _gone = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) _open();
  }

  @override
  void dispose() {
    _guard.dispose();
    if (!_gone) WebViewGuard.release(_controller);
    super.dispose();
  }

  void _open() {
    final theme = Theme.of(context);
    final background = theme.colorScheme.surface;
    final html = mermaidHtml(
      widget.source,
      dark: theme.brightness == Brightness.dark,
      background: background,
      foreground: theme.colorScheme.onSurface,
    );
    final textZoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    final controller = _controller = WebViewController();
    _ready = false;
    _problem = null;
    unawaited(() async {
      await Future.wait(
        [
          controller.setJavaScriptMode(JavaScriptMode.unrestricted),
          controller.setBackgroundColor(background),
          controller.addJavaScriptChannel('Dsh', onMessageReceived: (message) => _onMessage(message.message)),
          controller.setNavigationDelegate(
            NavigationDelegate(
              // The chart is the only page: links inside it go nowhere.
              onNavigationRequest: (request) => request.url == 'about:blank' || request.url.startsWith('data:')
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent,
            ),
          ),
        ].map((f) => f.catchError((_) {})),
      );
      if (!mounted || controller != _controller) return;
      // After the navigation delegate: a dead renderer is reported, not fatal.
      await _guard.attach(controller, dark: theme.brightness == Brightness.dark, textZoom: textZoom);
      if (!mounted || controller != _controller) return;
      await controller.loadHtmlString(html).catchError((_) {});
    }());
  }

  void _onRendererGone(bool crashed) {
    if (_gone || !mounted) return;
    setState(() => _gone = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_guard.destroy()));
  }

  void _reopen() {
    setState(() {
      _gone = false;
      _generation++;
      _open();
    });
  }

  void _onMessage(String message) {
    if (!mounted) return;
    setState(() {
      _ready = message == 'ok';
      _problem = switch (message) {
        'ok' => null,
        'offline' => appL10n.chatMermaidNeedsNetwork,
        _ => appL10n.chatMermaidSyntaxError,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final padding = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        // The page colour runs under the system bars and a side cutout; the
        // header and the chart stay clear of them.
        body: Padding(
          padding: EdgeInsets.fromLTRB(padding.left, padding.top, padding.right, padding.bottom),
          child: Column(
            children: [
              SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: AppIcons.back,
                        tooltip: l10n.commonBack,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(l10n.chatChartPreview, style: theme.textTheme.titleMedium)),
                      GlassIconButton(
                        icon: AppIcons.copy,
                        tooltip: l10n.chatCopyCode,
                        onPressed: () => Clipboard.setData(ClipboardData(text: widget.source)),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    if (!_gone)
                      Positioned.fill(
                        child: WebViewWidget(key: ValueKey(_generation), controller: _controller!),
                      ),
                    if (_gone)
                      Positioned.fill(
                        child: ColoredBox(
                          color: theme.colorScheme.surface,
                          child: RendererGone(label: l10n.chatChartClosed, onReopen: _reopen),
                        ),
                      )
                    else if (!_ready)
                      Positioned.fill(
                        child: ColoredBox(
                          color: theme.colorScheme.surface,
                          child: Center(
                            child: _problem == null
                                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(
                                    _problem!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: DshColors.of(context).textTertiary,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
