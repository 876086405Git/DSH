// The horizontal safe area, mirrored.
//
// A phone on its side reports its camera cutout (or a three-button
// navigation bar) on one side only. Content keeps clear of it on both sides,
// the way iOS hands out landscape safe areas, so a centred layout stays
// centred on the glass and left / right keys stay mirror images.

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// The larger of the left and right system insets: what content keeps clear
/// of on each side.
double sideInsetOf(BuildContext context) => sideInsetFor(MediaQuery.paddingOf(context));

/// [sideInsetOf] for a known [padding].
double sideInsetFor(EdgeInsets padding) => math.max(padding.left, padding.right);

/// [media] for content [inset] in from both sides: narrower by both insets,
/// with no horizontal system insets left (they are behind it now).
MediaQueryData sideTrimmed(MediaQueryData media, double inset) {
  EdgeInsets trim(EdgeInsets e) => EdgeInsets.fromLTRB(0, e.top, 0, e.bottom);
  return media.copyWith(
    size: Size(math.max(0, media.size.width - 2 * inset), media.size.height),
    padding: trim(media.padding),
    viewPadding: trim(media.viewPadding),
    viewInsets: trim(media.viewInsets),
    systemGestureInsets: trim(media.systemGestureInsets),
  );
}

/// Insets [child] by [sideInsetOf] on both sides and hands it a window
/// without horizontal insets, so it lays out as if there were no cutout.
///
/// Draws nothing itself: a page's backdrop stays edge to edge behind it.
/// The same widgets wrap [child] at every inset (zero when upright), so
/// turning the phone keeps its state.
class SideSafeArea extends StatelessWidget {
  const SideSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final inset = sideInsetFor(media.padding);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: MediaQuery(data: sideTrimmed(media, inset), child: child),
    );
  }
}

/// Hands everything under it symmetric side insets: both the larger of the
/// two (padding and view padding alike). Sits at the app's root, so every
/// [SafeArea], sheet and dialog stays centred on a phone on its side, as on
/// iOS.
class MirroredSideInsets extends StatelessWidget {
  const MirroredSideInsets({super.key, required this.child});

  final Widget child;

  static EdgeInsets mirror(EdgeInsets e, [double cutout = 0]) {
    final side = math.max(sideInsetFor(e), cutout);
    return EdgeInsets.fromLTRB(side, e.top, side, e.bottom);
  }

  /// How far a cutout reaches in from the side of a phone held on its side.
  /// HarmonyOS reports it only as a display feature, never in the padding.
  static double cutoutInset(MediaQueryData media) {
    final width = media.size.width;
    if (width <= media.size.height) return 0;
    var inset = 0.0;
    for (final feature in media.displayFeatures) {
      if (feature.type != DisplayFeatureType.cutout) continue;
      final bounds = feature.bounds;
      inset = math.max(inset, bounds.center.dx < width / 2 ? bounds.right : width - bounds.left);
    }
    return inset;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final cutout = Platform.operatingSystem == 'ohos' ? cutoutInset(media) : 0.0;
    return MediaQuery(
      data: media.copyWith(padding: mirror(media.padding, cutout), viewPadding: mirror(media.viewPadding, cutout)),
      child: child,
    );
  }
}
