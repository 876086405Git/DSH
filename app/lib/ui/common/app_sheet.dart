// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../shell/adaptive/adaptive_layout.dart' show WindowClass;
import '../theme/glass.dart';
import '../theme/motion.dart';
import '../theme/semantic_colors.dart';
import '../theme/shapes.dart';
import '../theme/sheet_recede.dart';
import '../theme/surfaces.dart';
import 'sheet_title_bar.dart';
import 'sheet_dismissal.dart';

export 'sheet_title_bar.dart' show SheetIconButton;
export 'sheet_dismissal.dart' show SheetDismissal, SheetDismissScope, SheetDragHolds;

/// 弹层内容的左右留白(弹层圆角 28,内容左右 20)。
///
/// [SheetHeader] 的标题与关闭钮、弹层里默认的 [SheetGroup] 都对齐到它;
/// 弹层里自己画的内容也用它。
const double kSheetGutter = SheetTitleBar.inset;

/// 分组小标题的字:[SheetGroup]、`ListPageCard`、`SettingsSection` 共用一种。
TextStyle? groupTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelLarge?.copyWith(color: DshColors.of(context).textTertiary);

/// 标记"这里是 showAppSheet 弹出的弹层",让 [SheetGroup] 默认用弹层留白。
class _InAppSheet extends InheritedWidget {
  const _InAppSheet({required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_InAppSheet>() != null;

  @override
  bool updateShouldNotify(_InAppSheet oldWidget) => false;
}

/// 统一的底部弹层入口。
///
/// [glass] = true 时弹层是模糊玻璃(背后的聊天内容透出来、被柔化);
/// 主题关闭模糊时自动退回不透明面,调用方无需判断。
///
/// [dismissal] selects one affordance: drag handle, or an explicit title key.
/// Fixed-height sheets default to button; content-sized sheets default to drag.
/// Button-only sheets cannot be dismissed by a drag or barrier tap.
/// A draggable sheet holding unsaved input ([SheetDragHolds], e.g. a dirty
/// `DiscardGuard`) asks before a drag closes it, like the handle and back do.
///
/// 从底部升起时快出、长尾减速([AppMotion.sheetRise],像有一点阻尼,
/// 不回弹);下拉跟手,松手按位置 / 速度决定收起或弹回。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double? heightFactor,
  bool isScrollControlled = false,
  bool glass = true,
  SheetDismissal? dismissal,
}) {
  final policy = dismissal ?? (heightFactor == null ? SheetDismissal.drag : SheetDismissal.button);
  final draggable = policy == SheetDismissal.drag;
  final holds = draggable ? SheetDragHolds() : null;
  Widget scoped(Widget child) => SheetDismissScope(
    dismissal: policy,
    holds: holds,
    child: _InAppSheet(child: child),
  );
  WidgetBuilder sized(WidgetBuilder inner) => heightFactor == null
      ? (context) => scoped(Builder(builder: inner))
      : (context) => scoped(
          SizedBox(
            height: MediaQuery.sizeOf(context).height * heightFactor,
            width: double.infinity,
            child: Builder(builder: inner),
          ),
        );

  // A phone on its side (under 480 tall): a sheet may rise to just under
  // the status bar instead of stopping at 9/16 of a short window, and sizes
  // to its content up to there. Width: Material's 640, centred between the
  // (mirrored) side insets.
  final short = MediaQuery.sizeOf(context).height < WindowClass.compactHeight;
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: isScrollControlled || heightFactor != null,
    scrollControlDisabledMaxHeightRatio: short ? 1 : 9 / 16,
    // One shared handle supplies the same dismiss action on both surfaces.
    showDragHandle: false,
    enableDrag: draggable,
    isDismissible: draggable,
    backgroundColor: glass ? Colors.transparent : null,
    elevation: 0,
    // 曲线也会被采纳(包括下拉松手后的剩余行程)。
    sheetAnimationStyle: AppMotion.reduced(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: AppMotion.sheetIn,
            reverseDuration: AppMotion.sheetOut,
            curve: AppMotion.sheetRise,
            reverseCurve: AppMotion.sheetFall,
          ),
    builder: sized((context) {
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (draggable) SheetDragHandle(onDismiss: () => Navigator.of(context).maybePop()),
          Flexible(child: builder(context)),
        ],
      );
      Widget surface([Animation<double>? held]) => glass
          ? _SheetGlass(
              held: held,
              child: Material(type: MaterialType.transparency, child: content),
            )
          : content;
      return SheetRecedeSheet(
        child: holds == null ? surface() : _HeldSheetDrag(holds: holds, builder: surface),
      );
    }),
  );
}

/// A sheet's glass, which blurs only at rest. A moving blur re-samples what is
/// behind it every frame, far over the frame budget on some GPUs; so while the
/// route's animation runs or a finger has the sheet, the glass is an opaque
/// fill, and once it stops the fill clears over [AppMotion.glassIn].
class _SheetGlass extends StatefulWidget {
  const _SheetGlass({this.held, required this.child});

  /// How far a [_HeldSheetDrag] has the sheet off its place.
  final Animation<double>? held;
  final Widget child;

  @override
  State<_SheetGlass> createState() => _SheetGlassState();
}

class _SheetGlassState extends State<_SheetGlass> with SingleTickerProviderStateMixin {
  late final AnimationController _settled = AnimationController(vsync: this, duration: AppMotion.glassIn);
  Animation<double>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    _route = ModalRoute.of(context)!.animation!..addStatusListener(_onRoute);
    widget.held?.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onRoute);
    widget.held?.removeListener(_sync);
    _settled.dispose();
    super.dispose();
  }

  void _onRoute(AnimationStatus _) => _sync();

  void _sync() {
    if (!_route!.isCompleted || (widget.held?.value ?? 0) != 0) {
      if (_settled.value != 0) _settled.value = 0;
    } else if (AppMotion.reduced(context)) {
      _settled.value = 1;
    } else if (!_settled.isForwardOrCompleted) {
      unawaited(_settled.forward());
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _settled,
    builder: (context, child) => GlassSurface(
      tier: GlassTier.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppShape.xl)),
      settled: _settled.value,
      child: child,
    ),
    child: widget.child,
  );
}

