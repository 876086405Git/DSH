// The push itself follows the shape of
// Flutter's CupertinoPageTransition; the back gesture reuses the framework's
// public PredictiveBackRoute hooks on TransitionRoute.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

import 'motion.dart';
import 'shapes.dart';
import 'sheet_recede.dart';

/// Secondary pages push in from the right, iOS style: the new page slides over
/// with a soft shadow on its leading edge while the page underneath drifts a
/// quarter to the left and dims a little.
///
/// The back gesture follows the finger, two ways:
///
/// - Android's system back gesture (Android 14+, when the app opts into
///   predictive back with `android:enableOnBackInvokedCallback="true"`) drives
///   the same transition through the framework's predictive-back hooks;
/// - a 20dp strip at the leading edge takes an in-app swipe (three-button
///   navigation, tablets, desktop).
///
/// Release past the middle, or fling right, and the page leaves; otherwise it
/// settles back. The in-app swipe hands its speed to a spring for either.
///
/// The fluid tier ([AppMotion.fluid]) adds two things:
///
/// - the page underneath is drawn from a snapshot while it moves, so its glass
///   doesn't re-sample the backdrop every frame (the transition gets cheaper);
/// - a page pushed from a card ([CardOrigin]) grows out of that card, and shrinks
///   back into it on the way out.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder() : _duration = AppMotion.push;

  /// The same transition taking no time, for [AppMotion.reduced]. A builder has
  /// no context to ask, and the route reads this duration from the theme at
  /// every push and pop, so the theme picks this one (lib/app.dart).
  const AppPageTransitionsBuilder.instant() : _duration = Duration.zero;

  /// A little more time on the fluid tier: a page growing out of a card has further
  /// to go than one sliding in, and the route reads one duration for both.
  const AppPageTransitionsBuilder.fluid() : _duration = AppMotion.pushFluid;

  final Duration _duration;

  @override
  Duration get transitionDuration => _duration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) =>
          _Recede(animation: secondaryAnimation, linear: false, child: child ?? const SizedBox.shrink());

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final linear = route.popGestureInProgress;
    final origin = CardOrigin._claim(route);
    return _BackGesture(
      route: route,
      child: SheetRecedePage(
        child: _Recede(
          animation: secondaryAnimation,
          linear: linear,
          route: route,
          child: origin == null
              ? _PushIn(animation: animation, linear: linear, child: child)
              : _CardMorph(animation: animation, linear: linear, origin: origin, child: child),
        ),
      ),
    );
  }
}

/// Where the page about to be pushed comes from: a card just tapped.
///
/// The card calls [remember] right before its `onTap`. If that tap pushes a page
/// with this theme's transition in the same frame, the page takes the card as its
/// origin; a tap that opens a sheet, or pushes after waiting for something, leaves
/// it unused and gets the normal push. Only in the fluid tier.
class CardOrigin {
  CardOrigin._(this.rect, this.radius, this.source);

  /// In the navigator's coordinates.
  final Rect rect;
  final double radius;

  /// The page holding the card. It stays put while the card grows over it.
  final Route<dynamic>? source;

  static CardOrigin? _pending;
  static final _claims = Expando<_Claim>('CardOrigin.claims');
  static final _covers = Expando<int>('CardOrigin.covers');

  /// [card]'s render box is the card's outline.
  static void remember(BuildContext card, {double radius = AppShape.lg}) {
    if (!AppMotion.fluid(card)) return;
    final box = card.findRenderObject();
    final frame = Navigator.maybeOf(card)?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || frame is! RenderBox) return;
    _pending = CardOrigin._(box.localToGlobal(Offset.zero, ancestor: frame) & box.size, radius, ModalRoute.of(card));
    // Gone after the next frame, whether or not anything took it.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _pending = null)
      ..ensureVisualUpdate();
  }

  /// The origin of [route], fixed the first time the route is built.
  static CardOrigin? _claim(PageRoute<dynamic> route) {
    final known = _claims[route];
    if (known != null) return known.origin;
    final pending = _pending;
    final origin = pending != null && route.isCurrent && !identical(route, pending.source) ? pending : null;
    _claims[route] = _Claim(origin);
    if (origin != null) {
      _pending = null;
      final source = origin.source;
      if (source != null) {
        _covers[source] = (_covers[source] ?? 0) + 1;
        route.completed.whenComplete(() => _covers[source] = (_covers[source] ?? 1) - 1);
      }
    }
    return origin;
  }

  static bool _covered(Route<dynamic>? route) => route != null && (_covers[route] ?? 0) > 0;
}

/// Expando can't hold null: "looked, no origin" needs a value of its own.
class _Claim {
  const _Claim(this.origin);
  final CardOrigin? origin;
}

/// A page growing out of its card: laid out at full size, drawn scaled to the
/// card's width and cut to the card's height, until both reach the whole window.
/// Linear (finger-driven) while a back gesture is in progress.
class _CardMorph extends StatefulWidget {
  const _CardMorph({required this.animation, required this.linear, required this.origin, required this.child});

  final Animation<double> animation;
  final bool linear;
  final CardOrigin origin;
  final Widget child;

