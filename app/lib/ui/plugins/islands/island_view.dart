import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seat_models.dart';
import '../../common/app_dialog.dart';
import '../../common/smooth_size.dart';
import '../../theme/theme.dart';
import 'island_gate.dart';
import 'island_handle.dart';
import 'island_host.dart';
import 'island_messages.dart';
import 'island_skeleton.dart';
import 'island_theme.dart';

/// How an island's WebView is drawn before it is ready. Fully see-through would
/// mean not drawn at all, and on iOS a platform view that isn't drawn leaves the
/// window and has no size: DSH Web would have nothing to lay itself out for.
double get _hiddenOpacity => defaultTargetPlatform == TargetPlatform.iOS ? 0.01 : 0;

/// Probe islands: the size DSH Web lays itself out for, off screen.
abstract final class IslandProbeMetrics {
  static const width = 360.0;
  static const height = 640.0;
}

/// Panel islands: the panel's height range (logical px).
abstract final class IslandPanelMetrics {
  static const minHeight = 72.0;
  static const maxHeight = 360.0;
}

/// A web island in a native seat (§6): DSH Web with only [spec]'s slot
/// showing, in one of three forms —
///
/// - [IslandForm.page]: fills the box it gets; the page scrolls itself.
/// - [IslandForm.panel]: as tall as its content (size messages), from
///   [IslandPanelMetrics.minHeight] up to [panelMaxHeight]; past that it
///   scrolls inside. Every gesture on it belongs to the page.
/// - [IslandForm.overlay]: fills the box, see-through; it only takes the
///   touches inside the regions the page reports, the rest fall through to
///   whatever is underneath.
///
/// Hidden behind a skeleton until the slot is on screen; [fallback] (the
/// seat's "open in DSH Web" row) when it can't be: no recipe, no room, no
/// `ready` in time, the slot missing or empty.
class IslandView extends ConsumerStatefulWidget {
  const IslandView({
    super.key,
    required this.spec,
    required this.fallback,
    this.labels = const [],
    this.panelMaxHeight = IslandPanelMetrics.maxHeight,
    this.insets = EdgeInsets.zero,
    this.onOpenSession,
    this.onReady,
  });

  final IslandSpec spec;
  final WidgetBuilder fallback;

  /// The occupant's labels (zh / en): how island.js finds a third-party
  /// settings section, panel or tab, which have no ids on screen.
  final List<String> labels;

  final double panelMaxHeight;

  /// Room the page keeps clear (under a floating header, above the
  /// gesture bar).
  final EdgeInsets insets;

  /// The plugin asked to open a conversation: open it natively when it
  /// exists (and say whether it did).
  final Future<bool> Function(String sessionId)? onOpenSession;

  /// The slot is on screen (probes: the bridge reported its occupancy).
  final ValueChanged<IslandHandle>? onReady;

  @override
  ConsumerState<IslandView> createState() => _IslandViewState();
}

class _IslandViewState extends ConsumerState<IslandView> {
  late final IslandHost _host;
  IslandHandle? _handle;
  StreamSubscription<IslandMessage>? _requests;
  bool _acquiring = false;

  /// acquire() had nothing for us: show the fallback.
  bool _none = false;

  /// No room right now (islands ranked as high are on screen): the
  /// fallback, until the pool changes.
  bool _noRoom = false;

  /// The renderer died under this view: 「插件界面已关闭」 until reopened.
  bool _closed = false;
  Uri? _url;
  int _generation = 0;
  bool _readyReported = false;

  static final _gestures = <Factory<OneSequenceGestureRecognizer>>{
    Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  IslandTheme _theme(BuildContext context) =>
      IslandTheme.fromTheme(Theme.of(context), textScale: MediaQuery.textScalerOf(context).scale(16) / 16);

  /// On screen: the top route, ticking (not an inactive tab).
  bool _visible(BuildContext context) =>
      TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);

