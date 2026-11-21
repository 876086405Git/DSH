// The pet's speech bubble (docs/design/pets.md §2.6): one glass capsule over
// its head — 「做完了」, 「标题 · 等你确认」, 「3 个对话做完了」. Only the (masked) title, never the
// conversation's text, never buttons. It replaces the glass banner while the
// pet is on screen, so it carries the banner's accessibility: a live region,
// focusable, tappable.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../pets/pet_state.dart';
import '../theme/theme.dart';

/// The bubble's make-up, measured in `test/pets/pet_parts_test.dart`.
abstract final class PetBubbleMetrics {
  static const height = 32.0;

  /// Left and right inside the capsule (equal: the dot has no air of its own).
  static const pad = 12.0;
  static const dot = 6.0;
  static const dotGap = 8.0;
  static const maxWidth = 260.0;

  /// Between the bubble's bottom and the top of the pet's body.
  static const lift = 6.0;
}

/// A tone per kind: done in the success colour, a failure in danger,
/// waiting requests in warning (as the run strip shows them).
Color petBubbleTone(BuildContext context, PetBubbleKind kind) {
  final dsh = DshColors.of(context);
  return switch (kind) {
    PetBubbleKind.done => dsh.success,
    PetBubbleKind.failed => dsh.danger,
    PetBubbleKind.approval || PetBubbleKind.question => dsh.warning,
  };
}

/// The capsule itself.
class PetBubbleView extends StatelessWidget {
  const PetBubbleView({super.key, required this.bubble, this.onTap});

  final PetBubble bubble;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final title = bubble.shortTitle;
    final verb = theme.textTheme.labelMedium!.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );
    final quiet = theme.textTheme.labelMedium!.copyWith(
      color: dsh.textTertiary,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );
    return Semantics(
      container: true,
      liveRegion: true,
      button: onTap != null,
      label: bubble.text,
      excludeSemantics: true,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PetBubbleMetrics.maxWidth),
        child: GlassSurface(
          tier: GlassTier.chrome,
          stadium: true,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: PetBubbleMetrics.height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: PetBubbleMetrics.pad, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    key: const ValueKey('pet-bubble-dot'),
                    width: PetBubbleMetrics.dot,
                    height: PetBubbleMetrics.dot,
                    decoration: ShapeDecoration(
                      color: petBubbleTone(context, bubble.kind),
                      shape: const CircleBorder(),
                    ),
                  ),
                  const SizedBox(width: PetBubbleMetrics.dotGap),
                  if (title != null) ...[
                    Flexible(
                      child: Text(title, style: quiet, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text(' · ', style: quiet),
                  ],
                  Text(bubble.verb, key: const ValueKey('pet-bubble-verb'), style: verb, maxLines: 1),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bubble coming and going: rises out of the pet's head (scale from its
/// bottom centre + fade), fades when it goes. Instant without animations.
class PetBubbleSwitcher extends StatelessWidget {
  const PetBubbleSwitcher({super.key, required this.child});

  /// The bubble (keyed by its id) or nothing.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.standard),
      reverseDuration: AppMotion.of(context, AppMotion.quick),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.bottomCenter, clipBehavior: Clip.none, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          alignment: Alignment.bottomCenter,
          scale: Tween(begin: 0.9, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: child ?? const SizedBox.shrink(key: ValueKey('none')),
    );
  }
}
