// The chat page's pet (docs/design/pets.md §2). [PetStage] lays a layer over
// the page (the list's layout untouched); the pet stands on the top edge of the
// topmost capsule above the composer ([PetPerch]), following it through a layer
// link in the same frame, hops when that changes, walks about now and then,
// sleeps when left alone, reacts to taps, drags and long presses, and raises a
// bubble when a turn ends or something waits in another conversation. Only its
// body takes touches.
//
// Interaction: tap left / right, a quick run of taps tickles, drag, sleep
// after 60 s idle. The overlay twin lives in Kotlin.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pets/pet_mood.dart';
import '../../pets/pet_overlay_bridge.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_sheets.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../state/ui_mode_state.dart';
import '../chat/widgets/approval_card.dart';
import '../chat/widgets/question_card.dart';
import '../common/discard_guard.dart';
import '../theme/theme.dart';
import 'pet_bubble.dart';
import 'pet_menu.dart';
import 'pet_perch.dart';
import 'pet_sprite.dart';

/// Geometry and timing shared with the tests.
abstract final class PetMetrics {
  /// The body keeps this far from either end of its perch.
  static const inset = 16.0;

  /// Areas the pet keeps out of grow by this on each side.
  static const avoidGap = 8.0;

  /// The bubble keeps this far from the page's edges.
  static const bubbleMargin = 16.0;

  /// The highest point of a hop above the straight line.
  static const hopHeight = 18.0;
  static const hop = Duration(milliseconds: 380);

  /// Walking speed along the perch, logical px per second.
  static const walkSpeed = 28.0;

  /// How far a walk goes, as a share of the perch.
  static const walkMin = 0.08;
  static const walkMax = 0.2;

  /// Between walks: 45 s – 5 min, about 2 min on average.
  static const roamEvery = PetEvery();

  /// The lift while held.
  static const dragLift = 10.0;

  /// A drag starts after this much movement.
  static const dragSlop = 6.0;

  /// A tickle: this many taps within [tickleWithin].
  static const tickleTaps = 3;
  static const tickleWithin = Duration(milliseconds: 1100);

  /// Tapping on through a tickle into this many taps annoys it, when the pack
  /// has an `annoyed` reaction.
  static const annoyedTaps = 6;
}

/// The pet over the chat page. Wrap the page body; capsules inside report
/// with [PetPerch], panels that should send it away with [PetCover], areas
/// it keeps out of with [PetAvoid].
class PetStage extends ConsumerStatefulWidget {
  const PetStage({super.key, this.sessionId, this.aside = false, required this.child});

  /// The conversation the page shows (null: a new chat). The pet reads what
  /// it is doing from here.
  final String? sessionId;

  /// A phone on its side is typing: the bars fold away, the pet stays on
  /// the composer.
  final bool aside;
  final Widget child;

  @override
  ConsumerState<PetStage> createState() => _PetStageState();
}

