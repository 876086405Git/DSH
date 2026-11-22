import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 全 App 弹对话框的唯一入口,用法和 [showDialog] 一样。
///
/// 标准档就是 [showDialog]。灵动档([AppMotion.fluid])下对话框带一点回弹地弹出来,
/// 收起时快速缩小淡出;只多一个缩放,不多离屏层。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute)? onRouteChanged,
}) {
  // This opaque identity belongs only to the opted-in caller of this exact
  // dialog. The previous owned route can identify it before its builder runs.
  final settings = onRouteChanged == null ? null : RouteSettings(arguments: onRouteChanged);
  Widget content(BuildContext context) => onRouteChanged == null
      ? builder(context)
      : _DialogRouteObservation(
          onRouteChanged: onRouteChanged,
          child: Builder(builder: builder),
        );
  if (!AppMotion.fluid(context)) {
    return showDialog<T>(
      context: context,
      builder: content,
      barrierDismissible: barrierDismissible,
      routeSettings: settings,
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    routeSettings: settings,
    animationStyle: AnimationStyle(
      duration: AppMotion.popCurve.duration,
      reverseDuration: AppMotion.quick,
      // 这是路由整体的淡入:弹簧要走满,淡入不用等它。
      curve: const Interval(0, 0.35, curve: Curves.easeOut),
      reverseCurve: Curves.easeOut,
    ),
    builder: (context) => _DialogPop(child: Builder(builder: content)),
  );
}

/// Observe the actual dialog route without replacing showDialog's platform
/// behaviour. Its owner checks after this frame, when the builder has run.
class _DialogRouteObservation extends StatefulWidget {
  const _DialogRouteObservation({required this.onRouteChanged, required this.child});
  final void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute) onRouteChanged;
  final Widget child;

  @override
  State<_DialogRouteObservation> createState() => _DialogRouteObservationState();
}

class _DialogRouteObservationState extends State<_DialogRouteObservation> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of<Object?>(context);
    if (route != null) {
      widget.onRouteChanged(route, null);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DialogPop extends StatefulWidget {
  const _DialogPop({required this.child});

  final Widget child;

  @override
  State<_DialogPop> createState() => _DialogPopState();
}

class _DialogPopState extends State<_DialogPop> {
  static const _from = 0.9;

  CurvedAnimation? _curved;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (route == null || _curved?.parent == route) return;
    _curved?.dispose();
    _curved = CurvedAnimation(parent: route, curve: AppMotion.popCurve, reverseCurve: Curves.easeOut);
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    if (curved == null) return widget.child;
    return ScaleTransition(
      scale: Tween(begin: _from, end: 1.0).animate(curved),
      child: widget.child,
    );
  }
}