  @override
  void initState() {
    super.initState();
    _host = ref.read(islandHostProvider)..addListener(_onHost);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final handle = _handle;
    if (handle != null) {
      handle.setTheme(_theme(context));
      _host.setVisible(handle, _visible(context));
    }
  }

  @override
  void didUpdateWidget(IslandView old) {
    super.didUpdateWidget(old);
    if (old.spec != widget.spec) {
      _release();
      _none = false;
      _noRoom = false;
    }
    if (old.insets != widget.insets) unawaited(_handle?.setInsets(widget.insets));
  }

  Future<void> _acquire(Uri url) async {
    if (_acquiring) return;
    _acquiring = true;
    final generation = ++_generation;
    final handle = await _host.acquire(
      widget.spec,
      url: url,
      theme: _theme(context),
      labels: widget.labels,
      visible: _visible(context),
    );
    _acquiring = false;
    if (!mounted || generation != _generation) {
      if (handle != null) _host.detachView(handle);
      return;
    }
    if (handle == null) {
      setState(() {
        if (_host.hasRoomFor(widget.spec)) {
          _none = true;
        } else {
          _noRoom = true;
        }
      });
      return;
    }
    _handle = handle;
    _url = url;
    _host.setVisible(handle, _visible(context));
    handle.addListener(_onHandle);
    _requests = handle.requests.listen(_onRequest);
    unawaited(handle.setInsets(widget.insets));
    _onHandle();
  }

  void _release() {
    _generation++;
    final handle = _handle;
    _handle = null;
    _url = null;
    _readyReported = false;
    unawaited(_requests?.cancel());
    _requests = null;
    if (handle != null) {
      handle.removeListener(_onHandle);
      _host.detachView(handle);
    }
  }