  @override
  State<_CardMorph> createState() => _CardMorphState();
}

class _CardMorphState extends State<_CardMorph> {
  /// The page has faded in by this far along: the card is still small, so the
  /// page seems to be the card from early on.
  static const _fadeBy = 0.3;

  late CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _curved = _curve();
  }

  CurvedAnimation _curve() => CurvedAnimation(
    parent: widget.animation,
    // Not the push's glide: most of that happens in the first 100ms, too quick to
    // see where the page came from.
    curve: widget.linear ? Curves.linear : AppMotion.std,
    reverseCurve: widget.linear ? Curves.linear : AppMotion.std.flipped,
  );

  @override
  void didUpdateWidget(_CardMorph old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation || old.linear != widget.linear) {
      _curved.dispose();
      _curved = _curve();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).brightness == Brightness.dark ? 0.32 : 0.10;
    final origin = widget.origin;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return AnimatedBuilder(
          animation: _curved,
          child: widget.child,
          builder: (context, child) {
            final t = _curved.value.clamp(0.0, 1.0);
            final rect = Rect.lerp(origin.rect, Offset.zero & size, t)!;
            final scale = rect.width / size.width;
            return Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: dim * t)),
                ),
                Transform(
                  transform: Matrix4.identity()
                    ..translateByDouble(rect.left, rect.top, 0, 1)
                    ..scaleByDouble(scale, scale, 1, 1),
                  child: ClipRRect(
                    clipBehavior: t < 1 ? Clip.antiAlias : Clip.none,
                    clipper: _PageCut(height: rect.height / scale, radius: origin.radius * (1 - t) / scale),
                    child: Opacity(opacity: (t / _fadeBy).clamp(0.0, 1.0), alwaysIncludeSemantics: true, child: child),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The top [height] of the page, rounded.
class _PageCut extends CustomClipper<RRect> {
  const _PageCut({required this.height, required this.radius});

  final double height;
  final double radius;

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(Offset.zero & Size(size.width, height), Radius.circular(radius));

  @override
  bool shouldReclip(_PageCut old) => old.height != height || old.radius != radius;
}

/// The incoming page: slides in from the right with a shadow on its leading
/// edge. Linear (finger-driven) while a back gesture is in progress.
class _PushIn extends StatefulWidget {
  const _PushIn({required this.animation, required this.linear, required this.child});

  final Animation<double> animation;
  final bool linear;
  final Widget child;

  @override
  State<_PushIn> createState() => _PushInState();
}

class _PushInState extends State<_PushIn> {
  late CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _curved = _curve();
  }

  CurvedAnimation _curve() => CurvedAnimation(
    parent: widget.animation,
    curve: widget.linear ? Curves.linear : AppMotion.glide,
    reverseCurve: widget.linear ? Curves.linear : AppMotion.glide.flipped,
  );

  @override
  void didUpdateWidget(_PushIn old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation || old.linear != widget.linear) {
      _curved.dispose();
      _curved = _curve();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final position = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(_curved);
    return SlideTransition(
      position: position,
      textDirection: Directionality.of(context),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          widget.child,
          PositionedDirectional(
            start: -14,
            width: 14,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _curved,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.centerStart,
                      end: AlignmentDirectional.centerEnd,
                      colors: [
                        Colors.black.withValues(alpha: 0),
                        Colors.black.withValues(alpha: dark ? 0.22 : 0.06),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The page underneath while another is pushed over it: drifts a quarter to the
/// left and dims slightly. Under a page growing out of one of its cards it stays
/// where it is, and that page does the dimming.
class _Recede extends StatefulWidget {
  const _Recede({required this.animation, required this.linear, required this.child, this.route});

  final Animation<double> animation;
  final bool linear;
  final Widget child;
  final PageRoute<dynamic>? route;

  @override
  State<_Recede> createState() => _RecedeState();
}

class _RecedeState extends State<_Recede> {
  late CurvedAnimation _curved;

  /// Only while the page moves: it would otherwise hold a full-screen image for
  /// as long as it is covered.
  final _snapshot = SnapshotController();
  bool _fluid = false;

  @override
  void initState() {
    super.initState();
    _curved = _curve();
    widget.animation.addStatusListener(_syncSnapshot);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fluid = AppMotion.fluid(context);
    _syncSnapshot(widget.animation.status);
  }

  void _syncSnapshot(AnimationStatus status) {
    // CanvasKit renders on the UI thread: no gain there (see SnapshotWidget).
    _snapshot.allowSnapshotting = !kIsWeb && _fluid && status.isAnimating && (widget.route?.allowSnapshotting ?? true);
  }

  CurvedAnimation _curve() => CurvedAnimation(
    parent: widget.animation,
    curve: widget.linear ? Curves.linear : AppMotion.glide,
    reverseCurve: widget.linear ? Curves.linear : AppMotion.glide.flipped,
  );

  @override
  void didUpdateWidget(_Recede old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      old.animation.removeStatusListener(_syncSnapshot);
      widget.animation.addStatusListener(_syncSnapshot);
      _syncSnapshot(widget.animation.status);
    }
    if (old.animation != widget.animation || old.linear != widget.linear) {
      _curved.dispose();
      _curved = _curve();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_syncSnapshot);
    _snapshot.dispose();
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Animation<double> motion = CardOrigin._covered(widget.route) ? kAlwaysDismissedAnimation : _curved;
    return SlideTransition(
      position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.25, 0)).animate(motion),
      textDirection: Directionality.of(context),
      transformHitTests: false,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          SnapshotWidget(controller: _snapshot, mode: SnapshotMode.permissive, autoresize: true, child: widget.child),
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: motion,
                child: ColoredBox(color: Colors.black.withValues(alpha: dark ? 0.32 : 0.10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Drives the route's transition from a back gesture: Android's predictive back
/// events, or a swipe from the leading edge.
class _BackGesture extends StatefulWidget {
  const _BackGesture({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_BackGesture> createState() => _BackGestureState();
}

class _BackGestureState extends State<_BackGesture> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _edge = 20.0;
  static const _minFlingVelocity = 1.0; // screen widths per second

  late final AnimationController _settle = AnimationController(vsync: this);
  HorizontalDragGestureRecognizer? _drag;

  /// Route progress while the in-app swipe owns the route (1 = fully shown).
  double? _progress;

  /// The start we must balance until commit/cancel hands it back to the route.
  NavigatorState? _gestureNavigator;

  PageRoute<dynamic> get _route => widget.route;

  bool get _canGesture => _gestureNavigator == null && _route.isCurrent && _route.popGestureEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settle.addListener(() {
      if (_route.isCurrent) {
        _route.handleUpdateBackGestureProgress(progress: _settle.value);
      }
      // Off screen: the rest of the spring has nothing to show, so don't wait.
      if (_settle.value == 0 && _settle.isAnimating) _settle.stop();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final navigator = _gestureNavigator;
    _gestureNavigator = null;
    _progress = null;
    _drag?.dispose();
    _settle.dispose();
    if (navigator != null) {
      // The route can leave before the swipe or its spring finishes. Updating
      // the surviving routes' IgnorePointer must wait until unmounting ends.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted) navigator.didStopUserGesture();
      });
    }
    super.dispose();
  }

  // ── Android predictive back ────────────────────────────────────────────────

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !_canGesture || _progress != null) {
      return false;
    }
    _gestureNavigator = _route.navigator;
    _route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    _route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (_gestureNavigator == null) return;
    _gestureNavigator = null;
    _route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (_gestureNavigator == null) return;
    _gestureNavigator = null;
    _route.handleCommitBackGesture();
  }

  // ── In-app edge swipe ──────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    if (!_canGesture || _settle.isAnimating) return;
    (_drag ??= HorizontalDragGestureRecognizer(debugOwner: this)
          ..onStart = _onStart
          ..onUpdate = _onUpdate
          ..onEnd = _onEnd
          ..onCancel = _onCancel)
        .addPointer(event);
  }

  double get _width => context.size?.width ?? MediaQuery.sizeOf(context).width;

  double _sign() => Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  void _onStart(DragStartDetails details) {
    if (!_canGesture) return;
    _progress = 1;
    _gestureNavigator = _route.navigator;
    _route.handleStartBackGesture(progress: 1);
  }

  void _onUpdate(DragUpdateDetails details) {
    final progress = _progress;
    if (progress == null) return;
    final next = (progress - _sign() * details.primaryDelta! / _width).clamp(0.0, 1.0);
    _progress = next;
    _route.handleUpdateBackGestureProgress(progress: next);
  }

  void _onEnd(DragEndDetails details) {
    final progress = _progress;
    if (progress == null) return;
    final velocity = _sign() * details.velocity.pixelsPerSecond.dx / _width;
    final leave = velocity.abs() >= _minFlingVelocity ? velocity > 0 : progress < 0.5;
    _finish(from: progress, leave: leave, velocity: -velocity);
  }

  void _onCancel() {
    final progress = _progress;
    if (progress != null) _finish(from: progress, leave: false);
  }

  /// [velocity]: route values a second.
  void _finish({required double from, required bool leave, double velocity = 0}) {
    final target = leave ? 0.0 : 1.0;
    _settle.value = from;
    void done() {
      _progress = null;
      if (!mounted) return;
      if (leave) {
        handleCommitBackGesture();
      } else {
        handleCancelBackGesture();
      }
    }

    if (AppMotion.reduced(context) || from == target) {
      if (_route.isCurrent) {
        _route.handleUpdateBackGestureProgress(progress: target);
      }
      done();
      return;
    }
    _settle
        .animateWith(AppMotion.settle(AppMotion.sheetSpring, from, target, velocity, landing: !leave))
        .whenCompleteOrCancel(done);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context);
    final edge = _edge + (Directionality.of(context) == TextDirection.rtl ? inset.right : inset.left);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          width: edge,
          top: 0,
          bottom: 0,
          child: Listener(onPointerDown: _onPointerDown, behavior: HitTestBehavior.translucent),
        ),
      ],
    );
  }
}
