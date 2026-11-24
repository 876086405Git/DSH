// Where the pet can stand. The capsules above the composer (the composer
// itself, the run strip, the todo / goal bars, the banners, the plugins' status
// line and capsule row) wrap themselves in [PetPerch]; the chat page's pet
// layer stands on the top edge of the topmost one it can see. Each perch is a
// layer link leader, so the pet follows its capsule in the same frame
// (keyboard, a growing composer, the strip rising) without a frame of lag.
//
// Outside a [PetPerchScope] (Bot chats, settings previews) the wrappers are
// plain pass-throughs.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// What a perch is.
enum PerchKind {
  /// The composer (or the read-only bar in its place): the fallback.
  composer,

  /// The run strip (思考条).
  strip,

  /// The todo and goal bars.
  dock,

  /// The banners and the auto-approve pill above them.
  banner,

  /// The plugins' status line and the capsule row (ui.json's and plugins'):
  /// the foot on the row's top edge, the capsules themselves stay free.
  plugin,
}

/// Where a perch is, in the stage's coordinates.
@immutable
class PerchSpot {
  const PerchSpot(this.perch, this.rect);

  final PetPerchState perch;
  final Rect rect;

  PerchKind get kind => perch.widget.kind;
  LayerLink get link => perch.link;
}

/// The perches, avoid areas and covers under one stage.
class PerchRegistry extends ChangeNotifier {
  final List<PetPerchState> _perches = [];
  final List<PetAvoidState> _avoids = [];
  final List<PetCoverState> _covers = [];

  /// The kind of perch the pet stands on now (null: none, or no pet). The
  /// run strip hides its whale tail while the pet stands on it.
  final occupied = ValueNotifier<PerchKind?>(null);

  /// A pet is drawn: perches lead their layer links. Without one they add
  /// no layer at all, so pages without a pet composite unchanged.
  final leading = ValueNotifier<bool>(false);

  void _add(PetPerchState p) {
    _perches.add(p);
    notifyListeners();
  }

  void _remove(PetPerchState p) {
    _perches.remove(p);
    notifyListeners();
  }

  void _changed() => notifyListeners();

  /// The live perches with a box on screen, in [stage]'s coordinates.
  List<PerchSpot> spots(RenderBox stage) => [
    for (final p in _perches)
      if (p.widget.active)
        if (p.rectIn(stage) case final rect?) PerchSpot(p, rect),
  ];

  /// Areas the pet steps aside from (the jump-to-bottom key).
  List<Rect> avoids(RenderBox stage) => [
    for (final a in _avoids)
      if (a.widget.active) ?a.rectIn(stage),
  ];

  /// Something the pet hides for (the slash palette) is up.
  bool get covered => _covers.any((c) => c.widget.active);

  @override
  void dispose() {
    occupied.dispose();
    leading.dispose();
    super.dispose();
  }
}

/// Puts [registry] under a stage; [PetPerch]es below report to it.
class PetPerchScope extends InheritedWidget {
  const PetPerchScope({super.key, required this.registry, required super.child});

  final PerchRegistry registry;

  static PerchRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PetPerchScope>()?.registry;

  @override
  bool updateShouldNotify(PetPerchScope old) => old.registry != registry;
}

Rect? _rectOf(BuildContext context, RenderBox stage, {double minSide = 0}) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize || !stage.attached) return null;
  // Checked before the walk to the stage: a collapsed banner is no perch.
  if (box.size.shortestSide < minSide) return null;
  try {
    final topLeft = box.localToGlobal(Offset.zero, ancestor: stage);
    return topLeft & box.size;
  } catch (_) {
    // Not under the stage (moved by a global key): not a perch now.
    return null;
  }
}

/// A capsule the pet can stand on. [active] false while it is on its way out.
class PetPerch extends StatefulWidget {
  const PetPerch({super.key, required this.kind, this.active = true, required this.child});

  final PerchKind kind;
  final bool active;
  final Widget child;

  @override
  State<PetPerch> createState() => PetPerchState();
}

class PetPerchState extends State<PetPerch> {
  final link = LayerLink();
  PerchRegistry? _registry;

  /// At least 1dp each way to stand on.
  Rect? rectIn(RenderBox stage) => _rectOf(context, stage, minSide: 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = PetPerchScope.maybeOf(context);
    if (registry == _registry) return;
    _registry?._remove(this);
    _registry = registry;
    registry?._add(this);
  }

  @override
  void didUpdateWidget(PetPerch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.kind != widget.kind) _registry?._changed();
  }

  @override
  void dispose() {
    _registry?._remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = _registry;
    if (registry == null) return widget.child;
    return ValueListenableBuilder<bool>(
      valueListenable: registry.leading,
      builder: (context, leading, child) => _PetLeader(link: link, active: leading, child: child),
      child: widget.child,
    );
  }
}

/// [CompositedTransformTarget] that leads only while [active]: off, it is a
/// plain pass-through (no layer), and the tree never changes shape.
class _PetLeader extends SingleChildRenderObjectWidget {
  const _PetLeader({required this.link, required this.active, super.child});

  final LayerLink link;
  final bool active;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPetLeader(link, active);

  @override
  void updateRenderObject(BuildContext context, _RenderPetLeader renderObject) => renderObject
    ..link = link
    ..active = active;
}

class _RenderPetLeader extends RenderProxyBox {
  _RenderPetLeader(this._link, this._active);

  LayerLink _link;
  set link(LayerLink value) {
    if (value == _link) return;
    _link = value;
    markNeedsPaint();
  }

  bool _active;
  set active(bool value) {
    if (value == _active) return;
    _active = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _active;

  @override
  void performLayout() {
    super.performLayout();
    _link.leaderSize = size;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_active) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    final leader = layer;
    if (leader is LeaderLayer) {
      leader
        ..link = _link
        ..offset = offset;
    } else {
      layer = LeaderLayer(link: _link, offset: offset);
    }
    context.pushLayer(layer!, super.paint, Offset.zero);
  }
}

/// An area the pet steps aside from while [active] (it stands beside it).
class PetAvoid extends StatefulWidget {
  const PetAvoid({super.key, this.active = true, required this.child});

  final bool active;
  final Widget child;

  @override
  State<PetAvoid> createState() => PetAvoidState();
}

class PetAvoidState extends State<PetAvoid> {
  PerchRegistry? _registry;

  Rect? rectIn(RenderBox stage) => _rectOf(context, stage);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = PetPerchScope.maybeOf(context);
    if (registry == _registry) return;
    _registry?._avoids.remove(this);
    _registry = registry;
    registry?._avoids.add(this);
    registry?._changed();
  }

  @override
  void didUpdateWidget(PetAvoid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _registry?._changed();
  }

  @override
  void dispose() {
    _registry?._avoids.remove(this);
    _registry?._changed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// While [active], the pet fades away (a panel opened right where it stands).
class PetCover extends StatefulWidget {
  const PetCover({super.key, this.active = true, required this.child});

  final bool active;
  final Widget child;

  @override
  State<PetCover> createState() => PetCoverState();
}

class PetCoverState extends State<PetCover> {
  PerchRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = PetPerchScope.maybeOf(context);
    if (registry == _registry) return;
    _registry?._covers.remove(this);
    _registry = registry;
    registry?._covers.add(this);
    registry?._changed();
  }

  @override
  void didUpdateWidget(PetCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _registry?._changed();
  }

  @override
  void dispose() {
    _registry?._covers.remove(this);
    _registry?._changed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