  /// The pool changed. Often while another view is being torn down (its
  /// island detaching), so the rebuild waits for the next frame.
  void _onHost() {
    if (!mounted) return;
    var changed = false;
    if (_host.rendererLost && !_closed) {
      _release();
      _closed = true;
      changed = true;
    } else if (_noRoom && _host.hasRoomFor(widget.spec)) {
      _noRoom = false;
      changed = true;
    }
    if (!changed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onHandle() {
    final handle = _handle;
    if (handle == null || !mounted) return;
    if (handle.phase == IslandPhase.ready && !_readyReported) {
      _readyReported = true;
      widget.onReady?.call(handle);
    }
    if (handle.phase == IslandPhase.closed || handle.phase == IslandPhase.failed) {
      final failure = handle.failure;
      _release();
      if (failure == IslandFailure.renderer) {
        _closed = true;
      } else if (failure != IslandFailure.evicted) {
        // Its own failure: the seat falls back (and the planner, which sees
        // the failure in the budget, plans a web link next time).
        _none = true;
      }
      // Evicted: comes back cold once on screen again.
    }
    setState(() {});
  }

  void _reopen() {
    _host.reopen();
    setState(() {
      _closed = false;
      _none = false;
    });
  }

  Future<void> _onRequest(IslandMessage message) async {
    if (!mounted) return;
    switch (message) {
      case IslandLink(:final url):
        if (await _confirmLink(context, url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication).catchError((_) => false);
        }
      case IslandOpenSession(:final sessionId):
        await widget.onOpenSession?.call(sessionId);
      default:
        break;
    }
  }

  @override
  void dispose() {
    _release();
    _host.removeListener(_onHost);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = ref.watch(islandHostUrlProvider(widget.spec.host));
    if (url == null) return widget.fallback(context);
    if (_url != null && url != _url) {
      // A restarted engine (new token) or a reconnected tunnel.
      _release();
      _none = false;
    }
    if (_closed) {
      return widget.spec.form == IslandForm.overlay ? widget.fallback(context) : _Closed(onReopen: _reopen);
    }
    if (_none || _noRoom) return widget.fallback(context);
    final handle = _handle;
    if (handle == null) {
      // Only an island on screen asks for room: one under another page
      // would just push out the one in front of it.
      if (!_acquiring && _visible(context)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _handle == null && !_none && !_closed) unawaited(_acquire(url));
        });
      }
      return _loading();
    }
    final ready = handle.phase == IslandPhase.ready;
    final web = WebViewWidget(key: ObjectKey(handle), controller: handle.controller, gestureRecognizers: _gestures);
    return switch (widget.spec.form) {
      IslandForm.page => _stack(web, ready),
      IslandForm.panel => SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: ready
              ? (handle.contentHeight ?? IslandPanelMetrics.minHeight).clamp(
                  IslandPanelMetrics.minHeight,
                  widget.panelMaxHeight,
                )
              : IslandPanelMetrics.minHeight * 2,
          child: _stack(web, ready, skeletonRows: 2),
        ),
      ),
      IslandForm.overlay => IgnorePointer(
        ignoring: !ready,
        child: Opacity(
          opacity: ready ? 1 : _hiddenOpacity,
          child: IslandHitRegion(rects: handle.hitRects, child: web),
        ),
      ),
      // Laid out at a phone's size (DSH Web boots as it would on screen),
      // clipped to nothing and see-through.
      IslandForm.probe => SizedBox.square(
        dimension: 1,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: IslandProbeMetrics.width,
            maxWidth: IslandProbeMetrics.width,
            minHeight: IslandProbeMetrics.height,
            maxHeight: IslandProbeMetrics.height,
            child: Opacity(
              opacity: _hiddenOpacity,
              child: IgnorePointer(child: web),
            ),
          ),
        ),
      ),
    };
  }

  Widget _loading() => switch (widget.spec.form) {
    IslandForm.page => const IslandSkeleton(),
    IslandForm.panel => const SizedBox(height: IslandPanelMetrics.minHeight * 2, child: IslandSkeleton(rows: 2)),
    IslandForm.overlay || IslandForm.probe => const SizedBox.shrink(),
  };

  /// The WebView laid out at its real size from the start (DSH Web lays
  /// itself out for it while hidden), the skeleton over it until ready.
  Widget _stack(Widget web, bool ready, {int skeletonRows = 6}) => Stack(
    fit: StackFit.expand,
    children: [
      IgnorePointer(
        ignoring: !ready,
        child: Opacity(opacity: ready ? 1 : _hiddenOpacity, child: web),
      ),
      IgnorePointer(
        child: AnimatedOpacity(
          opacity: ready ? 0 : 1,
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.std,
          child: Align(
            alignment: Alignment.topCenter,
            child: IslandSkeleton(rows: skeletonRows),
          ),
        ),
      ),
    ],
  );
}

/// 「插件界面已关闭」: the WebView renderer died and took every island
/// with it. One tap brings them back.
class _Closed extends StatelessWidget {
  const _Closed({required this.onReopen});

  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.pluginsIslandClosed, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
            const SizedBox(height: 8),
            TextButton(onPressed: onReopen, child: Text(l10n.pluginsReopen)),
          ],
        ),
      ),
    );
  }
}

/// 「在浏览器打开 example.com？」
Future<bool> _confirmLink(BuildContext context, Uri url) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.pluginsOpenBrowserHost(url.host)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.commonOpen)),
      ],
    ),
  );
  return ok == true;
}

/// Takes pointer events only inside [rects] (the overlay island's reported
/// regions); everywhere else the hit test fails and the event goes to the
/// widgets underneath. Flutter hit-tests in Dart before a platform view sees
/// anything, so the WebView never learns about the other touches.
class IslandHitRegion extends SingleChildRenderObjectWidget {
  const IslandHitRegion({super.key, required this.rects, super.child});

  final List<Rect> rects;

  @override
  RenderIslandHitRegion createRenderObject(BuildContext context) => RenderIslandHitRegion(rects);

  @override
  void updateRenderObject(BuildContext context, RenderIslandHitRegion renderObject) => renderObject.rects = rects;
}

class RenderIslandHitRegion extends RenderProxyBox {
  RenderIslandHitRegion(this.rects);

  List<Rect> rects;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!rects.any((r) => r.contains(position))) return false;
    return super.hitTest(result, position: position);
  }
}