/// A draggable sheet's drag while one of its [SheetDragHolds] is on.
///
/// It sits inside the sheet's own drag, so it takes the gesture first (as an
/// inner scroll view does); otherwise it stays out of the arena. It follows
/// the finger and springs back; where the sheet would have closed (a fling
/// down, or past half its height, as `BottomSheet` decides) it asks the route
/// with `maybePop`, and the content's [PopScope] answers.
class _HeldSheetDrag extends StatefulWidget {
  const _HeldSheetDrag({required this.holds, required this.builder});

  final SheetDragHolds holds;

  /// The sheet, told how far the drag has it off its place.
  final Widget Function(Animation<double> offset) builder;

  @override
  State<_HeldSheetDrag> createState() => _HeldSheetDragState();
}

class _HeldSheetDragState extends State<_HeldSheetDrag> with SingleTickerProviderStateMixin {
  // BottomSheet's own thresholds.
  static const _flingVelocity = 700.0;
  static const _closeFraction = 0.5;

  late final AnimationController _offset = AnimationController.unbounded(vsync: this);
  double _dragged = 0;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails details) {
    // Caught on its way back: the drag carries on from where the sheet is.
    if (_offset.isAnimating) {
      _offset.stop();
      _dragged = _offset.value;
    }
    _dragged += details.delta.dy;
    _offset.value = math.max(0, _dragged);
  }

  /// [velocity]: pixels a second, downwards.
  void _settle([double velocity = 0]) {
    _dragged = 0;
    if (AppMotion.reduced(context) || _offset.value == 0) {
      _offset.value = 0;
      return;
    }
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    unawaited(_offset.animateWith(AppMotion.settle(AppMotion.sheetSpring, _offset.value, 0, velocity, extent: height)));
  }

  void _end(DragEndDetails details) {
    final height = context.size?.height ?? double.infinity;
    final velocity = details.primaryVelocity ?? 0;
    final closing = velocity > _flingVelocity || _dragged > height * _closeFraction;
    _settle(velocity);
    if (closing) unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: {
      _HeldDragRecognizer: GestureRecognizerFactoryWithHandlers<_HeldDragRecognizer>(
        () => _HeldDragRecognizer(holds: widget.holds, debugOwner: this),
        (recognizer) => recognizer
          ..holds = widget.holds
          ..onlyAcceptDragOnThreshold = true
          ..onUpdate = _update
          ..onEnd = _end
          ..onCancel = _settle,
      ),
    },
    child: AnimatedBuilder(
      animation: _offset,
      builder: (context, child) => Transform.translate(offset: Offset(0, _offset.value), child: child),
      child: widget.builder(_offset),
    ),
  );
}

/// Joins a gesture only while the sheet is held; otherwise the sheet's own
/// drag gets it, unchanged.
class _HeldDragRecognizer extends VerticalDragGestureRecognizer {
  _HeldDragRecognizer({required this.holds, super.debugOwner});

  SheetDragHolds holds;

  @override
  bool isPointerAllowed(PointerEvent event) => holds.held && super.isPointerAllowed(event);
}

/// 玻璃弹层顶部的拖把手(36×4,次级文字色 35%)。
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key, this.onDismiss});

  /// Null keeps the mark decorative (e.g. the adaptive resize handle).
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.35);
    final mark = Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: Container(
        width: 36,
        height: 4,
        decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
      ),
    );
    if (onDismiss == null) return mark;
    return Semantics(
      button: true,
      label: context.l10n.commonClose,
      onTap: onDismiss,
      onDismiss: onDismiss,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: Center(child: mark),
        ),
      ),
    );
  }
}

/// 弹层标题行:遵循共同退出策略;二级页保留左侧返回钮。
/// 标题和右侧操作的可见边缘与 [kSheetGutter](20) 对齐。
class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key, this.actions = const [], this.maxLines = 1});

  final String title;
  final List<Widget> actions;

  /// As [SheetTitleBar.maxLines].
  final int? maxLines;
  static const buttonSize = SheetTitleBar.keySize;

  @override
  Widget build(BuildContext context) => SheetTitleBar(title, actions: actions, maxLines: maxLines);
}

/// 弹层内的分组:一块 card 玻璃,组内项之间 2px 间隙,不画分隔线
/// (靠留白与材质分组)。
class SheetGroup extends StatelessWidget {
  const SheetGroup({super.key, required this.children, this.title, this.margin});

  final List<Widget> children;

  /// 可选组标题(卡片上方,labelLarge + 次级文字色)。
  final String? title;

  /// 缺省:页面里左右 16;`showAppSheet` 弹层里左右 [kSheetGutter](20)。
  /// 上下 6。
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final horizontal = _InAppSheet.of(context) ? kSheetGutter : 16.0;
    return Padding(
      padding: margin ?? EdgeInsets.symmetric(horizontal: horizontal, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title case final label?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Semantics(header: true, child: Text(label, style: groupTitleStyle(context))),
            ),
          GlassSurface(
            tier: GlassTier.card,
            borderRadius: AppShape.radiusLg,
            child: Material(
              // 水波画在玻璃之上,而不是被半透明填充盖住。
              type: MaterialType.transparency,
              clipBehavior: Clip.antiAlias,
              shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(height: 2), child],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