class _PetStageState extends ConsumerState<PetStage> {
  final _registry = PerchRegistry();
  final _content = GlobalKey();
  final _scrolling = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _registry.dispose();
    _scrolling.dispose();
    super.dispose();
  }

  /// Go and look: the conversation on screen scrolls to what waits (or its
  /// newest reply); another conversation opens.
  Future<void> _reveal(PetTarget target, PetBubbleKind kind) async {
    final here = ref.read(activeHostProvider) == target.host && ref.read(currentSessionProvider) == target.sessionId;
    if (here) {
      _scrollTo(kind);
      return;
    }
    if (!await DiscardGuard.confirmLeave(context) || !mounted) return;
    ref.read(activeHostProvider.notifier).select(target.host);
    ref.read(currentSessionProvider.notifier).select(target.sessionId);
  }

  /// Brings the waiting card (or the latest reply) into view.
  void _scrollTo(PetBubbleKind kind) {
    final root = _content.currentContext;
    if (root == null) return;
    final duration = AppMotion.of(context, AppMotion.emphasized);
    BuildContext? card;
    if (kind.waits) {
      void visit(Element e) {
        if (card != null) return;
        final w = e.widget;
        if (w is ApprovalCard || w is QuestionCard) {
          card = e;
          return;
        }
        e.visitChildElements(visit);
      }

      root.visitChildElements(visit);
    }
    if (card case final card?) {
      unawaited(Scrollable.ensureVisible(card, alignment: 1, duration: duration, curve: AppMotion.std));
      return;
    }
    // The newest content: the bottom of the conversation's list.
    ScrollableState? list;
    var tallest = 0.0;
    void find(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final box = e.renderObject;
        if (s.widget.axis == Axis.vertical && box is RenderBox && box.hasSize && box.size.height > tallest) {
          tallest = box.size.height;
          list = s;
        }
      }
      e.visitChildElements(find);
    }

    root.visitChildElements(find);
    final position = list?.position;
    if (position == null || !position.hasContentDimensions) return;
    if (duration == Duration.zero) {
      position.jumpTo(position.maxScrollExtent);
    } else {
      unawaited(position.animateTo(position.maxScrollExtent, duration: duration, curve: AppMotion.std));
    }
  }

  @override
  Widget build(BuildContext context) {
    // The overlay outside the app hears every state while the chat lives.
    ref.listen<void>(petOverlayBridgeProvider, (_, _) {});
    return PetPerchScope(
      registry: _registry,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => ref.read(petInteractionProvider.notifier).touch(),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification) _scrolling.value = true;
            if (n is ScrollEndNotification) _scrolling.value = false;
            return false;
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _FocusReporter(
                sessionId: widget.sessionId,
                child: KeyedSubtree(key: _content, child: widget.child),
              ),
              Positioned.fill(
                child: PetLayer(registry: _registry, aside: widget.aside, scrolling: _scrolling, onReveal: _reveal),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the page's conversation is doing, for [_FocusReporter] (null: a new chat).
final _pageFocusProvider = Provider.autoDispose.family<PetFocus?, String?>((ref, id) {
  if (id == null) return null;
  final host = ref.watch(activeHostProvider);
  final compacting = ref.watch(petCompactingProvider(id));
  return ref.watch(chatProvider(id).select((s) => petFocusOf(host, id, s, compacting: compacting)));
});

/// Tells the pet what the conversation on screen is doing (its activity,
/// compaction, an open card), from the page's own chat state.
///
/// Through a subscription, not this widget's builds: with the app in the
/// background there are no frames, and the pet out there still has to see the
/// turn end. A frozen 「running」 would keep it working and swallow the turn's
/// 做完了 (a new round, as far as it could tell), while the notification stays
/// silent for the pet to say it (`ResultSilence`).
class _FocusReporter extends ConsumerStatefulWidget {
  const _FocusReporter({required this.sessionId, required this.child});

  final String? sessionId;
  final Widget child;

  @override
  ConsumerState<_FocusReporter> createState() => _FocusReporterState();
}

class _FocusReporterState extends ConsumerState<_FocusReporter> {
  late final PetFocusController _focus;
  ProviderSubscription<PetFocus?>? _sub;

  @override
  void initState() {
    super.initState();
    _focus = ref.read(petFocusProvider.notifier);
    _follow();
  }

  @override
  void didUpdateWidget(_FocusReporter old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) _follow();
  }

  void _follow() {
    _sub?.close();
    _sub = ref.listenManual(_pageFocusProvider(widget.sessionId), (_, next) => _report(next), fireImmediately: true);
  }

  void _report(PetFocus? focus) {
    // Not while building (the first report comes from initState): right after.
    scheduleMicrotask(() {
      if (mounted) _focus.report(focus);
    });
  }

  @override
  void dispose() {
    _sub?.close();
    final focus = _focus;
    // The page is gone: nothing on screen.
    scheduleMicrotask(() => focus.report(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The pet itself, over the whole stage. Hit tests only on its body and its
/// bubble.
class PetLayer extends ConsumerStatefulWidget {
  const PetLayer({super.key, required this.registry, this.aside = false, this.scrolling, this.onReveal});

  final PerchRegistry registry;
  final bool aside;

  /// The page's list is scrolling (no walks then).
  final ValueListenable<bool>? scrolling;

  /// Go and look at [target] (a tapped bubble, a tap while it rings).
  final void Function(PetTarget target, PetBubbleKind kind)? onReveal;

  /// Dice for walks, idle rotation and celebrations (tests seed it).
  static math.Random random = math.Random();

  @override
  ConsumerState<PetLayer> createState() => PetLayerState();
}

class PetLayerState extends ConsumerState<PetLayer> with TickerProviderStateMixin {
  // ── Where it stands ──
  PerchSpot? _spot;
  Size _stage = Size.zero;
  Offset _stageGlobal = Offset.zero;
  List<Rect> _avoid = const [];
  bool _covered = false;

  /// Its foot point at the last check, in stage coordinates (a hop starts there).
  Offset? _lastFoot;
  bool _polling = false;

  late final AnimationController _hop = AnimationController(vsync: this, value: 1, duration: PetMetrics.hop)
    ..addListener(_tick);
  Offset _hopFrom = Offset.zero;

  // ── Walking ──
  late final AnimationController _walk = AnimationController(vsync: this)
    ..addListener(_tick)
    ..addStatusListener(_walked);
  double _walkFrom = 0;
  double _walkTo = 0;
  double? _roamed;
  bool _walking = false;
  bool _walkRight = false;

  // ── Held ──
  bool _dragging = false;
  double _dragFoot = 0;
  double _lift = 0;
  late final AnimationController _drop = AnimationController(vsync: this, value: 1)..addListener(_tick);
  double _dropFrom = 0;

  // ── One-offs ──
  PetAnimation? _reaction;
  Timer? _reactionTimer;
  PetAnimation? _variant;
  Timer? _variantTimer;
  Timer? _idleTimer;
  Timer? _roamTimer;
  Timer? _unhideTimer;
  final List<DateTime> _taps = [];
  bool _ready = false;
  bool _bodyFullyHidden = true;
  PetStateName? _lastState;
  PetPack? _statePack;
  PetPack? _pinned;

  /// Where the foot stands now, in stage coordinates (tests).
  @visibleForTesting
  Offset? get foot => _spot == null ? null : _spot!.rect.topLeft + Offset(_footX(_spot!), 0);

  /// The perch it stands on (tests).
  @visibleForTesting
  PerchKind? get perch => _spot?.kind;

  @visibleForTesting
  bool get hopping => _hop.isAnimating;

  @visibleForTesting
  bool get walking => _walking;

  /// The animation playing now (tests).
  @visibleForTesting
  PetAnimation? get playing => _anim;
  PetAnimation? _anim;

  /// In the tree (not parked by a moving global key or a closing route).
  bool _active = true;

  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_schedulePoll);
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _schedulePoll();
  }

  @override
  void didUpdateWidget(PetLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry.removeListener(_schedulePoll);
      widget.registry.addListener(_schedulePoll);
    }
    if (oldWidget.aside != widget.aside) _schedulePoll();
  }

  @override
  void dispose() {
    widget.registry.removeListener(_schedulePoll);
    widget.registry.occupied.value = null;
    _reactionTimer?.cancel();
    _variantTimer?.cancel();
    _idleTimer?.cancel();
    _roamTimer?.cancel();
    _unhideTimer?.cancel();
    _hop.dispose();
    _walk.dispose();
    _drop.dispose();
    super.dispose();
  }

  void _tick() => setState(() {});

  DateTime get _now => ref.read(petClockProvider)();

  // ── Geometry ───────────────────────────────────────────────────────────────

  void _schedulePoll() {
    if (_polling || !mounted) return;
    _polling = true;
    SchedulerBinding.instance.addPostFrameCallback(_poll);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// After every frame that happens: which perch is topmost, how wide it
  /// is, what to keep out of. Changes rebuild; the vertical position needs
  /// none (the layer link carries it, without a frame of lag).
  void _poll(Duration _) {
    _polling = false;
    if (!mounted || !_active) return;
    final stage = context.findRenderObject();
    if (stage is! RenderBox || !stage.hasSize || !stage.attached) return;
    var spots = widget.registry.spots(stage);
    if (widget.aside) {
      spots = [
        for (final s in spots)
          if (s.kind == PerchKind.composer) s,
      ];
    }
    PerchSpot? top;
    for (final s in spots) {
      if (top == null || s.rect.top < top.rect.top - 0.5) top = s;
    }
    final avoid = [for (final r in widget.registry.avoids(stage)) r.inflate(PetMetrics.avoidGap)];
    final covered = widget.registry.covered;
    final global = stage.localToGlobal(Offset.zero);
    final old = _spot;
    final moved = top?.perch != old?.perch;
    final changed =
        moved ||
        (top != null &&
            old != null &&
            ((top.rect.width - old.rect.width).abs() > 0.25 || (top.rect.left - old.rect.left).abs() > 0.25)) ||
        stage.size != _stage ||
        (global - _stageGlobal).distance > 0.01 ||
        covered != _covered ||
        !_sameRects(avoid, _avoid);
    if (moved && top != null && old != null && _lastFoot != null) {
      // Hop from where it stood to the new perch.
      _spot = top;
      _hopFrom = _lastFoot! - (top.rect.topLeft + Offset(_footX(top), 0));
      if (AppMotion.reduced(context) || _hopFrom.distance < 1 || !_visible) {
        _hop.value = 1;
      } else {
        _hop.duration = PetMetrics.hop;
        unawaited(_hop.forward(from: 0));
      }
    }
    if (changed) {
      setState(() {
        _spot = top;
        _stage = stage.size;
        _stageGlobal = global;
        _avoid = avoid;
        _covered = covered;
      });
    }
    final spot = _spot;
    _lastFoot = spot == null ? null : spot.rect.topLeft + Offset(_footX(spot), 0);
    final shown = _visible && _ready;
    // Perches lead their links once there is a pet to draw (and keep leading
    // while it fades out when covered or hidden).
    final leading = _ready && _pack != null;
    if (widget.registry.leading.value != leading) widget.registry.leading.value = leading;
    final occupied = shown ? spot?.kind : null;
    if (widget.registry.occupied.value != occupied) widget.registry.occupied.value = occupied;
    ref.read(petLayerShownProvider.notifier).set(shown);
    final pack = _pack;
    ref
        .read(petHeadroomProvider.notifier)
        .set(shown && pack != null ? (pack.baseline - pack.contentBox.top) * _scale : 0);
    // Keep watching while frames come (keyboard, strips rising).
    _polling = true;
    SchedulerBinding.instance.addPostFrameCallback(_poll);
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i].topLeft - b[i].topLeft).distance > 0.25 || a[i].size != b[i].size) return false;
    }
    return true;
  }

  PetPack? get _pack => ref.read(currentPetPackProvider);

  double get _dpr => MediaQuery.devicePixelRatioOf(context);

  double get _scale {
    final pack = _pack;
    if (pack == null) return 1;
    final prefs = ref.read(petPrefsProvider);
    return petScale(pack, prefs.size, _dpr, customHeight: prefs.customHeight);
  }

  /// Body extents left and right of the foot point, logical px.
  (double, double) _extents(PetPack pack, double s) =>
      ((pack.anchorX - pack.contentBox.left) * s, (pack.contentBox.right - pack.anchorX) * s);

  /// The range the foot may take along [spot] (its own coordinates).
  (double, double) _range(PerchSpot spot) {
    final pack = _pack;
    final w = spot.rect.width;
    if (pack == null) return (w / 2, w / 2);
    final (left, right) = _extents(pack, _scale);
    final lo = PetMetrics.inset + left;
    final hi = w - PetMetrics.inset - right;
    if (hi <= lo) return (w / 2, w / 2);
    return (lo, hi);
  }

  /// Steps [x] out of the areas it keeps out of, to the nearer side.
  double _clear(PerchSpot spot, double x) {
    final pack = _pack;
    final (lo, hi) = _range(spot);
    if (pack == null) return x.clamp(lo, hi);
    final s = _scale;
    final (left, right) = _extents(pack, s);
    final height = (pack.baseline - pack.contentBox.top) * s;
    for (final area in _avoid) {
      final r = area.shift(-spot.rect.topLeft);
      // Only what sits beside the body: above the perch, within its height.
      if (r.bottom < -height || r.top > 0) continue;
      if (x + right <= r.left || x - left >= r.right) continue;
      final before = r.left - right;
      final after = r.right + left;
      final fitsBefore = before >= lo;
      final fitsAfter = after <= hi;
      if (fitsBefore && (!fitsAfter || x - before <= after - x)) {
        x = before;
      } else if (fitsAfter) {
        x = after;
      }
    }
    return x.clamp(lo, hi);
  }

  /// Where the foot stands along [spot].
  double _footX(PerchSpot spot) {
    final (lo, hi) = _range(spot);
    if (_dragging) return _dragFoot.clamp(lo, hi);
    final prefs = ref.read(petPrefsProvider);
    final share = _walking ? _walkFrom + (_walkTo - _walkFrom) * _walk.value : (_roamed ?? prefs.position);
    return _clear(spot, (share * spot.rect.width).clamp(lo, hi));
  }

  bool get _visible {
    final prefs = ref.read(petPrefsProvider);
    return _pack != null &&
        prefs.loaded &&
        prefs.enabled &&
        !prefs.hiddenAt(_now) &&
        !ref.read(uiModeProvider).web &&
        _spot != null &&
        !_covered;
  }

  PetScope get _scope => _spot?.kind == PerchKind.strip ? PetScope.focus : PetScope.global;

  // ── Play ───────────────────────────────────────────────────────────────────

  void _onState(PetStateName next) {
    if (!mounted || !_active) return;
    final pack = _pack;
    if (pack == null) return;
    _variantTimer?.cancel();
    _variant = null;
    if (next != PetStateName.idle) {
      _idleTimer?.cancel();
      _roamTimer?.cancel();
      if (_walking) {
        _roamed = _walkFrom + (_walkTo - _walkFrom) * _walk.value;
        _walk.stop();
        _walking = false;
      }
    }
    // Now and then a state plays one of its extras: a celebration's confetti,
    // ultrathink while thinking, one of the working-day scenes.
    final bonus = next == PetStateName.idle ? null : pack.bonusOf(next);
    if (bonus != null && PetLayer.random.nextDouble() < bonus.chance) {
      _startVariant(pack.animations[bonus.anims[PetLayer.random.nextInt(bonus.anims.length)]]);
    }
    // Touching a sleeper only wakes it.
    if (next == PetStateName.sleeping || next == PetStateName.waking) _clearReaction();
    if (next == PetStateName.idle) _armIdle();
    setState(() {});
  }

  /// Plays [anim] over the state's own animation for one pass, then back.
  void _startVariant(PetAnimation? anim) {
    if (anim == null) return;
    final pack = _pack;
    _variant = anim;
    _variantTimer?.cancel();
    _variantTimer = Timer(Duration(milliseconds: pack?.playOf(anim) ?? anim.durationMs), () {
      if (mounted) setState(() => _variant = null);
    });
  }

  bool get _reduced => AppMotion.reduced(context);

  /// Idle: now and then an idle extra, now and then a walk.
  void _armIdle() {
    _idleTimer?.cancel();
    _roamTimer?.cancel();
    final pack = _pack;
    if (_reduced || pack == null) return;
    _idleTimer = Timer(pack.idleEvery.draw(PetLayer.random.nextDouble()), _idleTick);
    _armRoam();
  }

  void _armRoam() {
    _roamTimer?.cancel();
    _roamTimer = Timer(PetMetrics.roamEvery.draw(PetLayer.random.nextDouble()), _roam);
  }

  /// Plays one idle extra (weighted pick, for its ms), then back to idle.
  void _idleTick() {
    if (!mounted || !_active) return;
    final pack = _pack;
    if (pack == null || _lastState != PetStateName.idle) return;
    final pool = pack.idles;
    if (pool.isEmpty) return;
    if (_walking || _reaction != null || _dragging || !_visible) {
      _idleTimer = Timer(pack.idleEvery.draw(PetLayer.random.nextDouble()), _idleTick);
      return;
    }
    final total = pool.fold<double>(0, (sum, e) => sum + e.weight);
    var pick = PetLayer.random.nextDouble() * total;
    var chosen = pool.last;
    for (final entry in pool) {
      pick -= entry.weight;
      if (pick <= 0) {
        chosen = entry;
        break;
      }
    }
    final anim = pack.animations[chosen.anim];
    setState(() => _variant = anim);
    final ms = chosen.ms > 0 ? chosen.ms : (anim?.durationMs ?? 4800);
    _idleTimer = Timer(Duration(milliseconds: ms), () {
      if (!mounted) return;
      setState(() => _variant = null);
      _idleTimer = Timer(pack.idleEvery.draw(PetLayer.random.nextDouble()), _idleTick);
    });
  }

  bool get _typing {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Walks a little way along the perch (and back home the next time).
  void _roam() {
    if (!mounted || !_active) return;
    final spot = _spot;
    final pack = _pack;
    if (spot == null || pack == null || _lastState != PetStateName.idle) return;
    final bubbleUp = ref.read(petScopedStateProvider(_scope)).bubble != null;
    if (_dragging || _reaction != null || _typing || (widget.scrolling?.value ?? false) || bubbleUp || !_visible) {
      _armRoam();
      return;
    }
    final home = ref.read(petPrefsProvider).position;
    final from = _roamed ?? home;
    final r = PetLayer.random;
    final to = _roamed != null
        ? home
        : (from +
                  (r.nextBool() ? 1 : -1) *
                      (PetMetrics.walkMin + r.nextDouble() * (PetMetrics.walkMax - PetMetrics.walkMin)))
              .clamp(0.0, 1.0);
    // Not into an area it keeps out of, not past the perch's ends.
    final (lo, hi) = _range(spot);
    final endX = _clear(spot, (to * spot.rect.width).clamp(lo, hi));
    final startX = _footX(spot);
    final distance = (endX - startX).abs();
    if (distance < 4) {
      _armRoam();
      return;
    }
    setState(() {
      _walkFrom = startX / spot.rect.width;
      _walkTo = endX / spot.rect.width;
      _walkRight = endX > startX;
      _walking = true;
      _variant = null;
    });
    _walk.duration = Duration(milliseconds: (distance / PetMetrics.walkSpeed * 1000).round());
    unawaited(_walk.forward(from: 0));
  }

  void _walked(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_walking) return;
    final home = ref.read(petPrefsProvider).position;
    setState(() {
      _walking = false;
      _roamed = (_walkTo - home).abs() < 0.002 ? null : _walkTo;
    });
    if (_lastState == PetStateName.idle) _armRoam();
  }

  void _play(PetAnimation? anim) {
    final pack = _pack;
    if (anim == null || pack == null) return;
    _reactionTimer?.cancel();
    setState(() {
      _reaction = anim;
      _variant = null;
    });
    _reactionTimer = Timer(Duration(milliseconds: pack.playOf(anim)), () {
      if (mounted) setState(() => _reaction = null);
    });
  }

  void _clearReaction() {
    _reactionTimer?.cancel();
    _reaction = null;
  }

  // ── Touch ──────────────────────────────────────────────────────────────────

  void _onTapUp(TapUpDetails details) {
    final pack = _pack;
    if (pack == null) return;
    ref.read(petInteractionProvider.notifier).touch();
    final pet = ref.read(petScopedStateProvider(_scope));
    // Asleep: the touch wakes it, no poke on top of the yawn.
    if (pet.state == PetStateName.sleeping || pet.state == PetStateName.waking) return;
    // Ringing: a tap goes to see what waits, like the bubble.
    if (pet.state == PetStateName.notification && pet.target != null) {
      HapticFeedback.selectionClick();
      final question = ref.read(petPendingProvider).where((p) => p.target == pet.target).firstOrNull?.question ?? false;
      widget.onReveal?.call(pet.target!, question ? PetBubbleKind.question : PetBubbleKind.approval);
      return;
    }
    final now = _now;
    _taps
      ..removeWhere((t) => now.difference(t) > PetMetrics.tickleWithin)
      ..add(now);
    if (_taps.length >= PetMetrics.annoyedTaps && pack.reactions.containsKey('annoyed')) {
      // Tapped through a whole tickle and on: that is enough.
      _taps.clear();
      HapticFeedback.heavyImpact();
      _play(pack.reactionOutOf('annoyed', PetLayer.random));
      return;
    }
    if (_taps.length >= PetMetrics.tickleTaps) {
      // Tapping on keeps the tickle going.
      HapticFeedback.lightImpact();
      _play(pack.reactionOutOf('tickle', PetLayer.random));
      return;
    }
    final tickling = _reaction;
    if (tickling != null && (pack.reactions['tickle']?.contains(tickling.name) ?? false)) {
      _play(pack.reactionOutOf('tickle', PetLayer.random));
      return;
    }
    HapticFeedback.selectionClick();
    final left = details.localPosition.dx < pack.anchorX * _scale;
    _play(pack.reactionOutOf(left ? 'tapLeft' : 'tapRight', PetLayer.random));
  }

  void _onDragStart(DragStartDetails details) {
    final spot = _spot;
    if (spot == null) return;
    HapticFeedback.selectionClick();
    ref.read(petInteractionProvider.notifier).touch();
    _roamTimer?.cancel();
    _idleTimer?.cancel();
    _walk.stop();
    setState(() {
      _dragFoot = _footX(spot);
      _dragging = true;
      _walking = false;
      _roamed = null;
      _variant = null;
      _clearReaction();
      _lift = -PetMetrics.dragLift;
      _drop.value = 1;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final spot = _spot;
    if (spot == null || !_dragging) return;
    final (lo, hi) = _range(spot);
    setState(() {
      _dragFoot = (_dragFoot + details.delta.dx).clamp(lo, hi);
      // Held up a little; pulling up lifts it further, with some give.
      _lift = (_lift + details.delta.dy * 0.4).clamp(-PetMetrics.dragLift * 4, -PetMetrics.dragLift * 0.5);
    });
  }

  void _onDragEnd([DragEndDetails? _]) {
    final spot = _spot;
    if (!_dragging || spot == null) return;
    // Let go: it settles on the perch, out of any area it keeps out of.
    final x = _clear(spot, _dragFoot);
    setState(() {
      _dragging = false;
      _dropFrom = _lift;
      _lift = 0;
    });
    unawaited(ref.read(petPrefsProvider.notifier).setPosition(x / spot.rect.width));
    final drop = AppMotion.of(context, AppMotion.standard);
    if (drop == Duration.zero) {
      _drop.value = 1;
    } else {
      _drop.duration = drop;
      unawaited(_drop.forward(from: 0));
    }
    if (_lastState == PetStateName.idle) _armIdle();
  }

  Future<void> _menu() async {
    final pack = _pack;
    if (pack == null) return;
    ref.read(petInteractionProvider.notifier).touch();
    await showPetMenu(context, pack: pack);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  /// [origin] moved so the canvas's top-left lands on a device pixel.
  Offset _snap(PerchSpot spot, Offset origin) {
    final dpr = _dpr;
    final global = _stageGlobal + spot.rect.topLeft + origin;
    final snapped = Offset((global.dx * dpr).roundToDouble() / dpr, (global.dy * dpr).roundToDouble() / dpr);
    return origin + (snapped - global);
  }

  @override
  Widget build(BuildContext context) {
    final pack = ref.watch(currentPetPackProvider);
    final prefs = ref.watch(petPrefsProvider);
    final pet = ref.watch(petScopedStateProvider(_scope));
    ref.watch(uiModeProvider.select((m) => m.web));
    // A new state (or the pack just arrived): arm what goes with it.
    if (pet.state != _lastState || !identical(pack, _statePack)) {
      _lastState = pet.state;
      _statePack = pack;
      final next = pet.state;
      WidgetsBinding.instance.addPostFrameCallback((_) => _onState(next));
    }
    if (pack != null && !identical(pack, _pinned)) {
      _pinned = pack;
      PetSheets.instance.pin(pack, pack.animFor(PetStateName.idle));
      _ready = false;
    }
    _armUnhide(prefs);
    _schedulePoll();

    final spot = _spot;
    if (pack == null || spot == null) {
      _bodyFullyHidden = true;
      return const SizedBox.expand();
    }
    final s = _scale;
    final visible = _visible;
    final canvas = Size(pack.canvas.width * s, pack.canvas.height * s);
    final footX = _footX(spot);

    // Hop: from the old foot point to the new along an arc.
    final t = _hop.value;
    final eased = Curves.easeInOut.transform(t);
    final hop = _hopFrom * (1 - eased) + Offset(0, t < 1 ? -PetMetrics.hopHeight * 4 * t * (1 - t) : 0);
    final lift = _dragging ? _lift : _dropFrom * (1 - Curves.easeIn.transform(_drop.value));
    var origin = Offset(footX - pack.anchorX * s, -pack.baseline * s) + hop + Offset(0, lift);
    if (!_dragging && !_hop.isAnimating && !_walking && !_drop.isAnimating) origin = _snap(spot, origin);

    final anim = _dragging
        ? (pack.reaction('drag') ?? pack.animFor(pet.state, tier: pet.tier))
        : _reaction ?? (_walking ? pack.roam : null) ?? _variant ?? pack.animFor(pet.state, tier: pet.tier);
    _anim = anim;
    final flip = _walking && pack.mirrorWalking(right: _walkRight);

    // Only the body takes touches: the animation's hit box, never below the
    // foot line (the capsule under it keeps its taps).
    final box = pack.hitBoxFor(anim);
    final mirrored = flip
        ? Rect.fromLTRB(2 * pack.anchorX - box.right, box.top, 2 * pack.anchorX - box.left, box.bottom)
        : box;
    final hitRect = Rect.fromLTRB(
      mirrored.left * s,
      mirrored.top * s,
      mirrored.right * s,
      math.min(mirrored.bottom, pack.baseline) * s,
    );
    final shown = visible && _ready;
    final fadeDuration = AppMotion.of(context, AppMotion.standard);
    // Resume before the first visible fade-in frame; a reversed fade keeps running.
    if (shown) _bodyFullyHidden = false;
    final pauseSprite = !visible && (_bodyFullyHidden || fadeDuration == Duration.zero);

    final body = CompositedTransformFollower(
      link: spot.link,
      showWhenUnlinked: false,
      offset: origin,
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: fadeDuration,
          curve: AppMotion.std,
          onEnd: () {
            // A show request may have arrived since the fade began.
            if (shown) return;
            // Zero-duration completion may happen while widgets are updating.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || (_visible && _ready) || _bodyFullyHidden) return;
              setState(() => _bodyFullyHidden = true);
            });
          },
          child: MediaQuery(
            // A drag starts after 6dp (the default slop is far more).
            data: MediaQuery.of(context)
                .copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: PetMetrics.dragSlop / 2)),
            child: GestureDetector(
              // The pet follows the finger from where it went down.
              dragStartBehavior: DragStartBehavior.down,
              onTapUp: _onTapUp,
              onLongPress: _menu,
              onPanStart: _onDragStart,
              onPanUpdate: _onDragUpdate,
              onPanEnd: _onDragEnd,
              onPanCancel: _onDragEnd,
              child: _HitRect(
                rect: hitRect,
                child: RepaintBoundary(
                  child: SizedBox.fromSize(
                    key: const ValueKey('pet-body'),
                    size: canvas,
                    child: PetSprite(
                      pack: pack,
                      anim: anim,
                      scale: s,
                      flip: flip,
                      paused: pauseSprite,
                      onShown: () {
                        if (_ready) return;
                        // Shown during a frame: ready right after it.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && !_ready) setState(() => _ready = true);
                        });
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final bubble = shown && !_dragging ? pet.bubble : null;
    const room = 160.0;
    // Over the head, and over what the state holds up (Deepy's 「!」, a
    // thought cloud): the higher of the body and the state's own art.
    final stateAnim = _variant ?? pack.animFor(pet.state, tier: pet.tier);
    final headArt = math.min(pack.contentBox.top, stateAnim.box.top) * s;
    final bubbleBox = Size(math.max(0, _stage.width - 2 * PetMetrics.bubbleMargin), room);
    final centre = spot.rect.left + origin.dx + pack.anchorX * s - PetMetrics.bubbleMargin;
    final speech = TweenAnimationBuilder<double>(
      tween: Tween(end: headArt),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      builder: (context, head, child) => CompositedTransformFollower(
        link: spot.link,
        showWhenUnlinked: false,
        offset: Offset(PetMetrics.bubbleMargin - spot.rect.left, origin.dy + head - PetBubbleMetrics.lift - room),
        child: child,
      ),
      child: SizedBox.fromSize(
        size: bubbleBox,
        child: CustomSingleChildLayout(
          delegate: _BubbleLayout(centre),
          child: PetBubbleSwitcher(
            child: bubble == null
                ? null
                : _Swipe(
                    key: ValueKey(bubble.id),
                    onSwipeUp: () => ref.read(petMoodProvider(PetScope.global).notifier).dismissBubble(bubble.id),
                    child: PetBubbleView(
                      bubble: bubble,
                      onTap: () {
                        ref.read(petMoodProvider(PetScope.global).notifier).dismissBubble(bubble.id);
                        widget.onReveal?.call(bubble.target, bubble.kind);
                      },
                    ),
                  ),
          ),
        ),
      ),
    );

    return Stack(clipBehavior: Clip.none, children: [body, speech]);
  }

  void _armUnhide(PetPrefs prefs) {
    _unhideTimer?.cancel();
    final until = prefs.hiddenUntil;
    if (until == null) return;
    final wait = until.difference(_now);
    if (wait.isNegative) return;
    _unhideTimer = Timer(wait + const Duration(milliseconds: 10), () {
      if (mounted) setState(() {});
    });
  }
}

/// Places the bubble over the pet's head, kept inside the page.
class _BubbleLayout extends SingleChildLayoutDelegate {
  _BubbleLayout(this.centre);

  /// The pet's centre, in the box's coordinates.
  final double centre;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (centre - child.width / 2).clamp(0.0, math.max(0.0, size.width - child.width));
    return Offset(x.roundToDouble(), size.height - child.height);
  }

  @override
  bool shouldRelayout(_BubbleLayout old) => old.centre != centre;
}

/// An upward flick sends the bubble away without opening anything.
class _Swipe extends StatelessWidget {
  const _Swipe({super.key, required this.onSwipeUp, required this.child});

  final VoidCallback onSwipeUp;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onVerticalDragEnd: (d) {
      if ((d.primaryVelocity ?? 0) < -150) onSwipeUp();
    },
    child: child,
  );
}

/// Takes touches only inside [rect].
class _HitRect extends SingleChildRenderObjectWidget {
  const _HitRect({required this.rect, super.child});

  final Rect rect;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHitRect(rect);

  @override
  void updateRenderObject(BuildContext context, _RenderHitRect renderObject) => renderObject.rect = rect;
}

class _RenderHitRect extends RenderProxyBox {
  _RenderHitRect(this.rect);

  Rect rect;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!rect.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
