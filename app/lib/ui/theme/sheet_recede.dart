// iOS's page sheet: while a sheet is up, the page under it sits back a little, its corners round
// off and the status bar turns light over the dark edge that shows. It follows the sheet, finger
// included. On the fluid tier and on phones only, and nothing at all on other platforms.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import 'motion.dart';
import 'shapes.dart';

bool get _available => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Sheets take over the whole screen's attention on a phone. A tablet's float in the middle and
/// leave the page where it is, as the system's do.
bool _sitsBack(BuildContext context) => AppMotion.fluid(context) && MediaQuery.sizeOf(context).shortestSide < 600;

/// How far the open sheets have the page sat back, from 0 to 1.
abstract final class SheetRecede {
  /// How small the page gets, all the way back.
  static const scale = 0.94;

  static final _sheets = <Animation<double>>{};
  static final _amount = ValueNotifier<double>(0);

  @visibleForTesting
  static ValueListenable<double> get amount => _amount;

  static void _update() {
    var most = 0.0;
    for (final sheet in _sheets) {
      most = math.max(most, sheet.value);
    }
    // The same rise as the sheet, which only takes a curve through its own animation style.
    _amount.value = AppMotion.sheetRise.transform(most.clamp(0.0, 1.0));
  }

  static void _add(Animation<double> sheet) {
    if (_sheets.add(sheet)) sheet.addListener(_update);
    // A sheet comes and goes during a build, which can't rebuild the page.
    scheduleMicrotask(_update);
  }

  static void _remove(Animation<double> sheet) {
    if (_sheets.remove(sheet)) sheet.removeListener(_update);
    scheduleMicrotask(_update);
  }
}

/// Around a page. The tree stays the same whatever the amount, so nothing in the page rebuilds or
/// loses its state.
class SheetRecedePage extends StatelessWidget {
  const SheetRecedePage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!_available) return child;
    final sits = _sitsBack(context);
    final top = MediaQuery.paddingOf(context).top;
    return ValueListenableBuilder<double>(
      valueListenable: SheetRecede._amount,
      child: child,
      builder: (context, amount, child) {
        final t = sits ? amount : 0.0;
        final scale = 1 - (1 - SheetRecede.scale) * t;
        return Transform(
          alignment: Alignment.topCenter,
          // Below the status bar, whose text stays on the dark edge.
          transform: Matrix4.translationValues(0, top * t, 0)..scaleByDouble(scale, scale, 1, 1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppShape.lg * t),
            clipBehavior: t == 0 ? Clip.none : Clip.antiAlias,
            child: child,
          ),
        );
      },
    );
  }
}

/// Inside a sheet: tells the page how far up it is.
class SheetRecedeSheet extends StatefulWidget {
  const SheetRecedeSheet({super.key, required this.child});

  final Widget child;

  @override
  State<SheetRecedeSheet> createState() => _SheetRecedeSheetState();
}

class _SheetRecedeSheetState extends State<SheetRecedeSheet> {
  Animation<double>? _route;
  final _statusBar = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    if (_available) _statusBar.show();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_available) return;
    final route = ModalRoute.of(context)?.animation;
    if (route == _route) return;
    if (_route != null) SheetRecede._remove(_route!);
    _route = route;
    if (route != null) SheetRecede._add(route);
  }

  @override
  void dispose() {
    if (_route != null) SheetRecede._remove(_route!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return widget.child;
    // The status bar reads the topmost region at its own height, which is outside the sheet's
    // clip, so this one goes on the overlay, above the sheet. It turns once the page has sat back
    // far enough to show the dark edge.
    final sits = _sitsBack(context);
    return OverlayPortal(
      controller: _statusBar,
      overlayChildBuilder: (context) => ValueListenableBuilder<double>(
        valueListenable: SheetRecede._amount,
        builder: (context, amount, _) => sits && amount > 0.5
            ? const AnnotatedRegion<SystemUiOverlayStyle>(
                value: SystemUiOverlayStyle.light,
                sized: false,
                child: SizedBox.shrink(),
              )
            : const SizedBox.shrink(),
      ),
      child: widget.child,
    );
  }
}
